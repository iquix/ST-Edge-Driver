--- @module knx.telegram
--- KNX Telegram Framing (KnxTelegramRx, KnxTelegramTx)

local utils = require "knx.utils"
local KnxData = require "knx.data"

local telegram = {}

--- APCI Service Codes (Bidirectional Enum)
local APCI = utils.build_enum {
  GROUP_VALUE_READ     = 0x0000,
  GROUP_VALUE_RESPONSE = 0x0040,
  GROUP_VALUE_WRITE    = 0x0080,
}

telegram.APCI = APCI


------------------------------------------------------------------------
-- KNX ADDRESS CODECS
------------------------------------------------------------------------

--- Convert KNX Group Address string (e.g., "1/3/7") to 2-byte binary string
--- @param addr_str string Group address in "main/middle/sub" format
--- @return string|nil 2-byte binary string, string|nil err
local function group_addr_to_bytes(addr_str)
  if not addr_str then return nil, "Missing group address" end
  local main, middle, sub = tostring(addr_str):match("^(%d+)/(%d+)/(%d+)$")
  if not main then
    return nil, "Invalid KNX Group Address format: " .. tostring(addr_str) .. " (expected main/middle/sub)"
  end

  main, middle, sub = tonumber(main), tonumber(middle), tonumber(sub)
  if main > 31 or middle > 7 or sub > 255 then
    return nil, "KNX Group Address out of range: " .. addr_str
  end

  return string.char((main << 3) | middle, sub)
end

--- Convert 2-byte binary string to KNX Group Address string (e.g. "1/3/7")
--- @param bytes string 2-byte binary string
--- @return string Group address string in "main/middle/sub" format
local function bytes_to_group_addr(bytes)
  local b1, b2 = bytes:byte(1, 2)
  return string.format("%d/%d/%d", b1 >> 3, b1 & 7, b2)
end

--- Convert KNX Individual Address string (e.g., "1.1.10") to 2-byte binary string
--- @param addr_str string Individual address in "area.line.device" format
--- @return string|nil 2-byte binary string, string|nil err
local function individual_addr_to_bytes(addr_str)
  if addr_str == "0.0.0" then return "\x00\x00" end -- fast path
  if not addr_str then return nil, "Missing individual address" end
  local area, line, device = tostring(addr_str):match("^(%d+)%.(%d+)%.(%d+)$")
  if not area then
    return nil, "Invalid KNX Individual Address format: " .. tostring(addr_str) .. " (expected area.line.device)"
  end

  area, line, device = tonumber(area), tonumber(line), tonumber(device)
  if area > 15 or line > 15 or device > 255 then
    return nil, "KNX Individual Address out of range: " .. addr_str
  end

  return string.char((area << 4) | line, device)
end

--- Convert 2-byte binary string to KNX Individual Address string (e.g. "1.1.10")
--- @param bytes string 2-byte binary string
--- @return string Individual address string in "area.line.device" format
local function bytes_to_individual_addr(bytes)
  local b1, b2 = bytes:byte(1, 2)
  return string.format("%d.%d.%d", b1 >> 4, b1 & 15, b2)
end

telegram.group_addr_to_bytes = group_addr_to_bytes
telegram.bytes_to_group_addr = bytes_to_group_addr
telegram.individual_addr_to_bytes = individual_addr_to_bytes
telegram.bytes_to_individual_addr = bytes_to_individual_addr


------------------------------------------------------------------------
-- KnxTelegramRx (Inbound KNX Telegram)
------------------------------------------------------------------------

--- @class KnxTelegramRx
---
--- Inbound KNX bus telegram received from the KNX bus.
---
--- @field public src string KNX source Individual Address (e.g. "1.1.10")
--- @field public dst string KNX destination Group Address (e.g. "1/2/3")
--- @field public apci number APCI service code (e.g. 0x0080 for Write, 0x0040 for Response)
--- @field public data KnxData The parsed KnxData payload container
local KnxTelegramRx = {}
KnxTelegramRx.NAME = "KnxTelegramRx"
KnxTelegramRx.__index = KnxTelegramRx
telegram.KnxTelegramRx = KnxTelegramRx

--- Return a human-readable string representation of this telegram
--- @return string
function KnxTelegramRx:pretty_print()
  local apci_name = APCI[self.apci] or string.format("0x%04X", self.apci)
  return utils.format_fields(self.NAME, {
    { "src",  self.src },
    { "dst",  self.dst },
    { "apci", apci_name },
    { "data", self.data },
  })
end

KnxTelegramRx.__tostring = KnxTelegramRx.pretty_print

--- Constructor for KnxTelegramRx
--- @param cls table Class table
--- @param fields table Telegram fields { src, dst, apci, data }
--- @return KnxTelegramRx
function KnxTelegramRx.init(cls, fields)
  local self = {
    src  = fields.src,
    dst  = fields.dst,
    apci = fields.apci,
    data = fields.data,
  }
  return setmetatable(self, cls)
end

