# 코루틴과 동시성: stackful fiber와 `await` 키워드에서 제너레이터 · Thread · Future 메서드로

2026-11-01 작성. 개요는 `cyber_0_3_to_0_4_overview.md`. 제거 경위와 평가는 `docs/decisions/project_coroutines.md`에 먼저
적혀 있고, 이 문서는 세 시점의 상태를 나란히 놓는 데 집중한다.

## 0.3 상태 (2023-12)

- 동시성 수단은 fiber 하나였다. `coinit(fn, args...)`로 만들고 `coresume`으로 진행, `coyield`로 멈췄다. fiber는 자기 콜 스택과
  pc를 가진 stackful 코루틴이고 첫 클래스 값이었다. main 실행 컨텍스트도 fiber였다.
- `coresume`은 반환값을 돌려줬고 `Fiber.status()`는 `.paused` · `.done`을 줬다. `coyield`는 콜 스택 어디서든 쓸 수 있었다.
- Planned: `reset()`, `bindArgs()`, fiber 블록(`coinit:`), `coyield`가 값을 돌려주는 것, Gas mileage, Async, Multi-thread.
- 타입은 동적이었다. fiber 함수는 `dyn`을 반환했고 `coresume`은 아무 값이나 돌려줬다.

## 구간 A에서 바뀐 것 (2024-01 ~ 2024-09)

| 날짜 | 커밋 | 변화 |
|---|---|---|
| 2024-05-23 | `16cfe032` | `await` · `Future` · `FutureResolver` · `queueTask` · `clRunReadyTasks` |
| 2024-05-23 | `79eaf002` | Web REPL, JS Promise를 Future에 바인딩 |
| 2024-07-10 | `a27cc8ae` | `runReadyTasks()` 스택 오버플로 처리 |

`c992b94e` 시점 문서의 "Concurrency" 장은 Async가 앞, Fibers가 뒤였다. Async 절은 `Future`, `await` 표현식(키워드),
"colorless async", `Future.then` · `Future.catch`(Planned), `FutureResolver[int].new()`와 `queueTask`, 그리고 Planned인
Structured concurrency(`Async` 컨텍스트, `waitAll` finish policy, `Async.block`), Task cancellation, Threads를 담았다.
"단일 스레드 위에서 task를 스케줄하고 멀티스레드는 계획"이라고 적었다. Fibers 절은 0.3과 같았다.

## 구간 B에서 바뀐 것 (2025-11 ~ 2025-12)

`b751ca6c`에서 `coinit` · `coresume` · `coyield` · `await` 키워드가 삭제되고 `yield`가 들어왔다. 옛 fiber 테스트
`test/concurrency/fibers.cy` · `test/functions/call_fiber_param.cy`도 지워졌다. 같은 커밋이 Thread · `spawn` · `Sendable` ·
Growable stacks 절을 문서에 넣었다.

## 0.4.2 현재 상태

- 제너레이터: `#[generator]` 속성을 붙인 함수를 호출하면 `Generator[Fn]`이 돌아온다. `yield`로 값을 내고 `next()`가
  `?(type.fn_ret(Fn))`, `status()`가 `paused` · `running` · `done`을 준다. stackless라 프레임 하나만 저장한다.
  `src/builtins/core.cy`의 `type Generator[FnPtr Any]`, 테스트 `src/test/concurrency/generator.cy`.
- 스레드: `spawn(fn, {args})`가 `Future[T]`를 돌려준다(`core.cy`의 `type Thread _`, `fn spawn`). 스레드는 자기 힙과 성장형
  스택을 가진 가상 스레드다. 테스트 `spawn.cy`.
- Future: `Future[T]`, `Future.complete(v)`, `f.await()` 메서드, `f.get()`. `FutureResolver[T]`는 소스에 있고
  테스트(`src/test/memory/future_resolver.cy`)도 있지만 문서는 TBD로 표시한다. 테스트 `await.cy`.
- 문서만 있고 소스에 없는 것: 스택형 `Fiber`(`Fiber(fn, args)` · `resume()` · `Fiber.yield()`), `Sendable`, Channels,
  Shared memory, `await` union, OS threads, SIMD, Gas mileage, `Future.then_spawn`, 람다 `spawn`, 제너레이터 reset.
- 옛 코드: `src/fiber.zig`는 어디서도 import하지 않는다. `examples/fiber.cy`는 "TODO: Implement new fibers" 주석과 옛 코드.

## fork가 한 것 (2026-10 ~ 11)

- `src/test/bench/fiber/fiber.cy`를 `#[generator]` 10만 개로 포팅했다. ReleaseSafe CLI 28 ms, 결과 200000.
- 제너레이터 박스가 `single_run` 종료 스윕에서 빠지던 문제(메타가 `^Generator` pointer kind)를 고쳤다.
- `FutureResolver.complete`마다 `FutureValue`가 새던 문제를 빌림으로 고쳤다.

## 미완 지점

- 스택형 `Fiber` 미구현. 에이전트 루프에서 실행 중단 · 재개가 필요해지면 첫 후보다(`project_embedding_agent_loop.md`).
- 제너레이터 reset TBD. 0.3의 `reset()` · `bindArgs()` 계획이 제너레이터로 옮겨 오지 않았다.
- 패닉한 자식 스레드 상태 조회 TBD. Channels · Shared memory · `await` union · OS threads TBD.
- 외부 중단은 `cl_vm_interrupt` · `cl_vm_set_fuel`(2026-11-01 `f21993e2`)로 생겼다. 그러나 "호스트 함수 안에서 멈추고 나중에 재개"는
  여전히 없다. `Future.await()`는 main 스레드에서 spin-wait로 블록하고(`src/vm.zig`의 `zAwait`), 비-main 스레드의 await와
  continuation 큐(`FutureValue.cont_head`, `cl_run_ready_tasks`)는 주석 처리 또는 `@panic("TODO")` 상태다.
- `#[generator]`가 반환 타입을 바꾸는 표기 문제(`-> int`인데 호출 결과는 `Generator[fn() -> int]`). 평가는 `project_coroutines.md`.

## fork의 결정 · 미결

- 결정: 당장은 upstream 문법을 따른다. 벤치 · 예제 · 임베딩 코드는 `#[generator]`를 쓴다. 비어 있는 부분은 fork가 설계한다.
- 미결: 호스트 경계에서 멈추고 재개하는 수단(스택형 Fiber 또는 `RES_AWAIT` continuation 경로). 제너레이터 reset. `#[generator]` 표기.

## 해석

- upstream은 "코루틴"을 둘로 갈랐다. 값을 조금씩 내는 쪽은 stackless 제너레이터로, 독립 실행 컨텍스트는 자기 힙을 가진 Thread로.
  0.3 fiber가 하던 두 역할을 각각 더 싼 것과 더 격리된 것으로 나눈 셈이다. 그 사이의 "같은 힙을 공유하는 stackful 코루틴"이
  바로 미구현 `Fiber`다.
- `await`가 키워드에서 메서드로 바뀐 것은 colorless 유지와 문법 축소를 동시에 만족시킨다. `Future.await()`는 어떤 함수에서도
  부를 수 있고, 키워드 하나가 줄었다.
- 구간 A의 Structured concurrency 계획(`Async` 컨텍스트 · finish policy · cancellation)은 B에서 통째로 사라졌다. 취소가
  빠진 것이 fork에게 가장 아쉬운 부분이다. 에이전트 루프는 실행 시간 상한이 필요하다.
