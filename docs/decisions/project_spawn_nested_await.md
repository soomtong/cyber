# spawn 스레드 안의 `await`와 스레드 panic 메시지 전달 (2026-11-08)

상태: 구현됨(`56af553f`). 발견 이슈 F-07(07장 표의 8번 · 10번).

## 배경

`Future.await()`는 `zAwait`(`src/vm.zig`)에서 처리한다. 공유 future(`spawn`이 돌려준 것)를 main 스레드가 기다리면 완료될
때까지 spin하고, spawn된 스레드(worker 풀의 OS 스레드에서 도는 `cy.Thread`)가 기다리면 continuation 큐에 넣고
`RES_AWAIT`를 돌려주려던 코드가 전부 주석이고 `@panic("TODO")`만 남아 있었다. Zig의 `@panic`이라 스크립트 오류가 아니라
호스트 프로세스 abort다(`exit=134`). 스크립트 한 줄(`fn mid(): return spawn(leaf, {}).await()`)로 임베딩 호스트를 죽일 수 있어
에이전트 루프 규칙 4("`spawn` · `await`를 쓰지 않는다")의 근거였다.

같은 경로의 둘째 문제로, spawn된 스레드가 `panic('boom')`으로 끝나면 worker가 future 상태만 3(실패)으로 바꾸고 스레드를
해제하므로 main의 await는 `Spawned thread did not finish.`만 보고 원래 메시지는 사라졌다.

## 결정

1. spawn된 스레드의 `await`도 main과 같이 블록한다. 공유 future의 상태가 2(완료)가 될 때까지 기다리고, 3이면 panic, 4면
   interrupt, 호스트 interrupt 플래그가 서면 interrupt다. continuation 큐 · `RES_AWAIT` 경로는 만들지 않는다. 스레드마다
   OS 스레드가 있으므로 블록해도 다른 스레드는 돈다. 협력 스케줄링이 필요해지면 `project_coroutines.md`의 설계로 간다.
2. 기다리는 스레드는 큐에 쌓인 스레드 작업을 직접 실행한다(`Pool.run_queued_task`). worker 풀은 `CPU 수 - 1`개로 고정이라
   블록만 하면 "풀 크기만큼의 스레드가 각자 자식을 await"하는 순간 자식이 큐에서 영영 꺼내지지 않아 교착한다. 기다리는
   쪽이 큐를 비우면 기다리는 작업은 다른 worker에서 돌고 있거나 큐에 있어 자기가 꺼내 돌리므로 항상 진행한다.
   main 스레드도 같은 방식으로 돕는다. 이로써 CPU가 1개라 worker가 0개인 환경에서도 `spawn(...).await()`가 멈추지 않는다
   (이전에는 큐에 넣고 main이 영원히 spin).
3. 스레드 panic 메시지를 awaiting 쪽에 전달한다. 공유 상태 `FutureSyncState`(`src/sync.zig`)를 `u8`에서
   `extern struct { state: u8, panic_msg_ptr, panic_msg_len }`로 바꾸고, worker는 스레드를 해제하기 전에 메시지를 복사해 두고
   상태를 3으로 바꾼다. awaiting 쪽은 `Spawned thread panicked: <메시지>` panic을 만든다. 중첩이면 메시지가 겹친다
   (`Spawned thread panicked: Spawned thread panicked: boom`). 메시지가 없는 실패(panic 타입이 메시지가 아닌 경우)는 이전처럼
   `Spawned thread did not finish.`.
   `state`를 첫 필드로 두어 `core.cy`가 `Ptr[byte]`로 들고 `shared_state.* = 0`을 쓰는 자리는 그대로다. 메시지는 공유 상태와
   같이 `VM.shared_states`가 소유하고 VM reset · deinit 때 해제하므로 awaiting 쪽은 읽기만 한다.

4. VM을 해제할 때 worker 스레드를 종료하고 join한다(`Pool.deinit`: `shutdown` 플래그 + `cond.broadcast` + `join`). 그 전에
   `VM.deinit`이 `stopSpawnedThreads`로 아직 도는 스레드(await하지 않고 버린 future의 것)를 멈추고 풀이 빌 때까지 기다린다.
   이전에는 worker OS 스레드가 VM보다 오래 살아 해제된 `Pool` 안의 조건 변수 위에서 잠들어 있었고, 같은 주소에 다음 VM이
   올라오면 깨어나 해제된 메모리를 밟았다. 기존 결함이지만 spawn 테스트가 worker를 1개만 만들 때는 드러나지 않았고, 이번
   변경의 깊이 30 체인이 worker 9개를 만들자 ReleaseSafe behavior 테스트가 다음 케이스에서 세그폴트로 드러냈다.
   `Pool.wait_idle`도 큐의 작업을 직접 돌리므로 worker가 없는 환경에서 멈추지 않는다.

