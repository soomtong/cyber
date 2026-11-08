# libcyber 임베딩 검토 (에이전트 루프용)

2026-10-31, TARS 에이전트 루프(CodeAct 계열)의 실행 언어 후보로 Cyber를 라이브러리로 붙일 수 있는지 검토한 기록.
측정은 macOS arm64, Zig 0.17.0, `zig build lib -Doptimize=ReleaseFast`로 만든 `libcyber.a`에 C 프로그램을
링크해서 했다. 재현 프로그램은 `examples/libcyber/host_tool.c`이며 `zig build lib-standalone-test`에 포함했다.

## 결론

- 라이브러리 경로는 쓸 만하다. VM 하나를 만들어 두고 스크립트를 반복 eval하면서 호스트 함수를 도구로 노출하는
  패턴이 동작하고, 컴파일 에러 · 런타임 panic 뒤에도 같은 VM을 계속 쓸 수 있다.
- 실행 중인 스크립트는 `cl_vm_interrupt`(다른 스레드에서도 가능)와 `cl_vm_set_fuel`(검사점 횟수 제한)로 멈춘다
  (2026-11-01, `project_vm_interrupt.md`). 호스트 함수 안에서 막힌 경우는 여전히 못 끊는다.
- REPL식 상태 유지(`persist_main`): 함수 · 타입 · `use` 선언과 main의 지역 변수가 다음 eval로 넘어간다(지역 변수는
  2026-11-01부터). 같은 이름을 다시 선언하면 새 선언이 이긴다. panic이 나면 힙이 비워지므로 지역 변수는 모두 버려진다.
  에이전트 루프에서는 panic에도 남아야 하는 상태라면 여전히 호스트가 들고 있는 편이 안전하다.

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
  해제 코드를 생략하므로 빠르지만, 그 변수들이 가진 메모리는 `cl_vm_deinit`에서 한꺼번에 정리된다. `VM.deinit`이
  맨 앞에서(타입 정보가 살아 있을 때) 패닉 경로와 같은 `thread.freeHeapPages` 스윕을 돌려 heap 객체를 소멸자 없이
  타입 크기대로 해제하고 raw buffer도 해제한다. 큰 객체(32바이트 초과, 페이지 밖 할당)도 여기서 해제된다.
  소멸자를 건너뛰므로 제너레이터 `@deinit` 같은 정리 코드는 돌지 않는다.
- 임베딩에서 VM을 재사용하거나 누수 검사를 하려면 기본값 `false`를 유지한다. CLI는 ReleaseFast에서만 `true`를 켠다.

## 호스트 ↔ 스크립트 경계

- 호스트 함수는 모듈 로더에서 `#[bind] fn` 선언 소스와 `cl_mod_add_func`로 묶는다. 인자는 `cl_thread_str` 등으로
  꺼내고 반환값은 `cl_thread_ret`로 받은 슬롯에 쓴다. `str` 반환은 `cl_str_init`로 만든다.
- 호스트 함수는 값으로 받은 매개변수(`str`, `[]T` 등)를 소유한다. 다 쓰면 `cl_str_deinit` 등으로 해제해야 하고,
  빠뜨리면 힙 문자열을 넘길 때마다 샌다(리터럴은 버퍼가 없어 드러나지 않음). 빌리기만 하려면 매개변수를 `[&]T` span으로
  선언한다. 2026-11-01에 이 규약을 어긴 내장 함수 `atof` · `atof32` · `str.index` · `str.insert` · `cy.VM.eval` ·
  `os.fetchUrl` · `os.cacheUrl`을 고쳤고, `os.exec`는 `AsSpan[str]`을 받는 Cyber 래퍼가 `[&]str`을 바인딩 `_exec`에
  넘기는 형태로 바꿨다. 회귀 테스트는 lib "Host functions release their owned str params."(32바이트 초과 문자열이라야
  누수 검사 allocator에 걸린다), `memory/host_str_params.cy`, `modules/os.cy`의 `exec()`, `modules/cy.cy`.
  `cl_thread_count_objects`로는 이 누수가 잡히지 않았다.
