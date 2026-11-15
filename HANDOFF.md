# HANDOFF (2026-11-15)

## 지금 상태

- 최신 릴리스 0.4.11(태그 → `097b831f`, `build-883-097b831`, Latest). 노트 `docs/releases/0.4.11.md`.
- `origin/master` = 로컬 = `e25e7d76`. 작업 트리는 미추적 `HANDOFF.md`만.
- 0.4.11 뒤 커밋은 `e25e7d76` 하나: tars-agent CodeAct 회차의 오류 문구 여섯(`for ... in`, `q: byte = 0`, `var` 없는 타입 선언,
  `none` 비교, 옵션 아닌 값의 `?else`, 연산자 타입 불일치). 내용은 `docs/releases/unreleased.md`.
- 2026-11-15: 표준 모듈 `json` · `toon`(TOON 사양 v4.4, 공식 fixture 564/564)과 F-141(`.?` · `!` 언랩 임시값 누수) 수정.
  설계는 `docs/decisions/project_std_json_toon.md`, 사용자 문서는 `docs/docs.md` "JSON and TOON.".
- tars-agent는 cyber 0.4.11에 고정했고(`78df31d`), `730813e`에서 `e25e7d76`의 회신을 기록하고 0.4.12에서 확인하겠다고 했다.
  요청서 `/Users/dp/Repository/tars-agent/docs/requests/cyber-0.4.11-codeact-messages.md`.

## 다음 할 일

1. 0.4.12 릴리스: 사용자 지시를 기다린다. tars-agent가 이 버전을 기다린다. 절차는 아래 "릴리스".
2. 사용자 결정 대기:
   - `scope` 블록 안의 `return` · `break` · `continue`가 합류한다는 것을 알리는 도구(안 1 LSP Information 진단, 안 2 hover,
     안 3 inlay hint). `docs/decisions/project_coroutines.md` 끝 절.
   - 정렬 안 A(일반 지역을 빌림 캡처하는 pinned closure. F-136으로 스택 이동 걸림돌은 풀림)와 `sort_by_key`(람다 반환 타입으로
     제네릭 `%K` 추론이 필요). `docs/decisions/project_sort_closures.md`.
   - 0.5에서 무엇을 더 풀지. 사용자 목표는 "fiber 관련 동시성 동작을 모두 완성해 0.5".
3. `json` · `toon` 후속(사용자 결정 대기): `Value` → 타입 역변환(`json.to(T, v)`), 무손실 큰 수, core `@eq`의 choice 지원,
   F-142(`Int.parse` 넘침 미검사) 수정. `project_std_json_toon.md` 끝 절.
4. 남은 기술 부채(급하지 않음):
   - carry 재시도 루프: 실패한 본문의 IR을 되돌리는 장치가 없어 사전 단계로 옮기지 못했다. 콜백 반복은 `cyber.h` · docs.md에 적음.
   - `@destruct_span`은 쓰이지 않아 취소 keep 지점이 아니다. 쓰게 되면 더한다(`project_coroutines.md`).

## 알려진 한계

- 취소 도중 다른 `@deinit`이 다시 멈추면 `panic: A fiber was suspended while it was cancelled.`
- 변수에 담은 `FnTuple`로는 빌림을 넘기지 못한다.
- 최상위 `#x := ...` 컴파일 타임 변수는 뒤의 최상위 실행문에서 못 쓴다(선언 단계에서만 평가).
- 보간 안의 보간은 지원하지 않는다(토크나이저 상태가 한 단계). 원인을 말하는 오류만 낸다.
- `Fiber.waiting()`은 `wait_ready`로 멈춘 fiber에 대해 스레드의 fiber를 전부 훑는다. 양보만 하는 fiber와 Future를 기다리는
  fiber가 섞이면 `Scope.run`이 쉬지 않고 돈다.
