-- Zigbee Switch with Child ver 0.5.0
-- Copyright 2021-2022 Jaewon Park (iquix)
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local st_device = require "st.device"
local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local zcl_messages = require "st.zigbee.zcl"
local messages = require "st.zigbee.messages"
local data_types = require "st.zigbee.data_types"
local zb_const = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"
local read_attribute = require "st.zigbee.zcl.global_commands.read_attribute"
local default_response = require "st.zigbee.zcl.global_commands.default_response"
local device_management = require "st.zigbee.device_management"
local switch_defaults = require "st.zigbee.defaults.switch_defaults"
local log = require "log"

local device_data = require "device_data"

local CLUSTER_TUYA = 0xEF00
local CLUSTER_BASIC = 0x0000
local SET_DATA = 0x00
local DP_TYPE_BOOL = "\x01"
local TUYA_MODEL_HEADER = "TS"
local TUYA_MCU_MODEL = "TS0601"

local packet_id = 0
local POLLING_TIMER = "switch_polling_timer"


--------------------------------------------------

local function refresh_handler(device)
  local attrRead = zcl_clusters.OnOff.attributes.OnOff:read(device)
  for _, ep in pairs(device.zigbee_endpoints) do
    device:send(attrRead:to_endpoint(ep.id))
  end
end

local function setup_polling(device)
  log.debug("** setup_polling()")
  local polling_timer = device:get_field(POLLING_TIMER)
  if polling_timer then
    log.debug("** unschedule polling...")
    device.thread:cancel_timer(polling_timer)
    polling_timer = nil
  end
  log.debug("** set polling every 5 minutes...")
  polling_timer = device.thread:call_on_schedule(300, function(d)
    refresh_handler(device)
  end)
  device:set_field(POLLING_TIMER, polling_timer)
end

--------------------------------------------------

local function is_tuya_mcu_switch(device)
  return (device:get_model() == TUYA_MCU_MODEL)
end

local function send_tuya_command(device, dp, dp_type, fncmd) 
  local zclh = zcl_messages.ZclHeader({cmd = data_types.ZCLCommandId(SET_DATA)})
  zclh.frame_ctrl:set_cluster_specific()
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(CLUSTER_TUYA),
    zb_const.HA_PROFILE_ID,
    CLUSTER_TUYA
  )
  packet_id = (packet_id + 1) % 65536
  local fncmd_len = string.len(fncmd)
  local payload_body = generic_body.GenericBody(string.pack(">I2", packet_id) .. dp .. dp_type .. string.pack(">I2", fncmd_len) .. fncmd)
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = payload_body
  })
  local send_message = messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body
  })
  device:send(send_message)
end

local function configure_tuya_magic_packet(device)
  local zclh = zcl_messages.ZclHeader({cmd = data_types.ZCLCommandId(read_attribute.ReadAttribute.ID)})
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(CLUSTER_BASIC),
    zb_const.HA_PROFILE_ID,
    CLUSTER_BASIC
  )
  local payload_body = read_attribute.ReadAttribute( {0x0004, 0x0000, 0x0001, 0x0005, 0x0007,0xFFFE} )
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = payload_body
  })
  local send_message = messages.ZigbeeMessageTx({
      address_header = addrh,
      body = message_body
  })
  device:send(send_message)
end

--------------------------------------------------

local function find_child(parent, endpoint)
  return parent:get_child_by_parent_assigned_key(string.format("%02X", endpoint))
end

local function get_ep_array(device)
  local ep_array

  if device.preferences.forceChild > 0 then
    ep_array = {}
    for i = 1, device.preferences.forceChild do ep_array[i] = i end  -- assuming ep# from 1 to 'forceChild'
    return ep_array
  end
  
  ep_array = device_data.endpoints[device:get_manufacturer().."/"..device:get_model()]
  if ep_array ~= nil then return ep_array end
  
  if is_tuya_mcu_switch(device) then
    return {1,2,3,4,5,6}
  end

  ep_array = {}
  for _, ep in pairs(device.zigbee_endpoints) do
    for _, clus in ipairs(ep.server_clusters) do
      if clus == zcl_clusters.OnOff.ID then
        table.insert(ep_array, tonumber(ep.id))
        break
      end
    end
  end
  table.sort(ep_array)
  return ep_array
end

local function create_child_devices(driver, device)
  log.debug("create_child_devices()")
  for _, ep in pairs(get_ep_array(device)) do
    if ep ~= device.fingerprinted_endpoint_id then
      if find_child(device, ep) == nil then
        local metadata = {
          type = "EDGE_CHILD",
          parent_assigned_child_key = string.format("%02X", ep),
          label = device.label..' '..ep,
          profile = "child-switch",
          parent_device_id = device.id,
          manufacturer = device:get_manufacturer(),
          model = device:get_model()
        }
        driver:try_create_device(metadata)
      end
    end
  end
end

--------------------------------------------------

