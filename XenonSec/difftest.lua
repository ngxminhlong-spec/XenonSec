local Parser = dofile("parser.lua")
local Renamer = dofile("renamer.lua")
local Compiler = dofile("compiler.lua")
local Interp = dofile("interpreter.lua")

local function captureNative(src)
	local out = {}
	local realPrint = print
	local env_print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		out[#out + 1] = table.concat(parts, "\t")
	end
	local chunk = assert(load(src, "native", "t"))
	local oldPrint = _G.print
	_G.print = env_print
	local ok, err = pcall(chunk)
	_G.print = oldPrint
	if not ok then return nil, err end
	return table.concat(out, "\n")
end

local function captureVM(src)
	local out = {}
	local env_print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		out[#out + 1] = table.concat(parts, "\t")
	end
	local oldPrint = _G.print
	_G.print = env_print
	local ok, err = pcall(function()
		local ast = Parser.parse(src, "vmtest")
		Renamer.resolve(ast)
		local mod = Compiler.compile(ast)
		Interp.run(mod)
	end)
	_G.print = oldPrint
	if not ok then return nil, err end
	return table.concat(out, "\n")
end

local function test(name, src)
	local nativeOut, nativeErr = captureNative(src)
	local vmOut, vmErr = captureVM(src)
	if nativeErr and not vmErr then
		print("[FAIL] " .. name .. " -- native errored but VM didn't: " .. tostring(nativeErr))
		return false
	end
	if nativeOut ~= vmOut then
		print("[FAIL] " .. name)
		print("  native: " .. tostring(nativeOut))
		print("  vm    : " .. tostring(vmOut))
		if vmErr then print("  vm err: " .. tostring(vmErr)) end
		return false
	end
	print("[ OK ] " .. name)
	return true
end

return { test = test }
