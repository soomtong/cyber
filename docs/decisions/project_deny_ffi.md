# 신뢰하지 않는 스크립트의 C FFI 차단 `deny_ffi` (2026-11-26)

## 배경

HANDOFF "알려진 한계"에 "신뢰하지 않는 스크립트의 C FFI 차단은 미결정"이 남아 있었다. 기존 장치는 모듈 허용 표(호스트
resolver, `project_embedding_module_allowlist.md`), `deny_raw_ptrs`(`project_deny_raw_ptrs.md`), `deny_spawn`이다. 스크립트가
C에 닿는 길을 라이브러리 빌드(기본 로더)와 허용 표 로더로 나눠 확인했다(Debug CLI · lib-test, 0.4.22 뒤).

- `#[extern]` 함수: 스크립트 chunk에 `#[extern] fn getpid() -> i32`를 쓰면 `@initBindLib`이 호스트 실행 파일(`dlopen(NULL)`)에서
  이름으로 찾아 묶는다. `use c`가 없어도 `c` chunk만 올라와 있으면 된다(`sema_resolve.ensure_resolved_func`는
  `chunk_map.get("c")`만 본다). `math`가 `use c`를 하므로 `core`, `math`만 허용하는 표에서도 `use math` 뒤 `getpid()`가
  돌았다. 정수만 받는 `exit` · `kill` · `fork`로 호스트를 끝낼 수 있고, 포인터 인자는 `deny_raw_ptrs`가 막아도 `int`로 선언하면
  주소를 넘긴다. 허용 표로는 막을 수 없다.
- `#[extern]` 전역(`#[extern] global errno i32`)도 같은 길이다.
- extern 함수 타입: `fn g(f #[extern] fn() -> i32)`에 `none`을 넘겨 부르면 널 주소 호출로 호스트가 SIGSEGV다. 정수에서
  캐스트는 이미 오류('Cannot cast `int` to ...')다.
- `use c`: `#c.bind_lib(path)`는 그 chunk의 extern 함수를 위해 임의 라이브러리를 `dlopen`한다(생성자 실행). `#c.include` ·
  `#c.flag`는 `Compiler.c_includes` · `c_flags`에 쌓여 그 compile의 모든 extern 함수, 곧 `math`의 것까지 묶는 TCC 소스에
  들어간다(`#define acos ...` 같은 주입). 허용 표가 `c`를 막으면 닿지 않는다.
- `os` FFI: `os_ffi.zig`(`bindLib`)는 `os.zig`에서 주석 처리되어 있어 닿지 않는다. `os` · `libc` 모듈은 CLI 로더에만 있고
  라이브러리 기본 로더에는 없다. `math`의 extern 함수(`c_acos` 등)는 비공개라 스크립트가 부를 수 없다.
- `meta`: 모듈의 심볼을 이름으로 꺼내거나 extern을 만드는 함수가 없다(`type(s)`는 타입만, `new_struct`는 구조체만).
  컴파일 타임 평가는 extern 함수를 부르지 않는다.
- `cy.eval` · `cy.VM()`: 새 VM은 기본 로더와 기본 설정을 갖는다. 그 안에서는 `use c`도 `#[extern]`도, 호스트가 막은 모듈도
  된다. Debug CLI에서 `cy.eval('use c\n#[extern]\nfn getpid() -> i32\nprint(getpid())')`가 안쪽 VM에서 `getpid`를 불렀다
  (값을 내는 식 `cy.eval('1 + 1')`은 'Expected assignment to a variable or placeholder' 컴파일 오류다). 허용 표에서 `cy`를
  빼면 닿지 않는다.

정리하면 허용 표 + `deny_raw_ptrs`로 남는 구멍은 `#[extern]` 선언(함수 · 전역 · 함수 타입)이다. `c` · `cy`는 허용 표로 막히지만
허용 표 없이 기본 로더를 쓰는 호스트나 `c`를 허용한 호스트에는 열려 있다.

## 결정

컴파일 옵션 `deny_ffi`(`CLEvalConfig` · `CLCompileConfig`, 기본 false)를 둔다. `deny_raw_ptrs` · `deny_spawn`과 같은 꼴이다.
켜지면 builtin 모듈(bind 함수가 `markBuiltinModule`로 표시한 `core` · `meta` · `math` · `cy` · `c` · `io` · `test` · `time` ·
`json` · `peg` · `regex` · `toon` · `path`)이 아닌 chunk에서 다음이 컴파일 오류다.

