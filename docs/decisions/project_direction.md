# 이 fork의 용도와 방향

2026-10-31, LLVM 백엔드 항목을 닫으면서 적어 둔 것.

## 용도

- soomtong/cyber는 Cyber를 평소 쓰는 Python · Perl · Shell 스크립트의 대용으로 쓰기 위해 직접 fork해서
  빌드하는 저장소다. 목표는 스크립트를 바로 실행하는 CLI이고, Cyber로 네이티브 바이너리를 만들 이유는 없다.
  바이너리가 필요한 일은 Zig나 Odin 같은 안정된 언어로 한다.
- 더 나아가 TARS 리눅스(`/Users/dp/Repository/tars-linux`)에 붙일 내장 에이전트 루프의 실행 언어 후보로
  Cyber를 살펴보는 중이다. 에이전트가 도구 호출을 JSON으로 나열하지 않고 스크립트를 써서 실행하는
  CodeAct 계열 설계라, 작은 런타임 · 빠른 시작 · 임베딩 가능한 라이브러리(`libcyber`)가 중요하다.

## 백엔드

- 기본 백엔드는 바이트코드 VM이다. 네이티브가 필요하면 TCC/C AOT(`-Dtest-backend=tcc|cc`)로 충분하다.
  2026-11-23 덧붙임: 위 문장은 확인 없이 적은 것이다. C 백엔드(`-tcc`, `-cc`, `CL_TCC`, `CL_CC`)는 지금 어떤 스크립트도
  컴파일하지 못한다. `print(1.5)`가 `core:17`(`#[bind] fn abort`)에서 'CompileError: Expected function implementation.'으로
  끝난다. upstream에서 물려받은 상태이고 CI는 이 백엔드를 돌린 적이 없다. 원인은 세 겹이다.
  1. `src/sema_resolve.zig`의 `#[bind]` 함수 해소가 백엔드가 VM이 아니면 VM에 묶인 함수마다 `.cy` 본문을 요구한다
     (`c.compiler.config.backend != C.BackendVM and decl.stmts.len == 0`). core · meta의 63개 함수에 본문이 없다.
  2. `src/cgen.zig`의 `mapType(builtins_c, "int", ...)` 계열이 null을 만난다. `int` · `i32` · `byte` · `r32` · `r64` ·
     `float`가 이제 템플릿의 별칭이라 이름으로 찾는 타입 심볼이 아니다.
  3. cgen의 이름 표가 옛 `$name` 훅 이름을 쓴다. `core.cy`는 지금 `@name`을 쓴다.
  런타임 쪽 결함도 있다. `src/aot.c`의 `cb_float_fmt`는 1e21 이상의 값에서 버퍼 밖을 읽고, `cb_utf8_seq_len`은 본문이 비어 있다.
  2026-11-23 결정: 지금은 고치지 않고 제품이 사실대로 말하게 한다. `Compiler.compile()`이 JIT 거절 바로 뒤에서 `C.BackendTCC` ·
  `C.BackendCC`를 'The C backend (-tcc, -cc) does not work in this version. Run with the bytecode VM (the default).' 컴파일 오류로
  거절하고, CLI는 컴파일 전에 같은 문구를 찍고 종료 코드 1로 끝난다. `cyber help`는 두 옵션을 'Not working in this version.'으로
  적는다. 백엔드 코드(`src/cgen.zig`, `src/aot.c`, `src/aot.h`)는 남긴다. 고치는 사람을 위한 길은 둘이다.
  `-Dtest-backend=tcc|cc`(`task test:behavior BACKEND=tcc`)는 전처럼 백엔드에 닿고, CLI는 환경 변수 `CYBER_C_BACKEND=1`을 주면
  거절하지 않는다. 둘 다 라이브러리의 `clCBackendDev` 스위치를 켠다(`src/lib.zig`, `docs/build.md`). 고칠 때는 위 1 → 2 → 3 순서로
  막힌다. 발견 표 F-33 · F-195.
- LLVM 백엔드(`src/llvm.zig` · `src/llvm_gen.zig`, `-Djit`)는 켜지 않는다. upstream도 2025-11 이후
  손대지 않은 미완성 경로다. Zig 0.17 업그레이드의 남은 항목 7(LLVM-C 번역 모듈)은 이 이유로 닫았다.
  당시에는 `cy.hasJIT` 뒤에 있어 빌드에 영향이 없으므로 두었고, 2026-11-04 죽은 코드 정리에서 파일을 지웠다.
