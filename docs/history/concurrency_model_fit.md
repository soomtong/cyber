# 동시성 모델 고르기: "어느 것이 좋은가"보다 "무엇이 나에게 맞는가"

2026-11-03 작성. 사실 근거는 `coroutines_concurrency.md`, `docs/decisions/project_coroutines.md`,
`docs/decisions/project_vm_interrupt.md`, `docs/study/07-coroutines-concurrency.md`이다. 이 문서는 새 사실을 더하지 않는다.
판단 틀을 세우고 그 틀에 이 fork의 두 용도(스크립트 CLI, TARS 에이전트 루프)를 대입한다.

---

## 1. 개요

0.3 → 0.4 사이에 나온 단어들(Fiber, Future, Stackful, Stackless, Generator, Thread, await)은 **같은 축 위의 선택지가 아니다**.
그래서 "Fiber가 좋은가, Future가 좋은가"는 질문 자체가 성립하지 않는다. 먼저 단어를 축별로 나눠야 한다.

| 축 | 묻는 것 | 선택지 |
| --- | --- | --- |
| A. 멈춤의 저장 방식 | 멈춘 실행을 어디에 보관하나 | **stackful**(스택 전체) / **stackless**(프레임 하나 또는 상태 기계) |
| B. 스케줄링 | 누가 다음 실행을 고르나 | **협력형**(코드가 명시적으로 양보: coroutine) / **선점형**(런타임·OS가 끊음: thread) |
| C. 병렬성 | 실제로 동시에 CPU를 쓰나 | 단일 스레드 교차 실행 / 다중 코어 병렬 |
| D. 결과 전달 | 값을 어떻게 돌려받나 | 직접 반환(resume의 값) / **Future**(값의 자리표) / 채널 / 콜백 |
| E. 메모리 공유 | 실행 맥락끼리 힙을 공유하나 | 공유 / **격리**(복사로만 통신) |

용어를 이 축에 놓으면 이렇다.

| 용어 | A | B | C | D | E |
| --- | --- | --- | --- | --- | --- |
| Fiber (0.3, 문서상의 새 `Fiber`) | stackful | 협력 | 단일 | resume 반환값 | 공유 |
| Generator (0.4 `#[generator]`) | stackless | 협력 | 단일 | `next()` 반환값 | 공유 |
| Thread (0.4 `spawn`) | 각자 스택(성장형) | 선점(OS 워커) | 병렬 | **Future** | 격리 |
| Future (0.4 `Future[T]`) | — | — | — | 값의 자리표 | — |
| async/await (중간기 키워드) | stackless(가 보통) | 협력 | 단일 | Future | 공유 |

핵심은 두 가지다.

1. **Future는 실행 모델이 아니다.** "언젠가 채워질 값"을 표현하는 프로토콜이다. 그 값을 채우는 주체가 스레드든 fiber든
   호스트든 상관없다. 0.4에서 Future가 Thread와 같이 나오는 것은 결합일 뿐, 같은 개념이 아니다.
2. **stackful / stackless는 "어디서 멈출 수 있는가"를 결정한다.** 이것이 사용 경험을 가르는 가장 큰 차이다.
   stackful은 호출 깊이 어디서든 멈추고, stackless는 표시된 함수 본문에서만 멈춘다.

---

## 2. 핵심 디자인: Cyber 0.3 → 0.4에 대입

### 2.1 무엇이 어떻게 갈라졌나

~~~text
0.3 (2023-12)                          0.4.2 (현재)
┌─────────────────────────────┐        ┌───────────────────────────────────────────┐
│ fiber 하나가 모든 역할       │        │ 값을 조금씩 내기   → #[generator] (stackless) │
│  - 값을 조금씩 내기          │  ───▶  │ 독립 실행·병렬     → spawn + Thread (격리 힙)  │
│  - 독립 실행 맥락            │        │ 결과 받기          → Future[T].await()        │
│  - 호출 깊이 중간 yield      │        │ 같은 힙 stackful   → Fiber  (문서만, 미구현)  │
│  stackful, 동적 타입         │        │ 호스트 경계 대기   → (없음)                   │
└─────────────────────────────┘        └───────────────────────────────────────────┘
~~~

- 0.3 fiber: `coinit` / `coresume` / `coyield`. 자기 스택과 pc를 가진 **비대칭 stackful 코루틴**(resume한 쪽으로만 돌아감).
  전환은 {스택 포인터, 길이, pc, fp} 교환이라 O(1). 호출 깊이 어디서든 `coyield` 가능.
