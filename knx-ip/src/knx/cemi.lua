--- @module knx.cemi
--- Common External Message Interface (cEMI) Framing
--- Provides message code constants and framing encoders/decoders for cEMI L_Data.

local utils = require "knx.utils"

local cemi = {}

--- cEMI Message Codes (Bidirectional Enum)
local MSG_CODE = utils.build_enum {
  L_DATA_REQ = 0x11,
  L_DATA_CON = 0x2E,
  L_DATA_IND = 0x29,
}

cemi.MSG_CODE = MSG_CODE

--- Decode a cEMI binary frame into its message code and raw telegram bytes
--- @param cemi_bytes string|nil Raw cEMI frame
--- @return table|nil frame { msg_code, telegram_bytes }, string|nil err
function cemi.decode(cemi_bytes)
  if not cemi_bytes or #cemi_bytes < 2 then
    return nil, "Incomplete cEMI frame header"
  end
  local msg_code, add_info_len = cemi_bytes:byte(1, 2)
  return {
    msg_code       = msg_code,
    telegram_bytes = cemi_bytes:sub(3 + add_info_len),
  }
end

--- Encode a raw telegram into a cEMI binary frame
--- @param telegram_bytes string Raw KNX telegram bytes
--- @param msg_code number|nil cEMI message code (default: 0x11 L_DATA_REQ)
--- @return string Binary cEMI frame
function cemi.encode(telegram_bytes, msg_code)
  return string.pack(">BB", msg_code or MSG_CODE.L_DATA_REQ, 0x00) .. (telegram_bytes or "")
end

return cemi
