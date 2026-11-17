use test

-- The search for one byte compares 128 bytes at a time (four 32-byte blocks with AVX2). A byte at every position of
-- a 128-byte block and of the blocks after it is found at its own index, also by `split` and `index_byte`.
for {128, 160, 256, 300} |n|:
    for 0..n |pos|:
        s := '-'.repeat(pos) + '\n' + '-'.repeat(n - pos - 1)
        test.eq(pos, s.index('\n').?)
        test.eq(pos, s.index(byte('\n')).?)
        test.eq(pos, s.split('\n')[0].len())

-- Two hits in different blocks: the first one wins.
s := '-'.repeat(100) + 'x' + '-'.repeat(20) + 'x' + '-'.repeat(40)
test.eq(100, s.index('x').?)
test.eq(true, '-'.repeat(256).index('x') == none)

--cytest: pass
