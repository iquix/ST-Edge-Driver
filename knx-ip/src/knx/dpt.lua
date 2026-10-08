--- @module knx.dpt
--- KNX Data Point Types (DPT) Codec Registry and Factory

local KnxData = require "knx.data"
local utils = require "knx.utils"

local dpt = {}

------------------------------------------------------------------------
-- CONSTANTS & ENUMS
------------------------------------------------------------------------

--- DPT 20.102 HVAC Mode (Bidirectional Enum)
local DPT_HVAC_MODE = utils.build_enum {
  AUTO                = 0,
  COMFORT             = 1,
  STANDBY             = 2,
  ECONOMY             = 3,
  BUILDING_PROTECTION = 4,
}

--- DPT 20.105 HVAC Control Mode (Bidirectional Enum)
local DPT_HVAC_CONTROL_MODE = utils.build_enum {
  AUTO             = 0,
  HEAT             = 1,
  COOL             = 3,
  OFF              = 6,
  FAN_ONLY         = 9,
  DEHUMIDIFICATION = 14,
}

dpt.DPT_HVAC_MODE = DPT_HVAC_MODE
dpt.DPT_HVAC_CONTROL_MODE = DPT_HVAC_CONTROL_MODE
dpt.HVAC_MODE = DPT_HVAC_MODE
dpt.HVAC_CONTROL_MODE = DPT_HVAC_CONTROL_MODE


------------------------------------------------------------------------
-- HELPER FUNCTIONS
------------------------------------------------------------------------

local function clamp(v, min_v, max_v)
  local n = tonumber(v) or min_v
  if n < min_v then return min_v end
  if n > max_v then return max_v end
  return n
end

