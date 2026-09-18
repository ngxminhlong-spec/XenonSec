-- =====================================================
-- LUA 5.1 MICRO-BENCHMARK SUITE
-- Measure Execution Overhead (Ops / Time Elapsed)
-- =====================================================

local os_clock = os.clock
local math_floor = math.floor
local math_sin = math.sin
local math_cos = math.cos
local string_format = string.format
local table_insert = table.insert

local Benchmark = {}
Benchmark.results = {}

function Benchmark.run(name, iterations, fn)
    -- Flush garbage before testing each module
    collectgarbage("collect")
    
    local startTime = os_clock()
    fn(iterations)
    local endTime = os_clock()
    
    local elapsed = endTime - startTime
    table_insert(Benchmark.results, {
        name = name,
        time = elapsed,
        opsPerSec = (iterations / (elapsed > 0 and elapsed or 0.00001))
    })
end

-- =====================================================
-- BENCHMARK TESTS
-- =====================================================

-- Test 1: Tight Loop & Arithmetic Logic
Benchmark.run("Tight Loop & Basic Math", 5000000, function(n)
    local sum = 0
    for i = 1, n do
        sum = sum + (i % 7) * 3 - 1
    end
    return sum
end)

-- Test 2: Table Creation & Dynamic Allocation
Benchmark.run("Table Allocation & Access", 500000, function(n)
    local t = {}
    for i = 1, n do
        t[i] = { id = i, val = i * 2 }
    end
    local sum = 0
    for i = 1, n do
        sum = sum + t[i].val
    end
    return sum
end)

-- Test 3: String Manipulation & Formatting
Benchmark.run("String Concat & Formatting", 200000, function(n)
    local str = ""
    for i = 1, n do
        local temp = string_format("num_%d", i % 100)
        if i % 1000 == 0 then
            str = temp
        end
    end
    return str
end)

-- Test 4: OOP Metatables & Method Calls
Benchmark.run("Metatable Method Dispatch", 2000000, function(n)
    local Vector = {}
    Vector.__index = Vector
    function Vector.new(x, y)
        return setmetatable({x = x, y = y}, Vector)
    end
    function Vector:add(v)
        self.x = self.x + v.x
        self.y = self.y + v.y
    end

    local v1 = Vector.new(1, 2)
    local v2 = Vector.new(3, 4)
    for i = 1, n do
        v1:add(v2)
    end
    return v1.x
end)

-- Test 5: Closure Creation & Call Overhead
Benchmark.run("Closure & Scope Resolution", 2000000, function(n)
    local function makeAdder(x)
        return function(y)
            return x + y
        end
    end
    local adder = makeAdder(10)
    local sum = 0
    for i = 1, n do
        sum = sum + adder(i % 50)
    end
    return sum
end)

-- Test 6: Trigonometric Math & Floating Point
Benchmark.run("Trigonometry Computation", 1000000, function(n)
    local result = 0
    for i = 1, n do
        result = result + math_sin(i) * math_cos(i)
    end
    return result
end)

-- Test 7: Recursion Depth (Fibonacci)
Benchmark.run("Recursion Overhead (Fib 28)", 1, function()
    local function fib(k)
        if k < 2 then return k end
        return fib(k - 1) + fib(k - 2)
    end
    return fib(28)
end)

-- =====================================================
-- REPORT GENERATOR
-- =====================================================

local function displayResults()
    local totalTime = 0
    print("==========================================================")
    print("                LUA 5.1 BENCHMARK REPORT                  ")
    print("==========================================================")
    print(string_format("%-30s | %-10s | %-12s", "Test Name", "Time (s)", "Ops/Sec"))
    print("----------------------------------------------------------")
    
    for _, res in ipairs(Benchmark.results) do
        totalTime = totalTime + res.time
        print(string_format("%-30s | %-10.4f | %-12.0f", res.name, res.time, res.opsPerSec))
    end
    
    print("----------------------------------------------------------")
    print(string_format("%-30s | %-10.4f |", "TOTAL ELAPSED TIME", totalTime))
    print("==========================================================")
end

displayResults()

