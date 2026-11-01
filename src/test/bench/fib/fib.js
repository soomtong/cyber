'use strict'

function fib(n) {
    return n < 2 ? n : fib(n - 1) + fib(n - 2)
}

const start = performance.now()
const res = fib(30)
console.log(`time: ${performance.now() - start}`)
console.log(res)
