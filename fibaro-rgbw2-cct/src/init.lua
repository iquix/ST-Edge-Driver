-- Copyright 2022 iquix
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

local st_device = require "st.device"
local capabilities = require "st.capabilities"
local utils = require "st.utils"

--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"
--- @type st.zwave.defaults
local defaults = require "st.zwave.defaults"

--- @type st.zwave.constants
local constants = require "st.zwave.constants"
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version=1 })
--- @type st.zwave.CommandClass.SwitchMultilevel
local SwitchMultilevel = (require "st.zwave.CommandClass.SwitchMultilevel")({ version=3 })
--- @type st.zwave.CommandClass.SwitchColor
local SwitchColor = (require "st.zwave.CommandClass.SwitchColor")({ version=3 })
--- @type st.zwave.CommandClass.CentralScene
local CentralScene = (require "st.zwave.CommandClass.CentralScene")({ version=3 })

local paramsMap = require "params"
local log = require "log"

------------------------------------------------------
-- driver specific constants
------------------------------------------------------

local MIN_CT = 2700
local MAX_CT = 6500
local LIGHT2_COMPONENT = "light2"
local LIGHT3_COMPONENT = "light3"
local LIGHT4_COMPONENT = "light4"

------------------------------------------------------

local function send_event(device, comp, evt)
  log.debug("send_event() to component "..comp)
  
  local parent = (device.network_type ~= st_device.NETWORK_TYPE_CHILD) and device or device:get_parent_device()
  local child = (device.network_type == st_device.NETWORK_TYPE_CHILD) and device or device:get_child_by_parent_assigned_key(comp)
  
  if comp == "main" then
    parent:emit_event(evt)
  else
    if parent:component_exists(comp) then
      parent:emit_component_event(parent.profile.components[comp], evt)
    end
    if child then
      child:emit_event(evt)
    end
  end
end

local function component_to_channel(device, comp)
  -- R:ch1 / G:ch2 / B:ch3 / W:ch4
  if comp == "main" then 
    -- main : return first enabled light channel
    if device.preferences.lightMode1 ~= 'disabled' then
      return 1
    elseif device.preferences.lightMode2 ~= 'disabled' then
      return 2
    elseif device.preferences.lightMode3 ~= 'disabled' then
      return 3
    elseif device.preferences.lightMode4 ~= 'disabled' then
      return 4
    end
  else
    if comp == LIGHT2_COMPONENT then
      return 2
    elseif comp == LIGHT3_COMPONENT then
      return 3
    elseif comp == LIGHT4_COMPONENT then
      return 4
    end
  end
  return 0
end

local function channel_to_component(device, channel)
  -- R:ch1 / G:ch2 / B:ch3 / W:ch4
  -- return "main" if it is first enabled light channel, otherwise return LIGHTn_COMPONENT
  if channel == 1 then
    return "main"
  elseif channel == 2 then
    return (device.preferences.lightMode1 == 'disabled') and "main" or LIGHT2_COMPONENT
  elseif channel == 3 then
    return (device.preferences.lightMode1 == 'disabled' and device.preferences.lightMode2 == 'disabled') and "main" or LIGHT3_COMPONENT
  elseif channel == 4 then
    return (device.preferences.lightMode1 == 'disabled' and device.preferences.lightMode2 == 'disabled' and device.preferences.lightMode3 == 'disabled') and "main" or LIGHT4_COMPONENT
  end
end

------------------------------------------------------

local function get_state(device, comp, capa, attr, fail_default_value)
  local parent = (device.network_type ~= st_device.NETWORK_TYPE_CHILD) and device or device:get_parent_device()
  local ret
  if parent:component_exists(comp) then
    ret = parent:get_latest_state(comp, capa, attr)
  else
    local comp_child = parent:get_child_by_parent_assigned_key(comp)
    if comp_child then
      ret = comp_child:get_latest_state("main", capa, attr)
    end
  end
  return ret == nil and fail_default_value or ret
end

