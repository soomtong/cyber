use os

start := os.now()!

type Node:
    value int

type Heap:
    nodes Array[Node]

fn Heap :: @init() -> Heap:
    return {nodes={}}

fn (&Heap) insert(n Node):
    pos := self.nodes.len()
    self.nodes.append(n)
    self.sift_up(pos)

fn (&Heap) sift_up(pos int):
    while pos != 0:
        parent := (pos - 1) / 2
        if self.nodes[parent].value < self.nodes[pos].value:
            self.swap(pos, parent)
            pos = parent
        else:
            break

fn (&Heap) sift_down(pos int):
    while:
        left := pos * 2 + 1
        if left >= self.nodes.len():
            break
        if self.nodes[left].value > self.nodes[pos].value:
            self.swap(pos, left)
            pos = left
            continue
        right := left + 1
        if right >= self.nodes.len():
            break
        if self.nodes[right].value > self.nodes[pos].value:
            self.swap(pos, right)
            pos = right
            continue
        break

fn (&Heap) swap(a int, b int):
    temp := self.nodes[a]
    self.nodes[a] = self.nodes[b]
    self.nodes[b] = temp

fn (&Heap) pop() -> Node:
    top := self.nodes[0]
    self.nodes[0] = self.nodes[self.nodes.len() - 1]
    self.nodes.remove(self.nodes.len() - 1)
    self.sift_down(0)
    return top

h := Heap()
for 1..20000 |i|:
    h.insert(Node{value=i})

sum := 0
for 1..20000:
    sum += h.pop().value

print('time: %{float(os.now()! - start) / 1000000}')
print(sum)
