--- @module knx_dispatcher
--- Hierarchical KNX Telegram Dispatcher extending SmartThings MessageDispatcher

local MessageDispatcher = require "st.dispatcher"

--- @class KnxDispatcher : MessageDispatcher
---
--- This inherits from MessageDispatcher and routes KnxTelegramRx telegrams to matching sub_drivers.
---
--- @field public name string Name of this dispatcher level
--- @field public child_dispatchers KnxDispatcher[] Child dispatchers in the hierarchy
--- @field public default_handlers table { knx_handlers = { [handler_key] = fn } }
--- @field public dispatcher_class_name string "KnxDispatcher"
local KnxDispatcher = {
  NAME = "KnxDispatcher",
  group_address_resolver = nil,
}
KnxDispatcher.__index = KnxDispatcher

--- Initialize a KnxDispatcher instance
--- @param cls table Class table
--- @param name string Name for logging/debugging
--- @param dispatcher_filter function Filter function (can_handle)
--- @param default_handlers table Default handlers table
--- @return KnxDispatcher
function KnxDispatcher.init(cls, name, dispatcher_filter, default_handlers)
  local new_disp = MessageDispatcher.init(cls, name, dispatcher_filter, default_handlers, "KnxDispatcher")
  new_disp._subscriptions = {}
  return new_disp
end

--- Set the global group address resolver callback
--- @param resolver_fn function(device, handler_key) -> string|nil
function KnxDispatcher.set_group_address_resolver(resolver_fn)
  KnxDispatcher.group_address_resolver = resolver_fn
end

--- Recursively build KnxDispatcher hierarchy from driver.sub_drivers
--- @param driver Driver Main driver or parent subdriver
function KnxDispatcher.populate_knx_dispatcher_from_sub_drivers(driver)
  for _, sub_driver in ipairs(driver.sub_drivers) do
    if sub_driver.knx_handlers then
      local sub_disp = KnxDispatcher(
        sub_driver.NAME,
        sub_driver.can_handle,
        {
          knx_handlers = sub_driver.knx_handlers,
        }
      )
      driver.knx_dispatcher:register_child_dispatcher(sub_disp)
      if sub_driver.sub_drivers then
        KnxDispatcher.populate_knx_dispatcher_from_sub_drivers(sub_driver)
      end
    end
  end
end

--- Resolve a group address for a given device and handler key
--- @param device table Device instance
--- @param handler_key string Logical handler key
--- @return string|nil Group address string (e.g. "1/1/1")
function KnxDispatcher:resolve_group_address(device, handler_key)
  local resolver = self.group_address_resolver or KnxDispatcher.group_address_resolver
  return resolver and resolver(device, handler_key) or nil
end

--- Find default handlers that match this KNX telegram for the given device
--- @param driver Driver Driver context
--- @param device st.Device Device being dispatched to
--- @param knx_rx KnxTelegramRx Inbound KNX telegram
--- @return function[] List of matching handlers
function KnxDispatcher:find_default_handlers(driver, device, knx_rx)
  local matching_handlers = {}
  local knx_handlers = self.default_handlers and self.default_handlers.knx_handlers
  if knx_handlers and device and knx_rx and knx_rx.dst then
    local root = self.parent or self
    local matched_keys = root._subscriptions[device.id] and root._subscriptions[device.id][knx_rx.dst]
    if matched_keys then
      for _, key in ipairs(matched_keys) do
        local handler = knx_handlers[key]
        if handler then
          table.insert(matching_handlers, handler)
        end
      end
    end
  end
  return matching_handlers
end

--- Pretty print default handlers
--- @param self KnxDispatcher
--- @param indent number|nil Indentation spaces (default: 0)
--- @return string
function KnxDispatcher.pretty_print_default_handlers(self, indent)
  indent = indent or 0
  local indent_str = string.rep(" ", indent)
  return string.format("%sdefault_handlers: %s\n", indent_str, self.name)
end

--- Subscribe a device and eagerly calculate its group address subscriptions
--- @param device table Device instance
--- @return table<string, string[]> Map of group address to handler keys
function KnxDispatcher:subscribe_device(device)
  if not device or not device.id then return {} end
  local ga_map = {}

  local function register_handlers(dispatcher, handlers)
    if not handlers then return end
    for handler_key, _ in pairs(handlers) do
      local ga = dispatcher:resolve_group_address(device, handler_key)
      if ga and ga ~= "" then
        ga_map[ga] = ga_map[ga] or {}
        table.insert(ga_map[ga], handler_key)
      end
    end
  end

  if self.child_dispatchers and #self.child_dispatchers > 0 then
    for _, child in ipairs(self.child_dispatchers) do
      local status, val = pcall(child.dispatcher_filter, {dispatcher_class = child.dispatcher_class_name}, nil, device)
      if status and val then
        register_handlers(child, child.default_handlers and child.default_handlers.knx_handlers)
      end
    end
  else
    register_handlers(self, self.default_handlers and self.default_handlers.knx_handlers)
  end

  self._subscriptions[device.id] = ga_map
  return ga_map
end

--- Unsubscribe a device and clear its subscriptions
--- @param device table Device instance
function KnxDispatcher:unsubscribe_device(device)
  if not device or not device.id then return end
  self._subscriptions[device.id] = nil
end

--- Check if a device is subscribed to a given group address
--- @param device table Device instance
--- @param ga string Group address
--- @return boolean
function KnxDispatcher:is_subscribed(device, ga)
  if not device or not device.id or not ga then return false end
  local ga_map = self._subscriptions[device.id]
  if not ga_map then
    ga_map = self:subscribe_device(device)
  end
  return ga_map[ga] ~= nil
end

--- Get map of subscribed group addresses to handler keys for a device
--- @param device table Device instance
--- @return table<string, string[]> Map of group address to array of handler keys
function KnxDispatcher:get_subscriptions(device)
  if not device or not device.id then return {} end
  return self._subscriptions[device.id] or {}
end

setmetatable(KnxDispatcher, {
  __index = MessageDispatcher,
  __call = KnxDispatcher.init,
})

return KnxDispatcher
