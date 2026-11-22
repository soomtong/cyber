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
   있다(`project_spawn_nested_await.md` 남은 것, 해제 후 쓰기). 버린 future가 부모 힙에 받은 결과 문자열도 아무도 해제하지
   않았다. 재현(scratchpad `drop.cy`: 루프에서 `_ = spawn work(i)` · `_ = spawn work_str(i)` 2천 번씩, 그 뒤 main이 2만 개
   문자열)은 Debug에서 10번 모두 실패했다(`hash_map` 잠금 단언 abort, 세그폴트(139), `unreleased refcount: 1888`).
   "Future 소유권" 절에서 다룬다.

## 결정

1. 결과는 spawn된 스레드의 힙에 남겨 두고, future의 소유자가 자기 스레드에서 가져간다(pull). worker는 부모 힙도 부모의
   `FutureValue`도 건드리지 않는다.
   - `@thread_entry`는 `@call(func, &args)`의 값을 그대로 돌려준다. worker는 반환 값의 바이트를 풀 할당자의 버퍼로 옮기고
     (`FutureSyncState.result`), 스레드 객체를 `FutureSyncState.thread`에 둔 채 상태를 2로 바꾼다. OS 스레드는 풀로 돌아간다.
   - `Future.await()`는 `@await_` 뒤 `completed`가 거짓이면 `Future.@receive`로 값을 자기 힙에 복사해 `data`에 넣고
     `completed = true`, 그다음 `@thread_result_done`이 상태를 5(받음)로 바꾸고 spawn된 스레드를 해제한다.
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
   await하지도 destruct하지도 않은 future의 스레드다(release op가 없는 `single_run`의 main 지역, panic 쓸기로 사라진 객체 안의
   future). 컴파일된 drop 함수가 아직 있을 때 돈다.

## Future 소유권 (await 없이 버린 future)

pull로 worker가 `FutureValue`를 쓰지 않게 되어 해제 후 쓰기는 사라졌지만, 버린 future의 spawn된 스레드(스택 · 힙 · 결과)는
VM 해제 때까지 남았다. 루프에서 future를 버리는 스크립트는 그만큼 메모리가 늘었다(lib 테스트의 300개 × 4회 eval에서 약 12 MiB).

결정: spawn된 스레드는 소유자(future)와 생산자(worker) 둘이 공유하고, 나중에 끝나는 쪽이 해제한다. 별도 refcount 없이 공유
상태의 원자적 상태 하나로 정한다.

1. `FutureValue`에 `@deinit`을 둔다. `@future_drop(shared_state)`가 `cmpxchg 0 → 6`(버림)을 시도한다.
   - 성공: 스레드가 아직 돈다(또는 큐에 있다). worker가 끝날 때 `cmpxchg 0 → 2`가 6을 보고 실패하면 자기 OS 스레드에서
     `dropThreadResult`로 결과와 스레드를 해제한다. 실패 경로(3 · 4)의 `cmpxchg`도 6을 보면 panic 메시지를 되돌려 해제한다.
   - 실패하고 2: 스레드가 이미 끝났다. 소유자가 2 → 5로 바꾸고 그 자리에서 해제한다.
   - 실패하고 3 · 4 · 5: worker가 이미 해제했거나 결과를 받았다. 할 일이 없다.
2. 경쟁하는 전이는 생산자의 0 → 2/3/4와 소유자의 0 → 6뿐이다. 2에서 5로 가는 것은 소유자만이다(`await`와 `@deinit`은 같은
   스레드에서 돈다. `Future`는 `@send`가 없어 다른 스레드로 가지 않는다). 따라서 `cmpxchg` 하나로 해제 책임이 정확히 한 쪽에
   간다.
3. 공유 상태 자체는 이전처럼 `VM.shared_states`가 소유하고 VM과 같이 해제한다. 버린 future가 많은 스크립트에서 이 목록은
   spawn 수만큼 자란다(한 항목 수십 바이트). 상태를 refcount로 바꿔 즉시 해제하는 것은 남은 것으로 둔다.
   (해결: 아래 "공유 상태의 회수" 절)

구현: `core.cy` `FutureValue.@deinit` · `@future_drop` 바인딩, `worker.zig` `dropFuture`와 `run_task`의 `cmpxchg 0 → 2`
(결과 버퍼 할당 실패의 0 → 3도 `cmpxchg`), `sync.zig` 상태 6. 호스트 future(`cl_future_new`)와 `Future.complete`는
`shared_state`가 없어 `@future_drop`이 바로 돌아온다.

