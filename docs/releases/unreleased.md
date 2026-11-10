# 0.4.4 이후 변경 (미릴리스)

0.4.4(2026-11-09) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

- 스크립트가 호스트 프로세스를 끝낼 수 있던 경로 둘을 막았다(F-52). 실패한 적 없는 `cy.VM`에 `compile_error_summary()`를 부르면
  `panic: No report.`, `panic_summary()`를 부르면 `panic: Unexpected panic type.`으로 프로세스가 abort했다(종료 코드 134).
  이제 빈 문자열을 돌려준다.
- 한 타입 안에서 이름이 겹치는 필드나 case가 컴파일러를 죽이던 것을 고쳤다(F-81). `type P: x int, x int`, 같은 case를 두 번 적은
  enum · choice · cunion은 `panic: Unsupported: .field`(`.enum_case` · `.choice_case` · `.union_case`)로 프로세스가 abort했다
  (종료 코드 134). 이제 두 번째 선언 위치의 컴파일 오류다: ``CompileError: `x` has already been declared as a `field`.``
- 타입 선언이 중간에 컴파일 오류로 끝날 때 컴파일러가 메모리를 놓치던 곳 셋을 고쳤다. trait의 메서드 하나가 해석에 실패할 때
  (없는 반환 타입 등) 그 앞 메서드들, enum · choice · cunion의 case 하나가 실패할 때(없는 payload 타입, 중복 이름) case 목록.
  누수는 실패한 eval마다 쌓였고 `cl_vm_deinit`도 돌려주지 않았다.

## 언어와 표준 라이브러리

- (F-82) `i8` · `i16` · `i32`와 `byte` · `r16` · `r32`의 나눗셈 · 나머지 · `>>`가 VM 백엔드에서 틀린 값을 내던 것을 고쳤다. VM 레지스터는 64비트이고
  좁은 정수의 상위 비트는 정해져 있지 않은데(변환과 넘친 덧셈이 그대로 둔다) 세 연산이 그 비트까지 읽었다.
  `i8(-8) / i8(2)`는 `124`, `i32(-8) / i32(2)`는 `0`, `i32(-7) % i32(4)`는 `-7`, `(byte(200) + byte(100)) / byte(2)`는 `0x96`이었다.
  이제 `-4` · `-4` · `-3` · `0x16`이다. `udiv` · `umod`도 같이 고쳐졌다. 비교 연산처럼 연산 앞에서 피연산자를 자기 폭으로 확장한다.
  같은 원인의 `float()` 변환(F-84)과 `**` 컴파일 오류(F-85)는 아래 항목에서 고쳤다.

- (F-84) `i8` · `i16` · `i32`와 `byte` · `r16` · `r32`를 `float` · `f32`로 바꿀 때 넘친 값의 상위 비트가 읽히던 것을 고쳤다.
  `float(i8(100) + i8(100))`은 `200`, `float(byte(200) + byte(100))`은 `300`이었다. 이제 `-56` · `44`다(`int()` 변환과 같은 값).
  부호 있는 정수는 자기 부호 비트에서, `byte` · `r16` · `r32`는 0으로 확장한 뒤 변환한다.

- (F-85) `i8` · `i16` · `i32`의 거듭제곱 `**`이 컴파일된다. 이전에는 `i8(2) ** i8(3)`이 `core.cy`의 `return result`에서
  ``CompileError: Expected type `i8`, got `int`.``였다. 결과는 피연산자 타입이고 넘치면 그 폭에서 wrap한다(`i8(2) ** i8(8)`은 `0`).

- (F-86) 목표 타입이 `float`인 자리의 `~`가 컴파일된다. `float(~x)`, `var f float = ~x`, `float` 매개변수에 넘긴 `~3`, `var o ?int = ~x`가
  ``CompileError: Can not find the symbol `~` in `float`.``(또는 `` in `?int` ``)였다. 목표 타입이 피연산자에 먼저 적용돼 `x`가 `float`로
  바뀐 뒤 `~`를 찾았기 때문이다. 이제 목표가 정수(`Int` · `Raw`)일 때만 피연산자에 전달한다. 정수 목표의 동작은 그대로다:
  `var z r32 = ~r16(5)`는 피연산자를 먼저 넓혀 `0xfffffffa`이고(C의 정수 승격과 같다), `n := ~r16(5)` 뒤 `r32(n)`은 `0xfffa`다.