- 중간기(2024-05): `await` 키워드 + `Future` + `queueTask`. 단일 스레드 태스크 큐. "colorless async"를 표방.
- 0.4 (2025-11 `b751ca6c`): 키워드 4개 삭제, `yield` 하나 추가. 역할을 **더 싼 것(generator)** 과 **더 격리된 것(Thread)** 으로 나눔.
  그 사이의 "같은 힙을 공유하는 stackful 코루틴" 자리는 비어 있다.

### 2.2 왜 갈랐나 (해석)

- **정적 타입 전환.** `coresume`은 아무 값이나 돌려줬다(`dyn`). 정적 타입에서는 결과 타입을 시그니처에서 유도해야 하고,
  generator는 `?(type.fn_ret(Fn))`으로 이를 해결한다.
- **소유권/빌림.** stackful fiber의 스택에 있는 값을 다른 맥락이 빌리면, 스택이 이동할 때 그 주소를 고쳐야 한다.
  격리된 Thread는 아예 복사(`@send`)로 이 문제를 없앤다.
- **비용 정리.** 가벼운 쪽은 프레임 하나만, 무거운 쪽은 독립 힙. 중간(별도 스택 + 공유 힙)이 가장 구현이 까다롭다.

### 2.3 현재 구현 상태에서 알아 둘 함정

| 모델 | 함정 | 출처 |
| --- | --- | --- |
| Generator | 본문 지역 변수가 `yield`를 넘어 보존되지 않음(매개변수만 힙 스냅샷). 루프 카운터 오염, 관리 타입이면 segfault 가능 | 학습 문서 2.4 |
| Generator | 호출 깊이 중간 yield 불가, `yield*` 위임 TODO, `next(arg)`로 값 되받기 없음 | 2.4, 6.2 |
| Thread | 보낼 수 있는 타입이 `int` 계열과 `str`뿐. 연달아 spawn하면 직렬화될 수 있음 | 2.6 |
| Future | main 스레드 `await`는 spin, 비-main 스레드 `await`는 `@panic("TODO")`로 호스트 abort | 2.6 |
| Fiber | 소스에 없음. `src/fiber.zig`는 import되지 않는 잔재 | `project_coroutines.md` |

---

## 3. 판단 틀: 일곱 개의 질문

모델의 우열은 아래 질문에 대한 **당신의 답**으로 정해진다. 위에서부터 답하면 대부분 3번 안에 결론이 난다.

| # | 질문 | 답 → 기울어지는 쪽 |
| --- | --- | --- |
| Q1 | 왜 멈추는가? | 값을 하나씩 낸다 → **generator** · 외부(I/O, 호스트, 사람)를 기다린다 → **stackful 또는 VM 중단** · CPU를 더 쓰고 싶다 → **thread** |
| Q2 | 멈추는 지점이 어디인가? | 한 함수 본문 안 → stackless로 충분 · 헬퍼/재귀/남이 쓴 코드 안 → **stackful 필수** |
| Q3 | 누가 그 코드를 쓰는가? | 내가(멈춤 지점을 통제) → stackless 감당 가능 · 사용자·LLM(통제 불가) → **함수 색이 없는 모델** |
| Q4 | 상태를 공유하나? | 같은 객체를 함께 고친다 → 같은 힙(generator/fiber) · 입력→출력만 → 격리(thread) |
| Q5 | 동시에 몇 개가 살아 있나? | 수백만 → stackless(객체 ~146 B/개) · 수천 → stackful도 무방 · 코어 수 → thread |
| Q6 | 누가 재개하나? | 스크립트 자신 → 코루틴 · 호스트(C/Zig) → **VM 수준 중단/재개 API** · OS → thread |
| Q7 | 취소·시간 상한이 필요한가? | 필요 → 검사점이 있는 모델(`cl_vm_interrupt`/fuel은 모든 스레드에 전파됨, 단 호스트 함수 내부는 못 끊음) |

Q2와 Q3가 결정적이다. **"멈춤 지점을 내가 통제하는가"** 가 stackless를 쓸 수 있는지의 경계선이다.
JS·Python·Rust가 stackless + `async`를 택하고 "함수 색"을 감수한 것은, 라이브러리 작성자가 멈춤 지점을 통제한다는 전제가 있기 때문이다.
Lua·Go·Java Loom이 stackful을 택한 것은 그 전제를 버렸기 때문이다.

---

## 4. 당신의 용도에 대입

`project_direction.md`가 적은 두 용도와, 언어 설계자로서의 세 번째 관점을 따로 본다.

