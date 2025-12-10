-- Tuya Window Shade ver 0.6.2
-- Copyright 2021-2025 Jaewon Park (iquix) / SmartThings
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
local read_attribute = require "st.zigbee.zcl.global_commands.read_attribute"
local device_management = require "st.zigbee.device_management"
local clusters = require "st.zigbee.zcl.clusters"
local Basic = clusters.Basic
local window_preset_defaults = require "st.zigbee.defaults.windowShadePreset_defaults"
local log = require "log"


---------- Constant Definitions ----------


local CLUSTER_TUYA = {
  ID = 0xEF00,
  commands = {
    TY_DATA_REQUEST = 0x00,
    TY_DATA_RESPONSE = 0x01,
    TY_DATA_REPORT = 0x02,
    TY_DATA_QUERY = 0x03
  }
}
local DP_TYPE_VALUE = "\x02"
local DP_TYPE_ENUM = "\x04"

local packet_id = 0
local MOVING = "moving"
local LEVEL_CMD_VAL = "levelCmdVal"
local PARAMS = "params"


---------- Tuya Packet Functions ----------


local function send_tuya_command(device, dp, dp_type, fncmd) 
  local header_args = {
    cmd = data_types.ZCLCommandId(CLUSTER_TUYA.commands.TY_DATA_REQUEST)
  }
  local zclh = zcl_messages.ZclHeader(header_args)
  zclh.frame_ctrl:set_cluster_specific()
  zclh.frame_ctrl:set_disable_default_response()
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(CLUSTER_TUYA.ID),
    zb_const.HA_PROFILE_ID,
    CLUSTER_TUYA.ID
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

local function configure_tuya_magic_packet(device)
  local zclh = zcl_messages.ZclHeader({cmd = data_types.ZCLCommandId(read_attribute.ReadAttribute.ID)})
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(Basic.ID),
    zb_const.HA_PROFILE_ID,
    Basic.ID
  )
  local payload_body = read_attribute.ReadAttribute( {0x0004, 0x0000, 0x0001, 0x0005, 0x0007,0xFFFE} )
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


---------- Advanced Parameters Functions ----------


local function parse_params(device)
  local params = {}
  local s = device.preferences.advancedParams
  if s ~= nil then
    s = s:lower():gsub("%s", "")
    for k, v in string.gmatch(s, "([^,=?]+)=([^,=?]+)") do  -- comma separated
      if v == "true" then
        v = true
      elseif v == "false" then
        v = false
      elseif tonumber(v) ~= nil then
        v = tonumber(v)
      end
      params[k] = v
    end
  end
  device:set_field(PARAMS, params)
end

local function get_params(device)
  local params = device:get_field(PARAMS)
  return (params == nil) and {} or params
end


---------- Product Category Functions ----------


local unusual_models_list = {"ueqqe6k", "qcqqjpb", "f1sl3tj", "mymn92d", "owvfni3", "mcdj3aq"}

local function product_id(device)
  local model = get_params(device).model
  if model == nil or unusual_models_list[model] == nil then
    return string.sub(device:get_manufacturer(), -7)
  else
    return unusual_models_list[model]
  end
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
    log.info("Ignore invalid reports")
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


---------- Zigbee Handlers ----------


local function tuya_cluster_handler(driver, device, zb_rx)
  local rx = zb_rx.body.zcl_body.body_bytes
  local dp = string.byte(rx:sub(3,3))
  local fncmd_len = string.unpack(">I2", rx:sub(5,6))
  local fncmd = string.unpack(">I"..fncmd_len, rx:sub(7))
  log.debug(string.format("dp=%d, fncmd=%d", dp, fncmd))
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
    log.info("direction state of the motor is "..(fncmd and "reverse" or "forward"))
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

local function basic_power_source_handler(driver, device, value, zb_rx)
  if value.value == Basic.attributes.PowerSource.SINGLE_PHASE_MAINS then    -- only make periodic reporting for mains powered devices to prevent battery drain
    -- configure ApplicationVersion to keep device online
    device:send(Basic.attributes.ApplicationVersion:configure_reporting(device, 30, 300, 1))
  end
end


---------- Command Handlers ----------


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
  local params = get_params(device)
  if current_level == command.args.shadeLevel then
    device:emit_event(capabilities.windowShadeLevel.shadeLevel(current_level))
    device:emit_event(capabilities.switchLevel.level(current_level))
  end
  if current_level ~= nil then
    device.thread:call_with_delay(10, function(d)
      set_event(device) -- to prevent showing 'network error' in SmartThings app
    end)
  end
  if command.args.shadeLevel == 0 and params.replace_setlevel_0_with_close == true then
    log.debug("sending close command instead of set level 0 command")
    send_tuya_command(device, "\x01", DP_TYPE_ENUM, "\x02")
  elseif command.args.shadeLevel == 100 and params.replace_setlevel_100_with_open == true then
    log.debug("sending open command instead of set level 100 command")
    send_tuya_command(device, "\x01", DP_TYPE_ENUM, "\x00")
  else
    send_tuya_command(device, "\x02", DP_TYPE_VALUE, string.pack(">I4", level_val(device, command.args.shadeLevel)))
  end
end

local function switch_level_set_level_handler(driver, device, command)
  window_shade_level_set_shade_level_handler(driver, device, {args = { shadeLevel = command.args.level }})
end

local function window_shade_preset_preset_position_handler(driver, device)
  local level = device.preferences.presetPosition or device:get_field(window_preset_defaults.PRESET_LEVEL_KEY) or window_preset_defaults.PRESET_LEVEL
  window_shade_level_set_shade_level_handler(driver, device, {args = { shadeLevel = level }})
end


---------- Lifecycle Handlers ----------


local function do_configure(driver, device)
  device:send(device_management.build_bind_request(device, Basic.ID, driver.environment_info.hub_zigbee_eui))
  configure_tuya_magic_packet(device)
end

local function device_added(driver, device)
  device:emit_event(capabilities.windowShade.supportedWindowShadeCommands({"open", "close", "pause"}, {visibility = {displayed = false}}))
  if get_current_level(device) == nil then
    set_event(device)
    device.thread:call_with_delay(3, function(d)
      window_shade_level_set_shade_level_handler(driver, device, {args = { shadeLevel = 50 }}) -- move to 50% position
    end)
  end
  do_configure(driver, device)
end

local function device_init(driver, device)
  parse_params(device)
end

local function device_info_changed(driver, device, event, args)
  if args.old_st_store.preferences.advancedParams ~= device.preferences.advancedParams then
    parse_params(device)
  end
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
      [CLUSTER_TUYA.ID] = {
        [CLUSTER_TUYA.commands.TY_DATA_RESPONSE] = tuya_cluster_handler,
        [CLUSTER_TUYA.commands.TY_DATA_REPORT] = tuya_cluster_handler
      }
    },
    attr = {
      [Basic.ID] = {
        [Basic.attributes.PowerSource.ID] = basic_power_source_handler
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
    init = device_init,
    infoChanged = device_info_changed,
    doConfigure = do_configure
  },
  health_check = false
}

local zigbee_driver = ZigbeeDriver("tuya-window-shade", tuya_window_shade_driver)
zigbee_driver:run()