--- Deserialize pure KNX telegram bytes into a KnxTelegramRx instance
--- @param telegram_bytes string Raw KNX telegram bytes starting with Control Fields (0xBC, 0xE0)
--- @return KnxTelegramRx|nil knx_rx, string|nil err
function KnxTelegramRx.deserialize(telegram_bytes)
  if not telegram_bytes or #telegram_bytes < 9 then
    return nil, "Incomplete KNX telegram body"
  end

  -- Unpack Source (2B), Destination (2B), Data Length (1B), and TPCI+APCI (2B)
  -- Control Field 1 (1B) and Control Field 2 (1B) are at bytes 1..2
  local src_bytes, dest_bytes, payload_size, apci_raw = string.unpack(">c2>c2B>I2", telegram_bytes, 3)
  local apci = apci_raw & 0x03c0

  if apci ~= APCI.GROUP_VALUE_WRITE and apci ~= APCI.GROUP_VALUE_RESPONSE then
    return nil, string.format("Unsupported APCI: 0x%04X", apci)
  end

  local end_pos = 8 + payload_size
  if payload_size < 1 or #telegram_bytes < end_pos then
    return nil, "Truncated payload in KNX telegram"
  end
  local apdu_bytes = string.char(apci_raw & 0x3f) .. telegram_bytes:sub(10, end_pos)

  return KnxTelegramRx({
    src  = bytes_to_individual_addr(src_bytes),
    dst  = bytes_to_group_addr(dest_bytes),
    apci = apci,
    data = KnxData.deserialize(apdu_bytes),
  })
end

setmetatable(telegram.KnxTelegramRx, {
  __call = KnxTelegramRx.init,
})


------------------------------------------------------------------------
-- KnxTelegramTx (Outbound KNX Telegram)
------------------------------------------------------------------------

--- @class KnxTelegramTx
---
--- Outbound KNX bus telegram targeted for transmission to the KNX bus.
---
--- @field public src string KNX source Individual Address (default: "0.0.0" or 2-byte binary)
--- @field public dst string KNX destination Group Address (e.g. "1/2/3")
--- @field public apci number APCI service code (e.g. 0x0080 for Write)
--- @field public data KnxData The parsed KnxData payload container
local KnxTelegramTx = {}
KnxTelegramTx.NAME = "KnxTelegramTx"
KnxTelegramTx.__index = KnxTelegramTx
telegram.KnxTelegramTx = KnxTelegramTx

--- Return a human-readable string representation of this telegram
--- @return string
function KnxTelegramTx:pretty_print()
  local apci_name = APCI[self.apci] or string.format("0x%04X", self.apci)
  local src_str = (#self.src == 2 and bytes_to_individual_addr(self.src)) or tostring(self.src)
  return utils.format_fields(self.NAME, {
    { "src",  src_str },
    { "dst",  self.dst },
    { "apci", apci_name },
    { "data", self.data },
  })
end

KnxTelegramTx.__tostring = KnxTelegramTx.pretty_print

--- Constructor for KnxTelegramTx
--- @param cls table Class table
--- @param fields table Telegram fields { src, dst, apci, data }
--- @return KnxTelegramTx
function KnxTelegramTx.init(cls, fields)
  local data_val = fields.data
  if type(data_val) == "string" then
    data_val = KnxData(data_val)
  end
  local self = {
    src  = fields.src or "0.0.0",
    dst  = fields.dst,
    apci = fields.apci or APCI.GROUP_VALUE_WRITE,
    data = data_val,
  }
  return setmetatable(self, cls)
end

--- Serialize this KnxTelegramTx into pure KNX telegram bytes
--- @return string|nil telegram_bytes, string|nil err
function KnxTelegramTx:serialize()
  if not self.dst or self.dst == "" then
    return nil, "Missing destination in KnxTelegramTx"
  end

  local dest_addr_bytes, dest_err = group_addr_to_bytes(self.dst)
  if not dest_addr_bytes then
    return nil, dest_err or "Invalid destination address in KnxTelegramTx"
  end

  local src_addr_bytes, src_err
  if #self.src == 2 then
    src_addr_bytes = self.src
  else
    src_addr_bytes, src_err = individual_addr_to_bytes(self.src)
  end
  if not src_addr_bytes then
    return nil, src_err or "Invalid source address in KnxTelegramTx"
  end

  local apci = self.apci
  local apdu = self.data and self.data:serialize() or "\x00"
  local data_len = #apdu
  local apci_high = apci >> 8
  local apci_low = (apci & 0xc0) | (apdu:byte() & 0x3f)
  local data_bytes = apdu:sub(2)

  local telegram_bytes = string.pack(
    ">BBc2c2BBB",
    0xBC, 0xE0,               -- Control Field 1 (standard frame), Control Field 2 (routing counter 6, group flag)
    src_addr_bytes,
    dest_addr_bytes,
    data_len, apci_high, apci_low
  ) .. data_bytes

  return telegram_bytes
end

--- Static factory method to create a GroupValueRead telegram
--- @param dst string Destination group address
--- @param src string|nil Optional source individual address
--- @return KnxTelegramTx
function KnxTelegramTx.read(dst, src)
  return KnxTelegramTx({
    src  = src,
    dst  = dst,
    apci = APCI.GROUP_VALUE_READ,
  })
end

--- Static factory method to create a GroupValueWrite telegram
--- @param dst string Destination group address
--- @param data KnxData|string Data container or raw payload
--- @param src string|nil Optional source individual address
--- @return KnxTelegramTx
function KnxTelegramTx.write(dst, data, src)
  return KnxTelegramTx({
    src  = src,
    dst  = dst,
    apci = APCI.GROUP_VALUE_WRITE,
    data = data,
  })
end

setmetatable(telegram.KnxTelegramTx, {
  __call = KnxTelegramTx.init,
})

return telegram