- 소유 규칙의 근거는 `ownOrManageArg`(`src/sema_func.zig`)다. object 타입 인자(`^T` 등)는 호출자가 관리하므로 호스트
  함수는 빌리기만 한다. 그 밖의 타입(구조체 값)은 복사되어 피호출자가 소유한다. 따라서 `str` · `[]T`뿐 아니라 관리 필드를
  가진 구조체(`Future[T]`, `Object` 등)를 값으로 받는 바인딩도 해제 의무가 있다.
  2026-11-01 `str` 외 매개변수 감사: `@notifyFutureComplete(f Future[T])`가 복사본을 해제하지 않아 `FutureResolver.complete`
  마다 `FutureValue`가 샜다. `@await_`처럼 `&FutureValue[T]`를 빌리도록 바꿨다(회귀 테스트 `memory/future_resolver.cy`).
  쓰이지 않던 `@refCount(obj Object)`도 같은 결함이라 `Ptr[void]`로 바꿨다. `@start_thread`의 `^FutureValue`는 object 타입이라
  문제없고, `FnTuple` 인자는 `move`로 넘겨 스레드 스택에 복사되므로 소유가 넘어간다. 나머지 바인딩은 `&T` 수신자,
  `Ptr`, 원시 값, 관리 필드 없는 구조체(`NumberFormatConfig`, `cy.Value`)만 받는다.
- `[]T` 값 매개변수는 `cl_thread_slice`로 받고 `cl_slice_deinit(t, elem_t, &s)`로 해제한다(2026-11-01 추가). `elem_t`는
  원소 타입이고 관리 타입이 아니면 NULL이어도 된다. `Slice.@deinit`과 같이 버퍼가 유일 참조일 때만 버퍼 앞 8바이트의
  초기화 원소 수만큼 원소를 해제한 뒤 버퍼를 release한다. 관리 원소(`[]str` 등)에 NULL을 넘기면 원소가 샌다.
  빌리기만 할 거라면 여전히 `[&]T` span이 더 싸다. 회귀 테스트는 lib "Host functions release their owned slice params."
  (해제를 빼거나 `[]str`에 NULL을 넘기면 누수 검사에 걸리는 것을 확인).
- 스크립트의 결과는 `fn main() -> T`의 반환값으로 받는다. `CLEvalResult.res`가 값 포인터, `res_t`가 타입 id이고
  `cl_value_desc`로 문자열화할 수 있다. 상위 문장만 있는 스크립트는 `res_t`가 void(1)다.
- 출력은 `cl_vm_set_printer` · `cl_vm_set_eprinter`로 가로챈다. `print`는 본문과 개행을 따로 두 번 호출한다.
- 에러는 반환 코드(`CL_ERROR_COMPILE` · `CL_ERROR_PANIC`)와 `cl_vm_error_summary`로 받는다. panic 요약에는 스택
  트레이스가 포함된다.

## 실행 제어

- 2026-11-01까지는 VM 루프에 호스트가 끼어드는 지점이 없었다(`CL_RET_INTERRUPT`는 호스트 함수가 panic을 일으킬 때
  쓰는 값이지 외부 중단이 아니다). 지금은 역방향 `JUMP`와 `CALL` 계열이 검사점이고, `cl_vm_interrupt` · `cl_vm_set_fuel`로
  멈추면 eval이 `CL_ERROR_INTERRUPT`를 돌려준다. 자세한 내용은 `project_vm_interrupt.md`.
