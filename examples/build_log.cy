-- Runs a build-like task and keeps its stdout and stderr together, in the order the program writes them,
-- with `Cmd.stderr_to_stdout` (the `2>&1` of a shell).
-- Run it on a POSIX system: `cyber examples/build_log.cy`.
use os

-- A task that writes progress to stdout and warnings to stderr, then fails.
task := os.cmd({'sh', '-c', 'echo "compile a.c"; echo "warning: unused x" >&2; echo "compile b.c"; echo "error: no main" >&2; exit 2'})

-- Without it, `run_status` gives the two streams apart, and the order between them is lost.
res := task.run_status()!
print('stdout:\n%{res.out}stderr:\n%{res.err}exit code: %{res.code}\n')

-- With it, stderr goes where stdout goes. Here that is what `start` reads, so every line comes in order.
p := task.stderr_to_stdout().start()!
for p.lines() |i, line|:
    print('%{i + 1}: %{line}')
else |err|:
    print('stopped: %{err}')
print('exit code: %{p.wait_code()!}\n')

-- A log file that has both streams, as a CI log does. The exit code still comes from `run_status`.
log := os.cmd({'mktemp'}).read()!.trim()
res = task.stdout_file(log).stderr_to_stdout().run_status()!
print('exit code %{res.code}, log:')
print(os.read_file(log)!)
os.remove_file(log)!

-- In a pipeline, stderr joins the pipe to the next stage: `grep` sees the warnings and the errors too.
counted := task.stderr_to_stdout().pipe(os.cmd({'grep', '-c', ':'})).run_status()!
print('lines with a colon: %{counted.out.trim()}')
