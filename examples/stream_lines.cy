-- Reads the output of a running program a line at a time with `Cmd.start`, and stops it early.
-- Run it on a POSIX system: `cyber examples/stream_lines.cy`.
use os

-- A program that writes a line every 0.2 seconds, ten times.
ticker := os.cmd({'sh', '-c', 'for i in 1 2 3 4 5 6 7 8 9 10; do echo "tick $i"; sleep 0.2; done'})

-- Each line comes as soon as the program writes it.
p := ticker.start()!
while p.read_line()! |line|:
    print('got: %{line}')
    if line == 'tick 3':
        -- Enough. `kill` stops the program, and `wait` then reports the signal.
        p.kill()
        break
print('exit code after kill: %{p.wait_code()!}')

-- With a time limit, `read_line` returns `error.TimedOut` once it passes.
slow := ticker.timeout_ms(500).start()!
n := 0
while:
    line := slow.read_line() !else |err|:
        print('stopped after %{n} lines: %{err}')
        break
    if line |text|:
        n += 1
        print('got: %{text}')
    else:
        break

-- Lines from a pipeline with input text. `wait` succeeds when every program does.
upper := os.cmd({'cat'}).stdin('alpha\nbeta\ngamma\n').pipe(os.cmd({'tr', 'a-z', 'A-Z'})).start()!
while upper.read_line()! |line|:
    print(line)
upper.wait()!

-- A `Process` that goes away stops its program: nothing is left running.
fn first_line(cmd os.Cmd) -> !?str:
    p := cmd.start()!
    return p.read_line()!

print(first_line(os.cmd({'yes', 'first'}))!.?)
