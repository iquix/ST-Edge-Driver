-- mDNS Discovery Module for Chromecast Devices
-- : Uses mDNS discovery to find Chromecast devices on the local network
-- Copyright © 2026 Jaewon Park (iquix) / SmartThings
-- Licensed under the Apache License, Version 2.0

local mdns = require "st.mdns"
local socket = require "cosock.socket"
local validate_ipv4_string = (require "st.net_utils").validate_ipv4_string
local log = require "log"
local cast = require "chromecast"

local Discovery = {}
local joined_device = {}  -- Track devices currently being joined to avoid duplicates


-- === Helper Functions for mDNS responses ===

-- Helper: Parse TXT records into a key-value map
local function parse_txt_records(text_items)
    local records = {}
    for _, item in ipairs(text_items or {}) do
        -- Handle both raw byte arrays and strings
        local text = (type(item) == "table") and string.char(table.unpack(item)) or item
        local key, value = string.match(text, "([^=]+)=(.*)")
        if key then
            records[key] = value
        end
    end
    return records
end

-- Helper: Extract all service info from mDNS response into a structured map
local function extract_mdns_entities(discovery_responses)
    local entities = {}  -- Key: service_name or hostname

    -- 1. Process "found" items (high priority, usually contains everything)
    for _, found in pairs(discovery_responses.found or {}) do
        local name = found.service_info and found.service_info.name or (found.host_info and found.host_info.address)
        if name and found.host_info then
            local ip = found.host_info.address
            if ip and validate_ipv4_string(ip) then
                entities[name] = {
                    ip = ip,
                    port = found.host_info.port,
                    txt = {}
                }
                if found.txt and found.txt.text then
                    for _, raw_txt in pairs(found.txt.text) do
                        table.insert(entities[name].txt, raw_txt)
                    end
                end
            end
        end
    end

    -- 2. Supplement from answers/additional (fallback or updates)
    for _, records in ipairs({discovery_responses.answers, discovery_responses.additional}) do
        for _, record in pairs(records or {}) do
            local name = record.name
            if name then
                entities[name] = entities[name] or { txt = {} }
                if record.kind and record.kind.ARecord then
                    local ip = record.kind.ARecord.ipv4
                    if ip and validate_ipv4_string(ip) then
                        -- Only set if not already present (found items have priority)
                        entities[name].ip = entities[name].ip or ip
                    end
                elseif record.kind and record.kind.TxtRecord then
                    for _, txt in ipairs(record.kind.TxtRecord.text or {}) do
                        table.insert(entities[name].txt, txt)
                    end
                elseif record.kind and record.kind.SRVRecord then
                    -- Only set if not already present
                    entities[name].port = entities[name].port or record.kind.SRVRecord.port
                    -- SRV record often points to a target hostname ARecord
                    entities[name].target = record.kind.SRVRecord.target
                end
            end
        end
    end

    -- 3. Parse and Finalize
    for _, entity in pairs(entities) do
        -- Convert raw TXT list to key-value map
        entity.txt = parse_txt_records(entity.txt)
    end
    
    return entities
end

-- === Helper Functions for Chromecast device discovery ===

-- Helper: Build device info table for try_create_device
local function build_device_info(params)
    return {
        type = "LAN",
        device_network_id = "chromecast-" .. params.id,
        label = params.name,
        profile = "chromecast-audio",
        manufacturer = "Google",
        model = params.model,
        vendor_provided_label = params.name
    }
end

-- Helper: Set device fields from discovery cache after device is added
function Discovery.set_device_field(driver, device)
    log.info(string.format("[Discovery] set_device_field: dni=%s", device.device_network_id))
    local cache = driver.datastore.discovery_cache[device.device_network_id]
    
    if cache then
        device:set_field("device_ip", cache.ip, { persist = true })
        device:set_field("device_port", cache.port or cast.DEFAULT_CAST_PORT, { persist = true })
        log.info(string.format("[Discovery] Device configured: ip=%s, port=%d", cache.ip, cache.port or cast.DEFAULT_CAST_PORT))
        driver.datastore.discovery_cache[device.device_network_id] = nil
    else
        log.warn("[Discovery] No cache found for device: " .. device.device_network_id)
    end
end

-- Helper: Update device cache before creation
local function update_device_discovery_cache(driver, dni, params)
    log.info(string.format("[Discovery] Caching device: dni=%s, ip=%s, port=%d, name=%s", dni, params.ip, params.port, params.name))
    driver.datastore.discovery_cache[dni] = {
        ip = params.ip,
        port = params.port,
        device_info = build_device_info(params)
    }
