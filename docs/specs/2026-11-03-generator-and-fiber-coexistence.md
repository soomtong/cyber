# Generator와 Fiber를 함께 두는 설계 검토

2026-11-03 작성, 2026-11-07 결정, 2026-11-11 제너레이터 선언을 `generator fn`으로 바꿔 구현. 상태: 단계 1.5 · 2 구현(2026-11-11: `generator fn`, `.suspended`, `fiber` · `suspend` · `Fiber`). 단계 1(`CL_AWAIT`, `cl_vm_resume`, 호스트 Future C API)은 2026-11-12 구현(`docs/decisions/project_coroutines.md`의 "단계 1 구현" 절). 단계 3 · 4는 미구현. 구현 기록과 스펙에서 달라진 점은 `docs/decisions/project_coroutines.md`의 "Fiber 구현 (2026-11-11)" 절. 결정 항목은 `docs/decisions/project_coroutines.md`의
"설계 결정 (2026-11-07)" 절에 있다. 이 문서의 코드는 그 결정을 반영한 제안 문법이다.
앞선 판단 틀은 `docs/history/concurrency_model_fit.md`, 사실 근거는 `docs/study/07-coroutines-concurrency.md`이다.

---

## 1. 개요

질문: stackless(`#[generator]`)와 stackful(`Fiber`)을 둘 다 구현해서 가지고 있으면 어떤가?

짧은 답: 좋다. 단, 두 모델이 같은 역할을 놓고 경쟁하지 않을 때만. 같은 역할을 두 모델이 나눠 가지면 생태계가 갈라진다
(Python의 generator 기반 asyncio와 greenlet/gevent가 대표적인 실패 사례다).

사실 이것은 새로운 방향이 아니다. upstream 문서(`docs/docs.md`의 Concurrency 장)가 이미 둘 다를 계획했다.

- `Generators.` 절: `#[generator]`, `yield v`, `next()` (구현됨)
- `Threads.` 아래 `Fibers.` 절: `Fiber(fn, args)`, `f.resume()`, `Fiber.yield()` (*TODO*, 미구현)

눈여겨볼 점은 문서상의 `Fiber.yield()`가 값을 싣지 않는다는 것이다. upstream이 역할을 이미 나눠 둔 흔적이다.
값은 generator가 내고, fiber는 실행을 양보만 한다. 이 문서는 그 분담을 명시적인 규칙으로 만들고, 둘이 만나는 지점을 정리한다.
(결정 뒤 보충: 이 fork는 `Fiber.yield()` 대신 `suspend` 키워드를 쓴다. 3.2 참고.)

---

## 2. 선례: 둘 다 가진 언어들

| 언어 | stackless | stackful | 관계 | 교훈 |
| --- | --- | --- | --- | --- |
| Lua | 없음 | `coroutine` | generator는 `coroutine.wrap`으로 만든 관용구 | stackful 하나로 둘 다 된다. 대신 값 타입이 동적이다 |
| Ruby | (내부 반복 `each`) | `Fiber` (1.9) | `Enumerator#next`(외부 반복)가 Fiber 위에서 구현됨. 3.0부터 Fiber Scheduler로 non-blocking I/O | 계층화. generator가 fiber의 응용이라 개념이 하나로 모인다. 대신 외부 반복이 느리다 |
| Python | generator, `async def` | greenlet(외부 라이브러리) | 서로 모름. gevent와 asyncio는 섞어 쓰기 어렵다 | 역할이 겹치면 생태계가 둘로 갈린다. 3.4 asyncio가 generator를 코루틴으로 쓰다가 3.5에서 `async def`로 분리했다 |
| Kotlin | `sequence {}`, `suspend` | 없음 | `sequence`가 `suspend` 상태 기계를 재사용 | 한 메커니즘에 API 두 개. 둘 다 stackless라 색 문제가 남는다 |
| Go | 없음(range-over-func는 콜백) | goroutine | 1.23 `iter.Pull`이 런타임 내부 코루틴 전환(`coroswitch`)으로 구현됨 | stackful 런타임이 "당겨 쓰는 반복자"를 위해 가벼운 전환 경로를 따로 둔다 |
| C++ | C++20 코루틴 | Boost.Context / Boost.Fiber, `fiber_context` 제안(P0876) | 언어와 라이브러리로 나뉨 | 언어에는 stackless, 라이브러리에는 stackful. 둘이 자주 함께 쓰인다 |
| Zig | (0.11에서 `async` 제거) | `std.Io` 구현체(그린 스레드) | 실행 모델을 `Io` 인터페이스 뒤로 숨김 | 사용자는 모델을 고르지 않고, 구현체가 고른다 |
| OCaml 5 | 없음 | effect handler (one-shot continuation) | generator · async · 스케줄러를 모두 effect로 표현 | 원리적으로 통합된 답. 대신 effect가 타입에 드러나지 않는다 |

