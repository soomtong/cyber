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

## `time` · `regex` · `peg`: 순서 연산자, 함수로 치환, 대소문자 무시 리터럴 (2026-11-26)

- `time.DateTime`에 `<` · `<=` · `>` · `>=`와 `DateTime - DateTime -> Duration`. 순간만 비교한다(오프셋 · zone은 보지 않는다).
  `==`는 그대로 모든 칸을 비교하므로, 같은 순간의 `+09:00` 값과 `Z` 값은 `a <= b and a >= b`이면서 `a != b`다. 순간의 같음은
  `a.time() == b.time()`. 결정 `docs/decisions/project_std_time.md` "셋째 단계".
- `DateTime.format` · `Date.format` · `Time.format`에 `%U`(일요일 시작 주)와 `%W`(월요일 시작 주), 00~53, C `strftime`과 같은
  값.
- `parse_format`이 주 날짜를 읽는다(같은 날 이어서): `%U` · `%W`는 `%Y`(`%y`)와, `%V`는 `%G`와, 그리고 요일(`%a` · `%A` · `%u` ·
  `%w`)과 함께 날짜를 정한다. 전에는 `%u` · `%w` · `%G` · `%V` · `%U` · `%W`가 출력 전용 오류였다. 요일이 빠지면
  'A week of the year needs a day of the week: add `%a`, `%A`, `%u` or `%w`.', 그 주에 없는 날은 `error.Range`
  ('Week 0 of 2026 has no Wednesday.'), `%m` · `%d` · `%j`와 함께 쓰면 `error.Format`.
- 동작이 바뀜: 연도와 월 · 일(또는 `%j`)이 다 있는 형식의 요일은 이제 그 날짜의 요일이어야 한다. 전에는 읽고 버렸다.
  `Fri 2026-11-26`을 `%a %F`로 읽으면 `error.Range`, '2026-11-26 is a Thursday, not a Friday.' 연도가 없으면 그대로 버린다.
- `regex.Regex.replace` · `replace_all`이 함수를 받는다: `repl &OpaqueFunc[fn(&Captures) -> str]`(함수 포인터 · 클로저).
  일치마다 왼쪽부터 한 번 불리고, 돌려준 문자열은 `$`를 확장하지 않고 그대로 들어간다. 결정 `project_std_regex.md` "함수로 치환".
- `peg.Peg.replace` · `replace_all`도 같은 꼴로 함수를 받는다(`fn(&Capture) -> str`, 매치 전체의 캡처).
- `peg`: 닫는 따옴표 바로 뒤의 `i`로 대소문자를 무시하는 리터럴(`'select'i`, `"select"i`). `regex`의 `(?i)`와 같은 Unicode
  simple case folding이라 `'k'i`는 Kelvin 기호에도 맞는다. 깨지는 변경: 전에는 `'x'i`가 리터럴 뒤 규칙 `i`의 호출이었다.
  규칙을 부르려면 `'x' i`처럼 띄운다(`'x'id`처럼 이름이 이어지면 지금도 규칙). 결정 `project_std_peg.md` "대소문자 무시 리터럴과
  함수로 치환".

## 빌림 검사의 자리 대상 지역 (2026-11-26)

- 다른 컨테이너 안의 자리를 빌린 값을 담은 지역(`g := H{b=&w.x}`)이 살아 있는 동안 같은 블록의 다른 컨테이너도 마지막 사용 뒤에
  끝나지 않았다. `h := H{b=&a[0]}`를 다 쓴 뒤의 `a << 3`이 'Expected exclusive access. There is another active borrow to `a`.'였다.
  이제 자리를 담은 지역은 실제로 가리킬 수 있는 지역(`w`)만 붙잡는다.
- `hr := &h`로 꺼낸 복사(`r := hr.b`, `r = hr.b`)를 `scope` 함수가 돌려주면(`return r`) `h`가 자리를 담지 않아도 'Expected to
  return a borrow from the same scope as `p`.'였다. 이제 받는다. `h`가 자리를 담으면(`h := H{b=&w.x}`) 그대로 오류다.
- 그대로인 것: `&&h`를 넘긴 컨테이너(`&&self` 메서드 호출 포함)는 아무 지역이나 가리킬 수 있다고 본다.
- 확인: `memory/borrow_last_use_place.cy`와 `borrow_{last_use_place,last_use_place_copy,last_use_place_through,return_via_place,
  via_place_bind}_error.cy`. 결정 `project_borrow_model.md` "자리 대상 지역 목록".
