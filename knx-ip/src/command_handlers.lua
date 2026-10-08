-- SmartThings - KNX IP Interface Connector
-- Copyright © 2025-2026 iquix
-- Licensed under the Apache License, Version 2.0

-- SmartThings Edge Platform libraries
local capabilities = require "st.capabilities"
local stutils = require "st.utils"

-- KNX Protocol Subsystem
local dpt = require "knx.dpt"
local telegram = require "knx.telegram"
local KnxTelegramTx = telegram.KnxTelegramTx

local command_handlers = {}

--- Capability command handler: switch.on / switch.off
--- @param driver Driver SmartThings Driver instance
--- @param device Device SmartThings Device instance
--- @param command table Capability command table
function command_handlers.switch_handler(driver, device, command)
  local knx_data = dpt.encode("1.001", command.command == "on")
  local tx = KnxTelegramTx.write(device.preferences.cmdSwitch, knx_data)
  device:send(tx)
end

--- Capability command handler: switchLevel.setLevel
--- @param driver Driver SmartThings Driver instance
--- @param device Device SmartThings Device instance
--- @param command table Capability command table
function command_handlers.switch_level_handler(driver, device, command)
  local knx_data = dpt.encode("5.001", command.args.level)
  local tx = KnxTelegramTx.write(device.preferences.cmdLevel, knx_data)
  device:send(tx)
end

--- Capability command handler: statelessSwitchLevelStep.stepLevel
--- @param driver Driver SmartThings Driver instance
--- @param device Device SmartThings Device instance
--- @param command table Capability command table
function command_handlers.switch_level_step_handler(driver, device, command)
  local level = stutils.clamp_value((device:get_latest_state("main", capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME) or 0) + command.args.stepSize, 0, 100)
  device:emit_event(capabilities.switchLevel.level((((level + 0.5) // 1) | 0)))
  command_handlers.switch_level_handler(driver, device, { args = { level = level } })
end

--- Capability command handler: colorTemperature.setColorTemperature
--- @param driver Driver SmartThings Driver instance
--- @param device Device SmartThings Device instance
--- @param command table Capability command table
function command_handlers.color_temperature_handler(driver, device, command)
  local knx_data = dpt.encode("7.600", command.args.temperature)
  local tx = KnxTelegramTx.write(device.preferences.cmdColorTemperature, knx_data)
  device:send(tx)
end

--- Capability command handler: iquix.knxtelegram.send
--- @param driver Driver SmartThings Driver instance
--- @param device Device SmartThings Device instance
--- @param command table Capability command table
function command_handlers.send_knx_telegram_handler(driver, device, command)
  local dst = command.args.destination
  local payload = command.args.payload
  local data_type = command.args.dataType

  if dst == "" then
    device.log.warn_with({ hub_logs = true }, "Cannot send KNX telegram: destination group address is empty")
    return
  end

  local knx_data = dpt.encode_from_string(data_type, payload)
  local tx = KnxTelegramTx.write(dst, knx_data)
  device:send(tx)
end

return command_handlers
