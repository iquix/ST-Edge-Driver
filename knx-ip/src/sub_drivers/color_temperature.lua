local capabilities = require "st.capabilities"
local device_utils = require "device_utils"
local dpt = require "knx.dpt"

local function device_added(driver, device)
  device:emit_event(capabilities.colorTemperature.colorTemperature(1, {visibility = { displayed = false }, state_change = false}))
end

local function color_temperature_handler(driver, device, knx_rx)
  local kelvin = dpt.decode("7.600", knx_rx.data)
  device:emit_event(capabilities.colorTemperature.colorTemperature(kelvin, {state_change = true}))
end

local color_temperature = {
  NAME = "color_temperature",
  can_handle = device_utils.can_handle("color_temperature"),
  knx_handlers = {
    ["colorTemperature"] = color_temperature_handler,
  },
  lifecycle_handlers = {
    added = device_added,
  },
}

return color_temperature