### 4.1 용도 A: Python · Perl · Shell 대체 스크립트 CLI

| 질문 | 답 |
| --- | --- |
| Q1 | 주로 지연 시퀀스(파일 줄, 디렉터리 순회), 가끔 병렬 작업 |
| Q2 | 대부분 한 함수 안. 재귀 디렉터리 순회는 예외 |
| Q3 | 내가 쓴다 |
| Q4 | 병렬 작업은 입력→출력이 대부분 |
| Q6 | 스크립트 자신 |

**맞는 모델: generator + spawn/Future. Fiber는 필요 없다.** 0.4의 분리가 이 용도에는 오히려 잘 맞는다.
단, generator 지역 변수 버그가 고쳐지기 전까지는 **상태를 힙 객체(매개변수)에 두는 패턴**만 쓴다. 재귀 순회는 stackless의 약점이라
generator 안에서 재귀 호출을 yield로 이을 수 없으므로(`yield*` 미구현) 명시적 스택(리스트)으로 평탄화한다.

### 4.2 용도 B: TARS 에이전트 루프 (CodeAct)

| 질문 | 답 |
| --- | --- |
| Q1 | **외부를 기다린다**(도구 호출, LLM 응답) |
| Q2 | LLM이 만든 헬퍼 함수 안, 반복문 안, 어디서든 |
| Q3 | **LLM이 쓴다** — 멈춤 지점을 통제할 수 없다 |
| Q4 | 같은 VM 상태(`persist_main` 변수)를 이어 쓴다 |
| Q6 | **호스트**가 결과를 넣고 재개 |
| Q7 | 필수(fuel, interrupt) |

**맞는 모델: stackful. 정확히는 "VM 하나 = 암묵적 fiber 하나"인 VM 수준 중단.**

- generator는 Q2·Q3에서 탈락한다. LLM이 `fn summarize(path): tool('read', path)`처럼 헬퍼를 만들면 그 안에서 멈출 수 없다.
  모델에게 "도구는 `#[generator]` 본문 최상위에서만 부르라"고 가르치는 것은 함수 색을 프롬프트로 떠넘기는 일이다.
- Thread + Future는 Q4·Q6에서 탈락한다. 상태가 복사로만 오가고, 호스트가 Future를 완료시킬 C API가 없으며, main의 await는 spin이다.
- 학습 문서 6.4의 다섯 길 중 단계적 처방:
  1. **지금**: 길 1(동기 호스트 함수 + VM당 OS 스레드). 코루틴 없이 동작한다. 취소는 interrupt/fuel + 도구 함수 자체 타임아웃.
  2. **다음**: 길 2(`CALL_HOST`에서 `RES_AWAIT`로 빠져나가고 `cl_vm_resume`으로 재개). VM 스택이 이미 힙에 있고 `CL_AWAIT` 결과 코드가
     ABI에 있으므로 변경이 작다. 이것은 **WebAssembly JSPI나 Lua의 C 경계 yield와 같은 모양**의 stackful 중단이다. 멈출 수 있는 깊이는 무제한이고
     LLM 코드에 색이 없다.
  3. **필요해지면**: 길 3(같은 힙 위의 여러 `Fiber`). 한 VM 안에서 여러 에이전트 스크립트를 교차 실행해야 할 때만.

### 4.3 관점 C: 언어 설계자로서 Cyber의 정체성

이 fork가 언어를 직접 설계하겠다고 했으므로(`project_direction.md`), 마지막 질문은 "Cyber가 어느 진영의 언어인가"이다.

| 선택 | 따라오는 것 |
| --- | --- |
| stackless만 (현재) | 정적 타입·소유권과 잘 맞음. 대신 "colorless"라는 0.3·중간기의 약속을 사실상 포기. 임베딩 스크립트 언어로서의 강점(Lua가 가진 것)을 잃음 |
| stackful 재도입 | 스택 이동 시 빌림 무효화 문제를 sema 규칙(fiber 경계를 넘는 빌림 금지)으로 풀어야 함. Go의 스택 복사 + 포인터 맵과 같은 길이고, 이 VM은 이미 포인터 레이아웃으로 스택을 패치함 |
| 둘 다 (generator는 지역 시퀀스용, Fiber는 대기용) | Lua·Python 양쪽 강점. 개념이 하나 늘지만 역할이 겹치지 않으면 비용은 작다 |

