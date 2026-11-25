use io
use meta
use c

#[cond=meta.system() == .macos]
use macos 'os.macos.cy'

#[cond=meta.system() == .linux]
use linux 'os.linux.cy'

#[cond=meta.system() != .windows]
use lc 'libc'

#[cond=meta.system() == .windows]
use windows 'os.windows.cy'

#[cond=meta.system() == .windows]
use kernel32 'windows/kernel32.cy'

--| Contains system level functions.
--|
--| ## Architecture:
--| This module provides a cross-platform API for OS operations.
--| Platform-specific implementations are in separate modules:
--| - os.macos.cy: macOS-specific implementations
--| - os.windows.cy: Windows-specific implementations
--| - os.linux.cy: Linux-specific implementations
--|
--| Sample usage:
--| ```cy
--| use os
--| 
--| env := os.get_env_all()
--| for env |e|:
--|     print('%{e.key} -> %{e.value}')
--| ```

type c_int = c.c_int

--| Platform-specific file descriptor type
type FileHandle = switch meta.system():
    case .windows => Ptr[void]
    else => lc.fd_t

--| Default SIMD vector bit size.
#[bind] global vecBitSize int

--| Returns the standard error handle.
#[bind]
fn stderr() -> File

--| Returns the standard input handle.
#[bind]
fn stdin() -> File

--| Returns the standard output handle.
#[bind]
fn stdout() -> File

const AccessExists  = c_int(0)  -- F_OK
const AccessRead    = c_int(4)  -- R_OK
const AccessWrite   = c_int(2)  -- W_OK
const AccessExecute = c_int(1)  -- X_OK
type AccessMode = c_int

const ns_per_us = 1000
const ns_per_ms = 1000 * ns_per_us
const ns_per_s = 1000 * ns_per_ms

--| Attempts to access a file at the given `path` with `mode`.
fn access_file(path str, mode AccessMode) -> !void:
    #if meta.system() == .windows:
        return windows.access_file(path)
    #else:
        cpath := str.initz(path)
        code := lc.access(cpath.ptr, mode)
        if code != 0:
            return last_error()

--| Returns the command line arguments.
fn args() -> []str:
    return _args(type.id(RawBuffer[byte]))

#[bind] fn _args(buffer_t int) -> []str

--| Returns the path of a locally cached file of `url`.
--| If no such file exists locally, it's fetched from `url`.
#[bind] fn cache_url(url str) -> str

--| Copies a file to a destination path.
fn copy_file(src_path str, dst_path str) -> !void:
    #if meta.system() == .macos:
        src := open_file(src_path)!
        dst := create_file(dst_path)!
        if lc.macos.fcopyfile(src.fd, dst.fd, none, lc.macos.COPYFILE_DATA) != 0:
            return last_error()

    #else meta.system() == .windows:
        src16 := windows.utf8ToUtf16Le(src_path)!
        dst16 := windows.utf8ToUtf16Le(dst_path)!
        if kernel32.CopyFileW(src16.ptr, dst16.ptr, windows.FALSE) == windows.FALSE:
            return windows.fromWin32Error()

    #else:
        panic('copy_file not supported on this platform')

--| Creates the directory at `path`.
fn create_dir(path str) -> !void:
    #if meta.system() == .windows:
        path16 := windows.utf8ToUtf16Le(path)!
        if kernel32.CreateDirectoryW(path16.ptr, none) == windows.FALSE:
            return windows.fromWin32Error()
    #else:
        cpath := str.initz(path)
        if lc.mkdir(cpath.ptr, lc.DefaultDirMode) != 0:
            return last_error()

fn create_file(path str) -> !File:
    return create_file(path, true)

--| Creates and opens the file at `path`. If `truncate` is true, an existing file will be truncated.
fn create_file(path str, truncate bool) -> !File:
    #if meta.system() == .windows:
        return windows.create_file(path, truncate)
    #else:
        flags := lc.O_WRONLY || lc.O_CREAT || lc.O_CLOEXEC
        if truncate:
            flags ||= lc.O_TRUNC
        cpath := str.initz(path)
        fd := lc.open(cpath.ptr, flags, lc.DefaultFileMode)
        if fd == -1:
            return last_error()
        return {fd=fd}

--| Returns the current working directory.
fn cwd() -> !str:
    #if meta.system() == .windows:
        return windows.cwd()
    #else:
        buf := [lc.PATH_MAX]byte(0)
        if lc.getcwd(*buf[0], as buf.len()) == none:
            return last_error()
        return c.from_strz(*buf[0])

--| Change the current working directory.
fn chdir(path str) -> !void:
    #if meta.system() == .windows:
        return windows.set_cwd(path)
    #else:
        cpath := str.initz(path)
        if lc.chdir(cpath.ptr) == -1:
            return last_error()

--| Runs the program `args[0]` with the rest of `args` as its arguments and returns its stdout, stderr and exit code.
--| There is no shell: an argument is passed as it is. A program that can not be started is a panic.
--| `cmd` does the same with errors as values, and with pipes, a working directory, environment variables and input.
fn exec(args AsSpan[str]) -> ExecResult:
    return _exec(args.span())

-- Takes a borrowed span so the caller keeps owning the strings.
#[bind] fn _exec(args [&]str) -> ExecResult

--| The outcome of a program or a pipeline: what it wrote to stdout and stderr, and its exit code.
--| From `Cmd.run_status`, `code` is 0 when every stage succeeded.
type ExecResult:
    out  str
    err  str
    code int

--| A command: a program with its arguments, or several that are joined by pipes, and where and how they run.
--| A `Cmd` is a value. Nothing starts until `run`, `read` or `run_status` is called, and it can be run again.
--| There is no shell. An argument reaches the program as it is, with its spaces, quotes and `$`, so text from
--| outside can not turn into more arguments or another command. A pipe, a working directory, an
--| environment variable, a file for a stream and a time limit are set with methods instead of shell syntax.
--| Sample usage:
--| ```cy
--| use os
--|
--| branch := os.cmd({'git', 'rev-parse', '--abbrev-ref', 'HEAD'}).read()!.trim()
--| top := os.cmd({'du', '-sk', dir}).pipe(os.cmd({'sort', '-rn'})).read()!
--| os.cmd({'make', 'test'}).dir('build').env('CI', '1').stdout_file('build.log').run()!
--| res := os.cmd({'grep', '-c', 'TODO'}).stdin(text).timeout_ms(5000).run_status()!
--| if res.code != 0:
--|     eprint(res.err)
--| ```
type Cmd:
    -stages []CmdStage
    -- The stdin of the first stage: a `CmdIo` and the text or the path.
    -in_io  int = 0
    -in     str = ''
    -- The stdout of the last stage: a `CmdIo` and the path.
    -out_io int = 0
    -out    str = ''
    -- 0 for no time limit, -1 for a limit that is not over 0.
    -limit_ms int = 0

