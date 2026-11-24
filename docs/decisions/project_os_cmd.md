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
- 파일 리다이렉션(`stdout="out.txt"`). `read()`의 결과를 `os.write_file`로 쓴다. 큰 출력이 필요해지면 다시 본다.
- 줄 단위 스트리밍, 실행 중 중단, 시간 제한. 호스트 함수 안에서는 `cl_vm_interrupt`가 닿지 않는다(`project_vm_interrupt.md`).
  검토 3.4 A가 다음 단계로 둔 것이다.
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
- PR의 첫 CI에서 macOS 두 job이 `modules/os_cmd.cy`로 실패했다. `os.cmd({'yes'}).pipe(os.cmd({'head', '-1'})).read()`가
  `error.ExitStatus`였고 로그에 `yes: stdout: Broken pipe`가 찍혔다. 그 러너의 테스트 프로세스는 `SIGPIPE`를 무시하고,
  무시 설정은 exec를 넘어 자식에게 간다. 그러면 `yes`는 신호로 끝나지 않고 쓰기 오류로 종료 코드 1을 낸다. "정한 것" 4번의
  규칙은 신호가 자식에게 닿아야 성립한다. Linux에서도 `sh -c 'trap "" PIPE; exec cyber x.cy'`로 재현된다.
  고침: 단계가 둘 이상인 파이프라인을 시작하기 전에, 이 프로세스의 `SIGPIPE` 처리가 무시(`SIG_IGN`)이면 아무 일도 하지 않는
  핸들러로 바꾼다(`cmdLetStagesGetSigpipe`). 핸들러는 exec에서 기본 동작으로 돌아가므로 단계들은 신호를 받는다. 이 프로세스에는
  차이가 없다. 닫힌 파이프에 쓰면 전처럼 신호 없이 오류가 난다. `std.Io.Threaded.init`이 자기가 띄우는 프로세스를 위해 하는
  것과 같은 방법이다. 기본 동작이나 호스트가 건 핸들러는 건드리지 않는다. 한 번 바꾸면 되돌리지 않는다: 임베딩 호스트가
  `SIGPIPE`의 처리를 다시 물으면 무시 대신 핸들러가 보인다.
  남는 경우: 파이프라인을 시작하는 스레드가 `SIGPIPE`를 mask로 막고 있으면 그 mask도 자식에게 가고, 앞 단계는 신호를 받지
  못한다. 이 경우는 다루지 않았다.
  자동 테스트는 없다(behavior 테스트가 자기 프로세스의 신호 처리를 바꿀 길이 없다). macOS CI가 이 경우를 돈다.

## 확인한 것과 못 한 것

- Linux(이 세션의 컨테이너)에서 behavior 테스트 `modules/os_cmd.cy`가 Debug에서 누수 검사와 함께 통과한다. 파이프 · 디렉터리 ·
  환경 · stdin(파이프 용량보다 큰 글을 다 읽는 · 일부만 읽는 · 안 읽는 프로그램) · 실패 종류 · 출력 한도 · 단계 한도 ·
  spawn한 스레드에서의 실행을 본다.
- x86_64-windows-gnu, aarch64-macos, x86_64-macos로 교차 컴파일이 된다.
- 실행해 보지 못한 것: macOS와 Windows에서의 동작. 테스트는 POSIX 프로그램(`sh`, `sort`, `tr` 등)을 쓰므로 Windows에서는
  본문을 건너뛴다. Windows의 파이프 · 인자 인용은 Zig 표준 라이브러리에 맡겼고 직접 확인하지 않았다. macOS는 CI가 돌린다.
