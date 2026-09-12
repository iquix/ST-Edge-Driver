-- SmartThings Edge Driver for Chromecast Audio
-- Copyright © 2026 Jaewon Park (iquix)
-- Licensed under the Apache License, Version 2.0

local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"
local utils = require "st.utils"
local st_device = require "st.device"
local log = require "log"
local discovery = require "disco"
local cast = require "chromecast"
local tts = require "tts"

local send_command = cast.send_command  -- Local alias for frequently used module function

-- Forward declaration of functions
local device_task  
local load_media

-- Configuration Constants
local PING_INTERVAL       = 5    -- Heartbeat interval (seconds)
local POLL_INTERVAL       = 180  -- Status polling interval (seconds)
local SOCKET_TIMEOUT      = 5    -- Socket I/O timeout (seconds)
local RECONNECT_DELAY     = 5    -- Initial reconnect delay (seconds)
local MAX_RECONNECT_DELAY = 300  -- Maximum reconnect delay (seconds)
local INACTIVITY_TIMEOUT  = 30   -- Socket inactivity timeout (seconds)


-- === Helper Functions for Chromecast Command Channel ===

-- Helper: Send message to device's Tx channel safely
local function send_channel_message(device, msg)
    local tx_channel = device:get_field("tx_channel")
    if tx_channel then
        return pcall(tx_channel.send, tx_channel, msg)
    end
    return false
end

-- Helper: Add command to Tx channel
local function queue_command(device, cmd)
    log.info(string.format("[Queue] (%s) Command: NS=%s, Type=%s", device.label, cmd.namespace, cmd.data.type))
    if not send_channel_message(device, { type = "COMMAND", cmd = cmd }) then
        log.warn(string.format("[Queue] (%s) No active command channel", device.label))
    end
end

-- === Helper Functions for Generating SmartThings Capability Attribute Events ===

-- Helper: Turn off all child switches
local function turn_off_child_switches(device)
    local child_devices = device:get_child_list()
    if child_devices then
        for _, child in ipairs(child_devices) do
            child:emit_event(capabilities.switch.switch.off())
        end
    end
end

-- Helper: Set device to stopped state
local function emit_stopped_events(device)
    device:emit_event(capabilities.switch.switch.off())
    device:emit_event(capabilities.mediaPlayback.playbackStatus.stopped())
    device:emit_event(capabilities.audioTrackData.audioTrackData({title="", album="", mediaSource=""}))
    turn_off_child_switches(device)
end

-- === Helper Functions for Volume Restoration After Media Playback ===

-- Helper: Save current volume state for restoration later
local function snapshot_volume_state(device)
    local state = {}
    -- Save original volume
    local current_vol = device:get_latest_state("main", capabilities.audioVolume.ID, capabilities.audioVolume.volume.NAME)
    if current_vol then
        state.volume = current_vol
    end
    -- Save original mute state
    local current_mute = device:get_latest_state("main", capabilities.audioMute.ID, capabilities.audioMute.mute.NAME)
    if current_mute == "muted" then
        state.muted = true
    end
    if next(state) ~= nil then
        device:set_field("volume_state", state)
    end
end

-- Helper: Handle notification/child media playback completion
local function handle_media_playback_finished(device)
    local media_type = device:get_field("media_type")
    if media_type ~= "notification" and media_type ~= "child_switch" then
        return
    end

    -- Restore original volume and mute state
    local restore_state = device:get_field("volume_state")
    if restore_state then
        log.info(string.format("[Volume] (%s) Restoring - volume: %s, muted: %s", device.label, tostring(restore_state.volume), tostring(restore_state.muted)))
        if restore_state.volume then
            queue_command(device, cast.set_volume(restore_state.volume))
        end
        if restore_state.muted then
            queue_command(device, cast.set_volume_muted(true))
        end
        device:set_field("volume_state", nil)
    end

    -- Auto-stop receiver app
    log.info(string.format("[Auto-Stop] (%s) Media playback finished. Stopping receiver app.", device.label))
    local session_id = (device:get_field("active_app") or {}).session_id
    if session_id then
        queue_command(device, cast.stop_app(session_id))
    end
