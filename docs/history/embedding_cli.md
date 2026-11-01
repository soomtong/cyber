# 임베딩과 CLI: `cs*` 동적 값 API에서 `cl_*` 정적 스택 ABI와 `#[bind]`로

2026-11-01 작성. 개요는 `cyber_0_3_to_0_4_overview.md`. fork의 임베딩 검토는 `docs/decisions/project_embedding_agent_loop.md`,
릴리스는 `docs/decisions/project_fork_release_ci.md`.

## 0.3 상태 (2023-12)

- C API 접두사는 `Cs` · `CS` · `cs`. `csCreate()` · `csEval(vm, src, &val)` · `csRelease`. 값은 `CsValue` 하나의 동적 표현이고
  호스트 함수 시그니처는 `CsValue f(CsVM*, const CsValue* args, uint8_t nargs)`였다.
- 모듈 로더 `csSetModuleLoader`가 소스를 돌려주고, 함수 · 변수 · 타입 로더 콜백 세 개를 따로 등록했다. 스크립트 쪽은 `@host`
  주석(`@host func add(a float, b float) float`, `@host var Root.X`). 호스트 타입은 `getChildren` · `finalizer`로 ARC에 참여.
- C API 함수 수는 76개(`src/include/cyber.h`의 `cs*(` 패턴).
- CLI는 스크립트 실행과 JIT · AOT(문서 "JIT" · "AOT" 절). CLI REPL은 없었다(2024-04-12에 구현).
- 0.3 릴리스 노트 항목: JIT compiler, Cycle detector, Embed API, cbindgen, Type system, Operator · Function overloading,
  Compiler rewrite, WASI target, Doc gen.

## 구간 A에서 바뀐 것 (2024-01 ~ 2024-09)

| 날짜 | 커밋 | 변화 |
|---|---|---|
| 2024-01-19 | `0a57ae4f` | C 백엔드 착수 |
| 2024-03-08 | `5bb32eca` `c437dfdf` `38819d84` | AOT용 런타임 라이브러리 분리, 테스트를 링크된 라이브러리로 실행, `UserVM` 제거 |
| 2024-04-12 | `93282036` `1ad836ce` `52bfa85f` | `csEvalPath`, CLI REPL, `use $global` |
| 2024-04-14 | `1f74c02b` `0e01e3f7` | `cy` 모듈, `cli.repl` |
| 2024-05-13 | `94cd86aa` `40d3820a` | 콜백 대신 선언형 바인딩, 모듈 바인딩 리팩터 |
| 2024-05-23 | `a3f289e6` `79eaf002` `45b2abbb` | REPL을 Cyber로 재구현, Web REPL, `cy.eval`을 Cyber로 |
| 2024-08-25 | `b2450cd6` `a13c0f73` | 타입 생성을 콜백에 위임, 호스트 object 타입 분리 |
| 2024-09-21 | `64589bf1` `42c5227e` `ba0fc9c9` | `@host` 콜백으로 내장 타입 생성, lib 코드를 Zig에서 쓸 수 있게 분리, `clFindType` |

`c992b94e` 시점: 접두사가 `CL` · `cl`로 바뀌었다(`clCreate` · `clEval` · `clRelease` · `clSetModuleLoader`). 함수 바인딩은
`CLHostFuncEntry funcs[] = { CL_FUNC("add", add), ... }` 표를 `CLModuleConfig.funcs`에 넣는 선언형. 스크립트 쪽은 여전히
`@host fn add(a float, b float) float`. 값은 여전히 `CLValue` 동적 표현. C API 함수 수 110개. CLI REPL은 `use $global`로
시작해 선언 없는 변수를 허용했고 지역 변수는 다음 입력에 넘어가지 않았다. JIT "불완전 · 불안정", C 백엔드 "진행 중".

## 구간 B에서 바뀐 것 (2025-11 ~ 2025-12)

- `b751ca6c`: API가 snake_case가 됐다. `cl_vm_init` · `cl_vm_deinit` · `cl_vm_eval` · `cl_vm_set_printer` · `cl_vm_set_loader`.
  스크립트 쪽 `@host`가 `#[bind]`로. 호스트 함수는 `CLRet f(CLThread* t)`이고 인자와 반환을 스택 슬롯 크기로 다룬다
  (`cl_thread_ret(t, sizeof(double))`, `cl_thread_float(t)`). 동적 `CLValue` 인자 배열이 사라졌다.
  eval 반환값은 `fn main() -> int`로 돌려받는다. 타입은 C struct와 같은 메모리 배치를 가진다.
- `e1ac563d`(2025-11-27): libcyber를 CLI 앱에서 분리. `435813c1`(2025-12-09): libcyber 빌드에서 FFI 기본 꺼짐.
- `99baa594`(2025-12-11): WASM + WASI, 내장 훅 방식, 기본 연산자 fast path, const eval 제한 시작.
- `830addae`(2025-12-03): Windows Win32 바인딩. `e03de564`: MSVC 링크 수정.
- `53e37ed6` `a9e03404` `0d554770`(2025-12-13 ~ 19): 명령어 2바이트, 스텐실 JIT를 바이트코드에서 직접 생성, x64 스텐실.

## 0.4.2 현재 상태

- C API 함수 수 101개(`cl_*(` 패턴). 문서 절: Create VM, Override `print`(`eprint` · `log` 포함), Eval script, Eval return,
  Module loader(`cl_default_loader` 위임), Function binding(`CL_BIND_FUNC`, `cl_mod_add_func`), Global binding(`CL_BIND_GLOBAL`),
  Type binding(예제 TODO).