- 실행으로 확인하지 못한 경로: 시작한 자식이 `suspend` · `await`에서 멈춘 동안 부모 스택이 옮겨지는 경우.
- VM 생성(`cl_vm_init*`)과 값 생성 C API의 할당 실패는 아직 `fatal`(실패를 알릴 시그니처를 먼저 정해야 함).
- 신뢰하지 않는 스크립트의 C FFI 차단은 미결정(`deny_raw_ptrs` · `deny_spawn`은 있음).
- Windows `FallbackReadLine`은 실제 실행으로 확인하지 않았다.
- `?json.Value == none`은 컴파일 오류(`Unsupported: Value`, core `@eq`가 choice 미지원). `?else` · `Value.eq`를 쓴다.
- `int.parse`는 넘침을 검사하지 않는다(F-142).
- 전체 발견 이슈 표는 `docs/study/10-findings-register.md`(현재 F-143까지).

## 작업 방식

- 순서: scratchpad 재현 → 수정 → Debug CLI 확인(`zig build cli -p <scratchpad>/dbg`) → 회귀 테스트 → 문서 → 13단계 검증 → 커밋.
- 13단계 검증: `src/tools/verify.sh [로그 디렉터리]`(`task verify`, 약 10분, 기본 로그 `zig-out/verify/`). `run_in_background`로
  돌리고 완료 알림을 기다린다. 끝나면 `rc=`를 확인한 뒤 커밋한다(`tail`만 보지 않는다).
  도는 동안 `src/`를 고치지 않는다. 고쳤으면 죽이고 다시. 다음 작업을 이어 가려면 git worktree에서 돌린다(끝나면 `git worktree remove`).
- 커밋은 의미 있는 diff면 묻지 않고 한다. push · 태그 · 릴리스는 사용자 지시 때만. `gh`는 `-R soomtong/cyber`.
- 사용자에게 보이는 변경(버그 · 언어 규칙 · 한계)은 같은 커밋에서 `docs/releases/unreleased.md`에, 언어 규칙이면 `docs/docs.md`에도
  적는다. 설계 결정은 `docs/decisions/`에. 문서는 한국어, `**` 금지. 전체 `zig fmt` 금지(바꾼 줄만).

## 릴리스

1. 버전 세 곳: `build.zig` · `build.zig.zon` · `install.sh`.
2. `unreleased.md` → `docs/releases/<v>.md`(요약 · 호환성 절을 새로 쓴다), `unreleased.md`는 머리말만 남긴다.
3. 13단계 검증 rc=0 → annotated 태그 → master와 함께 push.
4. 릴리스 run 확인(`gh run list`), `gh release edit <v> --notes-file docs/releases/<v>.md --latest`. Latest 여부는 `gh release list`로 본다.
5. `install.sh <v>`를 scratchpad에 설치해 버전 문자열 · `cyber-lsp initialize` · 예제 하나 확인.
6. 노트에 태그 커밋 · 빌드 번호를 적어 커밋, `docs/decisions/project_fork_release_ci.md`에도 기록.
- 재태깅 · macOS arm64 로컬 자산 업로드 절차는 `project_fork_release_ci.md`.

## 테스트 요령

- 새 behavior 테스트는 `src/behavior_test.zig`에 `run.case`로 등록해야 돈다. 파일 끝은 `--cytest: pass` 꼬리가 있어야 한다.
- 새 파일을 만들기 전에 같은 이름이 있는지 본다(덮어쓴 적 있음).
- 오류 테스트(`--cytest: error`): 기대 출력은 Debug CLI 출력에서 경로를 `@MainPath()`로 바꿔 만들고, 마지막 `--` 줄 뒤 줄바꿈 없이
  끝낸다(`perl -pi -e 'chomp if eof'`). Debug CLI는 오류에 스택 트레이스를 섞으니 `rg -A4 "^(Compile|Parse)Error"`로 문구만 뽑는다.
- lib 테스트 하나: `zig build lib-test -Dtest-filter="lib_test.await"`(`-Dtest-filter`는 하나만). 로그 끝의 `failed command:`는
  오류 테스트 stderr 탓이니 종료 코드로 판정한다.
