-- Power Trigger Switch ver 0.1.4
-- Copyright 2021-2023 Jaewon Park (iquix)
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
local zcl_clusters = require "st.zigbee.zcl.clusters"
local zcl_types = require "st.zigbee.zcl.types"
local ZigbeeDriver = require "st.zigbee"
local constants = require "st.zigbee.constants"
local defaults = require "st.zigbee.defaults"
local default_response = require "st.zigbee.zcl.global_commands.default_response"
local powerMeter_defaults = require "st.zigbee.defaults.powerMeter_defaults"
local socket = require "socket"
local log = require "log"

local Basic = zcl_clusters.Basic
local OnOff = zcl_clusters.OnOff
local SimpleMetering = zcl_clusters.SimpleMetering
local ElectricalMeasurement = zcl_clusters.ElectricalMeasurement

local ONTIME = "trigger_ontime"
local OFFTIME = "trigger_offtime"
local POLLING_TIMER = "trigger_polling_timer"
local APPLICATION_VERSION = "application_version"
--local POWER_REFRESH_AWAITING = "power_refresh_awaiting"


---------------------------------------------------------------


local function emit_current_switch_event(device)
  local sw = device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME)
  device:emit_event(capabilities.switch.switch(sw))
end

local function switch_cmd_on(driver, device)
  if device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) == "on" then
    return
  end
  local pushed_ev = capabilities.button.button.pushed({state_change = true})
  device.profile.components["onButton"]:emit_event(pushed_ev)
  emit_current_switch_event(device)
end

local function switch_cmd_off(driver, device)
  if device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) == "off" then
    return
  end
  local pushed_ev = capabilities.button.button.pushed({state_change = true})
  device.profile.components["offButton"]:emit_event(pushed_ev)
  emit_current_switch_event(device)
end


---------------------------------------------------------------


local function power_refresh(device)
  log.debug("** power_refresh()")
  device:send(SimpleMetering.attributes.InstantaneousDemand:read(device))
  device:send(ElectricalMeasurement.attributes.ActivePower:read(device))
end

local function get_default_divisor(device)
  return (string.sub(device:get_model(),1,2) == "TS") and 100 or 1000
end

local function is_polling(device) 
  local manufacturer = device:get_manufacturer()
  local model = device:get_model()
  local app_ver = device:get_field(APPLICATION_VERSION)
  local power_polling = device.preferences.powerPolling
  local polling_TS011F_app_vers = {[69]=true, [68]=true, [65]=true, [64]=true}
  local push_TS0121_devices = {_TZ3000_8nkb7mof=true}
  return (power_polling ~= "p2") and ((model == "TS0121" and (push_TS0121_devices[manufacturer] == nil) ) or (model == "TS011F" and polling_TS011F_app_vers[app_ver] == true) or power_polling == "p1")
end

local function setup_polling(device)
  log.debug("** setup_polling()")
  local polling_timer = device:get_field(POLLING_TIMER)
  if polling_timer then
    log.debug("** unschedule polling...")
    device.thread:cancel_timer(polling_timer)
    polling_timer = nil
  end
  if is_polling(device) then
    log.debug("** set polling every 10 seconds...")
    polling_timer = device.thread:call_on_schedule(10, function(d)
      power_refresh(device)
    end)
  else
    log.debug("** NOT setting periodic polling for this device...")
  end
  device:set_field(POLLING_TIMER, polling_timer)
end

local function process_switch_off(device)
  if device.preferences.forceTurnOn then
    log.debug("** process_switch_off() : force turn on the switch after 1sec")
    device.thread:call_with_delay(1, function(d)
      device:send(OnOff.server.commands.On(device))
    end)
  end
end