-type CmdStage:
    args []str
    -- Empty for the working directory of this process.
    dir  str
    -- Names and values in turn.
    env  []str
    -- The stderr of the stage: a `CmdIo` and the path.
    err_io int = 0
    err    str = ''

-- Mirrored by `CmdIo` in `os.zig`. 0: what the method that runs the command says, 1: the input text,
-- 2: a file that is read, or created or emptied, 3: a file that is created or added to.
-const CmdIoText = 1
-const CmdIoFile = 2
-const CmdIoAppend = 3

--| Returns a command that runs the program `args[0]` with the rest of `args` as its arguments.
--| A program name without a `/` is looked up in `PATH`.
fn cmd(args AsSpan[str]) -> Cmd:
    var list []str = {}
    list += args.span()
    return {stages={CmdStage{args=list, dir='', env={}}}}

-fn (&Cmd) with_stages(stages []CmdStage) -> Cmd:
    return {stages=stages, in_io=self.in_io, in=self.in, out_io=self.out_io, out=self.out, limit_ms=self.limit_ms}

--| Returns this command with its stdout joined to the stdin of `next`. The result runs both at once.
--| It succeeds when both do. A stage that is stopped because the next one closed its input (as `head` does)
--| counts as a success. The stdin of the result is that of this command and its stdout is that of `next`:
--| text or a file that `stdin` or `stdin_file` gave to `next` is not used, since the stdin of `next` is the pipe,
--| and neither is a file that `stdout_file` gave to this command. The time limit is the shorter one of the two.
fn (&Cmd) pipe(next Cmd) -> Cmd:
    limit := self.limit_ms
    if next.limit_ms != 0 and (limit == 0 or next.limit_ms < limit):
        limit = next.limit_ms
    return {stages=self.stages + next.stages, in_io=self.in_io, in=self.in, out_io=next.out_io, out=next.out,
        limit_ms=limit}

--| Returns this command with `path` as the working directory of every stage it has so far.
fn (&Cmd) dir(path str) -> Cmd:
    var stages []CmdStage = {}
    for self.stages |stage|:
        stages += CmdStage{args=stage.args, dir=path, env=stage.env, err_io=stage.err_io, err=stage.err}
    return self.with_stages(stages)

--| Returns this command with the environment variable `name` set to `value` for every stage it has so far.
--| The other variables are those of this process when the command runs.
fn (&Cmd) env(name str, value str) -> Cmd:
    var stages []CmdStage = {}
    for self.stages |stage|:
        stages += CmdStage{args=stage.args, dir=stage.dir, env=stage.env + name + value, err_io=stage.err_io,
            err=stage.err}
    return self.with_stages(stages)

--| Returns this command with `text` as the stdin of its first stage, in place of a file that `stdin_file` gave.
fn (&Cmd) stdin(text str) -> Cmd:
    return {stages=self.stages, in_io=CmdIoText, in=text, out_io=self.out_io, out=self.out, limit_ms=self.limit_ms}

--| Returns this command with the file at `path` as the stdin of its first stage, in place of text that `stdin`
--| gave. The file is opened when the command runs. A relative path is relative to the working directory of this
--| process, not to that of `dir`.
fn (&Cmd) stdin_file(path str) -> Cmd:
    return {stages=self.stages, in_io=CmdIoFile, in=path, out_io=self.out_io, out=self.out, limit_ms=self.limit_ms}

--| Returns this command with the stdout of its last stage written to the file at `path`. The file is created, or
--| emptied when it exists, when the command runs. A relative path is relative to the working directory of this
--| process. `read` can not be used with it, and `run_status` returns an empty `out`.
fn (&Cmd) stdout_file(path str) -> Cmd:
    return {stages=self.stages, in_io=self.in_io, in=self.in, out_io=CmdIoFile, out=path, limit_ms=self.limit_ms}

--| Like `stdout_file`, but the output is added to the end of the file.
fn (&Cmd) stdout_append(path str) -> Cmd:
    return {stages=self.stages, in_io=self.in_io, in=self.in, out_io=CmdIoAppend, out=path, limit_ms=self.limit_ms}

--| Returns this command with the stderr of every stage it has so far written to the file at `path`. The file is
--| created, or emptied when it exists, when the command runs. Stages that name the same file write to it
--| together. `run_status` does not return what goes to the file in `err`.
fn (&Cmd) stderr_file(path str) -> Cmd:
    return self.stderr_to(CmdIoFile, path)

--| Like `stderr_file`, but the output is added to the end of the file.
fn (&Cmd) stderr_append(path str) -> Cmd:
    return self.stderr_to(CmdIoAppend, path)

-fn (&Cmd) stderr_to(io int, path str) -> Cmd:
    var stages []CmdStage = {}
    for self.stages |stage|:
        stages += CmdStage{args=stage.args, dir=stage.dir, env=stage.env, err_io=io, err=path}
    return self.with_stages(stages)

--| Returns this command with a time limit of `ms` milliseconds. When the limit passes before the command ends,
--| its stages are stopped (`SIGKILL`, `TerminateProcess`) and the method that ran it returns `error.TimedOut`.
--| The programs that a stage started itself are not stopped. A limit that is not over 0 is
--| `error.InvalidArgument` when the command runs.
fn (&Cmd) timeout_ms(ms int) -> Cmd:
    limit := ms
    if ms <= 0:
        limit = -1
    return {stages=self.stages, in_io=self.in_io, in=self.in, out_io=self.out_io, out=self.out, limit_ms=limit}

