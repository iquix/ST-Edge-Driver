-- Tuya Window Shade ver 0.4.3
-- Copyright 2021-2022 Jaewon Park (iquix) / SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local zcl_messages = require "st.zigbee.zcl"
local messages = require "st.zigbee.messages"
local data_types = require "st.zigbee.data_types"
local zb_const = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"
local window_preset_defaults = require "st.zigbee.defaults.windowShadePreset_defaults"
local _log = require "log"


---------- Constant Definitions ----------


local CLUSTER_TUYA = 0xEF00
local SET_DATA = 0x00
local DP_TYPE_VALUE = "\x02"
local DP_TYPE_ENUM = "\x04"

local packet_id = 0
local MOVING = "moving"
local LEVEL_CMD_VAL = "levelCmdVal"


---------- send Tuya Command Function ----------


local function send_tuya_command(device, dp, dp_type, fncmd) 
  local header_args = {
    cmd = data_types.ZCLCommandId(SET_DATA)
  }
  local zclh = zcl_messages.ZclHeader(header_args)
  zclh.frame_ctrl:set_cluster_specific()
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(CLUSTER_TUYA),
    zb_const.HA_PROFILE_ID,
    CLUSTER_TUYA
  )
  packet_id = (packet_id + 1) % 65536
  local fncmd_len = string.len(fncmd)
  local payload_body = generic_body.GenericBody(string.pack(">I2", packet_id) .. dp .. dp_type .. string.pack(">I2", fncmd_len) .. fncmd)
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = payload_body
  })
  local send_message = messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body
  })
  device:send(send_message)
end


---------- Product Category Functions ----------


local function product_id(device)
  return string.sub(device:get_manufacturer(), -7)
end

local function is_old_zemi_curtain(device)
  return product_id(device) == "owvfni3"
end

local function is_zemi_blind(device)
  local p = product_id(device)
  return (p == "mcdj3aq" or p == "zo2pocs" or p == "eue9vhc")
end

local function is_dp2_position_devices(device)
  local p = product_id(device)
  return (p == "ueqqe6k" or p == "sbebbzs" or p == "uzcvlku" or p == "xxfv8wi")
end

local function support_dp1_state(device)
  local p = product_id(device)
  return (p == "qcqqjpb" or p == "aabybja" or p == "mymn92d")
end

local function does_report_start_pos(device)
  local p = product_id(device)
  return (p == "f1sl3tj" or p == "mymn92d")
end


---------- Device Specific Level/Direction Functions ----------


local function level_val(device, level)
  local ret
  local prod = product_id(device)
  if prod=="ogaemzt" then
    ret = (level == level%256) and level or 100-(level%256)
  else
    local fixpercent_devices = {["owvfni3"]=true, ["zbp6j0u"]=true, ["pzndjez"]=true, ["qcqqjpb"]=true, ["ueqqe6k"]=true, ["sbebbzs"]=true, ["uzcvlku"]=true, ["aabybja"]=true, ["mymn92d"]=true, ["0jdjrvi"]=true}
    ret = fixpercent_devices[prod] and 100-level or level
  end
  return device.preferences.fixPercent and 100-ret or ret
end

local function direction_val(device, c)
  return (is_zemi_blind(device) and device.preferences.reverse~=true) and 1-c or c
end


---------- Level Event Functions ----------


local function get_current_level(device)
  return device:get_latest_state("main", capabilities.windowShadeLevel.ID, capabilities.windowShadeLevel.shadeLevel.NAME)
end

local function level_event_moving(device, level)
  local current_level = get_current_level(device)
  if current_level == nil or current_level == level then
    _log.info("Ignore invalid reports")
  else
    if current_level < level then
      device:emit_event(capabilities.windowShade.windowShade.opening())
      return true
    elseif (current_level > level) then
      device:emit_event(capabilities.windowShade.windowShade.closing())
      return true
    end
  end
  return false
end

local function level_event_arrived(device, level) 
  local window_shade_val
  local moving = device:get_field(MOVING)
  if type(level) ~= "number" then
    window_shade_val = "unknown"
    level = 50
  elseif level == 0 then
    window_shade_val = "closed"
  elseif level == 100 then 
    window_shade_val = "open"
  elseif level > 0 and level < 100 then
    window_shade_val = "partially open"
  else
    window_shade_val = "unknown"
    level = 50
  end
  device:emit_event(capabilities.windowShadeLevel.shadeLevel(level))
  device:emit_event(capabilities.switchLevel.level(level))
  if support_dp1_state(device) and moving then
    return
  elseif does_report_start_pos(device) and moving then
    device:set_field(MOVING, false)
  else
    device:emit_event(capabilities.windowShade.windowShade(window_shade_val))
  end
end

local function set_event(device)
  level_event_arrived(device, get_current_level(device))
end


---------- Command Handlers ----------


