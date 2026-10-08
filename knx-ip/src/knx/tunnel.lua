--- @module knx.tunnel
--- Pure, self-contained KNXnet/IP UDP Tunneling Client.
--- Driven by a Single Explicit FSM, Unified Single-Client Architecture,
--- and a Single-Exit Reactor Event Loop with in-loop atomic restart.
--- Zero dependency on SmartThings platform libraries.

local cosock = require "cosock"
local socket = require "cosock.socket"
local knxnet_ip = require "knx.knxnet_ip"
local cemi = require "knx.cemi"
local telegram = require "knx.telegram"
local KnxTelegramRx = telegram.KnxTelegramRx
local knx_utils = require "knx.utils"

--- @class KnxTunnel
---
--- Pure, self-contained KNXnet/IP UDP tunneling client driven by an explicit 4-state machine.
---
--- @field public state string Current connection lifecycle state
--- @field public host string|nil Target gateway IP
--- @field public port number|nil Target gateway port
--- @field public channel_id number|nil Active tunneling channel ID
local KnxTunnel = {}
KnxTunnel.__index = KnxTunnel

--- Formal Connection Lifecycle States (Minimal 4-State Machine)
local STATE = {
  STOPPED    = "STOPPED",
  CONNECTING = "CONNECTING",
  CONNECTED  = "CONNECTED",
  PROBING    = "PROBING",
}
KnxTunnel.STATE = STATE

--- Standardized Disconnect Reasons
local DISCONNECT_REASON = {
  INVALID_CONFIG    = "INVALID_CONFIG",
  USER_STOP         = "USER_STOP",
  CONNECT_TIMEOUT   = "CONNECT_TIMEOUT",
  CONNECT_REJECTED  = "CONNECT_REJECTED",
  HEARTBEAT_TIMEOUT = "HEARTBEAT_TIMEOUT",
  PEER_DISCONNECT   = "PEER_DISCONNECT",
  SOCKET_ERROR      = "SOCKET_ERROR",
}
KnxTunnel.DISCONNECT_REASON = DISCONNECT_REASON

--- Standardized Internal Domain Events
local EVENT = {
  TX            = "TX",
  STOP          = "STOP",
  RESTART       = "RESTART",
  TUNNEL_REQ    = "TUNNEL_REQ",
  TUNNEL_ACK    = "TUNNEL_ACK",
  CONNECT_RES   = "CONNECT_RES",
  HEARTBEAT_ACK = "HEARTBEAT_ACK",
  DISCONNECT    = "DISCONNECT",
  TIMEOUT       = "TIMEOUT",
}
local BIND_ADDR = "0.0.0.0"
local BIND_PORT = 0
local CONNECT_TIMEOUT = 10
local HEARTBEAT_INTERVAL = 30
local ACK_TIMEOUT = 10
local MAX_RETRIES = 3
local BASE_RECONNECT_DELAY = 3
local MAX_RECONNECT_DELAY = 60

-- Parse raw UDP datagram bytes into a normalized Domain Event (Stage 1)
local function parse_datagram(bytes)
  local packet, _ = knxnet_ip.parse(bytes)
  if not packet then
    return nil
  end

  local service_type = packet.service_type

  if service_type == knxnet_ip.SERVICE_TYPE.TUNNELING_REQUEST then
    return { type = EVENT.TUNNEL_REQ, packet = packet }
  elseif service_type == knxnet_ip.SERVICE_TYPE.CONNECTIONSTATE_RESPONSE then
    return { type = EVENT.HEARTBEAT_ACK, packet = packet }
  elseif service_type == knxnet_ip.SERVICE_TYPE.TUNNELING_ACK then
    return { type = EVENT.TUNNEL_ACK, packet = packet }
  elseif service_type == knxnet_ip.SERVICE_TYPE.CONNECT_RESPONSE then
    return { type = EVENT.CONNECT_RES, packet = packet }
  elseif service_type == knxnet_ip.SERVICE_TYPE.DISCONNECT_REQUEST then
    return { type = EVENT.DISCONNECT, packet = packet }
  end

  return nil
end

