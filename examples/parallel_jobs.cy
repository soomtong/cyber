-- Runs several commands at once with `Cmd.start`, then waits for each and reports its exit code.
-- Run it on a POSIX system: `cyber examples/parallel_jobs.cy`.
use os

-- Three jobs that take different times. One fails.
jobs := []os.Cmd{
    os.cmd({'sh', '-c', 'sleep 0.3; echo "fetch done"'}),
    os.cmd({'sh', '-c', 'sleep 0.1; echo "lint: 2 warnings" >&2; exit 1'}).stderr_to_stdout(),
    os.cmd({'sh', '-c', 'sleep 0.2; echo "test done"'}),
}

-- `start` returns while the job runs, so all three run at the same time.
start := os.now()!
procs := Array[os.Process]{}
for jobs |job|:
    p := job.start()!
    print('started pid %{p.pid()}')
    procs.append(p)

-- Each `read_all` and `wait_code` waits for its own job. The whole takes about as long as the slowest one.
failed := 0
for procs |&p|:
    out := p.read_all()!.trim()
    code := p.wait_code()!
    print('pid %{p.pid()}: exit %{code}, output: %{out}')
    if code != 0:
        failed += 1
print('%{failed} of %{procs.len()} failed in about %{(os.now()! - start) / 100_000_000 * 100} ms')
