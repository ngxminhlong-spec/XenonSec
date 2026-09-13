#!/usr/bin/env lua
--------------------------------------------------------------------
-- XenonSec CLI
--   lua xenonsec.lua <input.lua> [-o output.lua]
--------------------------------------------------------------------

local scriptDir = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./")
local Obf = dofile(scriptDir .. "obfuscate.lua")

local function usage()
  io.stderr:write([[
XenonSec :: VM-based Lua 5.1 Obfuscator

Usage:
  lua xenonsec.lua <input.lua> [options]

Options:
  -o <file>        Output path (default: <input>.xenon.lua)
  --no-minify      Keep the generated VM/header readable (debugging)
  --no-fold        Disable constant folding of literal arithmetic
  --no-localize    Disable global localization (local aliases for globals)
  --no-ssa         Disable SSA-style value propagation / dead-store elimination
  --luau           Parse input as Luau (compound ops, continue, type
                   annotations, if-expressions, // floor division)
  --junk <0..1>    Junk-instruction injection rate (default 0.12, 0 disables)
  --decoys <n>     Number of decoy constants to inject (default: randomized)
  -h               Show this help

]])
end

local args = { ... }
if #args == 0 and arg then
  -- Fallback for host runtimes (e.g. texlua) that only populate the
  -- global `arg` table and don't forward CLI args through `...`.
  local i = 1
  while arg[i] do args[i] = arg[i]; i = i + 1 end
end
if #args == 0 or args[1] == "-h" or args[1] == "--help" then
  usage()
  os.exit(#args == 0 and 1 or 0)
end

local inputPath = args[1]
local outputPath = nil
local opts = {}
local i = 2
while i <= #args do
  local a = args[i]
  if a == "-o" then
    outputPath = args[i + 1]; i = i + 2
  elseif a == "--no-minify" then
    opts.minify = false; i = i + 1
  elseif a == "--no-fold" then
    opts.fold = false; i = i + 1
  elseif a == "--no-localize" then
    opts.localizeGlobals = false; i = i + 1
  elseif a == "--no-ssa" then
    opts.ssa = false; i = i + 1
  elseif a == "--luau" then
    opts.luau = true; i = i + 1
  elseif a == "--junk" then
    opts.junkRate = tonumber(args[i + 1]); i = i + 2
  elseif a == "--decoys" then
    opts.decoyConstants = tonumber(args[i + 1]); i = i + 2
  else
    io.stderr:write("Unknown argument: " .. tostring(a) .. "\n")
    os.exit(1)
  end
end

if not outputPath then
  outputPath = inputPath:gsub("%.lua$", "") .. ".xenon.lua"
end

local f, openErr = io.open(inputPath, "r")
if not f then
  io.stderr:write("Cannot open input file: " .. tostring(openErr) .. "\n")
  os.exit(1)
end
local source = f:read("*a")
f:close()

local ok, result = pcall(Obf.obfuscate, source, inputPath, opts)
if not ok then
  io.stderr:write("XenonSec: obfuscation failed:\n  " .. tostring(result) .. "\n")
  os.exit(1)
end

local out, writeErr = io.open(outputPath, "w")
if not out then
  io.stderr:write("Cannot open output file: " .. tostring(writeErr) .. "\n")
  os.exit(1)
end
out:write(result)
out:close()

print("XenonSec: wrote " .. outputPath .. " (" .. #result .. " bytes)")