- `#[extern]` 함수 선언(제네릭 포함), `#[extern]` 전역, `#[extern] fn(...)` 함수 타입:
  '`#[extern]` is not allowed. The host disabled C FFI for this script (`deny_ffi`).' 오류 위치는 속성이다. 함수는
  `ensure_resolved_func`의 속성 검사(`#[unsafe]` 등 builtin 전용 속성과 같은 자리), 전역은 `reserveGlobal`, 함수 타입은
  `sema_type.resolveFuncType`에서 막는다. 선언을 막으므로 extern 함수가 builtin 모듈 밖에서 생기지 않는다. 호출 쪽은 따로
  보지 않는다(builtin 모듈의 extern 함수는 비공개이거나 신뢰하는 바인딩이다).
- `use c`(별칭 `use cc 'c'`도, 해석된 URI가 `c`인 것): 'The module `c` is not allowed. The host disabled C FFI for this script
  (`deny_ffi`).' `bind_lib` · `include` · `flag`를 하나씩 막는 것보다 단순하고, 나머지(`to_strz` · `from_strz` · `memcpy`)는
  raw 포인터 도구라 FFI를 막는 스크립트에 쓸 데가 없다.
- `cy.VM` 생성(`VM.@init`, `cy.eval`도 이것을 부른다)은 런타임 panic:
  '`cy.VM` is not allowed. The host disabled C FFI for this script (`deny_ffi`).' `cy.eval`은 `cy` chunk(builtin) 안에서
  `VM()`을 부르므로 컴파일 검사로는 잡을 수 없다. 새 VM에 호스트 설정을 물려주는 안은 버렸다. 로더 · resolver · 호스트 함수는
  물려줄 수 없어 허용 표 밖 모듈이 그대로 열린다. `cy`의 파서 도구(`cy.parse`)는 그대로 쓴다.
- `VM.compile`(`cl_vm_compile`)이 `deny_raw_ptrs` · `deny_spawn` · `deny_ffi`를 VM의 eval 설정에도 옮긴다. 전에는 기본값으로
  덮어서 그 뒤 `cl_vm_validate`와 런타임 `spawn` 검사가 옵션을 보지 못했다.
- CLI 옵션은 두지 않는다(CLI는 의도적으로 열려 있다). 모듈 허용 표는 그대로 필요하다. `deny_ffi`는 `os`처럼 호스트 로더가
  주는 모듈 자체의 능력(파일 · 프로세스)을 막지 않는다. CLI 로더의 `os` · `libc`는 builtin으로 표시되지 않으므로 호스트가 그것을
  주면 `libc`의 extern 선언이 거부될 것이다(확인하지 않음, 라이브러리 기본 로더에는 두 모듈이 없다).

두 구조체 끝에 `bool deny_ffi`가 늘어 레이아웃이 바뀌었다. 호스트는 `cyber.h`로 다시 컴파일해야 한다. Zig 쪽은 `@cImport`한
구조체를 그대로 쓰므로 따로 맞출 미러 구조체가 없다.

## 검증

lib-test `deny_ffi rejects C FFI in script chunks.`(`src/lib_test/compile.zig`): `persist_main` 세션에서 `use math` 뒤
`#[extern] fn getpid`, 제네릭 extern 함수, extern 전역, extern 함수 타입 매개변수(`g(none)`), `type F = #[extern] fn() -> i32`,
`use c` + `#c.bind_lib`, `use cc 'c'`가 모두 컴파일 오류이고 `cl_vm_validate`도 오류, 거부 뒤 `use math`의 `math.acos(1.0)`
(builtin extern 함수)와 앞 eval의 지역 `a`가 그대로, `cy.eval('1 + 1')`이 문구를 담은 `CL_ERROR_PANIC`. `cl_vm_compile`은
기본 설정에서 같은 `getpid` 스크립트를 통과시키고 `deny_ffi`로 거부한다. 기본 설정의 `cl_vm_eval`은 `getpid`를 부른다.

## 남은 것

- 호스트가 자체 로더로 주는 Cyber 소스 모듈은 builtin이 아니라 `#[extern]`을 쓸 수 없다. 필요하면 로더 결과에 신뢰 플래그를
  더한다(`deny_raw_ptrs`의 같은 한계).
- 옵션은 eval마다 받는다. 앞 eval이 `deny_ffi` 없이 `use c`나 extern 함수를 세션에 남겼다면 뒤 eval이 그것을 쓸 수 있다.
  호스트는 세션의 모든 eval에 같은 설정을 준다.
- tars-agent 쪽 반영(`cfg.deny_ffi = true`)은 이 작업에서 하지 않았다.
