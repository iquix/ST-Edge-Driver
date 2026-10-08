--- @module knx.utils
--- General Binary & String Utilities for KNX Subsystem
--- Provides stateless general binary codecs and formatting helpers.

local utils = {}

local noop = function() end
utils.NOOP_LOGGER = { debug = noop, info  = noop, warn  = noop, error = noop }

--- Format a class and its fields into standard <ClassName || key: value, ...> representation
--- @param class_name string Class name identifier
--- @param fields table List of { key, value } pairs
--- @return string Formatted string
function utils.format_fields(class_name, fields)
  local parts = {}
  for _, item in ipairs(fields) do
    local k, v = item[1], item[2]
    if v ~= nil then
      parts[#parts + 1] = string.format("%s: %s", k, tostring(v))
    end
  end
  return string.format("<%s || %s>", class_name, table.concat(parts, ", "))
end

--- Convert binary byte string to uppercase hexadecimal string
--- @param bytes string Binary byte string
--- @return string Hexadecimal string
function utils.bytes_to_hex(bytes)
  if #bytes == 0 then return "" end
  return string.format(string.rep("%02X", #bytes), string.byte(bytes, 1, #bytes))
end

--- Convert hexadecimal string to binary byte string
--- @param hex_str string Hexadecimal string (e.g. "010A" or "01 0a")
--- @return string Binary string
function utils.hex_to_bytes(hex_str)
  local clean = hex_str:gsub("%s+", ""):gsub("^0[xX]", "")
  if (#clean % 2) ~= 0 then
    clean = "0" .. clean
  end
  return (clean:gsub("(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

--- Build a bidirectional enum table with value <-> key mappings
--- @param tbl table Key-value table (string keys to numeric/scalar values)
--- @return table Enriched table with reverse mappings
function utils.build_enum(tbl)
  local enum = {}
  for k, v in pairs(tbl) do
    enum[k] = v
    enum[v] = k
  end
  return enum
end

return utils
