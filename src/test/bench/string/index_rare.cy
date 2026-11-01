use os

-- Same as index.cy but the needle starts with a byte that never appears in the haystack.
-- First-byte scans (memchr) run without stopping here, unlike in index.cy.
s := 'abcdefghijklmnopqrstuvwxyz123456'.repeat(1000000)
s += 'Waldo'

start := os.now()!
idx := 0
for 0..50:
    idx = s.index('Waldo').?

print('time: %{float(os.now()! - start) / 1000000}')
print(idx)
