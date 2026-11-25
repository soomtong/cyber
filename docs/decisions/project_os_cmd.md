# `os.cmd`: 명령을 값으로 (2026-11-24)

## 배경

외부 프로그램을 돌리는 길은 `os.exec(args) -> ExecResult{out, err, code}` 하나였다. 인자 목록을 받아 shell 없이 실행하는 것은
옳았지만 나머지가 없었다.

- stdin을 줄 수 없고, 파이프로 이을 수 없고, 작업 디렉터리와 환경 변수를 정할 수 없다. 파이프가 필요하면
  `os.exec({'/bin/bash', '-c', '... | ...'})`로 shell에 문자열을 넘겨야 했다. 인용과 주입 문제가 그대로 돌아온다.
- 0이 아닌 종료 코드는 `code` 필드라서 확인을 빼먹으면 조용히 지나간다.
- 시작하지 못한 프로그램(없는 이름)은 오류 값이 아니라 `panic: FileNotFound`였다. 스크립트가 받을 수 없다.

Julia 검토(`docs/study/11-design-principles-review.md` 3.3.4 · 3.4 A)가 Julia의 `Cmd` · `pipeline`에서 원칙 넷을 뽑았다.
명령은 문자열이 아니라 값이다. shell을 거치지 않는다. 파이프와 리다이렉션은 값의 조립이다. 실패한 종료는 기본이 오류다.

## 결정 (사용자, 2026-11-24: "A의 os.cmd도 넣자")

검토 3.7의 1번이 남긴 두 가지(실패한 종료를 기본 오류로 할지, 파이프의 어느 쪽 실패를 올릴지)는 검토의 권고대로 정했다.
사용자가 따로 고르지 않은 항목이라 아래 "정한 것"에 이유와 함께 적는다. 바꾸려면 여기부터 고친다.

### API (`src/std/os.cy`)

~~~cy
use os

branch := os.cmd({'git', 'rev-parse', '--abbrev-ref', 'HEAD'}).read()!.trim()
top := os.cmd({'du', '-sk', dir}).pipe(os.cmd({'sort', '-rn'})).read()!
os.cmd({'make', 'test'}).dir('build').env('CI', '1').run()!
res := os.cmd({'grep', '-c', 'TODO'}).stdin(text).run_status()!
if res.code != 0:
    eprint(res.err)
~~~

| 함수 | 뜻 |
| --- | --- |
| `os.cmd(args AsSpan[str]) -> Cmd` | `args[0]`을 나머지 인자로 실행하는 명령. 아무것도 시작하지 않는다 |
| `Cmd.pipe(next Cmd) -> Cmd` | 이 명령의 stdout을 `next`의 stdin에 잇는다 |
| `Cmd.dir(path str) -> Cmd` | 지금까지의 모든 단계의 작업 디렉터리 |
| `Cmd.env(name str, value str) -> Cmd` | 지금까지의 모든 단계에 환경 변수 하나. 나머지는 이 프로세스의 환경 |
| `Cmd.stdin(text str) -> Cmd` | 첫 단계의 stdin으로 줄 글 |
| `Cmd.run() -> !void` | 실행하고 기다린다. stdout · stderr는 이 프로세스의 것 |
| `Cmd.read() -> !str` | 마지막 단계의 stdout을 돌려준다. stderr는 이 프로세스의 것 |
| `Cmd.run_status() -> !ExecResult` | stdout, 모든 단계의 stderr, 종료 코드. 0이 아닌 코드는 오류가 아니다 |

### 정한 것

1. `Cmd`는 복사되는 값이다(`NoCopy`가 아니다). 메서드는 새 `Cmd`를 돌려주고 받는 쪽을 바꾸지 않는다. 같은 `Cmd`를 여러 번
   실행할 수 있다. 명령은 자원이 아니라 설명이기 때문이다. 필드는 모듈 밖에서 보이지 않는다(`-stages`, `-input`).