정리하면 성공한 조합은 두 종류다.

1. 계층화(Ruby, Lua): stackful이 기반이고 generator는 그 위의 관용구다.
2. 역할 분리(C++, Go의 `iter.Pull`): 각자 잘하는 일만 한다.

실패한 조합은 두 모델이 같은 일(대기)을 놓고 경쟁한 경우다(Python).

---

## 3. 핵심 디자인

### 3.1 세 가지 공존 방식

| 방식 | 내용 | 평가 |
| --- | --- | --- |
| A. 역할 분리 병존 | Generator와 Fiber를 별도 타입 · 별도 메커니즘으로 둔다. 역할 규칙으로 겹침을 막는다 | 권장. 현재 구현을 버리지 않고, upstream 문서 설계와 같다 |
| B. 계층화 | Fiber만 구현하고 Generator를 Fiber 위의 라이브러리로 만든다(Ruby `Enumerator` 방식) | generator 100만 개(~146 B/개)라는 장점을 잃는다. 이미 있는 stackless 구현을 버리게 된다 |
| C. 컴파일러 자동 선택 | `yield`가 본문에만 있으면 stackless, 깊은 곳에도 있으면 stackful로 컴파일 | 의미가 달라진다(스택 주소의 유효 기간, 성능 절벽). 사용자가 모델을 예측할 수 없다. 기각 |

### 3.2 역할 규칙 (방식 A의 핵심)

| | Generator | Fiber |
| --- | --- | --- |
| 목적 | 값을 만든다(지연 시퀀스, 파서 토큰, 순회) | 기다린다(호스트, I/O, Future, 다른 fiber) |
| 선언 · 생성 | `generator fn f(...) -> T:` 선언, 호출하면 `Generator` | `fiber f(args)` 또는 `fiber:` 블록, 결과는 `Fiber` |
| 멈춤 표기 | `yield v` 키워드, generator 본문에서만 | `suspend` 키워드, 어디서든 |
| 밖에서 진행 | `g.next() -> ?T`, `for g \|v\|` | `f.resume() -> FiberStatus` (`.suspended` / `.done`) |
| 상태 | `g.status()`: `.suspended` · `.running` · `.done` | `f.status()`: 같은 세 값 |
| 값 전달 | `next()` 반환값, 타입은 시그니처에서 유도 | 값 없음. 결과는 Future · 힙 객체 · 채널로 전달 |
| 함수 색 | 있음(감수) | 없음 |
| 비용 | 객체 하나 + 프레임 스냅샷 | 별도 스택(작게 시작해 성장) |
| 이식성 | 어디서든(C 상태 기계로 낮출 수 있음) | VM 전용(VM 스택이 힙에 있어서 wasm32에서도 가능) |

규칙은 두 줄이다.

- 값을 내는 일은 generator만 한다. `suspend`는 값을 싣지 않는다.
- 기다리는 일은 fiber만 한다. generator로 비동기 대기를 흉내 내는 관용구(Python 3.4 방식)를 표준 라이브러리에 두지 않는다.

