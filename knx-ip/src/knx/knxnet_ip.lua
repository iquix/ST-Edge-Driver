--- @module knx.knxnet_ip
--- KNXnet/IP Transport Layer Packet Framing
--- Provides stateless packet builders and parsers for KNXnet/IP Core and Tunneling services.

local utils = require "knx.utils"
local telegram = require "knx.telegram"

local knxnet_ip = {}

--- KNXnet/IP Service Type Identifiers (Bidirectional Enum)
local SERVICE_TYPE = utils.build_enum {
  SEARCH_REQUEST           = 0x0201,
  SEARCH_RESPONSE          = 0x0202,
  CONNECT_REQUEST          = 0x0205,
  CONNECT_RESPONSE         = 0x0206,
  CONNECTIONSTATE_REQUEST  = 0x0207,
  CONNECTIONSTATE_RESPONSE = 0x0208,
  DISCONNECT_REQUEST       = 0x0209,
  DISCONNECT_RESPONSE      = 0x020A,
  TUNNELING_REQUEST        = 0x0420,
  TUNNELING_ACK            = 0x0421,
}

knxnet_ip.SERVICE_TYPE = SERVICE_TYPE

--- KNXnet/IP Status / Error Codes (Bidirectional Enum)
--- Standard KNXnet/IP Core v01.03.02 & Tunneling v01.02 error codes
local ERROR_CODE = utils.build_enum {
  E_NO_ERROR              = 0x00,
  E_HOST_PROTOCOL_TYPE    = 0x01,
  E_VERSION_NOT_SUPPORTED = 0x02,
  E_SEQUENCE_NUMBER       = 0x04,
  E_CONNECTION_ID         = 0x21,
  E_CONNECTION_TYPE       = 0x22,
  E_CONNECTION_OPTION     = 0x23,
  E_NO_MORE_CONNECTIONS   = 0x24,
  E_DATA_CONNECTION       = 0x26,
  E_KNX_CONNECTION        = 0x27,
  E_TUNNELING_LAYER       = 0x29,
}

knxnet_ip.ERROR_CODE = ERROR_CODE

--- KNXnet/IP Supported Service Family Identifiers (Bidirectional Enum)
local SERVICE_FAMILY = utils.build_enum {
  CORE              = 0x02,
  DEVICE_MANAGEMENT = 0x03,
  TUNNELING         = 0x04,
  ROUTING           = 0x05,
  REMOTE_LOGGING    = 0x06,
  REMOTE_CONFIG     = 0x07,
  OBJECT_SERVER     = 0x08,
}

knxnet_ip.SERVICE_FAMILY = SERVICE_FAMILY

--- Standard KNXnet/IP port (IANA assigned UDP port 3671)
knxnet_ip.DEFAULT_PORT = 3671


------------------------------------------------------------------------
-- HPAI (HOST PROTOCOL ADDRESS INFORMATION) - INTERNAL
------------------------------------------------------------------------

--- Default NAT mode HPAI: 0.0.0.0:0 (KNX Standard Vol 3/8/4 Section 2.3.2)
local HPAI_NAT_DEFAULT = "\x08\x01\x00\x00\x00\x00\x00\x00"

-- Build 8-byte HPAI structure from an "ip:port" endpoint string (defaults to NAT default)
local function build_hpai(endpoint)
  -- fast path for standard NAT route-back default (nil or "0.0.0.0:0")
  if not endpoint or endpoint == "0.0.0.0:0" then
    return HPAI_NAT_DEFAULT
  end

  local o1, o2, o3, o4, port = endpoint:match("^(%d+)%.(%d+)%.(%d+)%.(%d+):(%d+)$")
  if not o1 then return nil end
  return string.pack(">BBBBBB>I2", 0x08, 0x01, tonumber(o1), tonumber(o2), tonumber(o3), tonumber(o4), tonumber(port))
end

-- Parse 8-byte HPAI binary structure into "ip:port" endpoint string
local function parse_hpai(bytes, offset)
  if not bytes or #bytes < (offset or 1) + 7 then return nil end
  local len, proto, o1, o2, o3, o4, port = string.unpack(">BBBBBB>I2", bytes, offset or 1)
  if len ~= 0x08 or proto ~= 0x01 then return nil end
  return string.format("%d.%d.%d.%d:%d", o1, o2, o3, o4, port)
end


------------------------------------------------------------------------
-- PACKET HEADER (0x0610)
------------------------------------------------------------------------