2. 실패한 종료는 `run` · `read`에서 `error.ExitStatus`다. Julia는 예외를 던지지만 사이버에서는 `!T`라서 호출마다 `!`가 보인다.
   종료 코드나 stderr가 필요하면 `run_status`를 쓴다. `error`에 payload가 없으므로(`project_planned_features.md`) 코드를 오류에
   실어 보내지 않는다.
3. 파이프라인은 어느 단계든 실패하면 실패다(bash `pipefail`). `run_status`의 `code`는 실패한 단계 가운데 마지막 것의 코드이고,
   모두 성공이면 0이다. 신호로 끝난 단계는 128 + 신호 번호다(shell의 관례. `kill -9`는 137).
4. 마지막이 아닌 단계가 `SIGPIPE`로 끝나면 성공으로 본다. `yes | head -1`의 `yes`는 할 일을 다 한 것이다. `pipefail`의 잘 알려진
   불편을 피한다. Julia도 `SIGPIPE`로 끝난 프로세스를 성공으로 본다(일반 지식, 이번에 원문을 확인하지 않았다).
5. 표준 스트림:

   | | stdin (첫 단계) | stdout (마지막 단계) | stderr (모든 단계) |
   | --- | --- | --- | --- |
   | `run` | 이 프로세스의 것 | 이 프로세스의 것 | 이 프로세스의 것 |
   | `read` | 빈 입력 | 잡는다 | 이 프로세스의 것 |
   | `run_status` | 빈 입력 | 잡는다 | 잡는다(단계 순서로 이어 붙임) |

   `stdin(text)`를 주면 어느 것이든 그 글이 입력이다. `run`은 Rust의 `status()`, `run_status`는 `output()`과 같은 기본값이다.
   `read`가 stderr를 잡지 않는 것은 Julia의 `read(cmd, String)`과 같다. 실패한 이유가 사용자에게 바로 보인다.
6. 시작하지 못한 프로그램은 오류 값이다. `error.NotFound`(없는 프로그램, 없는 작업 디렉터리), `error.PermissionDenied`,
   `error.InvalidArgument`(빈 인자 목록, 빈 프로그램 이름, NUL이 든 인자, `=`이 든 환경 변수 이름, 17단계 이상),
   `error.NotADirectory` · `error.IsADirectory` · `error.TooManyOpenFiles` · `error.OutOfMemory` · `error.Unknown`.
   이름은 OS 오류의 표준 어휘(`project_os_error_names.md`)다. 어느 단계가 시작하지 못하면 이미 시작한 단계는 끝낸다.
7. 잡는 출력은 stdout 10 MiB, stderr(모든 단계 합) 10 MiB까지다. 넘으면 `error.TooBig`이고 프로그램은 끝낸다. `os.exec`의
   한도와 같다. `yes`처럼 끝없이 쓰는 프로그램이 메모리를 채우지 못하게 한다.
8. 단계는 16개까지다. 넘으면 `error.InvalidArgument`.
9. 환경: 자식은 실행 시점의 이 프로세스 환경을 받는다. `os.set_env`로 바꾼 것도 보인다(아래 "함께 고친 결함").
10. 잡은 출력은 UTF-8을 검증하지 않고 `str`로 돌려준다(`os.exec` · `str(bytes)`와 같다, `project_str_from_utf8.md`).
11. `os.exec`는 그대로 둔다. 반환 타입(`ExecResult`, 결과가 아님)과 시작 실패가 panic인 것을 바꾸면 기존 스크립트가 깨진다.
    문서 주석의 "Runs a shell command"는 사실과 달라 고쳤다. 새 코드는 `os.cmd`를 쓴다.

### 가져오지 않은 것

- 백틱 문법과 보간. 사이버의 백틱은 raw 문자열이다. 인자 목록은 슬라이스 연산으로 만든다(`[]str{'grep', pat} + files`).
- 파일 리다이렉션, 실행 중 중단, 시간 제한은 2026-11-25에 넣었다(아래 "시간 제한 · 중단 · 파일 리다이렉션").
- 줄 단위 스트리밍도 같은 날 넣었다(아래 "줄 단위 스트리밍").
- 단계별 stdin 글, stderr를 stdout에 합치기(`2>&1`), detach.