local function tuya_cluster_handler(driver, device, zb_rx)
  local rx = zb_rx.body.zcl_body.body_bytes
  local dp = string.byte(rx:sub(3,3))
  local fncmd_len = string.unpack(">I2", rx:sub(5,6))
  local fncmd = string.unpack(">I"..fncmd_len, rx:sub(7))
  _log.debug(string.format("dp=%d, fncmd=%d", dp, fncmd))
  if dp == 1 then -- 0x01: Control -- Opening/closing/stopped
    if fncmd == 1 then
      device:set_field(MOVING, false)
    elseif fncmd == 0 or fncmd == 2 then
      device:set_field(MOVING, level_event_moving(device, fncmd == 0 and 100 or 0))
    end
  elseif dp == 2 then -- 0x02: Percent control -- Started moving to position (triggered from Zigbee)
    if (not is_dp2_position_devices(device)) then
      local pos = level_val(device, fncmd)
      device:set_field(LEVEL_CMD_VAL, pos)
      level_event_moving(device, pos)
    else
      level_event_arrived(device, level_val(device, fncmd))
    end
  elseif dp == 3 then -- 0x03: Percent state -- Arrived at position
    level_event_arrived(device, level_val(device, fncmd))
  elseif dp == 5 then -- 0x05: Direction state
    _log.info("direction state of the motor is "..(fncmd and "reverse" or "forward"))
  elseif dp == 6 then -- 0x06: Arrived at destination (with fncmd==0)
    local level_cmd_val = device:get_field(LEVEL_CMD_VAL)
    if fncmd == 0 and level_cmd_val ~=nil then
      level_event_arrived(device, level_cmd_val)
      device:set_field(LEVEL_CMD_VAL, nil)
    end
  elseif dp == 7 then -- 0x07: Work state -- Started moving (triggered by RF remote or pulling the curtain)
    if is_old_zemi_curtain(device) then
      local current_level = get_current_level(device)
      if current_level == 0 then
        device:emit_event(capabilities.windowShade.windowShade.opening())
      elseif current_level == 100 then
        device:emit_event(capabilities.windowShade.windowShade.closing())
      end
    elseif support_dp1_state(device) then
      return
    else
      if direction_val(device, fncmd) == 0 then
        level_event_moving(device, 100)
      elseif direction_val(device, fncmd) == 1 then
        level_event_moving(device, 0)
      end
    end
  end
end

local function window_shade_open_handler(driver, device)
  local current_level = get_current_level(device)
  if current_level == 100 then
    device:emit_event(capabilities.windowShade.windowShade.open())
  end
  send_tuya_command(device, "\x01", DP_TYPE_ENUM, "\x00")
end

local function window_shade_close_handler(driver, device)
  local current_level = get_current_level(device)
  if current_level == 0 then
    device:emit_event(capabilities.windowShade.windowShade.closed())
  end
  send_tuya_command(device, "\x01", DP_TYPE_ENUM, "\x02")
end

local function window_shade_pause_handler(driver, device)
  local window_shade_val = device:get_latest_state("main", capabilities.windowShade.ID, capabilities.windowShade.windowShade.NAME)
  device:emit_event(capabilities.windowShade.windowShade(window_shade_val))
  send_tuya_command(device, "\x01", DP_TYPE_ENUM, "\x01")
end

local function window_shade_level_set_shade_level_handler(driver, device, command)
  local current_level = get_current_level(device)
  if current_level == command.args.shadeLevel then
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(current_level))
    device:emit_event(capabilities.switchLevel.level(current_level))
  end
  if current_level ~= nil then
    device.thread:call_with_delay(10, function(d)
      set_event(device) -- to prevent showing 'network error' in SmartThings app
    end)
  end
  send_tuya_command(device, "\x02", DP_TYPE_VALUE, string.pack(">I4", level_val(device, command.args.shadeLevel)))
end

local function switch_level_set_level_handler(driver, device, command)
  window_shade_level_set_shade_level_handler(driver, device, {args = { shadeLevel = command.args.level }})
end

local function window_shade_preset_preset_position_handler(driver, device)
  local level = device.preferences.presetPosition or device:get_field(window_preset_defaults.PRESET_LEVEL_KEY) or window_preset_defaults.PRESET_LEVEL
  window_shade_level_set_shade_level_handler(driver, device, {args = { shadeLevel = level }})
end


---------- Lifecycle Handlers ----------


local function device_added(driver, device)
  device:emit_event(capabilities.windowShade.supportedWindowShadeCommands({"open", "close", "pause"}))
  if get_current_level(device) == nil then
    set_event(device)
    device.thread:call_with_delay(3, function(d)
      window_shade_level_set_shade_level_handler(driver, device, {args = { shadeLevel = 50 }}) -- move to 50% position
    end)
  end
end

local function device_info_changed(driver, device, event, args)
  if args.old_st_store.preferences.reverse ~= device.preferences.reverse then
    send_tuya_command(device, "\x05", DP_TYPE_ENUM, device.preferences.reverse and "\x01" or "\x00")
  end
  if (args.old_st_store.preferences.reverse ~= device.preferences.reverse) ~= (args.old_st_store.preferences.fixPercent ~= device.preferences.fixPercent) then
    level_event_arrived(device, 100-get_current_level(device))
  end
end


---------- Driver Main ----------


local tuya_window_shade_driver = {
  supported_capabilities = {
    capabilities.windowShade,
    capabilities.windowShadePreset,
    capabilities.windowShadeLevel,
    capabilities.switchLevel
  },
  zigbee_handlers = {
    cluster = {
      [CLUSTER_TUYA] = {
        [0x01] = tuya_cluster_handler,
        [0x02] = tuya_cluster_handler
      }
    }
  },
  capability_handlers = {
    [capabilities.windowShade.ID] = {
      [capabilities.windowShade.commands.open.NAME] = window_shade_open_handler,
      [capabilities.windowShade.commands.close.NAME] = window_shade_close_handler,
      [capabilities.windowShade.commands.pause.NAME] = window_shade_pause_handler
    },
    [capabilities.windowShadePreset.ID] = {
      [capabilities.windowShadePreset.commands.presetPosition.NAME] = window_shade_preset_preset_position_handler
    },
    [capabilities.windowShadeLevel.ID] = {
      [capabilities.windowShadeLevel.commands.setShadeLevel.NAME] = window_shade_level_set_shade_level_handler
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = switch_level_set_level_handler
    }
  },
  lifecycle_handlers = {
    added = device_added,
    infoChanged = device_info_changed
  }
}

local zigbee_driver = ZigbeeDriver("tuya-window-shade", tuya_window_shade_driver)
zigbee_driver:run()