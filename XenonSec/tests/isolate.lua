--------------------------------------------------------------------
-- Runs a Lua chunk in a fresh interpreter process and returns its result.
--
-- Why a process: the test harnesses used to capture output by replacing
-- `print` in the SAME process. Since the anti-debug guard now treats a
-- replaced print as an env logger (on purpose), that capture itself looked
-- like tampering. A separate process keeps the protected code's view of
-- `print` untouched, so "anti-debug changes nothing on normal runs" is tested
-- honestly. Tests that simulate a logger still do it in-process on purpose.
--
--   ok, err, output = Iso.exec(source)
--     ok      true when the process exited 0
--     err     stderr text when it failed (nil on success)
--     output  stdout, without the final newline
--------------------------------------------------------------------
local M = {}
local interp = (arg and arg[-1]) or "texlua"

local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local s = f:read("*a")
  f:close()
  return s
end

function M.exec(source)
  local base = os.tmpname()
  local src, outf, errf = base .. ".lua", base .. ".out", base .. ".err"
  local f = assert(io.open(src, "wb"))
  f:write(source)
  f:close()
  -- Lua 5.1 returns the exit status as a number; 5.2+ returns true/nil, "exit", code.
  local r1, _, code = os.execute(string.format('"%s" "%s" > "%s" 2> "%s"', interp, src, outf, errf))
  local success
  if type(r1) == "number" then success = (r1 == 0) else success = (r1 == true) or (code == 0) end
  local rc = success and 0 or (type(r1) == "number" and r1 or code or 1)
  local out = readAll(outf):gsub("\n$", "")
  local err = readAll(errf)
  os.remove(src); os.remove(outf); os.remove(errf); os.remove(base)
  if rc == 0 then return true, nil, out end
  return false, (err ~= "" and err or ("exit " .. tostring(rc))), out
end

return M