표기 원칙(2026-11-07 결정). 수신자가 있는 조작은 메서드(`f.resume()`, `f.status()`, `g.next()`), 현재 실행 맥락을 멈추는
조작은 키워드(`yield v`, `suspend`)다. `return` · `break`와 같은 분류다. upstream 문서의 `Fiber.yield()`는 수신자 없는 조작을
정적 메서드로 흉내 낸 것이라 쓰지 않는다. 새 키워드는 `generator` · `fiber` · `suspend` 셋이고, `#[generator]` 속성은 키워드
도입과 함께 제거한다(24곳). 제너레이터 선언은 `generator fn f(...)`다(2026-11-11). `fiber f(args)`가 호출식이라 `fn`으로
선언과 표현식을 가른다. `generator`는 `fn` 앞에서만 수식어이고 예약어가 아니다. 상태 enum은 `.paused`를 `.suspended`로 바꿔 `suspend` → `.suspended` → `resume()`이 한 어휘가
되게 한다(Lua의 `suspended` · `running` · `dead`와 같은 꼴).

키워드 선택 근거.

| 후보 | 평가 |
| --- | --- |
| `generator` | 채택. `Generator` 타입 · `yield`와 어휘가 이어진다. 저장소 내 식별자 사용 0건 |
| `iter` · `gen` | 변수명으로 이미 쓰인다(`gen :=` 9건, `iter :=` 4건). 문맥 키워드는 파서를 복잡하게 한다 |
| `yield fn f()` | `yield fn() -> int:`(람다를 yield)와 모호하다 |
| `fn f() -> Generator[T]:`로 추론 | 선언 머리에 역할이 안 보이고 `Generator[Fn]` 매개변수 모양과 맞지 않는다 |
| `suspend` | 채택. Zig(옛 async)의 `suspend` 문, Kotlin 용어, Lua 상태 이름. 식별자 사용 0건 |
| `pause` | `.paused`와 어울리지만 게임 · UI 코드의 변수 · 메서드 이름과 자주 충돌한다 |
| 값 없는 `yield` | generator 본문 안에서 값 yield와 fiber 양보가 헷갈린다 |

Fiber 생성 표기는 Go의 `go f(x)`와 같은 "키워드 + 호출식"을 택했다. 인자는 지금 평가하고 호출은 첫 `resume()`에서 한다.
upstream의 `Fiber(f, {args})`는 호출을 미루기 위해 함수와 인자 튜플을 따로 받는 생성자였고, 같은 꼴인 `spawn(fn, {args})`는
이번에 바꾸지 않는다. fiber 구현에서 호출식을 함수와 인자로 분해하는 코드가 생기면 `spawn f(args)`로 맞추는 일은 후속 작업이다.

`suspend`에 값을 싣지 않는 데에는 타입 이론상의 이유도 있다. stackful yield는 호출 깊이 어디서든 일어나므로,
yield하는 값의 타입이 호출 체인 위쪽 함수의 시그니처에 드러나지 않는다. 이것은 effect이고, 정적으로 검사하려면
effect 시스템(Koka)이 필요하다. 0.3의 `coresume`이 `dyn`을 돌려줘야 했던 이유이기도 하다. 값을 빼면 이 문제가 사라진다.
fiber 진입 함수의 반환 타입은 `void`만 허용한다. 결과는 `^T` · Future · 채널로 전달한다.

### 3.3 Future를 둘 사이의 다리로

Future를 "대기의 공통 인터페이스"로 정하면 두 모델과 Thread가 하나로 이어진다.

~~~text
                         Future[T].await()
                                │
        ┌───────────────────────┼─────────────────────────┐
        ▼                       ▼                         ▼
  fiber 안에서 호출       main 맥락(fiber 밖)       호스트 경계(루트 맥락)
  → 완료될 때까지         → 지금처럼 spin           → CL_AWAIT로 eval을 빠져나감
    suspend                 (호환 유지)               호스트가 완료시키고 cl_vm_resume
    스케줄러가 재개
~~~

- `await()`의 정의는 하나다. "완료될 때까지 현재 실행 맥락을 멈춘다." 어떻게 멈추는지만 런타임이 고른다.
- 완료된 Future는 플래그 검사 후 값을 돌려준다. 맥락 검사 없이 지금 비용과 같다. fiber 안의 멈춤은 pc · fp · 스택 포인터
  저장과 교체뿐이고 힙 할당이 없다. 미완료 Future에서 멈춘 fiber를 `resume()`하면 본문에 들어가지 않고 `.suspended`를 바로
  돌려준다. 스케줄러가 spin하지 않게 하는 보조(`Future.wait_any` 등)는 단계 3의 일이다.
