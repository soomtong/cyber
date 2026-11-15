# HANDOFF (2026-11-15)

## 지금 상태

- 최신 릴리스 0.4.11(태그 `097b831f`, `build-883-097b831`, Latest). 노트 `docs/releases/0.4.11.md`.
- 로컬 master는 `origin/master`(PR #7 병합 `d755dc53`)보다 한 커밋(`json.Value.number`) 앞서 있다. push는 사용자 지시 때.
- 0.4.11 뒤 변경(모두 `docs/releases/unreleased.md`에 있다):
  - `e25e7d76`: tars-agent CodeAct 회차의 오류 문구 여섯(`for ... in`, `q: byte = 0`, `var` 없는 타입 선언, `none` 비교,
    옵션 아닌 값의 `?else`, 연산자 타입 불일치).
  - `260f48e0`: 표준 모듈 `json` · `toon`(TOON 사양 v4.4, 공식 fixture 564/564), `cl_mod_bind_json` · `cl_mod_bind_toon`,
    F-141(`.?` · `!` 언랩 임시값 누수) · F-143(wasm32 `str.is_utf8` panic) 수정.
  - 그다음 커밋: `json.to(T, v)` · `json.decode(T, src)`(`Diag.path`), F-142(`int.parse` 넘침 → `error.Overflow`),
    F-144(`?T` · `!T` 함수의 `return -x`), F-145(`!else`가 `NoCopy` 결과를 옮김), F-146(`meta.access(T, ...)`에 템플릿 인자).
  - 그다음 커밋: `json.Value.number`(원문 텍스트, 큰 수 무손실), `ParseOptions{exact}` · `toon.DecodeOptions{exact}`, `fmt_number`.
  - 설계 `docs/decisions/project_std_json_toon.md`, 사용자 문서 `docs/docs.md` "JSON and TOON.".
- tars-agent는 cyber 0.4.11에 고정(`78df31d`). `730813e`에서 `e25e7d76`의 회신을 기록했고 0.4.12에서 확인한다.
  요청서 `/Users/dp/Repository/tars-agent/docs/requests/cyber-0.4.11-codeact-messages.md`.

## 다음 할 일

1. 0.4.12 릴리스: 사용자 지시를 기다린다. tars-agent가 이 버전을 기다린다. 절차는 아래 "릴리스".
2. 사용자 결정 대기:
   - `scope` 블록 안의 `return` · `break` · `continue`가 합류한다는 것을 알리는 도구(안 1 LSP Information 진단, 안 2 hover,
     안 3 inlay hint). `project_coroutines.md` 끝 절.
   - 정렬: 안 A(일반 지역을 빌림 캡처하는 pinned closure, F-136으로 스택 이동 걸림돌은 풀림), 키 정렬(람다 반환 타입으로
     제네릭 추론, 이름), 인자 없는 `sort()`의 원소 조건. `project_sort_closures.md` "결정할 것".
   - core `@eq`의 choice 지원(`?json.Value == none`, `t.eq`로 choice 비교).
   - 설계 원칙 검토(PR #7, `docs/study/11-design-principles-review.md`) 1.7 · 2.7의 결정 항목: 표준 오류 어휘, 순환 가능성 정적
     판정, 제네릭 본문 정의 시점 검사, 구조적 병렬 루프, 마지막 사용 분석(빌림 NLL · `Slice` 값 의미 · 암시적 이동 · 분기 안 이동).
   - 0.5 범위. 사용자 목표는 "fiber 관련 동시성 동작을 모두 완성해 0.5".
3. 기술 부채(급하지 않음):
   - carry 재시도 루프: 실패한 본문의 IR을 되돌리는 장치가 없어 사전 단계로 옮기지 못했다. 콜백 반복은 `cyber.h` · docs.md에 적음.
   - `@destruct_span`은 쓰이지 않아 취소 keep 지점이 아니다. 쓰게 되면 더한다.

## 알려진 한계

- 취소 도중 다른 `@deinit`이 다시 멈추면 `panic: A fiber was suspended while it was cancelled.`
- `Fiber.waiting()`은 `wait_ready`로 멈춘 fiber에 대해 스레드의 fiber를 전부 훑는다. 양보만 하는 fiber와 Future를 기다리는
  fiber가 섞이면 `Scope.run`이 쉬지 않고 돈다.
- 실행으로 확인하지 못한 경로: 시작한 자식이 `suspend` · `await`에서 멈춘 동안 부모 스택이 옮겨지는 경우, Windows `FallbackReadLine`.
- 변수에 담은 `FnTuple`로는 빌림을 넘기지 못한다.
- 최상위 `#x := ...` 컴파일 타임 변수는 뒤의 최상위 실행문에서 못 쓴다(선언 단계에서만 평가).
- 보간 안의 보간은 지원하지 않는다(토크나이저 상태가 한 단계). 원인을 말하는 오류만 낸다.
- `?json.Value == none`은 컴파일 오류(core `@eq`가 choice 미지원). `?else` · `Value.eq`를 쓴다.
- `json` 기본 파싱은 17자리 넘는 소수를 `float`으로 근사한다(`exact`면 원문). `json.to`는 struct 필드 기본값을 쓰지 않는다.
- 하위 블록에서는 `move` · `meta.consume`을 못 쓴다(`else` 갈래의 consume은 뒤까지 죽은 상태로 남는다). 컴파일 타임
  `#for xs |v|`(EvalBuffer 반복)는 `#case` 바로 아래에서 `for_iter_stmt` 오류라 `#for 0..n |i|`로 돈다.
- VM 생성(`cl_vm_init*`)과 값 생성 C API의 할당 실패는 아직 `fatal`(실패를 알릴 시그니처를 먼저 정해야 함).
- 신뢰하지 않는 스크립트의 C FFI 차단은 미결정(`deny_raw_ptrs` · `deny_spawn`은 있음).
- 전체 발견 이슈 표: `docs/study/10-findings-register.md`(F-148까지, 열린 것 없음).

## 작업 방식

- 순서: scratchpad 재현 → 수정 → Debug CLI 확인(`zig build cli -p <scratchpad>/dbg`) → 회귀 테스트 → 문서 → 13단계 검증 → 커밋.
- 13단계 검증: `src/tools/verify.sh [로그 디렉터리]`(`task verify`, 약 10분, 기본 로그 `zig-out/verify/`). `run_in_background`로
  돌리고 완료 알림을 기다린 뒤 `rc=`를 확인하고 커밋한다(`tail`만 보지 않는다). 도는 동안 `src/`를 고치지 않는다(고쳤으면
  죽이고 다시). 다른 작업을 이어 가려면 git worktree에서 돌리고 끝나면 `git worktree remove`.
- 커밋은 의미 있는 diff면 묻지 않고 한다. push · 태그 · 릴리스는 사용자 지시 때만. `gh`는 `-R soomtong/cyber`.
- 사용자에게 보이는 변경(버그 · 언어 규칙 · 한계)은 같은 커밋에서 `unreleased.md`에, 언어 규칙이면 `docs/docs.md`에도 적는다.
  설계 결정은 `docs/decisions/`, 발견 이슈는 findings register에. 문서는 한국어, `**` 금지. 전체 `zig fmt` 금지(바꾼 줄만).

## 릴리스

1. 버전 세 곳: `build.zig` · `build.zig.zon` · `install.sh`.
2. `unreleased.md` → `docs/releases/<v>.md`(요약 · 호환성 절을 새로 쓴다), `unreleased.md`는 머리말만 남긴다.
3. 13단계 검증 rc=0 → annotated 태그 → master와 함께 push.
4. 릴리스 run 확인(`gh run list`), `gh release edit <v> --notes-file docs/releases/<v>.md --latest`. Latest는 `gh release list`로 본다.
5. `install.sh <v>`를 scratchpad에 설치해 버전 문자열 · `cyber-lsp initialize` · 예제 하나 확인.
6. 노트에 태그 커밋 · 빌드 번호를 적어 커밋하고 `docs/decisions/project_fork_release_ci.md`에도 기록.
- 재태깅 · macOS arm64 로컬 자산 업로드 절차는 `project_fork_release_ci.md`.

## 테스트 요령

- behavior 테스트는 `src/behavior_test.zig`에 `run.case`로 등록해야 돈다. 파일 끝에 `--cytest: pass` 꼬리가 있어야 한다.
  새 파일을 만들기 전에 같은 이름이 있는지 본다(덮어쓴 적 있음).
- 오류 테스트(`--cytest: error`): 기대 출력은 Debug CLI 출력에서 경로를 `@MainPath()`로 바꿔 만들고, 마지막 `--` 줄 뒤 줄바꿈
  없이 끝낸다(`perl -pi -e 'chomp if eof'`). Debug CLI는 스택 트레이스를 섞으니 `rg -A4 "^(Compile|Parse)Error"`로 문구만 뽑는다.
- lib 테스트 하나: `zig build lib-test -Dtest-filter="lib_test.await"`(필터는 하나만). 로그 끝 `failed command:`는 오류 테스트
  stderr 탓이니 종료 코드로 판정한다.
- sema를 건드리면 lib 테스트도 돌린다(`cy` 모듈 · `deny_raw_ptrs` 경로가 다르게 탄다).
- `spawn`을 쓰는 behavior 테스트는 wasm에서 뺀다(`if (!is_wasm)`).
- ReleaseSafe는 해제된 메모리를 `0xaa`로 채운다. Debug · Fast만 통과한 것은 통과가 아니다.
- 끝나지 않는 테스트는 결함일 수 있다. 탐침은 백그라운드로 띄우고 몇 초 뒤 `pgrep`으로 판정한다(포그라운드 `sleep`은 막혀 있다).
- 취소 탐침은 정상 경로의 `@deinit` 횟수와 비교한다(목록 리터럴은 임시 복사본을 만들고 버린다).
- TOON fixture 갱신은 `src/test/assets/toon-spec/README.md`.

## 구현 함정

- wasm32: 값 칸은 8바이트, 포인터는 4바이트. 칸의 위 32비트는 쓰레기라 포인터로 쓸 때는 아래 절반만 본다(F-140 · F-143).
  `@intFromPtr`는 `usize`라 `u64`에 넣을 때 `@as(u64, ...)`.
- `Heap` · `Pool` 등 C 미러 구조체(`vm.h`)가 있는 타입에 필드를 더하면 오프셋 검사에 걸린다. 끝(`c` 뒤)에 두거나 전역으로 뺀다.
- opcode 추가: `vm.h` enum과 `vm.c` `JENTRY` 표 같은 위치, `bytecode.zig`의 enum · 길이 · 덤프 · opcode 수 테스트.
- 새 AST 노드: `ast.zig`의 enum · 타입 맵 · `src` · `pos` · `end` 다섯 곳 + 노드 수 테스트 + `cy.cy` 미러 + tree-sitter 코퍼스.
- IR 지역 id는 선언 문장 순서와 같아야 한다(`Expected next IR local to be N, got M.`). 람다 인자는 `pushProc`이 먼저.
- 템플릿 타입의 메서드는 쓰지 않아도 인스턴스마다 본문이 검사되는 경우가 있다(core 타입에서 겪음). 사용자 템플릿 타입의 쓰지 않는
  메서드는 검사되지 않았다(2026-11-15 `Box[Array[int]]`로 확인). 원소 타입에 따라 안 되는 메서드는 `#[cond=...]`로 막는다.
  호출 자리마다 달라지는 검사는 core의 `meta.error`가 아니라 sema 호출 경로에 둔다.
- 검사를 엄격히 하는 수정은 core.cy · std의 숨은 불일치를 드러낸다. 전체 테스트로 확인한다.
- core.cy는 `zig-out/bin/src/`에서 읽힌다. 고친 뒤 `zig build cli`를 다시 한다.
- `@ptr_init` 같은 `@` 함수는 builtin 모듈(`markBuiltinModule`, std `json` · `toon` 포함)만 쓴다. 구조체를 필드별로 만들 때는
  `var res T = undef` + `@ptr_init(*meta.access(res, name), v)`, `#for`로 펼친 본문은 `begin:` 블록으로 감싸 지역 이름이 겹치지 않게.
- behavior 러너에는 파일 필터가 없다(`-Dtest-filter`는 zig test 이름). 파일 하나는 Debug CLI로 돌리고 누수 검사는 전체 실행에서 본다.
- 언어 메모: 비트 OR은 `||`, AND는 `&&`. 전역은 `global g int = 5`. `var x = 0`은 문법 오류(`x := 0`). `os.parseArgs`는
  `-name=value`만 받는다. `Map`의 개수는 `size()`. `out.* += fut.await()`는 await 전에 `out.*`를 읽는다.
- 벤치는 다른 프로세스가 CPU를 쓰는지 먼저 본다(tars-linux `services_test`, 종료 금지). 테스트와 동시에 돌리지 않는다.

## 참고 위치

- 동시성 전체(제너레이터 · fiber · 단계 1 · 3 · 취소 · `scope` · `@deinit` 취소): `docs/decisions/project_coroutines.md`.
- JSON · TOON: `project_std_json_toon.md`. 정렬 클로저: `project_sort_closures.md`.
- 임베딩 · tars-agent: `project_embedding_agent_loop.md` · `project_tars_agent_runtime_review.md`, C API `src/include/cyber.h`.
- 컴파일러 한계: `project_compiler_limits.md`. 평가 순서: `project_eval_order.md`. 스택 포인터 보정: `project_stack_ptr_patch.md`.
- 방향(네이티브 · LLVM · JIT는 범위 밖): `project_direction.md`.
- tars-agent는 다른 세션이 동시에 고치고 있을 수 있다(지금도 미커밋 변경이 있다). 그 저장소에 쓰기 전에 `git status`를 보고,
  쓸지는 사용자에게 맡긴다.