## 구현

- `os.cy`: `Cmd{stages []CmdStage, input ?str}`, `CmdStage{args, dir, env}`. 실행 메서드는 `start(mode)`에서 단계들을 평평한
  span 다섯(`args`, `counts`, `dirs`, `envs`, `input`)으로 풀어 `#[bind] _cmd_run`에 넘긴다. 호스트는 `CmdRaw{out, err, code, fail}`을
  돌려주고 `cmd_error`가 `fail`을 오류 이름으로 바꾼다. Zig 오류는 `zErrFunc`가 panic으로 바꾸므로 값으로 돌려줄 길이 이것뿐이다.
- `os.zig` `cmdRun` · `cmdRunPipeline`:
  - `std.process.spawn`을 단계마다 부른다. 앞 단계의 stdout은 `.pipe`, 다음 단계의 stdin은 `.{ .file = 앞 단계.stdout }`이고,
    넘긴 뒤 부모 쪽 읽는 끝을 닫는다(안 닫으면 앞 단계가 `SIGPIPE`를 받지 못한다).
  - 잡는 스트림은 `std.Io.File.MultiReader` 하나로 함께 읽는다(스트림 0은 마지막 stdout, 1부터는 각 단계의 stderr).
    `Buffer(17)`을 잡고 `Streams.len`을 실제 개수로 줄여 쓴다. `Streams`는 `len`에서 두 배열의 자리를 계산하므로 안전하다.
  - stdin 글은 따로 띄운 스레드(`cmdFeedInput`)가 쓰고 닫는다. 단계가 입력을 읽기 전에 출력을 읽어 줘야 하고 파이프의 용량은
    정해져 있어서다. 그 스레드에서 `SIGPIPE`를 막는다. 입력을 읽지 않고 끝나는 프로그램이면 쓰기가 신호 대신 오류로 끝나고
    막힌 신호는 스레드와 함께 사라진다. 막지 않으면 사이버 프로세스가 신호로 죽는다.
  - `defer`의 `child.kill`이 오류 경로에서 시작한 단계들을 끝낸다. `wait` 뒤에는 아무 일도 하지 않는다.
  - wasm에서는 `Unsupported.` panic이다(`os.exec`와 같다).
- `stdx.processEnvironBlock`을 pub으로 바꿨다.

## 함께 고친 결함

F-198: 자식이 `os.set_env`로 정한 변수를 받지 못했다. `os.set_env('X', '1')` 뒤 `os.exec({'sh', '-c', 'echo $X'})`가 빈 줄이었다.
`stdx.io()`의 `Threaded`가 처음 만들어질 때 읽은 환경 블록을 기억하고, 환경을 물려주는 spawn이 그 블록을 쓰기 때문이다.
libc의 `setenv`는 `environ`을 새 배열로 옮기므로 옛 블록에는 새 변수가 없다. `os.exec`와 `os.cmd` 모두 실행 시점의 환경으로
만든 map(`currentEnvMap`)을 `environ_map`으로 넘기게 했다.

## PR 리뷰에서 고친 것 (2026-11-24, soomtong/cyber#12)

- 입력 글이 있는 명령이 시작 뒤에 실패하면 끝나지 않았다. `os.cmd({'cat'}).stdin('x'.repeat(12000000)).read()`가 `error.TooBig`
  대신 멈췄다. `cmdRunPipeline`에서 입력 스레드를 기다리는 `defer`가 단계들을 끝내는 `defer`보다 먼저 돌았고, 스레드는 아무도
  읽지 않는 단계에 쓰느라 막혀 있었다. `feeder`의 선언과 join을 단계들의 kill 앞에 두어 kill이 먼저 돌게 했다.
- Windows에서는 환경 map을 만들지 않는다(`inherits_current_env`). 낡은 환경은 libc `setenv`가 `environ`을 옮기는 데서 오는
  문제라 Windows에는 없고, 환경을 주지 않은 자식이 지금의 환경을 받는다. `os.exec`의 Windows 경로가 0.4.19와 같아진다.
  `env()`를 준 단계만 Windows에서도 map을 만든다.