--- Table-Driven Domain Event Dispatcher (Stage 2)
local event_handlers = {
  [EVENT.TX] = function(client, event)
    if client:is_connected() then
      local tb, err = event.payload:serialize()
      if not tb then
        client.log.warn(string.format("[KnxTunnel] Failed to serialize telegram: %s", tostring(err)))
        return
      end
      local cf = cemi.encode(tb, cemi.MSG_CODE.L_DATA_REQ)
      local req = knxnet_ip.build_tunnel_req(client.channel_id, client.sequence, cf)
      client.sequence = (client.sequence + 1) & 0xFF
      local ok, send_err = client:_send_udp(req)
      if not ok then
        client.log.error(string.format("[KnxTunnel] Failed to send tunneling request: %s", tostring(send_err)))
        client:transition_to_state(STATE.STOPPED, DISCONNECT_REASON.SOCKET_ERROR)
      end
    end
  end,

  [EVENT.TUNNEL_REQ] = function(client, event)
    local packet = event.packet
    if client:is_connected() and packet.channel_id == client.channel_id then
      -- Immediate L4 transport acknowledgment
      client:_send_udp(knxnet_ip.build_tunnel_ack(client.channel_id, packet.sequence))

      -- Duplicate sequence filtering
      if packet.sequence == client.last_rx_sequence then
        client.log.debug(string.format("[KnxTunnel] Dropping duplicate tunneling request (seq: %d)", packet.sequence))
        return
      end
      client.last_rx_sequence = packet.sequence

      -- Active traffic proves gateway connectivity: recover from PROBING or extend heartbeat deadline
      if client.state == STATE.PROBING then
        client:transition_to_state(STATE.CONNECTED)
      else
        client.next_timeout = socket.gettime() + client.heartbeat_interval
        client.retry_count = 0
      end

      -- cEMI L_Data.ind decoding and application callback
      local cf = cemi.decode(packet.cemi_frame)
      if cf and cf.msg_code == cemi.MSG_CODE.L_DATA_IND then
        local rx = KnxTelegramRx.deserialize(cf.telegram_bytes)
        if rx then
          client:_invoke_callback("on_telegram", client.on_telegram, rx)
        end
      end
    end
  end,

  [EVENT.TUNNEL_ACK] = function(client, event)
    local packet = event.packet
    local status = packet.status
    -- E_CONNECTION_ID (0x21), E_TUNNELING_LAYER (0x29), or E_SEQUENCE_NUMBER (0x04)
    if status == knxnet_ip.ERROR_CODE.E_CONNECTION_ID
        or status == knxnet_ip.ERROR_CODE.E_TUNNELING_LAYER
        or status == knxnet_ip.ERROR_CODE.E_SEQUENCE_NUMBER then
      local err_name = knxnet_ip.ERROR_CODE[status] or string.format("0x%02X", status)
      client.log.warn(string.format("[KnxTunnel] Gateway rejected session/sequence (%s). Reconnecting...", err_name))
      client:transition_to_state(STATE.STOPPED, DISCONNECT_REASON.PEER_DISCONNECT)
    elseif status and status ~= knxnet_ip.ERROR_CODE.E_NO_ERROR then
      local err_name = knxnet_ip.ERROR_CODE[status] or string.format("0x%02X", status)
      client.log.warn(string.format("[KnxTunnel] Tunneling ACK error status from gateway: %s", err_name))
    end
  end,

  [EVENT.CONNECT_RES] = function(client, event)
    local packet = event.packet
    if client.state == STATE.CONNECTING and packet then
      if packet.status == knxnet_ip.ERROR_CODE.E_NO_ERROR and packet.channel_id then
        client.channel_id = packet.channel_id
        client.sequence = 0
        client.last_rx_sequence = nil
        client.log.info(string.format("[KnxTunnel] Connected to gateway (channel ID: %d)", packet.channel_id))
        client:transition_to_state(STATE.CONNECTED)
      else
        local err_name = knxnet_ip.ERROR_CODE[packet.status] or string.format("0x%02X", packet.status or -1)
        client.log.warn(string.format("[KnxTunnel] Connect rejected by gateway (status: %s)", err_name))
        client:transition_to_state(STATE.STOPPED, DISCONNECT_REASON.CONNECT_REJECTED)
      end
    end
  end,

  [EVENT.HEARTBEAT_ACK] = function(client, event)
    local packet = event.packet
    if client.state == STATE.PROBING and packet.channel_id == client.channel_id then
      if packet.status == knxnet_ip.ERROR_CODE.E_NO_ERROR then
        client:transition_to_state(STATE.CONNECTED)
      else
        local err_name = knxnet_ip.ERROR_CODE[packet.status] or string.format("0x%02X", packet.status or -1)
        client.log.warn(string.format("[KnxTunnel] Heartbeat rejected by gateway (status: %s)", err_name))
        client:transition_to_state(STATE.STOPPED, DISCONNECT_REASON.HEARTBEAT_TIMEOUT)
      end
    end
  end,

  [EVENT.DISCONNECT] = function(client, event)
    if event.packet and client.channel_id and event.packet.channel_id ~= client.channel_id then
      client.log.warn(string.format("[KnxTunnel] Ignored Disconnect Request with mismatched channel ID: %s (expected %s)", tostring(event.packet.channel_id), tostring(client.channel_id)))
      return
    end
    local reason = event.reason or DISCONNECT_REASON.PEER_DISCONNECT
    if event.packet and client.channel_id then
      pcall(client._send_udp, client, knxnet_ip.build_disconnect_res(client.channel_id))
    end
    client.channel_id = nil
    client.log.warn(string.format("[KnxTunnel] Disconnect received (reason: %s)", tostring(reason)))
    client:transition_to_state(STATE.STOPPED, reason)
  end,

  [EVENT.TIMEOUT] = function(client, _event)
    if client.state == STATE.CONNECTING then
      client.log.warn("[KnxTunnel] Connection handshake timed out")
      client:transition_to_state(STATE.STOPPED, DISCONNECT_REASON.CONNECT_TIMEOUT)
    elseif client.state == STATE.CONNECTED then
      client:transition_to_state(STATE.PROBING)
    elseif client.state == STATE.PROBING then
      client.retry_count = client.retry_count + 1
      if client.retry_count <= client.max_retries then
        client.log.warn(string.format("[KnxTunnel] Heartbeat missed, sending probe retry %d/%d", client.retry_count, client.max_retries))
        client:_send_probe()
      else
        client.log.error("[KnxTunnel] Heartbeat failed after max retries")
        if client.channel_id then
          pcall(client._send_udp, client, knxnet_ip.build_disconnect_req(client.channel_id))
          client.channel_id = nil
        end
        client:transition_to_state(STATE.STOPPED, DISCONNECT_REASON.HEARTBEAT_TIMEOUT)
      end
    end
  end,

  [EVENT.STOP] = function(client, event)
    client:cancel_reconnect_timer()
    if client.channel_id then
      pcall(client._send_udp, client, knxnet_ip.build_disconnect_req(client.channel_id))
      client.channel_id = nil
    end
    local reason = event.reason or DISCONNECT_REASON.USER_STOP
    client.log.debug(string.format("[KnxTunnel] Stopping session (%s)", tostring(reason)))
    client:transition_to_state(STATE.STOPPED, reason)
  end,

  [EVENT.RESTART] = function(client, event)
    client:cancel_reconnect_timer()
    client.log.info(string.format("[KnxTunnel] In-Loop Atomic Restart initiated to %s:%d", tostring(event.host), tostring(event.port)))
    -- 1. Gracefully release existing channel slot on gateway
    if client.channel_id then
      pcall(client._send_udp, client, knxnet_ip.build_disconnect_req(client.channel_id))
    end
    -- 2. Close active socket
    if client.sock then
      pcall(client.sock.close, client.sock)
      client.sock = nil
    end
    -- 3. Reset session parameters
    client.channel_id = nil
    client.sequence = 0
    client.last_rx_sequence = nil
    client.retry_count = 0
    client:reset_reconnect_delay()
    client.host = event.host
    client.port = event.port

    -- 4. Open and bind new UDP socket
    local new_sock = socket.udp()
    if not new_sock or not new_sock:setsockname(BIND_ADDR, BIND_PORT) then
      if new_sock then pcall(new_sock.close, new_sock) end
      client.log.error("[KnxTunnel] Failed to rebind local UDP socket during restart")
      client:transition_to_state(STATE.STOPPED, DISCONNECT_REASON.SOCKET_ERROR)
      return
    end
    new_sock:settimeout(0)
    client.sock = new_sock

    -- 5. Transition to CONNECTING and transmit new 0x0205 Connect Request
    client:transition_to_state(STATE.CONNECTING)
    client.log.debug(string.format("[KnxTunnel] Sending Connection Request to %s:%d", client.host, client.port))
    client:_send_udp(knxnet_ip.build_connect_req())
    client.next_timeout = socket.gettime() + client.connect_timeout
  end,
}