- 완료시키는 쪽은 `spawn`(다른 스레드), `FutureResolver`(같은 스레드), 호스트 C API(신설) 셋이다.
- generator 본문 안의 `await()`는 generator를 소비하는 fiber를 멈춘다. generator 자신은 `running` 상태로 남는다(3.4).
- 이렇게 하면 지금 `@panic("TODO")`인 "비-main 스레드의 await"도 같은 경로로 풀 수 있다. 각 스레드의 루트 맥락을 fiber로 보면 된다.

### 3.4 "길 2"는 Fiber의 특수한 경우다

`concurrency_model_fit.md`의 길 2(호스트 함수에서 `RES_AWAIT`로 빠져나가고 재개)는 루트 fiber가 호스트에게 yield하는 것과 같다.
따라서 순서를 이렇게 잡으면 일을 버리지 않는다.

1. 루트 맥락 하나만 멈추고 재개하는 경로를 만든다(길 2). 스택 교체가 없으므로 작다.
2. 같은 저장/복원 코드(`t->c.pc`, `fp`, 스택 포인터)를 일반화해 여러 스택을 오가게 하면 `Fiber`가 된다.

### 3.5 둘이 만나는 지점: 상호작용 매트릭스

| 상황 | 규칙 | 근거/위험 |
| --- | --- | --- |
| fiber 안에서 `gen.next()` | 허용. generator 프레임은 소비자 스택, 즉 fiber 스택 위에 복사된다 | generator 지역 보존 버그(학습 문서 2.4)는 2026-11-04에 `RET_Y`가 프레임을 힙에 되저장하도록 고쳤다 |
| generator 본문에서 `suspend` 또는 `await()` | 허용. fiber 전체가 멈추고 generator는 `running`으로 남는다 | 프레임이 fiber 스택에 있는 채로 멈추므로 안전하다. `yield`는 값, `suspend`는 양보라 두 키워드가 구별된다 |
| 멈춘(`running`) generator를 다른 fiber가 `next()` | panic: "Generator is already running." | 재진입 검사가 필요하다(Python의 `ValueError: generator already executing`와 같음) |
| `generator` 함수를 `fiber g()`의 진입점으로 | 컴파일 에러 | 역할 규칙 위반 |
| `suspend 1` | 파스 에러 | 값은 generator의 `yield`만 싣는다 |
| generator 밖의 `yield` | 컴파일 에러 | `yield`는 generator 본문에서만 |
| `fiber:` 블록이 스택 지역을 캡처 | 컴파일 에러. `^T`만 캡처 | 아래 빌림 규칙과 같은 이유 |
| 끝난 fiber의 `resume()` | `.done` 반환, panic 없음 | generator의 `next()`가 `none`을 돌려주는 것과 대칭 |
| 루트 맥락(어느 fiber도 아님)의 `suspend` | CLI에서는 no-op. 임베딩이 켜 두면 eval이 `CL_YIELD`로 나온다(선택) | 길 2의 저장 · 복원 코드를 그대로 쓴다 |
| fiber 스택의 값을 다른 fiber가 빌림 | 컴파일 에러(sema). 힙(`^T`)으로만 공유 | fiber 스택은 성장할 때 이동한다. 포인터 레이아웃 패치는 자기 스택 안의 포인터만 고친다 |
| `.host` 프레임을 넘는 `suspend` | panic: "Cannot suspend across a host call." | C 스택이 끼어 있다(Lua의 "attempt to yield across a C-call boundary"와 같음). 호스트 대기는 3.3의 `CL_AWAIT` 경로로만 |
| fiber 안의 panic | 같은 스레드의 모든 fiber 종료(upstream 문서) | 현재 panic 경로가 `freeHeapPages`로 힙 전체를 비우므로 규칙과 맞다 |
| 진행 중인 fiber의 소멸 | panic: "Fiber is still in progress."(upstream 문서) | 구조적 수명. 취소를 넣는다면 여기서 정리 코드를 돌리는 쪽으로 확장 |
| `cl_vm_interrupt` · fuel | 스레드 단위 플래그와 카운터를 fiber들이 공유 | 검사점(역방향 `JUMP`, `CALL` 계열)은 그대로 둔다 |
| 스택 트레이스 · unwind | 프레임 종류가 `.gen`, fiber 경계 둘로 늘어난다 | `.gen` 쪽에 이미 결함이 3개 있다(학습 문서 2.5). fiber를 넣기 전에 먼저 고친다 |
| C AOT 백엔드(`cgen.zig`) | 둘 다 미지원(옛 `coyield` 주석만 있음) | generator는 C 상태 기계로 낮출 수 있다. fiber는 ucontext나 어셈블리 전환이 필요하다. AOT의 fiber는 범위 밖으로 둔다 |

