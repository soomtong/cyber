-- Starts a program that keeps running on its own with `Cmd.detach`, talks to it, then stops it by its process id.
-- Run it on a POSIX system with `python3` and `curl`: `cyber examples/background_job.cy`.
use os

port := '8765'
dir := os.cmd({'mktemp', '-d'}).read()!.trim()
os.write_file('%{dir}/hello.txt', 'hello from a detached server\n')!
log := '%{dir}/server.log'

-- `detach` returns at once with the process id. The server's output goes to a log file, both streams in it.
-- It is not stopped when this script ends, so the script stops it below.
server := os.cmd({'python3', '-m', 'http.server', port, '--bind', '127.0.0.1'}).dir(dir)
pid := server.stdout_file(log).stderr_to_stdout().detach()!
print('server started, pid %{pid}')

-- Waits until the server answers, a tenth of a second at a time.
-- `curl -f` fails until the server is up, and `!else` turns that error into an empty text.
fetch := os.cmd({'curl', '-sf', 'http://127.0.0.1:%{port}/hello.txt'}).timeout_ms(1000)
body := ''
for 0..50:
    body = fetch.read() !else ''
    if body != '':
        break
    os.sleep(100_000_000)!
print('got: %{body.trim()}')

-- The process id is all that is left of it: `kill` stops it.
os.cmd({'kill', '%{pid}'}).run()!
os.sleep(200_000_000)!
print('server log:')
print(os.read_file(log)!.trim())

os.cmd({'rm', '-r', dir}).run()!
