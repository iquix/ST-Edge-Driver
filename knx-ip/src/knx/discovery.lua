--- @module knx.discovery
--- KNXnet/IP Interface Discovery Module
--- Multicast search (224.0.23.12:3671) over UDP using cosock.socket.

local socket = require "cosock.socket"
local knxnet_ip = require "knx.knxnet_ip"
local knx_utils = require "knx.utils"

local KnxDiscovery = {}

local KNX_MULTICAST_IP   = "224.0.23.12"
local KNX_MULTICAST_PORT = knxnet_ip.DEFAULT_PORT
local DEFAULT_TIMEOUT    = 3.0

-- Detect local IP address used to route to the KNX multicast group
local function get_local_ip()
  local probe = socket.udp()
  if not probe then
    return "0.0.0.0"
  end

  probe:setpeername(KNX_MULTICAST_IP, KNX_MULTICAST_PORT)
  local local_ip = probe:getsockname()
  probe:close()

  if not local_ip or local_ip == "127.0.0.1" then
    return "0.0.0.0"
  end

  return local_ip
end

--- Discover KNXnet/IP gateways on the local network via multicast SEARCH_REQUEST.
--- @param opts table|nil Options table:
---   - timeout: number (seconds to listen, default 3.0)
---   - on_device_found: function(device_record) callback triggered immediately when new device is discovered
---   - log: table logger (optional)
--- @return table found_devices List of discovered device records
function KnxDiscovery.discover(opts)
  opts = opts or {}
  local timeout = opts.timeout or DEFAULT_TIMEOUT
  local on_device_found = opts.on_device_found
  local log = opts.log or knx_utils.NOOP_LOGGER

  local sock = socket.udp()
  if not sock then
    log.warn("Failed to create UDP socket for KNX discovery")
    return {}
  end

  sock:setsockname("0.0.0.0", 0)
  local _, bound_port = sock:getsockname()
  local local_port = tonumber(bound_port) or 0
  local local_endpoint = string.format("%s:%d", get_local_ip(), local_port)

  local search_req = knxnet_ip.build_search_req(local_endpoint)
  local ok, send_err = sock:sendto(search_req, KNX_MULTICAST_IP, KNX_MULTICAST_PORT)
  if not ok then
    log.warn(string.format("Failed to broadcast KNX SEARCH_REQUEST: %s", tostring(send_err)))
    sock:close()
    return {}
  end

  local next_timeout = socket.gettime() + timeout
  local found_gateways = {}
  local found_devices = {}

  while true do
    local remaining = next_timeout - socket.gettime()
    if remaining <= 0 then
      break
    end

    sock:settimeout(remaining)
    local data, sender_ip, sender_port = sock:receivefrom()
    if not data then
      break
    end

    local record, err = knxnet_ip.parse_search_res(data, sender_ip, sender_port)
    if record then
      local endpoint = record.addr or (sender_ip and sender_port and string.format("%s:%d", sender_ip, sender_port))
      if endpoint and not found_gateways[endpoint] then
        found_gateways[endpoint] = record
        found_devices[#found_devices + 1] = record
        log.info(string.format("Discovered KNX gateway: %s at %s", record.device_name, endpoint))
        if on_device_found then
          on_device_found(record)
        end
      end
    elseif err then
      log.debug(string.format("Ignored non-search-response or malformed packet: %s", tostring(err)))
    end
  end

  sock:close()

  return found_devices
end

return KnxDiscovery
