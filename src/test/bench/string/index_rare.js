'use strict'

// Same as index.js but the needle starts with a byte that never appears in the haystack.
const str = 'abcdefghijklmnopqrstuvwxyz123456'.repeat(1_000_000) + 'Waldo'

const start = performance.now()
let idx = 0
for (let i = 0; i < 50; i++) {
    idx = str.indexOf('Waldo')
}

console.log(`time: ${performance.now() - start}`)
console.log(idx)