- (F-83) `Int.asr()`(부호를 유지하는 오른쪽 시프트)가 VM 백엔드에서 동작한다. 이전에는 호출하면 `bc_gen: .asr` 뒤 `CompileError: error.TODO`로
  컴파일이 실패했다. `(-8).asr(1)`은 `-4`다(`-8 >> 1`은 0을 채우는 logical shift라 큰 양수). `i8` · `i16` · `i32`는 자기 폭의 부호 비트에서
  시프트하고, 시프트 양이 부호 비트를 넘으면 부호만 남는다(음수는 `-1`, 아니면 `0`). VM에 `ASR` opcode를 더했다. C 백엔드(`cgen`)에는 아직 없다.

## 임베딩 API

- 메모리 한도: `cl_vm_set_memory_limit(vm, bytes)`와 `cl_vm_memory_used(vm)`(F-41). 한도는 VM이 할당자로 쥔 전체 바이트
  (컴파일러 · 로드된 모듈 · 힙 · 스택, 첫 eval 뒤 약 2 MiB) 기준이고 0 이하는 무제한(기본값)이다. 스크립트에 N 바이트를 주려면
  `cl_vm_memory_used(vm) + N`으로 정한다. 스크립트가 힙이나 스택을 한도 너머로 키우면 `panic: OutOfMemory`이고 eval은
  `CL_ERROR_PANIC`을 돌려준다. panic은 힙 페이지와 커진 스택을 반환하므로 같은 한도로 VM을 계속 쓸 수 있다. `spawn`한 스레드도
  같은 한도를 쓴다(`panic: Spawned thread panicked: OutOfMemory`). 컴파일 단계와 호스트 함수의 할당은 세기만 하고 막지 않는다
  (`docs/decisions/project_memory_limit.md`).
- C 호스트용 메모리 함수: `cl_vm_init_mem(CLMemFuncs)`가 `ctx` · `alloc(ctx, size, align)` · `free(ctx, ptr, size, align)`로 VM을
  만든다(F-41). `CLVM` 객체를 포함해 VM의 모든 메모리가 이 두 함수를 거치고 `cl_vm_deinit`이 전부 돌려준다. `align`은 2의 거듭제곱이며
  `malloc`의 보장보다 클 수 있고, 두 함수는 스레드에 안전해야 한다(`spawn`). 제자리 성장 함수는 없다. 스크립트의 메모리 상한은 `NULL`을
  돌려주는 `alloc`이 아니라 `cl_vm_set_memory_limit`으로 건다. `examples/libcyber/host_tool.c`가 이 방식으로 바뀌었다
  (`docs/decisions/project_c_mem_funcs.md`).
