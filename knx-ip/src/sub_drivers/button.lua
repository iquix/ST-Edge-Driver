local capabilities = require "st.capabilities"
local device_utils = require "device_utils"
local knx_utils = require "knx.utils"
local telegram = require "knx.telegram"

local function device_added(driver, device)
  device:emit_event(capabilities.button.supportedButtonValues({"pushed", "held", "up_hold", "down_hold"}, {visibility = { displayed = false }}))
end

local function pressed_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.pressedPayload) == knx_rx.data.raw then
    device:emit_event(capabilities.button.button.pushed({state_change = true}))
  end
end

local function held_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.heldPayload) == knx_rx.data.raw then
    device:emit_event(capabilities.button.button.held({state_change = true}))
  end
end

local function hold_down_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.holdDownPayload) == knx_rx.data.raw then
    device:emit_event(capabilities.button.button.down_hold({state_change = true}))
  end
end

local function hold_up_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.holdUpPayload) == knx_rx.data.raw then
    device:emit_event(capabilities.button.button.up_hold({state_change = true}))
  end
end

local button = {
  NAME = "button",
  can_handle = device_utils.can_handle("button"),
  knx_handlers = {
    ["pressedAddr"]  = pressed_handler,
    ["heldAddr"]     = held_handler,
    ["holdDownAddr"] = hold_down_handler,
    ["holdUpAddr"]   = hold_up_handler,
  },
  lifecycle_handlers = {
    added = device_added,
  },
}

return button
