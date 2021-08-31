-- Hue Motion Sensor ver 0.1.0
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
local clusters = require "st.zigbee.zcl.clusters"
local data_types = require "st.zigbee.data_types"


local function occupancy_attr_handler(driver, device, occupancy, zb_rx)
	device:emit_event(
		occupancy.value == 1 and capabilities.motionSensor.motion.active() or capabilities.motionSensor.motion.inactive())
end

local function illuminance_attr_handler(driver, device, value, zb_rx)
	-- illuminance handler is explicitly defined because of the error in the default built-in zigbee handler.
	local lux_value = math.floor(10 ^ ((value.value - 1) / 10000))
	device:emit_event(capabilities.illuminanceMeasurement.illuminance(lux_value))
end

local hue_motion_driver = {
	supported_capabilities = {
		capabilities.motionSensor,
		capabilities.temperatureMeasurement,
		capabilities.illuminanceMeasurement,
		capabilities.battery,
	},
	zigbee_handlers = {
		attr = {
			[clusters.OccupancySensing.ID] = {
				[clusters.OccupancySensing.attributes.Occupancy.ID] = occupancy_attr_handler
			},
			[clusters.IlluminanceMeasurement.ID] = {
				[clusters.IlluminanceMeasurement.attributes.MeasuredValue.ID] = illuminance_attr_handler
			}
		}
	},
	cluster_configurations = {
		[capabilities.motionSensor.ID] = {
			{
				cluster = clusters.OccupancySensing.ID,
				attribute = clusters.OccupancySensing.attributes.Occupancy.ID,
				minimum_interval = 1,
				maximum_interval = 300,
				data_type = data_types.Bitmap8
			}
		},
		[capabilities.illuminanceMeasurement.ID] = {
			{
				cluster = clusters.IlluminanceMeasurement.ID,
				attribute = clusters.IlluminanceMeasurement.attributes.MeasuredValue.ID,
				minimum_interval = 5,
				maximum_interval = 300,
				data_type = data_types.Uint16,
				reportable_change = 1000
			}
		}
	}
}

defaults.register_for_default_handlers(hue_motion_driver, hue_motion_driver.supported_capabilities)
local zigbee_driver = ZigbeeDriver("hue-motion-sensor", hue_motion_driver)
zigbee_driver:run()