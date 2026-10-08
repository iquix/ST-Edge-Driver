local capabilities = require "st.capabilities"
local device_utils = require "device_utils"
local dpt = require "knx.dpt"

local function device_added(driver, device)
  device:emit_event(capabilities.switch.switch("off", {visibility = { displayed = false }, state_change = false}))
  device:emit_event(capabilities.switchLevel.level(100, {visibility = { displayed = false }, state_change = false}))
  device:emit_event(capabilities.colorTemperature.colorTemperature(4000, {visibility = { displayed = false }, state_change = false}))
end

local function switch_handler(driver, device, knx_rx)
  local on_off = dpt.decode("1.001", knx_rx.data)
  device:emit_event(capabilities.switch.switch(on_off and "on" or "off"))
end

local function level_handler(driver, device, knx_rx)
  local level = dpt.decode("5.001", knx_rx.data)
  device:emit_event(capabilities.switchLevel.level(level))
end

local function color_temperature_handler(driver, device, knx_rx)
  local kelvin = dpt.decode("7.600", knx_rx.data)
  device:emit_event(capabilities.colorTemperature.colorTemperature(kelvin))
end

local color_temp_bulb = {
  NAME = "color_temp_bulb",
  can_handle = device_utils.can_handle("color_temp_bulb"),
  knx_handlers = {
    ["switch"] = switch_handler,
    ["level"] = level_handler,
    ["colorTemperature"] = color_temperature_handler,
  },
  lifecycle_handlers = {
    added = device_added,
  },
}

return color_temp_bulb