end

-- Helper: Parse and validate discovered entity
local function parse_and_validate_entity(entity)
    local params, err = cast.parse_device_info(entity)
    -- Guard: Parsing failed
    if not params then
        if err then log.debug(string.format("[Discovery] Skipping invalid entity: %s", err)) end
        return nil
    end
    -- Filter: Skip group devices with invalid ports (default port 8009 is usually wrong for groups)
    if params.multizone_group and params.port == cast.DEFAULT_CAST_PORT then
        log.warn(string.format("[Discovery] Skipping group device with invalid port %s:%d", params.ip, params.port))
        return nil
    end
    -- Filter: Skip non-audio-capable devices
    if not params.audio_out then
        log.info(string.format("[Discovery] Skipping non-audio capable device: %s (%s) at %s:%d", params.name, params.id, params.ip, params.port))
        return nil
    end
    log.info(string.format("[Discovery] Found audio capable device: %s (%s) at %s:%d", params.name, params.id, params.ip, params.port))
    return params
end

-- Helper: Build table of discovered chromecast devices from mDNS response
local function find_devices()
    log.info("[Discovery] Starting mDNS discovery for " .. cast.MDNS_SERVICE_TYPE)
    local discovery_responses = mdns.discover(cast.MDNS_SERVICE_TYPE, cast.MDNS_DOMAIN) or {}
    local entities = extract_mdns_entities(discovery_responses)
    
    local devices = {}
    for _, entity in pairs(entities) do
        local params = parse_and_validate_entity(entity)
        if params then
            devices[params.id] = params
        end
    end

    return devices
end

-- Helper: Try to add a discovered device
local function try_add_device(driver, params)
    local dni = "chromecast-" .. params.id
    log.info(string.format("[Discovery] Trying to add device: dni=%s, ip=%s", dni, params.ip))
    
    update_device_discovery_cache(driver, dni, params)
    driver:try_create_device(driver.datastore.discovery_cache[dni].device_info)
    return true
end

-- === Discovery Module Functions ===

-- Main discovery handler called by lifecycle handlings
function Discovery.discovery_handler(driver, _, should_continue)
    log.info("[Discovery] Starting Chromecast discovery")
    
    while should_continue() do
        -- Get list of already known devices
        local known_devices = {}
        for _, device in pairs(driver:get_devices()) do
            known_devices[device.device_network_id] = device
        end
        
        -- Discover devices on network
        local found_devices = find_devices()
        
        -- Add unknown devices
        for device_id, params in pairs(found_devices) do
            local dni = "chromecast-" .. device_id
            if not known_devices[dni] and not joined_device[dni] then
                try_add_device(driver, params)
                joined_device[dni] = true
                log.info("[Discovery] Device creation triggered for: " .. dni)
            end
        end
        
        socket.sleep(1.5)
    end
    
    log.info("[Discovery] Ending Chromecast discovery")
end

-- Called when device is added
function Discovery.device_added(driver, device)
    log.info(string.format("[Discovery] Device added: %s", device.label))
    Discovery.set_device_field(driver, device)
    joined_device[device.device_network_id] = nil
end

-- Check and update device IP:Port via mDNS discovery
-- : Returns true if device is online, false otherwise
function Discovery.update_device_addr(device)
    local current_ip = device:get_field("device_ip")
    local current_port = device:get_field("device_port")
    
    local device_id = string.match(device.device_network_id, "chromecast%-(.+)")
    if not device_id then
        log.warn("[Discovery] Could not extract device_id from DNI: " .. device.device_network_id)
        device:offline()
        return false
    end
    
    log.info(string.format("[Discovery] Checking IP for device: %s (current: %s)", device_id, tostring(current_ip)))
    
    -- Run mDNS discovery
    local found_devices = find_devices()
    
    if found_devices[device_id] then
        local new_ip = found_devices[device_id].ip
        local new_port = found_devices[device_id].port
        
        if current_ip ~= new_ip then
            log.info(string.format("[Discovery] IP changed for %s: %s -> %s", device_id, tostring(current_ip), new_ip))
            device:set_field("device_ip", new_ip, { persist = true })
        end
        if current_port ~= new_port then
            log.info(string.format("[Discovery] Port changed for %s: %s -> %d", device_id, tostring(current_port), new_port))
            device:set_field("device_port", new_port, { persist = true })
        end
        device:online()
        return true
    else
        log.warn(string.format("[Discovery] Device not found on network: %s", device_id))
        device:offline()
        return false
    end
end

return Discovery