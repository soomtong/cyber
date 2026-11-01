--!strict
--!native
--!optimize 2

local function fib(n: number): number
    if n < 2 then return n end
    return fib(n - 1) + fib(n - 2)
end

local start = os.clock()
local res = fib(30)
print(`time: {(os.clock() - start) * 1000}`)
print(res)
