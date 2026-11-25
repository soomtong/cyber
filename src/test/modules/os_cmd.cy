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
    -- Also while the input is still being written: the program is stopped before the writer is waited for.
    t.eq(error.TooBig, os.cmd({'cat'}).stdin('x'.repeat(12000000)).read().unwrap_error())
    -- The input of the command after a pipe is not used.
    t.eq('first', os.cmd({'cat'}).stdin('first').pipe(os.cmd({'cat'}).stdin('second')).read()!)

    -- At most 16 stages.
    var many os.Cmd = os.cmd({'cat'}).stdin('through\n')
    for 0..15:
        many = many.pipe(os.cmd({'cat'}))
    t.eq('through\n', many.read()!)
    many = many.pipe(os.cmd({'cat'}))
    t.eq(error.InvalidArgument, many.read().unwrap_error())

    -- A command is a value: a method returns a new one and the command can run again.
    -- `-P` for the path without symbolic links, which is what `os.cwd` returns.
    base := os.cmd({'pwd', '-P'})
    moved := base.dir('/')
    t.eq('/\n', moved.read()!)
    t.eq('/\n', moved.read()!)
    t.eq(os.cwd()! + '\n', base.read()!)

    -- Output that is not UTF-8 is kept as bytes.
    t.eq(2, os.cmd({'printf', '\\377\\376'}).read()!.len())

    -- timeout_ms(): the stages are stopped when the limit passes.
    t.eq(error.TimedOut, os.cmd({'sleep', '5'}).timeout_ms(100).run().unwrap_error())
    t.eq(error.TimedOut, os.cmd({'sleep', '5'}).timeout_ms(100).read().unwrap_error())
    t.eq(error.TimedOut, os.cmd({'sleep', '5'}).pipe(os.cmd({'cat'})).timeout_ms(100).run_status().unwrap_error())
    t.eq(error.TimedOut, os.cmd({'cat'}).stdin('x'.repeat(1000000)).pipe(os.cmd({'sleep', '5'})).timeout_ms(100).read().unwrap_error())
    -- Also when a program that a stage started keeps the pipe open.
    t.eq(error.TimedOut, os.cmd({'sh', '-c', 'sleep 3 & echo started'}).timeout_ms(200).read().unwrap_error())
    -- The shorter limit of a pipe.
    t.eq(error.TimedOut, os.cmd({'sleep', '5'}).timeout_ms(60000).pipe(os.cmd({'cat'}).timeout_ms(100)).run().unwrap_error())
    t.eq('done\n', os.cmd({'echo', 'done'}).timeout_ms(10000).read()!)
    t.eq(error.InvalidArgument, os.cmd({'true'}).timeout_ms(0).run().unwrap_error())
    t.eq(error.InvalidArgument, os.cmd({'true'}).timeout_ms(-5).run().unwrap_error())

    -- Files for the streams. A relative path is relative to this process, not to `dir`.
    tmp := os.cmd({'mktemp', '-d'}).read()!.trim()
    out := tmp + '/out.txt'
    os.cmd({'echo', 'one'}).stdout_file(out).run()!
    os.cmd({'echo', 'two'}).stdout_append(out).run()!
    t.eq('one\ntwo\n', os.read_file(out)!)
    os.cmd({'echo', 'three'}).dir('/').stdout_file(out).run()!
    t.eq('three\n', os.read_file(out)!)
    t.eq('THREE\n', os.cmd({'tr', 'a-z', 'A-Z'}).stdin_file(out).read()!)
    -- The later of `stdin` and `stdin_file` is used.
    t.eq('text', os.cmd({'cat'}).stdin_file(out).stdin('text').read()!)
    t.eq('three\n', os.cmd({'cat'}).stdin('text').stdin_file(out).read()!)
    -- The stdout of a pipe is that of its last command.
    os.cmd({'echo', 'piped'}).stdout_file(tmp + '/lost.txt').pipe(os.cmd({'cat'}).stdout_file(out)).run()!
    t.eq('piped\n', os.read_file(out)!)
    t.eq(error.NotFound, os.read_file(tmp + '/lost.txt').unwrap_error())
    -- A stream that goes to a file is not in the result.
    res = os.cmd({'sh', '-c', 'echo o; echo e >&2'}).stdout_file(out).run_status()!
    t.eq('', res.out)
    t.eq('e\n', res.err)
    t.eq(error.InvalidArgument, os.cmd({'echo'}).stdout_file(out).read().unwrap_error())
    -- stderr goes to a file for the stages so far, and stages that name the same file write to it together.
    err := tmp + '/err.txt'
    res = os.cmd({'sh', '-c', 'echo e1 >&2; echo x'}).pipe(os.cmd({'sh', '-c', 'cat; echo e2 >&2'})).stderr_file(err).run_status()!
    t.eq('x\n', res.out)
    t.eq('', res.err)
    t.eq('e1\ne2\n', os.cmd({'sort'}).stdin_file(err).read()!)
    res = os.cmd({'sh', '-c', 'echo e3 >&2'}).stderr_append(err).pipe(os.cmd({'sh', '-c', 'echo e4 >&2'})).run_status()!
    t.eq('e4\n', res.err)
    t.eq('e1\ne2\ne3\n', os.cmd({'sort'}).stdin_file(err).read()!)
    -- A file that can not be opened starts nothing.
    t.eq(error.NotFound, os.cmd({'cat'}).stdin_file(tmp + '/none.txt').read().unwrap_error())
    t.eq(error.NotFound, os.cmd({'echo'}).stdout_file(tmp + '/no/dir.txt').run().unwrap_error())
    t.eq(error.IsADirectory, os.cmd({'echo'}).stdout_file(tmp).run().unwrap_error())
    t.eq(error.InvalidArgument, os.cmd({'echo'}).stdout_file('').run().unwrap_error())
    t.eq(error.InvalidArgument, os.cmd({'echo'}).stderr_file('a\x00b').run().unwrap_error())
    os.cmd({'rm', '-r', tmp}).run()!

    -- start(): the stdout of the last stage a line at a time, while the command runs.
    p := os.cmd({'printf', 'a\\nb\\r\\n\\nc'}).start()!
    t.eq('a', p.read_line()!.?)
    t.eq('b', p.read_line()!.?)
    t.eq('', p.read_line()!.?)
    t.eq('c', p.read_line()!.?)
    t.eq(true, p.read_line()! == none)
    t.eq(true, p.read_line()! == none)
    p.wait()!
    p.wait()!
    t.eq(0, p.wait_code()!)
    -- The lines of a pipeline with input, then the rest.
    lines := os.cmd({'cat'}).stdin('one\ntwo\nthree\n').pipe(os.cmd({'tr', 'a-z', 'A-Z'})).start()!
    t.eq('ONE', lines.read_line()!.?)
    t.eq('TWO\nTHREE\n', lines.read_all()!)
    t.eq('', lines.read_all()!)
    lines.wait()!
    -- A program that does not end: stopped after the first line.
    endless := os.cmd({'yes'}).start()!
    t.eq('y', endless.read_line()!.?)
    endless.kill()
    endless.kill()
    t.eq(error.ExitStatus, endless.wait().unwrap_error())
    t.eq(137, endless.wait_code()!)
    -- The output that was not read is dropped while the command is waited for: more than a pipe holds.
    t.eq(3, os.cmd({'sh', '-c', 'head -c 300000 /dev/zero; exit 3'}).start()!.wait_code()!)
    -- The time limit counts from start().
    slow := os.cmd({'sh', '-c', 'echo first; sleep 5'}).timeout_ms(300).start()!
    t.eq('first', slow.read_line()!.?)
    t.eq(error.TimedOut, slow.read_line().unwrap_error())
    t.eq(error.TimedOut, slow.wait().unwrap_error())
    -- lines(): for `for`, with the error in the `else` block.
    var got []str = {}
    listed := os.cmd({'printf', 'x\\ny\\n'}).start()!
    for listed.lines() |line|:
        got += line
    else |err|:
        got += 'error'
    t.eq(2, got.len())
    t.eq('y', got[1])
    var stopped ?error = none
    limited := os.cmd({'sh', '-c', 'echo first; sleep 5'}).timeout_ms(300).start()!
    for limited.lines() |line|:
        got += line
    else |err|:
        stopped = err
    t.eq(error.TimedOut, stopped.?)
    t.eq(error.NotFound, os.cmd({'no-such-program-xyz'}).start().unwrap_error())
    t.eq(error.InvalidArgument, os.cmd({'echo'}).stdout_file('out.txt').start().unwrap_error())
    -- A value that goes away stops its programs.
    started_pid := start_and_drop()!
    t.eq('gone\n', os.cmd({'sh', '-c', 'kill -0 ' + started_pid + ' 2>/dev/null || echo gone'}).read()!)

-- Returns the pid of a program that runs for 30 seconds, whose `Process` goes away here.
fn start_and_drop() -> !str:
    p := os.cmd({'sh', '-c', 'echo $$; exec sleep 30'}).start()!
    return p.read_line()!.?

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
