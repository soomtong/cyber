use os

-- The needle's first byte appears every 32 bytes, which stops first-byte scans (memchr) often.
-- index_rare.cy covers a needle whose first byte never appears.
s := 'abcdefghijklmnopqrstuvwxyz123456'.repeat(1000000)
s += 'waldo'

start := os.now()!
idx := 0
for 0..50:
    idx = s.index('waldo').?

print('time: %{float(os.now()! - start) / 1000000}')
print(idx)