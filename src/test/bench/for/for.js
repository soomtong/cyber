'use strict'

const start = performance.now()

const arr = []
for (let i = 0; i < 1_000_000; i++) {
    arr.push(i)
}

let sum = 0
for (const i of arr) {
    sum += i
}

console.log(`time: ${performance.now() - start}`)
console.log(sum)
