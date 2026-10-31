--------------------------------------------------------------------
-- XenonSec :: passes.lua
--   flatten -- control-flow flattening: shuffled basic blocks, explicit
--              fall-through jumps, and dead decoy blocks.
--
-- Runs on the compiled register code, after junk injection and before the
-- bundler. Every jump target is remapped exactly, so behavior is unchanged;
-- the test suites check this on every build.
--------------------------------------------------------------------

local Passes = {}

-- Which operand field of each jump opcode holds the target instruction index.
local JUMP_FIELD = { JMP = "a", JF = "b", JT = "b", JNIL = "b" }
Passes.JUMP_FIELD = JUMP_FIELD

-- Opcodes after which control never falls through to the next instruction.
local NO_FALLTHROUGH = { JMP = true, RET = true, RETM = true }

local function jumpTargets(code)
	local t = {}
	for _, ins in ipairs(code) do
		local f = JUMP_FIELD[ins.op]
		if f then t[ins[f]] = true end
	end
	return t
end

-- Decoy blocks run harmless register writes that nothing can reach.
local DECOY_TEMPLATES = {
	{ op = "LOADNIL", a = 1, b = 1 },
	{ op = "LOADTRUE", a = 1 },
	{ op = "NEWTABLE", a = 1 },
}

--------------------------------------------------------------------
-- Control-flow flattening
--
-- 1. Give every proto an explicit RET at its end (falling off the end
--    already returns nothing, so this is the same behavior).
-- 2. Split the code into basic blocks at every jump target and after every
--    jump or return.
-- 3. Lay the blocks out in a shuffled order (the entry block stays first),
--    and add dead decoy blocks. Decoys chain into each other and into real
--    blocks, so the dead region has edges of its own, not isolated stubs.
-- 4. A block that could fall through gets an explicit JMP to its original
--    successor, appended at its end. For a conditional jump, that JMP runs
--    exactly when the condition takes the fall-through path.
-- 5. Opaque edges: before some of those JMPs, a conditional jump on a
--    scratch register that is always falsy (LOADNIL + JT) or always truthy
--    (LOADTRUE + JNIL). It is never taken, but it is a real edge to a decoy
--    block in the graph. Blocks ending in a multi-result producer get none,
--    since a scratch write there could clobber pending values.
-- 6. Remap every jump to the new position of its target block.
--------------------------------------------------------------------

local OPAQUE_P = 0.5

local function isMultiProducer(ins)
	return ((ins.op == "CALL" or ins.op == "CALLM") and ins.c == 0)
		or (ins.op == "VARARG" and ins.b == 0)
end

