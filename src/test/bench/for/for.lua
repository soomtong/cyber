local clock = os.clock

local start = clock()

-- 1-based keys stay in the table's array part.
local list = {}
for i = 0, 999999 do
    list[i + 1] = i
end

local sum = 0
for j = 1, #list do
    sum = sum + list[j]
end

print(string.format("time: %f", (clock() - start) * 1000))
print(string.format("%d", sum))
