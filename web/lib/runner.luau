--------------------------------------------------------------------
-- XenonSec web playground :: Lune runner
--
-- Run as:  lune run runner.luau -- <libDir> <input.lua> <output.lua> <opts.json>
--
-- The obfuscator was written for plain Lua 5.1/5.3. Lune has no `dofile`,
-- and its `debug` table is read-only, so this runner provides both pieces
-- the obfuscator needs:
--   * dofile   : loads a sibling file (obfuscate.lua -> src/*.lua)
--   * the self-locating line `debug.getinfo(1, "S").source` is rewritten on
--     load to a helper that returns the path of the file being run.
-- Nothing else in the obfuscator is changed.
--------------------------------------------------------------------

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

-- Lune puts "--" at index 1, so the user arguments start at index 2.
local libDir = process.args[2]
local inPath = process.args[3]
local outPath = process.args[4]
local optsPath = process.args[5]

local chunkStack = {}

_XS_SOURCE = function()
	return "@" .. chunkStack[#chunkStack]
end

dofile = function(path)
	local text = fs.readFile(path):gsub('debug%.getinfo%(1, "S"%)%.source', "_XS_SOURCE()")
	local fn, err = loadstring(text, "@" .. path)
	assert(fn, err)
	table.insert(chunkStack, path)
	local results = table.pack(fn())
	table.remove(chunkStack)
	return table.unpack(results, 1, results.n)
end

local Obf = dofile(libDir .. "/obfuscate.lua")
local source = fs.readFile(inPath)
local opts = serde.decode("json", fs.readFile(optsPath))

local ok, result = pcall(Obf.obfuscate, source, "input.lua", opts)
if not ok then
	print("ERR " .. tostring(result))
	process.exit(1)
end

fs.writeFile(outPath, result)
print("OK " .. #result)