--- Parse 6-byte KNXnet/IP packet header
--- @param bytes string|nil Raw UDP packet bytes received
--- @return table|nil header { header_len, version, service_type, total_len }, string|nil err
function knxnet_ip.parse_header(bytes)
  if not bytes or #bytes < 6 then
    return nil, "Packet too short for KNXnet/IP header"
  end

  local header_len, version, service_type, total_len = string.unpack(">BB>I2>I2", bytes)
  if header_len ~= 0x06 or version ~= 0x10 then
    return nil, string.format("Invalid KNXnet/IP header: len=0x%02X, ver=0x%02X", header_len, version)
  end

  return {
    header_len   = header_len,
    version      = version,
    service_type = service_type,
    total_len    = total_len,
  }
end


------------------------------------------------------------------------
-- DISCOVERY (0x0201 / 0x0202)
------------------------------------------------------------------------

--- Build KNXnet/IP Search Request packet (0x0201)
--- @param local_endpoint string|nil Local discovery endpoint "ip:port" or 8-byte HPAI (defaults to "0.0.0.0:0")
--- @return string Binary packet
function knxnet_ip.build_search_req(local_endpoint)
  return string.pack(
    ">BB>I2>I2c8",
    0x06, 0x10,
    SERVICE_TYPE.SEARCH_REQUEST,
    0x000e, -- 14 bytes total
    build_hpai(local_endpoint)
  )
end

--- Parse KNXnet/IP Search Response packet (0x0202)
--- @param bytes string|nil Raw UDP packet bytes received
--- @param sender_ip string|nil IP address of responding gateway
--- @param sender_port number|nil Port of responding gateway
--- @return table|nil res Discovered gateway record, string|nil err
function knxnet_ip.parse_search_res(bytes, sender_ip, sender_port)
  if not bytes or #bytes < 14 then
    return nil, "Incomplete Search Response packet"
  end

  local header, err = knxnet_ip.parse_header(bytes)
  if not header then
    return nil, err
  end

  if header.service_type ~= SERVICE_TYPE.SEARCH_RESPONSE then
    return nil, string.format("Invalid service type: 0x%04X (expected SEARCH_RESPONSE 0x0202)", header.service_type)
  end

  local ctrl_endpoint = parse_hpai(bytes, 7)
  if not ctrl_endpoint then
    return nil, "Invalid Control Endpoint HPAI in Search Response"
  end

  local cursor = 15
  local device_info = nil
  local supported_services = nil

  while cursor < #bytes do
    local dib_len, dib_type = bytes:byte(cursor, cursor + 1)
    local next_cursor = cursor + dib_len
    if dib_len < 2 or next_cursor > #bytes + 1 then
      break
    end

    if dib_type == 0x01 then
      -- Device Information DIB (Standard size: 54 bytes; some hardware pad to 56 bytes)
      if dib_len >= 54 then
        local medium, device_status, individual_address_raw, project_install_id,
              serial_number_raw, multicast_ip_raw, mac_address_raw, device_name_raw =
          string.unpack(">BBc2>I2c6c4c6c30", bytes, cursor + 2)

        device_info = {
          medium             = medium,
          device_status      = device_status,
          individual_address = telegram.bytes_to_individual_addr(individual_address_raw),
          project_install_id = project_install_id,
          serial_number      = utils.bytes_to_hex(serial_number_raw),
          multicast_ip       = string.format("%d.%d.%d.%d", multicast_ip_raw:byte(1, 4)),
          mac                = string.format("%02X:%02X:%02X:%02X:%02X:%02X", mac_address_raw:byte(1, 6)),
          device_name        = device_name_raw:match("^[^%z]+"),
        }
      end
    elseif dib_type == 0x02 then
      -- Supported Service Families DIB (maps family_id -> version)
      supported_services = {}
      for sc = cursor + 2, cursor + dib_len - 2, 2 do
        local family_id, version = bytes:byte(sc, sc + 1)
        supported_services[family_id] = version
      end
    end

    cursor = next_cursor
  end

  device_info = device_info or {}

  return {
    addr               = ctrl_endpoint,
    device_name        = device_info.device_name,
    serial_number      = device_info.serial_number,
    mac                = device_info.mac,
    individual_address = device_info.individual_address,
    project_install_id = device_info.project_install_id,
    multicast_ip       = device_info.multicast_ip,
    medium             = device_info.medium,
    device_status      = device_info.device_status,
    supported_services = supported_services or {},
    sender_ip          = sender_ip,
    sender_port        = sender_port,
  }
end


------------------------------------------------------------------------
-- CONNECTION MANAGEMENT (0x0205 / 0x0206)
------------------------------------------------------------------------