---

## 4. Pros vs Cons

| 장점 | 단점 |
| --- | --- |
| 각 용도에 맞는 비용: 시퀀스는 ~146 B, 대기는 스택 하나 | 개념이 하나 늘어난다. "언제 무엇을"을 문서와 컴파일 에러로 가르쳐야 한다 |
| 에이전트 스크립트(LLM이 작성)에 색 없는 대기를 제공 | 프레임 종류가 늘어나 트레이스 · unwind · 디버거 코드가 복잡해진다 |
| generator는 정적 타입 그대로 유지. fiber는 값을 싣지 않아 effect 문제를 피함 | 상호작용 매트릭스(3.5)만큼 테스트가 필요하다 |
| Future가 Thread · Fiber · 호스트를 잇는 공통 대기 수단이 된다 | Future.await의 의미가 맥락에 따라 달라진다(spin / yield / 호스트 탈출) |
| 길 2를 거쳐 단계적으로 갈 수 있어 중간 산출물이 바로 쓸모 있다 | upstream이 멈춰 있어 fork가 유지 부담을 전부 진다 |
| upstream 문서 설계와 호환된다 | fiber 스택 성장과 빌림 규칙은 새 sema 규칙이 필요하다(Sendable과 비슷한 수준) |

---

## 5. 예제 코드 (결정된 문법. 5.1 · 5.3은 구현됨, 5.2는 2026-11-12 구현(호스트 루프의 이름은 `cyber.h`를 따른다), fiber의 `await`가 양보하는 5.4는 미구현)

### 5.1 요구사항: 값을 조금씩 내는 쪽은 generator만 쓴다

~~~cy
generator fn countdown(n int) -> int:
    while n > 0:
        yield n
        n -= 1

for countdown(3) |x|:
    print(x)                    --> 3, 2, 1

-- 재귀 순회. 위임 문법(yield*)은 두지 않고 루프로 넘긴다.
type Tree:
    val  int
    kids []^Tree

generator fn walk(t ^Tree) -> int:
    yield t.val
    for t.kids |k|:
        for walk(k) |v|:
            yield v

-- 외부 상태를 구조체로 두면 중단한 자리에서 다시 시작할 수 있다.
type Cursor:
    i int

generator fn chunks(c ^Cursor, paths []str) -> str:
    while c.i < paths.len():
        yield paths[c.i]
        c.i += 1
~~~

### 5.2 요구사항: 기다리는 쪽은 색이 없는 일반 함수다

~~~cy
-- tool()은 #[bind] 호스트 함수이고 Future[str]을 돌려준다.
fn summarize(path str) -> str:
    text := tool('read_file', path).await()     -- 두 단계 깊이의 대기. 시그니처는 그대로
    return tool('llm', 'summarize: ' + text).await()

fn main():
    gen := chunks(^Cursor{i=0}, files)
    while gen.next() |p|:
        print(summarize(p))
~~~

~~~c
/* 호스트. 루트 맥락이 Future에서 멈추면 eval이 CL_AWAIT로 빠져나온다. */
CLResultCode r = cl_vm_eval(vm, uri, src, cfg, &res);
while (r == CL_AWAIT) {
    CLFuture* f = cl_vm_pending_future(vm);   /* 스크립트가 기다리는 Future */
    run_tool(f);                              /* LLM · 도구 호출. 다른 스레드여도 된다 */
    cl_future_complete(vm, f, &value);
    r = cl_vm_resume(vm, &res);               /* 멈춘 pc에서 이어 실행 */
}
~~~

### 5.3 요구사항: 같은 힙에서 여러 맥락을 교차 실행한다

~~~cy
log := ^Array[str]{}

fn worker(name str, log ^Array[str]):
    for 0..3 |i|:
        log << '$(name) $(i)'
        suspend                         -- 값 없이 양보만