local function clamp_round(v, min_v, max_v)
  local n = (((tonumber(v) or 0) + 0.5) // 1) | 0
  if n < min_v then return min_v end
  if n > max_v then return max_v end
  return n
end

-- PRIMITIVE PACKERS AND UNPACKERS

local function pack_bool(v)
  return (v == true or v == 1) and "\x01" or "\x00"
end

local function unpack_bool(raw)
  if raw and #raw > 0 then
    return (raw:byte() & 1) == 1
  end
  return false
end

local function pack_step(val)
  if type(val) == "table" then
    local dir = (val.direction == 1 or val.direction == "increase" or val.direction == "up") and 1 or 0
    return string.char((dir << 3) | clamp(val.step, 0, 7))
  else
    return string.char(clamp(val, 0, 15))
  end
end

local function unpack_step(raw)
  local b = (raw and #raw > 0) and raw:byte() or 0
  return {
    direction = (b >> 3) & 1,
    step = b & 7,
  }
end

local function pack_u8(v)
  return string.char(clamp_round(v, 0, 255))
end

local function unpack_u8(raw)
  if raw and #raw > 0 then
    return raw:byte()
  end
  return 0
end

local function pack_i8(v)
  return string.pack(">b", clamp_round(v, -128, 127))
end

local function unpack_i8(raw)
  if raw and #raw >= 1 then
    return (string.unpack(">b", raw))
  end
  return 0
end

local function pack_u16(v)
  return string.pack(">I2", clamp_round(v, 0, 65535))
end

local function unpack_u16(raw)
  if raw and #raw >= 2 then
    return (string.unpack(">I2", raw))
  elseif raw and #raw == 1 then
    return raw:byte()
  end
  return 0
end

local function pack_i16(v)
  return string.pack(">i2", clamp_round(v, -32768, 32767))
end

local function unpack_i16(raw)
  if raw and #raw >= 2 then
    return (string.unpack(">i2", raw))
  elseif raw and #raw == 1 then
    return (string.unpack(">b", raw))
  end
  return 0
end

local function pack_float16(v)
  local num = tonumber(v) or 0.0
  local sign = 0
  if num < 0 then
    sign = 1
    num = -num
  end
  local v_scaled = num * 100.0
  local exp = 0
  while v_scaled > 2047.5 and exp < 15 do
    v_scaled = v_scaled * 0.5
    exp = exp + 1
  end
  local mant = ((v_scaled + 0.5) // 1) | 0
  if mant > 2047 then
    if exp < 15 then
      mant = mant >> 1
      exp = exp + 1
    else
      mant = 2047
    end
  end
  if sign == 1 then
    mant = -mant
  end
  local raw_u16 = (sign << 15) | (exp << 11) | (mant & 0x07FF)
  return string.pack(">I2", raw_u16)
end

local function unpack_float16(raw)
  if raw and #raw >= 2 then
    local b1, b2 = raw:byte(1, 2)
    local mant = (((b1 & 0x07) << 8) | b2) - ((b1 & 0x80) << 4)
    local exp = (b1 >> 3) & 0x0F
    return (mant << exp) * 0.01
  end
  return 0.0
end

local function pack_u32(v)
  return string.pack(">I4", clamp_round(v, 0, 4294967295))
end

local function unpack_u32(raw)
  if raw and #raw >= 4 then
    return (string.unpack(">I4", raw))
  end
  return 0
end

local function pack_i32(v)
  return string.pack(">i4", clamp_round(v, -2147483648, 2147483647))
end

local function unpack_i32(raw)
  if raw and #raw >= 4 then
    return (string.unpack(">i4", raw))
  end
  return 0
end

local function pack_float32(v)
  local num = tonumber(v) or 0.0
  return string.pack(">f", num)
end

local function unpack_float32(raw)
  if raw and #raw >= 4 then
    return (string.unpack(">f", raw))
  end
  return 0.0
end

local function pack_string(v)
  local str = tostring(v or "")
  if #str > 14 then
    str = str:sub(1, 14)
  end
  return str .. string.rep("\x00", 14 - #str)
end

local function unpack_string(raw)
  if not raw or #raw == 0 then return "" end
  local str = raw:sub(1, 14)
  local null_pos = str:find("\x00")
  if null_pos then
    str = str:sub(1, null_pos - 1)
  end
  return str
end

local function pack_scene_number(v)
  return string.char((clamp(v, 1, 64) - 1) & 0x3F)
end

local function unpack_scene_number(raw)
  local b = (raw and #raw > 0) and raw:byte() or 0
  return (b & 0x3F) + 1
end

local function pack_scene_control(v)
  local scene, learn
  if type(v) == "table" then
    scene = v.scene_number or v.scene or v[1]
    learn = (v.learn == true or v[2] == true)
  else
    scene = v
    learn = false
  end
  local wire_val = (clamp(scene, 1, 64) - 1) & 0x3F
  local flag = learn and 0x80 or 0x00
  return string.char(flag | wire_val)
end

local function unpack_scene_control(raw)
  local b = (raw and #raw > 0) and raw:byte() or 0
  return {
    scene_number = (b & 0x3F) + 1,
    learn        = (b & 0x80) ~= 0,
  }
end

local function pack_hvac_mode(v, mode_tbl)
  local code = nil
  if type(v) == "table" then
    code = tonumber(v.id or v.mode or v[1])
  elseif type(v) == "string" then
    code = mode_tbl and mode_tbl[string.upper(v)]
    if not code then code = tonumber(v) end
  elseif type(v) == "number" then
    code = v
  end
  return string.char(clamp(code, 0, 255))
end

local function unpack_hvac_mode(raw, mode_tbl)
  local code = (raw and #raw > 0) and raw:byte() or 0
  if mode_tbl and mode_tbl[code] then
    return string.lower(mode_tbl[code])
  end
  return code
end

local function pack_rgb(v)
  if type(v) == "table" then
    return string.char(
      clamp_round(v.r, 0, 255),
      clamp_round(v.g, 0, 255),
      clamp_round(v.b, 0, 255)
    )
  end
  return "\x00\x00\x00"
end

local function unpack_rgb(raw)
  if raw and #raw >= 3 then
    local r, g, b = raw:byte(1, 3)
    return {
      r = r,
      g = g,
      b = b,
    }
  end
  return { r = 0, g = 0, b = 0 }
end

-- STRING PAYLOAD CASTERS

local function cast_bool(str)
  local s = string.lower(tostring(str or "")):match("^%s*(.-)%s*$")
  return (s == "1" or s == "true" or s == "on")
end

local function cast_number(str)
  return tonumber(str) or 0
end

local function cast_string(str)
  return tostring(str or "")
end

local function cast_rgb(str)
  local hex = tostring(str or ""):gsub("^#", ""):gsub("^0[xX]", "")
  if #hex == 6 and hex:match("^%x+$") then
    local r, g, b = hex:match("^(%x%x)(%x%x)(%x%x)$")
    return { r = tonumber(r, 16), g = tonumber(g, 16), b = tonumber(b, 16) }
  end
  return { r = 0, g = 0, b = 0 }
end

-- SCALER BUILDERS

local function build_u8_scaler(max_val)
  local encode = function(val)
    return pack_u8((tonumber(val) or 0) * 255 / max_val)
  end
  local decode = function(raw)
    return (((unpack_u8(raw) * max_val / 255.0) + 0.5) // 1) | 0
  end
  return encode, decode
end

-- DPT BUILDERS

local function build_bool_dpt(name)
  return { name = name, is_short_frame = true, encode = pack_bool, decode = unpack_bool, cast = cast_bool }
end

local function build_step_dpt(name)
  return { name = name, is_short_frame = true, encode = pack_step, decode = unpack_step, cast = cast_number }
end

local function build_u8_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_u8, decode = unpack_u8, cast = cast_number }
end

local function build_scaled_u8_dpt(name, max_val)
  local enc, dec = build_u8_scaler(max_val)
  return { name = name, is_short_frame = false, encode = enc, decode = dec, cast = cast_number }
end

local function build_i8_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_i8, decode = unpack_i8, cast = cast_number }
end

local function build_u16_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_u16, decode = unpack_u16, cast = cast_number }
end

local function build_i16_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_i16, decode = unpack_i16, cast = cast_number }
end

local function build_float16_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_float16, decode = unpack_float16, cast = cast_number }
end

local function build_u32_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_u32, decode = unpack_u32, cast = cast_number }
end

local function build_i32_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_i32, decode = unpack_i32, cast = cast_number }
end

local function build_float32_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_float32, decode = unpack_float32, cast = cast_number }
end

