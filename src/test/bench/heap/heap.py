import time
from dataclasses import dataclass


# Array-based max heap, the same algorithm as heap.cy.
@dataclass(slots=True)
class Node:
    value: int


class Heap:
    __slots__ = ("nodes",)

    def __init__(self) -> None:
        self.nodes: list[Node] = []

    def insert(self, n: Node) -> None:
        pos = len(self.nodes)
        self.nodes.append(n)
        self.sift_up(pos)

    def sift_up(self, pos: int) -> None:
        nodes = self.nodes
        while pos != 0:
            parent = (pos - 1) // 2
            if nodes[parent].value < nodes[pos].value:
                self.swap(pos, parent)
                pos = parent
            else:
                break

    def sift_down(self, pos: int) -> None:
        nodes = self.nodes
        while True:
            left = pos * 2 + 1
            if left >= len(nodes):
                break
            if nodes[left].value > nodes[pos].value:
                self.swap(pos, left)
                pos = left
                continue
            right = left + 1
            if right >= len(nodes):
                break
            if nodes[right].value > nodes[pos].value:
                self.swap(pos, right)
                pos = right
                continue
            break

    def swap(self, a: int, b: int) -> None:
        nodes = self.nodes
        nodes[a], nodes[b] = nodes[b], nodes[a]

    def pop(self) -> Node:
        nodes = self.nodes
        top = nodes[0]
        nodes[0] = nodes[-1]
        nodes.pop()
        self.sift_down(0)
        return top


def main() -> None:
    start = time.perf_counter()

    h = Heap()
    for i in range(1, 20000):
        h.insert(Node(i))

    total = 0
    for _ in range(1, 20000):
        total += h.pop().value

    print(f"time: {(time.perf_counter() - start) * 1000}")
    print(total)


if __name__ == "__main__":
    main()
