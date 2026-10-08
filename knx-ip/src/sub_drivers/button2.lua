local capabilities = require "st.capabilities"
local device_utils = require "device_utils"
local knx_utils = require "knx.utils"
local telegram = require "knx.telegram"

local function device_added(driver, device)
  device.profile.components.button1:emit_event(capabilities.button.supportedButtonValues({"pushed", "held", "up_hold", "down_hold"}, {visibility = { displayed = false }}))
  device.profile.components.button2:emit_event(capabilities.button.supportedButtonValues({"pushed", "held", "up_hold", "down_hold"}, {visibility = { displayed = false }}))
end

local function pressed1_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.pressedPayload1) == knx_rx.data.raw then
    device.profile.components.button1:emit_event(capabilities.button.button.pushed({state_change = true}))
  end
end

local function held1_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.heldPayload1) == knx_rx.data.raw then
    device.profile.components.button1:emit_event(capabilities.button.button.held({state_change = true}))
  end
end

local function hold_down1_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.holdDownPayload1) == knx_rx.data.raw then
    device.profile.components.button1:emit_event(capabilities.button.button.down_hold({state_change = true}))
  end
end

local function hold_up1_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.holdUpPayload1) == knx_rx.data.raw then
    device.profile.components.button1:emit_event(capabilities.button.button.up_hold({state_change = true}))
  end
end

local function pressed2_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.pressedPayload2) == knx_rx.data.raw then
    device.profile.components.button2:emit_event(capabilities.button.button.pushed({state_change = true}))
  end
end

local function held2_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.heldPayload2) == knx_rx.data.raw then
    device.profile.components.button2:emit_event(capabilities.button.button.held({state_change = true}))
  end
end

local function hold_down2_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.holdDownPayload2) == knx_rx.data.raw then
    device.profile.components.button2:emit_event(capabilities.button.button.down_hold({state_change = true}))
  end
end

local function hold_up2_handler(driver, device, knx_rx)
  if knx_rx.apci == telegram.APCI.GROUP_VALUE_WRITE and knx_utils.hex_to_bytes(device.preferences.holdUpPayload2) == knx_rx.data.raw then
    device.profile.components.button2:emit_event(capabilities.button.button.up_hold({state_change = true}))
  end
end

local button2 = {
  NAME = "button2",
  can_handle = device_utils.can_handle("button2"),
  knx_handlers = {
    ["pressedAddr1"]  = pressed1_handler,
    ["heldAddr1"]     = held1_handler,
    ["holdDownAddr1"] = hold_down1_handler,
    ["holdUpAddr1"]   = hold_up1_handler,
    ["pressedAddr2"]  = pressed2_handler,
    ["heldAddr2"]     = held2_handler,
    ["holdDownAddr2"] = hold_down2_handler,
    ["holdUpAddr2"]   = hold_up2_handler,
  },
  lifecycle_handlers = {
    added = device_added,
  },
}

return button2