--| Runs the command and waits for it. Its stdout and stderr are those of this process, and so is its stdin
--| unless `stdin` or `stdin_file` gave it one, or a method gave it a file.
--| Returns `error.ExitStatus` when a stage ends with an exit code other than 0 or is stopped by a signal,
--| `error.TimedOut` when the time limit passed, and `error.NotFound`, `error.PermissionDenied` and the like when a
--| program can not be started or a file can not be opened.
--| When the host asks the VM to stop (`cl_vm_interrupt`), the stages are stopped and so is the VM.
fn (&Cmd) run() -> !void:
    raw := self.launch(0)
    if raw.fail != 0:
        return cmd_error(raw.fail)
    if raw.code != 0:
        return error.ExitStatus

--| Runs the command, waits for it and returns what its last stage wrote to stdout. stderr is that of this process.
--| Without `stdin` or `stdin_file`, the first stage reads an empty input.
--| Returns the errors of `run`, `error.TooBig` when the output is over 10 MiB, and `error.InvalidArgument` when
--| `stdout_file` or `stdout_append` sent the output to a file.
fn (&Cmd) read() -> !str:
    if self.out_io != 0:
        return error.InvalidArgument
    raw := self.launch(1)
    if raw.fail != 0:
        return cmd_error(raw.fail)
    if raw.code != 0:
        return error.ExitStatus
    return raw.out

--| Runs the command, waits for it and returns the stdout of its last stage, the stderr of all stages and the
--| exit code. An exit code other than 0 is not an error here: `code` is that of the last stage that failed, and
--| 128 plus the signal number for a stage that a signal stopped.
--| Without `stdin` or `stdin_file`, the first stage reads an empty input. A stream that goes to a file is not
--| in the result.
--| Returns an error only when a program can not be started or a file can not be opened (`error.NotFound` and
--| the like), when the time limit passed (`error.TimedOut`), or when stdout or stderr is over 10 MiB
--| (`error.TooBig`).
fn (&Cmd) run_status() -> !ExecResult:
    raw := self.launch(2)
    if raw.fail != 0:
        return cmd_error(raw.fail)
    return {out=raw.out, err=raw.err, code=raw.code}

-- Hands the stages to the host as flat spans. `counts` has three numbers per stage: arguments, environment pairs
-- and the `CmdIo` of stderr.
-fn (&Cmd) launch(mode int) -> CmdRaw:
    var args []str = {}
    var counts []int = {}
    var dirs []str = {}
    var envs []str = {}
    var errs []str = {}
    for self.stages |stage|:
        args += stage.args
        counts += stage.args.len()
        counts += stage.env.len() / 2
        counts += stage.err_io
        dirs += stage.dir
        envs += stage.env
        errs += stage.err
    texts := []str{self.in, self.out}
    opts := []int{self.in_io, self.out_io, self.limit_ms}
    -- When the host asks the VM to stop, the host function stops the stages and returns `CmdFail.interrupted`
    -- (11). The checkpoint of this loop then stops the VM: the result is never taken for that of the command.
    while:
        raw := _cmd_run(args.span(), counts.span(), dirs.span(), envs.span(), errs.span(), texts.span(), opts.span(),
            mode)
        if raw.fail != 11:
            return raw

--| Starts the command and returns it while it runs, to read the stdout of its last stage a line at a time.
--| stderr is that of this process, and the first stage reads an empty input without `stdin` or `stdin_file`.
--| The time limit of `timeout_ms` counts from here.
--| Returns the errors of a program that can not be started or a file that can not be opened, as `run` does,
--| and `error.InvalidArgument` when `stdout_file` or `stdout_append` sent the output to a file.
--| Sample usage:
--| ```cy
--| p := os.cmd({'ping', '-c', '3', 'localhost'}).start()!
--| while p.read_line()! |line|:
--|     print('> ' + line)
--| p.wait()!
--| ```
fn (&Cmd) start() -> !Process:
    if self.out_io != 0:
        return error.InvalidArgument
    raw := self.launch(3)
    if raw.fail != 0:
        return cmd_error(raw.fail)
    return {id=raw.code}

--| A command that runs: what `Cmd.start` returns. Its stdout is read with `read_line` or `read_all`, and `wait` or
--| `wait_code` waits for its end.
--| When the value goes away before the command ended, its programs are stopped. Also when the eval ends with a
--| panic, and when the host asks the VM to stop (`cl_vm_interrupt`).
type Process:
    with NoCopy
    -id int

fn (&Process) @deinit():
    _proc_free(self.id)

--| Returns the next line that the last stage wrote to stdout, without its line break (`\n` or `\r\n`), or `none`
--| when the output ended. Waits until a whole line or the end comes.
--| Returns `error.TimedOut` when the time limit passed, and `error.TooBig` for a line over 10 MiB.
fn (&Process) read_line() -> !?str:
    raw := self.op(0)
    if raw.fail != 0:
        return cmd_error(raw.fail)
    if raw.code == 0:
        return none
    return raw.out

--| Returns the lines that the last stage writes to stdout, for `for`. An error of `read_line` ends the loop in
--| the `else |err|:` block:
--| ```cy
--| for p.lines() |line|:
--|     print(line)
--| else |err|:
--|     eprint('stopped: %{err}')
--| ```
fn (&Process) lines() -> ProcessLines:
    return {id=self.id}

--| The lines of a `Process`, for `for`. It reads from the `Process` it came from while that is alive.
type ProcessLines:
    -id int

fn (&ProcessLines) iterator() -> int:
    return 0

fn (&ProcessLines) next(count &int) -> !?str:
    raw := proc_op(self.id, 0)
    if raw.fail != 0:
        return cmd_error(raw.fail)
    if raw.code == 0:
        return none
    count.* += 1
    return raw.out

--| Returns the rest of what the last stage writes to stdout, until its end.
--| Returns `error.TimedOut` when the time limit passed, and `error.TooBig` when the rest is over 10 MiB.
fn (&Process) read_all() -> !str:
    raw := self.op(1)
    if raw.fail != 0:
        return cmd_error(raw.fail)
    return raw.out