임베딩 스크립트 언어라는 용도를 고려하면 **"generator(값 생성) + VM/Fiber 중단(대기) + Thread(병렬)"의 세 갈래**가 가장 자연스럽다.
각 도구가 Q1의 세 답에 하나씩 대응하기 때문이다.

---

## 5. Pros vs Cons

### 5.1 일반론

| 모델 | 장점 | 단점 |
| --- | --- | --- |
| Stackful coroutine / Fiber | 호출 깊이 어디서든 멈춤, 함수 색 없음, 기존 동기 코드를 그대로 재사용 | 맥락마다 스택 메모리, 스택 성장·이동 시 포인터 문제, C/호스트 프레임을 넘는 yield 불가, 디버거·트레이스가 복잡 |
| Stackless generator | 객체가 작음(프레임 하나), 정적 타입과 잘 맞음, 구현 경계가 명확 | 함수 색, 중간 호출 yield 불가(위임 문법 필요), yield를 넘는 지역 저장이 설계의 핵심 난제 |
| Future / Promise | 결과 전달을 실행 모델과 분리, 조합(all/race)·취소 설계 여지 | 혼자서는 아무것도 실행하지 않음, 완료 주체가 없으면 영원히 대기, 콜백 체인 시 가독성 저하 |
| Thread (격리 힙) | 진짜 병렬, 데이터 레이스 없음, 패닉 격리 | 통신이 복사뿐, 생성 비용(µs 단위), 공유 상태 패턴 불가 |
| async/await (stackless + Future) | 대기 지점이 코드에 보임, 수많은 동시 대기를 싸게 | 함수 색이 콜 그래프 전체로 전염, 동기 라이브러리와 이중화 |

### 5.2 Cyber 현재 상태 기준

| 축 | 0.3 fiber | 0.4 generator | 0.4 Thread + Future | (제안) VM 중단 |
| --- | --- | --- | --- | --- |
| 중간 호출 멈춤 | ○ | × | — | ○ |
| 함수 색 | 없음 | 있음 | await는 없음 | 없음 |
| 메모리 / 맥락 | 88 B + 스택 | ~146 B (실측) | 4 KB 스택 + 힙 | VM 하나 |
| 전환 비용 | O(1) 포인터 교환 | `next()` ~30 ns | spawn+await ~2 µs | VM 재진입 |
| 정적 타입 적합 | × (`dyn`) | ○ | ○ | ○ |
| 호스트가 재개 | 미확인 | × | × | ○ |
| 구현 상태 | 삭제 | 지역 보존 버그 | 비-main await abort | 미구현(경로는 있음) |

---

## 6. 예제 코드

### 6.1 0.3 fiber: 호출 중간 yield (현재 파서는 받지 않음)

~~~cy
func foo():
    print 'foo'
    bar()
func bar():
    coyield          -- foo → bar 깊이에서 멈춘다
    print 'bar'
var fiber = coinit(foo)
coresume fiber       -- 'foo' 출력 후 bar 안에서 멈춤
coresume fiber       -- 'bar' 출력
~~~

### 6.2 0.4 generator: 지금 안전한 패턴

~~~cy
-- 상태를 힙 객체 매개변수에 둔다. 본문 지역 변수를 yield 너머로 쓰지 않는다.
type Counter:
    i int

#[generator]
fn count_to(c ^Counter, n int) -> int:
    while c.i < n:
        yield c.i
        c.i += 1

gen := count_to(^Counter{i=0}, 3)
while gen.next() |v|:
    print(v)         -- 0 1 2
~~~

지역 변수로 쓰면 학습 문서 2.4의 버그에 걸린다.

~~~cy
#[generator]
fn bad() -> int:
    i := 10          -- 소비자 스택에만 산다
    yield i
    i += 1           -- 다음 next() 때 다른 값을 읽을 수 있다
    yield i
~~~

### 6.3 0.4 Thread + Future

~~~cy
fn work(n int) -> int:
    sum := 0
    for 0..n |i|:
        sum += i
    return sum

a := spawn(work, {1000000})   -- 인자는 @send로 대상 스레드 힙에 복사
b := spawn(work, {2000000})
print(a.await() + b.await())  -- main에서 spin-wait
~~~

### 6.4 왜 에이전트 루프에 stackless가 맞지 않는가

~~~cy
-- LLM이 생성한 스크립트. tool()은 호스트 함수.
fn summarize(path str) -> str:
    text := tool('read_file', path)     -- 여기서 호스트 대기가 필요
    return tool('llm', 'summarize: ' + text)

for files |f|:
    print(summarize(f))                 -- 두 단계 깊이의 대기
