-- Hue Dimmer Switch ver 0.2.0
-- Copyright 2021 Jaewon Park (iquix)
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
local defaults = require "st.zigbee.defaults"
local device_management = require "st.zigbee.device_management"
local clusters = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local data_types = require "st.zigbee.data_types"

local comp = {"button1", "button2", "button3", "button4"}

local button_handler = function(driver, device, zb_rx)
	local rx = zb_rx.body.zcl_body.body_bytes
	local button = string.byte(rx:sub(1,1))
	local buttonState = string.byte(rx:sub(5,5))
	local buttonHoldTime = string.byte(rx:sub(7,7))
	
	local pushed_ev = capabilities.button.button.pushed()
	local held_ev = capabilities.button.button.held()
	pushed_ev.state_change = true
	held_ev.state_change = true
	
	if buttonState == 2 then
		device.profile.components[comp[button]]:emit_event(pushed_ev)
		device:emit_event(pushed_ev)
	elseif (buttonState == 3 and device.preferences.holdTimingValue == "h1") then
		device.profile.components[comp[button]]:emit_event(held_ev)
		device:emit_event(held_ev)
	elseif (buttonHoldTime == 8 and device.preferences.holdTimingValue ~= "h1") then
		device.profile.components[comp[button]]:emit_event(held_ev)
		device:emit_event(held_ev)
	elseif (buttonHoldTime > 8 and device.preferences.holdTimingValue == "h2") then
		device.profile.components[comp[button]]:emit_event(held_ev)
		device:emit_event(held_ev)
	end
end

local is_wall_switch = function(device)
	local m = device:get_model()
	return (m == "RDM001")
end

local set_sw_type = function(device)
	local swTypeTable = {singleRocker = 0, singlePush = 1, dualRocker = 2, dualPush = 3}
	device:send(cluster_base.write_manufacturer_specific_attribute(device, clusters.Basic.ID, 0x0034, 0x100b,
		data_types.Enum8, swTypeTable[device.preferences.swTypeValue]))
end

local device_added = function(driver, device)
	device:emit_event(capabilities.button.supportedButtonValues({"pushed", "held"}))
	device:emit_event(capabilities.button.button.pushed())
	local n_button = is_wall_switch(device) and 2 or 4
	for i = 1, n_button, 1 do
		device.profile.components[comp[i]]:emit_event(capabilities.button.supportedButtonValues({"pushed", "held"}))
		device.profile.components[comp[i]]:emit_event(capabilities.button.button.pushed())
	end
	if is_wall_switch(device) then
		set_sw_type(device)
	end
end

local do_configure = function(self, device)
	device:configure()
	device:send(device_management.build_bind_request(device, 0xFC00, device.driver.environment_info.hub_zigbee_eui))
	device:send(clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
end

local device_info_changed = function(driver, device, event, args)
	if is_wall_switch(device) then
		if args.old_st_store.preferences.swTypeValue ~= device.preferences.swTypeValue then
			set_sw_type(device)
		end
	end
end

local hue_dimmer_driver = {
	supported_capabilities = {
		capabilities.button,
		capabilities.battery,
	},
	zigbee_handlers = {
		cluster = {
			[0xFC00] = {
				[0x00] = button_handler
			}
		},
	},
	lifecycle_handlers = {
		added = device_added,
		infoChanged = device_info_changed,
		doConfigure = do_configure
	}
}

defaults.register_for_default_handlers(hue_dimmer_driver, hue_dimmer_driver.supported_capabilities)
local zigbee_driver = ZigbeeDriver("hue-dimmer-switch", hue_dimmer_driver)
zigbee_driver:run()