--| Waits for the command to end. stdout that was not read is read and dropped, so that a program does not wait
--| for room in a full pipe.
--| Returns `error.ExitStatus` when a stage ends with an exit code other than 0 or is stopped by a signal (also
--| by `kill`), and `error.TimedOut` when the time limit passed. Waiting again returns the same.
fn (&Process) wait() -> !void:
    code := self.wait_code()!
    if code != 0:
        return error.ExitStatus

--| Like `wait`, but returns the exit code instead of `error.ExitStatus`: 0 when every stage succeeded, otherwise
--| that of the last stage that failed, and 128 plus the signal number for a stage that a signal stopped.
fn (&Process) wait_code() -> !int:
    raw := self.op(2)
    if raw.fail != 0:
        return cmd_error(raw.fail)
    return raw.code

--| Stops the programs that still run (`SIGKILL`, `TerminateProcess`). Does nothing after they ended.
--| `read_line` then returns what they wrote before, and `wait` returns `error.ExitStatus`.
fn (&Process) kill():
    _ = self.op(3)

-fn (&Process) op(op int) -> CmdRaw:
    return proc_op(self.id, op)

-- As `launch` does, the loop lets the VM stop when the host function returns `CmdFail.interrupted`.
-fn proc_op(id int, op int) -> CmdRaw:
    while:
        raw := _proc_op(id, op)
        if raw.fail != 11:
            return raw

#[bind] -fn _proc_op(id int, op int) -> CmdRaw

#[bind] -fn _proc_free(id int)

-type CmdRaw:
    out  str
    err  str
    code int
    fail int

-- `fail` is the `CmdFail` of `os.zig`.
-fn cmd_error(fail int) -> error:
    switch fail:
        case 1: return error.NotFound
        case 2: return error.PermissionDenied
        case 3: return error.InvalidArgument
        case 4: return error.TooBig
        case 5: return error.NotADirectory
        case 6: return error.IsADirectory
        case 7: return error.TooManyOpenFiles
        case 8: return error.OutOfMemory
        case 10: return error.TimedOut
        else: return error.Unknown

#[bind] -fn _cmd_run(args [&]str, counts [&]int, dirs [&]str, envs [&]str, errs [&]str, texts [&]str, opts [&]int,
    mode int) -> CmdRaw

--| Exits the program with a status code.
fn exit(status int) -> never:
    #if meta.system() == .windows:
        kernel32.ExitProcess(r32(status))
    #else:
        lc.exit(c_int(status))

--| Fetches the contents at `url` using the HTTP GET request method.
#[bind] fn fetch_url(url str) -> str

--| Checks whether the file at the given `path` exists.
fn file_exists(path str) -> bool:
    access_file(path, AccessExists) !else:
        return false
    return true

fn file_info(path str) -> !FileInfo:
    cpath := str.initz(path)
    #if meta.system() == .linux:
        return linux.file_info(cpath.ptr)

    #else meta.system() == .macos:
        cstat := lc.Stat{}
        if lc.stat(cpath.ptr, &cstat) != 0:
            return last_error()
        return file_info(&cstat)

    #else meta.system() == .windows:
        path16 := windows.utf8ToUtf16Le(path)!
        data := kernel32.WIN32_FILE_ATTRIBUTE_DATA{
            dwFileAttributes=undef, ftCreationTime=undef,
            ftLastAccessTime=undef, ftLastWriteTime=undef,
            nFileSizeHigh=undef, nFileSizeLow=undef,
        }
        if kernel32.GetFileAttributesExW(path16.ptr, kernel32.DWORD(kernel32.GetFileExInfoStandard), &data) == windows.FALSE:
            return windows.fromWin32Error()
        return windows.fileInfoFromWin32Attr(&data)

    #else:
        panic('file_info not supported on this platform')

#[cond=meta.system() != .windows]
fn file_info(stat Ptr[lc.Stat]) -> FileInfo:
    var res FileInfo = undef
    #if meta.system() == .macos:
        res = macos.fromStat(stat)
    #else:
        panic('file_info not supported on this platform')
    return res

--| Frees the memory located at `ptr`.
fn free(ptr Ptr[void]):
    #if meta.system() == .windows:
        heap := kernel32.GetProcessHeap()
        _ = kernel32.HeapFree(heap, 0, ptr)
    #else:
        lc.free(ptr)

--| The error of the last failed OS call, from `errno` (POSIX) or `GetLastError` (Windows). Read it right after the
--| call: a later call can change it. `last_os_error` gives the code itself.
fn last_error() -> error:
    #if meta.system() == .windows:
        return windows.fromWin32Error()
    #else:
        return from_errno(int(lc.errno))

--| The code of the last failed OS call: `errno` (POSIX) or `GetLastError` (Windows).
fn last_os_error() -> int:
    #if meta.system() == .windows:
        return int(kernel32.GetLastError())
    #else:
        return int(lc.errno)

--| Converts a Windows error code (`GetLastError`) to the standard error name. See `from_errno`.
--| Off Windows it gives `error.Unknown`.
fn from_win32_error(code int) -> error:
    #if meta.system() == .windows:
        return windows.from_win32_error(code)
    #else:
        return error.Unknown

