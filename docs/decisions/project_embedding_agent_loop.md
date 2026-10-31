# libcyber 임베딩 검토 (에이전트 루프용)

2026-10-31, TARS 에이전트 루프(CodeAct 계열)의 실행 언어 후보로 Cyber를 라이브러리로 붙일 수 있는지 검토한 기록.
측정은 macOS arm64, Zig 0.17.0, `zig build lib -Doptimize=ReleaseFast`로 만든 `libcyber.a`에 C 프로그램을
링크해서 했다. 재현 프로그램은 `examples/libcyber/host_tool.c`이며 `zig build lib-standalone-test`에 포함했다.

## 결론

- 라이브러리 경로는 쓸 만하다. VM 하나를 만들어 두고 스크립트를 반복 eval하면서 호스트 함수를 도구로 노출하는
  패턴이 동작하고, 컴파일 에러 · 런타임 panic 뒤에도 같은 VM을 계속 쓸 수 있다.
- 실행 중인 스크립트를 밖에서 멈출 수단은 없다. 폭주 스크립트 차단은 호스트가 프로세스 · 스레드 수준에서 해야 한다.
- REPL식 상태 유지(`persist_main`)는 upstream에서 미완성이다. 함수 · 타입 선언은 다음 eval로 넘어가지만
  지역 변수는 넘어가지 않는다. 에이전트 루프에서는 상태를 호스트가 들고 있거나 매 턴 전체 스크립트를 다시 eval하는 쪽이 맞다.

## 측정값

| 항목 | 값 |
| --- | --- |
| `libcyber.a` 크기 (ReleaseFast, FFI 끔) | 2.1 MB |
| `cl_vm_init` | 0.2 ms |
| 첫 eval (`print('hello')`, core 모듈 로드 포함) | 2.8 ms |
| 같은 VM에서 두 번째 eval | 0.01 ms |
| `cl_vm_reset` 뒤 eval | 2.0 ms (core를 다시 로드) |
| `for 0..1000000` 누적 루프 | 4.8 ms |

## 라이브러리 구성

- `zig build lib`는 FFI를 끄고(`standalone_opts.ffi = false`) 정적 라이브러리를 만든다. `build.zig:165`.
- 내장 모듈은 소스를 `@embedFile`로 포함하므로 디스크의 `src/`가 필요 없다. 라이브러리의 기본 로더
  (`cl_default_loader`, `src/compiler.zig`의 `mods`)가 제공하는 모듈은 `core` · `meta` · `math` · `cy` · `c` · `io` · `test`다.
- `os` · `libc` · `cli`는 CLI 전용이다(`src/cli.zig:88`). 라이브러리에서 `use os`는 "Failed to load module: os"
  컴파일 에러가 된다. 파일 · 프로세스 · 환경변수 접근은 호스트가 도구 함수로 열어 주는 것만 가능하다.
- `c` 모듈은 FFI를 꺼도 남는다. `c.to_strz` · `c.from_strz`와 `Ptr[byte]`로 raw 포인터를 다룰 수 있고, extern
  호출만 panic으로 막힌다. 스크립트를 신뢰하지 않는다면 로더에서 `c`를 거르는 것을 고려한다.
- `cl_vm_initx(CLAllocator)`로 할당자를 바꿀 수 있어 메모리 상한을 호스트 할당자에서 걸 수 있다.

## `single_run`

- `CLEvalConfig.single_run = true`는 "이 프로세스는 eval 한 번 하고 끝난다"는 뜻이다. 컴파일러가 main 블록 지역 변수의
  해제 코드를 생략하므로 빠르지만, 그 변수들이 가진 메모리는 `cl_vm_deinit`에서 한꺼번에 정리된다(raw buffer는
  `Heap.freeAllBuffers`, heap 객체는 페이지 단위 해제). 제너레이터 프레임처럼 그 밖에서 할당된 것은 해제되지 않는다.
- 임베딩에서 VM을 재사용하거나 누수 검사를 하려면 기본값 `false`를 유지한다. CLI는 ReleaseFast에서만 `true`를 켠다.