--- Build KNXnet/IP Connection Request packet (0x0205)
--- @param control_endpoint string|nil Control endpoint "ip:port" or 8-byte HPAI (defaults to "0.0.0.0:0")
--- @param data_endpoint string|nil Data endpoint "ip:port" or 8-byte HPAI (defaults to "0.0.0.0:0")
--- @return string Binary packet
function knxnet_ip.build_connect_req(control_endpoint, data_endpoint)
  return string.pack(
    ">BB>I2>I2c8c8c4",
    0x06, 0x10,
    SERVICE_TYPE.CONNECT_REQUEST,
    0x001a, -- 26 bytes total
    build_hpai(control_endpoint),
    build_hpai(data_endpoint),
    "\x04\x04\x02\x00" -- Tunnel connection, UDP
  )
end

--- Parse KNXnet/IP Connection Response packet (0x0206)
--- @param bytes string|nil Raw packet bytes received
--- @return table|nil res { status, channel_id }, string|nil err
function knxnet_ip.parse_connect_res(bytes)
  if not bytes or #bytes < 8 then
    return nil, "Incomplete Connection Response packet"
  end

  local channel_id, status = bytes:byte(7, 8)
  return {
    status     = status,
    channel_id = channel_id,
  }
end


------------------------------------------------------------------------
-- CONNECTION STATE / HEARTBEAT (0x0207 / 0x0208)
------------------------------------------------------------------------

--- Build KNXnet/IP ConnectionState Request packet (0x0207, Heartbeat)
--- @param channel_id number Communication channel ID
--- @param control_endpoint string|nil Control endpoint "ip:port" or 8-byte HPAI (defaults to "0.0.0.0:0")
--- @return string Binary packet
function knxnet_ip.build_connstate_req(channel_id, control_endpoint)
  return string.pack(
    ">BB>I2>I2BBc8",
    0x06, 0x10,
    SERVICE_TYPE.CONNECTIONSTATE_REQUEST,
    0x0010, -- 16 bytes total
    channel_id,
    0x00,    -- Reserved
    build_hpai(control_endpoint)
  )
end

--- Parse KNXnet/IP ConnectionState Response packet (0x0208, Heartbeat Response)
--- @param bytes string|nil Raw packet bytes received
--- @return table|nil res { channel_id, status }, string|nil err
function knxnet_ip.parse_connstate_res(bytes)
  if not bytes or #bytes < 8 then
    return nil, "Incomplete ConnectionState Response packet"
  end

  local channel_id, status = bytes:byte(7, 8)
  return {
    channel_id = channel_id,
    status     = status,
  }
end


------------------------------------------------------------------------
-- TUNNELING (0x0420 / 0x0421)
------------------------------------------------------------------------

--- Build KNXnet/IP Tunneling Request packet (0x0420)
--- @param channel_id number Communication channel ID
--- @param sequence number 8-bit sequence counter
--- @param cemi_frame string Binary cEMI frame
--- @return string|nil packet Binary packet, string|nil err
function knxnet_ip.build_tunnel_req(channel_id, sequence, cemi_frame)
  if not cemi_frame then
    return nil, "Missing cEMI frame"
  end

  local total_length = 10 + #cemi_frame
  return string.pack(
    ">BB>I2>I2BBBB",
    0x06, 0x10,
    SERVICE_TYPE.TUNNELING_REQUEST,
    total_length,
    0x04, channel_id, sequence & 0xff, 0x00
  ) .. cemi_frame
end

--- Parse KNXnet/IP Tunneling Request packet (0x0420)
--- @param bytes string|nil Raw UDP packet bytes received
--- @return table|nil req { channel_id, sequence, cemi_frame }, string|nil err
function knxnet_ip.parse_tunnel_req(bytes)
  if not bytes or #bytes < 10 then
    return nil, "Incomplete Tunneling Request packet"
  end

  local struct_len, channel_id, sequence = bytes:byte(7, 9)

  return {
    channel_id = channel_id,
    sequence   = sequence,
    cemi_frame = bytes:sub(7 + struct_len),
  }
end

--- Build KNXnet/IP Tunneling ACK packet (0x0421)
--- @param channel_id number Communication channel ID
--- @param sequence number 8-bit sequence counter being acknowledged
--- @param status number|nil Status code (default: 0x00 success)
--- @return string Binary packet
function knxnet_ip.build_tunnel_ack(channel_id, sequence, status)
  return string.pack(
    ">BB>I2>I2BBBB",
    0x06, 0x10,
    SERVICE_TYPE.TUNNELING_ACK,
    0x000a, -- 10 bytes total
    0x04, channel_id, sequence & 0xff, status or 0x00
  )
end

