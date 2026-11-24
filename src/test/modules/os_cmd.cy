use os
use meta
use t 'test'

-- The programs of this test are those of a POSIX system.
fn run_all() -> !void:
    -- read(): the stdout of the program.
    t.eq('hello world\n', os.cmd({'/bin/echo', 'hello world'}).read()!)
    t.eq('ab\n', os.cmd([]str{'/bin/echo', 'a' + 'b'}).read()!)

    -- No shell: an argument is passed as it is.
    t.eq('a b|$HOME|"q"|; rm -rf x|*|', os.cmd({'printf', '%s|', 'a b', '$HOME', '"q"', '; rm -rf x', '*'}).read()!)

    -- pipe()
    t.eq('a\nb\nc\n', os.cmd({'printf', 'b\na\nc\n'}).pipe(os.cmd({'sort'})).read()!)
    counted := os.cmd({'printf', 'b\na\nb\n'}).pipe(os.cmd({'sort'})).pipe(os.cmd({'uniq', '-d'})).read()!
    t.eq('b\n', counted)

    -- dir()
    t.eq('/\n', os.cmd({'pwd'}).dir('/').read()!)

    -- env(): on top of the environment of this process, which includes what `set_env` set.
    t.eq('1-two words\n', os.cmd({'sh', '-c', 'echo $CY_A-$CY_B'}).env('CY_A', '1').env('CY_B', 'two words').read()!)
    t.eq('has-path\n', os.cmd({'sh', '-c', 'test -n "$PATH" && echo has-path'}).env('CY_A', '1').read()!)
    os.set_env('CY_CMD_SET', 'yes')!
    t.eq('yes\n', os.cmd({'sh', '-c', 'echo $CY_CMD_SET'}).read()!)
    t.eq('yes\n', os.cmd({'sh', '-c', 'echo $CY_CMD_SET'}).env('CY_A', '1').read()!)
    t.eq('yes\n', os.exec({'sh', '-c', 'echo $CY_CMD_SET'}).out)
    os.unset_env('CY_CMD_SET')!

    -- stdin()
    t.eq('SHOUT\n', os.cmd({'tr', 'a-z', 'A-Z'}).stdin('shout\n').read()!)
    t.eq('8', os.cmd({'cat'}).stdin('piped in').pipe(os.cmd({'wc', '-c'})).read()!.trim())
    -- More than a pipe holds, to a program that reads it all, reads a part, and reads nothing.
    big := 'x'.repeat(1000000)
    t.eq(1000000, os.cmd({'cat'}).stdin(big).read()!.len())
    t.eq('xxxxx', os.cmd({'head', '-c', '5'}).stdin(big).read()!)
    os.cmd({'true'}).stdin(big).run()!
    -- Without stdin(), read() gives an empty input.
    t.eq('', os.cmd({'cat'}).read()!)

    -- run(): success and failure.
    os.cmd({'true'}).run()!
    t.eq(error.ExitStatus, os.cmd({'false'}).run().unwrap_error())
    t.eq(error.ExitStatus, os.cmd({'false'}).read().unwrap_error())
    t.eq(error.ExitStatus, os.cmd({'sh', '-c', 'kill -9 $$'}).run().unwrap_error())

    -- A program that can not be started.
    t.eq(error.NotFound, os.cmd({'no-such-program-xyz'}).run().unwrap_error())
    t.eq(error.NotFound, os.cmd({'no-such-program-xyz'}).read().unwrap_error())
    t.eq(error.NotFound, os.cmd({'no-such-program-xyz'}).run_status().unwrap_error())
    t.eq(error.NotFound, os.cmd({'true'}).dir('/no/such/dir').run().unwrap_error())
    t.eq(error.InvalidArgument, os.cmd([]str{}).run().unwrap_error())
    t.eq(error.InvalidArgument, os.cmd({''}).run().unwrap_error())
    t.eq(error.InvalidArgument, os.cmd({'echo', 'a\x00b'}).run().unwrap_error())
    t.eq(error.InvalidArgument, os.cmd({'true'}).env('A=B', '1').run().unwrap_error())
    -- The stages that started are stopped.
    t.eq(error.NotFound, os.cmd({'yes'}).pipe(os.cmd({'no-such-program-xyz'})).pipe(os.cmd({'cat'})).read().unwrap_error())

    -- A pipeline fails when any stage fails.
    t.eq(error.ExitStatus, os.cmd({'false'}).pipe(os.cmd({'cat'})).run().unwrap_error())
    t.eq(error.ExitStatus, os.cmd({'true'}).pipe(os.cmd({'false'})).run().unwrap_error())
    -- A stage that is stopped because the next one closed its input succeeded.
    t.eq('y\n', os.cmd({'yes'}).pipe(os.cmd({'head', '-1'})).read()!)

    -- run_status(): an exit code is not an error.
    res := os.cmd({'sh', '-c', 'echo out; echo err >&2; exit 3'}).run_status()!
    t.eq('out\n', res.out)
    t.eq('err\n', res.err)
    t.eq(3, res.code)
    t.eq(0, os.cmd({'true'}).run_status()!.code)
    t.eq(137, os.cmd({'sh', '-c', 'kill -9 $$'}).run_status()!.code)
    -- The code of the last stage that failed, and the stderr of every stage in order.
    res = os.cmd({'sh', '-c', 'exit 2'}).pipe(os.cmd({'sh', '-c', 'cat; exit 5'})).run_status()!
    t.eq(5, res.code)
    res = os.cmd({'sh', '-c', 'echo e1 >&2; exit 2'}).pipe(os.cmd({'sh', '-c', 'cat; echo e2 >&2'})).run_status()!
    t.eq(2, res.code)
    t.eq('e1\ne2\n', res.err)
    -- stdout and stderr are read together.
    res = os.cmd({'sh', '-c', 'head -c 300000 /dev/zero | tr "\\0" o; head -c 300000 /dev/zero | tr "\\0" e >&2'}).run_status()!
    t.eq(300000, res.out.len())
    t.eq(300000, res.err.len())

    -- Over 10 MiB of output is an error, and the program is stopped.
    t.eq(error.TooBig, os.cmd({'yes'}).read().unwrap_error())

    -- At most 16 stages.
    var many os.Cmd = os.cmd({'cat'}).stdin('through\n')
    for 0..15:
        many = many.pipe(os.cmd({'cat'}))
    t.eq('through\n', many.read()!)
    many = many.pipe(os.cmd({'cat'}))
    t.eq(error.InvalidArgument, many.read().unwrap_error())

    -- A command is a value: a method returns a new one and the command can run again.
    base := os.cmd({'pwd'})
    moved := base.dir('/')
    t.eq('/\n', moved.read()!)
    t.eq('/\n', moved.read()!)
    t.eq(os.cwd()! + '\n', base.read()!)

    -- Output that is not UTF-8 is kept as bytes.
    t.eq(2, os.cmd({'printf', '\\377\\376'}).read()!.len())

fn in_thread(word str) -> str:
    return os.cmd({'/bin/echo', word}).pipe(os.cmd({'tr', 'a-z', 'A-Z'})).read() !else 'failed'

if meta.system() != .windows:
    run_all()!
    -- From a spawned thread.
    a := spawn in_thread('one')
    b := spawn in_thread('two')
    t.eq('ONE\n', a.await())
    t.eq('TWO\n', b.await())

--cytest: pass
