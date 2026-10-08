--- @module disco
--- Discovery module for KNX IP gateways.
--- Handles KNXnet/IP multicast discovery and SmartThings parent bridge creation.

local socket = require "cosock.socket"
local log = require "log"
local st_device = require "st.device"
local knxnet_ip = require "knx.knxnet_ip"
local KnxDiscovery = require "knx.discovery"

local FALLBACK_GATEWAY_DNI = "knxIP-fallback"
local FALLBACK_GATEWAY_LABEL = "KNX IP Interface"

local joined_devices = {} -- Track devices currently being joined to avoid duplicates
local disco = {}


------------------------------------------------------------------------
-- LOCAL HELPER FUNCTIONS
------------------------------------------------------------------------

-- Generate a unique DNI from discovered device record (MAC, serial, or host_port fallback)
local function generate_dni(record)
  if not record then return FALLBACK_GATEWAY_DNI end

  if record.mac then
    local mac = record.mac:gsub(":", ""):upper()
    if #mac == 12 and not mac:match("^0+$") then
      return string.format("knxIP-%s", mac)
    end
  end

  if record.serial_number then
    local serial = record.serial_number:upper()
    if #serial == 12 and not serial:match("^0+$") then
      return string.format("knxIP-%s", serial)
    end
  end

  local host, port = (record.addr or ""):match("^([^:]+):?(%d*)$")
  host = host or "0.0.0.0"
  if not port or port == "" then port = knxnet_ip.DEFAULT_PORT end
  return string.format("knxIP-%s_%s", host:gsub("%.", "_"), port)
end

-- Build device creation table for try_create_device
local function build_gateway_device_info(dni, label)
  local target_dni = dni or FALLBACK_GATEWAY_DNI
  local target_label = label or FALLBACK_GATEWAY_LABEL
  local brand = label and label:match("^(%S+)")
  return {
    type = "LAN",
    device_network_id = target_dni,
    label = target_label,
    profile = 'knxip-main',
    manufacturer = brand or "KNX",
    model = target_label,
    vendor_provided_label = target_label,
  }
end

-- Discover devices via multicast and map by DNI
local function scan_devices()
  local records = KnxDiscovery.discover({
    timeout = 2.0,
    log = log,
  })
  local found_devices = {}
  for _, record in ipairs(records) do
    if record.supported_services[knxnet_ip.SERVICE_FAMILY.TUNNELING] then
      local dni = generate_dni(record)
      found_devices[dni] = record
    else
      log.info(string.format("[Discovery] Ignoring device '%s' at %s: tunneling not supported", record.device_name or "unknown", record.addr or "unknown"))
    end
  end
  return found_devices
end

-- Cache device info and trigger gateway creation
local function try_add_gateway_device(driver, record)
  local dni = generate_dni(record)
  log.info(string.format("[Discovery] Caching and creating gateway device: dni=%s, addr=%s", dni, record.addr))

  driver.datastore.discovery_cache[dni] = {
    addr = record.addr,
    device_info = build_gateway_device_info(dni, record.device_name),
  }
  driver:try_create_device(driver.datastore.discovery_cache[dni].device_info)
end


------------------------------------------------------------------------
-- PUBLIC MODULE API
------------------------------------------------------------------------

--- Set device fields from discovery cache after device is added
--- @param driver Driver SmartThings Driver instance
--- @param device Device SmartThings Device instance
function disco.set_device_field(driver, device)
  log.info(string.format("[Discovery] set_device_field: dni=%s", device.device_network_id))
  local cache = driver.datastore.discovery_cache[device.device_network_id]

  if cache then
    device:set_field("discovered_addr", cache.addr, { persist = true })
    log.info(string.format("[Discovery] Device configured with discovered_addr: %s", cache.addr))
    driver.datastore.discovery_cache[device.device_network_id] = nil
  elseif device.device_network_id == FALLBACK_GATEWAY_DNI then
    log.info("[Discovery] Fallback device added; awaiting manual IP configuration in preferences")
  else
    log.warn(string.format("[Discovery] No cache found for device: %s", device.device_network_id))
  end
end

--- Called when parent bridge device is added
--- @param driver Driver SmartThings Driver instance
--- @param device Device SmartThings Device instance
function disco.device_added(driver, device)
  log.info(string.format("[Discovery] Gateway device added: %s (%s)", device.label, device.device_network_id))
  disco.set_device_field(driver, device)
  joined_devices[device.device_network_id] = nil
end

--- Check and update device discovered address via multicast discovery scan.
--- Does NOT restart tunnels or touch preferences; returns success flag and discovered address.
--- @param device Device SmartThings Device instance
--- @return boolean found Whether device was found on network
--- @return string|nil addr Discovered address string "ip:port"
function disco.update_device_addr(device)
  local dni = device.device_network_id
  local current_discovered_addr = device:get_field("discovered_addr")

  log.info(string.format("[Discovery] Checking IP for device: %s (current: %s)", dni, tostring(current_discovered_addr)))

  local found_devices = scan_devices()
  local record = found_devices[dni]

  if record then
    local new_addr = record.addr
    if current_discovered_addr ~= new_addr then
      log.info(string.format("[Discovery] Address changed for %s: %s -> %s", dni, tostring(current_discovered_addr), new_addr))
      device:set_field("discovered_addr", new_addr, { persist = true })
    end
    return true, new_addr
  else
    log.warn(string.format("[Discovery] Device not found on network: %s", dni))
    return false, nil
  end
end

--- SmartThings LAN discovery handler
--- Initiates multicast KNXnet/IP SEARCH_REQUEST loop and provisions new parent bridge devices.
--- Existing devices are never modified or restarted during discovery.
--- @param driver Driver SmartThings Driver instance
--- @param _ any Ignored
--- @param should_continue function Callable returning boolean
function disco.discovery_handler(driver, _, should_continue)
  log.info("Starting KNX IP interface discovery")

  local gateway_discovered = false
  local known_gateways = {}

  while should_continue() do
    -- Get list of already known gateway devices
    known_gateways = {}
    for _, device in ipairs(driver:get_devices()) do
      if device.network_type ~= st_device.NETWORK_TYPE_CHILD then
        known_gateways[device.device_network_id] = device
      end
    end

    local found_devices = scan_devices()

    for dni, record in pairs(found_devices) do
      gateway_discovered = true
      if not known_gateways[dni] and not joined_devices[dni] then
        try_add_gateway_device(driver, record)
        joined_devices[dni] = true
        log.info(string.format("[Discovery] Gateway device creation triggered for: %s (%s)", dni, record.addr))
      end
    end

    socket.sleep(0.5)
  end

  if not gateway_discovered and not next(known_gateways) and not joined_devices[FALLBACK_GATEWAY_DNI] then
    log.info("No KNX IP gateway discovered via multicast; creating fallback gateway device for manual IP configuration.")
    joined_devices[FALLBACK_GATEWAY_DNI] = true
    driver:try_create_device(build_gateway_device_info(FALLBACK_GATEWAY_DNI, FALLBACK_GATEWAY_LABEL))
  end

  log.info("Ending KNX IP interface discovery")
end

return disco