local function build_string_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_string, decode = unpack_string, cast = cast_string }
end

local function build_scene_number_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_scene_number, decode = unpack_scene_number, cast = cast_number }
end

local function build_scene_control_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_scene_control, decode = unpack_scene_control, cast = cast_number }
end

local function build_hvac_mode_dpt(name, mode_tbl)
  return {
    name = name,
    is_short_frame = false,
    encode = function(v) return pack_hvac_mode(v, mode_tbl) end,
    decode = function(raw) return unpack_hvac_mode(raw, mode_tbl) end,
    cast = cast_string,
  }
end

local function build_rgb_dpt(name)
  return { name = name, is_short_frame = false, encode = pack_rgb, decode = unpack_rgb, cast = cast_rgb }
end


------------------------------------------------------------------------
-- DECLARATIVE DPT REGISTRY
------------------------------------------------------------------------

local DPTS = {
  -- Major 1 (1-bit Boolean)
  ["1"]     = build_bool_dpt("DPT 1.xxx (Boolean)"),
  ["1.001"] = build_bool_dpt("DPT 1.001 (Switch)"),
  ["1.002"] = build_bool_dpt("DPT 1.002 (Bool)"),
  ["1.003"] = build_bool_dpt("DPT 1.003 (Enable)"),
  ["1.008"] = build_bool_dpt("DPT 1.008 (UpDown)"),
  ["1.009"] = build_bool_dpt("DPT 1.009 (OpenClose)"),
  ["1.010"] = build_bool_dpt("DPT 1.010 (Start)"),
  ["1.019"] = build_bool_dpt("DPT 1.019 (Window/Door)"),
  ["1.100"] = build_bool_dpt("DPT 1.100 (Cool/Heat)"),

  -- Major 3 (4-bit Control)
  ["3"]     = build_step_dpt("DPT 3.xxx (Control)"),
  ["3.007"] = build_step_dpt("DPT 3.007 (Dimming Control)"),

  -- Major 5 (8-bit Unsigned / Scaled)
  ["5"]     = build_scaled_u8_dpt("DPT 5.001 (Percentage)", 100),
  ["5.001"] = build_scaled_u8_dpt("DPT 5.001 (Percentage)", 100),
  ["5.003"] = build_scaled_u8_dpt("DPT 5.003 (Angle)", 360),
  ["5.004"] = build_u8_dpt("DPT 5.004 (Percent_U8 0..255)"),
  ["5.010"] = build_u8_dpt("DPT 5.010 (Ucount 0..255)"),
  ["5.100"] = build_scaled_u8_dpt("DPT 5.100 (Fan Stage)", 100),

  -- Major 6 (8-bit Signed)
  ["6"]     = build_i8_dpt("DPT 6.xxx (8-bit Int)"),
  ["6.010"] = build_i8_dpt("DPT 6.010 (Value_1_Count)"),

  -- Major 7 (16-bit Unsigned)
  ["7"]     = build_u16_dpt("DPT 7.xxx (16-bit Uint)"),
  ["7.001"] = build_u16_dpt("DPT 7.001 (Pulse)"),
  ["7.005"] = build_u16_dpt("DPT 7.005 (Time Period sec)"),
  ["7.012"] = build_u16_dpt("DPT 7.012 (Current mA)"),
  ["7.013"] = build_u16_dpt("DPT 7.013 (Brightness Lux)"),
  ["7.600"] = build_u16_dpt("DPT 7.600 (Color Temp Kelvin)"),

  -- Major 8 (16-bit Signed)
  ["8"]     = build_i16_dpt("DPT 8.xxx (16-bit Int)"),
  ["8.001"] = build_i16_dpt("DPT 8.001 (Value_2_Count)"),
  ["8.010"] = build_i16_dpt("DPT 8.010 (Delta Time sec)"),
  ["8.011"] = build_i16_dpt("DPT 8.011 (Delta Time ms)"),
  ["8.012"] = build_i16_dpt("DPT 8.012 (Percent_V16)"),

  -- Major 9 (16-bit Float)
  ["9"]     = build_float16_dpt("DPT 9.xxx (Float16)"),
  ["9.001"] = build_float16_dpt("DPT 9.001 (Temperature °C)"),
  ["9.004"] = build_float16_dpt("DPT 9.004 (Lux)"),
  ["9.005"] = build_float16_dpt("DPT 9.005 (Speed m/s)"),
  ["9.006"] = build_float16_dpt("DPT 9.006 (Pressure Pa)"),
  ["9.007"] = build_float16_dpt("DPT 9.007 (Humidity %)"),
  ["9.008"] = build_float16_dpt("DPT 9.008 (Air Quality ppm)"),
  ["9.024"] = build_float16_dpt("DPT 9.024 (Power kW)"),

  -- Major 12 (32-bit Unsigned)
  ["12"]     = build_u32_dpt("DPT 12.xxx (32-bit Uint)"),
  ["12.001"] = build_u32_dpt("DPT 12.001 (Pulse Counter)"),
  ["12.100"] = build_u32_dpt("DPT 12.100 (Counter)"),

  -- Major 13 (32-bit Signed)
  ["13"]     = build_i32_dpt("DPT 13.xxx (32-bit Int)"),
  ["13.001"] = build_i32_dpt("DPT 13.001 (Value_4_Count)"),
  ["13.010"] = build_i32_dpt("DPT 13.010 (Active Energy Wh)"),
  ["13.013"] = build_i32_dpt("DPT 13.013 (Active Energy kWh)"),
  ["13.100"] = build_i32_dpt("DPT 13.100 (Delta Time sec)"),

  -- Major 14 (32-bit Float IEEE 754)
  ["14"]     = build_float32_dpt("DPT 14.xxx (Float32)"),
  ["14.019"] = build_float32_dpt("DPT 14.019 (Current A)"),
  ["14.027"] = build_float32_dpt("DPT 14.027 (Voltage V)"),
  ["14.033"] = build_float32_dpt("DPT 14.033 (Frequency Hz)"),
  ["14.056"] = build_float32_dpt("DPT 14.056 (Power W)"),
  ["14.068"] = build_float32_dpt("DPT 14.068 (Temperature °C)"),
  ["14.076"] = build_float32_dpt("DPT 14.076 (Volume m3)"),

  -- Major 16 (14-byte String)
  ["16"]     = build_string_dpt("DPT 16.xxx (14-byte String)"),
  ["16.000"] = build_string_dpt("DPT 16.000 (ASCII String)"),
  ["16.001"] = build_string_dpt("DPT 16.001 (ISO-8859-1 String)"),

  -- Major 17 (Scene Number)
  ["17"]     = build_scene_number_dpt("DPT 17.xxx (Scene Number)"),
  ["17.001"] = build_scene_number_dpt("DPT 17.001 (Scene Number 1..64)"),

  -- Major 18 (Scene Control)
  ["18"]     = build_scene_control_dpt("DPT 18.xxx (Scene Control)"),
  ["18.001"] = build_scene_control_dpt("DPT 18.001 (Scene Control)"),

  -- Major 20 (8-bit Enum / HVAC)
  ["20"]     = build_u8_dpt("DPT 20.xxx (8-bit Enum)"),
  ["20.102"] = build_hvac_mode_dpt("DPT 20.102 (HVAC Mode)", DPT_HVAC_MODE),
  ["20.105"] = build_hvac_mode_dpt("DPT 20.105 (HVAC Control Mode)", DPT_HVAC_CONTROL_MODE),

  -- Major 232 (3-byte RGB)
  ["232"]     = build_rgb_dpt("DPT 232.xxx (3-byte RGB)"),
  ["232.600"] = build_rgb_dpt("DPT 232.600 (RGB Color)"),
}

