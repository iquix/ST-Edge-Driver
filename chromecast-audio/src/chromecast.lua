-- Chromecast Protocol Module
-- : Handles low-level Chromecast communication: protobuf encoding, SSL connection, and packet I/O
-- Copyright © 2026 Jaewon Park (iquix)
-- Licensed under the Apache License, Version 2.0

local socket = require "cosock.socket"
local ssl = require "cosock.ssl"
local json = require "st.json"
local validate_ipv4_string = (require "st.net_utils").validate_ipv4_string
local log = require "log"

local M = {}
local request_id_counter = 0

-- Chromecast Constants
M.MDNS_SERVICE_TYPE = "_googlecast._tcp"
M.MDNS_DOMAIN       = "local"
M.DEFAULT_CAST_PORT = 8009

-- Chromecast Protocol URNs
M.URN_CONNECTION = "urn:x-cast:com.google.cast.tp.connection"
M.URN_HEARTBEAT  = "urn:x-cast:com.google.cast.tp.heartbeat"
M.URN_RECEIVER   = "urn:x-cast:com.google.cast.receiver"
M.URN_MEDIA      = "urn:x-cast:com.google.cast.media"

-- Chromecast App IDs
M.APP_ID          = "CC1AD845"  -- Default Media Receiver
M.BACKDROP_APP_ID = "E8C28D3C"  -- Backdrop (screensaver), treat as no app

-- Chromecast Default Source and Destination IDs
M.DEFAULT_SOURCE_ID      = "sender-0"
M.DEFAULT_DESTINATION_ID = "receiver-0"

-- Constants for placeholders
M.SENTINEL_TRANSPORT_ID     = "__TRANSPORT_ID__"
M.SENTINEL_MEDIA_SESSION_ID = "__MEDIA_SESSION_ID__"

-- Chromecast Device Capabilities (Bit Flags)
-- Bit 0: VIDEO_OUT (0x01)
-- Bit 1: VIDEO_IN (0x02)
-- Bit 2: AUDIO_OUT (0x04)
-- Bit 3: AUDIO_IN (0x08)
-- Bit 5: MULTIZONE_GROUP (0x20)
M.CAPABILITY_VIDEO_OUT       = 0x01
M.CAPABILITY_VIDEO_IN        = 0x02
M.CAPABILITY_AUDIO_OUT       = 0x04
M.CAPABILITY_AUDIO_IN        = 0x08
M.CAPABILITY_MULTIZONE_GROUP = 0x20


-- === Protobuf Helpers ===

local function encode_varint(val)
    local res = {}
    while val > 127 do
        table.insert(res, string.char((val & 127) | 128))
        val = val >> 7
    end
    table.insert(res, string.char(val))
    return table.concat(res)
end

