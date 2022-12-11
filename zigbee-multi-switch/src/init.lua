-- Zigbee Switch with Child ver 0.4.2
-- Copyright 2021-2022 Jaewon Park (iquix)
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
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local device_management = require "st.zigbee.device_management"
local switch_defaults = require "st.zigbee.defaults.switch_defaults"
local log = require "log"

local device_data = require "device_data"
local POLLING_TIMER = "switch_polling_timer"

--------------------------------------------------

local function refresh_handler(device)
  local attrRead = zcl_clusters.OnOff.attributes.OnOff:read(device)
  for _, ep in pairs(device.zigbee_endpoints) do
    device:send(attrRead:to_endpoint(ep.id))
  end
end

local function setup_polling(device)
  log.debug("** setup_polling()")
  local polling_timer = device:get_field(POLLING_TIMER)
  if polling_timer then
    log.debug("** unschedule polling...")
    device.thread:cancel_timer(polling_timer)
    polling_timer = nil
  end
  log.debug("** set polling every 5 minutes...")
  polling_timer = device.thread:call_on_schedule(300, function(d)
    refresh_handler(device)
  end)
  device:set_field(POLLING_TIMER, polling_timer)
end

--------------------------------------------------

local function find_child(parent, endpoint)
  return parent:get_child_by_parent_assigned_key(string.format("%02X", endpoint))
end

local function create_child_devices(driver, device)
  local ep_array
  
  if device.preferences.forceChild > 0 then
    ep_array = {}
    for i = 1, device.preferences.forceChild do ep_array[i] = i end  -- assuming ep# from 1 to 'forceChild'
  else
    ep_array = device_data.endpoints[device:get_manufacturer().."/"..device:get_model()]
  end
  
  if ep_array == nil then
    ep_array = {}
    for _, ep in pairs(device.zigbee_endpoints) do
      for _, clus in ipairs(ep.server_clusters) do
        if clus == zcl_clusters.OnOff.ID then
          table.insert(ep_array, tonumber(ep.id))
          break
        end
      end
    end
    table.sort(ep_array)
  end
  
  for i, ep in pairs(ep_array) do
    if ep ~= device.fingerprinted_endpoint_id then
      if find_child(device, ep) == nil then
        local metadata = {
          type = "EDGE_CHILD",
          parent_assigned_child_key = string.format("%02X", ep),
          label = device.label..' '..ep,
          profile = "child-switch",
          parent_device_id = device.id,
          manufacturer = device:get_manufacturer(),
          model = device:get_model()
        }
        driver:try_create_device(metadata)
      end
    end
  end
end

--------------------------------------------------

local function do_configure(self, device)
  if device.network_type == st_device.NETWORK_TYPE_CHILD then return end
  log.debug("parent do_configure()")
  if device_data.is_polling_manufacturer[device:get_manufacturer()] then
    device:send(cluster_base.write_manufacturer_specific_attribute(device, zcl_clusters.Basic.ID, 0x0099, 0x0000, data_types.Uint8, 0x01))
    setup_polling(device)
  else
    local attrCfg = device_management.attr_config(device, switch_defaults.default_on_off_configuration)
    local attrRead = zcl_clusters.OnOff.attributes.OnOff:read(device)
    
    for _, ep in pairs(device.zigbee_endpoints) do
      local bindReq = device_management.build_bind_request(device, zcl_clusters.OnOff.ID, device.driver.environment_info.hub_zigbee_eui, ep.id)
      device:send(bindReq:to_endpoint(ep.id))
      device:send(attrCfg:to_endpoint(ep.id))
      device:send(attrRead:to_endpoint(ep.id))
    end
  end
end

local function device_added(driver, device)
  if device.network_type == st_device.NETWORK_TYPE_CHILD then return end
  log.debug("parent device_added()")
  create_child_devices(driver, device)
  device.thread:call_with_delay(2, function(d)
    do_configure(self, device)
  end)
end

local function device_init(driver, device)
  if device.network_type == st_device.NETWORK_TYPE_CHILD then return end
  log.debug("parent device_init()")
  device:set_find_child(find_child)
end

local function device_info_changed(driver, device, event, args)
  if device.network_type == st_device.NETWORK_TYPE_CHILD then return end
  log.debug("parent device_info_changed()")
  if args.old_st_store.preferences.forceChild ~= device.preferences.forceChild then
    create_child_devices(driver, device)
    device.thread:call_with_delay(2, function(d)
      do_configure(self, device)
    end)
  end
end

--------------------------------------------------

local zigbee_switch_driver = {
  supported_capabilities = {
    capabilities.switch
  },
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    infoChanged = device_info_changed,
    doConfigure = do_configure
  },
}

defaults.register_for_default_handlers(zigbee_switch_driver, zigbee_switch_driver.supported_capabilities)
local zigbee_driver = ZigbeeDriver("zigbee-multi-switch", zigbee_switch_driver)
zigbee_driver:run()