-- Dispatch an internal domain event through the table-driven dispatcher (Stage 2)
local function dispatch_event(client, event)
  if not event then return end
  local handler = event_handlers[event.type]
  if handler then
    handler(client, event)
  end
end

--- Instantiate a new KnxTunnel client
--- @param cls table Class table
--- @param callbacks table { on_connect = fn(), on_telegram = fn(rx), on_disconnect = fn(reason), on_state_change = fn(state) }
--- @param opts table|nil { log = logger, connect_timeout = 10, heartbeat_interval = 30, ack_timeout = 10, max_retries = 3 }
--- @return KnxTunnel
function KnxTunnel.init(cls, callbacks, opts)
  local self = setmetatable({}, cls)
  callbacks = callbacks or {}
  opts = opts or {}

  self.on_connect      = callbacks.on_connect
  self.on_telegram     = callbacks.on_telegram
  self.on_disconnect   = callbacks.on_disconnect
  self.on_state_change = callbacks.on_state_change

  self.opts = opts
  self.log = opts.log or knx_utils.NOOP_LOGGER

  self.state = STATE.STOPPED
  self.channel_id = nil
  self.host = nil
  self.port = nil

  self.sender = nil
  self.receiver = nil
  self.sock = nil

  self.sequence = 0
  self.last_rx_sequence = nil
  self.retry_count = 0
  self.next_timeout = 0
  self.should_exit = false
  self.disconnect_reason = DISCONNECT_REASON.USER_STOP

  self.connect_timeout = opts.connect_timeout or CONNECT_TIMEOUT
  self.heartbeat_interval = opts.heartbeat_interval or HEARTBEAT_INTERVAL
  self.ack_timeout = opts.ack_timeout or ACK_TIMEOUT
  self.max_retries = opts.max_retries or MAX_RETRIES
  self.base_reconnect_delay = opts.base_reconnect_delay or BASE_RECONNECT_DELAY
  self.max_reconnect_delay = opts.max_reconnect_delay or MAX_RECONNECT_DELAY
  self.reconnect_delay = self.base_reconnect_delay
  self.reconnect_timer = nil
  self.cancel_timer_fn = nil

  return self
