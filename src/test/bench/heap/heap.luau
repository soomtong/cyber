--!strict
--!native
--!optimize 2

-- Array-based max heap, the same algorithm as heap.cy (1-based indices).
type Node = { value: number }

local Heap = {}
Heap.__index = Heap

type Heap = typeof(setmetatable({} :: { nodes: {Node}, n: number }, Heap))

function Heap.new(): Heap
    return setmetatable({ nodes = {}, n = 0 }, Heap)
end

function Heap.swap(self: Heap, a: number, b: number)
    local nodes = self.nodes
    nodes[a], nodes[b] = nodes[b], nodes[a]
end

function Heap.sift_up(self: Heap, pos: number)
    local nodes = self.nodes
    while pos ~= 1 do
        local parent = pos // 2
        if nodes[parent].value < nodes[pos].value then
            self:swap(pos, parent)
            pos = parent
        else
            break
        end
    end
end

function Heap.sift_down(self: Heap, pos: number)
    local nodes = self.nodes
    while true do
        local left = pos * 2
        if left > self.n then break end
        if nodes[left].value > nodes[pos].value then
            self:swap(pos, left)
            pos = left
            continue
        end
        local right = left + 1
        if right > self.n then break end
        if nodes[right].value > nodes[pos].value then
            self:swap(pos, right)
            pos = right
            continue
        end
        break
    end
end

function Heap.insert(self: Heap, node: Node)
    local n = self.n + 1
    self.n = n
    self.nodes[n] = node
    self:sift_up(n)
end

function Heap.pop(self: Heap): Node
    local nodes, n = self.nodes, self.n
    local top = nodes[1]
    nodes[1] = nodes[n]
    nodes[n] = nil :: any
    self.n = n - 1
    self:sift_down(1)
    return top
end

local start = os.clock()

local h = Heap.new()
for i = 1, 19999 do
    h:insert({ value = i })
end

local sum = 0
for _ = 1, 19999 do
    sum += h:pop().value
end

print(`time: {(os.clock() - start) * 1000}`)
print(sum)
