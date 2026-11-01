--!strict
--!native
--!optimize 2

local str = string.rep("abcdefghijklmnopqrstuvwxyz123456", 1000000) .. "waldo"

local start = os.clock()
local idx = 0
for _ = 1, 50 do
    -- Plain find, 1-based. Report the 0-based index like the other benches.
    idx = (string.find(str, "waldo", 1, true) :: number) - 1
end

print(`time: {(os.clock() - start) * 1000}`)
print(idx)