- `a.pipe(b)`가 `b`의 입력 글을 쓰지 않는다는 것을 문서 주석과 매뉴얼에 적었다.
- 테스트의 `pwd`를 `pwd -P`로 바꿨다. `os.cwd()`는 심볼릭 링크를 푼 경로다.
- PR의 CI에서 macOS 두 job이 `modules/os_cmd.cy`로 실패했다. `os.cmd({'yes'}).pipe(os.cmd({'head', '-1'})).read()`가
  `error.ExitStatus`였고 로그에 `yes: stdout: Broken pipe`가 찍혔다. `yes`가 `SIGPIPE`로 끝나지 않고 쓰기 오류로 종료 코드 1을
  낸 것이다. "정한 것" 4번의 규칙은 신호가 단계에 닿아야 성립한다. 닿지 않는 길이 둘 있었다.
  1. 무시된 `SIGPIPE`(`SIG_IGN`)는 exec를 넘어 자식에게 간다. 처음에는 이것이 원인이라고 보고 고쳤다. Linux에서
     `sh -c 'trap "" PIPE; exec cyber x.cy'`로 재현되는 실제 경우다. 고침: 단계가 둘 이상인 파이프라인을 시작하기 전에, 이
     프로세스의 처리가 무시이면 아무 일도 하지 않는 핸들러로 바꾼다(`cmdLetStagesGetSigpipe`). 핸들러는 exec에서 기본 동작으로
     돌아가므로 단계들은 신호를 받는다. 이 프로세스에는 차이가 없다(닫힌 파이프에 쓰면 전처럼 신호 없이 오류).
     `std.Io.Threaded.init`이 하는 것과 같은 방법이다. 기본 동작이나 호스트가 건 핸들러는 건드리지 않는다. 한 번 바꾸면
     되돌리지 않는다: 호스트가 `SIGPIPE`의 처리를 다시 물으면 무시 대신 핸들러가 보인다.
  2. 그 수정 뒤에도 macOS는 같은 줄에서 실패했다. 신호 mask도 exec를 넘어 자식에게 간다. 입력 스레드(`cmdFeedInput`)가
     `SIGPIPE`를 막으려고 `std.posix.sigprocmask`를 불렀는데, Darwin의 `sigprocmask`는 부른 스레드가 아니라 프로세스의 모든
     스레드의 mask를 바꾼다(XNU의 `block_procsigmask`. 기억에 기댄 것이고 이번에 소스를 다시 읽지 않았다). 그래서 `stdin()`을
     한 번 쓴 뒤로는 어느 스레드가 띄우는 단계든 `SIGPIPE`가 막힌 채 시작했다. Linux에서는 스레드 하나의 mask라 드러나지 않았다.
     고침: Darwin에서는 mask를 건드리지 않고 그 파이프에만 `fcntl(F_SETNOSIGPIPE)`를 건다. 다른 POSIX에서는
     `pthread_sigmask`(libc가 없으면 시스템 호출)로 그 스레드만 막는다. 호스트의 mask를 바꾸던 것도 함께 없어졌다.
  남는 경우: 파이프라인을 시작하는 스레드가 스스로 `SIGPIPE`를 mask로 막고 있으면 앞 단계는 신호를 받지 못한다. 다루지 않았다.
  자동 테스트: 1은 behavior 테스트가 자기 프로세스의 신호 처리를 바꿀 길이 없어 없다. 2는 `modules/os_cmd.cy`의 순서(`stdin()`
  뒤의 `yes | head -1`)가 macOS CI에서 잡는다.

## 확인한 것과 못 한 것

- Linux(이 세션의 컨테이너)에서 behavior 테스트 `modules/os_cmd.cy`가 Debug에서 누수 검사와 함께 통과한다. 파이프 · 디렉터리 ·
  환경 · stdin(파이프 용량보다 큰 글을 다 읽는 · 일부만 읽는 · 안 읽는 프로그램) · 실패 종류 · 출력 한도 · 단계 한도 ·
  spawn한 스레드에서의 실행을 본다.