end

function KnxTunnel:_invoke_callback(name, cb, ...)
  if not cb then return end
  local ok, err = xpcall(cb, debug.traceback, ...)
  if not ok then
    self.log.error(string.format("[KnxTunnel] Callback '%s' failed:\n%s", name, tostring(err)))
  end
  return ok, err
end

--- Check if the tunnel is active and ready for transmission
--- @return boolean
function KnxTunnel:is_connected()
  return (self.state == STATE.CONNECTED or self.state == STATE.PROBING) and self.channel_id ~= nil
end

--- Get current client FSM state
--- @return string
function KnxTunnel:get_state()
  return self.state
end

--- Reset exponential backoff reconnect delay to initial value
function KnxTunnel:reset_reconnect_delay()
  self.reconnect_delay = self.base_reconnect_delay
end

--- Get current reconnect delay and advance to the next exponential backoff step
--- @return number delay Current delay in seconds
function KnxTunnel:get_and_advance_reconnect_delay()
  local current = self.reconnect_delay
  self.reconnect_delay = math.min(self.reconnect_delay * 2, self.max_reconnect_delay)
  return current
end

--- Set active reconnect timer and its cancellation callback
--- @param timer any Platform timer handle
--- @param cancel_fn function Closure that cancels the platform timer
function KnxTunnel:set_reconnect_timer(timer, cancel_fn)
  self:cancel_reconnect_timer()
  self.reconnect_timer = timer
  self.cancel_timer_fn = cancel_fn
