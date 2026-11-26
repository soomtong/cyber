# 0.4.22 이후 변경 (미릴리스)

0.4.22(2026-11-26) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## `os.cmd` 예제 셋 (2026-11-26)

- `examples/build_log.cy`: `stderr_to_stdout`로 stdout · stderr를 쓴 순서대로 받는다(줄 단위 읽기, 로그 파일, 파이프).
- `examples/background_job.cy`: `detach`로 `python3 -m http.server`를 띄우고 `curl`로 확인한 뒤 pid로 멈춘다.
- `examples/parallel_jobs.cy`: `start`로 명령 셋을 동시에 돌리고 `Array[os.Process]`에 담아 종료 코드를 모은다.
- 셋 다 `behavior_test`의 "Compile."에서 컴파일만 확인한다(POSIX 프로그램이 필요해 실행하지 않는다).

## C API: 할당 실패에 프로세스를 끝내지 않는다 (2026-11-26)

- `cl_vm_init` · `cl_vm_initx` · `cl_vm_init_mem`은 할당이 실패하면 `NULL`을 돌려준다. 그때까지 받은 블록은 모두 돌려준다. 전에는
  프로세스를 끝냈다(`fatal`). 호스트는 `NULL`을 확인한다(깨지는 변경: 확인하지 않던 호스트는 abort 대신 `NULL` 역참조가 된다).
- 호스트 함수가 값을 만드는 함수(`cl_str_init` · `cl_astr_init` · `cl_ustr_init` · `cl_slice_init` · `cl_new_func_union` · `cl_lift` ·
  `cl_array_empty` · `cl_map_empty`)는 할당하지 못하면 빈 문자열 · 빈 slice · 값 0을 돌려주고, 그 호스트 함수는 돌아오는 즉시
  'panic: OutOfMemory'로 끝난다(호스트가 `cl_thread_ret_panic`으로 낸 panic은 그대로). 실패한 값은 쓰거나 다른 값에 담지 않는다.
- `cl_vm_alloc`은 `NULL`, `cl_vm_allocb` · `cl_object_string` · `cl_value_desc` · `cl_vm_resolve`는 null 문자열,
  `cl_vm_ensure_func_sig`는 `NULL`, `cl_symbol` · `cl_error`는 -1을 돌려준다. `cl_vm_resolve`는 해석하지 못한 uri에도 프로세스를
  끝냈다.
- `cy.eval`의 새 VM을 만들지 못하면 스크립트의 `OutOfMemory` panic이다.
- 결정은 `docs/decisions/project_capi_alloc_failure.md`. 남은 `fatal`: `cl_vm_reset`, `clReportApiError`, 런타임 안쪽.

## 임베딩: C FFI 차단 `deny_ffi` (2026-11-26)

- `CLEvalConfig` · `CLCompileConfig` 끝에 `bool deny_ffi`가 늘었다(기본 false). 두 구조체의 레이아웃이 바뀌었으므로 호스트는
  `cyber.h`로 다시 컴파일해야 한다.
- 모듈 허용 표로는 C를 막지 못했다. `math`가 `use c`를 하므로 `use math`만 허용한 스크립트도 `#[extern] fn getpid() -> i32`를
  선언해 호스트 프로세스의 아무 심볼이나 불렀고, `#[extern] fn() -> i32` 타입의 `none`을 부르면 호스트가 SIGSEGV였다.
- `deny_ffi`를 켜면 builtin 모듈이 아닌 chunk에서 `#[extern]` 함수 · 전역 · 함수 타입이
  '`#[extern]` is not allowed. The host disabled C FFI for this script (`deny_ffi`).', `use c`(어떤 별칭이든)가
  'The module `c` is not allowed. The host disabled C FFI for this script (`deny_ffi`).' 컴파일 오류다. `cy.VM` 생성
  (`cy.eval`)은 '`cy.VM` is not allowed. The host disabled C FFI for this script (`deny_ffi`).' panic이다. 새 VM은 기본 로더와
  기본 설정을 갖기 때문이다. builtin 모듈의 extern 함수(`math.acos`)는 그대로 돈다. CLI는 켜지 않는다.
- `cl_vm_compile`이 `deny_raw_ptrs` · `deny_spawn` · `deny_ffi`를 VM에 남긴다. 전에는 그 뒤의 `cl_vm_validate`와 런타임
  `spawn` 검사가 옵션을 보지 못했다.
- 결정 `docs/decisions/project_deny_ffi.md`, 매뉴얼 `docs/docs.md` "Denying C FFI.".
