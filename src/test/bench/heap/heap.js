'use strict'

// Array-based max heap, the same algorithm as heap.cy.
class Node {
    constructor(value) {
        this.value = value
    }
}

class Heap {
    #nodes = []

    insert(n) {
        const pos = this.#nodes.length
        this.#nodes.push(n)
        this.#siftUp(pos)
    }

    #siftUp(pos) {
        const nodes = this.#nodes
        while (pos !== 0) {
            const parent = (pos - 1) >> 1
            if (nodes[parent].value < nodes[pos].value) {
                this.#swap(pos, parent)
                pos = parent
            } else {
                break
            }
        }
    }

    #siftDown(pos) {
        const nodes = this.#nodes
        for (;;) {
            const left = pos * 2 + 1
            if (left >= nodes.length) break
            if (nodes[left].value > nodes[pos].value) {
                this.#swap(pos, left)
                pos = left
                continue
            }
            const right = left + 1
            if (right >= nodes.length) break
            if (nodes[right].value > nodes[pos].value) {
                this.#swap(pos, right)
                pos = right
                continue
            }
            break
        }
    }

    #swap(a, b) {
        const nodes = this.#nodes;
        [nodes[a], nodes[b]] = [nodes[b], nodes[a]]
    }

    pop() {
        const nodes = this.#nodes
        const top = nodes[0]
        nodes[0] = nodes[nodes.length - 1]
        nodes.pop()
        this.#siftDown(0)
        return top
    }
}

const start = performance.now()

const h = new Heap()
for (let i = 1; i < 20000; i++) {
    h.insert(new Node(i))
}

let sum = 0
for (let i = 1; i < 20000; i++) {
    sum += h.pop().value
}

console.log(`time: ${performance.now() - start}`)
console.log(sum)
