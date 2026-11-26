# 표준 입력: 줄 입력 · 파이프 · 숨김 입력 (2026-11-26)

상태: 구현됨. 사용자 요청(2026-11-26): "터미널에서 입출력하는 프로그램을 만들기 위해 키보드 입력 같은 게 필요해. 그리고
파이프라인에서 입력받을 수 있는 것도 필요하고 검증해서 추가하도록 하자." 범위는 질문에 "기본 + 숨김 입력"으로 답했다(키 단위
raw 입력은 넣지 않음).

## 배경

스크립트가 stdin을 읽을 길이 사실상 없었다.

- `os.stdin()` · `os.stdout()` · `os.stderr()`가 깨져 있었다(F-217). Zig 쪽이 옛 꼴의 `File{fd, closed}`를 채웠는데 Cyber의
  `File`은 `33842c2f`(0.4.21)에서 `guard` 칸이 늘었다. `fd`가 쓰레기 값(66560 등)이라 `read`가 `error.InvalidArgument`였고,
  값이 사라질 때 그 번호를 닫다 panic했다. 부르는 테스트가 없어 0.4.21 · 0.4.22에 그대로 나갔다.
- `File.read_line()`은 본문이 `return error.TODO`였다.
- `io.Scanner.next_line()`은 끝나지 않았다(F-218). `read_full`이 `error.EndOfFile`만 끝으로 보는데 `File.read`는 끝에서 0을
  돌려준다. 버퍼 경계에 걸친 줄은 둘로 잘렸고, 줄바꿈이 없는 마지막 조각 뒤 `\r` 검사가 범위를 넘었다.

## 비교

- Python 3.15: `input(prompt)`(줄바꿈 뺌, 끝이면 `EOFError`), `sys.stdin`의 줄 반복, `sys.stdin.read()`, `isatty()`.
  `getpass.getpass(prompt)`는 `/dev/tty`의 echo를 끄고 읽고, `finally`로 되돌린다(Ctrl-C도 `KeyboardInterrupt`라 복구된다).
  터미널이 없으면 경고 뒤 stdin에서 읽는다. stdin은 프로세스 전역 버퍼 객체 하나다.
- Rust: `std::io::stdin()`은 전역 버퍼(`StdinLock`)를 나눠 쓰는 핸들이다. `read_line(&mut String)`은 줄바꿈을 남기고 끝이면 0,
  `lines()` 반복자, `read_to_string`, `IsTerminal`. 숨김 입력 · raw 모드는 std에 없다(`rpassword`, `crossterm`).
- Zig 0.17.1: `std.Io.File.stdin()`에 호출자가 버퍼를 준 reader를 만든다(`takeDelimiterExclusive`). `isTty()`. 숨김 입력은
  `std.posix.tcgetattr` · `tcsetattr`로 직접 한다.
- Nim 2.4: `stdin.readLine()`(끝이면 `EOFError`), `readLine(stdin, line): bool`, `lines(stdin)`, `readAll`, `isatty`.
  `terminal.readPasswordFromStdin`, raw 키는 `terminal.getch`.

공통점: 줄은 줄바꿈 없이 돌려주거나(Python · Nim) 끝을 따로 알린다. stdin 버퍼는 프로세스에 하나다(Python · Rust · C stdio).
숨김 입력은 echo만 끄고 줄 편집(canonical 모드)은 둔다.

## 결정

1. `os.read_line() -> !?str`: 줄바꿈(`\n`, `\r\n`)을 뺀 줄, 끝이면 `none`. 마지막 줄은 줄바꿈이 없어도 된다. Cyber는 끝을
   옵션으로 나타내는 꼴이 이미 있다(`Process.read_line`, `Scanner.next_line`). Python · Nim처럼 오류로 하면 `while` 꼴이 안 된다.
2. `os.input(prompt) -> !?str`: 프롬프트를 줄바꿈 없이 찍고(`prints`, 호스트의 printer) 읽는다. Python의 이름이다.
   프롬프트는 stdin이 터미널일 때만 찍는다(bash `read -p`와 같다, 같은 날 예제 `pi_digits.cy`를 쓰며 바꿈). Python `input`은
   언제나 찍어서 `echo 50 | prog`의 출력이 `Prompt: 3.14...`로 붙는다. 파이프로 받는 프로그램의 출력은 다음 프로그램의 입력이라
   묻는 말이 섞이면 안 된다. `read_password`도 같다.