- 복사-패치 JIT(`src/jit/`, CLI `-jit`)는 LLVM 백엔드와 다른 경로다. 2026-11-01 확인 결과 세 겹으로 동작하지 않는다.
  1. `src/compiler.zig`의 `C.BackendJIT` 분기가 `jitgen.gen` 앞에서 무조건 `error.Unsupported`를 돌려준다(upstream
     `f401a101`, 2024-07-10 "Refactor to `Slot`"부터).
  2. 그 분기를 지우면 `src/jit/gen.zig`에 `gen` 함수가 없어 컴파일되지 않는다. gen.zig는 IR을 `idx` 정수로 다루던 옛
     API(`genStmt(c, idx: u32)` 등) 그대로라 지금 IR(`*ir.Stmt` · `*ir.Expr`)과 맞지 않는다. Zig는 도달하지 않는 코드를
     분석하지 않아서 빌드는 통과한다.
  3. 그보다 앞서 `cyber -jit x.cy`는 `core.cy`의 `#[bind]` 함수에서 "Expected function implementation"으로 멈춘다.
  bytecode에 새 opcode를 넣을 때 JIT 지원은 맞추지 않는다. JIT를 살리려면 gen.zig를 지금 IR · bytecode에 맞춰 다시 써야
  하므로 별도 결정이 필요하다.
  2026-11-01 결정: `Compiler.compile()` 맨 앞에서 `C.BackendJIT`를 "The JIT backend is not supported."
  컴파일 오류로 거절한다(CLI `-jit`과 임베딩 API `CL_JIT` 공통, lib 테스트 "JIT backend is rejected with a clear
  compile error."). `cyber help`에서 `-jit`를 뺐고 `docs/docs.md`의 JIT 절은 지원하지 않는다고 고쳤다. `CL_JIT`
  enum 값은 ABI 호환을 위해 남긴다.
  2026-11-06 결정(사용자 지시): 잔재를 모두 지운다. `src/jit/` 11개 파일(gen · 어셈블러 · 스텐실 · 생성 스크립트),
  `Compiler.jitBuf` · `CompileResult.jit`, `Chunk.jit_funcs` · `Chunk.jit`, `bc_gen`의 JIT 생성 단계와 `func.info.jit`
  분기, `FuncInfo.jit`(packed라 `padding`을 u3으로 늘려 크기 유지), `#[jit]` 속성(parser · ast · sema, 테스트
  `functions/jit_func.cy`), `ByteCodeBuffer.labels`(JIT만 쓰던 역방향 점프 표), `enter_jit` opcode(`vm.h` enum ·
  `vm.c` `JENTRY` · `CASE`, `FRAME_JIT`, `JitEntry`, x86_64 `i2c` naked 어댑터, opcode 수 132 → 131), `-Djit` 빌드 옵션과
  `cy.hasJIT`, `TestBackend.jit`, lib-test `All declarations compile.`의 `jitgen` 예외. 남긴 것: `CL_JIT` enum 값과
  `cy.Backend.jit`(ABI), CLI `-jit`과 `Compiler.compile()`의 거절 오류, 그 lib 테스트. `docs/docs.md` JIT 절은
  코드가 제거됐다고 한 문장 고쳤다.

## 따라오는 우선순위

- 릴리스 번들과 `install.sh`는 CLI 실행 환경(실행 파일 하나. 0.4.6까지는 실행 파일 + `src/` 표준 모듈)을 바로 쓰게 하는 데 맞춘다.
- 에이전트 루프 쪽 검토는 임베딩 API(`src/lib.zig`, `cyber.h`)와 `-Dffi=false` 같은 작은 구성이 기준이 된다.

## upstream과의 관계 (2026-10-31 추가)

- upstream(fubark/cyber)은 2025-11 커밋 이후 사실상 멈춰 있다. 재설계가 끝나지 않은 부분(스택형 `Fiber`, 제너레이터
  reset, REPL의 지역 변수 이월, Attributes 문서 등)은 기다리지 않고 이 fork가 직접 설계하고 구현한다.
- 순서는 용도를 따른다. 스크립트 CLI와 에이전트 루프 임베딩에 필요한 것부터 하고, 언어 문법은 upstream과 호환을 깨지
  않는 범위에서 바꾼다. 바꿀 때는 `docs/decisions`에 결정을 먼저 적는다.
- 코루틴 관련 경위와 평가는 `project_coroutines.md`에 있다.

## 정체성 (2026-11-20 추가)

- 개발 과정을 "자연어 → 의사 코드 → 타입 있는 자동 메모리 언어 → 저수준 시스템 언어"로 볼 때 사이버는 세 번째 단계 언어다.
  알고리즘과 메모리 관리를 따로 생각하게 하는 쪽이 기본이고, `move` · `&&` · `NoCopy` 같은 네 번째 단계 도구는 성능을 다듬을
  때 꺼내는 선택이다. 근거와 그에 따른 과제(마지막 사용 분석, 0.5 뒤)는 `docs/study/11-design-principles-review.md` 2절.