end

-- === Helper Functions for Handling Chromecast Messages ===

-- Helper: Handle media status updates
local function handle_media_status(device, result)
    -- Update media session ID
    if result.media_session_id then
        if result.media_session_id ~= device:get_field("media_session_id") then
            log.info(string.format("[Media] (%s) Updated mediaSessionId: %s", device.label, result.media_session_id))
            device:set_field("media_session_id", result.media_session_id)
        end
    end

    -- Handle player state
    if result.player_state == "PLAYING" then
        if device:get_field("media_type") ~= "notification" then  -- Ignore playback status for transient audio notifications
            device:emit_event(capabilities.mediaPlayback.playbackStatus.playing())
        end
    elseif result.player_state == "BUFFERING" then
        -- Do nothing
    elseif result.player_state == "PAUSED" then
        device:emit_event(capabilities.mediaPlayback.playbackStatus.paused())
    elseif result.player_state == "IDLE" then
        if result.is_loading then
            log.info(string.format("[Media] (%s) Loading media, with player state idle. Setting plabackStatus as buffering.", device.label))
            device:emit_event(capabilities.mediaPlayback.playbackStatus.buffering())
        else
            device:emit_event(capabilities.mediaPlayback.playbackStatus.stopped())
            turn_off_child_switches(device)
        end

        -- When media playback is finished
        if result.idle_reason == "FINISHED" then
            handle_media_playback_finished(device)
            device:set_field("media_type", nil)
        end
    else
        emit_stopped_events(device)
    end

    -- Update metadata unless it's empty or playing notification
    if result.metadata and next(result.metadata) ~= nil and device:get_field("media_type") ~= "notification" then
        local track_data = { mediaSource = (device:get_field("active_app") or {}).app_name or "Chromecast" }
        if result.metadata.title then
            track_data.title = result.metadata.title or " "
            track_data.artist = result.metadata.artist or " "
            track_data.album = result.metadata.album
            track_data.albumArtUrl = result.metadata.album_art_url
        elseif result.player_state ~= "BUFFERING" then
            track_data.title = " "
        end
        device:emit_event(capabilities.audioTrackData.audioTrackData(track_data))
    end
end

-- Helper: Update SmartThings capabilities based on parsed Chromecast message
local function handle_receiver_status(device, result)
    -- Update volume
    if result.volume then
        device:emit_event(capabilities.audioVolume.volume(result.volume))
    end
    if result.muted ~= nil then
        local mute = result.muted and capabilities.audioMute.mute.muted() or capabilities.audioMute.mute.unmuted()
        device:emit_event(mute)
    end

    -- Update app state
    if result.app then
        local prev_active_app = device:get_field("active_app") or {}
        device:set_field("active_app", result.app)
        if prev_active_app.transport_id ~= result.app.transport_id then
            log.info(string.format("[App] (%s) Found App: %s, TransportId: %s", device.label, result.app.app_name, result.app.transport_id))
            -- After Default Media Receiver is launched, load media when there's media to load.
            local media_to_load = device:get_field("media_to_load")
            if result.app.app_id == cast.APP_ID and media_to_load then
                device:set_field("media_to_load", nil)
                load_media(device, media_to_load.uri, media_to_load.volume, media_to_load.muted)
            end
        end
        device:emit_event(capabilities.switch.switch.on())
    else
        log.info(string.format("[App] (%s) No active app found in RECEIVER_STATUS", device.label))
        device:set_field("active_app", {})
        device:set_field("media_session_id", nil)
        emit_stopped_events(device)
    end
end