local function tuya_cluster_handler(driver, device, zb_rx)
  local rx = zb_rx.body.zcl_body.body_bytes
  local dp = string.byte(rx:sub(3,3))
  local fncmd_len = string.unpack(">I2", rx:sub(5,6))
  local fncmd = string.unpack(">I"..fncmd_len, rx:sub(7))
  device:emit_event_for_endpoint(dp, capabilities.switch.switch(fncmd == 1 and "on" or "off"))
end

local function default_response_handler(driver, device, zb_rx)
  if is_tuya_mcu_switch(device) then return end  -- ignore default responses from tuya switches
  switch_defaults.default_response_handler(driver, device, zb_rx)
end

local function on_off_attr_handler(driver, device, value, zb_rx)
  if is_tuya_mcu_switch(device) then return end  -- ignore OnOff attrs from tuya switches
  switch_defaults.on_off_attr_handler(driver, device, value, zb_rx)
end

local function switch_on(driver, device, command)
  if is_tuya_mcu_switch(device) then
    local dp = (device.network_type == st_device.NETWORK_TYPE_CHILD) and string.char(device:get_endpoint()) or "\x01"
    send_tuya_command(device, dp, DP_TYPE_BOOL, "\x01") 
  else
    switch_defaults.on(driver, device, command)
  end
end

local function switch_off(driver, device, command)
  if is_tuya_mcu_switch(device) then
    local dp = (device.network_type == st_device.NETWORK_TYPE_CHILD) and string.char(device:get_endpoint()) or "\x01"
    send_tuya_command(device, dp, DP_TYPE_BOOL, "\x00") 
  else
    switch_defaults.off(driver, device, command)
  end
end

--------------------------------------------------

local function do_configure(self, device)
  if device.network_type == st_device.NETWORK_TYPE_CHILD then return end
  log.debug("parent do_configure()")
  
  if string.sub(device:get_model(),1,2) == TUYA_MODEL_HEADER then  -- if it is a tuya device, then send the magic packet
    configure_tuya_magic_packet(device)
  end
  
  if device_data.is_polling_manufacturer[device:get_manufacturer()] then
    device:send(cluster_base.write_manufacturer_specific_attribute(device, zcl_clusters.Basic.ID, 0x0099, 0x0000, data_types.Uint8, 0x01))
    setup_polling(device)
  elseif not is_tuya_mcu_switch(device) then  -- nothing to configure for tuya MCU switch
    local attrCfg = device_management.attr_config(device, switch_defaults.default_on_off_configuration)
    local attrRead = zcl_clusters.OnOff.attributes.OnOff:read(device)
    for _, ep in pairs(device.zigbee_endpoints) do
      local bindReq = device_management.build_bind_request(device, zcl_clusters.OnOff.ID, device.driver.environment_info.hub_zigbee_eui, ep.id)
      device:send(bindReq:to_endpoint(ep.id))
      device:send(attrCfg:to_endpoint(ep.id))
      device:send(attrRead:to_endpoint(ep.id))
    end
  end
end

local function device_added(driver, device)
  log.debug("device_added()")
  if device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "on" then
    device:emit_event(capabilities.switch.switch.off())
  end
  if device.network_type ~= st_device.NETWORK_TYPE_CHILD then
    create_child_devices(driver, device)
    device.thread:call_with_delay(2, function(d)
      do_configure(self, device)
    end)
  end
end

local function device_init(driver, device)
  if device.network_type == st_device.NETWORK_TYPE_CHILD then return end
  log.debug("parent device_init()")
  device:set_find_child(find_child)
end

local function device_info_changed(driver, device, event, args)
  if device.network_type == st_device.NETWORK_TYPE_CHILD then return end
  log.debug("parent device_info_changed()")
  if args.old_st_store.preferences.forceChild ~= device.preferences.forceChild then
    create_child_devices(driver, device)
    device.thread:call_with_delay(2, function(d)
      do_configure(self, device)
    end)
  end
end

--------------------------------------------------

local zigbee_switch_driver = {
  supported_capabilities = {
    capabilities.switch
  },
  zigbee_handlers = {
    global = {
      [zcl_clusters.OnOff.ID] = {
        [default_response.DefaultResponse.ID] = default_response_handler,
      }
    },
    cluster = {
      [CLUSTER_TUYA] = {
        [0x01] = tuya_cluster_handler,
        [0x02] = tuya_cluster_handler,
      }
    },
    attr = {
      [zcl_clusters.OnOff.ID] = {
        [zcl_clusters.OnOff.attributes.OnOff.ID] = on_off_attr_handler,
      }
    },
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on,
      [capabilities.switch.commands.off.NAME] = switch_off,
    },
  },
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    infoChanged = device_info_changed,
    doConfigure = do_configure
  },
}

local zigbee_driver = ZigbeeDriver("zigbee-multi-switch", zigbee_switch_driver)
zigbee_driver:run()