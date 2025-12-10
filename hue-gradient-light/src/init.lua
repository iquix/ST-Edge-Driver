-- Copyright 2023 Jaewon Park
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
local zcl_messages = require "st.zigbee.zcl"
local messages = require "st.zigbee.messages"
local clusters = require "st.zigbee.zcl.clusters"
local data_types = require "st.zigbee.data_types"
local zb_const = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"
local utils = require "st.utils"

local colorTemperature_defaults = require "st.zigbee.defaults.colorTemperature_defaults"
local colorControl_defaults = require "st.zigbee.defaults.colorControl_defaults"

local MANUFACTURER_SPECIFIC_CLUSTER_ID = 0xFC03
local MFG_CODE = 0x100B

----------------------------------------------------------------------

local function send_hue_command(device, data) 
  local header_args = {
    cmd = data_types.ZCLCommandId(0x00),
    mfg_code = data_types.Uint16(MFG_CODE)
  }
  local zclh = zcl_messages.ZclHeader(header_args)
  zclh.frame_ctrl:set_cluster_specific()
  zclh.frame_ctrl:set_mfg_specific()
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(MANUFACTURER_SPECIFIC_CLUSTER_ID),
    zb_const.HA_PROFILE_ID,
    MANUFACTURER_SPECIFIC_CLUSTER_ID
  )
  local payload_body = generic_body.GenericBody(data)
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

local function rgb_to_bin(r, g, b)
  local x, y = utils.rgb_to_xy(r, g, b)
  x = utils.round(x * 4095 / 0.7347)
  y = utils.round(y * 4095 / 0.8431)
  return string.pack(">I3", ((x & 0xff) << 16) + ((y & 0xf) << 12) + (x & 0xf00) + (y >> 4))
end

local function send_gradient(device)
  local hue1 = device:get_latest_state("color1", capabilities.colorControl.ID, capabilities.colorControl.hue.NAME) % 100
  local hue2 = device:get_latest_state("color2", capabilities.colorControl.ID, capabilities.colorControl.hue.NAME) % 100
  local hue3 = device:get_latest_state("color3", capabilities.colorControl.ID, capabilities.colorControl.hue.NAME) % 100
  local sat1 = device:get_latest_state("color1", capabilities.colorControl.ID, capabilities.colorControl.saturation.NAME)
  local sat2 = device:get_latest_state("color2", capabilities.colorControl.ID, capabilities.colorControl.saturation.NAME)
  local sat3 = device:get_latest_state("color3", capabilities.colorControl.ID, capabilities.colorControl.saturation.NAME)
  
  local r1, g1, b1 = utils.hsv_to_rgb(0.01 * hue1, 0.01 * sat1)
  local r2, g2, b2 = utils.hsv_to_rgb(0.01 * hue2, 0.01 * sat2)
  local r3, g3, b3 = utils.hsv_to_rgb(0.01 * hue3, 0.01 * sat3)
  
  local colors = rgb_to_bin(r1, g1, b1) .. rgb_to_bin((r1+r2)/2, (g1+g2)/2, (b1+b2)/2) .. rgb_to_bin(r2, g2, b2) .. rgb_to_bin((r2+r3)/2, (g2+g3)/2, (b2+b3)/2) .. rgb_to_bin(r3, g3, b3)
  send_hue_command(device, "\x50\x01\x04\x00\x13\x50\x00\x00\x00" .. colors .. "\x28\x00")
end

----------------------------------------------------------------------

local function set_color_temperature_handler(driver, device, cmd)
  colorTemperature_defaults.set_color_temperature(driver, device, cmd)
  device.thread:call_with_delay(1, function(d)
    device:send(clusters.ColorControl.attributes.ColorTemperatureMireds:read(device))
  end)
end

local function set_color_handler(driver, device, cmd)
  if cmd.component == "main" then
    colorControl_defaults.set_color(driver, device, cmd)
  else
    device:emit_component_event(device.profile.components[cmd.component], capabilities.colorControl.hue(cmd.args.color.hue))
    device:emit_component_event(device.profile.components[cmd.component], capabilities.colorControl.saturation(cmd.args.color.saturation))
    send_gradient(device)
  end
end

local function momentary_push_handler(driver, device, cmd)
  send_gradient(device)
end

----------------------------------------------------------------------

local function do_configure(self, device)
  device:refresh()
  device:configure()
end

local function device_added(driver, device)
  for _, comp in ipairs({"color1", "color2", "color3"}) do
    device:emit_component_event(device.profile.components[comp], capabilities.colorControl.hue(0))
    device:emit_component_event(device.profile.components[comp], capabilities.colorControl.saturation(0))
  end
end

----------------------------------------------------------------------

local zigbee_driver_template = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.colorControl,
    capabilities.colorTemperature,
    capabilities.momentary
  },
  capability_handlers = {
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = set_color_temperature_handler
    },
    [capabilities.colorControl.ID] = {
      [capabilities.colorControl.commands.setColor.NAME] = set_color_handler
    },
    [capabilities.momentary.ID] = {
      [capabilities.momentary.commands.push.NAME] = momentary_push_handler
    }
  },
  lifecycle_handlers = {
    doConfigure = do_configure,
    added = device_added
  },
  health_check = false
}

defaults.register_for_default_handlers(zigbee_driver_template,
  zigbee_driver_template.supported_capabilities)
local hue_gradient_light = ZigbeeDriver("hue_gradient_light", zigbee_driver_template)
hue_gradient_light:run()