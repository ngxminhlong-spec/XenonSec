-- ============================================================================
-- ADVANCED LUA OBFUSCATION BENCHMARK SUITE (FULL VERSION)
-- ============================================================================

local AdvancedBench = {}
AdvancedBench.__index = AdvancedBench

function AdvancedBench.new()
    local self = setmetatable({}, AdvancedBench)
    self.tests = {}
    self.results = {}
    return self
end

function AdvancedBench:add(name, category, func)
    table.insert(self.tests, { name = name, category = category, func = func })
end

local function getTime()
    return (os and os.clock) and os.clock() or (tick and tick() or 0)
end

local function getMem()
    collectgarbage("collect")
    return collectgarbage("count")
end

function AdvancedBench:run(iterations)
    iterations = iterations or 1
    self.results = {}

    print("\n=======================================================================")
    print("           LUA BENCHMARK SUITE - ADVANCED OBFUSCATION TEST             ")
    print("=======================================================================")
    print(string.format("Số vòng lặp thực thi mỗi bài: %d", iterations))
    print("-----------------------------------------------------------------------")

    local globalStartTime = getTime()
    local globalStartMem = getMem()

    for i, test in ipairs(self.tests) do
        collectgarbage("collect")
        
        local startMem = getMem()
        local startTime = getTime()

        for _ = 1, iterations do
            test.func()
        end

        local endTime = getTime()
        local endMem = getMem()

        local duration = math.max(0, (endTime - startTime) * 1000) -- ms
        local memAlloc = math.max(0, endMem - startMem) -- KB

        table.insert(self.results, {
            id = i,
            name = test.name,
            category = test.category,
            time = duration,
            mem = memAlloc
        })

        print(string.format("[%02d/%02d] %-12s | %-28s | %8.2f ms | %6.2f KB", 
            i, #self.tests, "[" .. test.category .. "]", test.name, duration, memAlloc))
    end

    local globalEndTime = getTime()
    local globalEndMem = getMem()

    -- In báo cáo tổng hợp
    print("-----------------------------------------------------------------------")
    print(string.format("TỔNG THỜI GIAN CHẠY : %10.2f ms", (globalEndTime - globalStartTime) * 1000))
    print(string.format("TỔNG RAM BIẾN ĐỘNG  : %10.2f KB", math.max(0, globalEndMem - globalStartMem)))
    print("=======================================================================\n")
end

local suite = AdvancedBench.new()

-- ============================================================================
-- 1. MATH & NUMERICAL COMPUTATION (Tính toán số học & Vòng lặp)
-- ============================================================================
suite:add("Math heavy loop", "MATH", function()
    local a = 0
    for i = 1, 2000000 do
        a = a + math.sin(i) * math.cos(i) + math.tan(i % 360 + 1)
    end
end)

suite:add("Bitwise operations", "MATH", function()
    local x = 0xFFFFFFFF
    for i = 1, 1000000 do
        -- Tự giả lập phép bitwise XOR / AND đơn giản nếu môi trường không có bit32
        x = ((x * 3) + 13) % 4294967296
    end
end)

-- ============================================================================
-- 2. RECURSION & CALL STACK (Đệ quy & Quản lý Call Stack)
-- ============================================================================
local function fibonacci(n)
    if n <= 1 then return n end
    return fibonacci(n - 1) + fibonacci(n - 2)
end

suite:add("Deep Recursion (Fib 32)", "STACK", function()
    fibonacci(32)
end)

-- ============================================================================
-- 3. TABLE ALLOCATION & MATRIX (Thao tác mảng & Bảng đa chiều)
-- ============================================================================
suite:add("Table Allocation (100k)", "TABLE", function()
    local list = {}
    for i = 1, 100000 do
        list[i] = { id = i, key = "val_" .. i }
    end
end)

suite:add("Matrix Multiplication", "TABLE", function()
    local N = 120
    local A, B, C = {}, {}, {}
    for i = 1, N do
        A[i], B[i], C[i] = {}, {}, {}
        for j = 1, N do
            A[i][j] = i + j
            B[i][j] = i * j
            C[i][j] = 0
        end
    end
    for i = 1, N do
        for j = 1, N do
            for k = 1, N do
                C[i][j] = C[i][j] + A[i][k] * B[k][j]
            end
        end
    end
end)

-- ============================================================================
-- 4. STRING & PATTERN MATCHING (Xử lý chuỗi & Regex Lua)
-- ============================================================================
suite:add("String Concat & Matching", "STRING", function()
    local buffer = {}
    for i = 1, 10000 do
        table.insert(buffer, "node_" .. i .. "={val=" .. (i * 2) .. "}")
    end
    local fullStr = table.concat(buffer, ";")
    local count = 0
    for _ in string.gmatch(fullStr, "%d+") do
        count = count + 1
    end
end)

-- ============================================================================
-- 5. ALGORITHMS (Thuật toán QuickSort)
-- ============================================================================
local function quickSort(arr, low, high)
    if low < high then
        local pivot = arr[high]
        local i = low - 1
        for j = low, high - 1 do
            if arr[j] <= pivot then
                i = i + 1
                arr[i], arr[j] = arr[j], arr[i]
            end
        end
        arr[i + 1], arr[high] = arr[high], arr[i + 1]
        local p = i + 1
        quickSort(arr, low, p - 1)
        quickSort(arr, p + 1, high)
    end
end

suite:add("QuickSort (10k items)", "ALGO", function()
    local arr = {}
    for i = 1, 10000 do
        arr[i] = (i * 16807) % 2147483647
    end
    quickSort(arr, 1, #arr)
end)

-- ============================================================================
-- CHẠY CHƯƠNG TRÌNH BENCHMARK
-- ============================================================================
suite:run(1)
