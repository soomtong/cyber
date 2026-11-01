--!strict
--!native
--!optimize 2

local start = os.clock()

local list: {number} = {}
for i = 0, 999999 do
    list[i + 1] = i
end

local sum = 0
for _, i in list do
    sum += i
end

print(`time: {(os.clock() - start) * 1000}`)
print(string.format("%d", sum))
