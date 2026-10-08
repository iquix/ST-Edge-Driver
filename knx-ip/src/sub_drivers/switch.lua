local capabilities = require "st.capabilities"
local device_utils = require "device_utils"
local dpt = require "knx.dpt"

local function device_added(driver, device)
  device:emit_event(capabilities.switch.switch("off", {visibility = { displayed = false }, state_change = false}))
end

local function switch_handler(driver, device, knx_rx)
  local on_off = dpt.decode("1.001", knx_rx.data)
  device:emit_event(capabilities.switch.switch(on_off and "on" or "off"))
end

local switch = {
  NAME = "switch",
  can_handle = device_utils.can_handle("switch"),
  knx_handlers = {
    ["switch"] = switch_handler,
  },
  lifecycle_handlers = {
    added = device_added,
  },
}

return switch