확인: `drop.cy` Debug 200회 0 실패(수정 전 10회 모두 실패), ReleaseSafe 200회 0 실패. behavior `concurrency/spawn_drop.cy`
(끝나기 전 · 뒤에 버린 future 섞기, 스레드 안에서 버린 future, `@deinit` 있는 결과, `Future.wait_any` 뒤 버림. Debug의
refcount 검사가 spawn된 스레드마다 drop 뒤 0을 확인한다). lib `Futures dropped without await free their spawned threads.`(같은
VM에서 300개씩 버리는 eval 5회의 메모리 증가가 2 MiB 이하. 소유권 수정 전 약 12 MiB).

## 공유 상태의 회수

배경: `FutureSyncState`는 `@new_shared_state`가 만들어 `VM.shared_states`에 넣고 VM 해제(또는 reset) 때만 해제했다. 같은
VM에서 spawn을 반복하는 호스트(세션 · persist_main)나 루프에서 spawn하는 스크립트는 spawn마다 한 항목(구조체 약 64바이트와
목록의 포인터)이 VM 수명 동안 남았다. lib 테스트의 eval 5회(4011개 spawn씩)에서 목록이 20055개로 자랐다.

결정: 공유 상태에 사용자 수 `refs`(처음 2)를 두고, 둘 다 끝나면 마지막 쪽이 목록에서 빼고 해제한다(`VM.releaseSharedState`).
스레드 결과의 해제 책임(위 상태 6)과 같은 "나중에 끝나는 쪽" 모델이다. 상태 머신에 상태를 더하지 않고 별도 카운터를 쓴 이유는,
상태는 결과 · 스레드의 해제 책임을 정하고 카운터는 상태 구조체 자체의 수명을 정해 두 질문이 다르기 때문이다(상태 5 · 3 · 4
뒤에도 소유자는 `panic_msg`와 상태를 읽는다).

1. 소유자 쪽: `FutureValue.@deinit`의 `@future_drop`이 `dropFuture` 뒤 한 번 내린다. `await`가 받은 뒤(상태 5)에도 소유자는
   `FutureValue`가 살아 있는 동안 상태를 읽으므로, 받기가 아니라 destruct가 끝이다.
2. 생산자 쪽: `run_task`의 세 끝(성공 · 실패 · 결과 버퍼 할당 실패)에서 마지막 상태 쓰기와 (상태 6이면) `dropThreadResult` 뒤
   내린다. 그 뒤 생산자는 상태를 건드리지 않는다(`notifyProgress`는 전역 epoch만 쓴다). `@start_thread`에서 작업을 큐에 넣지
   못하면 생산자가 없으므로 그 자리에서 내린다.
3. 목록 제거는 O(1)이다. 상태에 목록 위치 `index`를 두고 `shared_state_mutex` 아래 `swapRemove` 뒤 옮겨진 항목의 `index`를
   고친다. `VM` 필드의 타입은 그대로라 `vm.h`의 `ZVM` padding은 변하지 않는다.
4. 목록은 남은 상태를 찾는 데 계속 쓴다. 소유자가 destruct되지 않은 future(release op가 없는 `single_run` · `persist_main`의 main
   지역, panic 쓸기로 사라진 객체 안의 future)의 상태는 `refs`가 0이 되지 않으므로 전처럼 `dropUnclaimedResults`가 결과를 해제하고
   VM 해제 · reset이 상태를 해제한다. VM 해제 중 `dropMainResult`가 REPL 결과의 future를 destruct하면 그 자리에서 목록에서
   빠지고, 마지막 해제 루프는 남은 것만 돈다.

확인: lib `The sync states of spawned threads are freed when both sides are done.`(await한 것과 버린 것, 스레드 안의 spawn을 섞은
4011개 spawn eval을 같은 VM에서 5회. 첫 eval 뒤 4회 동안 목록 64개 이하, 메모리 증가 512 KiB 이하. 해제를 끄면 목록 20055개로
실패). scratchpad `stress.cy`(버린 `int` · `?str` future 4천 개, await하는 `?str` 500개, `?str` · `!str` 인자, main의 2만 개 문자열) Debug 200회 0 실패, ReleaseSafe 200회 0 실패(출력 비교, Debug의 refcount 검사 포함).

