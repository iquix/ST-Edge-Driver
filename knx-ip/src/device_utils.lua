-- SmartThings Device Utilities for KNX-IP Driver
-- Provides child device key generation, type parsing, and caching

local socket = require "cosock.socket"

local device_utils = {
  DOMAIN = "knxIP",
}

--- Build profile name for a child device
--- @param device_type string Internal device type (e.g. "switch", "color_temp_bulb")
--- @return string profile_name e.g. "knxip-switch", "knxip-color-temp-bulb"
function device_utils.build_profile_name(device_type)
  return string.format("%s-%s", device_utils.DOMAIN:lower(), (device_type:gsub("_", "-")))
end

--- Build parent_assigned_child_key for a new child device
--- @param device_type string Internal device type (e.g. "switch", "fan_5speed")
--- @return string child_key e.g. "knxIP_switch_1719123456.789"
function device_utils.build_child_key(device_type)
  return string.format("%s_%s_%.3f", device_utils.DOMAIN, device_type, socket.gettime())
end

--- Get device type from parent_assigned_child_key and cache on device field
--- @param device table|nil ST device
--- @return string|nil device_type
function device_utils.get_device_type(device)
  if not device or not device.parent_assigned_child_key then return nil end
  local device_type = device:get_field("device_type")
  if not device_type then
    device_type = device.parent_assigned_child_key:match("^" .. device_utils.DOMAIN .. "_(.+)_[^_]+")
    device:set_field("device_type", device_type)
  end
  return device_type
end

--- Create a can_handle predicate for a specific device type
--- @param device_type string Internal device type (e.g. "switch", "button")
--- @return function can_handle predicate matching the device type
function device_utils.can_handle(device_type)
  return function(opts, driver, device, ...)
    return device_utils.get_device_type(device) == device_type
  end
end

return device_utils