- x86_64-windows-gnu, aarch64-macos, x86_64-macos로 교차 컴파일이 된다.
- 실행해 보지 못한 것: macOS와 Windows에서의 동작. 테스트는 POSIX 프로그램(`sh`, `sort`, `tr` 등)을 쓰므로 Windows에서는
  본문을 건너뛴다. Windows의 파이프 · 인자 인용은 Zig 표준 라이브러리에 맡겼고 직접 확인하지 않았다. macOS는 CI가 돌린다.

## 시간 제한 · 중단 · 파일 리다이렉션 (2026-11-25)

사용자: "os.cmd 이어서 진행". 위 "가져오지 않은 것"의 다음 단계 셋 가운데 둘(시간 제한과 중단, 파일 리다이렉션)을 넣었다.
API 꼴은 사용자가 따로 고르지 않아 아래 비교로 정했다. 바꾸려면 여기부터 고친다.

### 다른 언어

| | 시간 제한 | 파일로 보내기 |
| --- | --- | --- |
| Python `subprocess.run` | `timeout=` 초(float). 지나면 자식을 kill하고 `TimeoutExpired`(그때까지의 출력을 실음) | `stdout=open(...)` 파일 객체 |
| Rust `std::process::Command` | 없음(`wait-timeout` crate, tokio의 `timeout`) | `Stdio::from(File)` |
| Nim `osproc` | `waitForExit(p, timeout: int = -1)` 밀리초 | `startProcess`의 파일 핸들 |
| Zig `std.process` | 없음(`Child.wait`는 기다리기만) | `StdIo.file` |
| Julia | `timedwait`와 `kill` 조합 | `pipeline(cmd, stdout="f", append=true)` |

### API

| 메서드 | 뜻 |
| --- | --- |
| `Cmd.timeout_ms(ms int) -> Cmd` | 명령 전체의 기한. 지나면 단계들을 끝내고 `error.TimedOut` |
| `Cmd.stdin_file(path str) -> Cmd` | 첫 단계의 stdin. `stdin(text)`와 나중에 부른 쪽이 이긴다 |
| `Cmd.stdout_file(path)` · `stdout_append(path)` | 마지막 단계의 stdout을 파일로(비우거나 덧붙임) |
| `Cmd.stderr_file(path)` · `stderr_append(path)` | 지금까지의 모든 단계의 stderr를 파일로 |

### 정한 것

1. 기한은 밀리초 정수다(`timeout_ms`). `time.Duration`을 받으려면 `os`가 `time`을 가져와야 하는데, 그러면 `use os`만 하는
   스크립트의 시작이 10.3 → 14.1 ms(+37%)가 된다(ReleaseFast, hyperfine 20회). 단위를 이름에 넣어 `timeout(5)`를 초로 읽는 실수를
   막는다. Nim이 같은 꼴이다. 0 이하는 실행할 때 `error.InvalidArgument`(조용히 "기한 없음"으로 읽지 않는다).
2. 기한이 지나면 단계들을 `SIGKILL`(Windows `TerminateProcess`)로 끝낸다. Python처럼 SIGTERM 뒤 기다리는 단계는 두지 않았다.
   기다릴 시간도 기한이 되어 버린다. 단계가 스스로 띄운 프로그램(손자)은 끝내지 않는다. 프로세스 그룹으로 묶으면 끝낼 수 있지만,
   그러면 터미널의 Ctrl-C가 `run`의 단계에 닿지 않는다. Python `subprocess.run`도 자식만 끝낸다.
3. 결과는 `error.TimedOut`(OS 오류 표준 어휘, `project_os_error_names.md`)이다. `run_status`도 오류다: 끝까지 가지 않은 명령의
   `code`는 뜻이 없다. 그때까지의 출력은 버린다(`error`에 payload가 없다).