end

--- Cancel any pending reconnect timer
function KnxTunnel:cancel_reconnect_timer()
  if self.cancel_timer_fn then
    pcall(self.cancel_timer_fn)
    self.cancel_timer_fn = nil
  end
  self.reconnect_timer = nil
end

function KnxTunnel:_send_udp(bytes)
  if self.sock then
    return self.sock:sendto(bytes, self.host, self.port)
  end
  return nil, "socket not open"
end

function KnxTunnel:_send_probe()
  self.next_timeout = socket.gettime() + self.ack_timeout
  if self.channel_id then
    self:_send_udp(knxnet_ip.build_connstate_req(self.channel_id))
  end
end

--- Transition FSM state and notify listeners
--- @param new_state string Target KnxTunnel.STATE
--- @param reason string|nil Disconnect reason (optional, used when transitioning to STOPPED)
function KnxTunnel:transition_to_state(new_state, reason)
  local old_state = self.state
  local now = socket.gettime()

  if new_state == STATE.CONNECTED then
    self.state = new_state
    self.next_timeout = now + self.heartbeat_interval
    self.retry_count = 0
    self:reset_reconnect_delay()
    if old_state == STATE.CONNECTING then
      self:_invoke_callback("on_connect", self.on_connect)
    end
    self:_invoke_callback("on_state_change", self.on_state_change, new_state)

  elseif new_state == STATE.PROBING then
    self.state = new_state
    self:_send_probe()
    self:_invoke_callback("on_state_change", self.on_state_change, new_state)

  elseif new_state == STATE.CONNECTING then
    self.state = new_state
    self:_invoke_callback("on_state_change", self.on_state_change, new_state)

  elseif new_state == STATE.STOPPED then
    self.disconnect_reason = reason or self.disconnect_reason
    self.should_exit = true
    if not self.sender then
      self.state = STATE.STOPPED
    end
  end
end

--- Transmit a KnxTelegramTx over the tunnel (thread-safe)
--- @param tx KnxTelegramTx Outbound KNX telegram
--- @return boolean success, string|nil err
function KnxTunnel:send_telegram(tx)
  if not tx then
    return false, "Cannot send telegram: missing KnxTelegramTx payload"
  end
  if not self:is_connected() or not self.sender then
    return false, string.format("Cannot send telegram: tunnel not connected (state: %s)", self.state)
  end
  return self.sender:send({ type = EVENT.TX, payload = tx })
end

--- Stop the active session and release all network resources (pure message-driven, thread-safe)
--- @param reason string|nil Standard disconnect reason (default: DISCONNECT_REASON.USER_STOP)
function KnxTunnel:stop(reason)
  self:cancel_reconnect_timer()
  if self.state == STATE.STOPPED then return end
  if self.sender then
    self.sender:send({ type = EVENT.STOP, reason = reason or DISCONNECT_REASON.USER_STOP })
  else
    self:transition_to_state(STATE.STOPPED, reason or DISCONNECT_REASON.USER_STOP)
  end
end