--| Converts an `errno` code to the standard error name. Codes without a name give `error.Unknown`, and so does
--| every code on Windows.
--| The names are the same on every platform (`from_win32_error` for Windows codes):
--| `NotFound`, `PermissionDenied`, `AlreadyExists`, `NotADirectory`, `IsADirectory`, `DirectoryNotEmpty`, `NoSpace`,
--| `ReadOnly`, `NameTooLong`, `TooManyOpenFiles`, `Busy`, `CrossesDevices`, `Interrupted`, `WouldBlock`, `TimedOut`,
--| `BrokenPipe`, `ConnectionRefused`, `OutOfMemory`, `InvalidArgument`, `Unsupported`, `Unknown`.
fn from_errno(code int) -> error:
    #if meta.system() == .windows:
        return error.Unknown
    #else:
        -- An `errno` is a C `int`. A code outside it has no name.
        if code < -0x80000000 or code > 0x7fffffff:
            return error.Unknown
        e := lc.c_int(code)
        if e == lc.ENOENT: return error.NotFound
        if e == lc.EPERM or e == lc.EACCES: return error.PermissionDenied
        if e == lc.EEXIST: return error.AlreadyExists
        if e == lc.ENOTDIR: return error.NotADirectory
        if e == lc.EISDIR: return error.IsADirectory
        if e == lc.ENOSPC: return error.NoSpace
        if e == lc.EROFS: return error.ReadOnly
        if e == lc.EMFILE or e == lc.ENFILE: return error.TooManyOpenFiles
        if e == lc.EBUSY: return error.Busy
        if e == lc.EXDEV: return error.CrossesDevices
        if e == lc.EINTR: return error.Interrupted
        if e == lc.EPIPE: return error.BrokenPipe
        if e == lc.ENOMEM: return error.OutOfMemory
        if e == lc.EINVAL or e == lc.EBADF or e == lc.EFAULT: return error.InvalidArgument
        #if meta.system() == .macos:
            if e == lc.macos.ENOTEMPTY: return error.DirectoryNotEmpty
            if e == lc.macos.ENAMETOOLONG: return error.NameTooLong
            if e == lc.macos.EAGAIN: return error.WouldBlock
            if e == lc.macos.ETIMEDOUT: return error.TimedOut
            if e == lc.macos.ECONNREFUSED: return error.ConnectionRefused
            if e == lc.macos.ENOSYS or e == lc.macos.ENOTSUP: return error.Unsupported
        #else meta.system() == .linux:
            if e == lc.linux.ENOTEMPTY: return error.DirectoryNotEmpty
            if e == lc.linux.ENAMETOOLONG: return error.NameTooLong
            if e == lc.linux.EAGAIN: return error.WouldBlock
            if e == lc.linux.ETIMEDOUT: return error.TimedOut
            if e == lc.linux.ECONNREFUSED: return error.ConnectionRefused
            if e == lc.linux.ENOSYS or e == lc.linux.ENOTSUP: return error.Unsupported
        return error.Unknown

--| Returns an environment variable by key.
fn get_env(key str) -> ?str:
    #if meta.system() == .windows:
        return windows.getEnvWindows(key)
    #else:
        ckey := str.initz(key)
        cval := lc.getenv(ckey.ptr)
        if cval == none:
            return none
        return c.from_strz(cval)

--| Returns all environment variables as a map.
fn get_env_all() -> ^Map[str, str]:
    #if meta.system() == .windows:
        return windows.getEnvAllWindows()
    #else:
        panic('get_env_all not yet implemented on this platform')

--| Allocates `size` bytes of memory and returns a pointer.
fn malloc(size int) -> !Ptr[void]:
    #if meta.system() == .windows:
        heap := kernel32.GetProcessHeap()
        ptr := kernel32.HeapAlloc(heap, 0, size)
        if ptr == none:
            return windows.fromWin32Error()
        return ptr
    #else:
        ptr := lc.malloc(size)
        if ptr == none:
            return last_error()
        return ptr

--| Returns the number of CPU cores on the current machine.
fn num_cpus() -> int:
    #if meta.system() == .macos:
        var count c.c_int = 0
        var count_len c.size_t = type.size(c.c_int)
        res := lc.macos.sysctlbyname('hw.logicalcpu', &count, &count_len, none, 0)
        if res == -1:
            return last_error()
        return count
    #else meta.system() == .linux:
        var cpu_set lc.cpu_set_t = undef
        if lc.linux.sched_getaffinity(0, type.size(lc.cpu_set_t), *cpu_set) != 0:
            return last_error()
        sum := 0
        for cpu_set |x|:
            --sum += @pop_count(x)
            panic('TODO: pop_count')
        return sum
    #else meta.system() == .windows:
        info := kernel32.SYSTEM_INFO{
            wProcessorArchitecture=undef, wReserved=undef, dwPageSize=undef,
            lpMinimumApplicationAddress=undef, lpMaximumApplicationAddress=undef,
            dwActiveProcessorMask=undef, dwNumberOfProcessors=undef,
            dwProcessorType=undef, dwAllocationGranularity=undef,
            wProcessorLevel=undef, wProcessorRevision=undef,
        }
        kernel32.GetSystemInfo(&info)
        return as[int] info.dwNumberOfProcessors
    #else:
        panic('num_cpus not supported on this platform')

fn open_dir(path str) -> !Dir:
    return open_dir(path, true)

--| Opens a directory at the given `path`. `iterable` indicates that the directory's entries can be iterated.
fn open_dir(path str, iterable bool) -> !Dir:
    #if meta.system() == .windows:
        -- Verify directory exists
        path16 := windows.utf8ToUtf16Le(path)!
        attrs := kernel32.GetFileAttributesW(path16.ptr)
        if attrs == kernel32.DWORD(4294967295):  -- INVALID_FILE_ATTRIBUTES
            return windows.fromWin32Error()

        -- On Windows, fd_t is void. We must provide fd field but it's unused.
        -- Return Dir directly (no local var) since Dir has NoCopy trait
        return Dir{fd=undef, path=path}

    #else:
        cpath := str.initz(path)
        fd := lc.open(cpath.ptr, lc.O_RDONLY || lc.O_DIRECTORY || lc.O_CLOEXEC, lc.mode_t(0))
        if fd == -1:
            return last_error()
        return {fd=fd}

--| Returns the current time in nanoseconds since the Epoch.
fn nano_time() -> !int:
    #if meta.system() == .macos:
        tp := lc.timespec{}
        if lc.clock_gettime(lc.macos.CLOCK_REALTIME, *tp) != 0:
            return last_error()
        return tp.sec * ns_per_s + tp.nsec
    #else meta.system() == .linux:
        tp := lc.timespec{}
        if lc.clock_gettime(lc.linux.CLOCK_REALTIME, *tp) != 0:
            return last_error() 
        return tp.sec * ns_per_s + tp.nsec
    #else meta.system() == .windows:
        ft := kernel32.FILETIME{dwLowDateTime=undef, dwHighDateTime=undef}
        kernel32.GetSystemTimeAsFileTime(&ft)
        -- FILETIME is 100-nanosecond intervals since Jan 1, 1601
        -- Unix epoch is Jan 1, 1970 = 116444736000000000 intervals
        intervals := (as[int] ft.dwHighDateTime << 32) || as[int] ft.dwLowDateTime
        unix_intervals := intervals - 116444736000000000
        return unix_intervals * 100  -- Convert to nanoseconds
    #else:
        panic('nano_time not supported on this platform')

