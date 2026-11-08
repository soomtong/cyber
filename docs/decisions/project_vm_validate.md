# `cl_vm_validate`는 세션을 리셋하지 않는다 (2026-11-08)

상태: 구현됨(`707b03e1`). 발견 이슈 F-05.

## 배경

`cl_vm_validate`와 `cl_vm_compile`은 둘 다 `VM.compile`을 거쳤고, `VM.compile`은 맨 앞에서 `resetVM()`을 불렀다. 그래서
REPL · 에이전트 루프처럼 `persist_main`으로 상태를 이어가는 세션에서 소스를 검증하면 이월된 지역 변수와 선언이 모두
사라졌고(검증 뒤 `print(x)`가 컴파일 오류), reset 뒤의 검증이 실패하면 첫 컴파일이 반쯤 만들어진 채 남아 다음 eval이
깨졌다(08장 §7.3의 SIGBUS. 이 둘째 증상은 F-04 수정 `f5f2d241`이 `first_compile_failed`로 먼저 막았다).
검증이 세션을 지우면 호스트는 검증용 VM을 따로 두거나 검증을 포기해야 하는데, 따로 둔 VM은 세션의 변수 · 함수를
모르므로 `x + 1` 같은 정상 입력을 오류로 본다.

## 결정

1. `cl_vm_validate`는 VM을 리셋하지 않고 현재 세션 위에 컴파일한다. eval과 같은 `cont` 컴파일이라 이월된 지역 변수
   (`env_local_saves`)와 이전 eval의 함수 · 타입 · `use`가 보인다. 실행은 하지 않는다.
2. 검증한 소스가 선언한 것은 다음 eval로 넘어가지 않는다. `Compiler.main_discarded`를 세우면 다음 컴파일의 persist alias
   루프가 실패한 컴파일(`last_compile_failed`)과 같이 그 main 청크 자신의 심볼을 건너뛰고 물려받은 alias만 넘긴다.
   검증한 소스의 지역 변수는 실행되지 않았으므로 저장본도 없다.
3. 코드 생성은 건너뛰지 않는다(이전에는 `skip_codegen`). 검증 중 처음 로드된 모듈(`use math`, 사용자 모듈)과 템플릿
   인스턴스는 다음 컴파일의 `newChunks()` 범위 밖이라 그때 생성되지 않는다. 지금 생성해 두어야 다음 eval이 그대로 부를 수
   있다. 비용은 sema에 비해 작다.
4. 검증 중 처음 로드된 모듈의 `@init`(static `global` 초기화)과 extern 바인딩(`@initBindLib`)은 검증의 `@program_init`에
   들어가지만 실행되지 않는다. 다음에 실제로 도는 프로그램이 대신 초기화한다: `Chunk.rt_ready`(코드 생성 완료)이고
   `Chunk.rt_inited`(어떤 프로그램이 돌았음)가 아닌 청크를 `emit_program_init_func` · `emit_program_deinit_func`가
   이번 컴파일의 청크와 같이 넣는다. 이미 있는 `@init` · `@deinit` 심볼을 쓰고(새로 reserve하면 중복 선언), `VM.eval`은
   실행이 끝나면(성공 · panic 모두) `rt_ready`인 모든 청크를 `rt_inited`로 표시한다.
5. `cl_vm_compile` · `cl_vm_compile_path`는 그대로 reset한다. 전체 프로그램을 자기 `CLCompileConfig`(backend · persist_main)로
   컴파일하는 API라 세션 위에 올릴 의미가 없고, 컴파일 결과를 실행하는 공개 API도 없다(`cyber compile` 덤프용).
   헤더 주석에 reset을 명시했다.
6. 첫 컴파일이 실패한 뒤(`first_compile_failed`)의 validate는 eval과 같이 먼저 reset한다. 첫 컴파일이 validate로 성공하면
   `cont=true`가 되고 다음 eval이 cont 컴파일로 이어진다. core는 static init · extern이 없어 실행 없이도 문제가 없다.

## 구현 메모

- `src/vm.zig` `VM.validate`: `first_compile_failed`면 `resetVM`, `reinitPerRun`, 컴파일 설정은 마지막 eval의 `self.config`
  (`single_run` · `persist_main` · `deny_raw_ptrs`)를 따른다. sema는 `c.vm.config.persist_main`을 읽으므로 `self.config`는
  건드리지 않는다. 컴파일 뒤 `main_discarded = true`(defer라 실패해도 세움). `main_res`는 런타임 `@mainResult`가 채우므로
  검증이 호스트가 들고 있는 `CLEvalResult`를 건드리지 않는다. `VM.compile`은 그대로 reset.
- `src/compiler.zig`: `Compiler.main_discarded`(`compile()`이 `defer`로 false, validate가 뒤에 true), alias 루프 조건,
  `emit_program_init_func` · `emit_program_deinit_func`가 `chunks` 전체를 돌며 `id < chunk_start`인 청크는
  `chunk_init_pending`(`rt_ready and !rt_inited`)일 때만, `getSym("@init")`으로.
- `src/chunk.zig` `rt_ready` · `rt_inited`, `src/bc_gen.zig` `genAll` 끝에서 `newChunks()`를 `rt_ready`로.
- lib 테스트 `cl_vm_validate checks against the session without resetting it.`: persist 세션에서 good · bad validate 뒤 변수 유지와
  요약 읽기, 호스트가 든 eval 결과 유지, validate의 함수 · 타입 · 지역이 다음 eval에 없음과 같은 이름 재선언, 이전 선언이
  validate에 보임, 빈 VM의 첫 validate 뒤 eval, validate가 처음 로드한 `math`(extern)와 사용자 모듈의 `global`이 다음 eval에서
  초기화되고 두 번 초기화되지 않음, `persist_main` 없는 eval 열.

## 남은 것

- 실패한 컴파일이 처음 로드한 모듈은 반쯤 처리된 채 `chunk_map`에 남고, 다음 eval의 `use`가 그 청크를 그대로 받아
  sema · 코드 생성 없이 쓴다. F-05 이전부터 있던 경로라 이번에 손대지 않았다(실패한 청크는 `rt_ready`가 아니라 pending
  초기화 대상도 아니다).
- 검증한 소스의 타입 · 템플릿 인스턴스는 `sema.types`에 남는다. 참조되지 않을 뿐 해제되지 않는다(실패한 eval과 같음).
- REPL에서 모듈의 `global`은 매 eval의 `@program_deinit`이 `@deinit`으로 해제하므로 힙 타입 global을 다음 eval에서 쓰면
  해제된 값을 읽는다. validate와 무관한 기존 동작이다.