local function process_power(device)
  local p = device:get_latest_state("main", capabilities.powerMeter.ID, capabilities.powerMeter.power.NAME)
  local sw = device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME)
  local now = socket.gettime()

  if p >= device.preferences.onThreshold and sw == 'off' then
    log.debug(string.format("** processPower() OnTrigger : Power{%f} >= OnThreshold{%f} at %f. On trigger start time=%f", p, device.preferences.onThreshold, now, device:get_field(ONTIME)))
    if device:get_field(ONTIME) == 0 and device.preferences.onDuration >= 1 then
      device:set_field(ONTIME, now)
      if is_polling(device) then
        device.thread:call_with_delay(device.preferences.onDuration, function(d)
          power_refresh(device)
        end)
      else
        device.thread:call_with_delay(device.preferences.onDuration + 1, function(d)
          process_power(device)
        end)
      end
    elseif now - device:get_field(ONTIME) >= device.preferences.onDuration then
      log.debug("** Setting switch status to on.")
      device:emit_event(capabilities.switch.switch.on())
      device:set_field(ONTIME, 0)
      device:set_field(OFFTIME, 0)
    end
  else
    device:set_field(ONTIME, 0)
  end

  if p <= device.preferences.offThreshold and sw == 'on' then
    log.debug(string.format("** processPower() OffTrigger : Power{%f} <= OffThreshold{%f} at %f. Off trigger start time=%f", p, device.preferences.offThreshold, now, device:get_field(OFFTIME)))
    if device:get_field(OFFTIME) == 0 and device.preferences.offDuration >= 1 then
      device:set_field(OFFTIME, now)
      if is_polling(device) then
        device.thread:call_with_delay(device.preferences.offDuration, function(d)
          power_refresh(device)
        end)
      else
        device.thread:call_with_delay(device.preferences.offDuration + 1, function(d)
          process_power(device)
        end)
      end
    elseif now - device:get_field(OFFTIME) >= device.preferences.offDuration then
      log.debug("** Setting switch status to off.")
      device:emit_event(capabilities.switch.switch.off())
      device:set_field(ONTIME, 0)
      device:set_field(OFFTIME, 0)
    end
  else
    device:set_field(OFFTIME, 0)
  end
  
--  if (not is_polling(device)) and p < 5 and sw == 'on' and device:get_field(POWER_REFRESH_AWAITING) == nil then
--    local timer = device.thread:call_with_delay(10, function(d)
--      power_refresh(device)
--      device:set_field(POWER_REFRESH_AWAITING, nil)
--    end)
--    device:set_field(POWER_REFRESH_AWAITING, timer)
--  end
end


---------------------------------------------------------------


local function default_response_handler(driver, device, zb_rx)
  local status = zb_rx.body.zcl_body.status.value
  local cmd = zb_rx.body.zcl_body.cmd.value
  log.debug(string.format("** default_response_handler(). status:%x cmd:%x", status, cmd))
  if status == zcl_types.ZclStatus.SUCCESS then
    emit_current_switch_event(device)
    if cmd == 0 then
      process_switch_off(device)
    end
  end
end

local function onoff_handler(driver, device, value, zb_rx)
  log.debug(string.format("** onoff_handler() with value cmd:%s", tostring(value.value)))
  emit_current_switch_event(device)
  if value.value == false then
    process_switch_off(device)
  end
end

local function energy_meter_handler(driver, device, value, zb_rx)
  local raw_value = value.value
  local multiplier = device:get_field(constants.SIMPLE_METERING_MULTIPLIER_KEY) or 1
  local divisor = device:get_field(constants.SIMPLE_METERING_DIVISOR_KEY) or get_default_divisor(device)
  local converted_value = raw_value * multiplier/divisor
  
  local offset = device:get_field(constants.ENERGY_METER_OFFSET) or 0
  if converted_value < offset then
    --- somehow our value has gone below the offset, so we'll reset the offset, since the device seems to have
    offset = 0
    device:set_field(constants.ENERGY_METER_OFFSET, offset, {persist = true})
  end
  converted_value = converted_value - offset
  
  local delta_energy = 0.0
  local current_power_consumption = device:get_latest_state("main", capabilities.powerConsumptionReport.ID, capabilities.powerConsumptionReport.powerConsumption.NAME)
  if current_power_consumption ~= nil then
    delta_energy = math.max(converted_value * 1000 - current_power_consumption.energy, 0.0)
  end
  device:emit_event(capabilities.powerConsumptionReport.powerConsumption({energy = converted_value * 1000, deltaEnergy = delta_energy })) -- the unit of these values should be 'Wh'
  device:emit_event(capabilities.energyMeter.energy({value = converted_value, unit = "kWh"}))
end

local function active_power_meter_handler(driver, device, value, zb_rx)
  powerMeter_defaults.active_power_meter_handler(driver, device, value, zb_rx)
  process_power(device)
end

