-- tuya Plug ver 0.1.2
-- Copyright 2022-2024 Jaewon Park (iquix)
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
local switch_defaults = require "st.zigbee.defaults.switch_defaults"
local device_management = require "st.zigbee.device_management"
local log = require "log"

local Basic = zcl_clusters.Basic
local OnOff = zcl_clusters.OnOff
local SimpleMetering = zcl_clusters.SimpleMetering
local ElectricalMeasurement = zcl_clusters.ElectricalMeasurement

local POWER_POLLING_TIMER = "tuya_plug_power_polling_timer"
local ENERGY_POLLING_TIMER = "tuya_plug_energy_polling_timer"
local APPLICATION_VERSION = "application_version"


---------------------------------------------------------------


local function power_refresh(device)
  log.debug("** power_refresh()")
  if (device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "off") then
    device:send(SimpleMetering.attributes.InstantaneousDemand:read(device))
    device:send(ElectricalMeasurement.attributes.ActivePower:read(device))
  end
end

local function energy_refresh(device)
  log.debug("** energy_refresh()")
  if (device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "off") then
    device:send(SimpleMetering.attributes.CurrentSummationDelivered:read(device))
  end
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

local function setup_power_polling(device)
  log.debug("** setup_power_polling()")
  local power_polling_timer = device:get_field(POWER_POLLING_TIMER)
  if power_polling_timer then
    log.debug("** unschedule power polling...")
    device.thread:cancel_timer(power_polling_timer)
    power_polling_timer = nil
  end
  if is_polling(device) then
    log.debug("** set power polling every 20 seconds...")
    power_polling_timer = device.thread:call_on_schedule(20, function(d)
      power_refresh(device)
    end)
  end
  device:set_field(POWER_POLLING_TIMER, power_polling_timer)
end

local function setup_energy_polling(device)
  log.debug("** setup_energy_polling()")
  local energy_polling_timer = device:get_field(ENERGY_POLLING_TIMER)
  if energy_polling_timer then
    log.debug("** unschedule energy polling...")
    device.thread:cancel_timer(energy_polling_timer)
    energy_polling_timer = nil
  end
  if device.preferences.energyPolling then
    log.debug("** set energy polling every 5 minutess...")
    energy_polling_timer = device.thread:call_on_schedule(300, function(d)
      energy_refresh(device)
    end)
  end
  device:set_field(ENERGY_POLLING_TIMER, energy_polling_timer)
end


---------------------------------------------------------------


local function energy_meter_handler(driver, device, value, zb_rx)
  local raw_value = value.value
  local multiplier = device:get_field(constants.SIMPLE_METERING_MULTIPLIER_KEY) or 1
  local divisor = device:get_field(constants.SIMPLE_METERING_DIVISOR_KEY) or 100
  local converted_value = raw_value * multiplier/divisor

  local delta_energy = 0.0
  local current_power_consumption = device:get_latest_state("main", capabilities.powerConsumptionReport.ID, capabilities.powerConsumptionReport.powerConsumption.NAME)
  if current_power_consumption ~= nil then
    delta_energy = math.max(raw_value - current_power_consumption.energy, 0.0)
  end
  device:emit_event(capabilities.powerConsumptionReport.powerConsumption({energy = raw_value, deltaEnergy = delta_energy })) -- the unit of these values should be 'Wh'
  device:emit_event(capabilities.energyMeter.energy({value = converted_value, unit = "kWh"}))
end

local function application_version_attr_handler(driver, device, value, zb_rx)
  local version = tonumber(value.value)
  device:set_field(APPLICATION_VERSION, version, {persist = true})
  setup_power_polling(device)
end

local function on_off_attr_handler(driver, device, value, zb_rx)
  if is_polling(device) then
    power_polling_timer = device.thread:call_with_delay(5, function(d)
      power_refresh(device)
    end)
  end
  switch_defaults.on_off_attr_handler(driver, device, value, zb_rx)
end

---------------------------------------------------------------------


local function device_added(self, device)
  log.debug("** device_added()")
  device:set_field(constants.SIMPLE_METERING_DIVISOR_KEY, 100, {persist = true})
end

local function device_init(self, device)
  log.debug("** device_init()")
  
  local ver = device:get_field(APPLICATION_VERSION)
  if ver==nil or c==0 then
    device:set_field(APPLICATION_VERSION, 0)
    device:send(Basic.attributes.ApplicationVersion:read(device))
  else
    setup_power_polling(device)
  end
  setup_energy_polling(device)

  -- Read Divisor and multipler for PowerMeter
  device:send(SimpleMetering.attributes.Divisor:read(device))
  device:send(SimpleMetering.attributes.Multiplier:read(device))
  -- Read Divisor and multipler for EnergyMeter
  device:send(ElectricalMeasurement.attributes.ACPowerDivisor:read(device))
  device:send(ElectricalMeasurement.attributes.ACPowerMultiplier:read(device))
end

local function do_configure(self, device)
  log.debug("** do_configure()")
  device:configure()
  device:refresh()
  device:send(SimpleMetering.attributes.CurrentSummationDelivered:configure_reporting(device, 1, 300, 1))
end

local function device_info_changed(driver, device, event, args)
  log.debug("** device_info_changed()")
  if args.old_st_store.preferences.powerPolling ~= device.preferences.powerPolling then
    setup_power_polling(device)
  end
  if args.old_st_store.preferences.energyPolling ~= device.preferences.energyPolling then
    setup_energy_polling(device)
  end  
end


---------------------------------------------------------------------


local tuya_plug = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.powerMeter,
    capabilities.energyMeter,
    capabilities.refresh,
  },
  zigbee_handlers = {
    attr = {
      [Basic.ID] = {
        [Basic.attributes.ApplicationVersion.ID] = application_version_attr_handler
      },
      [SimpleMetering.ID] = {
        [SimpleMetering.attributes.CurrentSummationDelivered.ID] = energy_meter_handler
      },
      [OnOff.ID] = {
        [OnOff.attributes.OnOff.ID] = on_off_attr_handler,
      },
    }
  },
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    doConfigure = do_configure,
    infoChanged = device_info_changed,
  }
}

defaults.register_for_default_handlers(tuya_plug, tuya_plug.supported_capabilities, {native_capability_cmds_enabled = true})
local zigbee_driver = ZigbeeDriver("tuya-plug", tuya_plug)
zigbee_driver:run()