3. `os.stdin_lines()`: `for`용 반복자(`else |err|:` 필수, `Process.lines`와 같은 꼴). `os.read_stdin() -> !str`: 나머지 전부.
4. `os.read_password(prompt) -> !?str`: 터미널이면 echo를 끄고(`ECHONL`은 켜서 Enter의 줄바꿈은 보인다) 한 줄 읽고 되돌린다.
   읽는 동안 SIGINT 핸들러를 두어 Ctrl-C면 설정을 되돌린 뒤 기본 동작으로 다시 신호를 낸다(CLI에 SIGINT 처리가 없어, 그대로면
   echo가 꺼진 셸이 남는다). 터미널이 아니면 `read_line`과 같다(Python처럼 파이프로 비밀번호를 줄 수 있게, 경고는 없음).
   Windows는 `SetConsoleMode`로 `ENABLE_ECHO_INPUT`을 끄고 줄바꿈을 직접 찍는다.
5. stdin 버퍼는 프로세스에 하나(`os.zig`의 `stdin_buf`, 뮤텍스)다. 모든 VM · 스레드가 나눠 쓰고, `os.stdin()`의 `File.read` ·
   `read_line` · `read_all`도 이 버퍼를 지난다(`File`의 비공개 칸 `std`). 그래서 섞어 써도 입력을 잃지 않는다. 버퍼와 돌려주는
   글은 VM보다 오래 살아 `smp_allocator`(wasm은 `wasm_allocator`)로 잡는다.
6. 기다리는 동안 중단: POSIX는 `poll` 100ms마다 `cl_thread_interrupted`를 보고 `CmdFail.interrupted`(11)를 돌려준다.
   스크립트 쪽 루프(`stdin_op`)가 다시 불러 검사점이 VM을 멈춘다(`os.cmd`와 같은 방식). 읽던 조각은 버퍼에 남는다.
   Windows · wasm은 읽기에서 막힌다.
7. `os.stdin()` · `stdout()` · `stderr()`는 Cyber로 옮겼다(POSIX fd 0 · 1 · 2, Windows `GetStdHandle`). `close()`는 표시만 하고
   스트림을 닫지 않는다. Zig 쪽에 구조체를 비춰 두지 않으니 `File` 칸이 늘어도 다시 어긋나지 않는다.
8. `File.is_terminal()`: Zig `std.Io.File.isTty`(Windows는 콘솔). wasm은 늘 거짓.
9. `File.read_line() -> !?str`(깨지는 변경: 전에는 `!str`이고 언제나 `error.TODO`). stdin이 아니면 한 바이트씩 읽는다(줄 뒤를
   먹지 않게). 많은 줄은 `io.Scanner`.
10. `io.Scanner`를 고쳤다: 읽기가 0이면 끝(`eof` 칸), 줄바꿈을 못 찾으면 더 읽고, 끝에서 남은 조각을 마지막 줄로 준다. 버퍼 끝의
    `\r`은 다음 읽기의 `\n`을 기다린다. `ScannerNextFn`이 `none`을 돌려주면 "더 읽어라"다(전에는 끝으로 봤다).
11. 키 단위 raw 입력(화살표 · Ctrl 키 해석)은 넣지 않았다(사용자 선택). 넣는다면 `os.Terminal` 꼴로 raw 모드를 켜고 끄는 값과
    `read_key() -> !?Key`를 두고, 되돌리기는 `@deinit`과 정리 목록(`cl_vm_add_cleanup`)에 건다.

## 검증

- `src/test/stdin/stdin.cy`를 `verify.sh` 16단계(`16-script-stdin`)가 파이프로 돌린다: `input`, `\r\n`, `File.read`가 버퍼를
  먼저 줌, `stdin_lines`, 9000바이트 넘는 줄바꿈 없는 마지막 줄, 끝 뒤의 `none` · 빈 글 · 0, 표준 스트림의 `close`.
  behavior 러너는 stdin을 줄 수 없고, Zig 테스트 러너의 stdin은 빌드 러너의 통신 채널이라 쓰지 않는다.
- wasm32-wasi CLI(wasmtime)로도 같은 스크립트가 통과한다. Windows는 교차 컴파일만 했다.
- pty(Python `pty.fork`)로: `is_terminal()` 참, `read_password` 동안 ECHO 꺼짐, 입력한 비밀번호가 출력에 없음, Ctrl-C 뒤 셸의
  `stty`에 `echo`가 돌아옴(`rc=130`).
- `io.Scanner`: 버퍼 4 · 2바이트로 `\n` · `\r\n` · `\r` · 빈 줄 · 줄바꿈 없는 끝, `StrReader`와 stdin.

## 한계

- 기다리는 동안의 중단은 POSIX에서만 된다. 실행으로 확인하지 못했다(CLI에 중단을 보낼 길이 없다).
- Windows 콘솔의 줄은 콘솔 코드 페이지 바이트다(`ReadFile`). UTF-8이 아닌 코드 페이지에서는 한글이 깨질 수 있다
  (`ReadConsoleW`로 바꾸는 것은 실행 확인이 필요해 하지 않았다).
- wasm에서 `File.write`(`os.stdout().write`)는 전처럼 C FFI가 없어 panic이다. 출력은 `print` · `eprint`.
