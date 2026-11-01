-- Array-based max heap, the same algorithm as heap.cy (1-based indices).
-- Runs on Lua 5.1+ and LuaJIT.
local clock = os.clock
local floor = math.floor

local Heap = {}
Heap.__index = Heap

function Heap.new()
    return setmetatable({ nodes = {}, n = 0 }, Heap)
end

function Heap:swap(a, b)
    local nodes = self.nodes
    nodes[a], nodes[b] = nodes[b], nodes[a]
end

function Heap:sift_up(pos)
    local nodes = self.nodes
    while pos ~= 1 do
        local parent = floor(pos / 2)
        if nodes[parent].value < nodes[pos].value then
            self:swap(pos, parent)
            pos = parent
        else
            break
        end
    end
end

function Heap:sift_down(pos)
    local nodes = self.nodes
    while true do
        local left = pos * 2
        if left > self.n then break end
        if nodes[left].value > nodes[pos].value then
            self:swap(pos, left)
            pos = left
        else
            local right = left + 1
            if right > self.n then break end
            if nodes[right].value > nodes[pos].value then
                self:swap(pos, right)
                pos = right
            else
                break
            end
        end
    end
end

function Heap:insert(node)
    local n = self.n + 1
    self.n = n
    self.nodes[n] = node
    self:sift_up(n)
end

function Heap:pop()
    local nodes, n = self.nodes, self.n
    local top = nodes[1]
    nodes[1] = nodes[n]
    nodes[n] = nil
    self.n = n - 1
    self:sift_down(1)
    return top
end

local start = clock()

local h = Heap.new()
for i = 1, 19999 do
    h:insert({ value = i })
end

local sum = 0
for _ = 1, 19999 do
    sum = sum + h:pop().value
end

print(string.format("time: %f", (clock() - start) * 1000))
print(sum)
