# 코루틴: 옛 fiber API의 제거 경위와 현재 상태

2026-10-31, `src/test/bench/fiber/fiber.cy`를 포팅하면서 조사한 내용. 이 fork가 바꾼 것은 없고 upstream의 결정을 기록한다.

## 사실

- upstream 커밋 `b751ca6c`(2025-11-21, "[all] some updates")에서 tokenizer의 `coinit` · `coresume` · `coyield`
  키워드가 삭제되고 `yield`가 추가됐다. 옛 테스트 `test/concurrency/fibers.cy` · `test/functions/call_fiber_param.cy`도
  같이 지워졌다. 정적 타입 전환을 포함한 대규모 재설계 커밋이라 fiber만의 이유는 적혀 있지 않다.
- 옛 fiber는 동적 타입에 묶여 있었다. fiber 함수는 `dyn`을 반환했고 인자는 `List[dyn]`, `coresume`은 아무 값이나 돌려줬다.
- 지금 동작하는 코루틴은 `#[generator]` 함수뿐이다. 호출하면 `Generator[Fn]`이 돌아오고 `next()`가
  `?(type.fn_ret(Fn))`, `status()`가 `paused` · `running` · `done`을 준다. 스택리스라 프레임 하나만 저장한다
  (`src/builtins/core.cy`의 `type Generator`). 테스트는 `src/test/concurrency/generator.cy`.
- 스택형 `Fiber` 타입은 `docs/docs.md`의 "Fibers." 절에 설계만 있다(`Fiber(fn, args)` · `f.resume()` · `Fiber.yield()`).
  본문에 TODO 표시가 있고 소스 어디에도 `type Fiber` 선언이 없다. `examples/fiber.cy`는 "TODO: Implement new fibers"
  주석과 옛 코드만 남아 있다. `src/fiber.zig`는 옛 VM용 코드이며 현재 어디서도 import하지 않는다.
- 제너레이터 10만 개를 만들어 두 번씩 resume하는 벤치는 ReleaseSafe CLI에서 28 ms다(`fiber.cy`, 결과 200000).

## 제거 이유에 대한 해석

- 정적 타입 전환과 맞지 않았다. 반환 타입이 정해지지 않는 `coinit` · `coresume`을 두기 어려웠고, 새 설계는 제너레이터의
  결과 타입을 함수 시그니처에서 유도한다.
- 역할을 둘로 나눴다. "값을 조금씩 내놓는 코루틴"은 스택리스 제너레이터로, "독립 실행 컨텍스트"는 자체 힙과 성장형 스택을
  가진 Thread와 Future · await로 보냈다. Generator 주석도 "격리된 실행 컨텍스트가 필요하면 threads를 쓰라"고 적는다.
- 비용 정리. 옛 fiber는 각자 스택을 가진 stackful 코루틴이었고, 가벼운 쪽은 stackless로, 무거운 쪽은 Thread로 정리했다.
- 키워드 세 개 대신 `yield` 하나만 남긴 것은 같은 커밋의 문법 축소 흐름과 맞는다.
- 따라서 현재는 "제거"라기보다 "교체 도중"이다. upstream은 2025-11 이후 사실상 멈춰 있어 교체가 끝나지 않았다.

## `#[generator]` 표기에 대한 평가

- `#[...]` 속성은 언어 안에 이미 자리 잡았다. 현재 `extern` · `bind` · `reserve` · `cond` · `generator` · `unsafe` ·
  `consteval` · `jit` 여덟 개이고 `src/parser.zig`의 `attributes` 고정 목록으로 검사한다. Rust와 같은 모양이다.
- 다만 다른 속성은 선언의 메타데이터인데 `#[generator]`는 호출 결과 타입을 `int`에서 `Generator[fn() -> int]`로 바꾼다.
  시그니처의 `-> int`만 보고 반환 타입을 오해할 수 있다. JS는 `function*`로 선언에 표시하고 Python은 `yield`로 추론한다.
  의미상으로는 `gen fn` 같은 선언 키워드나 `yield` 기반 추론이 더 가깝다.
- 문서의 "Attributes." 절은 `TBD`로 비어 있다. 속성 목록과 `#[generator]`가 반환 타입을 바꾼다는 점은 fork 문서에 적어 둔다.

## 결정

- 당장은 upstream 문법을 그대로 따른다. 벤치 · 예제 · 임베딩 코드는 `#[generator]`를 쓴다.
- upstream이 비활성이므로 비어 있는 부분(스택형 `Fiber`, 제너레이터 reset, 속성 문법 정리)은 필요해지면 이 fork가 직접
  설계하고 구현한다. 에이전트 루프(`docs/decisions/project_embedding_agent_loop.md`)에서 실행 중단 · 재개가 필요해지면
  스택형 Fiber 또는 VM 체크 포인트가 첫 후보다. 그때 이 문서의 해석을 출발점으로 삼고, 결정은 여기에 덧붙인다.