--| High resolution timestamp. Returns a relative up-time in nanoseconds.
fn now() -> !int:
    #if meta.system() == .macos:
        tp := lc.timespec{}
        if lc.clock_gettime(lc.macos.CLOCK_UPTIME_RAW, *tp) != 0:
            return last_error()
        return tp.sec * ns_per_s + tp.nsec

    #else meta.system() == .linux:
        tp := lc.timespec{}
        if lc.clock_gettime(lc.linux.CLOCK_BOOTTIME, *tp) != 0:
            return last_error()
        return tp.sec * ns_per_s + tp.nsec

    #else meta.system() == .windows:
        counter := windows.LARGE_INTEGER{QuadPart=0}
        freq := windows.LARGE_INTEGER{QuadPart=0}
        if kernel32.QueryPerformanceCounter(&counter) == windows.FALSE:
            return windows.fromWin32Error()
        if kernel32.QueryPerformanceFrequency(&freq) == windows.FALSE:
            return windows.fromWin32Error()
        -- Convert to nanoseconds avoiding overflow:
        -- Instead of (counter * ns_per_s) / freq which overflows,
        -- compute: secs * ns_per_s + (remainder * ns_per_s) / freq
        secs := counter.QuadPart / freq.QuadPart
        remainder := counter.QuadPart % freq.QuadPart
        return secs * ns_per_s + (remainder * ns_per_s) / freq.QuadPart

    #else:
        panic('now not supported on this platform')


fn open_file(path str) -> !File:
    return open_file(path, .read)

--| Opens a file at the given `path` with an `OpenMode`.
fn open_file(path str, mode OpenMode) -> !File:
    #if meta.system() == .windows:
        return windows.open_file(path, mode)
    #else:
        pathz := str.initz(path)
        access := switch mode:
            case .read       => lc.O_RDONLY
            case .write      => lc.O_WRONLY
            case .read_write => lc.O_RDWR
        fd := lc.open(pathz.ptr, access || lc.O_CLOEXEC, lc.mode_t(0))
        if fd == -1:
            return last_error()
        return {fd=fd}

--| Returns a result that can be used to query args. 
--| `opts`: The name of options to match excluding the hyphen prefix. eg. `-path`
fn parse_args(opts []str) -> ArgsResult:
    cmd_args := args()

    arg_opts := []ArgOption{}
    rest := []str{}

    for 0..cmd_args.len() |i|:
        arg := cmd_args[i]
        if arg[0] == '-':
            name_pair := arg[1..]
            val := ''
            name_end := name_pair.len()
            if name_pair.index('=') |ii|:
                name_end = ii
                val = name_pair[ii+1..]
            name := name_pair[0..name_end]
            if !opts.contains(name):
                rest += arg
                continue

            arg_opts += {name=name, value=val}
        else:
            rest += arg

    return ArgsResult{
        opts = arg_opts,
        rest = rest,
    }

--| Reads the file at `path` as text. Returns `error.Unicode` when the contents are not valid UTF-8.
--| Read bytes with `read_file_bytes`.
fn read_file(path str) -> !str:
    return str.from_utf8(read_file_bytes(path)!)

--| Reads the file contents from `path` as bytes.
fn read_file_bytes(path str) -> ![]byte:
    file := open_file(path)!
    return file.read_all()

--| Removes an empty directory at `path`.
fn remove_dir(path str) -> !void:
    #if meta.system() == .windows:
        path16 := windows.utf8ToUtf16Le(path)!
        if kernel32.RemoveDirectoryW(path16.ptr) == windows.FALSE:
            return windows.fromWin32Error()
    #else:
        cpath := str.initz(path)
        if lc.rmdir(cpath.ptr) != 0:
            return last_error()

--| Removes the file at `path`.
fn remove_file(path str) -> !void:
    #if meta.system() == .windows:
        path16 := windows.utf8ToUtf16Le(path)!
        if kernel32.DeleteFileW(path16.ptr) == windows.FALSE:
            return windows.fromWin32Error()
    #else:
        cpath := str.initz(path)
        if lc.unlink(cpath.ptr) != 0:
            return last_error()

--| Returns the current executable's path.
fn resolve_exe_path() -> !str:
    #if meta.system() == .windows:
        return windows.getExePathWindows()
    #else meta.system() == .macos:
        buf := [lc.PATH_MAX]byte(0)
        len := i32(buf.len())
        if lc.macos._NSGetExecutablePath(*buf[0], *len) != 0:
            return last_error()
        path := c.from_strz(*buf[0])
        return resolve_path(path)
    #else:
        panic('unsupported')

--| Returns the absolute path of the given path.
fn resolve_path(path str) -> !str:
    #if meta.system() == .windows:
        path16 := windows.utf8ToUtf16Le(path)!
        -- First call to get required buffer size
        size := kernel32.GetFullPathNameW(path16.ptr, 0, none, none)
        if size == 0:
            return windows.fromWin32Error()
        -- Allocate buffer and get full path
        buf := []windows.WCHAR(size, 0)
        result := kernel32.GetFullPathNameW(path16.ptr, size, buf.ptr, none)
        if result == 0:
            return windows.fromWin32Error()
        return windows.utf16LeToUtf8(buf)

    #else:
        buf := [lc.PATH_MAX]byte(0)
        pathz := str.initz(path)
        fd := lc.open(pathz.ptr, lc.O_RDONLY || lc.O_CLOEXEC || lc.O_NONBLOCK, lc.mode_t(0))
        if fd == -1:
            return last_error()

        #if meta.system() == .macos:
            file := File{fd=fd}
            if lc.fcntl(file.fd, lc.macos.F_GETPATH, *buf[0]) != 0:
                return last_error()
            return c.from_strz(*buf[0])
        #else meta.system() == .linux:
            proc_path := str.initz('/proc/self/fd/%{fd}')
            len := lc.readlink(proc_path.ptr, *buf[0], lc.PATH_MAX)
            if len < 0:
                return last_error()
            return str(buf[0..len])
        #else:
            panic('resolve_path not supported on this platform')