-- Helper: Update device status based on Chromecast messages
local function update_device_status(device, message)
    if not message then return end

    -- Handle media status updates
    if message.action == "MEDIA_STATUS" then
        handle_media_status(device, message)
    end

    -- Handle receiver status updates
    if message.action == "RECEIVER_STATUS" then
        handle_receiver_status(device, message)
    end
end

-- === Helper Functions for Device Task ===

-- Helper: Start device task (background loop)
local function start_device_task(driver, device)
    -- Terminate any previously running task for this device
    send_channel_message(device, { type = "TERMINATE" })

    local tx_channel, rx_channel = cosock.channel.new()
    device:set_field("tx_channel", tx_channel)

    local new_token = tostring(socket.gettime()) .. "-" .. tostring(math.random(1000,9999))
    device:set_field("task_token", new_token)

    log.info(string.format("[Lifecycle] (%s) Spawning new task with token: %s", device.label, new_token))
    cosock.spawn(function()
        device_task(driver, device, new_token, rx_channel)
    end, "chromecast_task_" .. device.id .. "_" .. new_token)
end

-- Helper: Main background loop for device task
device_task = function(driver, device, task_token, rx_channel)
    log.info(string.format("Starting background task for %s (Token: %s)", device.label, task_token))

    local conn = nil
    local last_ping = socket.gettime()
    local last_rx = socket.gettime()
    local last_poll = 0  -- Initialize to 0 so polling gets triggered immediately on connection

    local ping_interval       = PING_INTERVAL
    local poll_interval       = POLL_INTERVAL
    local inactivity_timeout  = INACTIVITY_TIMEOUT
    local reconnect_delay     = RECONNECT_DELAY
    local pending_msg         = nil

    while true do
        -- Wrap entire iteration in pcall to handle device deletion gracefully
        -- When device is deleted, calling methods on it throws an error
        local ok, result = pcall(function()
            -- 1. Handle tasks and connection
            -- Check for new task by checking token mismatch
            local current_token = device:get_field("task_token")
            if current_token ~= task_token then
                return "TERMINATE_TASK"  -- Clean exit signal
            end

            -- Get IP and port from stored device fields (set during discovery)
            local ip = device:get_field("device_ip")
            local port = device:get_field("device_port")

            -- 2. Connect if needed
            if not conn then
                log.info(string.format("[Session] (%s) Connecting to %s:%s", device.label, tostring(ip), tostring(port)))
                local err
                conn, err = cast.connect(ip, port)
                if conn then
                    conn:settimeout(SOCKET_TIMEOUT)
                    last_ping = socket.gettime()
                    last_rx = socket.gettime()
                    device:set_field("active_app", {})  -- Reset active_app on new connection
                    device:online()
                    reconnect_delay = RECONNECT_DELAY  -- Reset backoff on successful connection

                    -- Re-queue message received during reconnect wait
                    if pending_msg then
                        log.info(string.format("[Session] (%s) Re-injecting queued message on reconnect", device.label))
                        send_channel_message(device, pending_msg)
                        pending_msg = nil
                    end
                else
                    log.warn(string.format("[Session] (%s) Connection failed: %s", device.label, tostring(err)))
                    device:offline()
                    pending_msg = nil  -- Clear on failure to prevent infinite retry loop

                    -- Check if IP/Port changed before retrying
                    if discovery.update_device_addr(device) then
                        reconnect_delay = RECONNECT_DELAY  -- Reset backoff if device found
                    else
                        reconnect_delay = math.min(reconnect_delay * 2, MAX_RECONNECT_DELAY)  -- Exponential backoff
                    end
                    log.info(string.format("[Session] (%s) Retrying connection in %d seconds", device.label, reconnect_delay))

                    -- Wait for reconnect delay or early wake-up on channel message
                    local ready = socket.select({ rx_channel }, nil, reconnect_delay)
                    if ready and #ready > 0 then
                        local msg = rx_channel:receive()
                        if msg then
                            if msg.type == "TERMINATE" then
                                return "TERMINATE_TASK"
                            elseif msg.type == "COMMAND" then
                                log.info(string.format("[Session] (%s) Command received during backoff, retrying immediately", device.label))
                                pending_msg = msg
                            end
                        end
                    end
                    return "CONTINUE"  -- Skip rest of this iteration
                end
            end

            local now = socket.gettime()

            -- 3. Send Heartbeat (Every 5s - Required per spec)
            if now - last_ping >= ping_interval then
                send_command(conn, cast.ping())
                last_ping = now
            end

            -- 4. Poll Status (Every 180s - Backup)
            if now - last_poll >= poll_interval then
                log.info(string.format("[Poll] (%s) Polling device", device.label))
                send_command(conn, cast.get_receiver_status())
                local transport_id = (device:get_field("active_app") or {}).transport_id
                if transport_id then
                    send_command(conn, cast.get_media_status(transport_id))
                end
                last_poll = now
            end

            -- 5. Wait for socket activity or incoming channel command
            now = socket.gettime()
            local timeout = math.max(0, ping_interval - (now - last_ping))
            local ready_sockets = socket.select({ conn, rx_channel }, nil, timeout)
            local should_exit = false

            if ready_sockets and #ready_sockets > 0 then
                for _, s in ipairs(ready_sockets) do
                    if s == rx_channel then
                        -- Handle commands from channel
                        while true do
                            local msg = rx_channel:receive()
                            if msg then
                                if msg.type == "TERMINATE" then
                                    log.info(string.format("[Lifecycle] (%s) Received TERMINATE message. Exiting task.", device.label))
                                    should_exit = true
                                    break
                                elseif msg.type == "COMMAND" then
                                    local context = {
                                        transport_id = (device:get_field("active_app") or {}).transport_id,
                                        media_session_id = device:get_field("media_session_id")
                                    }
                                    send_command(conn, msg.cmd, context)
                                end
                            end
                            if #rx_channel.link.queue == 0 then break end
                        end
                    elseif s == conn then
                        -- Read incoming messages
                        local current_transport_id = (device:get_field("active_app") or {}).transport_id
                        local message, recv_err = cast.read_message(conn, current_transport_id)
                        if message then
                            last_rx = socket.gettime()
                            update_device_status(device, message)
                        elseif not recv_err then
                            -- Normal packet without status update (e.g. PONG, ignored protocol packets)
                            last_rx = socket.gettime()
                        elseif recv_err == "timeout" then
                            -- Normal timeout
                        elseif recv_err == "closed" then
                            log.warn(string.format("[Session] (%s) Connection closed by remote", device.label))
                            return "DISCONNECTED"
                        end
                    end
                end
            end

            -- 6. Check for socket inactivity timeout
            now = socket.gettime()
            if now - last_rx >= inactivity_timeout then
                log.warn(string.format("[Session] (%s) Inactivity timeout: no data received for %ds", device.label, inactivity_timeout))
                return "DISCONNECTED"
            end

            if should_exit then
                return "TERMINATE_TASK"
            end

            return "OK"
        end)

        -- Handle pcall result
        if ok then
            if result == "TERMINATE_TASK" then
                log.info(string.format("[Lifecycle] (%s) Task terminated", device.label))
                if conn then conn:close() end
                return
            elseif result == "DISCONNECTED" then
                log.warn(string.format("[Session] (%s) Resetting disconnected connection", device.label))
                if conn then conn:close() end
                conn = nil
                device:offline()
                discovery.update_device_addr(device)
            end
            -- When result is "CONTINUE", "OK", or "DISCONNECTED", loop continues
        else
            -- Unexpected error (not control flow)
            local err = result
            if conn then conn:close() end

            if device.id == nil then
                log.info(string.format("[Lifecycle] (%s) Task terminated: Device deleted", device.label or "Unknown"))
                return
            end
            log.error(string.format("[Lifecycle] Unexpected error on %s: %s. Respawning task in 5 seconds...", device.label, tostring(err)))
            socket.sleep(5)
            start_device_task(driver, device)
            return
        end
    end
