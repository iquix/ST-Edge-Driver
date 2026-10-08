-- KNX IP Interface Connector
-- Copyright © 2025-2026 Jaewon Park (iquix)
-- Licensed under the Apache License, Version 2.0

-- SmartThings Edge Platform libraries
local st_device = require "st.device"
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local stutils = require "st.utils"
local net_utils = require "st.net_utils"
local log = require "log"

-- Driver modules
local device_utils = require "device_utils"
local disco = require "disco"
local command_handlers = require "command_handlers"
local KnxDispatcher = require "knx_dispatcher"

-- KNX Protocol Subsystem
local KnxTunnel = require "knx.tunnel"
local knxnet_ip = require "knx.knxnet_ip"
local telegram = require "knx.telegram"
local KnxTelegramTx = telegram.KnxTelegramTx

local KNX_TELEGRAM_CAP_ID = 'iquix.knxtelegram'

local lan_driver


------------------------------------------------------------------------
-- HELPER FUNCTIONS
------------------------------------------------------------------------

-- Get the gateway device (returns parent if child, self if already gateway)
local function get_gateway_device(device)
  return (device.network_type == st_device.NETWORK_TYPE_CHILD) and device:get_parent_device() or device
end

-- Get the KnxTunnel instance for a device (resolves from gateway)
local function get_tunnel(device)
  local gateway = get_gateway_device(device)
  return gateway:get_field("tunnel")
end

-- Get resolved IP and port for a gateway device
local function get_gateway_ip_port(device)
  local addr = device.preferences.addr
  if not addr or addr == "" then
    addr = device:get_field("discovered_addr")
  end
  if not addr or addr == "" then return nil end
  local ip, port = addr:match('([^:]+):?(.*)$')
  port = tonumber(port) or knxnet_ip.DEFAULT_PORT
  if not net_utils.validate_ipv4_string(ip) or not net_utils.validate_port(port) then return nil end
  return ip, port
end

-- Synchronize online/offline status across gateway and its child devices
local function set_online_status(device, is_online)
  local target_state = is_online == true
  local update_status = function(target_device)
    if target_device:get_field("is_online") ~= target_state then
      target_device:set_field("is_online", target_state)
      if target_state then
        target_device:online()
      else
        target_device:offline()
      end
    end
  end
  update_status(device)
  for _, child in ipairs(device:get_child_list()) do
    update_status(child)
  end
end

-- Send GroupValueRead telegrams for a device (or all children if parent)
local function read_device_state(driver, device)
  local tunnel = get_tunnel(device)
  if not tunnel or not tunnel:is_connected() then
    return false
  end

  if device.network_type == st_device.NETWORK_TYPE_CHILD then
    local subscriptions = driver.knx_dispatcher:get_subscriptions(device)
    for group_address, _ in pairs(subscriptions) do
      device:send(KnxTelegramTx.read(group_address))
    end
    return true
  else
    local children = device:get_child_list()
    for _, child in ipairs(children) do
      read_device_state(driver, child)
    end
    return true
  end
end


------------------------------------------------------------------------
-- INBOUND TELEGRAM DISPATCH
------------------------------------------------------------------------

-- Dispatch a decoded KnxTelegramRx to matching child devices of a specific gateway
local function dispatch_knx_telegram(driver, device, knx_rx)
  local dispatched = false
  local children = device:get_child_list()

  for _, dev in ipairs(children) do
    if driver.knx_dispatcher:is_subscribed(dev, knx_rx.dst) then
      dev.log.info_with({ hub_logs = true }, string.format("received KnxTelegramRx: %s", knx_rx))
      driver.knx_dispatcher:dispatch(driver, dev, knx_rx)
      dispatched = true
    end
  end

  if not dispatched then
    device.log.debug(string.format("Received unhandled KnxTelegramRx: %s", knx_rx))
  end
  return dispatched
end

