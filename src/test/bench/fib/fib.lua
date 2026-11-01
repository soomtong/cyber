local clock = os.clock

local function fib(n)
    if n < 2 then return n end
    return fib(n - 1) + fib(n - 2)
end

local start = clock()
local res = fib(30)
print(string.format("time: %f", (clock() - start) * 1000))
print(res)
