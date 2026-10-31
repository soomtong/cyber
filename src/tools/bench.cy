#!cyber

-- Runs a command multiple times and relies on the process stdout for the clock time
-- which should be in the format `time: {ms}`.
-- This is useful for benching scripts where only the body of the script is measured.
-- Total wall time, and the difference from script time (load time) are also measured.
-- Finally the command is passed into `/usr/bin/time` (`-l` on macOS, `-v` on Linux) to get the peak memory usage.
--
-- Usage: cyber src/tools/bench.cy <cyber> <script.cy>

use os
use meta

max_runs := 50

-- `os.args()` starts at the script path, so the command follows it.
cmd := os.args()[1..]

total_times := []float{}
times := []float{}

for 0..max_runs:
    start := os.now()!

    res := os.exec(cmd)
    idx := res.out.index('time:') ?else
        panic('NoTimeOutput')
    out := res.out[idx + 'time:'.len()..]
    endIdx := out.index('\n').?
    msStr := out[0..endIdx].trim({' ', '\t'})
    ms := float(msStr)
    times += ms

    total_time := float(os.now()! - start) / 1000000
    total_times += total_time

sum := 0.0
for times |time|:
    sum += time
scriptTime := sum / float(times.len())

sum = 0.0
for total_times |time|:
    sum += time
totalTime := sum / float(total_times.len())

-- Get peak memory usage in bytes.
mem := peak_memory(cmd)

print('Total: %{totalTime}ms')
print('Script: %{scriptTime}ms')
print('Load: %{totalTime - scriptTime}ms')
print('Peak Memory: %{mem / 1000000} MB')
fn peak_memory(cmd []str) -> float:
    #if meta.system() == .linux:
        -- GNU time: `\tMaximum resident set size (kbytes): 9312`
        args := []str{'/usr/bin/time', '-v'}
        args = args + cmd
        res := os.exec(args)
        label := 'Maximum resident set size (kbytes):'
        idx := res.err.index(label) ?else
            panic('NoMemoryOutput')
        rest := res.err[idx + label.len()..]
        end := rest.index('\n') ?else rest.len()
        return float(rest[0..end].trim(' ')) * 1024
    #else:
        -- BSD time: `   9535488  maximum resident set size`
        args := []str{'/usr/bin/time', '-l'}
        args = args + cmd
        res := os.exec(args)
        idx := res.err.index('maximum resident set size') ?else
            panic('NoMemoryOutput')
        out := res.err[0..idx].trimRight(' ')
        i := out.len()-1
        while out[i] != ' ':
            i -= 1
        return float(out[i+1..])
