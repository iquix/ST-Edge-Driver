
-- Galaxy Home Music Switch ver 0.2.0
-- Copyright 2021-2026 Jaewon Park (iquix)
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


-- require st provided libraries
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "socket"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local log = require "log"

-- require custom handlers from driver package
local discovery = require "discovery"


-----------------------------------------------------------------
-- command functions
-----------------------------------------------------------------

function switch_off_handler(driver, device, command)
  log.info(send(device, "?stop"))
  device:emit_event(capabilities.switch.switch.off())
end

function switch_on_handler(driver, device, command)
  if (device.preferences.mediauri ~= nil) and (device.preferences.mediauri ~= "http://") then
    playURI(device, device.preferences.mediauri)
  else
    log.error("media uri is not set. Please go to settings and setup media uri")
  end
  device:emit_event(capabilities.switch.switch.on())
  device.thread:call_with_delay(3, function(d)
    device:emit_event(capabilities.switch.switch.off())
  end)
end


-----------------------------------------------------------------
-- play
-----------------------------------------------------------------

function escape(s)
    return (string.gsub(s, "([^A-Za-z0-9_/@#:\\?\\.])", function(c)
        return string.format("%%%02x", string.byte(c))
    end))
end

function playURI(device, uri)
  if (device.preferences.ipAddress ~= nil) and (device.preferences.ipAddress ~= "192.168.0.0") then
    u = escape(uri)
    log.info("playURI() called with "..u)
    log.info(send(device, u))
    log.info(send(device, "?play"))
  else
    log.error("galaxyHome IP Address is not set. Please go to settings and setup galaxyHome IP Address.")
  end
end


-----------------------------------------------------------------
-- http function
-----------------------------------------------------------------

function send(device, s)
  local urn = "urn:schemas-upnp-org:service:AVTransport:1"
  local action
  local args
  local res_body = {}
  
  if s == "?play" then
    action = "Play"
    args = "<InstanceID>0</InstanceID><Speed>1</Speed>"
  elseif s == "?stop" then
    action = "Stop"
    args = "<InstanceID>0</InstanceID>"
  else
    action = "SetAVTransportURI"
    args = "<InstanceID>0</InstanceID><CurrentURI>"..s.."</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"
  end
  
  local data = '<?xml version="1.0" encoding="utf-8"?><s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:'..action..' xmlns:u="'..urn..'">'..args..'</u:'..action..'></s:Body></s:Envelope>'
  
  local _, code = http.request({
    method = "POST",
    url = "http://"..device.preferences.ipAddress..":9197/upnp/control/AVTransport1",
    sink = ltn12.sink.table(res_body),
    source = ltn12.source.string(data),
    headers = {
      ["HOST"] = device.preferences.ipAddress..":9197",
      ["Content-Type"] = "text/xml; charset=\"utf-8\"",
      ["SOAPAction"] = '"' .. urn .. '#' .. action .. '"',
      ["Content-Length"] = #data
    }
  })
  
  -- Handle response
  return code, table.concat(res_body)
end


-----------------------------------------------------------------
-- device creation
-----------------------------------------------------------------

local function create_new_device(driver)
  local metadata = {
    type = "LAN",
    device_network_id = "galxyhome-music-device-"..socket.gettime(),
    label = "Galaxy Home Music",
    profile = "galxayhome-music-switch",
    manufacturer = "iquix",
    model = "v1",
    vendor_provided_label = nil
  }
  assert(driver:try_create_device(metadata), "failed to create a new switch")
end

-----------------------------------------------------------------
-- lifecycle functions
-----------------------------------------------------------------

local function device_added(driver, device)
  log.info("[" .. device.id .. "] Adding new device")
  -- set a default state for each capability attribute
  device:emit_event(capabilities.switch.switch.off())
end

local function device_init(driver, device)
  log.info("[" .. device.id .. "] Initializing device")
  -- mark device as online so it can be controlled from the app
  device:online()
end

local function device_removed(driver, device)
  log.info("[" .. device.id .. "] Removing device")
end

local function device_info_changed(driver, device, event, args)
  log.info("[" .. device.id .. "] Info changed")
  if args.old_st_store.preferences.createDev == false and device.preferences.createDev == true then
    create_new_device(driver)
  end
end


-----------------------------------------------------------------
-- driver main
-----------------------------------------------------------------

local lan_driver = Driver("galaxyhome-music", {
  discovery = discovery.handle_discovery,
  lifecycle_handlers = {
    added = device_added,
    init = device_init,
    removed = device_removed,
    infoChanged = device_info_changed
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on_handler,
      [capabilities.switch.commands.off.NAME] = switch_off_handler,
    },
  }
})

lan_driver:run()