dpt.DPTS = DPTS


-- PUBLIC LOOKUP AND CODEC APIS

--- Lookup DPT specification table by ID with fallback to Major number
--- @param id string|number DPT identifier (e.g. "1.001", "5", 7)
--- @return table|nil DPT specification table
function dpt.get_dpt(id)
  if not id then return nil end
  id = tostring(id)
  if dpt.DPTS[id] then return dpt.DPTS[id] end
  local major = id:match("^(%d+)")
  return dpt.DPTS[major]
end

--- Encode a Lua value into a KnxData instance for a given DPT
--- @param dpt_id string|number DPT identifier (e.g. "1.001", "5.001")
--- @param value any Lua value to encode
--- @return KnxData
function dpt.encode(dpt_id, value)
  local spec = dpt.get_dpt(dpt_id)
  if not spec then error(string.format("Unsupported DPT: %s", tostring(dpt_id)), 2) end
  local raw = spec.encode(value)
  return KnxData(raw, spec.is_short_frame)
end

--- Decode a KnxData instance into a native Lua value for a given DPT
--- @param dpt_id string|number DPT identifier (e.g. "1.001", "5.001")
--- @param knx_data KnxData Inbound KnxData instance
--- @return any Decoded native Lua value
function dpt.decode(dpt_id, knx_data)
  local spec = dpt.get_dpt(dpt_id)
  if not spec then error(string.format("Unsupported DPT: %s", tostring(dpt_id)), 2) end
  return spec.decode(knx_data.raw)
end

--- Create a KnxData instance from string payload and type descriptor
--- Used by custom capabilities and CLI tools (dpt1..232, raw, raw_short_frame)
--- @param data_type string|nil Data type string ("dpt1", "dpt5", "dpt9", "dpt232", "raw", "raw_short_frame")
--- @param payload string|nil String payload (e.g. "on"/"1", "255", "21.5", "0x0A8C", or hex "010A" / "0x010A" for raw)
--- @return KnxData
function dpt.encode_from_string(data_type, payload)
  data_type = string.lower(tostring(data_type or "raw")):match("^%s*(.-)%s*$")
  payload = tostring(payload or ""):match("^%s*(.-)%s*$")
  if data_type == "raw" or data_type == "raw_short_frame" then
    return KnxData(utils.hex_to_bytes(payload), data_type == "raw_short_frame")
  end
  local dpt_id = data_type:gsub("^dpt", "")
  local spec = dpt.get_dpt(dpt_id)
  if not spec then error(string.format("Unsupported DPT: %s", tostring(dpt_id)), 2) end
  local value = spec.cast and spec.cast(payload) or payload
  return dpt.encode(dpt_id, value)
end

return dpt