end

-- === Helpers for Device Lifecycles and Capability Command Handlers ===

-- Helper: Create child music switch
local function create_music_switch(driver, device)
    local metadata = {
        type = "EDGE_CHILD",
        parent_assigned_child_key = "music-switch-"..socket.gettime(),
        label = device.label.." Music Switch",
        profile = "chromecast-music-switch",
        manufacturer = device.manufacturer or "Google",
        model = device.model or "Chromecast",
        parent_device_id = device.id
    }
    driver:try_create_device(metadata)
end

-- Helper: Load media assuming default receiver is already loaded
load_media = function(device, uri, volume, muted)
    if volume then
        log.info(string.format("[Volume] (%s) Setting notification - volume: %d", device.label, volume))
        queue_command(device, cast.set_volume(volume))
    end
    if muted == false then
        log.info(string.format("[Volume] (%s) Unmuting for notification", device.label))
        queue_command(device, cast.set_volume_muted(false))
    end
    queue_command(device, cast.media_load(uri))
end

-- Helper: Play media using default receiver
local function play_media(device, uri, volume, muted)
    if not uri or uri == "" or uri == "http://" then return false end
    -- Load media after launching Default Media Receiver app if not already launched
    local active_app = device:get_field("active_app") or {}
    local is_default_media_receiver_running = active_app.app_id == cast.APP_ID and active_app.transport_id
    if is_default_media_receiver_running then
        load_media(device, uri, volume, muted)
    else
        queue_command(device, cast.launch_app())
        device:set_field("active_app", {})
        device:set_field("media_to_load", {uri = uri, volume = volume, muted = muted})
    end
