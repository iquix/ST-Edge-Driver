-- Hue Dimmer Switch ver 0.4.0
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
local constants = require "st.zigbee.constants"
local messages = require "st.zigbee.messages"
local zdo_messages = require "st.zigbee.zdo"
local bind_request = require "st.zigbee.zdo.bind_request"
local unbind_request = require "st.zigbee.zdo.unbind_request"
local mgmt_bind_req = require "st.zigbee.zdo.mgmt_bind_request"

--------------------------------

function get_client_endpoint(device, cluster)
  --Always check the fingerprinted endpoint first.
  local fingerprinted_ep = device.zigbee_endpoints[device.fingerprinted_endpoint_id]
  if fingerprinted_ep then
    for _, clus in ipairs(fingerprinted_ep.client_clusters) do
      if clus == cluster then
        return fingerprinted_ep.id
      end
    end
  end
  for _, ep in pairs(device.zigbee_endpoints) do
    for _, clus in ipairs(ep.client_clusters) do
      if clus == cluster then
        return ep.id
      end
    end
  end
  return device.fingerprinted_endpoint_id
end

local function bind_group(device, group_id, cluster)
  local zdo_cluster = bind_request.BindRequest.ID
  local device_ep = get_client_endpoint(device, cluster)
  local addr_header = messages.AddressHeader(constants.HUB.ADDR, constants.HUB.ENDPOINT, device:get_short_address(), device_ep, constants.ZDO_PROFILE_ID, zdo_cluster)
  local message_body = zdo_messages.ZdoMessageBody({
    zdo_body = bind_request.BindRequest(device.zigbee_eui, device_ep, cluster, bind_request.ADDRESS_MODE_16_BIT, group_id)
  })
  local bind_cmd = messages.ZigbeeMessageTx({
    address_header = addr_header,
    body = message_body
  })
  device:send(bind_cmd)
end

local function unbind_group(device, group_id, cluster)
  local zdo_cluster = unbind_request.UnbindRequest.ID
  local device_ep = get_client_endpoint(device, cluster)
  local addr_header = messages.AddressHeader(constants.HUB.ADDR, constants.HUB.ENDPOINT, device:get_short_address(), device_ep, constants.ZDO_PROFILE_ID, zdo_cluster)
  local message_body = zdo_messages.ZdoMessageBody({
    zdo_body = unbind_request.UnbindRequest(device.zigbee_eui, device_ep, cluster, unbind_request.ADDRESS_MODE_16_BIT, group_id)
  })
  local unbind_cmd = messages.ZigbeeMessageTx({
    address_header = addr_header,
    body = message_body
  })
  device:send(unbind_cmd)
end

local function mgmt_bind_request(device, cluster)
  local device_ep = get_client_endpoint(device, cluster)
  local addr_header = messages.AddressHeader(constants.HUB.ADDR, constants.HUB.ENDPOINT, device:get_short_address(), device_ep, constants.ZDO_PROFILE_ID, mgmt_bind_req.BINDING_TABLE_REQUEST_CLUSTER_ID)
  local message_body = zdo_messages.ZdoMessageBody({
    zdo_body = mgmt_bind_req.MgmtBindRequest(2) -- Single argument of the start index to query the table
  })
  local binding_table_cmd = messages.ZigbeeMessageTx({
    address_header = addr_header,
    body = message_body
  })
  device:send(binding_table_cmd)
end

--------------------------------

local comp = {"button1", "button2", "button3", "button4"}

local button_handler = function(driver, device, zb_rx)
	local rx = zb_rx.body.zcl_body.body_bytes
	local button = rx:byte(1)
	local buttonState = rx:byte(5)
	local buttonHoldTime = rx:byte(7)
	
	local pushed_ev = capabilities.button.button.pushed({state_change = true})
	local held_ev = capabilities.button.button.held({state_change = true})
	local up_ev = capabilities.button.button.up_hold({state_change = true})
	local down_ev = capabilities.button.button.down_hold({state_change = true})
	
	if buttonState == 2 then  -- pushed
		device.profile.components[comp[button]]:emit_event(pushed_ev)
		device:emit_event(pushed_ev)
	elseif buttonState == 3 then  -- up
		if device.preferences.holdTimingValue == "h1" then
			device.profile.components[comp[button]]:emit_event(held_ev)
			device:emit_event(held_ev)
		elseif device.preferences.holdTimingValue == "h3" then
			device.profile.components[comp[button]]:emit_event(up_ev)
			device:emit_event(up_ev)
		end
	elseif buttonHoldTime == 8 then  -- hold down starts
		if device.preferences.holdTimingValue == "h0" or device.preferences.holdTimingValue == "h2" then
			device.profile.components[comp[button]]:emit_event(held_ev)
			device:emit_event(held_ev)
		elseif device.preferences.holdTimingValue == "h3" then
			device.profile.components[comp[button]]:emit_event(down_ev)
			device:emit_event(down_ev)
		end
	elseif (buttonHoldTime > 8 and device.preferences.holdTimingValue == "h2") then  -- hold down continues
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
	device:emit_event(capabilities.button.supportedButtonValues({"pushed", "held", "up_hold", "down_hold"}))
	device:emit_event(capabilities.button.button.pushed())
	local n_button = is_wall_switch(device) and 2 or 4
	for i = 1, n_button, 1 do
		device.profile.components[comp[i]]:emit_event(capabilities.button.supportedButtonValues({"pushed", "held", "up_hold", "down_hold"}))
		device.profile.components[comp[i]]:emit_event(capabilities.button.button.pushed({state_change = false}))
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
	local group_id = device.preferences.groupId
	if args.old_st_store.preferences.bindGroup == false and device.preferences.bindGroup == true and group_id ~= 0 then
		bind_group(device, group_id, 0x0006)
		bind_group(device, group_id, 0x0008)
	elseif args.old_st_store.preferences.unbindGroup == false and device.preferences.unbindGroup == true and group_id ~= 0 then
		unbind_group(device, group_id, 0x0006)
		unbind_group(device, group_id, 0x0008)
	elseif args.old_st_store.preferences.queryBindTable == false and device.preferences.queryBindTable == true then
		mgmt_bind_request(device, device.preferences.groupId, 0x0006)
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
	cluster_configurations = {
		[capabilities.battery.ID] = {
			{
				cluster = clusters.PowerConfiguration.ID,
				attribute = clusters.PowerConfiguration.attributes.BatteryPercentageRemaining.ID,
				minimum_interval = 800,
				maximum_interval = 900,
				data_type = clusters.PowerConfiguration.attributes.BatteryPercentageRemaining.base_type,
				reportable_change = 2
			}
		}
	},
	lifecycle_handlers = {
		added = device_added,
		infoChanged = device_info_changed,
		doConfigure = do_configure
	},
	health_check = false
}

defaults.register_for_default_handlers(hue_dimmer_driver, hue_dimmer_driver.supported_capabilities)
local zigbee_driver = ZigbeeDriver("hue-dimmer-switch", hue_dimmer_driver)
zigbee_driver:run()