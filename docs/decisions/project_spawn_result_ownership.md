# spawn 결과의 전달과 Future 소유권 (2026-11-22)

상태: 구현됨. 관련 결정 `project_spawn_nested_await.md`(남은 것의 마지막 항목), 모델 정리 `docs/history/concurrency_model_fit.md`
(Thread는 격리 힙, 통신은 `@send` 복사).

## 배경

`spawn f(args)`의 스레드는 자기 힙을 가진다. 인자는 `@spawn`이 spawn하는 스레드에서 `@send`로 새 스레드의 힙에 복사하고, 새
스레드는 작업이 큐에 들어간 뒤에야 돌기 시작하므로 이쪽은 안전했다. 결과 쪽이 문제였다.

1. 결과 복사가 부모 힙을 잠금 없이 썼다. `@thread_entry`가 worker OS 스레드에서 `@send(result_thread, *res)`를 불렀고,
   `str.@send`는 `@init_astr_undef(result_thread, len)`로 부모 스레드의 힙에 할당했다. 부모는 그동안 자기 힙에서 계속
   할당 · 해제한다. 스레드 힙(free list, 페이지, `buffers` 맵, Trace 맵)은 스레드 안전하지 않다. 재현(scratchpad
   `heap.cy`: 400개 spawn이 `str`을 돌려주는 동안 main이 2만 개 문자열을 만듦)은 Debug에서 10번 중 4번
   `hash_map` 잠금 단언으로 abort했다(두 OS 스레드가 같은 힙의 맵을 동시에 고침).
2. 사용자 `@send`가 `^T`를 만들면 그 객체는 실행 중인 스레드, 곧 worker의 힙에 생겼다. 받는 쪽에서 보면 남의 힙을 가리키는
   값이다.
3. worker가 완료 값을 부모 힙의 `FutureValue.data`에 직접 썼다. future를 await하지 않고 버리면 그 객체는 이미 해제됐을 수
   있다(`project_spawn_nested_await.md` 남은 것). 버그 2(아래 "Future 소유권")와 같은 자리다.

## 결정

1. 결과는 spawn된 스레드의 힙에 남겨 두고, future의 소유자가 자기 스레드에서 가져간다(pull). worker는 부모 힙도 부모의
   `FutureValue`도 건드리지 않는다.
   - `@thread_entry`는 `@call(func, &args)`의 값을 그대로 돌려준다. worker는 반환 값의 바이트를 풀 할당자의 버퍼로 옮기고
     (`FutureSyncState.result`), 스레드 객체를 `FutureSyncState.thread`에 둔 채 상태를 2로 바꾼다. OS 스레드는 풀로 돌아간다.
   - `Future.await()`는 `@await_` 뒤 `completed`가 거짓이면 `@send(@cur_thread(), result)`로 값을 자기 힙에 복사해
     `data`에 넣고 `completed = true`, 그다음 `@thread_result_done`이 상태를 5(받음)로 바꾸고 spawn된 스레드를 해제한다.
     두 번째 `await`는 `data`를 읽는다.
   - 해제는 `worker.dropThreadResult`: spawn된 스레드 위에서 `@thread_drop[Sig]`(결과의 `@destruct`)를 부른 뒤 스레드를 해제한다.
     스레드가 끝난 뒤에는 그 스레드를 아무도 쓰지 않으므로, 호출하는 OS 스레드에서 돌린다(`run_queued_task`가 대기 중에 남의
     작업을 돌리는 것과 같은 방식). interrupt · fuel로 멈추지 않게 그동안 스레드 자신의 0 플래그와 무제한 fuel을 쓴다.
   - `@send`가 받는 스레드에서 돌므로 사용자 `@send`의 할당도 받는 힙에 생긴다(배경 2).
2. 잠금이 아니라 복사 위치를 옮긴 이유. 부모 힙에 잠금을 두려면 부모 자신의 모든 할당 · 해제 · refcount 경로가 잠가야 한다.
   단일 스레드 경로의 비용이 들고, `concurrency_model_fit.md`의 격리 힙 모델(복사로만 통신)과 어긋난다. pull은 모델을 그대로
   두고 "힙은 그 스레드만 고친다"를 지킨다.
3. 받는 쪽의 복사는 `Future.@receive`다. 참조가 없는 값(`type.managed`가 거짓, 복사 가능)은 바이트 그대로, 참조가 있는
   struct는 그 타입의 `@send`. `spawn`은 이 둘만 받는다(`@spawn`의 `@check_sendable`, 'Expected sendable: <타입>' 컴파일 오류).
   전에는 `@send`의 `#switch`에 갈래가 없는 타입(`?str`, `!str` 같은 참조 있는 option · result)이 빈 본문으로 컴파일돼 정의되지
   않은 값을 돌려줬다. 참조 없는 `symbol` · `error` · `!int`는 이제 바이트 복사로 정확히 온다. `await`가 모든 `Future[T]`에서
   인스턴스화되므로(호스트 future 포함) `@receive`는 받지 못하는 타입에서 `@send` 대신 panic 한 줄로 컴파일된다. 그 줄은
   `spawn`이 그런 future를 만들지 않으므로 실행되지 않는다.
4. VM을 해제할 때(`VM.deinit`, reset 포함) `stopSpawnedThreads` 뒤 `dropUnclaimedResults`가 상태 2로 남은 스레드를 해제한다.
   await하지 않은 future의 스레드다. 컴파일된 drop 함수가 아직 있을 때 돈다.

## 구현 메모

- `src/sync.zig` `FutureSyncState`: `thread`, `result` · `result_len`, `drop_func` 필드와 상태 5. 상태 1(쓰는 중)은 쓰지 않는다.
- `src/builtins/core.cy`: `Future.await`, `@thread_entry`, `@thread_drop`, `@cur_thread` · `@thread_result` · `@thread_result_done`
  바인딩. `@start_thread`는 drop 함수와 `FutureValue` 대신 공유 상태를 받는다. 스택의 진입 인자에서 `result_thread`가 빠졌다.
- `src/worker.zig`: `run_task` 성공 경로, `dropThreadResult` · `claimThreadResult` · `dropUnclaimedResults`. 결과 버퍼 할당이
  실패하면 스레드 힙을 panic처럼 쓸어 버리고 상태 3(`Spawned thread did not finish.`).
- `src/vm.zig` `zAwait`: 상태 5도 완료.
- 확인: `heap.cy` Debug 200회 0 실패(수정 전 10회 중 4회 abort), ReleaseSafe 200회 0 실패. behavior
  `concurrency/spawn_send.cy`(main이 할당하는 동안 `str` 결과 64개, 두 번 await, 자식을 await하며 할당하는 스레드,
  `@deinit` 있는 결과), lib `A spawned function returns only what await can copy.`(`?str` · 참조 있는 struct의 컴파일 오류,
  `symbol` · `!int` 결과).

## 남은 것

- 인자 쪽 `@send`도 같은 `#switch`라 참조 있는 option · result 인자는 빈 본문으로 컴파일된다. 인자는 spawn하는 스레드에서
  새 스레드(아직 돌지 않음)의 힙으로 복사하므로 경쟁은 없지만 값이 정의되지 않는다. `@check_sendable`을 인자에도 걸지는
  따로 정한다.