end

-- === Capability Handlers ===

-- Play media command handler
local function play_media_handler(driver, device, command)
    log.debug(string.format("[play_media_handler] (%s) command: %s", device.label, command.command))
    local uri = command.args.uri
    local volume
    local muted

    if command.command == "playTrackAndResume" or 
       command.command == "playTrackAndRestore" or
       command.command == "playNotification" or
       command.command == "speak" then
        -- Set media type to notification
        device:set_field("media_type", "notification")

        -- Save original volume and mute status
        snapshot_volume_state(device)
        
        -- Set notification volume and unmute (snapshot was taken above)
        volume = command.args.level or (device.preferences.audioNotiVolume ~= 0 and device.preferences.audioNotiVolume or nil)
        
        -- If muted is not explicitly handled here, play_media will use default behavior
        -- But for notifications we typically want to ensure unmuted if volume is set
        if volume then
             muted = false
        end
    else
        volume = command.args.level
    end
    
    -- Play media using default media receiver app
    play_media(device, uri, volume, muted)
end

-- Volume & Mute
local function volume_set_handler(driver, device, command)
    local volume = utils.clamp_value(command.args.volume, 0, 100)
    queue_command(device, cast.set_volume(volume))
end

local function volume_up_handler(driver, device, command)
    local current_vol = device:get_latest_state("main", capabilities.audioVolume.ID, capabilities.audioVolume.volume.NAME) or 0
    local new_vol = current_vol + 5
    volume_set_handler(driver, device, { args = { volume = new_vol } })
end

local function volume_down_handler(driver, device, command)
    local current_vol = device:get_latest_state("main", capabilities.audioVolume.ID, capabilities.audioVolume.volume.NAME) or 0
    local new_vol = current_vol - 5
    volume_set_handler(driver, device, { args = { volume = new_vol } })
end

local function mute_set_handler(driver, device, command)
    local state = command.args.state
    queue_command(device, cast.set_volume_muted(state == "muted"))
end

local function mute_handler(driver, device, command)
    mute_set_handler(driver, device, { args = { state = "muted" } })
end

local function unmute_handler(driver, device, command)
    mute_set_handler(driver, device, { args = { state = "unmuted" } })
end