- 호스트 할당자가 eval 중에 실패해도(`cl_vm_init_mem`의 `alloc`이 `NULL`, `cl_vm_initx`에 준 할당자의 실패) eval은 오류를 돌려주고
  VM은 계속 쓸 수 있다(F-41). 이전에는 실패한 지점에 따라 프로세스 abort · SEGV · 누수였다(`docs/decisions/project_compile_alloc_failure.md`).
  - 컴파일러에서 실패: `CL_ERROR_COMPILE`. 요약은 `CompileError: OutOfMemory` 계열(텍스트 writer 뒤의 실패는 `WriteFailed`)이거나,
    리포트를 만들 메모리도 없으면 비어 있다.
    다음 eval · validate는 `cl_vm_reset`처럼 VM을 reset한 뒤 시작한다. `persist_main` 세션이 쥐고 있던 지역 변수와 선언은 사라진다.
    호스트 설정(연료, 스택 · 메모리 한도, 프린터, user data)은 남는다.
  - 스크립트 실행 중 실패: `CL_ERROR_PANIC`, `panic: OutOfMemory`. 다른 panic의 메시지를 할당하지 못하면 메시지가 `OutOfMemory`로
    바뀌고, 스택 트레이스를 기록하지 못하면 트레이스가 비어 있다. 어느 경우에도 스레드의 힙은 해제된다.
  - 실행 뒤 정리(결과 값 복사, `persist_main`의 지역 변수 이월)에서 실패: `CL_ERROR_UNKNOWN`, 요약 없음.
  - `cl_vm_error_summary` · `cl_vm_compile_error_summary` · `cl_thread_panic_summary`는 문자열을 할당하지 못하면 null `CLBytes`를
    돌려준다. `cl_vm_freeb`에 그대로 넘겨도 된다.
  - `cl_mod_add_func` · `cl_mod_add_type` · `cl_mod_add_global`과 타입 생성 콜백(`CLCreateTypeFn`의 `NULL` 반환)의 실패는 그 모듈을
    로드하던 컴파일의 실패가 된다. `clExpandTypeTemplate` · `cl_find_type`은 `NULL`을 돌려준다.
  - 그대로인 것: VM을 만드는 중(`cl_vm_init` · `cl_vm_initx` · `cl_vm_init_mem`)과 호스트가 값을 만드는 함수(`cl_str_init`,
    `cl_array_empty`, `cl_map_empty`, `cl_vm_alloc` 등)의 할당 실패는 여전히 프로세스를 abort한다. 스크립트의 메모리 상한은
    실패하는 할당자가 아니라 `cl_vm_set_memory_limit`으로 건다.
- `cl_vm_allocator`가 돌려주는 할당자는 호스트가 `cl_vm_initx`에 준 것이 아니라 그 위의 계수 래퍼다. 거기서 받은 메모리는 같은
  할당자로 돌려줘야 하고, `cl_vm_deinit` 뒤에는 쓸 수 없다.
- panic으로 끝난 eval은 힙 페이지(첫 페이지 제외)와 main 스레드의 커진 스택을 할당자에 돌려준다. 이전에는 VM이 끝날 때까지 쥐고 있었다.
- 객체 · 클로저 · 함수 union 할당이 실패하면 `CL_ERROR_UNKNOWN` 대신 `panic: OutOfMemory`(`CL_ERROR_PANIC`)다.
- `print` · `eprint` 콜백(`CLPrintFn` · `CLPrintErrorFn`)의 첫 인자가 선언대로 실행 중인 스레드(`CLThread*`)다. 이전에는 VM 포인터를
  넘겨 콜백 안의 `cl_thread_vm(t)` 같은 호출이 쓰레기를 읽었다. 콜백에서 VM이 필요하면 `cl_thread_vm(t)`를 쓴다(F-50,
  `docs/decisions/project_capi_header_sync.md`).
- `cyber.h`를 실제 export에 맞췄다(F-51). 구현이 없던 `clResolveType` · `cl_array_empty_new` · `cl_map_empty_new` 선언을 지우고
  `cl_array_empty(CLThread*, CLType*)` · `cl_map_empty(CLThread*, CLType*)`를 선언했다. `cl_type_from_id`는 `(CLVM* vm, CLTypeId id)`다.
  정의되지 않은 타입을 참조하던 `CL_CUSTOM_TYPE` · `CL_CUSTOM_PRE_TYPE` · `CL_CREATE_TYPE` 매크로는 `cl_mod_add_type`에 넘길
  `CLBindType`을 만드는 `CL_BIND_DECL_TYPE(id)` · `CL_BIND_CREATE_TYPE(fn)` · `CL_BIND_ALIAS_TYPE(fn)`으로 바꿨다. 주석의 옛 이름
  (`cl_free` → `cl_vm_freeb` 등)을 고쳤다. 헤더에 없던 export `clAlloc` · `clGetAllocator`는 지웠다(`cl_vm_alloc` · `cl_vm_allocator` 사용).
  lib 테스트가 헤더의 모든 `cl*` 함수 선언이 export되는지 링크로 검사한다.
