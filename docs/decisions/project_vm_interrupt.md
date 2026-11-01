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
2. fuel: `cl_vm_set_fuel(vm, n)`. eval마다 검사점을 n번 지나면 멈춘다. 0 이하는 무제한(기본값). 실행 시간과 무관하게
   결정적이라 테스트와 재현에 쓰기 좋다.

검사점은 두 곳이다.

- 역방향 `JUMP`(오프셋 < 0). 모든 루프의 반복은 역방향 점프를 지난다(`Chunk.pushJumpBackTo`, `continue`).
- `CHK_STK`(함수 진입). 재귀와 호스트를 거친 재진입을 잡는다.

명령마다 검사하지 않으므로 직선 코드는 비용이 없다. 루프 한 번과 호출 한 번마다 로드 · 감소 · 분기가 붙는다.

멈추면 panic과 같은 경로로 unwind한다(소멸자, 스택 트레이스, 힙 스윕). panic과 구분되도록 결과 코드는
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

## 미정

- 호스트 함수 안(예: `os.exec`, 긴 I/O)에서 막힌 경우는 이 방법으로 끊지 못한다. 호스트 함수가 직접 확인해야 한다.
- 스레드 풀 작업 스레드(`spawn`)의 interrupt 전파.