local function switch_level_step_handler(driver, device, command)
    local current_vol = device:get_latest_state("main", capabilities.audioVolume.ID, capabilities.audioVolume.volume.NAME) or 0
    local new_vol = utils.round(current_vol + command.args.stepSize)
    volume_set_handler(driver, device, { args = { volume = new_vol } })
    device:emit_event(capabilities.audioVolume.volume(new_vol))
end

-- Media Playback
local function media_play_handler(driver, device, command)
    queue_command(device, cast.media_play())
end

local function media_pause_handler(driver, device, command)
    queue_command(device, cast.media_pause())
end

local function media_stop_handler(driver, device, command)
    queue_command(device, cast.media_stop())
end

-- Speech Synthesis
local function speak_handler(driver, device, command)
    local phrase = command.args.phrase
    if not phrase or phrase == "" then return end
    local tts_url = tts.get_url(phrase, device.preferences.speakLanguage)
    log.info(string.format("[SpeechSynthesis] (%s) Speaking: %s", device.label, phrase))
    -- Delegate to play_media_handler
    play_media_handler(driver, device, {
        command = "speak",
        args = { uri = tts_url, level = command.args.level }
    })
end

-- Media Track Control
local function media_next_handler(driver, device, command)
    queue_command(device, cast.queue_next())
end

local function media_prev_handler(driver, device, command)
    queue_command(device, cast.queue_prev())
end

-- Switch
local function switch_on_handler(driver, device, command)
    if (device.network_type == st_device.NETWORK_TYPE_CHILD) then
        -- Child device on - play media with parent device
        local parent = device:get_parent_device()
        if play_media(parent, device.preferences.mediaUri) then
            device:emit_event(capabilities.switch.switch.on())
            -- Set media type to child switch
            device:set_field("media_type", "child_switch")
        end
        return
    end

    -- launch the default media receiver app
    queue_command(device, cast.launch_app())
    device:emit_event(capabilities.switch.switch.on())
end

local function switch_off_handler(driver, device, command)
    if (device.network_type == st_device.NETWORK_TYPE_CHILD) then
        -- Child device off - Stop media playback on parent device
        local parent = device:get_parent_device()
        media_stop_handler(nil, parent, nil)
        device:emit_event(capabilities.switch.switch.off())
        return
    end

    -- Stop active session & app
    local session_id = (device:get_field("active_app") or {}).session_id
    if session_id then
        queue_command(device, cast.stop_app(session_id))
    end
    emit_stopped_events(device)
end

-- === Lifecycle Handlers ===

local function device_init(driver, device)
    log.info("device_init: Initializing device " .. device.label)
    if device.network_type == st_device.NETWORK_TYPE_CHILD then
        -- Child device init - no connection thread needed
        return
    end

    -- Compatibility fix
    device:emit_event(capabilities.mediaPlayback.supportedPlaybackCommands({"play", "pause", "stop"}))
    -- Check if device fields need to be set from discovery cache
    local device_ip = device:get_field("device_ip")
    if not device_ip then
        -- Try to get from discovery cache
        if driver.datastore.discovery_cache and driver.datastore.discovery_cache[device.device_network_id] then
            discovery.set_device_field(driver, device)
            device_ip = device:get_field("device_ip")
        end
    end
    -- Update IP/Port via mDNS discovery (handles changes)
    discovery.update_device_addr(device)
    -- Start device task
    device:set_field("task_token", nil)
    start_device_task(driver, device)
end

local function device_added(driver, device)
    log.info("device_added: " .. device.label)
    if device.network_type == st_device.NETWORK_TYPE_CHILD then
        -- Child device added
        device:emit_event(capabilities.switch.switch.off())
        return
    end

    device:emit_event(capabilities.switch.switch.off())
    device:emit_event(capabilities.mediaPlayback.playbackStatus.stopped())
    device:emit_event(capabilities.mediaPlayback.supportedPlaybackCommands({"play", "pause", "stop"}))
    device:emit_event(capabilities.audioVolume.volume(0))
    device:emit_event(capabilities.audioMute.mute.unmuted())
    device:emit_event(capabilities.audioTrackData.audioTrackData({title="", album="", mediaSource=""}))
    discovery.device_added(driver,device)