## 호스트 ↔ 스크립트 경계

- 호스트 함수는 모듈 로더에서 `#[bind] fn` 선언 소스와 `cl_mod_add_func`로 묶는다. 인자는 `cl_thread_str` 등으로
  꺼내고 반환값은 `cl_thread_ret`로 받은 슬롯에 쓴다. `str` 반환은 `cl_str_init`로 만든다.
- 스크립트의 결과는 `fn main() -> T`의 반환값으로 받는다. `CLEvalResult.res`가 값 포인터, `res_t`가 타입 id이고
  `cl_value_desc`로 문자열화할 수 있다. 상위 문장만 있는 스크립트는 `res_t`가 void(1)다.
- 출력은 `cl_vm_set_printer` · `cl_vm_set_eprinter`로 가로챈다. `print`는 본문과 개행을 따로 두 번 호출한다.
- 에러는 반환 코드(`CL_ERROR_COMPILE` · `CL_ERROR_PANIC`)와 `cl_vm_error_summary`로 받는다. panic 요약에는 스택
  트레이스가 포함된다.

## 실행 제어

- VM 루프에 호스트가 끼어드는 지점이 없다. `CL_RET_INTERRUPT`는 호스트 함수가 panic을 일으킬 때 쓰는 값이지
  외부 중단이 아니다. 스텝 예산 · 타임아웃 · 취소 플래그 모두 없다.
- 따라서 에이전트 루프에서는 스크립트를 별도 프로세스(또는 종료 가능한 스레드)에서 돌리고 시간 제한은 밖에서 건다.
  필요하면 VM 루프에 체크 포인트를 넣는 패치를 fork에서 검토할 수 있다.
- 컴파일러의 `std.debug.panic` 경로가 호스트 프로세스를 abort시킨다. 2026-10-31에 그중 하나(`persist_main`)를 고쳤지만
  같은 종류가 더 있을 수 있으므로 스크립트 실행 프로세스를 분리할 이유가 하나 더 된다.

## 같은 VM에서 반복 eval할 때의 규칙

- `fn main`이 있는 스크립트를 eval한 뒤 상위 문장만 있는 스크립트를 eval하면 "Body statement is not allowed when
  main function is declared." 컴파일 에러가 났다. 컴파일러가 이전 eval의 `main_func`를 지우지 않아서였고,
  `src/compiler.zig`의 `compileInner`에서 매 컴파일마다 `main_func = null`로 초기화하도록 고쳤다.
  `cl_vm_reset`으로도 지워지지 않던 상태였다.
- `persist_main = true`로 두 번째 eval을 하면 `Unsupported: .use_alias` panic으로 프로세스가 죽었다. 이전 main
  모듈의 심볼을 use alias로 넘기는 루프가 `@main_init` · `@main_deinit`이라는 옛 이름만 걸러서 숨은 함수
  `@program_init` · `@program_deinit`까지 넘겼고, 새 main 청크가 같은 이름을 다시 예약하면서 중복 심볼 보고가
  decl 없는 alias의 `declNode()`를 호출했다. 걸러내는 이름을 현재 이름으로 바꿨다.
- 그 뒤에도 `persist_main`으로 지역 변수를 넘기는 경로(`src/sema.zig`의 `sema_program`, "For REPL, restore
  variables from previous evaluation")는 `return error.TODO`로 막혀 있어 "CompileError: Error: TODO"를 돌려준다.
  upstream 미완성이며 이 fork에서는 손대지 않았다.

## 발견한 다른 문제

- CLI REPL(`cyber`를 인자 없이 실행)은 시작 직후 "CompileError: Import path does not exist: `main`"으로 끝난다.
  `src/main.zig`의 `repl()`이 부트스트랩 소스를 uri `main`으로 eval하는데 CLI resolver(`src/cli.zig`의 `zResolve`)가
  uri를 파일 경로로 보고 `realpath`를 하기 때문이다. upstream의 Zig 0.15 코드에도 같은 구조라 fork에서 생긴 문제는
  아니다. REPL은 fork의 우선 과제가 아니어서 기록만 한다.
