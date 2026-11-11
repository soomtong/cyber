# 0.4.6 이후 변경 (미릴리스)

0.4.6(2026-11-11) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

## 언어와 표준 라이브러리

- 제너레이터 선언이 `#[generator]` 속성에서 `generator fn` 선언으로 바뀌었다. 호환되지 않는 변경이다.
  ```cy
  -- 이전
  #[generator]
  fn count() -> int:
      yield 1

  -- 이후
  generator fn count() -> int:
      yield 1
  ```
  - `generator`는 예약어가 아니다. 바로 뒤에 `fn`이 올 때만 수식어이고, 그 밖에는 이름으로 쓸 수 있다.
  - 숨김 선언은 `-generator fn`, 속성은 수식어 앞에 둔다(`#[inline] generator fn`).
  - `#[generator]`는 ``ParseError: The `#[generator]` attribute was replaced by `generator fn`.``이다.
  - 오류 문구가 바뀌었다: `` `yield` is only allowed in a `generator fn`. ``,
    ``A `generator fn` can not take the borrow type `&int` as a parameter. ...``
  - `cy` 모듈의 `FuncDecl`에 `generator bool` 필드가 생기고 `AttributeKind.generator`가 없어졌다.
  - tree-sitter 문법에 `generator_fn` 노드를 더했다(`generator fn`이 한 토큰). 속성 형태는 더 이상 제너레이터로 읽지 않는다.
  - 근거와 `generator f()` 대신 `generator fn f()`를 고른 이유는 `docs/decisions/project_coroutines.md`의
    "선언 모양 변경과 구현 (2026-11-11)" 절.
- `GeneratorStatus.paused`가 `GeneratorStatus.suspended`로 바뀌었다. 호환되지 않는 변경이다. `suspend` → `.suspended` → `resume()`이
  한 어휘가 된다.
- Fiber를 구현했다. 키워드 `fiber` · `suspend`가 새로 예약어가 된다(이 이름의 변수 · 함수는 더 쓸 수 없다).
  ```cy
  fn worker(name str, log ^ArrayStore[str]):
      for 0..2 |i|:
          log << '%{name} %{i}'
          suspend

  log := ^ArrayStore[str]{}
  a := fiber worker('a', log)     -- 인자는 지금 평가, 호출은 첫 resume에서
  b := fiber worker('b', log)
  while a.status() != .done or b.status() != .done:
      _ = a.resume()
      _ = b.resume()
  -- log: a 0, b 0, a 1, b 1

  t := fiber:                     -- 본문을 받는 형태. 클로저라 `^T` 변수만 캡처한다
      log << 'step'
      suspend
  ```
  - `Fiber`는 자기 스택을 가진 stackful 코루틴이다(512 B에서 시작해 스레드 스택처럼 성장). 같은 스레드의 힙을 공유한다.
  - `suspend`는 값을 싣지 않는 문장이고 호출 깊이 어디서든 쓴다. fiber 밖에서는 아무 일도 하지 않는다.
  - `f.resume() -> FiberStatus`는 `.suspended` 또는 `.done`, 끝난 fiber의 `resume()`은 `.done`. `f.status()`는
    `.suspended` · `.running` · `.done`.
  - 컴파일 오류: `A generator cannot be a fiber entry.`, ``A fiber entry function must return `void`.``,
    ``Cannot borrow a stack value across fibers. The parameter type is `&int`. Use `^T`.``,
    파스 오류: `` `suspend` takes no value. Use `yield` in a generator. ``, ``Expected a function call after `fiber`.``
  - panic: `Fiber is already running.`(자기 자신 또는 자기를 기다리는 fiber를 resume), `Fiber is still in progress.`
    (끝나지 않은 fiber의 소멸. 한 번도 resume하지 않은 fiber도 포함)
  - fiber 안의 panic은 스레드 panic이다. 스택 트레이스는 각 fiber의 `resume` 지점을 거쳐 main까지 이어진다.
  - 제약: 인자는 첫 `resume`에서 호출로 복사되므로 `NoCopy` 타입 매개변수는 안 된다. 진입점은 함수 이름이어야 한다
    (메서드 호출 `fiber obj.work()` 미지원). `Future.await()`는 fiber 안에서도 지금처럼 spin한다(양보하지 않음).
    AOT(C 백엔드)는 미지원.
  - `cy` 모듈의 `Node`에 `fiber_expr` · `suspend_stmt`가 생겼다. tree-sitter 문법에 `fiber_expression` ·
    `suspend_statement`를 더했다.
  - 구현 기록은 `docs/decisions/project_coroutines.md`의 "Fiber 구현 (2026-11-11)" 절.

- `#` · `@` 표기의 경계를 정리했다. 네 가지 모두 호환되지 않는 변경이다.
  - symbol 리터럴은 `symbol.usd`로 쓴다(`error.Name`과 같은 꼴). `@usd`는
    ``CompileError: Undeclared `@usd`. A symbol literal is written `symbol.usd`.``이다. 출력도 `symbol.usd`로 바뀌었다
    (`print(symbol.usd)`, `str(symbol.usd)`. 이전에는 `@usd`). `symbol`이라는 이름의 변수는 타입을 가리므로 그대로 쓸 수 있다.
  - `@`로 시작하는 함수 이름은 hook만 선언할 수 있다: `@init` · `@init_sequence` · `@init_record` · `@deinit` · `@copy` ·
    `@clone` · `@index` · `@set_index` · `@index_addr` · `@slice` · `@get` · `@set` · `@send`. 그 밖의 이름은
    ``CompileError: Unknown hook `@whatever`. ...``이다. 이전에는 일반 메서드로 선언되어 오타 난 hook이 조용히 무시됐다.
  - `#[unsafe]` · `#[consteval]` · `#[reserve]`는 builtin 모듈 전용이다. 스크립트에서 쓰면
    ``CompileError: The `#[consteval]` attribute is reserved for the builtin modules.``
  - builtin 모듈은 `core` · `meta` · `cy` · `c` · `math` · `io` · `test`다. 각 모듈의 bind 함수가 표시하므로 호스트가 소스를
    다른 곳에서 읽어도 같다. `os` · `cli` · `libc`는 스크립트와 같은 규칙을 받는다.
  - 스크립트는 builtin 모듈의 `@` 함수(intrinsic: `@memcpy` · `@bitCast` · `@retain` 등)를 호출하거나 값으로 쓸 수 없다.
    ``CompileError: `@bitCast` is internal to the builtin modules and can not be used in a script.``
    런타임 내부(참조 카운트 · 객체 레이아웃 · VM 명령)를 드러내는 함수들이라서다. hook을 메서드로 부르는 것(`a.@deinit()`)은 그대로 된다.
  - 스크립트에 필요한 기능은 표준 모듈의 일반 이름으로 제공한다. 이번에 더한 것:
    `c.memcpy(dst Ptr[byte], src Ptr[byte], len int)`, `meta.consume(local)`(`sink` 메서드에서 `self`를 `@deinit` 없이 끝냄),
    `meta.enum_from_int(T, val int) -> !T`. enum → 정수는 `int(x)`, `^T` → `Ptr[T]`는 `as[Ptr[T]] r`로 이미 된다.
  - 근거는 `docs/decisions/project_sigils.md`.

## 임베딩 API

## 변경

## 문서
