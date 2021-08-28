-- Hue Dimmer Switch ver 0.1.2
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

local comp = {"button1", "button2", "button3", "button4"}

local button_handler = function(driver, device, zb_rx)
	local rx = zb_rx.body.zcl_body.body_bytes
	local button = string.byte(rx:sub(1,1))
	local buttonState = string.byte(rx:sub(5,5))
	--local buttonHoldTime = string.byte(rx:sub(7,7))
	
	if buttonState == 2 then
		local ev = capabilities.button.button.pushed()
		ev.state_change = true
		device.profile.components[comp[button]]:emit_event(ev)
		device:emit_event(ev)
	elseif buttonState == 3 then
		local ev = capabilities.button.button.held()
		ev.state_change = true
		device.profile.components[comp[button]]:emit_event(ev)
		device:emit_event(ev)
	end
end

local device_added = function(driver, device)
	device:emit_event(capabilities.button.supportedButtonValues({"pushed", "held"}))
	device:emit_event(capabilities.button.button.pushed())
	for i,v in ipairs(comp) do
		device.profile.components[v]:emit_event(capabilities.button.supportedButtonValues({"pushed", "held"}))
		device.profile.components[v]:emit_event(capabilities.button.button.pushed())
	end
end

local do_configure = function(self, device)
	device:configure()
	device:send(device_management.build_bind_request(device, 0xFC00, device.driver.environment_info.hub_zigbee_eui))
	device:send(clusters.PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
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
		doConfigure = do_configure
	}
}

defaults.register_for_default_handlers(hue_dimmer_driver, hue_dimmer_driver.supported_capabilities)
local zigbee_driver = ZigbeeDriver("hue-dimmer-switch", hue_dimmer_driver)
zigbee_driver:run()