-- Reads stdin. `src/tools/verify.sh` (step 16) pipes this input to it:
--   'Ann\nx\r\nabcdef\nl1\nl2\nlast' followed by 9000 `y` bytes, with no line break at the end.
-- Not a behavior test: the runner has no stdin to give.
use os
use io
use test

test.eq(false, os.stdin().is_terminal())

-- `input` prints its prompt only at a terminal: a pipe is not asked.
test.eq('Ann', os.input('Name: ')!.?)
-- `\r\n` is a line break too.
test.eq('x', os.read_line()!.?)

-- `File.read` of stdin gives what `read_line` read past its line first.
inp := os.stdin()
test.eq('abc', str(inp.read(3)!))
test.eq('def', inp.read_line()!.?)

n := 0
for os.stdin_lines() |line|:
    n += 1
    if n == 1:
        test.eq('l1', line)
    else n == 2:
        test.eq('l2', line)
    else:
        -- The last line has no line break and is longer than one read.
        test.eq('last' + 'y'.repeat(9000), line)
else |err|:
    panic(str(err))
test.eq(3, n)

-- The end of the input stays the end.
test.eq(true, os.read_line()! == none)
test.eq('', os.read_stdin()!)
test.eq(0, inp.read(10)!.len())
-- Closing a standard stream leaves it open.
inp.close()
test.eq(true, inp.is_closed())
print('done')
