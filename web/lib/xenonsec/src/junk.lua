--------------------------------------------------------------------
-- XenonSec :: junk.lua
-- Splices JUNK instructions through each proto's register code. A JUNK
-- writes a constant into a scratch register that no real instruction uses,
-- so it can go anywhere. Every jump target is remapped to the new position
-- of its instruction, so control flow is unchanged.
--------------------------------------------------------------------

local Junk = {}

local JUMP_FIELD = { JMP = "a", JF = "b", JT = "b", JNIL = "b" }

function Junk.inject(mod, rate)
	rate = rate or 0.12
	for _, proto in ipairs(mod.protos) do
		local old = proto.code
		local scratch = (proto.nregs or 0) + 1
		proto.nregs = scratch
		-- A constant for the junk writes. Its value is never observed.
		mod.consts[#mod.consts + 1] = 0
		local junkConst = #mod.consts

		-- A multi-result producer (CALL or CALLM with c = 0, VARARG with b = 0)
		-- leaves its values in registers that may lie above `scratch`; the
		-- consumer that follows (CALLM, RETM, SETLISTM) reads them. Junk must not
		-- go between the two, or it would overwrite those values. A CALLM with
		-- c = 0 is both: it consumes one window and produces the next, as in
		-- f(g(h())), so the consumer check must run before the producer check.
		local newCode, map = {}, {}
		local inMulti = false
		for i = 1, #old do
			local ins = old[i]
			if not inMulti and math.random() < rate then
				newCode[#newCode + 1] = { op = "JUNK", a = scratch, b = junkConst }
			end
			newCode[#newCode + 1] = ins
			map[i] = #newCode
			if ins.op == "CALLM" or ins.op == "RETM" or ins.op == "SETLISTM" then
				inMulti = false
			end
			if (ins.op == "CALL" or ins.op == "CALLM") and ins.c == 0
				or (ins.op == "VARARG" and ins.b == 0) then
				inMulti = true
			end
		end
		map[#old + 1] = #newCode + 1
		for _, ins in ipairs(newCode) do
			local f = JUMP_FIELD[ins.op]
			if f then ins[f] = map[ins[f]] end
		end
		proto.code = newCode
	end
end

return Junk
