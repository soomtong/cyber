local clock = os.clock
local find = string.find

local str = string.rep("abcdefghijklmnopqrstuvwxyz123456", 1000000) .. "waldo"

local start = clock()
local idx = 0
for _ = 1, 50 do
    -- Plain find, 1-based. Report the 0-based index like the other benches.
    idx = find(str, "waldo", 1, true) - 1
end

print(string.format("time: %f", (clock() - start) * 1000))
print(idx)
