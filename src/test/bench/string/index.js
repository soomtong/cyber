'use strict'

const str = 'abcdefghijklmnopqrstuvwxyz123456'.repeat(1_000_000) + 'waldo'

const start = performance.now()
let idx = 0
for (let i = 0; i < 50; i++) {
    idx = str.indexOf('waldo')
}

console.log(`time: ${performance.now() - start}`)
console.log(idx)
