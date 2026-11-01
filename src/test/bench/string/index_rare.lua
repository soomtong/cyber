local clock = os.clock
local find = string.find

-- Same as index.lua but the needle starts with a byte that never appears in the haystack.
local str = string.rep("abcdefghijklmnopqrstuvwxyz123456", 1000000) .. "Waldo"

local start = clock()
local idx = 0
for _ = 1, 50 do
    idx = find(str, "Waldo", 1, true) - 1
end

print(string.format("time: %f", (clock() - start) * 1000))
print(idx)