local function pb_field_string(field_num, str)
    local key = (field_num << 3) | 2
    return encode_varint(key) .. encode_varint(#str) .. str
end

local function pb_field_varint(field_num, val)
    local key = (field_num << 3) | 0
    return encode_varint(key) .. encode_varint(val)
end

local function create_cast_message(source_id, dest_id, namespace, payload_str)
    local pb = ""
    pb = pb .. pb_field_varint(1, 0)  -- protocol_version
    pb = pb .. pb_field_string(2, source_id)
    pb = pb .. pb_field_string(3, dest_id)
    pb = pb .. pb_field_string(4, namespace)
    pb = pb .. pb_field_varint(5, 0)  -- payload_type: STRING
    pb = pb .. pb_field_string(6, payload_str)
    return string.pack(">I4", #pb) .. pb
end

-- === Packet Helpers ===

-- Helper: Create SSL connection to Chromecast
local function create_connection(ip, port)
    if not (ip and validate_ipv4_string(ip)) then
        return nil, "Invalid IP address"
    end
    port = port or M.DEFAULT_CAST_PORT
    log.info("[Connect] Attempting TCP connection to " .. ip .. ":" .. port)
    local tcp = socket.tcp()
    tcp:settimeout(5)
    local res, err = tcp:connect(ip, port)
    if not res then 
        log.error("[Connect] TCP connect failed: " .. tostring(err))
        return nil, err 
    end
    
    local ssl_params = { mode = "client", protocol = "any", verify = "none", options = "all" }
    local conn, wrap_err = ssl.wrap(tcp, ssl_params)
    if not conn then 
        tcp:close()
        log.error("[Connect] SSL wrap failed: " .. tostring(wrap_err))
        return nil, wrap_err 
    end
    local succ, handshake_err = conn:dohandshake()
    if not succ then 
        conn:close()
        log.error("[Connect] SSL handshake failed: " .. tostring(handshake_err))
        return nil, handshake_err 
    end
    log.info("[Connect] Connection established successfully")
    return conn
end

-- Helper: Send a packet to the Chromecast
local function send_packet(conn, dest, namespace, data)
    if not dest then
        log.error("[TX] Cannot send command: Missing destination ID")
        return
    end

    -- Assign request ID if not already set
    if not data.requestId then
        request_id_counter = (request_id_counter < 0x7fffffff) and (request_id_counter + 1) or 1
        data.requestId = request_id_counter
    end

    -- Encode table to JSON string safely
    local json_payload, err = json.encode(data)
    if err then
        log.error("[TX] Failed to encode JSON payload: " .. tostring(err))
        return
    end

    -- [DEBUG] Log outgoing packets (excluding Heartbeat PING/PONG to reduce noise)
    if namespace ~= M.URN_HEARTBEAT then
        log.info(string.format("[TX] Src:%s -> Dest:%s | NS:%s | Payload:%s", M.DEFAULT_SOURCE_ID, dest, namespace, json_payload))
    end

    local packet = create_cast_message(M.DEFAULT_SOURCE_ID, dest, namespace, json_payload)
    local sent, send_err = conn:send(packet)
    if not sent then
        log.error("[TX] Socket send failed: " .. tostring(send_err))
    end
end

-- Helper: Receive a single Chromecast packet from the connection
local function receive_packet(conn)
    local header, recv_err = conn:receive(4)
    
    if header then
        local len = string.unpack(">I4", header)
        local body = conn:receive(len)
        if body then
            -- Decode protobuf message body to JSON
            local json_str = string.match(body, '({.*})')
            if not json_str then 
                return nil, nil, "no_json_payload"
            end
            local data, _, err = json.decode(json_str)
            if err then 
                log.error("[RX] JSON decode error: " .. tostring(err))
                return nil, json_str, "json_decode_error"
            end
            return data, json_str, nil
        end
        return nil, nil, "body_receive_failed"
    end
    if recv_err == "closed" then
        log.warn("[RX] Socket closed by remote")
    end
    return nil, nil, recv_err
end

-- Helper: Parse incoming Chromecast packet into message table
local function parse_packet(data)
    if not data then return nil end

    -- Ignore PONG / MULTIZONE_STATUS
    if data.type == "PING" then
        return { action = "PING" }
    elseif data.type == "PONG" or data.type == "MULTIZONE_STATUS" then
        return nil
    end

    -- Parse RECEIVER_STATUS
    if data.type == "RECEIVER_STATUS" and data.status then
        local result = {
            action = "RECEIVER_STATUS",
            volume = nil,
            muted = nil,
            app = nil
        }
        
        -- Extract volume info
        if data.status.volume then
            if data.status.volume.level then
                result.volume = math.floor(data.status.volume.level * 100 + 0.5)
            end
            if data.status.volume.muted ~= nil then
                result.muted = data.status.volume.muted
            end
        end

        -- Extract active app info (skip BACKDROP)
        if data.status.applications then
            for _, app in ipairs(data.status.applications) do
                if app.appId == M.BACKDROP_APP_ID then
                    -- Skip backdrop, treat as no app
                elseif app.appId == M.APP_ID or app.displayName then
                    result.app = {
                        transport_id = app.transportId,
                        session_id = app.sessionId,
                        app_id = app.appId,
                        app_name = app.displayName
                    }
                    break
                end
            end
        end
        
        return result
    end

    -- Parse MEDIA_STATUS
    if data.type == "MEDIA_STATUS" and data.status then
        for _, status in ipairs(data.status) do
            local result = {
                action = "MEDIA_STATUS",
                media_session_id = nil,
                player_state = nil,
                idle_reason = nil,
                is_loading = false,
                metadata = nil
            }
            
            -- Extract media session ID
            if status.mediaSessionId then
                result.media_session_id = math.floor(status.mediaSessionId)
            end
            
            -- Extract player state
            result.player_state = status.playerState
            result.idle_reason = status.idleReason
            
            -- Check for loading state
            if status.extendedStatus and status.extendedStatus.playerState == "LOADING" then
                result.is_loading = true
            end
            
            -- Extract metadata
            if status.media then
                result.metadata = {}
                if status.media.metadata then
                    local meta = status.media.metadata
                    result.metadata.title = meta.title
                    result.metadata.artist = meta.subtitle or meta.artist
                    result.metadata.album = meta.albumName
                    if meta.images and meta.images[1] then
                        result.metadata.album_art_url = meta.images[1].url
                    end
                end
            end
            
            return result  -- Return first valid status
        end
    end

    -- Return raw data for unknown message types (for logging)
    return { action = "UNKNOWN", raw = data }
end


-- Helper: Check if device has a specific capability from ca field
local function check_capability(ca, flag)
    return (ca & flag) ~= 0
end

-- === Module functions: Connection and message handling ===

-- Connect to Chromecast and perform initial protocol handshake
-- @param ip: Chromecast IP address
-- @param port: Chromecast port (optional, default: 8009)
-- Returns: connection object on success, nil and error on failure
function M.connect(ip, port)
    local conn, err = create_connection(ip, port)
    if not conn then
        return nil, err
    end
    
    -- Send initial CONNECT to Default Destination ID
    log.info("[Init] Sending CONNECT to ".. M.DEFAULT_DESTINATION_ID)
    send_packet(conn, M.DEFAULT_DESTINATION_ID, M.URN_CONNECTION, { type = "CONNECT" })
    
    return conn
end

-- Read Chromecast packet and return message table
-- @param conn: connection object
-- @param current_transport_id: current transport ID (to detect changes)
-- Returns: (message, nil) on success, (nil, error_string) on failure
function M.read_message(conn, current_transport_id)
    local packet_table, packet_json, recv_err = receive_packet(conn)
    if not packet_table then
        return nil, recv_err
    end
    
    local message = parse_packet(packet_table)
    
    -- Handle protocol-level responses
    if message then
        if message.action == "PING" then
            send_packet(conn, M.DEFAULT_DESTINATION_ID, M.URN_HEARTBEAT, { type = "PONG" })
        else
            -- Log non-trivial messages
            log.info(string.format("[RX] Type:%s | Data:%s", packet_table.type, packet_json))
            
            -- Connect to new app session and get status when transport_id changed
            if message.action == "RECEIVER_STATUS" and message.app and current_transport_id ~= message.app.transport_id then
                send_packet(conn, message.app.transport_id, M.URN_CONNECTION, { type = "CONNECT" })
                send_packet(conn, message.app.transport_id, M.URN_MEDIA, { type = "GET_STATUS" })
            end
        end
    end
    
    return message, nil
end

-- Send a command table to the Chromecast
-- @param conn: connection object
-- @param cmd: command table with {dest, namespace, data}
-- @param context: optional table with {transport_id, media_session_id} for resolving sentinels
function M.send_command(conn, cmd, context)
    context = context or {}
    -- Resolve Destination Sentinel
    if cmd.dest == M.SENTINEL_TRANSPORT_ID then
        cmd.dest = context.transport_id
    end
    -- Resolve Media Session Sentinel
    if cmd.data and cmd.data.mediaSessionId == M.SENTINEL_MEDIA_SESSION_ID then
        cmd.data.mediaSessionId = context.media_session_id
    end
    send_packet(conn, cmd.dest, cmd.namespace, cmd.data)
end

-- === Module functions: Command Builders ===
-- Returns: command tables {dest, namespace, data}

-- Heartbeat Commands
function M.ping()
    return {
        dest = M.DEFAULT_DESTINATION_ID,
        namespace = M.URN_HEARTBEAT,
        data = { type = "PING" }
    }
end

-- Status Query Commands
function M.get_receiver_status()
    return {
        dest = M.DEFAULT_DESTINATION_ID,
        namespace = M.URN_RECEIVER,
        data = { type = "GET_STATUS" }
    }
end

-- @param transport_id: transport ID to get media status from
function M.get_media_status(transport_id)
    return {
        dest = transport_id or M.SENTINEL_TRANSPORT_ID,
        namespace = M.URN_MEDIA,
        data = { type = "GET_STATUS" }
    }
end

-- Volume Commands
-- @param level: volume level (0-100)
function M.set_volume(level)
    return {
        dest = M.DEFAULT_DESTINATION_ID,
        namespace = M.URN_RECEIVER,
        data = { type = "SET_VOLUME", volume = { level = level / 100.0 } }
    }
end

-- @param muted: true to mute, false to unmute
function M.set_volume_muted(muted)
    return {
        dest = M.DEFAULT_DESTINATION_ID,
        namespace = M.URN_RECEIVER,
        data = { type = "SET_VOLUME", volume = { muted = muted } }
    }
end

-- App Commands
-- @param app_id: app ID to launch
function M.launch_app(app_id)
    app_id = app_id or M.APP_ID
    return {
        dest = M.DEFAULT_DESTINATION_ID,
        namespace = M.URN_RECEIVER,
        data = { type = "LAUNCH", appId = app_id }
    }
end

-- @param session_id: session ID to stop
function M.stop_app(session_id)
    return {
        dest = M.DEFAULT_DESTINATION_ID,
        namespace = M.URN_RECEIVER,
        data = { type = "STOP", sessionId = session_id }
    }
end

-- Media Playback Commands
function M.media_play()
    return {
        dest = M.SENTINEL_TRANSPORT_ID,
        namespace = M.URN_MEDIA,
        data = { type = "PLAY", mediaSessionId = M.SENTINEL_MEDIA_SESSION_ID }
    }
end

function M.media_pause()
    return {
        dest = M.SENTINEL_TRANSPORT_ID,
        namespace = M.URN_MEDIA,
        data = { type = "PAUSE", mediaSessionId = M.SENTINEL_MEDIA_SESSION_ID }
    }
end

function M.media_stop()
    return {
        dest = M.SENTINEL_TRANSPORT_ID,
        namespace = M.URN_MEDIA,
        data = { type = "STOP", mediaSessionId = M.SENTINEL_MEDIA_SESSION_ID }
    }
end

-- @param uri: media URI
-- @param content_type: media content type (optional, default: "audio/mp3")
-- @param stream_type: stream type (NONE/BUFFERED/LIVE) (optional, default: "BUFFERED")
function M.media_load(uri, content_type, stream_type)
    content_type = content_type or "audio/mp3"
    stream_type = stream_type or "BUFFERED"
    return {
        dest = M.SENTINEL_TRANSPORT_ID,
        namespace = M.URN_MEDIA,
        data = {
            type = "LOAD",
            media = { contentId = uri, contentType = content_type, streamType = stream_type },
            autoplay = true
        }
    }
end

-- Media Queue Control
function M.queue_next()
    return {
        dest = M.SENTINEL_TRANSPORT_ID,
        namespace = M.URN_MEDIA,
        data = { type = "QUEUE_UPDATE", jump = 1, mediaSessionId = M.SENTINEL_MEDIA_SESSION_ID }
    }
end

function M.queue_prev()
    return {
        dest = M.SENTINEL_TRANSPORT_ID,
        namespace = M.URN_MEDIA,
        data = { type = "QUEUE_UPDATE", jump = -1, mediaSessionId = M.SENTINEL_MEDIA_SESSION_ID }
    }
end

-- === Module functions: Discovery ===

-- Parse parsed discovery info into structured device parameters
-- @param entity: Discovery entity (must have .ip and .txt map)
-- Returns: params table with parsed fields, or nil + error reason
function M.parse_device_info(entity)
    if not (entity.ip and validate_ipv4_string(entity.ip)) then
        return nil, "invalid_or_missing_ip"
    end
    if type(entity.txt) ~= "table" then
        return nil, "invalid_txt_records"
    end
    if not entity.txt.id then
        return nil, "missing_device_id"
    end
        
    local ip = entity.ip
    local txt_records = entity.txt
    local device_id = txt_records.id
    local friendly_name = txt_records.fn or txt_records.n or "Chromecast"
    local model = txt_records.md or "Chromecast"
    local capability = tonumber(txt_records.ca) or M.CAPABILITY_AUDIO_OUT  -- default to audio-only (0x04) if not specified

    local params = {
        id = device_id,
        name = friendly_name,
        model = model,
        ca = capability,
        ip = entity.ip,
        port = entity.port or M.DEFAULT_CAST_PORT,
        audio_out = check_capability(capability, M.CAPABILITY_AUDIO_OUT),
        video_out = check_capability(capability, M.CAPABILITY_VIDEO_OUT),
        multizone_group = check_capability(capability, M.CAPABILITY_MULTIZONE_GROUP)
    }
    return params
end

return M