4. `a.pipe(b)`의 기한은 둘 중 짧은 것이다. 입력(앞 명령의 것)이나 stdout 파일(뒤 명령의 것)과 달리 기한은 두 쪽 다 뜻이 있다.
5. 중단: 명령이 도는 동안 `cl_vm_interrupt`가 오면 단계들을 끝내고 VM이 멈춘다. 호스트 함수는 `CmdFail.interrupted`(11)를
   돌려주고 `os.cy`의 `start`가 호출을 반복문 안에 두어 그 반복의 검사점이 VM을 멈추게 한다(regex · peg와 같은 길).
   스크립트는 이 결과를 보지 못한다.
6. stdout 파일은 명령의 속성이고 `pipe`는 뒤 명령의 것을 쓴다(마지막 단계만 뜻이 있다). stderr 파일은 `dir` · `env`처럼 그때까지의
   단계마다 붙는다. 같은 경로 · 같은 방식을 가진 단계들은 파일을 한 번 열어 함께 쓴다(따로 열면 서로 덮어쓴다).
7. 파일은 실행할 때, 어느 단계도 시작하기 전에 연다. 열 수 없으면 아무것도 시작하지 않고 OS 오류다. 상대 경로는 이 프로세스의
   작업 디렉터리 기준이다(`dir`은 단계의 것). Python · Rust도 부모가 연다.
8. 덧붙이기는 POSIX에서 `O_APPEND`로 연다: 다른 프로세스가 그사이 덧붙여도 끝에 쓴다. Zig `Dir.createFile`에 그 선택지가 없어
   `posix.openat`을 쓴다. Windows는 끝으로 옮긴 뒤 넘긴다(`FILE_APPEND_DATA`가 아니라서 동시 쓰기에는 약하다).
9. stdout을 파일로 보낸 명령의 `read`는 `error.InvalidArgument`다. 돌려줄 것이 없는데 빈 문자열을 주면 실수가 숨는다.
   `run_status`는 `out`이 빈 문자열이다(종료 코드와 stderr에는 여전히 뜻이 있다).

### 구현

- 감시 스레드(`os.zig` `CmdWatch`): 모든 단계가 시작된 뒤 띄운다. 20ms마다(또는 기한에) 깨어 중단 요청과 기한을 보고, 걸리면 아직
  끝나지 않은 단계를 끝낸다. 실행하는 스레드는 그동안 읽기나 대기에 막혀 있다. 명령 실행마다 스레드 하나라 `true` 한 번에 약
  0.05~0.08ms(4~6%)가 는다(macOS ReleaseFast, 200회 반복).
- pid 재사용 경쟁: 실행하는 스레드가 단계를 회수(`wait`)한 뒤에는 그 pid가 다른 프로세스일 수 있다. 그래서 회수하지 않고 끝을
  기다린 다음(`waitid(WEXITED | WNOWAIT)`, Windows는 `NtWaitForSingleObject`) 잠금 아래 "끝남"으로 표시하고, 감시 스레드는 같은
  잠금 아래 표시되지 않은 단계만 끝낸다. 감시 스레드를 join한 뒤에 회수한다. Darwin의 `waitid`는 `std.c`에 없어 선언했다.
  Linux · Darwin · Windows 밖에서는 기다리는 동안의 끝내기가 없다(빌드 대상이 아니다).
- 손자가 파이프를 쥐고 있으면 단계를 끝내도 읽기가 끝나지 않는다. 읽기를 50ms 기한으로 돌며 감시 스레드가 멈췄는지 본다.
- `cl_thread_interrupted(t)`를 공개 C API로 더했다. `os.zig`는 `cyber.zig`를 가져올 수 없다(CLI 실행 파일에서 `build_config`가
  다르다). 임베더의 오래 막히는 호스트 함수에도 같은 길이 필요해 공개로 했다.
- 중단 반복을 처음에는 `while: pass`로 썼다가 VM이 멈추지 않는 것을 찾았다(F-208, `project_vm_interrupt.md` 끝).

### 확인