~~~

- generator: `summarize` 안에서 yield할 수 없다. 스크립트 전체를 generator로 바꾸고 헬퍼를 없애라고 LLM에게 강요해야 한다.
- VM 중단(길 2): `tool()`이 `CL_AWAIT`로 eval을 빠져나가고, 호스트가 결과를 쓰고 `cl_vm_resume`하면 그대로 이어진다. 스크립트는 바꿀 필요가 없다.

### 6.5 문서에만 있는 새 Fiber (참고, 미구현)

~~~cy
fn two_steps():
    print('one')
    Fiber.yield()
    print('two')

f := Fiber(two_steps, {})
f.resume()     -- one
f.resume()     -- two
~~~

---

## 7. 역사, 이후 설계에 미친 영향, 현재 상황

### 7.1 계보

| 시기 | 사건 | 남긴 것 |
| --- | --- | --- |
| 1958–63 | Melvin Conway, "coroutine" (COBOL 컴파일러) | 대칭적 협력 실행의 원형 |
| 1967 | Simula 67 `detach` / `resume` | 객체 + 코루틴 = 시뮬레이션 프로세스 |
| 1975 | CLU iterator | stackless generator의 원형 (→ Python, C#, JS) |
| 1976–77 | Friedman & Wise "promise", Baker & Hewitt "future" | 값의 자리표 개념 |
| 1985 | Multilisp `future` (Halstead) | 병렬 평가와 future의 결합 |
| 2001 | Python 2.2 generator (PEP 255) | `yield`를 대중화 |
| 2003–04 | Lua 5.0 비대칭 stackful coroutine, "Revisiting Coroutines" (de Moura, Ierusalimschy) | 비대칭 stackful이 one-shot continuation과 같은 표현력임을 정리 |
| 2007–12 | F# async workflow → C# 5 `async`/`await` | stackless 상태 기계 + Task |
| 2009 | Go goroutine | 성장형(복사) 스택의 stackful + 선점 스케줄러 |
| 2015 | Bob Nystrom, "What Color is Your Function?" | 함수 색 문제의 이름 |
| 2015–19 | Python 3.5 `async def`, ES2017, Rust 1.39 `async` | stackless + Future가 주류가 됨 |
| 2020 | C++20 코루틴 (stackless) | 반면 Boost.Context 등 stackful 라이브러리는 계속 병존 |
| 2023 | Java 21 virtual thread (Loom), Zig 0.11에서 `async` 제거 | **stackful로의 회귀**, "함수 색 없는 대기" 재평가 |
| 2025 | Zig `std.Io` 인터페이스 재설계 | "async는 concurrency가 아니다" — 실행 모델을 인터페이스 뒤로 숨김 |

### 7.2 Cyber의 궤적은 업계 흐름의 축소판이다

- 0.3: Lua형(stackful, 동적 타입, 임베딩 스크립트).
- 중간기: JS/Python형(`await` 키워드 + Future + 단일 스레드 큐).
- 0.4: Python형 generator + Dart isolate형 Thread(독립 힙, 메시지 복사).
- 비어 있는 자리: Loom·Go·Lua가 다시 증명한 "색 없는 대기". Zig가 `async`를 버리고 `Io` 인터페이스로 실행 모델을 숨긴 것도 같은 문제의식이다.

### 7.3 현재 상황 요약

- upstream은 2025-11 이후 멈춰 있고 교체가 끝나지 않았다.
- 이 fork는 generator · Future 쪽 누수와 interrupt 전파를 고쳤다. generator 지역 보존 버그와 비-main await는 남아 있다.
- 호스트 경계 대기 수단은 없다. `RES_AWAIT` → `CL_AWAIT` 경로만 끝까지 이어져 있고 만드는 곳이 없다.

---

## 8. 결론: 질문 하나로 줄이면

> **"멈춤 지점을 쓰는 사람이 나인가, 아닌가?"**

- 나라면(스크립트 CLI): stackless generator로 충분하다. 0.4가 맞다.
- 내가 아니라면(LLM이 쓰는 에이전트 스크립트, 사용자 플러그인): stackful이 필요하다. 0.3의 fiber가 하던 일이고,
  가장 작은 구현은 VM 수준 중단(길 2)이다.
- 병렬 CPU 작업은 이 질문과 무관하게 Thread다.

우열이 아니라 **역할 배정**의 문제다. 0.4는 역할을 나눴고, 이 fork의 용도에서는 그중 한 칸(색 없는 대기)이 비어 있다.