- 에이전트 루프 권장 구성: 턴마다 `cl_vm_set_fuel`로 상한을 두고, 벽시계 제한은 타이머 스레드가 `cl_vm_interrupt`를
  부르게 한다. 호스트 함수(I/O)에서 오래 막힐 수 있으면 그 함수가 직접 시간 제한을 둔다.
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
- `persist_main` 지역 변수 이월(2026-11-01 구현). upstream은 `sema_program`에서 `return error.TODO`로 막혀 있었고,
  `trackMainLocal`은 선언 시점의 스택 절대 주소만 저장했다. 지금 구조:
  - `trackMainLocal`은 main 스레드 스택 시작 기준 레지스터 오프셋과 크기를 기록한다. 실행 중 스택이 커지면
    `growStackPrecise`가 스택을 새로 할당하므로 절대 주소는 쓸 수 없다.
  - `VM.eval`이 실행을 마치면 `copyMainLocalSaves`가 값을 VM 소유 버퍼로 복사한다. `persist_main`은 main 블록 해제
    코드를 만들지 않으므로 값의 소유권은 저장본으로 넘어온 상태다.
  - 다음 `sema_program`은 저장본마다 `Ptr[T]` 상수를 역참조해 지역을 선언한다(비트 단위 move, `@copy` 없음).
    복원된 지역이 다시 track되면 이전 버퍼는 해제만 한다. 컴파일 에러면 저장본이 그대로 남는다.
  - panic이면 unwind가 main 프레임을 해제하고 `freeHeapPages`가 힙을 비우므로 `dropMainLocalSaves`가 기록만 지운다.
  - 빌림 타입(`&T` · `[&]T` · 빌림 필드를 가진 struct) 지역은 이월하지 않는다(2026-11-04). 값을 새 슬롯으로 옮기므로 빌림은 옛
    슬롯을 가리키고, 스택이 커져 재할당되면 해제된 메모리를 읽는다. `localDecl`이 맨 위 선언을 컴파일 오류로 막는다
    (`docs/decisions/project_span_literal_local.md` REPL 절). 블록 안 지역은 이월되지 않으므로 그대로 쓸 수 있다.
    CLI REPL은 이때 "Variables were reset."을 출력한다.
  - 이월된 심볼은 decl 없는 use alias다. 새 main이 같은 이름을 선언하면 중복 보고(`declNode()` panic) 대신 대체되게
    했다(`src/module.zig`의 `isCarriedOverSym`). 이전에는 `use test`를 두 번 eval하면 프로세스가 죽었다.
  - 회귀 테스트는 lib "persist_main keeps main locals across evals."(누수 검사 allocator, 구조체 · 힙 문자열 ·
    스택 재할당 · 재선언 · 컴파일 에러 · panic).
- 첫 eval의 컴파일 실패(F-04, 2026-11-08 수정 `f5f2d241`). 실패한 첫 컴파일은 core 타입 · core 청크 · main 청크를 반쯤 만든
  채 `cont=false`로 남겼고, 다음 컴파일이 core를 다시 올리며 죽었다(구문 오류 뒤 SIGSEGV, 의미 오류 뒤 `@program_init has
  already been declared`). `cont`를 일찍 true로 바꾸는 것은 답이 아니었다: core 청크의 sema · 코드 생성은 `chunk_start`
  이후 범위에만 돌아 첫 실패 때 건너뛴 core가 처리되지 않는다(`No such field` panic). 지금은 `Compiler.first_compile_failed`를
  세우고 다음 `VM.eval`이 `resetVM()`으로 처음부터 시작한다. reset은 컴파일러 · 힙 · 심볼 테이블만 비우고 main 스레드의
  fuel · 스택 상한 · interrupt 플래그, VM의 printer · user data는 그대로 둔다. 호스트가 "빈 소스로 예열"하거나 실패 뒤
  `cl_vm_reset`을 부르던 우회는 필요 없다.
- 성공한 eval 뒤 실패한 eval의 선언은 다음 eval로 넘어가지 않는다(같은 커밋). 이전에는 `fn broken() -> int: return nope`가
  실패해도 `broken`이 `persist_main` alias로 넘어가 다음 eval의 `broken()` 호출이 SIGSEGV(바이트코드 없음)였다.
  `Compiler.last_compile_failed`면 이전 main 청크 자신의 심볼은 건너뛰고 그 청크가 물려받은 alias만 넘긴다. 실패한 eval 안의
  지역 변수는 원래 실행되지 않았으므로 저장본도 없다.

## 발견한 다른 문제