- behavior 테스트 `modules/os_cmd.cy`(기한: 단일 · 파이프 · 입력 글 · 손자가 쥔 파이프 · 짧은 쪽 · 잘못된 값, 파일: 비우기 ·
  덧붙이기 · `dir`과 상대 경로 · `stdin`과의 순서 · `pipe` · 결과에서 빠짐 · `read` 거절 · 같은 파일의 stderr · 열 수 없는 파일).
- cli 테스트 `cl_vm_interrupt stops a running os.cmd and its programs.`(`cli.zig`): `sleep 30 | cat`을 중단해 10초 안에
  `CL_ERROR_INTERRUPT`, 다음 eval은 정상. `os`는 CLI의 모듈이라 lib 테스트에 두지 못한다(`os.zig`를 가져오면 `cli.zig`의
  linenoise까지 분석된다. 필터를 건 lib 테스트에서는 드러나지 않았다). 컴파일 중에 온 요청은 eval 시작에서 지워지므로 테스트는
  eval이 끝날 때까지 100ms마다 다시 요청한다.
- 교차 컴파일: x86_64-windows-gnu, x86_64-linux-gnu, aarch64-linux-gnu, x86_64-macos. 실행은 aarch64 macOS만.
  Windows의 `TerminateProcess` · `SetFilePointerEx` 경로는 실행해 보지 못했다.

## 줄 단위 스트리밍 (2026-11-25)

사용자: 계획(아래)에 "agree. explain the plan" 뒤 "LGTM go implementation and make some examples into @examples/".

### 다른 언어

| | 시작 | 줄 읽기 | 놓을 때 |
| --- | --- | --- | --- |
| Python | `Popen(stdout=PIPE)` | `for line in p.stdout` | 그대로 둔다(`ResourceWarning`) |
| Rust | `Command::spawn` | `BufReader::new(child.stdout).lines()` | 그대로 둔다(기다리지도 않는다) |
| Nim | `startProcess` | `outputStream.lines` | `close`가 끝낸다 |
| Zig | `std.process.spawn` | `File.Reader` | 직접 `kill` · `wait` |
| Julia | `open(cmd)` | `eachline(cmd)` | 블록 꼴의 `open`이 닫는다 |

호스트 함수가 스크립트 함수를 다시 부를 길이 없어서 `each_line(f)` 같은 콜백 꼴은 안 된다. 살아 있는 프로세스를 값으로 든다.

### API

`Cmd.start() -> !Process`, `Process.read_line() -> !?str`, `read_all() -> !str`, `wait() -> !void`, `wait_code() -> !int`, `kill()`.

### 정한 것

1. 값이 사라지면(`@deinit`) 단계들을 끝내고 회수한다. Rust · Python과 다르다. 에이전트가 쓴 스크립트에서 잊힌 `tail -f`가 남는 쪽이
   더 위험하다. 끝난 뒤에도 돌아야 하는 프로그램(detach)은 다루지 않는다.
2. `wait`는 읽지 않은 stdout을 끝까지 읽어 버린다. 읽지 않으면 가득 찬 파이프에 단계가 멈추고(교착), 닫으면 단계가 `SIGPIPE`로
   끝나 거짓 실패가 된다.
3. `kill` 뒤의 `wait`는 `error.ExitStatus`(신호로 끝남), `wait_code`는 137. 다시 기다리면 같은 결과다.
4. `read_line`은 `\n`에서 자르고 앞의 `\r`도 뗀다(Windows 프로그램). 끝에 줄바꿈 없는 조각도 한 줄이다. 10 MiB를 넘는 줄은
   `error.TooBig`.
5. 시간 제한은 `start`부터. 감시 스레드가 값과 함께 산다. 지나면 그 뒤의 `read_line` · `read_all` · `wait`가 `error.TimedOut`이다.
   끝까지 읽은 뒤에도 감시가 단계를 멈췄으면 `none` 대신 `error.TimedOut`이다(잘린 출력을 끝으로 읽지 않게).
6. stdin은 `stdin` · `stdin_file` 아니면 빈 입력, stderr는 이 프로세스의 것(`read`와 같음). stdout을 파일로 보낸 명령의 `start`는
   `error.InvalidArgument`.