local function instantaneous_demand_handler(driver, device, value, zb_rx)
  powerMeter_defaults.instantaneous_demand_handler(driver, device, value, zb_rx)
  process_power(device)
end

local function application_version_attr_handler(driver, device, value, zb_rx)
  local version = tonumber(value.value)
  device:set_field(APPLICATION_VERSION, version, {persist = true})
  setup_polling(device)
end


---------------------------------------------------------------------


local device_added = function(self, device)
  log.debug("** device_added()")

  if device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) == nil then
    local swoff_ev = capabilities.switch.switch.off({visibility = {displayed = false}, state_change=false})
    local pushed_ev = capabilities.button.button.pushed({visibility = {displayed = false}, state_change=false})
    local supported_button_ev = capabilities.button.supportedButtonValues({"pushed"}, {visibility = {displayed = false}, state_change=false})
    device:emit_event(swoff_ev)
    device.profile.components["onButton"]:emit_event(pushed_ev)
    device.profile.components["offButton"]:emit_event(pushed_ev)
    device.profile.components["onButton"]:emit_event(supported_button_ev)
    device.profile.components["offButton"]:emit_event(supported_button_ev)
  end
  device:set_field(constants.SIMPLE_METERING_DIVISOR_KEY, get_default_divisor(device), {persist = true})
end

local device_init = function(self, device)
  log.debug("** device_init()")

  device:set_field(ONTIME, 0)
  device:set_field(OFFTIME, 0)
  
  local ver = device:get_field(APPLICATION_VERSION)
  if ver==nil or c==0 then
    device:set_field(APPLICATION_VERSION, 0)
    device:send(Basic.attributes.ApplicationVersion:read(device))
  else
    setup_polling(device)
  end

  -- Divisor and multipler for PowerMeter
  device:send(SimpleMetering.attributes.Divisor:read(device))
  device:send(SimpleMetering.attributes.Multiplier:read(device))
  -- Divisor and multipler for EnergyMeter
  device:send(ElectricalMeasurement.attributes.ACPowerDivisor:read(device))
  device:send(ElectricalMeasurement.attributes.ACPowerMultiplier:read(device))
end

local do_configure = function(self, device)
  log.debug("** do_configure()")
  device:configure()
  device:refresh()
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:configure_reporting(device, 1, 300, 1))

  if device:get_manufacturer() == "DAWON_DNS" then
    device:send(SimpleMetering.attributes.InstantaneousDemand:configure_reporting(device, 1, 300, 1))
  end
end

local device_info_changed = function(driver, device, event, args)
  log.debug("** device_info_changed()")
  if args.old_st_store.preferences.steMode ~= device.preferences.steMode then
    if device.preferences.steMode then
      device:try_update_metadata({profile="power-trigger-switch-ste"})
    else
      device:try_update_metadata({profile="power-trigger-switch-cfg"})
    end
  end
  if args.old_st_store.preferences.powerPolling ~= device.preferences.powerPolling then
    setup_polling(device)
  end
end

---------------------------------------------------------------------


local power_trigger_switch = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.powerMeter,
    capabilities.energyMeter,
    capabilities.refresh,
  },
  zigbee_handlers = {
    global = {
      [OnOff.ID] = {
        [default_response.DefaultResponse.ID] = default_response_handler
      }
    },
    attr = {
      [Basic.ID] = {
        [Basic.attributes.ApplicationVersion.ID] = application_version_attr_handler
      },
      [ElectricalMeasurement.ID] = {
        [ElectricalMeasurement.attributes.ActivePower.ID] = active_power_meter_handler
      },
      [SimpleMetering.ID] = {
        [SimpleMetering.attributes.CurrentSummationDelivered.ID] = energy_meter_handler,
        [SimpleMetering.attributes.InstantaneousDemand.ID] = instantaneous_demand_handler
      },
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = onoff_handler
      }
    }
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_cmd_on,
      [capabilities.switch.commands.off.NAME] = switch_cmd_off
    }
  },
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    infoChanged = device_info_changed,
    driverSwitched = do_configure,
    doConfigure = do_configure
  }
}

defaults.register_for_default_handlers(power_trigger_switch, power_trigger_switch.supported_capabilities)
local zigbee_driver = ZigbeeDriver("power-trigger-switch", power_trigger_switch)
zigbee_driver:run()