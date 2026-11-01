-- Round-trip test for the proto record codec. The LZSS compressor (lzCompress
-- in bundle.lua) and the decoder (%lzd% in templates/header.lua) are pulled
-- out of the source text, so the test exercises exactly what ships.
-- Run from the project root: texlua tests/codec_test.lua
local TEST_DIR = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./")
local SRC = TEST_DIR .. "../src/"

local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- Returns the source from startPat through the end of endPat.
local function extract(text, startPat, endPat)
  local a = text:find(startPat, 1, true)
  assert(a, "missing: " .. startPat)
  local _, b = text:find(endPat, a, true)
  assert(b, "missing end: " .. endPat)
  return text:sub(a, b)
end

local bundleSrc = readFile(SRC .. "obfuscator/bundle.lua")
local headerSrc = readFile(SRC .. "obfuscator/templates/header.lua")

local compressSrc = extract(bundleSrc, "local function lzCompress(s)",
  "return table.concat(out)\n  end")
local compress = assert(load(compressSrc .. "\nreturn lzCompress"))()

-- Template placeholders %name% become plain names; the runtime's captured
-- byte/char/concat are provided locally.
local decodeSrc = extract(headerSrc, "local function %lzd%(%s%)",
  "return %concat%(%chars%)\nend")
decodeSrc = decodeSrc:gsub("%%(%w+)%%", "%1")
local decode = assert(load("local byte, char, concat = string.byte, string.char, table.concat\n"
  .. decodeSrc .. "\nreturn lzd"))()

local pass, total = 0, 0
local function check(name, cond, detail)
  total = total + 1
  if cond then
    pass = pass + 1
  else
    print("FAIL: " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

math.randomseed(20260101)

local function randomBytes(n)
  local t = {}
  for i = 1, n do t[i] = string.char(math.random(0, 255)) end
  return table.concat(t)
end

-- 12-byte raw records shaped like real proto plaintext: small operands,
-- mostly zero high bytes.
local function recordBytes(n)
  local t = {}
  for i = 1, n do
    local vals = { math.random(0, 60), math.random(0, 20), math.random(0, 255), math.random(0, 3) }
    for _, v in ipairs(vals) do
      t[#t + 1] = string.char(math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)
    end
  end
  return table.concat(t)
end

local block = randomBytes(3000)
local far = randomBytes(5000)
local cases = {
  { "empty", "" },
  { "one byte", "\0" },
  { "two bytes", "ab" },
  { "three equal bytes", "aaa" },
  { "run of one byte", string.rep("x", 1000) },
  { "repeating phrase", string.rep("abcdefgh", 500) },
  { "random bytes", randomBytes(5000) },
  { "records", recordBytes(300) },
  -- Copy source lies inside the 4096-byte window.
  { "match at distance under 4096", block .. randomBytes(200) .. block },
  -- Copy source lies beyond the window, so the encoder must not use it.
  { "match beyond the window", far .. far:sub(1, 100) .. far:sub(1, 100) },
}

local rawTotal, packedTotal = 0, 0
for _, c in ipairs(cases) do
  local name, s = c[1], c[2]
  local packed = compress(s)
  local back = decode(packed)
  check("round trip: " .. name, back == s,
    string.format("len %d -> %d -> %d", #s, #packed, #back))
  rawTotal = rawTotal + #s
  packedTotal = packedTotal + #packed
end

-- The record data should shrink, or the redesign is not worth shipping.
local rec = recordBytes(400)
local recPacked = compress(rec)
check("records compress below raw size", #recPacked < #rec,
  string.format("%d -> %d", #rec, #recPacked))
check("decoded header length matches", #decode(recPacked) == #rec)

-- Corrupted input must not decode to the original (guards against a decoder
-- that ignores the stream).
local corrupt = recPacked:sub(1, 20) .. string.char((recPacked:byte(21) + 1) % 256) .. recPacked:sub(22)
local ok, out = pcall(decode, corrupt)
check("corrupted stream does not round trip", not ok or out ~= rec)

print(string.format("codec_test: %d/%d passed (raw %d bytes -> %d packed across cases)",
  pass, total, rawTotal, packedTotal))
if pass ~= total then os.exit(1) end
