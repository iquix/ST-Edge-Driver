local capabilities = require "st.capabilities"
local device_utils = require "device_utils"
local dpt = require "knx.dpt"

local function device_added(driver, device)
  device:emit_event(capabilities.illuminanceMeasurement.illuminance(0, {visibility = { displayed = false }, state_change = false}))
end

local function brightness_handler(driver, device, knx_rx)
  local lux = dpt.decode("7.013", knx_rx.data)
  device:emit_event(capabilities.illuminanceMeasurement.illuminance(lux))
end

local illuminance = {
  NAME = "illuminance",
  can_handle = device_utils.can_handle("illuminance"),
  knx_handlers = {
    ["brightness"] = brightness_handler,
  },
  lifecycle_handlers = {
    added = device_added,
  },
}

return illuminance