a := fiber worker('a', log)             -- 인자는 지금 평가, 본문은 첫 resume에서 시작
b := fiber worker('b', log)
while a.status() != .done or b.status() != .done:
    _ = a.resume()                      -- 반환값(FiberStatus)은 버릴 수 없다
    _ = b.resume()
-- log: a 0, b 0, a 1, b 1, a 2, b 2

-- 블록 형태. 한 번 쓰고 버리는 단계 작업에 쓴다. ^T만 캡처할 수 있다.
t := fiber:
    print('step 1')
    suspend
    print('step 2')
_ = t.resume()                          --> step 1
_ = t.resume()                          --> step 2
~~~

### 5.4 요구사항: Future가 Thread · Fiber · 호스트를 잇는 공통 대기 수단이다

~~~cy
fn fetch_all(urls []str, out ^Array[str]):
    for urls |u|:
        out << http.get(u).await()      -- fiber 안: 멈추고 양보. 루트: 호스트로 탈출. 스레드: 지금처럼

out := ^Array[str]{}
f1 := fiber fetch_all({'a', 'b'}, out)
f2 := fiber fetch_all({'c'}, out)
run_all(^Array[Fiber]{f1, f2})          -- 5.5의 이디엄 1
~~~

### 5.5 자주 쓸 이디엄

~~~cy
-- 1. 가장 작은 스케줄러: 라운드 로빈. 살아 있는 fiber가 없으면 끝난다.
fn run_all(fs ^Array[Fiber]):
    while:
        alive := false
        for fs |f|:
            if f.resume() == .suspended:
                alive = true
        if not alive:
            break

-- 2. 긴 계산의 공정성. 색이 없으므로 어떤 헬퍼에서든 양보할 수 있다.
fn crunch(data []int) -> int:
    sum := 0
    for data |x|:
        sum += x
        if sum % 4096 == 0:
            suspend
    return sum

-- 3. 결과 전달은 Future로. fiber는 값을 싣지 않는다.
r := FutureResolver(int)
done := r.future()
w := fiber:
    r.complete(crunch(data))
run_all(^Array[Fiber]{w})
print(done.await())

-- 4. generator는 for로, 멈춤 · 재개가 필요하면 next()로.
for walk(tree) |v|: print(v)
gen := walk(tree)
first := gen.next().?                   -- 나머지는 나중에
~~~

### 5.6 특이 케이스와 진단

~~~cy
-- fiber 안에서 generator 소비: 허용. 프레임은 fiber 스택 위에 복사된다.
f := fiber:
    for walk(tree) |v|: print(v)

-- generator 본문의 await · suspend: 허용. 소비하는 fiber 전체가 멈추고 generator는 running으로 남는다.
generator fn lines(path str) -> str:
    text := tool('read_file', path).await()
    for text.split('\n') |l|:
        yield l                         -- 값
        suspend                         -- 양보

-- 멈춘 generator를 다른 fiber가 재진입: 실행 시 panic.
gen := ^lines('big.txt')                -- fiber: 블록은 ^T만 캡처한다
a := fiber:
    gen.next()                          -- await에서 a가 멈춘다. gen.status() == .running
b := fiber:
    gen.next()                          -- panic: Generator is already running.

-- 역할 위반: 컴파일 · 파스 에러.
f := fiber countdown(3)                 -- CompileError: A generator cannot be a fiber entry.
suspend 1                               -- ParseError: `suspend` takes no value. Use `yield` in a generator.
fn h() -> int:
    yield 1                             -- CompileError: `yield` is only allowed in a generator.

-- 스택 빌림을 fiber 경계 너머로: 컴파일 에러. fiber 스택은 성장할 때 이동한다.
n := 1
f := fiber bump(&n)                     -- CompileError: Cannot borrow a stack value across fibers. Use ^T.

-- 호스트 프레임을 넘는 양보: 실행 시 panic. C 스택이 끼어 있다.
host_each(items, |x| suspend)           -- panic: Cannot suspend across a host call.

-- 진행 중인 fiber의 소멸: upstream 문서 그대로.
fn forever():
    while: suspend
f := fiber forever()
f.resume()
-- 블록 끝 --> panic: Fiber is still in progress.
~~~