-- Schedule an asynchronous reconnection timer with exponential backoff
local function schedule_reconnect(device, delay)
  local tunnel = device:get_field("tunnel")
  if not tunnel then return end

  tunnel:cancel_reconnect_timer()

  local timer
  timer = device.thread:call_with_delay(delay, function(_)
    tunnel:cancel_reconnect_timer()
    if tunnel:get_state() == KnxTunnel.STATE.STOPPED then
      local pref_addr = device.preferences.addr
      if not pref_addr or pref_addr == "" then
        disco.update_device_addr(device)
      end
      local ip, port = get_gateway_ip_port(device)
      tunnel:start(ip, port)
    end
  end)

  tunnel:set_reconnect_timer(timer, function()
    device.thread:cancel_timer(timer)
  end)
end


------------------------------------------------------------------------
-- DEVICE EXTENSION (device:send)
------------------------------------------------------------------------

-- Send a KnxTelegramTx to this device
local function device_send(self, tx)
  local tunnel = get_tunnel(self)
  if not tunnel then
    self.log.warn_with({ hub_logs = true }, "Failed to send KnxTelegramTx: tunnel not initialized")
    return false
  end

  local ok, err = tunnel:send_telegram(tx)
  if not ok then
    self.log.warn_with({ hub_logs = true }, string.format("Failed to send KnxTelegramTx: %s", tostring(err)))
    return false
  end

  self.log.info_with({ hub_logs = true }, string.format("sending KnxTelegramTx: %s", tx))
  return true
end


------------------------------------------------------------------------
-- DEFAULT COMMAND HANDLERS
------------------------------------------------------------------------

local function refresh_handler(driver, device, command)
  device.log.info_with({ hub_logs = true }, "refresh() called")
  local gateway = get_gateway_device(device)
  local tunnel = get_tunnel(device)
  local is_connected = tunnel and tunnel:is_connected() or false

  set_online_status(gateway, is_connected)
  if is_connected and device.network_type == st_device.NETWORK_TYPE_CHILD then
    read_device_state(driver, device)
  end
end


------------------------------------------------------------------------
-- REQUIRED EDGE DRIVER HANDLERS
------------------------------------------------------------------------

local function create_child_device(driver, device, device_type)
  local create_device_msg = {
    type = "EDGE_CHILD",
    parent_assigned_child_key = device_utils.build_child_key(device_type),
    label = 'KNX '..device_type,
    profile = device_utils.build_profile_name(device_type),
    parent_device_id = device.id,
    manufacturer = 'SmartThings Community',
    model = 'KNX IP',
    vendor_provided_label = 'KNX IP',
  }
  driver:try_create_device(create_device_msg)
end

local function device_init(driver, device)
  -- this is called both when a device is added (but after `added`) and after a hub reboots.
  device:extend_device("send", device_send)
  log.debug(device.id .. ": " .. device.device_network_id .. "> INITIALIZING")
  if device.network_type ~= st_device.NETWORK_TYPE_CHILD then
    -- Check if device fields need to be set from discovery cache
    local discovered_addr = device:get_field("discovered_addr")
    if not discovered_addr then
      if driver.datastore.discovery_cache and driver.datastore.discovery_cache[device.device_network_id] then
        disco.set_device_field(driver, device)
      end
    end

    local old_tunnel = device:get_field("tunnel")
    if old_tunnel then
      old_tunnel:stop()
    end

    local tunnel
    tunnel = KnxTunnel({
      on_connect = function()
        set_online_status(device, true)
        device.log.info_with({ hub_logs = true }, "KNX IP gateway connected.")
        read_device_state(driver, device)
      end,

      on_telegram = function(knx_rx)
        dispatch_knx_telegram(driver, device, knx_rx)
      end,

      on_disconnect = function(reason)
        set_online_status(device, false)

        if reason == KnxTunnel.DISCONNECT_REASON.USER_STOP then
          device.log.info_with({ hub_logs = true }, string.format("KNX disconnected: %s", reason))
        else
          device.log.warn_with({ hub_logs = true }, string.format("KNX disconnected: %s", reason))
          local delay = tunnel:get_and_advance_reconnect_delay()
          device.log.info_with({ hub_logs = true }, string.format("Scheduling reconnect in %d seconds (exponential backoff)", delay))
          schedule_reconnect(device, delay)
        end
      end,
    }, {
      log = log,
    })

    device:set_field("tunnel", tunnel, { persist = false })

    -- benchmark.run()
    local ip, port = get_gateway_ip_port(device)
    tunnel:start(ip, port)
  else
    driver.knx_dispatcher:subscribe_device(device)
    local tunnel = get_tunnel(device)
    if tunnel and tunnel:is_connected() and not device:get_field("is_online") then
      device:set_field("is_online", true)
      device:online()
    end
  end
