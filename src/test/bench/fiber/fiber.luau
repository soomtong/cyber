--!strict
--!native
--!optimize 2

local start = os.clock()
local count = 0

local function inc()
    count += 1
    coroutine.yield()
    count += 1
end

local list: {thread} = {}
for i = 1, 100000 do
    local co = coroutine.create(inc)
    coroutine.resume(co)
    list[i] = co
end

for _, co in list do
    coroutine.resume(co)
end

print(`time: {(os.clock() - start) * 1000}`)
print(count)