- 라이브러리 기본 로더의 내장 모듈: `core` · `meta` · `math` · `cy` · `c` · `io` · `test`. `os`는 CLI 전용(`src/cli.zig`).
- CLI: 인자 없으면 REPL, `cyber main.cy`, `cyber help`, `-jit`(불완전), C 백엔드(진행 중). REPL은 변수 재선언 허용, `:`로 끝나면
  자동 들여쓰기, 최상위 선언은 다음 입력에서 참조 가능.
- 백엔드: 바이트코드 VM 기본. TCC/C AOT(`-Dtest-backend=tcc|cc`). LLVM 경로(`-Djit`)는 미완성.
- 테스트: `src/test/cli_test.cy`, `zig build lib-test`(41개), `zig build lib-standalone-test`(예제 3개), `examples/libcyber/`.

## fork가 한 것 (2026-10 ~ 11)

- Zig 0.15.2 → 0.17.0(ZU M1 ~ M5, `d64bcde5` ~ `ee12d0b6`). `Value`를 `extern union`으로, `stdx.io()` 하나로 `Io` 공급,
  translate-c를 빌드 단계로. `docs/specs/2026-10-25-zig-0.17-upgrade-design.md`.
- 릴리스: 태그 push로 빌드 12개 + Release. 번들에 `src/` 표준 모듈 포함, `install.sh`는 `/usr/local/lib/cyber` + 심링크.
  0.4.1(2026-10-29) · 0.4.2(2026-10-31). macOS arm64 · Rocky Linux 9에서 설치 확인.
- 임베딩 검토: ReleaseFast `libcyber.a` 2.1 MB, `cl_vm_init` 0.2 ms, 첫 eval 2.8 ms, 1M 루프 4.8 ms. 반복 eval 버그 둘
  (`main_func` 미초기화, `persist_main`의 `.use_alias` 패닉) 수정. CLI REPL이 "Import path does not exist: `main`"으로
  끝나던 문제를 고쳐 시작은 된다. `examples/libcyber/host_tool.c` 바인딩 패턴 예제 추가.
- 호스트 ↔ 스크립트 경계의 소유 규약 확정과 `cl_slice_deinit`(`ownership_memory.md`).
- `single_run` 종료 계약 정리, `src/tools/bench.cy` 수리.
- REPL 지역 변수를 `persist_main` eval 사이에 넘기고 심볼 재선언을 허용(`e541090a`). wasm32 크래시 원인을 u48 피연산자 쓰기로 추적해
  음수 `Ptr` 인덱스를 되살림(`b8f4efeb`).
- 호스트가 실행 중인 eval을 멈추는 `cl_vm_interrupt`와 체크포인트 예산 `cl_vm_set_fuel`(`f21993e2` · `d62bb3d0`). 중단된 eval은
  패닉처럼 되감고 `CL_ERROR_INTERRUPT`를 돌려주며 VM은 재사용 가능하다.

## 미완 지점

- 외부 중단은 `cl_vm_interrupt` · `cl_vm_set_fuel`로 가능해졌다(2026-11-01 `f21993e2`). 시간 기준 타임아웃은 호스트가 다른 스레드에서
  `cl_vm_interrupt`를 불러 구현한다. 메모리 상한은 없다. spawn된 스레드가 중단 · fuel 소진으로 끝났을 때 `await`가 깨어나는 경로는 작업 중.
- 신뢰하지 않는 스크립트용으로 로더에서 `c` 모듈을 거르는 옵션. 문서의 "safe mode" · "sandbox mode"는 소스에 플래그가 없다.
  `src/ct_inline.zig`의 주석 한 줄에만 남아 있다.
- 타입 바인딩 예제 TODO. 호스트 타입을 `#[bind] type`으로 노출하는 패턴이 문서에 없다.
- JIT · C 백엔드는 fork 방침상 범위 밖(`project_direction.md`).

## fork의 결정 · 미결

- 결정: 용도는 스크립트 실행 CLI + 임베딩 라이브러리. 네이티브 바이너리 · LLVM은 범위 밖. 릴리스 번들 구성. `single_run`
  종료 계약. 호스트 함수 매개변수 소유 규약.
- 미결: `c` 모듈 필터 옵션. 메모리 상한. 호스트 함수 안에서 멈추고 나중에 재개하는 수단(아래 해석 참고).

## 해석

- 임베딩 API의 변화는 타입 시스템 변화의 그림자다. 값이 모두 `CsValue`였을 때는 호스트 함수가 인자 배열을 받으면 됐다.
  값이 unboxed 정적 타입이 되자 호스트가 스택 슬롯 크기와 배치를 알아야 하고, 그래서 `cl_thread_float(t)` 같은 타입별 접근자와
  "Cyber 타입은 C struct와 같은 배치"라는 규칙이 생겼다. 바인딩이 더 빨라졌지만 호스트 코드가 타입을 틀리면 조용히 깨진다.
- `#[bind]`가 `@host`를 대체한 것은 속성 문법으로의 통일이다(`#[extern]` · `#[generator]`와 같은 모양).
- libcyber를 CLI에서 분리하고 FFI를 기본으로 끈 것은 임베딩 쪽에 유리한 결정이었다. fork의 에이전트 루프 검토가 이 위에서 가능했다.
  빠진 것은 실행 제어다. upstream은 샌드박스를 "안전한 구문만 허용"으로 생각했고 "실행 시간 제한"은 생각하지 않았다.