end

local function device_info_changed(driver, device, event, args)
    log.info("device_info_changed: " .. device.label)
    if device.network_type == st_device.NETWORK_TYPE_CHILD then
        -- Child device info changed
        return
    end

    if args.old_st_store.preferences.createDev == false and device.preferences.createDev == true then
        create_music_switch(driver, device)
    end
end

local function device_removed(_, device)
    log.info("device_removed: Stopping task for " .. device.label)
    if device.network_type == st_device.NETWORK_TYPE_CHILD then
        -- Child device removed
        return
    end

    device:set_field("task_token", nil)
    send_channel_message(device, { type = "TERMINATE" })
    device:set_field("tx_channel", nil)
end

-- === Driver Definition ===

local chromecast_driver = Driver("chromecast-audio-driver", {
    discovery = discovery.discovery_handler,
    lifecycle_handlers = {
        init = device_init,
        added = device_added,
        infoChanged = device_info_changed,
        removed = device_removed
    },
    capability_handlers = {
        -- Switch
        [capabilities.switch.ID] = {
            [capabilities.switch.commands.on.NAME] = switch_on_handler,
            [capabilities.switch.commands.off.NAME] = switch_off_handler,
        },
        -- Audio Notification
        [capabilities.audioNotification.ID] = {
            [capabilities.audioNotification.commands.playTrack.NAME] = play_media_handler,
            [capabilities.audioNotification.commands.playTrackAndResume.NAME] = play_media_handler,
            [capabilities.audioNotification.commands.playTrackAndRestore.NAME] = play_media_handler,
        },
        -- Speech Synthesis
        [capabilities.speechSynthesis.ID] = {
            [capabilities.speechSynthesis.commands.speak.NAME] = speak_handler,
        },
        -- Volume & Mute
        [capabilities.audioVolume.ID] = {
            [capabilities.audioVolume.commands.setVolume.NAME] = volume_set_handler,
            [capabilities.audioVolume.commands.volumeUp.NAME] = volume_up_handler,
            [capabilities.audioVolume.commands.volumeDown.NAME] = volume_down_handler,
        },
        [capabilities.statelessSwitchLevelStep.ID] = {
            [capabilities.statelessSwitchLevelStep.commands.stepLevel.NAME] = switch_level_step_handler,
        },
        [capabilities.audioMute.ID] = {
            [capabilities.audioMute.commands.setMute.NAME] = mute_set_handler,
            [capabilities.audioMute.commands.mute.NAME] = mute_handler,
            [capabilities.audioMute.commands.unmute.NAME] = unmute_handler,
        },
        -- Media Playback
        [capabilities.mediaPlayback.ID] = {
            [capabilities.mediaPlayback.commands.play.NAME] = media_play_handler,
            [capabilities.mediaPlayback.commands.pause.NAME] = media_pause_handler,
            [capabilities.mediaPlayback.commands.stop.NAME] = media_stop_handler,
        },
        -- Media Track Control
        [capabilities.mediaTrackControl.ID] = {
            [capabilities.mediaTrackControl.commands.nextTrack.NAME] = media_next_handler,
            [capabilities.mediaTrackControl.commands.previousTrack.NAME] = media_prev_handler,
        },
        -- Custom Capability: iquix.mediaPlayUri
        ["iquix.mediaPlayUri"] = {
            ["play"] = play_media_handler,
            ["playNotification"] = play_media_handler,
        }
    }
})

-- Initialize discovery cache datastore
if chromecast_driver.datastore.discovery_cache == nil then
    chromecast_driver.datastore.discovery_cache = {}
end

chromecast_driver:run()