--- Start a new tunnel connection session. Rejects if already running.
--- @param host string|nil Target gateway IP
--- @param port number|string|nil Target gateway port (default: 3671 / knxnet_ip.DEFAULT_PORT)
--- @return boolean success, string|nil err
function KnxTunnel:start(host, port)
  self:cancel_reconnect_timer()
  if self.state ~= STATE.STOPPED then
    return false, string.format("Cannot start tunnel: session already running (state: %s)", self.state)
  end

  port = tonumber(port) or knxnet_ip.DEFAULT_PORT
  if not host or host == "" then
    cosock.spawn(function()
      self:_invoke_callback("on_disconnect", self.on_disconnect, DISCONNECT_REASON.INVALID_CONFIG)
    end, "knx invalid config notifier")
    return false, "Missing or empty gateway host"
  end

  self.host = host
  self.port = port
  self.should_exit = false
  self.disconnect_reason = DISCONNECT_REASON.USER_STOP

  local sender, receiver = cosock.channel.new()
  self.sender = sender
  self.receiver = receiver

  self.state = STATE.CONNECTING
  self:_invoke_callback("on_state_change", self.on_state_change, STATE.CONNECTING)

  cosock.spawn(function()
    local sock = socket.udp()
    if not sock or not sock:setsockname(BIND_ADDR, BIND_PORT) then
      if sock then pcall(sock.close, sock) end
      self.log.error("[KnxTunnel] Failed to bind local UDP socket")
      self:transition_to_state(STATE.STOPPED, DISCONNECT_REASON.SOCKET_ERROR)
    else
      sock:settimeout(0)
      self.sock = sock

      self.log.debug(string.format("[KnxTunnel] Sending Connection Request to %s:%d", self.host, self.port))
      self:_send_udp(knxnet_ip.build_connect_req())
      self.next_timeout = socket.gettime() + self.connect_timeout
    end

    -- Main Single-Exit Reactor loop
    while not self.should_exit do
      local timeout = math.max(0, self.next_timeout - socket.gettime())
      local ready = socket.select({ self.sock, receiver }, nil, timeout)

      if ready and #ready > 0 then
        for _, s in ipairs(ready) do
          if s == receiver then
            local cmd = receiver:receive()
            if cmd then
              dispatch_event(self, cmd)
              if self.should_exit then break end
            end
          elseif s == self.sock then
            local bytes, err = self.sock:receivefrom()
            if bytes then
              local event = parse_datagram(bytes)
              if event then
                dispatch_event(self, event)
              end
              if self.should_exit then break end
            elseif err ~= "timeout" then
              self.log.error(string.format("[KnxTunnel] Socket receive error: %s", tostring(err)))
              self:transition_to_state(STATE.STOPPED, DISCONNECT_REASON.SOCKET_ERROR)
              break
            end
          end
        end
      end

      -- Evaluate timer deadline independently of I/O readiness (prevents timer starvation under traffic)
      if not self.should_exit and socket.gettime() >= self.next_timeout then
        dispatch_event(self, { type = EVENT.TIMEOUT })
      end
    end

    -- Single-exit cleanup phase
    if self.sock then
      pcall(self.sock.close, self.sock)
      self.sock = nil
    end
    if self.receiver then
      pcall(self.receiver.close, self.receiver)
      self.receiver = nil
    end
    self.sender = nil
    self.channel_id = nil

    self.state = STATE.STOPPED
    self.log.info(string.format("[KnxTunnel] Session terminated (reason: %s)", tostring(self.disconnect_reason)))
    self:_invoke_callback("on_disconnect", self.on_disconnect, self.disconnect_reason)
    self:_invoke_callback("on_state_change", self.on_state_change, STATE.STOPPED)
  end, "knx tunnel reactor")

  return true
end

--- Restart tunnel session to a target host and port.
--- Uses In-Loop Atomic Restart: queues EVENT.RESTART to gracefully teardown 0x0209 and
--- reconnect 0x0205 sequentially within the same reactor loop, preventing 0x24 channel exhaustion.
--- @param host string|nil Target KNX IP interface host/IP
--- @param port number|string|nil Target KNX IP interface port (default: 3671 / knxnet_ip.DEFAULT_PORT)
--- @return boolean success
function KnxTunnel:restart(host, port)
  self:cancel_reconnect_timer()
  if not host or host == "" then
    if self.state ~= STATE.STOPPED then
      self:stop(DISCONNECT_REASON.INVALID_CONFIG)
    else
      cosock.spawn(function()
        self:_invoke_callback("on_disconnect", self.on_disconnect, DISCONNECT_REASON.INVALID_CONFIG)
      end, "knx invalid config notifier")
    end
    return false
  end

  port = tonumber(port) or knxnet_ip.DEFAULT_PORT

  if self.state ~= STATE.STOPPED and self.sender then
    return self.sender:send({ type = EVENT.RESTART, host = host, port = port })
  end

  return self:start(host, port)
end

setmetatable(KnxTunnel, {
  __call = KnxTunnel.init,
})

return KnxTunnel