## 구현 메모

- `src/vm.zig` `zAwait`: main · 비-main 분기를 하나의 루프로 합쳤다. 루프 한 바퀴마다 상태 · interrupt 플래그를 보고,
  큐에 작업이 있으면 하나 돌린 뒤 다시 확인하고, 없으면 `spinLoopHint`. `Thread.ret_panic_fmt` 추가(`fmt.allocFormat`).
- `src/worker.zig`: `Worker.run`의 작업 본문을 `Pool.run_task`로 빼고, `pop_task`(큐 머리 꺼내기 + `last_task_node` 정리)와
  `run_queued_task`(잠그고 꺼내고 풀고 실행)를 더했다. `active_workers`는 worker 루프에서만 센다(돕는 스레드는 이미 활성이거나
  main). 실패 경로는 `Thread.panic_msg()`로 메시지를 `pool.alloc`에 복사해 공유 상태에 적은 뒤 `cmpxchg 0 → 3`. 이미 3이면
  (소유자가 무효화한 경우를 위한 예비 경로, 현재 core.cy는 무효화하지 않음) 메시지를 되돌리고 해제.
- `src/thread.zig`: `panic_msg()`(payload의 ptr 48비트 · len 16비트 해독, `free_panic`이 이를 씀), `ret_panic_fmt`.
- `src/builtins/core.zig` `new_shared_state`: 구조체 할당, `.state = 0`. `src/vm.zig` deinit은 메시지도 해제.
- `src/worker.zig` `Pool.deinit` · `Worker.run`의 `shutdown` 검사, `wait_idle`의 `run_queued_task`. `src/vm.zig` `VM.deinit` 첫머리의
  `stopSpawnedThreads()`(reset 포함).
- 재현(scratchpad, 모두 수정 전 `exit=134`): 중첩 `spawn(...).await()`, 깊이 30 · 200 체인(풀 9개보다 깊음), 스레드 안 자식 panic.
  수정 후 각각 `41`, `30` · `200`, `panic: Spawned thread panicked: Spawned thread panicked: boom`. 20개 스레드가 각자 자식 3개를
  await하는 팬아웃, 중첩 `str` 전달도 정상.
- 테스트: behavior `concurrency/spawn.cy`(중첩 await, 중첩 `str`, 깊이 30 체인, 8개 팬아웃), lib
  `Spawned threads stop with the eval and do not abort the host.`(panic 메시지 `Spawned thread panicked: boom`, 중첩 panic 메시지,
  중첩 await 아래 fuel 소진이 `CL_ERROR_INTERRUPT`, 중첩 await 재사용).

## 남은 것

- 기다리는 스레드가 큐의 작업을 자기 OS 스택에서 실행하므로 체인이 깊으면 OS 스택에 VM 실행 루프가 겹겹이 쌓인다(worker 16 MiB,
  main은 OS 기본값). 깊이 200은 문제없었고 수천 단계의 await 체인은 측정하지 않았다. 필요하면 돕기 깊이에 상한을 둔다.
- `spawn` 스레드의 await는 여전히 바쁜 대기다(CPU 한 코어를 점유). 조건 변수로 바꾸려면 완료 쪽이 깨워야 하는데 지금 완료는
  원자적 저장뿐이다. 스레드가 많은 스크립트에서 문제되면 `spinLoopHint` 뒤에 짧은 sleep을 둔다.
- 호스트 함수 안에서 막힌 스레드는 이 변경과 무관하게 끊지 못한다(`project_vm_interrupt.md` 미정).
- `Future`를 await하지 않고 버리면 worker가 완료 값을 main 힙의 `FutureValue`에 쓰는 시점에 그 객체가 이미 해제됐을 수 있다.
  기존 경로이고 `sync.zig`의 "소유자 무효화(3)"가 그 자리인데 core.cy가 아직 쓰지 않는다.