---

## 6. 로드맵 (제안)

| 단계 | 내용 | 바로 얻는 것 | 선행 조건 |
| --- | --- | --- | --- |
| 0 | generator 지역 보존 수정(`RET_Y`에서 프레임 저장, 2026-11-04 완료), `.gen` 트레이스 결함 3개 수정(2026-11-04 완료) | 지금 있는 stackless가 믿을 만해짐 | 없음 |
| 1 | 루트 맥락 중단 · 재개(`CL_AWAIT`, `cl_vm_resume`, 호스트 Future C API. 2026-11-12 완료. fiber 안의 await도 탈출한다) | 에이전트 루프의 색 없는 도구 대기 | 0 권장 |
| 1.5 | 문법 정리: `generator fn`으로 `#[generator]` 대체, `.paused` → `.suspended`(둘 다 2026-11-11 완료). 런타임 변경 없음 | 선언 머리에 역할이 보인다. fiber 문법과 어휘를 맞춘다 | 없음 |
| 2 | `fiber f(args)` · `fiber:` · `suspend` 키워드, `Fiber` 타입: 스택 교체, 성장, 트레이스의 fiber 경계, 빌림 sema 규칙(2026-11-11 완료. 단계 1 없이 구현) | 같은 힙에서 여러 실행 맥락 | 1, 1.5 |
| 3 | fiber 안의 `Future.await()`를 yield로, 비-main 스레드 await를 같은 경로로 | `@panic("TODO")` 제거, 스레드마다 협력 스케줄링 | 2 |
| 4 | (선택) 취소(소멸 시 정리), `spawn f(args)` 호출식 꼴, `Future.wait_any` | 구조적 동시성, 생성 표기 통일, spin 없는 스케줄러 | 2 |

단계 1까지만 해도 이 fork의 두 용도(스크립트 CLI, 에이전트 루프)는 충족된다. 단계 2 이상은 한 VM에서 여러 스크립트를
교차 실행해야 할 때 진행한다.

---

## 7. 영향과 현재 상황

- 업계는 "하나로 통일"보다 "역할 분리 + 공통 대기 인터페이스" 쪽으로 수렴하고 있다. Go의 `iter.Pull`(stackful 위의 가벼운 전환),
  Ruby의 Fiber Scheduler, Java Loom(virtual thread)과 그대로 남은 `Iterator`, Zig `std.Io`가 그 예다.
- 원리적인 통합은 effect handler(OCaml 5, Koka, Unison)다. generator · async · fiber가 모두 effect 하나로 표현된다.
  Cyber에 이것을 넣는 일은 타입 시스템 수준의 결정이라 이 문서의 범위 밖이다. 다만 3.2의 "fiber는 값을 싣지 않는다" 규칙은
  나중에 effect를 도입할 때 막히지 않는 방향이다.
- 이 저장소의 현재 상태: generator는 구현됐고 지역 보존 버그는 2026-11-04에 고쳤다. Fiber는 2026-11-11에 구현했다.
  `CL_AWAIT`는 2026-11-12에 구현했다. C AOT 백엔드는 둘 다 지원하지 않는다.

## 8. 결론

- 둘 다 갖는다(2026-11-07 결정). 역할 분리 병존(방식 A)으로 한다. generator는 값, fiber는 대기를 맡는다.
- 멈춤은 키워드다. generator는 `yield v`, fiber는 `suspend`. `suspend`는 값을 싣지 않는다. 정적 타입과 충돌하지 않게 하는 핵심 장치다.
- 선언 · 생성도 키워드다. `generator fn f(...) -> T:`가 `#[generator]`를 대체하고(2026-11-11 구현), `fiber f(args)` · `fiber:`가 `Fiber(f, {args})`를 대체한다.
- 위임 문법(`yield*`)은 두지 않는다. `for inner() |v|: yield v` 두 줄이 명시적이다.
- Future를 공통 대기 인터페이스로 삼고, "루트 fiber가 호스트에 yield하기"(길 2)부터 만든다. 그 코드가 그대로 `Fiber`의 기반이 된다.
- 먼저 할 일은 새 모델이 아니라 기존 generator를 고치는 것이다(단계 0).
