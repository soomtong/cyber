--!strict
--!native
--!optimize 2

-- Same as index.luau but the needle starts with a byte that never appears in the haystack.
local str = string.rep("abcdefghijklmnopqrstuvwxyz123456", 1000000) .. "Waldo"

local start = os.clock()
local idx = 0
for _ = 1, 50 do
    idx = (string.find(str, "Waldo", 1, true) :: number) - 1
end

print(`time: {(os.clock() - start) * 1000}`)
print(idx)
