# VM 실행 중단: interrupt와 fuel

작성일 2026-11-01. 상태: 구현됨.

## 배경

에이전트 루프(CodeAct 계열)는 모델이 쓴 스크립트를 그대로 실행한다. 무한 루프나 폭주 재귀가 나오면 호스트가
멈출 수단이 없었다(`project_embedding_agent_loop.md`의 "실행 제어"). 프로세스나 스레드를 죽이는 것 말고는 방법이 없고,
그러면 같은 VM에 쌓인 상태(`persist_main` 변수, 선언)도 잃는다.

## 결정

VM 핫 루프에 검사점을 두고, 호스트가 두 가지 방법으로 실행을 끊게 한다.

1. interrupt: `cl_vm_interrupt(vm)`. 다른 스레드(타이머, 시그널 처리 스레드)에서 불러도 된다. 다음 검사점에서 멈춘다.
   eval이 시작될 때 지워진다.
2. fuel: `cl_vm_set_fuel(vm, n)`. eval마다 검사점 n개를 통과시키고 n+1번째 검사점에서 멈춘다(`--fuel < 0`, F-42는 이 뜻으로 확정). 0 이하는 무제한(기본값). 실행 시간과 무관하게
   결정적이라 테스트와 재현에 쓰기 좋다.

검사점은 두 곳이다.

- 역방향 `JUMP`(오프셋 < 0). 모든 루프의 반복은 역방향 점프를 지난다(`Chunk.pushJumpBackTo`, `continue`).
- 호출 명령(`CALL` 계열). 재귀와 호스트를 거친 재진입을 잡는다. 처음에는 `CHK_STK`(함수 진입)를 생각했지만
  구현에서 바꿨다(아래 구현 메모).

명령마다 검사하지 않으므로 직선 코드는 비용이 없다. 루프 한 번과 호출 한 번마다 로드 · 감소 · 분기가 붙는다.

멈추면 panic과 같은 경로로 unwind한다(스택 트레이스, 힙 스윕. panic 경로는 지역 소멸자를 돌리지 않는다). panic과 구분되도록 결과 코드는
`CL_ERROR_INTERRUPT`(enum 끝에 추가해 기존 값은 그대로)이고, 요약(`cl_vm_error_summary`)은 panic 요약에 사유
("Interrupted." 또는 "Out of fuel.")가 들어간다. 같은 VM은 계속 쓸 수 있다. `persist_main` 변수는 panic과 같이 버려진다.

## 고른 이유와 버린 대안

- 명령 단위 카운터: 정확하지만 핫 루프 모든 명령에 비용이 든다. 루프 · 호출 단위면 충분히 촘촘하다
  (검사점 없이 오래 도는 직선 코드는 길이가 바이트코드 크기로 제한된다).
- 시그널로 스레드 중단: 소멸자와 힙 상태를 보장할 수 없다.
- interrupt만 두기: 타이머 스레드가 필요하고 결과가 실행 속도에 따라 달라진다. fuel은 결정적이다.
- `CLEvalConfig`에 fuel 필드 추가: C 구조체 ABI와 `cy.cy`의 `EvalConfig` 미러가 바뀐다. 설정 함수가 더 가볍다.

## 구현 메모

- C `Thread`(`src/vm.h`)에 `fuel` · `fuel_limit` · `interrupt` 필드, Zig `ThreadC` 미러. `CHECKPOINT()` 매크로는
  `interrupt`를 volatile로 읽고 `fuel`을 감소시킨다. 무제한은 `fuel = INT64_MAX`라 분기가 하나다.
- 검사점은 역방향 `JUMP`와 `CALL` · `CALL_TRAIT` · `CALL_PTR` · `CALL_UNION`. `CHK_STK`(함수 진입)는 프레임이
  바뀌는 도중이라(`stack -= ret_size`) 피했다. 재귀는 반드시 호출 명령을 지난다.
- 멈춘 pc에서 스택 트레이스를 만들려면 debug sym이 있어야 한다. trace 빌드는 모든 명령에 debug sym을 붙이지만
  릴리스 빌드는 실패 가능 명령만 붙여서, 처음에는 ReleaseFast에서 `NoDebugSym`으로 `CL_ERROR_UNKNOWN`이 나왔다.
  `.jump`를 `pushFCode`로 내보내도록 바꿨다(`Chunk.pushJumpBackTo` · `pushEmptyJump`, `continue`가 뒤로 패치될 수 있음).