--- Parse KNXnet/IP Tunneling ACK packet (0x0421)
--- @param bytes string|nil Raw UDP packet bytes received
--- @return table|nil ack { channel_id, sequence, status }, string|nil err
function knxnet_ip.parse_tunnel_ack(bytes)
  if not bytes or #bytes < 10 then
    return nil, "Incomplete Tunneling ACK packet"
  end

  local channel_id, sequence, status = bytes:byte(8, 10)
  return {
    channel_id = channel_id,
    sequence   = sequence,
    status     = status,
  }
end


------------------------------------------------------------------------
-- DISCONNECT (0x0209 / 0x020A)
------------------------------------------------------------------------

--- Build KNXnet/IP Disconnect Request packet (0x0209)
--- @param channel_id number Communication channel ID
--- @param control_endpoint string|nil Control endpoint "ip:port" or 8-byte HPAI (defaults to "0.0.0.0:0")
--- @return string Binary packet
function knxnet_ip.build_disconnect_req(channel_id, control_endpoint)
  return string.pack(
    ">BB>I2>I2BBc8",
    0x06, 0x10,
    SERVICE_TYPE.DISCONNECT_REQUEST,
    0x0010, -- 16 bytes total
    channel_id, 0x00,
    build_hpai(control_endpoint)
  )
end

--- Parse KNXnet/IP Disconnect Request packet (0x0209)
--- @param bytes string|nil Raw UDP packet bytes received
--- @return table|nil req { channel_id, control_endpoint }, string|nil err
function knxnet_ip.parse_disconnect_req(bytes)
  if not bytes or #bytes < 16 then
    return nil, "Incomplete Disconnect Request packet"
  end

  return {
    channel_id       = bytes:byte(7),
    control_endpoint = parse_hpai(bytes, 9),
  }
end

--- Build KNXnet/IP Disconnect Response packet (0x020A)
--- @param channel_id number Communication channel ID
--- @param status number|nil Status code (default: 0x00 success)
--- @return string Binary packet
function knxnet_ip.build_disconnect_res(channel_id, status)
  return string.pack(
    ">BB>I2>I2BB",
    0x06, 0x10,
    SERVICE_TYPE.DISCONNECT_RESPONSE,
    0x0008, -- 8 bytes total
    channel_id, status or 0x00
  )
end

--- Parse KNXnet/IP Disconnect Response packet (0x020A)
--- @param bytes string|nil Raw UDP packet bytes received
--- @return table|nil res { channel_id, status }, string|nil err
function knxnet_ip.parse_disconnect_res(bytes)
  if not bytes or #bytes < 8 then
    return nil, "Incomplete Disconnect Response packet"
  end

  local channel_id, status = bytes:byte(7, 8)
  return {
    channel_id = channel_id,
    status     = status,
  }
end


------------------------------------------------------------------------
-- UNIFIED PACKET PARSER (FACTORY)
------------------------------------------------------------------------

--- Parse any incoming raw KNXnet/IP UDP packet into a structured table
--- @param bytes string|nil Raw UDP packet binary string
--- @return table|nil packet { service_type, ... }, string|nil err
function knxnet_ip.parse(bytes)
  local header, err = knxnet_ip.parse_header(bytes)
  if not header then
    return nil, err
  end

  local service_type = header.service_type
  local res, parse_err

  if service_type == SERVICE_TYPE.TUNNELING_REQUEST then
    res, parse_err = knxnet_ip.parse_tunnel_req(bytes)
  elseif service_type == SERVICE_TYPE.CONNECTIONSTATE_RESPONSE then
    res, parse_err = knxnet_ip.parse_connstate_res(bytes)
  elseif service_type == SERVICE_TYPE.TUNNELING_ACK then
    res, parse_err = knxnet_ip.parse_tunnel_ack(bytes)
  elseif service_type == SERVICE_TYPE.DISCONNECT_REQUEST then
    res, parse_err = knxnet_ip.parse_disconnect_req(bytes)
  elseif service_type == SERVICE_TYPE.CONNECT_RESPONSE then
    res, parse_err = knxnet_ip.parse_connect_res(bytes)
  elseif service_type == SERVICE_TYPE.DISCONNECT_RESPONSE then
    res, parse_err = knxnet_ip.parse_disconnect_res(bytes)
  elseif service_type == SERVICE_TYPE.SEARCH_RESPONSE then
    res, parse_err = knxnet_ip.parse_search_res(bytes)
  else
    return { service_type = service_type }
  end

  if not res then
    return nil, parse_err
  end

  res.service_type = service_type
  return res
end

return knxnet_ip