## 인자와 결과의 같은 보내기 규칙 (option · result의 payload 보내기)

배경: 위 결정 3 뒤에도 인자와 결과의 규칙이 달랐다. 결과는 `@check_sendable`(참조 없는 값은 바이트, 참조 있는 struct는
`@send`)을 따랐고, 인자는 `@send`의 `#switch`를 그대로 따랐다. 남은 것에 적었던 "참조 있는 option · result 인자가 빈 본문으로
컴파일된다"는 다시 재현해 보니 사실이 아니었다. 인자 쪽 `@send`의 `#else`가 'Expected sendable: ?str'로 막았다. 대신 반대
방향으로 어긋났다. `?int` · `!int` · 참조 없는 `@send` 없는 struct(`Point{x, y int}`)는 결과로는 되고 인자로는
'Expected sendable: ?int' · 'Expected sendable: Point' 컴파일 오류였다.

결정: 컴파일 오류로 맞추지 않고, payload를 보낼 수 있는 `?T` · `!T`를 보낸다. 인자와 결과가 같은 규칙 하나를 쓴다.

1. 규칙은 `core.cy`의 `#[consteval] fn @sendable(T type) -> bool` 하나다. `@send` 메서드가 있는 struct, 참조 없는 복사 가능 값
   (`type.managed`가 거짓이고 `type.is_copyable`), 참조 있는 `?T` · `!T`는 `T`가 보낼 수 있을 때.
2. `@send`가 이 규칙대로 복사한다. struct는 `@send` 메서드, 없으면 바이트. 참조 있는 option은 `none`이거나 payload의 `@send`,
   result는 error 그대로이거나 payload의 `@send`. 나머지는 바이트(`@send_bytes`), 바이트로 못 보내면 'Expected sendable: <타입>'.
   `@copy`의 option · result 갈래와 같은 모양이다.
3. `@spawn`은 결과와 각 인자에 `@check_sendable`을 건다. 오류는 바깥 타입 이름으로 난다('Expected sendable: ?[]int').
4. `Future.@receive`는 `#if @sendable(T)`일 때 `@send(@cur_thread(), res)`를 부른다. 받는 쪽도 같은 함수라 갈래를 따로 두지
   않는다. `await`가 호스트 future에서도 인스턴스화되므로 규칙 밖의 타입은 전처럼 panic 한 줄로 컴파일된다.

컴파일 오류로 맞추는 대신 보내기를 고른 이유. `?str` · `!str`은 spawn된 함수의 흔한 반환 타입이고(찾지 못함, 실패), payload의
`@send`를 재귀로 부르는 것만으로 된다. 새 복사 경로가 생기지 않는다. 할당은 payload의 `@send`가 하고, 그것은 이미 받는 스레드에서
돈다(인자는 아직 돌지 않는 새 스레드의 힙, 결과는 await하는 스레드). `docs.md` Sendable 절의 계획 목록에 있던
"`?T` · `!T` if `T` is Sendable"이 이것이다. 인자에서 참조 없는 struct를 바이트로 받게 된 것은 결과 쪽과 같은 규칙을 쓴 결과다.
`Ptr[T]`처럼 참조 없는 raw 값도 결과로는 이미 받았으므로 인자로도 받는다(raw 포인터는 `deny_raw_ptrs`로 막는 영역이다).

`#[consteval]` 함수 안의 `#switch`에는 `#else: pass`를 쓸 수 없다('Inline eval: Unsupported passStmt.'). 갈래 없이 아래로
떨어지게 쓴다.

확인: behavior `concurrency/spawn_send_option.cy`(`?str` · `!str` 인자와 결과, `none` · error 값, `@send` 있는 struct의 option
인자 · 결과, `??str`, 참조 없는 struct 인자, 버린 `?str` future). lib `A spawned function returns only what await can copy.`
(`?[]int` 결과와 `![]int` 인자의 컴파일 오류, `?int` 인자와 `none`).

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

- (해결) 인자와 결과의 보내기 규칙이 달랐다. "인자와 결과의 같은 보내기 규칙" 절.
- 아직 큐에 있는 작업의 future를 버려도 작업은 끝까지 돈다(결과는 곧 버려진다). 큐에서 빼거나 스레드 interrupt로 끊는 것은
  필요해지면 한다.
- (해결) `VM.shared_states`가 VM 수명 동안 자랐다. "공유 상태의 회수" 절.