- `exec_auto`가 `RES_INTERRUPT`를 받으면 `handleStop`이 사유를 panic 메시지로 넣고 panic unwind(트레이스, 힙 스윕)를
  거친 뒤 `error.Interrupted`를 돌려준다. `VM.exec_bytecode`가 eval 시작마다 `resetStop`으로 요청을 지우고 fuel을 채운다.
- 측정(ReleaseFast, hyperfine 15회): fib 30.6 → 30.9 ms(+0.9%), for 94.1 → 96.0 ms(+2.1%).
- 테스트: lib "cl_vm_set_fuel stops runaway loops and recursion.", "cl_vm_interrupt stops a running eval."(호스트 함수 안에서,
  다른 스레드에서. wasm32에서는 스레드 부분을 건너뜀). 누수 검사 allocator. 네이티브 Debug · ReleaseSafe · ReleaseFast ·
  trace 끔, wasm32 ReleaseSafe · ReleaseFast(wasmtime) 통과.

## spawn 스레드(2026-11-01, 자동 보안 리뷰 지적으로 추가)

처음 구현은 메인 스레드에만 적용됐다. 스크립트가 `spawn(무한 루프).await()`를 하면 작업 스레드는 fuel 무제한에
interrupt도 받지 않았고, 메인은 `zAwait`의 spin 루프에 갇혀 검사점을 지나지 않으므로 `cl_vm_interrupt`도 듣지 않았다.
호스트가 영구히 멈춘다. 또 작업 스레드의 panic은 `worker.zig`가 `std.debug.panic`으로 호스트 프로세스를 죽였다(기존 동작).

- `Thread.interrupt`는 이제 포인터다. 모든 스레드가 메인 스레드의 `interrupt_flag`를 가리킨다(`new_thread`에서 설정).
  값 1은 호스트 interrupt, 2는 "메인이 멈추는 중"이다. `new_thread`는 메인의 `fuel_limit`도 물려받는다(스레드마다 따로 셈).
- `zAwait`의 spin은 플래그를 확인해 `RES_INTERRUPT`를 돌려준다. `AWAIT` 명령은 원래 `RES_AWAIT` 말고는 결과를 무시했다.
  이제 오류면 pc를 `AWAIT`로 되돌려 반환하고, 트레이스용으로 `await_op`을 `pushFCode`로 내보낸다.
- 작업 스레드가 실패하면 프로세스를 죽이지 않고 future 상태를 바꾼다. 4는 멈춤(interrupt, fuel)이라 메인의 await는
  `CL_ERROR_INTERRUPT`, 3은 그 밖의 panic이라 "Spawned thread did not finish." panic이 된다(2026-11-08부터 메시지가 있으면
  "Spawned thread panicked: <메시지>", 비-main 스레드의 await도 같은 루프. `project_spawn_nested_await.md`).
- 메인이 panic이나 중단으로 힙을 스윕하기 전에 `VM.stopSpawnedThreads`가 플래그 2를 세우고 worker 풀이 빌 때까지
  기다린다(`Pool.wait_idle`). 작업 스레드가 메인 힙의 `FutureValue`에 쓰는 것과 스윕이 겹치지 않게 하려는 것이다.
- 처리한 요청은 지운다. 남겨 두면 eval 밖에서 호스트가 VM 함수를 다시 부를 때 곧바로 멈춘다.
- 테스트: lib "Spawned threads stop with the eval and do not abort the host."(fuel 상속, 다른 스레드의 interrupt가 await
  중인 메인과 작업 스레드에 도달, 작업 스레드 panic, 이후 재사용). ReleaseSafe 캐시 없이 3회 반복 통과.
- 별개의 기존 버그: 프로세스의 두 번째 이후 VM에서 인자 없는 `spawn(f, {})`는 ReleaseSafe 컴파일 중
  "incorrect alignment"(템플릿 확장, `value.zig` `asPtr`)로 죽었다. 원인은 중단 기능과 무관한 컴파일 타임 평가의
  미초기화 결과였고 2026-11-01에 고쳤다(`project_ct_eval_loop_result.md`).

## 미정

- 호스트 함수 안(예: `os.exec`, 긴 I/O)에서 막힌 경우는 이 방법으로 끊지 못한다. 호스트 함수가 직접 확인해야 한다.
  `stopSpawnedThreads`도 그런 작업 스레드를 기다린다.
- fuel은 스레드마다 따로 세므로 스크립트가 스레드를 많이 만들면 총량이 늘어난다(`spawn` 자체도 호출이라 메인 fuel을 쓰므로
  상한은 있다).