- 컴파일 오류 요약(`cl_vm_error_summary` · `cl_vm_compile_error_summary`)에 터미널 이스케이프 코드가 없다(F-52). 이전에는 표시 줄이
  호스트가 무엇이든 `\x1b[31m^~~~\x1b[0m`이었다. 색이 필요한 호스트는 `cl_vm_set_error_color(vm, true)`로 켠다. 설정은 `cl_vm_reset`을
  넘어 유지되고, 스크립트가 만든 `cy.VM`은 부모 VM의 설정을 물려받는다.
- `cl_vm_compile_error(vm, &err)`가 마지막 eval · compile · validate의 컴파일 오류를 `CLCompileError`로 준다(F-52). `kind`
  (`CL_REPORT_TOKEN_ERROR` · `CL_REPORT_PARSE_ERROR` · `CL_REPORT_COMPILE_ERROR`), `msg`(위치 없는 메시지), `uri`, `has_loc`, `line` ·
  `col`(0부터, `col`은 바이트), `len`(그 줄에서 표시되는 바이트 수, 토큰 · 파싱 오류는 1). 마지막 결과가 `CL_ERROR_COMPILE`이 아니면
  false를 돌려주고 `err`를 0으로 채운다. `msg` · `uri`는 VM 소유이고 다음 eval · compile · validate · reset 전까지 유효하다. 컴파일러는
  첫 오류에서 멈추므로 오류는 컴파일당 하나다. 문맥(이전 선언 · 템플릿 호출 지점)은 요약 문자열에만 있다
  (`docs/decisions/project_compile_error_report.md`).
- `cl_vm_compile_error_summary`는 기록된 컴파일 오류가 없으면, `cl_thread_panic_summary`는 스레드의 마지막 실행이 panic하지 않았으면
  빈 `CLBytes`를 돌려준다. 이전에는 호스트 프로세스를 abort했다. 빈 결과는 `cl_vm_freeb`에 그대로 넘겨도 된다.
- `cl_vm_eval`의 헤더 주석을 실제 동작으로 고쳤다. `res`는 `fn main() -> T`의 반환값이거나 `persist_main`에서 마지막 맨 표현식의
  값이고, 값이 없으면 `res_t`가 `CL_TYPE_VOID`다. 성공이 아니면 `res`는 채워지지 않는다. 이전 주석은 설정과 무관하게 마지막 표현식의
  값을 준다고 적었다.

## 변경

- `cyber`가 찍는 컴파일 오류의 표시 줄(`^~~~`)은 stderr가 ANSI 터미널일 때만 빨강이다(F-52). 파이프나 파일로 넘기면
  (`cyber bad.cy 2> err.txt`) 이스케이프 코드가 들어가지 않는다. `NO_COLOR`(비어 있지 않으면 끔)와 `CLICOLOR_FORCE`(비어 있지 않으면
  터미널이 아니어도 켬)를 따르고 둘 다 있으면 `NO_COLOR`가 이긴다. REPL도 같다.
- `cyber compile` 덤프의 `addr` 명령 표기를 `%dst = *%src`에서 `%dst = &%src`로 바꿨다. 이 명령은 레지스터 `src`의 스택 주소를 `dst`에
  넣는 것이라 옛 표기가 역참조로 읽혔다(`docs/decisions/project_ex_borrow_field_addr.md`).
- 빌드 버전 문자열(`cyber version`의 `build-N-xxxxxxx`)을 `zig build -Dbuild=N -Dcommit=xxxxxxx` 옵션으로 넘긴다. `BUILD` · `COMMIT` 환경
  변수는 폴백으로 남지만 Zig 0.17.1의 configure 캐시가 환경 변수를 추적하지 않아 같은 인자의 이전 빌드 결과가 남을 수 있다
  (`docs/decisions/project_fork_release_ci.md`).
- 빌드 · CI의 Zig를 0.17.0에서 0.17.1로 올렸다(`build.zig.zon` `minimum_zig_version`, 워크플로 `ZIG_VERSION`, `Taskfile.yml`, `docs/build.md`).

## 문서
