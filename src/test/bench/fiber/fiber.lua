local clock = os.clock
local cocreate, coresume, coyield = coroutine.create, coroutine.resume, coroutine.yield

local start = clock()
local count = 0

local function inc()
    count = count + 1
    coyield()
    count = count + 1
end

local list = {}
for i = 1, 100000 do
    local co = cocreate(inc)
    coresume(co)
    list[i] = co
end

for i = 1, #list do
    coresume(list[i])
end

print(string.format("time: %f", (clock() - start) * 1000))
print(count)
