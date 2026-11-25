-- Runs other programs with `os.cmd`: no shell, so an argument reaches the program as it is.
-- Run it in a git checkout on a POSIX system: `cyber examples/commands.cy`.
use os

-- The stdout of a program.
branch := os.cmd({'git', 'rev-parse', '--abbrev-ref', 'HEAD'}).read() !else 'no git'
print('branch: %{branch.trim()}')

-- A pipe joins the stdout of one program to the stdin of the next.
-- An argument with spaces or `$` is passed as it is, without quoting.
counted := os.cmd({'printf', '%s\n', 'b', 'a $HOME', 'b'}).pipe(os.cmd({'sort'})).pipe(os.cmd({'uniq', '-c'})).read()!
print(counted)

-- Text for stdin, and the exit code instead of an error.
res := os.cmd({'grep', '-c', 'cyber'}).stdin('cyber\nscript\ncyber\n').run_status()!
print('matches: %{res.out.trim()}, exit code: %{res.code}')
res = os.cmd({'grep', '-c', 'missing'}).stdin('cyber\n').run_status()!
print('matches: %{res.out.trim()}, exit code: %{res.code}')

-- A failed exit is an error from `run` and `read`.
print('`false` failed: %{os.cmd({'false'}).run().unwrap_error()}')

-- A program that does not exist is an error too, not a panic.
print(os.cmd({'no-such-program'}).run().unwrap_error())

-- Files for the streams. The command is a value: it runs again with the same settings.
log := os.cmd({'mktemp'}).read()!.trim()
note := os.cmd({'echo', 'a line for the log'}).stdout_append(log)
note.run()!
note.run()!
print(os.read_file(log)!)
os.remove_file(log)!

-- A time limit stops a program that runs too long.
print(os.cmd({'sleep', '10'}).timeout_ms(200).run().unwrap_error())