- sema를 건드리면 behavior만 보지 말고 lib 테스트도 돌린다(`cy` 모듈 · `deny_raw_ptrs` 경로가 다르게 탄다).
- `spawn`을 쓰는 behavior 테스트는 wasm에서 뺀다(`if (!is_wasm)`).
- ReleaseSafe는 해제된 메모리를 `0xaa`로 채운다. Debug · Fast만 통과한 것은 통과가 아니다.
- 끝나지 않는 테스트는 결함일 수 있다. 탐침은 백그라운드로 띄우고 몇 초 뒤 `pgrep`으로 판정한다. 포그라운드 `sleep`은 막혀 있다.
- 취소 탐침은 정상 경로의 `@deinit` 횟수와 비교한다(목록 리터럴은 임시 복사본을 만들고 버린다).

## 구현 함정

- wasm32: 값 칸은 8바이트지만 포인터는 4바이트. payload 칸의 위 32비트는 쓰레기라 32비트 대상에서는 아래 절반만 비교한다.
  `@intFromPtr`는 `usize`라 `u64`에 넣을 때 `@as(u64, ...)`.
- `Heap` · `Pool` 등 C 미러 구조체(`vm.h`)가 있는 타입에 필드를 더하면 오프셋 검사에 걸린다. 끝(`c` 뒤)에 두거나 전역으로 뺀다.
- opcode 추가: `vm.h` enum과 `vm.c` `JENTRY` 표 같은 위치, `bytecode.zig`의 enum · 길이 · 덤프 · opcode 수 테스트.
- 새 AST 노드: `ast.zig`의 enum · 타입 맵 · `src` · `pos` · `end` 다섯 곳 + 노드 수 테스트 + `cy.cy` 미러. tree-sitter 코퍼스도.
- IR 지역 id는 선언 문장 순서와 같아야 한다(`Expected next IR local to be N, got M.`). 람다 인자는 `pushProc`이 먼저.
- 템플릿 타입의 메서드는 쓰지 않아도 인스턴스마다 본문이 검사된다. 원소 타입에 따라 안 되는 메서드는 `#[cond=...]`로 막는다.
  호출 자리마다 달라지는 검사는 core의 `meta.error`가 아니라 sema 호출 경로에 둔다.
- 검사를 엄격히 하는 수정은 core.cy · std의 숨은 불일치를 드러낸다. 전체 테스트로 확인한다.
- core.cy는 `zig-out/bin/src/`에서 읽힌다. 고친 뒤 `zig build cli`를 다시 한다.
- 언어 메모: 비트 OR은 `||`, AND는 `&&`. 전역은 `global g int = 5`. `var x = 0`은 문법 오류(`x := 0`). `os.parseArgs`는
  `-name=value`만 받는다. `out.* += fut.await()`는 await 전에 `out.*`를 읽는다.
- 벤치는 다른 프로세스가 CPU를 쓰는지 먼저 본다(tars-linux `services_test`, 종료 금지). 테스트와 동시에 돌리지 않는다.

## 참고 위치

- JSON · TOON: `project_std_json_toon.md`. TOON fixture 갱신은 `src/test/assets/toon-spec/README.md`.
- 동시성 전체(제너레이터 · fiber · 단계 1 · 3 · 취소 · `scope` · `@deinit` 취소): `docs/decisions/project_coroutines.md`.
- 임베딩 · tars-agent 쪽: `project_embedding_agent_loop.md` · `project_tars_agent_runtime_review.md`, C API `src/include/cyber.h`.
- 컴파일러 한계 표: `project_compiler_limits.md`. 평가 순서: `project_eval_order.md`. 스택 포인터 보정: `project_stack_ptr_patch.md`.
- 방향(네이티브 · LLVM · JIT는 범위 밖): `project_direction.md`.
- tars-agent는 다른 세션이 동시에 고치고 있을 수 있다. 그 저장소에 쓰기 전에 `git status`를 보고, 쓸지는 사용자에게 맡긴다.