7. `for p.lines()`는 넣지 않았다. `for`의 반복자 `next`가 `!?T`를 돌려주면 'Expected `Option` type.' 컴파일 오류다. 반복자가
   오류를 삼키면 실패한 명령이 조용히 끝난 것처럼 보인다.

### 구현

- `os.zig` `CmdProc`: 단계들, 입력 스레드, 감시 스레드, stdout 읽기(`MultiReader` 하나)를 힙에 묶는다. `start` · `finish` ·
  `destroy` · `kill` · `readLine` · `readAll` · `drain`. `_cmd_run`의 `run` · `read` · `run_status`도 같은 `start` · `finish` ·
  `destroy`를 쓴다(호출 안에서 만들고 놓는다). 입력 글은 `start`에서만 복사한다(호출 뒤에도 쓰므로).
- 감시 스레드는 시작한 스레드가 아니라 VM의 main 스레드로 중단 요청을 본다. 모든 스레드가 main의 플래그를 가리키고, main
  스레드는 VM만큼 산다(값이 시작한 스레드보다 오래 살 수 있다).
- 값은 포인터가 아니라 id(`-id int`)를 든다. 호스트의 표(`proc_table`, 잠금 아래)가 id로 `CmdProc`를 찾는다. 정리 함수가 먼저
  돈 뒤에 값이 남아도 해제된 메모리를 가리키지 않는다(없는 id는 `error.InvalidArgument`).
- `Process.op`는 `launch`처럼 호출을 반복 안에 둔다. 중단이면 호스트가 `CmdFail.interrupted`를 돌려주고 반복의 검사점이 VM을 멈춘다.
- 정리: panic 스윕(`freeHeapPages`)은 메모리만 놓고 `@deinit`도 호스트 finalizer도 부르지 않는다(`os.File`도 panic 때 fd가 샌다).
  공개 C API `cl_vm_add_cleanup(vm, fn, ctx) -> id` · `cl_vm_remove_cleanup(vm, id)`를 더했다. VM은 main 스레드의 panic · 중단
  unwind가 힙을 쓸어낸 뒤(`thread.panic`)와 `VM.deinit`(스윕 전)에서 등록된 것을 새것부터 부르고 잊는다. `start`가 등록하고
  `@deinit`이 지운다. CLI는 최상위 지역의 `@deinit`을 부르지 않지만(single_run) VM 해제의 정리가 프로그램을 끝낸다(Debug ·
  ReleaseFast에서 확인).
  - 목록은 `VM` 필드가 아니라 `VM.data`의 "cleanups"에 둔다. `VM`에 필드를 더하면 `vm.h`가 빌드마다 패딩으로 맞추는 `VM.c`의
    오프셋이 바뀌어 빌드가 실패한다(`ZVM padding`).
  - 잠금은 spin이다. 호스트 함수가 어느 스레드에서든 부를 수 있고, wasm에서도 쓴다.
  - spawn한 스레드의 panic에서는 부르지 않는다. 그 값은 main의 다음 스윕이나 VM 해제 때 정리된다. 감시 스레드는 중단 요청에는
    바로 단계들을 끝낸다.

### 확인

- behavior 테스트 `modules/os_cmd.cy`: 줄(`\r\n`, 빈 줄, 끝 조각), 두 번 기다리기, 파이프와 입력 글, `read_all`, `kill`(두 번),
  137, 읽지 않은 300 KB 뒤 `wait_code`, 시간 제한, 시작 실패, 파일 stdout 거절, 값이 사라진 뒤 pid가 없음.
- lib 테스트 `cl_vm_add_cleanup runs when the heap is swept without the values' destructors.`: 정상 끝에는 안 부름, panic · 중단 ·
  VM 해제에서 한 번씩, 지운 것은 안 부름.
- cli 테스트 `cl_vm_interrupt stops a running os.cmd and its programs.`: `read_line`에 막힌 중 중단, 그 프로그램의 pid가 없음.
- 예제 `examples/stream_lines.cy` · `examples/commands.cy`(behavior 테스트가 컴파일한다, wasm 제외).
