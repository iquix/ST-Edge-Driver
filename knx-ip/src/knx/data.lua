--- @module knx.data
--- Pure KNX APDU Payload Container

local utils = require "knx.utils"

--- @class KnxData
---
--- Pure KNX APDU payload container supporting both short (< 6 bits) and long frames.
---
--- @field public raw string Binary byte string
--- @field public is_short_frame boolean Whether this data belongs in APCI (<= 6 bits)
local KnxData = {}
KnxData.NAME = "KnxData"
KnxData.__index = KnxData

--- Constructor for raw KnxData
--- @param raw string|nil Binary byte string (default: "")
--- @param is_short_frame boolean|nil Whether this data is short frame (<= 6 bits in APCI)
--- @return KnxData
function KnxData.init(cls, raw, is_short_frame)
  local self = setmetatable({}, cls)
  self.raw = raw or ""
  self.is_short_frame = (is_short_frame == true)
  return self
end

--- Deserialize standard KNX APDU payload bytes into a KnxData instance.
--- Short frames (<= 6 bits) have #apdu_bytes == 1 (is_short_frame = true).
--- Long frames (> 6 bits) have #apdu_bytes > 1, starting with \x00 overlap byte (is_short_frame = false).
--- @param apdu_bytes string Binary APDU byte string
--- @return KnxData
function KnxData.deserialize(apdu_bytes)
  if not apdu_bytes or #apdu_bytes == 0 then
    return KnxData("", false)
  elseif #apdu_bytes == 1 then
    return KnxData(apdu_bytes, true)
  else
    return KnxData(apdu_bytes:sub(2), false)
  end
end

--- Serialize KnxData into standard KNX APDU payload bytes.
--- Short frames (<= 6 bits) serialize as 1 byte (self.raw).
--- Long frames (> 6 bits) serialize as "\x00" .. self.raw.
--- @return string
function KnxData:serialize()
  if self.is_short_frame then
    return self.raw
  else
    return "\x00" .. self.raw
  end
end

--- Return human-readable string representation of this KnxData
--- @return string
function KnxData:pretty_print()
  local raw_hex = (#self.raw > 0) and ("0x" .. utils.bytes_to_hex(self.raw)) or nil
  return utils.format_fields(self.NAME, {
    { "raw",            raw_hex },
    { "is_short_frame", self.is_short_frame },
  })
end

KnxData.__tostring = KnxData.pretty_print

setmetatable(KnxData, {
  __call = KnxData.init,
})

return KnxData