end

local function device_added(driver, device)
  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")
  if device.network_type ~= st_device.NETWORK_TYPE_CHILD then
    disco.device_added(driver, device)
  end
end

local function device_removed(driver, device)
  log.debug(device.id .. ": " .. device.device_network_id .. "> REMOVED")
  if device.network_type ~= st_device.NETWORK_TYPE_CHILD then
    local tunnel = device:get_field("tunnel")
    if tunnel then
      tunnel:stop()
      device:set_field("tunnel", nil, { persist = false })
    end
  else
    driver.knx_dispatcher:unsubscribe_device(device)
  end
end

local function device_info_changed(driver, device, event, args)
  log.debug(device.id .. ": " .. device.device_network_id .. "> INFO CHANGED")

  if device.network_type == st_device.NETWORK_TYPE_CHILD then
    driver.knx_dispatcher:subscribe_device(device)
    read_device_state(driver, device)
    return
  end

  local tunnel = device:get_field("tunnel")
  if args.old_st_store.preferences.addr ~= device.preferences.addr then
    log.debug(device.id .. ": " .. device.device_network_id .. "> IP address changed to " .. tostring(device.preferences.addr))
    local ip, port = get_gateway_ip_port(device)
    if tunnel then
      tunnel:restart(ip, port)
    end
  end
  for _, sub in ipairs(driver.sub_drivers) do
    local create_name = stutils.camel_case("create_"..sub.NAME)
    if args.old_st_store.preferences[create_name] == false and device.preferences[create_name] == true then
      create_child_device(driver, device, sub.NAME)
      break
    end
  end
end


lan_driver = Driver("lan_driver", {
  discovery = disco.discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = device_info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = command_handlers.switch_handler,
      [capabilities.switch.commands.off.NAME] = command_handlers.switch_handler,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = command_handlers.switch_level_handler,
    },
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = command_handlers.color_temperature_handler,
    },
    [capabilities.statelessSwitchLevelStep.ID] = {
      [capabilities.statelessSwitchLevelStep.commands.stepLevel.NAME] = command_handlers.switch_level_step_handler,
    },
    [KNX_TELEGRAM_CAP_ID] = {
      ["send"] = command_handlers.send_knx_telegram_handler,
    },
  },
  sub_drivers = {
    require "sub_drivers.button",
    require "sub_drivers.button2",
    require "sub_drivers.illuminance",
    require "sub_drivers.color_temperature",
    require "sub_drivers.switch",
    require "sub_drivers.color_temp_bulb",
    require "sub_drivers.fan_5speed",
  },
})

lan_driver.knx_dispatcher = KnxDispatcher(lan_driver.NAME, function() return true end, {})
KnxDispatcher.set_group_address_resolver(function(device, handler_key)
  return device.preferences and device.preferences[handler_key]
end)
KnxDispatcher.populate_knx_dispatcher_from_sub_drivers(lan_driver)

if lan_driver.datastore.discovery_cache == nil then
  lan_driver.datastore.discovery_cache = {}
end

log.info('Starting SmartThings KNX/IP Interface Connector')
lan_driver:run()