--| Sets an environment variable by key.
fn set_env(key str, val str) -> !void:
    #if meta.system() == .windows:
        key16 := windows.utf8ToUtf16Le(key)!
        val16 := windows.utf8ToUtf16Le(val)!
        if kernel32.SetEnvironmentVariableW(key16.ptr, val16.ptr) == windows.FALSE:
            return windows.fromWin32Error()

    #else:
        ckey := str.initz(key)
        cval := str.initz(val)
        if lc.setenv(ckey.ptr, cval.ptr, 1) != 0:
            return last_error()

--| Pauses the current thread for `nsecs` nanoseconds.
fn sleep(nsecs int) -> !void:
    #if meta.system() == .windows:
        -- Windows Sleep takes milliseconds
        ms := nsecs / 1000000
        if ms == 0 and nsecs > 0:
            ms = 1  -- Minimum 1ms for non-zero sleep
        kernel32.Sleep(kernel32.DWORD(ms))

    #else:
        s := nsecs / ns_per_s
        ns := nsecs % ns_per_s
        req := lc.timespec{
            sec = s,
            nsec = as ns,
        }
        rem := lc.timespec{}
        if lc.nanosleep(*req, *rem) != 0:
            return last_error()

--| Removes an environment variable by key.
fn unset_env(key str) -> !void:
    #if meta.system() == .windows:
        key16 := windows.utf8ToUtf16Le(key)!
        -- Setting value to none removes the variable
        _ = kernel32.SetEnvironmentVariableW(key16.ptr, none)
        -- Ignore errors - variable may not exist
    
    #else:
        ckey := str.initz(key)
        if lc.unsetenv(ckey.ptr) != 0:
            return last_error()

--| Writes the text `contents` to a file. Write bytes with `write_file_bytes`.
fn write_file(path str, contents str) -> !void:
    file := create_file(path)!
    file.write_all(contents)!

--| Writes the bytes `contents` to a file.
fn write_file_bytes(path str, contents []byte) -> !void:
    file := create_file(path)!
    file.write_all(contents)!

type ArgOption:
    name  str
    value str

type ArgsResult:
    opts []ArgOption

    -- `args` that contains the non-option arguments.
    rest []str

fn (&ArgsResult) at(name str) -> str:
    return self.get(name) ?else panic("Missing option `%{name}`.")

fn (&ArgsResult) contains(name str) -> bool:
    return self.get(name) != none

fn (&ArgsResult) get(name str) -> ?str:
    for self.opts |opt|:
        if opt.name == name:
            return opt.value
    return none

fn (&ArgsResult) get_all(name str) -> []str:
    res := []str{}
    for self.opts |opt|:
        if opt.name == name:
            res += opt.value
    return res
    
type File:
    with io.Reader
    with io.Writer
    with NoCopy
    fd     FileHandle
    closed bool = false

fn (&File) @deinit():
    self.close()

--| Closes the file handle. File ops invoked afterwards will return `error.Closed`.
fn (&File) close() -> void:
    if self.closed:
        return

    #if meta.system() == .windows:
        if kernel32.CloseHandle(self.fd) == windows.FALSE:
            panic("Unexpected. %{windows.fromWin32Error()}")
    #else:
        if lc.close(self.fd) != 0:
            panic("Unexpected. %{last_error()}")

    self.closed = true

--| Returns info about the file.
fn (&File) info() -> !FileInfo:
    #if meta.system() == .linux:
        return linux.file_info(self.fd)
    #else meta.system() == .macos:
        cstat := lc.Stat{}
        if lc.fstat(self.fd, &cstat) != 0:
            return last_error()
        return file_info(&cstat)
    #else meta.system() == .windows:
        info := kernel32.BY_HANDLE_FILE_INFORMATION{
            dwFileAttributes=undef, ftCreationTime=undef,
            ftLastAccessTime=undef, ftLastWriteTime=undef,
            dwVolumeSerialNumber=undef, nFileSizeHigh=undef,
            nFileSizeLow=undef, nNumberOfLinks=undef,
            nFileIndexHigh=undef, nFileIndexLow=undef,
        }
        if kernel32.GetFileInformationByHandle(self.fd, &info) == windows.FALSE:
            return windows.fromWin32Error()
        return windows.fileInfoFromHandle(&info)
    #else:
        panic('File.info not supported on this platform')

--| Returns number of bytes read. If 0 is returned, then the file has reached the end.
fn (&File) read(buf [&]byte) -> !int:
    #if meta.system() == .windows:
        var bytes_read windows.DWORD = 0
        result := kernel32.ReadFile(self.fd, as buf.base, windows.DWORD(buf.length), &bytes_read, none)
        if result == windows.FALSE:
            return windows.fromWin32Error()
        return as[int] bytes_read
    #else:
        read := lc.read(self.fd, as buf.base, buf.length)
        if read == -1:
            return last_error()
        return read

fn (&File) read(bytes int) -> ![]byte:
    buf := []byte(bytes, 0)
    read := self.read(buf.span())!
    buf.size_down(read)
    return buf

--| Reads to the end of the file.
fn (&File) read_all() -> ![]byte:
    res := []byte{}
    buf := [4096]byte(0)
    while:
        read := self.read_fill(buf[..])!
        res += buf[0..read]
        if read < buf.len():
            break
    return res

--| Returns number of bytes read to the buffer `to`.
--| If read bytes is less than `to.len()`, the end of file was reached.
fn (&File) read_fill(as_buf AsSpan[byte]) -> !int:
    buf := as_buf.span()
    i := 0
    while i < buf.len():
        read := self.read(buf[i..])!
        if read == 0:
            break
        i += read
    return i

--| Reads until a new line as a `str`.
--| For bulk line reading, consider using `Scanner.nextLine`.
fn (&File) read_line() -> !str:
    return error.TODO
    -- const input = try std.io.getStdIn().reader().readUntilDelimiterAlloc(vm.alloc, '\n', 10e8);
    -- defer vm.alloc.free(input);
    -- // TODO: Use allocOwnedString
    -- return vm.heap.newStr(input);

--| Seeks the read/write position by `pos` bytes from the current position.
fn (&File) seek(n int) -> !void:
    #if meta.system() == .windows:
        windows.seek_file(self.fd, n, windows.core.FILE_CURRENT)!
    #else:
        res := lc.lseek(self.fd, lc.off_t(n), lc.SEEK_CUR)
        if res == -1:
            return last_error()