function Passes.flatten(mod, rng, fakeScale)
	rng = rng or math.random
	fakeScale = fakeScale or 1
	local blocksTotal, fakeTotal, opaqueTotal = 0, 0, 0

	for _, proto in ipairs(mod.protos) do
		local code = proto.code
		code[#code + 1] = { op = "RET", a = 1, b = 1 }
		local n = #code

		-- One scratch register past every real one, for the opaque predicates.
		local scratch = (proto.nregs or 0) + 1
		proto.nregs = scratch

		-- Block leaders.
		local leaders = jumpTargets(code)
		leaders[1] = true
		for i = 1, n do
			local ins = code[i]
			if JUMP_FIELD[ins.op] or ins.op == "RET" or ins.op == "RETM" then
				if i + 1 <= n then leaders[i + 1] = true end
			end
		end

		local starts = {}
		for i = 1, n do if leaders[i] then starts[#starts + 1] = i end end
		local blocks, blockOfStart = {}, {}
		for kk, s in ipairs(starts) do
			local e = (starts[kk + 1] or (n + 1)) - 1
			blocks[kk] = { s = s, e = e }
			blockOfStart[s] = kk
		end
		local nb = #blocks

		-- Layout: entry first, the rest shuffled.
		local layout = { 1 }
		local rest = {}
		for kk = 2, nb do rest[#rest + 1] = kk end
		for kk = #rest, 2, -1 do
			local j = rng(1, kk)
			rest[kk], rest[j] = rest[j], rest[kk]
		end
		for _, kk in ipairs(rest) do layout[#layout + 1] = kk end

		-- Dead decoy blocks. A decoy's successor is a real block or an earlier
		-- decoy (keys "f<k>"), so the dead region forms its own small graph.
		local fakeCount = math.floor(nb * 0.6 * fakeScale) + 2
		local fakes = {}
		for f = 1, fakeCount do
			local body = {}
			for _ = 1, rng(1, 3) do
				local tpl = DECOY_TEMPLATES[rng(1, #DECOY_TEMPLATES)]
				local copy = {}
				for kk, v in pairs(tpl) do copy[kk] = v end
				body[#body + 1] = copy
			end
			local target
			if f > 1 and rng(1, 2) == 1 then
				target = "f" .. rng(1, f - 1)
			else
				target = rng(1, nb)
			end
			fakes[f] = { body = body, jumpTo = target }
			local at = rng(2, #layout + 1)
			table.insert(layout, at, { fake = f })
		end

		-- Emit in layout order, recording where each block starts.
		local out, newStart, pending = {}, {}, {}
		for _, item in ipairs(layout) do
			if type(item) == "number" then
				local blk = blocks[item]
				newStart[item] = #out + 1
				for i = blk.s, blk.e do
					local copy = {}
					for kk, v in pairs(code[i]) do copy[kk] = v end
					out[#out + 1] = copy
					local f = JUMP_FIELD[copy.op]
					if f then
						-- The original target is an old index; it is a block start.
						pending[#out] = { field = f, block = blockOfStart[copy[f]] }
					end
				end
				local last = code[blk.e]
				if not NO_FALLTHROUGH[last.op] then
					if not isMultiProducer(last) and rng() < OPAQUE_P then
						local dead = "f" .. rng(1, fakeCount)
						if rng(1, 2) == 1 then
							out[#out + 1] = { op = "LOADNIL", a = scratch, b = 1 }
							out[#out + 1] = { op = "JT", a = scratch }
						else
							out[#out + 1] = { op = "LOADTRUE", a = scratch }
							out[#out + 1] = { op = "JNIL", a = scratch }
						end
						pending[#out] = { field = "b", block = dead }
						opaqueTotal = opaqueTotal + 1
					end
					out[#out + 1] = { op = "JMP", a = 0 }
					pending[#out] = { field = "a", block = item + 1 }
				end
			else
				newStart["f" .. item.fake] = #out + 1
				local fk = fakes[item.fake]
				for _, copy in ipairs(fk.body) do out[#out + 1] = copy end
				out[#out + 1] = { op = "JMP", a = 0 }
				pending[#out] = { field = "a", block = fk.jumpTo }
			end
		end

		-- Resolve every jump to its block's new start.
		for pos, p in pairs(pending) do
			out[pos][p.field] = newStart[p.block]
		end

		proto.code = out
		blocksTotal = blocksTotal + nb
		fakeTotal = fakeTotal + fakeCount
	end
	return blocksTotal, fakeTotal, opaqueTotal
end

-- State barriers. The runtime resets its decode state after every jump and
-- RET (see STATE_RESET). A jump target reached by fall-through from an
-- ordinary instruction would otherwise be decoded with a state the jumps
-- never produce, so a JMP-to-next barrier is placed in front of it. The
-- barrier only moves control to the next instruction, so semantics do not change.
local STATE_RESET = { JMP = true, JF = true, JT = true, JNIL = true, RET = true, RETM = true }
Passes.STATE_RESET = STATE_RESET

function Passes.insertStateBarriers(mod)
	for _, proto in ipairs(mod.protos) do
		local code = proto.code
		local targets = {}
		for _, ins in ipairs(code) do
			local f = JUMP_FIELD[ins.op]
			if f then targets[ins[f]] = true end
		end
		local out, newIdx, barrierFor = {}, {}, {}
		for i, ins in ipairs(code) do
			if targets[i] and i > 1 and not STATE_RESET[code[i - 1].op] then
				out[#out + 1] = { op = "JMP", a = 0, barrier = true }
				barrierFor[#out] = i
			end
			out[#out + 1] = ins
			newIdx[i] = #out
		end
		for pos, ins in ipairs(out) do
			if ins.barrier then
				ins.a = newIdx[barrierFor[pos]]
			else
				local f = JUMP_FIELD[ins.op]
				if f then ins[f] = newIdx[ins[f]] end
			end
		end
		proto.code = out
	end
end

return Passes