- CLI REPL(`cyber`를 인자 없이 실행)은 시작 직후 "CompileError: Import path does not exist: `main`"으로 끝난다.
  `src/main.zig`의 `repl()`이 부트스트랩 소스를 uri `main`으로 eval하는데 CLI resolver(`src/cli.zig`의 `zResolve`)가
  uri를 파일 경로로 보고 `realpath`를 하기 때문이다. upstream의 Zig 0.15 코드에도 같은 구조라 fork에서 생긴 문제는
  아니다. 2026-11-01 고침: `repl()`이 CLI 앱의 짧은 이름 표(`mod_uris`)에 `main` → `main`을 넣어 resolver가 그대로
  통과시킨다. 파일 실행 경로는 영향이 없다. 그 뒤 첫 입력에서 세그폴트가 났는데, 원인은 아래 "지역 변수 반환" 버그였다
  (`REPL.new()`가 `VM`을 담은 지역 `ctx`를 반환하면서 `vm_deinit`이 실행됨). 둘을 고친 뒤 REPL은 시작하고 표현식 ·
  함수 호출을 평가하고, 지역 변수 이월(위)까지 넣은 뒤에는 변수도 이어진다. `cy.cy`의 `TypeVoid`가 0으로 잘못 적혀
  있어(`TYPE_VOID`는 1) void 결과마다 빈 줄을 찍던 것도 고쳤다. 맨 이름(`x`)만 입력하는 것은 언어 규칙상 컴파일 에러라
  REPL이 값을 바로 보여 주지 않았는데, 2026-11-04에 `persist_main` 모드의 마지막 맨 표현식을 eval 결과로 돌려주게 했다
  (`docs/decisions/project_repl_result.md`). `cl_vm_evalx` 호출자도 `CLEvalResult.res` · `res_t`로 받는다.
- REPL 입력 끝(EOF) 처리(2026-11-01 고침). Ctrl-D나 파이프로 넣은 stdin이 끝나면 linenoise가 `null`을 돌려주고
  `replReadLine`(`src/cli.zig`)이 `error.EndOfStream`을 올려 `panic: EndOfStream`으로 끝났다. 이제 EOF는 `.exit`과 같게
  처리해 종료 코드 0으로 끝난다(`repl_end_of_input`). REPL 스크립트(`cy.cy`의 `ReadLineFn`)의 타입은 바꾸지 않았다.
  Windows용 `FallbackReadLine`은 stdin을 끝까지 통째로 읽고 EOF 뒤에는 빈 문자열을 계속 돌려줘 무한 루프가 될 수
  있었다. 이제 한 바이트씩 한 줄만 읽고(`\r\n` 처리), 읽은 것 없이 EOF면 `error.EndOfStream`을 낸다. 이 경로는
  `use_ln`이 comptime이라 macOS 빌드에서 분석되지 않으므로 `-Dtarget=x86_64-windows-gnu` 교차 빌드로 컴파일만 확인했다.
- 지역 변수 반환이 복사였다(2026-11-01 고침). `return r`이 `semaOwn`으로 복사본을 만들었고, `@copy`가 없는 타입은
  비트 단위 복사라 반환 시 지역의 `@deinit`과 호출자 쪽 `@deinit`이 같은 상태에 두 번 돌았다(자원 이중 해제).
  명시적 `move`는 "같은 블록에서 선언한 변수만" 허용해 분기 안의 `return move r`도 막혀 있었다.
  `semaReturnExprStmt`(`src/sema.zig`)가 이제 이 함수가 소유한 관리 타입 지역(참조 매개변수 · 부분 move된 지역 ·
  main 블록 제외)을 반환하면 move한다. 반환용 소멸 코드를 만드는 동안만 지역을 dead로 두고 되돌리므로, return 뒤는
  도달 불가이고 다른 분기에는 영향이 없다. 반환식이 이름 하나일 때는 반환 타입 맞춤(`r` → `?R` · `!R`)을 move 판단 뒤로 미뤄 감싸는 경우도 move한다. 다른 식은
  `fit_target`이 하위 식 검사에도 쓰여 기존 경로를 유지한다. `trace_test`의 "ARC in loops" 기대값은 move로 retain/release가
  두 쌍 줄어 11에서 9로 바꿨다. 이 변경을 처음 넣었을 때 드러난 ReleaseFast 메모리 손상은 move가 아니라 `setOpArgU48`의
  8바이트 쓰기 때문이었다(`project_zig_017_upgrade.md`).
  회귀 테스트 `memory/return_local_move.cy`(수정을 되돌리면 실패 확인).