--| Seeks the read/write position by `pos` bytes from the end. Positive `pos` is invalid.
fn (&File) seek_from_end(n int) -> !void:
    #if meta.system() == .windows:
        windows.seek_file_from_end(self.fd, n)!
    #else:
        res := lc.lseek(self.fd, lc.off_t(n), lc.SEEK_END)
        if res == -1:
            return last_error()

--| Seeks the read/write position to `pos` bytes from the start. Negative `pos` is invalid.
fn (&File) seek_from_start(n int) -> !void:
    #if meta.system() == .windows:
        windows.seek_file_from_start(self.fd, n)!
    #else:
        res := lc.lseek(self.fd, lc.off_t(n), lc.SEEK_SET)
        if res == -1:
            return last_error()

--| Writes a string to the current file position.
fn (&File) write(val str) -> !int:
    #if meta.system() == .windows:
        var bytes_written windows.DWORD = 0
        result := kernel32.WriteFile(self.fd, as val.ptr, windows.DWORD(val.len()), &bytes_written, none)
        if result == windows.FALSE:
            return windows.fromWin32Error()
        return as[int] bytes_written
        
    #else:
        written := lc.write(self.fd, as val.ptr, val.len())
        if written == -1:
            return last_error()
        return written

--| Writes the span `buf` to the file and returns the number of bytes written. Implements `io.Writer`.
fn (&File) write(buf [&]byte) -> !int:
    #if meta.system() == .windows:
        var bytes_written windows.DWORD = 0
        result := kernel32.WriteFile(self.fd, as buf.base, windows.DWORD(buf.length), &bytes_written, none)
        if result == windows.FALSE:
            return windows.fromWin32Error()
        return as[int] bytes_written

    #else:
        written := lc.write(self.fd, as buf.base, buf.length)
        if written == -1:
            return last_error()
        return written

--| Writes `buf` to the file and returns the number of bytes written.
fn (&File) write(buf []byte) -> !int:
    #if meta.system() == .windows:
        var bytes_written windows.DWORD = 0
        result := kernel32.WriteFile(self.fd, as buf.ptr, windows.DWORD(buf.len()), &bytes_written, none)
        if result == windows.FALSE:
            return windows.fromWin32Error()
        return as[int] bytes_written

    #else:
        written := lc.write(self.fd, as buf.ptr, buf.len())
        if written == -1:
            return last_error()
        return written

fn (&File) write_all(val str) -> !void:
    slice := val.ptr[0..val.len()]
    self.write_all(val.span())!

fn (&File) write_all(as_val AsSpan[byte]) -> !void:
    val := as_val.span()
    i := 0
    while i < val.length:
        -- Create a proper []byte slice from the span
        remaining := val[i..]
        buf := []byte(remaining.length, 0)
        -- Copy bytes from span to buffer
        for 0..remaining.length |j|:
            buf[j] = remaining[j]
        i += self.write(buf)!

type Dir:
    with NoCopy
    fd     FileHandle
    closed bool = false
    path str = '' -- TODO: Required by AI DirIterator implementation. Replace with NtQueryDirectoryFile.

fn (&Dir) @deinit():
    self.close()

fn (&Dir) close():
    if self.closed:
        return

    #if meta.system() == .windows:
        -- Windows Dir doesn't use fd directly, iterator handles are closed separately
        pass
    #else:
        res := lc.close(self.fd)
        if res != 0:
            panic("Unexpected. %{last_error()}")

    self.closed = true

--| Returns info about the directory.
fn (&Dir) info() -> !FileInfo:
    #if meta.system() == .linux:
        return linux.file_info(self.fd)
    #else meta.system() == .macos:
        cstat := lc.Stat{}
        if lc.fstat(self.fd, &cstat) != 0:
            return last_error()
        return file_info(&cstat)
    #else meta.system() == .windows:
        -- Use path to get directory info
        return file_info(self.path)
    #else:
        panic('Dir.info not supported on this platform')

--| Returns a new iterator over the directory entries.
--| If this directory was not opened with the iterable flag, `error.NotAllowed` is returned instead.
fn (&Dir) iterator() -> DirIterator:
    var new DirIterator = undef
    #if meta.system() == .macos:
        new = {impl = macos.DirIteratorImpl()}
    #else meta.system() == .linux:
        new = {impl = linux.DirIteratorImpl()}
    #else meta.system() == .windows:
        -- Initialize with struct literal, find_data will be filled by FindFirstFileW
        -- Note: We don't store dir_path to avoid string reference counting issues
        new = {impl = windows.DirIteratorImpl{find_data=undef}}
    #else:
        panic('DirIterator not supported on this platform')
    return new

--| Returns a new iterator over the directory recursive entries.
--| If this directory was not opened with the iterable flag, `error.NotAllowed` is returned instead.
fn (&Dir) walk() -> DirIterator:
    panic('TODO')

type DirIterator:
    impl DirIteratorImpl

--| Returns the next directory entry.
fn (&DirIterator) next(dir &Dir) -> !?DirEntry:
    return self.impl.next(dir)

type DirIteratorStub

fn (&DirIteratorStub) next(dir &Dir) -> !?DirEntry:
    panic('unsupported')

type DirIteratorImpl = switch meta.system():
    case .macos => macos.DirIteratorImpl
    case .linux => linux.DirIteratorImpl
    case .windows => windows.DirIteratorImpl
    else => DirIteratorStub

type DirEntry:
    kind FileKind
    name str

type FileInfo:
    inode int
    size  int
    mode  i32
    kind  FileKind

    -- Last access time since UNIX epoch.
    atime_sec  int
    atime_nsec int

    -- Last modification time since UNIX epoch.
    mtime_sec  int
    mtime_nsec int

    -- Last status/metadata change time since UNIX epoch. 
    ctime_sec  int
    ctime_nsec int

type FileKind enum:
    case block_device
    case character_device
    case directory
    case named_pipe
    case sym_link
    case file
    case unix_domain_socket
    case whiteout
    case door
    case event_port
    case unknown

type OpenMode enum:
    case read
    case write
    case read_write
