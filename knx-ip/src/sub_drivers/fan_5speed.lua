local capabilities = require "st.capabilities"
local device_utils = require "device_utils"
local stutils = require "st.utils"
local telegram = require "knx.telegram"
local KnxTelegramTx = telegram.KnxTelegramTx
local dpt = require "knx.dpt"
local log = require "log"

local function get_fan_max_speed(device)
  return device.preferences.fanMaxSpeed or 5
end

local function fan_speed_handler(driver, device, command)
  local max_speed = get_fan_max_speed(device)
  local speed = command.args.speed
  local raw_val = (((speed * 255 / max_speed) + 0.5) // 1) | 0
  local tx = KnxTelegramTx.write(device.preferences.cmdLevel, dpt.encode("5.010", raw_val))
  device:send(tx)
end

local function fan_speed_button_handler(driver, device, command)
  local max_level = get_fan_max_speed(device)
  local current_speed = device:get_latest_state("main", capabilities.fanSpeed.ID, capabilities.fanSpeed.fanSpeed.NAME) or 0
  local button = command.args.button
  local fan_step = (button == "fanspeedUp") and 1 or -1
  if fan_step > 0 and current_speed >= max_level then
    log.info("Fan speed already at max (" .. max_level .. "), ignoring step up command")
    return
  end
  if fan_step < 0 and current_speed <= 1 then
    log.info("Fan speed already at min (" .. current_speed .. "), ignoring step down command")
    return
  end
  local new_speed = stutils.clamp_value(current_speed + fan_step, 1, max_level)
  fan_speed_handler(driver, device, {args = {speed = new_speed}})
end

local function switch_level_step_handler(driver, device, command)
  local step = command.args.stepSize
  local max_level = get_fan_max_speed(device)
  local fan_step = math.ceil(math.abs(step) * max_level / 100.0)
  if step < 0 then fan_step = -fan_step end
  local current_speed = device:get_latest_state("main", capabilities.fanSpeed.ID, capabilities.fanSpeed.fanSpeed.NAME) or 0
  if fan_step > 0 and current_speed >= max_level then
    log.info("Fan speed already at max (" .. max_level .. "), ignoring step up command")
    return
  end
  if fan_step < 0 and current_speed <= 1 then
    log.info("Fan speed already at min (" .. current_speed .. "), ignoring step down command")
    return
  end
  local new_speed = stutils.clamp_value(current_speed + fan_step, 1, max_level)
  fan_speed_handler(driver, device, {args = {speed = new_speed}})
end

local function device_added(driver, device)
  device:emit_event(capabilities.switch.switch("off", {visibility = { displayed = false }, state_change = false}))
  device:emit_event(capabilities.fanSpeed.fanSpeed(0, {visibility = { displayed = false }, state_change = false}))
end

local function switch_handler(driver, device, knx_rx)
  local on_off = dpt.decode("1.001", knx_rx.data)
  device:emit_event(capabilities.switch.switch(on_off and "on" or "off"))
end

local function level_handler(driver, device, knx_rx)
  local raw_val = dpt.decode("5.010", knx_rx.data)
  local max_speed = get_fan_max_speed(device)
  local fan_speed = (((raw_val * max_speed / 255.0) + 0.5) // 1) | 0
  device:emit_event(capabilities.fanSpeed.fanSpeed(fan_speed))
end

local fan_5speed = {
  NAME = "fan_5speed",
  can_handle = device_utils.can_handle("fan_5speed"),
  knx_handlers = {
    ["switch"] = switch_handler,
    ["level"]  = level_handler,
  },
  capability_handlers = {
    [capabilities.fanSpeed.ID] = {
      [capabilities.fanSpeed.commands.setFanSpeed.NAME] = fan_speed_handler,
    },
    [capabilities.statelessFanspeedButton.ID] = {
      [capabilities.statelessFanspeedButton.commands.setButton.NAME] = fan_speed_button_handler,
    },
    [capabilities.statelessSwitchLevelStep.ID] = {
      [capabilities.statelessSwitchLevelStep.commands.stepLevel.NAME] = switch_level_step_handler,
    },
  },
  lifecycle_handlers = {
    added = device_added,
  },
}

return fan_5speed
