'use strict'

const start = performance.now()
let count = 0

function* inc() {
    count += 1
    yield
    count += 1
}

const gens = []
for (let i = 0; i < 100_000; i++) {
    const g = inc()
    g.next()
    gens.push(g)
}

for (const g of gens) {
    g.next()
}

console.log(`time: ${performance.now() - start}`)
console.log(count)