local function build_rgbw_level(device, level1, level2, level3, level4, cct1, cct3)
  local ret = { r=0, g=0, b=0, w=0, level=99 }

  if level1 == nil then
    local comp = channel_to_component(device, 1)
    level1 = get_state(device, comp, capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "on" and 0 or get_state(device, comp, capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME, 0)
  end
  if level2 == nil then
    local comp = channel_to_component(device, 2)
    level2 = get_state(device, comp, capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "on" and 0 or get_state(device, comp, capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME, 0)
  end
  if level3 == nil then
    local comp = channel_to_component(device, 3)
    level3 = get_state(device, comp, capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "on" and 0 or get_state(device, comp, capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME, 0)
  end
  if level4 == nil then
    local comp = channel_to_component(device, 4)
    level4 = get_state(device, comp, capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "on" and 0 or get_state(device, comp, capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME, 0)
  end
  if cct1 == nil then
    local comp = channel_to_component(device, 1)
    cct1 = get_state(device, comp, capabilities.colorTemperature.ID, capabilities.colorTemperature.colorTemperature.NAME, 0)
  end
  if cct3 == nil then
    local comp = channel_to_component(device, 3)
    cct3 = get_state(device, comp, capabilities.colorTemperature.ID, capabilities.colorTemperature.colorTemperature.NAME, 0)
  end
  
  local level1_frac = utils.clamp_value(level1/100, 0, 1)
  local level2_frac = utils.clamp_value(level2/100, 0, 1)
  local level3_frac = utils.clamp_value(level3/100, 0, 1)
  local level4_frac = utils.clamp_value(level4/100, 0, 1)
  local cct1_frac = utils.clamp_value((cct1 - MIN_CT) / (MAX_CT - MIN_CT), 0, 1)
  local cct3_frac = utils.clamp_value((cct3 - MIN_CT) / (MAX_CT - MIN_CT), 0, 1)
  
  
  if device.preferences.lightMode1 == "builtin_level" then
    ret.r = utils.round(255 * (1 - cct1_frac)) -- ww
    ret.g = utils.round(255 * cct1_frac)       -- cw
    ret.level = utils.round(level1)
    ret.level = ret.level == 100 and 99 or ret.level
  elseif device.preferences.lightMode1 == 'cw_ww' then
    ret.r = utils.round(255 * (1 - cct1_frac) * level1_frac) -- ww
    ret.g = utils.round(255 * cct1_frac * level1_frac)       -- cw
  elseif device.preferences.lightMode1 == 'level_cct' then
    ret.r = utils.round(255 * level1_frac) -- level
    ret.g = utils.round(255 * cct1_frac)   -- cct
  elseif device.preferences.lightMode1 == 'dimmer' then
    ret.r = utils.round(255 * level1_frac) -- level
  end
  
  if device.preferences.lightMode2 == 'dimmer' then
    ret.g = utils.round(255 * level2_frac) -- level
  end
  
  if device.preferences.lightMode3 ~= 'cw_ww' then
    ret.b = utils.round(255 * (1 - cct3_frac) * level3_frac) -- ww
    ret.w = utils.round(255 * cct3_frac * level3_frac)       -- cw
  elseif device.preferences.lightMode3 ~= 'level_cct' then
    ret.b = utils.round(255 * level3_frac)  -- level
    ret.w = utils.round(255 * cct3_frac)    -- cct
  elseif device.preferences.lightMode3 == 'dimmer' then
    ret.b = utils.round(255 * level3_frac) -- level
  end
  
  if device.preferences.lightMode4 == 'dimmer' then
    ret.w = utils.round(255 * level4_frac) -- level
  end
  
  if ret.r == 0 and ret.g == 0 and ret.b == 0 and ret.w == 0 and ret.level == 99 then
    ret.level = 0
  end

  return ret
end

local function send_rgbw_level(device, level1, level2, level3, level4, cct1, cct3)
  local val = build_rgbw_level(device, level1, level2, level3, level4, cct1, cct3)
  device:send(SwitchMultilevel:Set({value = val.level}))
  device:send(SwitchColor:Set({
    color_components = {
      { color_component_id=SwitchColor.color_component_id.RED, value=val.r },
      { color_component_id=SwitchColor.color_component_id.GREEN, value=val.g },
      { color_component_id=SwitchColor.color_component_id.BLUE, value=val.b },
      { color_component_id=SwitchColor.color_component_id.WARM_WHITE, value=val.w },
    }, 
    duration = tonumber(device.preferences.transitionTime)
  }))
end

------------------------------------------------------

local function switch_multilevel_report_handler(self, device, cmd)
  log.debug("switch_multilevel_report_handler()")
  if device.preferences.lightMode1 ~= "builtin_level" then return end  -- ignore switch_multilevel_report unless using "builtin_level" mode
  
  local value = cmd.args.target_value and cmd.args.target_value or cmd.args.value
  
  if value == SwitchMultilevel.value.OFF_DISABLE then
    device:emit_event(capabilities.switch.switch.off())
  else
    device:emit_event(capabilities.switch.switch.on())
    device:emit_event(capabilities.switchLevel.level(value >= 99 and 100 or value))
  end
end


local function switch_color_report_handler(driver, device, cmd)
  log.debug("switch_color_report_handler()")
  -- do nothing, optimistic state
end


local function scene_notification_handler(driver, device, cmd)
  log.debug("scene_notification_handler()")
  local value = cmd.args.key_attributes
  local comp = (cmd.args.scene_number ~= nil) and "button"..cmd.args.scene_number or "button"
  
  if value == CentralScene.key_attributes.KEY_PRESSED_1_TIME then
    send_event(device, comp, capabilities.button.button.pushed({ state_change = true }))
  elseif value == CentralScene.key_attributes.KEY_HELD_DOWN then
    send_event(device, comp, capabilities.button.button.held({ state_change = true }))
  elseif value == CentralScene.key_attributes.KEY_PRESSED_2_TIMES then
    send_event(device, comp, capabilities.button.button.double({ state_change = true }))
  end
end


------------------------------------------------------


local function set_switch_on_off(driver, device, cmd)
  local comp
  if (device.network_type == st_device.NETWORK_TYPE_CHILD) then
    comp = device.parent_assigned_child_key
    device = device:get_parent_device()
  else
    comp = cmd.component
  end
  
  log.debug("set_switch_on_off("..cmd.command.."): "..comp..", lightMode1: "..device.preferences.lightMode1..", lightMode2: "..device.preferences.lightMode2)
  local channel = component_to_channel(device, comp)
  log.debug("component_to_channel() returned "..channel)
  
  if channel == 1 then
    if device.preferences.lightMode1 == 'builtin_level' then
      -- when using built-in on/off and level
      local dimmingDuration = cmd.args.rate or constants.DEFAULT_DIMMING_DURATION -- dimming duration in seconds
      local delay = constants.MIN_DIMMING_GET_STATUS_DELAY -- delay in seconds
      if type(dimmingDuration) == "number" then
        delay = math.max(dimmingDuration + constants.DEFAULT_POST_DIMMING_DELAY, delay) -- delay in seconds
      end
      device:send(SwitchMultilevel:Set({value = (cmd.command=='on' and 0xFF or 0x00)}))
      device.thread:call_with_delay(delay, function() device:send(SwitchMultilevel:Get({})) end)
      send_event(device, comp, capabilities.switch.switch(cmd.command))   -- optimistic
    elseif device.preferences.lightMode1 ~= 'disabled' then   --CCT or dimmer
      local level = cmd.command=='on' and get_state(device, comp, capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME, 100) or 0
      send_rgbw_level(device, level, nil, nil, nil, nil, nil)
      send_event(device, comp, capabilities.switch.switch(cmd.command))   -- optimistic
    end
  
  elseif channel == 2 and device.preferences.lightMode2 == 'dimmer' then
    local level = cmd.command=='on' and get_state(device, comp, capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME, 100) or 0
    send_rgbw_level(device, nil, level, nil, nil, nil, nil)
    send_event(device, comp, capabilities.switch.switch(cmd.command))   -- optimistic

  elseif channel == 3 and device.preferences.lightMode3 ~= 'disabled' then   --CCT or dimmer
    local level = cmd.command=='on' and get_state(device, comp, capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME, 100) or 0
    send_rgbw_level(device, nil, nil, level, nil, nil, nil)
    send_event(device, comp, capabilities.switch.switch(cmd.command))   -- optimistic

  elseif channel == 4 and device.preferences.lightMode4 == 'dimmer' then
    local level = cmd.command=='on' and get_state(device, comp, capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME, 100) or 0
    send_rgbw_level(device, nil, nil, nil, level, nil, nil)
    send_event(device, comp, capabilities.switch.switch(cmd.command))   -- optimistic
  end
end

local function set_level(driver, device, cmd)
  local comp
  if (device.network_type == st_device.NETWORK_TYPE_CHILD) then
    comp = device.parent_assigned_child_key
    device = device:get_parent_device()
  else
    comp = cmd.component
  end
  
  log.debug("set_level("..cmd.args.level.."): "..comp..", lightMode1: "..device.preferences.lightMode1..", lightMode2: "..device.preferences.lightMode2)
  local channel = component_to_channel(device, comp)
  log.debug("component_to_channel() returned "..channel)

  if channel == 1 then
    if device.preferences.lightMode1 == 'builtin_level' then
      local level = utils.clamp_value(utils.round(cmd.args.level), 1, 99)   -- never allow level 0
      local dimmingDuration = cmd.args.rate or constants.DEFAULT_DIMMING_DURATION -- dimming duration in seconds
      local delay = constants.MIN_DIMMING_GET_STATUS_DELAY -- delay in seconds
      if type(dimmingDuration) == "number" then
        delay = math.max(dimmingDuration + constants.DEFAULT_POST_DIMMING_DELAY, delay) -- delay in seconds
      end
      device:send(SwitchMultilevel:Set({ value=level, duration=dimmingDuration }))
      device.thread:call_with_delay(delay, function() device:send(SwitchMultilevel:Get({})) end)
    elseif device.preferences.lightMode1 ~= 'disabled' then   --CCT or dimmer
      local level = utils.clamp_value(utils.round(cmd.args.level), 1, 100)   -- never allow level 0
      send_rgbw_level(device, level, nil, nil, nil, nil, nil)
      send_event(device, comp, capabilities.switchLevel.level(level))   -- optimistic
      send_event(device, comp, capabilities.switch.switch.on())   -- optimistic
    end
  
  elseif channel == 2 and device.preferences.lightMode2 == 'dimmer' then   --CCT or dimmer
    local level = utils.clamp_value(utils.round(cmd.args.level), 1, 100)   -- never allow level 0
    send_rgbw_level(device, nil, level, nil, nil, nil, nil)
    send_event(device, comp, capabilities.switchLevel.level(level))   -- optimistic
    send_event(device, comp, capabilities.switch.switch.on())   -- optimistic
  
  elseif channel == 3 and device.preferences.lightMode3 ~= 'disabled' then   --CCT or dimmer
    local level = utils.clamp_value(utils.round(cmd.args.level), 1, 100)   -- never allow level 0
    send_rgbw_level(device, nil, nil, level, nil, nil, nil)
    send_event(device, comp, capabilities.switchLevel.level(level))   -- optimistic
    send_event(device, comp, capabilities.switch.switch.on())   -- optimistic
  
  elseif channel == 4 and device.preferences.lightMode4 == 'dimmer' then
    local level = utils.clamp_value(utils.round(cmd.args.level), 1, 100)   -- never allow level 0
    send_rgbw_level(device, nil, nil, nil, level, nil, nil)
    send_event(device, comp, capabilities.switchLevel.level(level))   -- optimistic
    send_event(device, comp, capabilities.switch.switch.on())   -- optimistic
  end
end


local function set_color_temperature(driver, device, cmd)
  local comp
  if (device.network_type == st_device.NETWORK_TYPE_CHILD) then
    comp = device.parent_assigned_child_key
    device = device:get_parent_device()
  else
    comp = cmd.component
  end
  
  log.debug("set_color_temperature("..cmd.args.temperature.."): "..comp..", lightMode1: "..device.preferences.lightMode1..", lightMode2: "..device.preferences.lightMode2)
  local channel = component_to_channel(device, comp)
  log.debug("component_to_channel() returned "..channel)

  local temp = utils.clamp_value(cmd.args.temperature, MIN_CT, MAX_CT)

  if channel == 1 then
    send_rgbw_level(device, (device.preferences.lightMode1 == 'builtin_level') and 0xFF or nil, nil, nil, nil, temp, nil)
    send_event(device, comp, capabilities.colorTemperature.colorTemperature(temp))   -- optimistic
  elseif channel == 3 then
    send_rgbw_level(device, nil, nil, nil, nil, nil, temp)
    send_event(device, comp, capabilities.colorTemperature.colorTemperature(temp))   -- optimistic
  end
end

function do_refresh(driver, device)
  log.debug("do_refresh()")
  if (device.network_type == st_device.NETWORK_TYPE_CHILD) then return end
  if device.preferences.lightMode1 == 'builtin_level' then
    device:send(SwitchMultilevel:Get({}))
    device:emit_event(capabilities.colorTemperature.colorTemperature(  device:get_latest_state("main", capabilities.colorTemperature.ID, capabilities.colorTemperature.colorTemperature.NAME)  ))
  end
end


------------------------------------------------------

local function create_device(driver, device, name, device_profile)
  if device:get_child_by_parent_assigned_key(name) then
    log.warn("Error creating child device. '"..name.."' already exists for this device.")
    return
  end
  
  local metadata = {
    type = "EDGE_CHILD",
    label = device.label..' '..name,
    profile = device_profile,
    parent_device_id = device.id,
    parent_assigned_child_key = name,
    vendor_provided_label = name,
  }
  assert(driver:try_create_device(metadata), "failed to create a new switch")
end

local function create_child_devices(driver, device)
  if device.preferences.lightMode2 == "dimmer" then
    create_device(driver, device, LIGHT2_COMPONENT, "child-dimmer")
  end
  if device.preferences.lightMode3 == "cw_ww" or device.preferences.lightMode3 == "level_cct" then
    create_device(driver, device, LIGHT3_COMPONENT, "child-cct")
  elseif device.preferences.lightMode3 == "dimmer" then
    create_device(driver, device, LIGHT3_COMPONENT, "child-dimmer")
  end
  if device.preferences.lightMode4 == "dimmer" then
    create_device(driver, device, LIGHT4_COMPONENT, "child-dimmer")
  end
  for i = 1, 4 do
    create_device(driver, device, "button"..i, "child-button")
  end
end

------------------------------------------------------

local function device_added(self, device)
  log.debug("device_added()")
  -- write initial state values for the device
  for i, comp in ipairs({"main", "light2", "light3", "light4", "button1", "button2", "button3", "button4"}) do
    if device:supports_capability(capabilities.switch, comp) then device:emit_component_event(device.profile.components[comp], capabilities.switch.switch.off()) end
    if device:supports_capability(capabilities.switchLevel, comp) then device:emit_component_event(device.profile.components[comp], capabilities.switchLevel.level(100)) end
    if device:supports_capability(capabilities.colorTemperature, comp) then device:emit_component_event(device.profile.components[comp], capabilities.colorTemperature.colorTemperature(MIN_CT)) end
    if device:supports_capability(capabilities.button, comp) then
      device:emit_component_event(device.profile.components[comp], capabilities.button.supportedButtonValues({"pushed", "double", "held"}), {visibility = { displayed = false }})
    end
  end
end

local function do_configure(driver, device)
  if device.network_type == st_device.NETWORK_TYPE_CHILD then return end
  -- set default zwave parameters
  local configuration = paramsMap.device_configuration
  for _, value in ipairs(configuration) do
    device:send(Configuration:Set({parameter_number = value.parameter_number, size = value.size, configuration_value = value.configuration_value}))
  end
  device:send(SwitchMultilevel:Get({}))
end

local function info_changed(driver, device, event, args)
  if device.network_type == st_device.NETWORK_TYPE_CHILD then return end
  log.debug("info_changed(): lightMode1: "..device.preferences.lightMode1..", lightMode2: "..device.preferences.lightMode2..", lightMode3: "..device.preferences.lightMode3..", lightMode4: "..device.preferences.lightMode4)
  -- handle profile changes
  if args.old_st_store.preferences.profileValue ~= device.preferences.profileValue then
    if device.preferences.profileValue ~= nil then
      local profile_value = device.preferences.profileValue:gsub('_', '-')
      log.debug("try_update_metadata() with profile "..profile_value)
      device:try_update_metadata({profile=profile_value})
    end
  end
  -- handle child device creation
  if args.old_st_store.preferences.createChild == false and device.preferences.createChild == true then
    create_child_devices(driver, device)
  end
  -- zwave parameter preferences
  local preferences = paramsMap.device_parameters
  for id, value in pairs(device.preferences) do
    if args.old_st_store.preferences[id] ~= value and preferences and preferences[id] then
      local new_parameter_value = paramsMap.to_numeric_value(device.preferences[id])
      device:send(Configuration:Set({parameter_number = preferences[id].parameter_number, size = preferences[id].size, configuration_value = new_parameter_value}))
    end
  end
end

--------------------------------------------------------------------------------------------
-- Register message handlers and run driver
--------------------------------------------------------------------------------------------

local driver_template = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.colorTemperature,
    capabilities.refresh
  },
  zwave_handlers = {
    [cc.SWITCH_COLOR] = {
      [SwitchColor.REPORT] = switch_color_report_handler
    },
    [cc.SWITCH_MULTILEVEL] = {
      [SwitchMultilevel.REPORT] = switch_multilevel_report_handler
    },
    [cc.CENTRAL_SCENE] = {
      [CentralScene.NOTIFICATION] = scene_notification_handler
    }
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = set_switch_on_off,
      [capabilities.switch.commands.off.NAME] = set_switch_on_off
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = set_level,
    },
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = set_color_temperature
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh
    }
  },
  lifecycle_handlers = {
    added = device_added,
    infoChanged = info_changed
  }
}

local zwave_driver = ZwaveDriver("fibaro-rgbw2-cct", driver_template)
zwave_driver:run()
