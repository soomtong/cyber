# 다른 언어의 설계 원칙 검토: 사이버랭이 가져올 것과 두고 갈 것

다른 언어의 설계 원칙을 사이버랭의 현재 설계와 맞대 보는 검토를 모은다. 결정 문서가 아니다.
채택할 항목은 각각 `docs/decisions/`에 결정을 먼저 적은 뒤 구현한다(`project_direction.md`).

언어 하나, 또는 같은 기법을 공유하는 언어 묶음마다 절 하나를 둔다. 절 안은 같은 순서로 쓴다: 출처와 범위, 개요, 핵심 디자인과
사이버의 현재 위치, 가져올 만한 것, 장단점, 영향과 현재 상황, 결정할 것. 다른 절을 가리킬 때는 절 번호를 쓴다(예: 1.4 A).

| 절 | 언어 | 작성 | 계기 |
| --- | --- | --- | --- |
| 1 | Nim 3.0 (Nimony) | 2026-11-15 | 0.5를 앞두고 Araq의 설계 원칙 글 검토 |
| 2 | Nim 2 · Lean 4 · Koka: 마지막 사용 분석 | 2026-11-15 | 개발 과정에서 사이버가 맡을 단계 논의 |

## 1. Nim 3.0 (Nimony)

### 1.1 출처와 범위

- 원문: Araq, "Nimony: Design principles", https://nim-lang.org/araq/nimony.html (2025-05-03, 2025-05-10 수정).
  "a new compiler for a variant of Nim which will become Nim 3.0, eventually"라고 스스로 소개한다.
- 원문은 사양이 아니라 원칙 글이다. 출시 목표는 2025년 가을이었고, 이 검토는 그 글 한 편만 읽었다.
  nim-lang/nimony 저장소의 지금 상태나 그 뒤의 글은 확인하지 않았다. 아래 "Nimony"는 이 글의 Nimony다.
- 사이버 쪽 근거는 `docs/docs.md`, `docs/history/*`, `docs/decisions/*`, `src/std/os.cy`다.
  이번 검토에서는 빌드 도구가 없어 코드를 실행해 확인하지 못했다. 실행 확인이 필요한 주장은 그렇다고 적었다.

### 1.2 개요

Nimony의 목표 문장은 하나다. "hard real-time and embedded systems with a (mostly) memory safe language."
임베디드에서 잘 돌면 어디서든 잘 돈다는 논리이고, 여기서 WCET(최악 실행 시간) 예측 가능성이 나온다.
"This rules out just-in-time compilers and tracing garbage collectors."

이 목표가 나머지 결정을 끌고 간다.

| 영역 | Nimony의 선택 | 동기 |
| --- | --- | --- |
| 메모리 | 소멸자 + move의 스코프 기반 관리. `mm:atomicArc` 하나만 남김. `.acyclic`이 기본, 순환 가능 타입은 `.cyclic` | 예측 가능성, 소멸자의 합성 |
| 오류 | 예외 유지, 단 예외를 낼 수 있는 루틴은 `{.raises.}` 필수. 표준 `ErrorCode` enum(errno · Windows · HTTP 매핑) | 숨은 제어 흐름 표시, 라이브러리 사이 공통 어휘, 할당 없는 오류 |
| OOM · nil | 컨테이너는 교체 가능한 `oomHandler` 호출. `.raises` 루틴에서 `ref T`는 nil이 아니고 할당 실패는 `OutOfMemError` | nil 버그 제거 |
| 제네릭 | 인스턴스가 아니라 제네릭 본문 자체를 완전히 타입 검사. 본문에는 concept 제약 필수 | 이른 오류, 좋은 메시지, IDE 보완 |
| 동시성 | `spawn` 하나. 같은 스레드인지 다른 스레드인지는 스케줄러가 런타임에 정함. 병렬 for(`||`) | async와 스레드는 같은 함정을 가진다 |
| 메타프로그래밍 | 매크로 대신 플러그인. 기계어로 컴파일된 외부 프로그램이 타입 검사 뒤의 NIF를 읽고 씀 | 속도, 증분 · 병렬 컴파일 |
| 표준 컨테이너 | `seq`는 순수 라이브러리, `string`의 컴파일러 마법 최소화 | 언어 핵심 축소 |

### 1.3 핵심 디자인과 사이버의 현재 위치

각 항목은 "Nimony / 사이버 지금 / 판정" 순서다.

#### 1.3.1 메모리: 단일 모드와 비순환 기본

- Nimony: "Nim 2's way of doing it is basically perfect and we simply reimplemented it." 바뀐 것은 둘이다.
  mm 스위치를 모두 걷어내고 `atomicArc` 하나만 남겼다. 순환 수거기는 "unclear if or when it will be ready"이고, 대신
  `.acyclic`이 기본이며 순환에 낄 수 있는 객체만 `.cyclic`을 붙인다.
- 사이버 지금: 값 소유권 + 빌림(`&T` · `&&T`) + `@deinit`이 기본이고 `^T`만 ARC다. 순환은 아예 버그로 본다.
  "reference cycles is a sign of a bug in the program and is reported"이고, 스레드 끝에 탐지해 panic한다. 약한 참조는 없다.
- 판정: 방향이 같다. 사이버는 Nimony보다 한 걸음 더 갔다. Nimony는 "순환은 드물다"를 기본값으로 삼았고, 사이버는 "순환은 오류"로
  못박았다. 두 언어 모두 tracing GC를 버리고 결정적 소멸을 택했다.
- 다른 점 하나: Nimony는 `atomicArc`로 통일했고 사이버의 `^T`는 원자적이지 않다. 사이버는 `^T`가 `Sendable`이 아니라서
  스레드 사이로 넘어가지 않으므로 원자 연산이 필요 없다. 스레드 경계를 타입으로 막았기 때문에 얻은 이득이고, 유지할 이유가 된다.
- 가져올 것: 비순환을 정적으로 판정하는 것(1.4 B).

#### 1.3.2 오류: 예외 + `.raises`, 그리고 `ErrorCode`

- Nimony: Araq는 "I personally dislike both exceptions and its emulation via sum types."라고 쓴다. 합 타입 쪽에 대한 불만은
  조기 반환과 `?`가 식 전체에 번지는 것이다. 그가 든 가상 예는 `?fib(n -? 1) +? ?fib(n -? 2)`다.
  선호하는 방식은 오류 상태를 객체 안에 두는 것(스트림의 오류 상태, NaN, `low(int)`)이다. 그래도 예외는 남기되 예외를 낼 수 있는
  루틴에 `{.raises.}`를 반드시 붙인다. 구체적인 예외 집합은 적지 않는다.
- `ErrorCode`: 상속 기반 예외와 나란히 던질 수 있는 enum이다. "How ErrorCode is mapped from and to POSIX errno values,
  Windows API errors and HTTP status codes was a core consideration." 힙 할당이 없어 OOM도 미리 만들어 둔 예외 객체 없이 전파된다.
- 사이버 지금: 0.4에서 예외를 버리고 `!T` Result 값으로 갔다. 전파는 `!`, 기본값은 `!else`, 한곳 처리는 `try:` … `else |err|:`
  블록이다(`project_try_block.md`). `error`는 이름만 담는 값이고 payload · error set 타입은 Planned다.
- 판정: 전파 모델은 사이버가 낫다. `{.raises.}`는 "이 함수는 실패할 수 있다"만 알려 주고 호출 지점은 여전히 숨은 제어 흐름이다.
  사이버의 `!`는 전파 지점 하나하나를 보이게 한다. Araq가 싫어한 `?` 소음은 사이버에서 `try` 블록이 줄인다.
- 그러나 `ErrorCode`는 사이버에 없는 것이고, 지금 실제로 필요한 것이다(1.4 A).

~~~cy
-- Araq가 싫어한 모양. 사이버로 쓰면 이렇다.
fn fib2(n int) -> !int:
    return fib(n - 1)! + fib(n - 2)!

-- 여러 `!`를 한곳에서 처리하는 사이버의 답.
try:
    a := parse(x)!
    b := parse(y)!
    print(a + b)
else |err|:
    print('Failed with %{err}.')
~~~

#### 1.3.3 OOM과 nil

- Nimony: 할당 실패는 교체 가능한 `oomHandler`가 받는다. 기본 핸들러는 "remembers the size of the failing request and then
  execution continues"이고 `threadOutOfMem()`으로 묻는다. `.raises` 루틴 안에서는 nil 대신 `OutOfMemError`가 나서 `ref T`가
  nil이 아니게 된다. Araq 스스로 실험적이라고 적었다.
- 사이버 지금: nil이 없다(`?T`). 메모리는 `project_memory_limit.md`에서 정했다. 한도는 할당자가 아니라 힙 · 스택이 자라는
  지점에서 검사하고, 넘으면 `panic: OutOfMemory`, eval은 `CL_ERROR_PANIC`을 돌려주며 VM은 다시 쓸 수 있다.
- 판정: nil은 사이버가 이미 앞섰다. OOM에서 "기억하고 계속 실행"은 사이버의 용도와 맞지 않는다. 임베딩 호스트(tars-agent)에게는
  깨끗한 panic과 VM 재사용이 더 예측 가능하다. 할당 지점 수백 곳을 실패 가능하게 만드는 비용도 퍼즈로 이미 확인했다.
  다만 "`!T` 함수 안에서는 OOM을 `error.OutOfMemory` 값으로 돌려준다"는 발상은 1.4 A가 정착한 뒤의 장기 후보로 남긴다.

#### 1.3.4 제네릭: 본문 자체의 타입 검사

- Nimony: "performing complete type checking on generic code, not merely on generic instantiations." 본문에 쓰는 연산은
  concept으로 선언해야 하고, 제약 없는 `proc fib[T](a: T)`는 거절된다.

~~~nim
type Fibable = concept
  proc `<=`(a, b: Self): bool
  proc `+`(x, y: Self): Self
  proc `-`(x, y: Self): Self

proc fib[T: Fibable](a: T): T =
  if a <= 2: result = 1
  else: result = fib(a-1) + fib(a-2)
~~~

- Nimony가 인정한 타협: 제네릭 값의 대입(`let x = y`)은 허용한다. move 분석이 더 뒤에 돌기 때문에, 복사인지 이동인지를 본문
  검사 시점에 알 수 없어서다.
- 사이버 지금: 템플릿(`type C[T Any]`, `fn add[T Any]`)과 제네릭 함수(`%T`, trait 매개변수)는 특수화될 때 구체 타입으로 본문을
  검사한다(문서와 HANDOFF "템플릿 타입의 메서드는 쓰지 않아도 인스턴스마다 본문이 검사된다" 기준, 이번에 실행 확인은 못 함).
  원소 타입에 따라 안 되는 메서드는 `#[cond=type.is_copyable(T)]`처럼 조건으로 막는다. trait는 이미 "generic type"으로 제약에 쓰인다.
- Nimony가 타협한 지점을 사이버는 언어 규칙으로 풀었다. `move`는 복사 가능 여부와 독립이라, 제네릭 코드가 복사 가능 타입과
  `NoCopy` 타입을 같은 문장으로 다룬다(`Array.append`의 `move val`). 본문 검사 시점에 복사 · 이동을 정할 필요가 없다.
- 판정: 가져올 가치가 가장 큰 항목이다. 그러나 가장 비싸다(1.4 C).

#### 1.3.5 동시성: `spawn` 하나와 구조적 병렬

- Nimony: `spawn` 하나로 async와 스레드를 다룬다. 스레드 안전 규칙은 둘 다에 똑같이 적용한다. 구현은 CPS 변환이다.
  병렬은 `||` 반복자의 for로 쓴다. 유도 변수가 서로 다른 위치를 보장하고, 루프가 끝나면 모든 병렬이 끝나며, 마지막 반복은
  호출 스레드가 직접 돌 수 있다. FlowVar를 없애 `Matrix[FlowVar[float]]` 대신 `Matrix[float]`를 쓰게 하려는 것이다.

~~~nim
var a: array[2, int]
for i in 0 || 1:
  a[i] = fib(n-i-1)
~~~

- 사이버 지금: fiber(협력형, 같은 스레드)와 스레드(`spawn`, `Sendable`)를 일부러 나눴다. fiber는 `scope` 블록 안에서 지역 값을
  빌릴 수 있다(Scope borrows). 스레드로는 `^T` · `&T`가 넘어가지 않는다. 기다리는 스레드가 대기열의 스레드를 직접 도는 것은
  "마지막 반복은 호출 스레드가"와 같은 발상이다.
- 판정: 통합 `spawn`은 가져오지 않는다. Nimony는 async에도 스레드 규칙을 씌워 단순하게 만들었고, 그 대가로 async에서 빌림을 잃는다.
  사이버는 fiber에서 빌림을 허용하고, 스택이 옮겨질 때 빌림을 보정하는 장치까지 이미 만들었다(`project_stack_ptr_patch.md`).
  이것이 사이버 동시성의 표현력이고 0.5의 목표("fiber 관련 동시성 동작을 모두 완성")와도 이어진다.
  구조적 병렬 for는 따로 볼 만하다(1.4 D).

#### 1.3.6 메타프로그래밍: 플러그인과 NIF

- Nimony: 매크로를 플러그인으로 대체한다. 플러그인은 기계어로 컴파일되고, 보통 타입 검사 뒤에 돌며, 증분 · 병렬로 돈다.
  템플릿 · 반복자 · 타입 · 모듈 전체에 붙는다. 타입에 붙인 플러그인(`Matrix {.plugin: "avoidtemps".}`)은 `a*b + c - d`를 제자리
  `*=` · `+=` · `-=`로 바꿔 임시값을 없앤다(term rewriting macro 대체). 플러그인 API는 아직 없다고 적었다.
- 사이버 지금: Zig식 컴파일 타임 실행(`#if` · `#for` · `#switch`, `type.info`, `meta` 모듈, `const` 템플릿 매개변수,
  `type X const:` 타입 평가)이다. 같은 언어, 같은 프로세스 안에서 타입 정보를 보며 돈다.
- 판정: 가져오지 않는다. 외부 프로그램 플러그인은 대형 컴파일러의 증분 · 병렬 빌드를 위한 것이다. 사이버는 실행 파일 하나로
  스크립트를 바로 돌리는 CLI이자 임베딩 라이브러리라(`project_direction.md`) 외부 프로세스와 직렬화 IR을 끼울 이유가 없다.
  "타입 검사 뒤에, 타입 정보를 가진 채로 돈다"는 원칙은 사이버 comptime이 이미 따른다.

#### 1.3.7 단일 모드와 라이브러리 컨테이너

- Nimony는 mm 스위치를 없앴다. 사이버에서 의미를 바꾸는 스위치는 `single_run`(종료 시 `@deinit` 없이 힙 스윕) 하나다.
  문서에 계약으로 적어 두었으니 됐지만, 같은 종류의 스위치를 더 늘리지 않는다는 기준으로 삼을 만하다.
- `seq`를 라이브러리로 내린 것은 사이버의 `Array` · `Map` · `Slice`가 `core.cy`에 있는 것과 같은 방향이다.

### 1.4 가져올 만한 것

우선순위는 0.5까지 남은 일(fiber 동시성 완성)을 밀어내지 않는 순서로 매겼다.

#### A. 표준 오류 어휘 (Nimony `ErrorCode`) — 0.5 전후, 작음

문제는 지금 코드에 있다. `src/std/os.cy`의 `fromErrno`는 errno 여섯 개만 이름을 붙이고, 나머지는 stderr에 찍은 뒤
`error.Unknown`을 돌려준다. Windows에서는 panic한다.

~~~cy
fn fromErrno() -> error:
    #if meta.system() == .windows:
        panic('unsupported')
    #else:
        switch lc.errno:
            case lc.EPERM : return error.OperationDenied
            case lc.ENOENT: return error.FileNotFound
            case lc.EFAULT: return error.BadAddress
            case lc.EBADF : return error.BadFile
            case lc.EACCES: return error.AccessDenied
            case lc.EINVAL: return error.InvalidArgument
            else:
                eprint("errno: %{lc.errno}")
                return error.Unknown
~~~

std 전체를 훑으면 이름도 겹친다. 거부를 뜻하는 것만 `AccessDenied` · `OperationDenied` · `NotAllowed` 셋이고, 모름은
`Unknown` · `UnknownError` · `Unexpected` 셋이다(`src/std` · `src/builtins`의 `error.X`, Zig 쪽 오류 포함이라 스크립트에 모두
보이는지는 따로 확인해야 한다).

에이전트 루프(tars-agent)에서는 이것이 곧 품질 문제다. 모델이 쓴 스크립트가 오류 이름으로 분기하는데, 같은 실패가 함수마다
다른 이름이면 분기가 틀린다. `EEXIST` · `ENOTDIR` · `ENOSPC` · `ETIMEDOUT`처럼 흔한 실패가 모두 `Unknown`이 되는 것도 같다.

제안:

1. 표준 이름 집합을 정한다. 기준은 Nimony처럼 errno · Windows 오류 · HTTP 상태를 양방향으로 옮길 수 있는가다.
   예: `NotFound` · `PermissionDenied` · `AlreadyExists` · `NotADirectory` · `IsADirectory` · `NoSpace` · `TimedOut` ·
   `Interrupted` · `WouldBlock` · `BrokenPipe` · `ConnectionRefused` · `InvalidArgument` · `OutOfMemory` · `Unsupported` · `Unknown`.
2. 매핑을 한곳에 둔다. 표준 모듈(가칭 `errors`)에 `from_errno(code int) -> error`, Windows용 `from_win32`,
   `to_http_status(err error) -> int`. `os.fromErrno`는 그것을 부르고, `eprint` 부작용은 뺀다.
3. 옛 이름은 한 릴리스 동안 문서상 별칭으로 남긴다. `error`는 이름 값이라 `== error.FileNotFound`로 비교하는 스크립트가 깨진다.
   별칭을 언어로 지원할지(같은 값으로 취급), 릴리스 노트의 호환성 절로 처리할지는 결정이 필요하다.
4. Planned인 `error` set 타입이 들어오면 이 집합이 첫 사용처가 된다. 그때 `switch`의 완전성 검사가 생긴다.

~~~cy
-- 제안 모양(가상, 아직 없는 API).
use errors

data := os.read_file(path) !else |err|:
    switch err:
        case error.NotFound:
            return default_config()
        case error.PermissionDenied:
            eprint('No permission: %{path}')
            return err
        else:
            return err
~~~

장점: 작다. 언어 규칙을 바꾸지 않는다. 에이전트용 오류 문구 작업(0.4.11 CodeAct 회차)의 연장선이다.
단점: 이름 변경은 호환성 문제이고, Windows 매핑은 실제 Windows 실행 확인이 필요하다.

#### B. 순환 가능성의 정적 판정 (Nimony `.acyclic` 기본) — 0.5 이후, 중간

사이버는 순환을 오류로 보고 스레드 끝에 런타임에서 찾는다. 그런데 순환이 생길 수 있는 타입은 타입 그래프에서 정해진다.
어떤 타입 `T`의 필드를 따라가다 `^U` 경로로 `T` 자신에게 돌아올 수 없으면, `T` 객체는 순환에 낄 수 없다.

제안:

1. sema가 타입마다 "순환 가능" 비트를 계산한다(`^T` 간선만 따라가는 강결합 요소). 사용자 주석은 필요 없다.
   Nimony는 `.cyclic`을 사람이 붙이게 했지만, 사이버는 trait 객체(`^Dyn[T]`)를 빼면 타입 그래프가 닫혀 있어 컴파일러가 셀 수 있다.
   `^Dyn[T]`는 보수적으로 순환 가능으로 본다.
2. 순환 탐지는 그 비트가 선 객체만 훑는다. 프로그램에 순환 가능 타입이 하나도 없으면 스레드 끝 탐지를 건너뛴다.
3. LSP에서 순환 가능 타입에 Information 진단을 단다. "이 타입은 `^T`로 자기에게 돌아온다. 부모를 가리키려면 인덱스나 키를 쓴다."
   지금 문서가 Weak references 절에서 권하는 우회와 같은 말이다.

장점: 규칙이 바뀌지 않는다. 오류를 더 일찍 알려 준다.
단점: 탐지 비용이 실제로 문제인지 재 본 적이 없다. 측정 전에는 3번(진단)만 가치가 확실하다.

#### C. 제네릭 본문의 정의 시점 검사 (Nimony 핵심 변경) — 0.5 이후, 큼

지금 사이버에서 템플릿 본문의 오류는 특수화될 때, 구체 타입이 들어간 상태로 나온다. 그래서 오류가 정의가 아니라 사용
쪽 이야기처럼 읽히고, 2026-11-12 LSP 설계(`docs/specs/2026-11-12-lsp-design.md`)에서 제네릭 본문 안의 보완 · hover는
`T`에 대해 할 말이 없다. 에이전트가 쓴 제네릭 코드의 오류 문구도 같은 이유로 덜 정확하다.

~~~cy
type Shape trait:
    fn area() -> float

fn describe(s Shape) -> str:
    return 'area %{s.area()}'     -- Shape에 area가 있으니 정의 시점에 통과할 수 있다.
    -- s.perimeter()              -- 지금: 특수화될 때 구체 타입으로 검사된다.
                                  -- 제안: 정의 시점에 "Shape에 perimeter가 없다".
~~~

단계 제안:

1. 먼저 싸고 바로 이득인 것: 특수화 중 난 오류에 인스턴스화 경로를 붙인다. "`describe[Circle]`을 `main.cy:12`에서 특수화하는
   중". `src/sema*.zig`에서 이런 문구를 찾지 못했다(grep 기준).
2. trait로 제약한 매개변수(`s Shape`, `[T Shape]`)를 가진 본문은 정의 시점에 한 번 검사한다. 본문에서 `T`의 값에 쓸 수 있는 것은
   trait의 메서드와 모든 타입에 공통인 연산(move, 대입, 빌림)뿐이다.
3. `Any`는 지금처럼 특수화 시점 검사로 남긴다. Nimony는 제약을 강제했지만 사이버는 `#if` · `#switch type.info(T)`로 타입별 분기를
   하는 comptime 코드가 많아, `Any`를 탈출구로 두는 것이 맞다. C++20 concepts가 제약 없는 템플릿을 남긴 것과 같은 타협이다.

필요한 것: 연산자를 trait로 표현하는 방법(지금 연산자는 메서드라 trait 메서드로 적을 수는 있다), `#[cond]` 메서드가 정의 시점
검사와 어떻게 만나는지의 규칙. 큰 작업이고 sema 구조를 건드리므로 0.5 뒤에 결정 문서부터 쓴다.

#### D. 구조적 병렬 루프 (Nimony `||`) — 0.5 이후, 중간

사이버의 `scope` 블록은 fiber에 대해 이미 "블록이 끝나면 모두 끝난다"를 보장하고, 그 덕에 지역 값을 빌려 준다. Nimony의 병렬
for는 같은 보장을 스레드에 준다. 사이버로 옮기면 "스레드용 scope"가 되는데, 걸림돌은 `Sendable`이 `&T`를 막는다는 점이다.

필요한 것은 슬라이스를 겹치지 않는 조각으로 나눈 배타 빌림(Rust `chunks_mut`, Nimony의 "유도 변수가 서로 다른 위치")이다.
문법을 새로 만들기보다 표준 라이브러리 함수(`par.chunks(&&xs, n, fn)` 같은 모양)로 먼저 시도하고, 블록이 끝날 때 모든 스레드를
기다린다는 계약을 `scope`와 같게 한다. fiber 완성(0.5) 뒤가 맞다.

### 1.5 Pros vs Cons: Nimony 접근 자체

장점

- 목표 하나(WCET)에서 결정을 끌어내 일관성이 있다. GC · JIT를 버린 이유가 분명하다.
- 제네릭 본문 검사는 Nim 사용자가 오래 겪은 "인스턴스에서야 터지는 오류"를 정면으로 고친다.
- `ErrorCode`는 언어 기능이 아니라 어휘의 표준화다. 작고, 라이브러리 생태계 전체에 효과가 있다.
- mm 스위치 정리는 "모드가 많을수록 버그와 문서가 늘어난다"는 Nim 2의 경험에서 나온 교정이다.

단점

- 오류 처리가 세 갈래다(객체 안 오류 상태, 스레드 지역 오류 변수, `.raises` 예외 + `ErrorCode`). Araq 스스로 경험이 판단할
  것이라고 적었다. 사이버는 `!T` 하나라 더 단순하다.
- 순환 수거기가 미정인 채 `.acyclic` 기본으로 갔다. 틀린 주석은 누수가 된다. 사이버는 순환을 오류로 탐지하므로 이 위험이 없다.
- 플러그인 API가 없고 컴파일러 내부를 import해야 한다. 생태계가 기댈 표면이 아직 없다.
- 통합 `spawn`은 async에서 빌림을 잃는다.

### 1.6 영향과 현재 상황

- Nimony의 메모리 모델은 새것이 아니라 Nim 2의 ARC/ORC를 다듬은 것이다. 그 계보는 C++ RAII와 move, Rust의 소유권, Swift의
  ARC다. 사이버 0.4의 구조(값 소유권 + 빌림 + `^T` ARC)도 같은 계보에 있고(`docs/history/ownership_memory.md`), 두 언어가 같은
  결론에 따로 도착했다는 점이 이 설계 공간의 수렴을 보여 준다.
- 제네릭 본문 검사는 ML · Haskell의 타입 클래스, Rust의 trait bound, C++20 concepts, Swift의 프로토콜 제약이 걸어 온 길이다.
  Nim은 C++ 템플릿 쪽에서 출발해 그쪽으로 옮겨 가는 중이다. 사이버도 같은 출발점(템플릿)에 있다.
- 매크로 → 컴파일된 플러그인은 Rust의 proc-macro(별도 크레이트, 컴파일된 코드)와 닮았다. 다만 Rust는 토큰을, Nimony는 타입
  검사된 NIF를 다룬다.
- 현재 상황: 원문 기준 출시 목표는 2025년 가을이었다. 이 검토에서는 그 뒤의 진행을 확인하지 않았다. 채택 결정을 할 때 A · C는
  nim-lang/nimony 저장소의 지금 구현(특히 `ErrorCode` 목록과 매핑, concept 검사 규칙)을 한 번 더 읽는 것이 좋다.

### 1.7 결정할 것

1. A(표준 오류 어휘)를 0.4.12 또는 0.5에 넣을지. 넣는다면 옛 이름을 언어 별칭으로 둘지, 호환성 절로만 처리할지.
2. B는 3번(LSP 진단)만 먼저 할지, 측정을 먼저 할지.
3. C의 1단계(인스턴스화 경로 오류 문구)를 0.5 전에 할지. 2 · 3단계는 0.5 뒤 결정 문서로.
4. D는 0.5 범위 밖으로 두는 데 동의하는지.

가져오지 않기로 한 것: 통합 `spawn`(fiber 빌림을 지킨다), 플러그인 · NIF(실행 파일 하나라는 방향), OOM 계속 실행 핸들러
(깨끗한 panic + VM 재사용 유지), 예외 + `.raises`(`!T`가 이미 더 명시적).

## 2. Nim 2 · Lean 4 · Koka: 마지막 사용 분석

### 2.1 출처와 범위

- 계기: 개발 과정을 "자연어 → 의사 코드 → 타입 있는 자동 메모리 언어 → 저수준 시스템 언어"로 보는 관점. Rust와 Zig는 마지막 단계에
  맞는 도구이고, 앞 단계에서는 알고리즘과 메모리 관리를 따로 생각하고 싶다는 것이다. `project_direction.md`가 사이버를 Python ·
  Perl · Shell의 대용으로 두고 바이너리가 필요한 일을 Zig · Odin에 맡긴 것과 같은 구도라, 사이버는 세 번째 단계를 맡는다.
  이 절은 사이버가 그 단계에서 메모리를 얼마나 드러내는지, 그리고 어떻게 덜 드러낼 수 있는지를 본다.
- Nim: "Nim Destructors and Move Semantics", https://nim-lang.org/docs/destructors.html (페이지 버전 2.4.2, 2026-11-15에 전체를 읽음).
- Lean 4 · Koka: Ullrich · de Moura, "Counting Immutable Beans"(IFL 2019), Reinking 외, "Perceus"(PLDI 2021). 이번에 다시
  읽지 않았다. `project_slice_append_aliasing.md`의 2026-11-01 조사와 일반 지식에 기댄다.
- Rust · Swift · Mojo에 대한 서술은 일반 지식이다.
- 사이버 쪽 근거는 `docs/docs.md` Moving 절, `src/sema.zig`, `src/builtins/core.cy`, `project_slice_append_aliasing.md`,
  `project_borrow_model.md`, `docs/history/ownership_memory.md`다. 코드를 실행해 확인하지는 못했다.

### 2.2 개요

같은 `scores` 예제는 사이버에서 Python과 거의 같다.

~~~cy
scores := Map[str, int]{alice=100, bob=85}
scores['charlie'] = 92
~~~

할당자도, 할당 실패 처리도, 키의 소유자도 보이지 않는다. 할당 축에서는 사이버가 이미 세 번째 단계 언어다.
메모리가 드러나는 곳은 소유권 축이다.

~~~cy
fn total(xs Array[int]) -> int: ...

xs := Array[int]{1, 2, 3}
print(total(move xs))   -- `Array`는 `NoCopy`라 `move`를 적어야 한다
~~~

Rust는 값으로 넘기면 저절로 이동하므로, 이 자리에서는 사이버가 Rust보다 더 명시적이다.

여기서 다루는 언어들은 사이버와 같은 기반(소멸자 또는 참조 카운트, move)을 쓰면서 이동인지 복사인지를 컴파일러가 마지막 사용으로
정한다. 사용자는 값 의미로 쓰고, 소유권은 컴파일러가 해결하는 최적화가 된다.

| | 기본 의미 | 마지막 사용에서 | 뒤에서 다시 쓰면 | 이동된 자리 |
| --- | --- | --- | --- | --- |
| Nim 2 | 복사 | 이동(`=sink` + `=wasMoved`) | 조용히 복사. `=copy`에 `{.error.}`를 붙인 타입만 컴파일 오류 | 값 자체를 "파괴할 것 없음" 상태로 둠 |
| Lean 4 · Koka | 공유(참조 카운트) | 소유권을 넘김. 카운트가 1이면 제자리 재사용 | 컴파일러가 카운트를 올림(`dup`) | 해당 없음 |
| Rust | 이동 | 이동(마지막 사용과 무관) | 컴파일 오류 | 조건부 이동이면 스택의 drop flag |
| 사이버 지금 | 복사 가능 타입은 복사, `NoCopy`는 명시적 `move` | 반환만 암시적 이동 | 컴파일 오류 | 같은 블록에서 선언한 변수만 이동 가능, 플래그 없음 |

### 2.3 핵심 디자인과 사이버의 현재 위치

#### 2.3.1 Nim 2: `lastReadOf`와 재작성 규칙

- 마지막 사용은 제어 흐름 분석으로 정한다. 문서의 표기는 "lastReadOf(x) to describe that x is not used afterward"이고,
  "computed by a static control flow analysis"라고 적는다.
- 재작성 규칙은 넷이 핵심이다.

| 원래 식 | 바뀐 식 | 이름 |
| --- | --- | --- |
| `x = lastReadOf z` | `=sink(x, z)` 다음 `=wasMoved(z)` | move-optimization |
| `x = y` | `=copy(x, y)` | copy |
| `f_sink(lastReadOf y)` | `f_sink(y)` 다음 `=wasMoved(y)` | move-to-sink |
| `f_sink(notLastReadOf y)` | `let tmp = =dup(y)` 다음 `f_sink(tmp)` | copy-to-sink |

- 증명하지 못하면 복사한다. "If it cannot be proven to be the last usage of the location, a copy is done instead".
  그래서 Nim 사용자는 이동이 일어났는지 몰라도 프로그램이 맞다. 성능만 달라진다.
- `=wasMoved`는 "sets the object to a state that signifies to the destructor there is nothing to destroy"이다.
  이동 여부를 변수 밖의 플래그가 아니라 값 안(예: 포인터 필드를 nil로)에 적는다. 그래서 분기 한쪽에서만 이동해도 블록 끝의
  소멸자는 그대로 부르면 된다. 대가는 런타임 검사 한 번과, 모든 타입에 "비어 있음" 상태가 있어야 한다는 전제다.
  "=wasMoved(x) followed by a =destroy(x) operation cancel each other out"이라 직선 코드에서는 비용이 사라진다.
- 분석 범위는 좁다. "only concerned with local variables; however, object and tuple fields are treated as separate entities".
  사이버의 "Can only move a local or local member."와 같은 범위다.
- sink 매개변수 추론은 기본으로 꺼져 있다(`--sinkInference:on`). 문서는 "The details of the inference algorithm are currently
  undocumented."라고 적는다. 이동 자체(마지막 읽기에서 `=sink`)는 기본으로 켜져 있고, 꺼져 있는 것은 어떤 매개변수를 `sink`로
  볼지의 추론이다.
- `ensureMove x`는 런타임 동작이 없는 단언이다. "leads to a static error if the compiler cannot prove that a move would be safe".
- cursor 추론은 "a compile-time copy-on-write analysis"다. 원본도 사본도 뒤에서 바뀌지 않으면 복사하지 않고 빌린다.
  예: `let v = tab["key"]`는 `tab`이 바뀌지 않으므로 복사도 소멸도 없다.

#### 2.3.2 Lean 4 · Koka: Perceus (일반 지식)

- 모든 힙 값이 참조 카운트를 가진다. 컴파일러가 마지막 사용 뒤에 `drop`을, 다시 쓰이는 값에 `dup`을 정확히 넣는다.
- 인자는 기본적으로 소유로 넘긴다. 받는 쪽에서 카운트가 1이면 그 칸을 제자리에서 고친다(reuse). 그래서
  `Array.push : Array α → α → Array α` 같은 함수형 시그니처가 명령형 코드와 같은 속도로 돈다(FBIP, functional but in-place).
- 저자들이 경고하는 점: 빌린 참조는 카운트가 1이어도 제자리 갱신이 안전하지 않다. `project_slice_append_aliasing.md`가 사이버의
  `clone_on_resize`에서 바로 이 경우를 찾았다.

#### 2.3.3 사이버 지금

- 세 번째 단계 층은 이미 있다. `str`, `[]T`(`Slice`), 멤버가 모두 복사 가능한 struct는 암시적으로 복사되고, `str` · `Slice`의
  버퍼는 참조 카운트라 복사가 싸다. 네 번째 단계 층은 `Array[T]` · `NoCopy` · `&&T` · `Ptr[T]`다.
- 추론된 이동은 반환 하나뿐이다(fork `eb060d5`, `?R` · `!R` 감싸기 포함).
- 이동은 같은 블록에서 선언한 변수에만 쓸 수 있다(`src/sema.zig:9108`, "Can only move variable declared in the same block.").
  이유는 부분 이동 절이 적은 것과 같다. "the state at the end of the block is known without runtime flags". Rust의 drop flag도,
  Nim의 `=wasMoved` 상태도 쓰지 않는 설계다.
- sema에는 마지막 사용 분석이 없다(`last use` · `liveness` 같은 이름을 grep으로 찾지 못함).
- 그 결과 세 군데에 구멍이 있다.
  1. `Slice` 별칭: `Slice.clone_on_resize`(`src/builtins/core.cy`)는 빌린 `&Slice` 수신자에서 `@isUniqueRef`가 참이면 버퍼를
     그대로 돌려준다. 2026-11-01 결정은 해제 정확성만 버퍼 헤더로 고쳤고, 값 의미는 마지막 사용 분석이 필요해 남겼다(후보 2).
  2. 빌림의 비어휘적 수명: 매뉴얼은 `elem := &a[2]; a << 4`가 된다고 약속하지만 빌림 수명은 어휘적이다(`project_borrow_model.md`).
  3. `NoCopy` 값 전달: 마지막 사용이어도 `move`를 적어야 하고, 하위 블록에서는 적을 수도 없다.

### 2.4 가져올 만한 것

하나의 분석이 세 구멍을 함께 막는다. A가 기반이고 B · C · D · E가 그 소비자다.

#### A. 마지막 사용 분석 — 기반

- Proc마다 지역과 지역 멤버 경로(`f.b`)에 대해 "이 사용 뒤로 어느 경로에서도 읽히지 않는다"를 계산한다. 범위는 Nim과 같게
  지역과 멤버로 한정한다. 사이버의 이동 규칙이 이미 이 범위다.
- 두는 자리는 IR이다. sema가 소유권 연산(retain · release · destruct)을 이미 IR에 넣고 bc_gen은 번역만 하므로, IR 위에서
  역방향 활성 분석(backward liveness)을 한 번 돌리고 그 결과로 IR을 고친다.
- 조건: 지역 id가 선언 순서와 같아야 한다는 IR 불변식(HANDOFF "구현 함정")을 깨지 않는다. 분석은 지역을 새로 만들지 않고
  사용 지점에 표시만 단다.

#### B. `Slice`의 값 의미 — 첫 소비자 후보 1

`append` · `+` · `insert`처럼 `clone_on_resize`를 거치는 연산에서, 수신자가 마지막 사용이면 소유로 넘겨 제자리 갱신을 허용하고,
아니면 갱신 전에 복사한다. 슬라이스 문서의 후보 2이고 Lean 4 · Koka의 소유 인자와 같은 규칙이다.

~~~cy
a := []str{'x', 'y'}
b := a.size_down(0)
print(a[0])       -- 지금: `a`와 `b`가 버퍼를 나눠 써서 해제된 칸을 읽는다(06장 미완 지점, 이번에 재실행은 못 함)
                  -- 제안: `a`가 뒤에서 쓰이므로 `size_down` 전에 복사, 'x'

xs := []int{}
for 0..1000 |i|:
    xs = xs.append(i)   -- `xs`는 대입 직전 마지막 사용이라 지금처럼 제자리
~~~

장점: 이미 알려진 미결을 닫는다. 문서와 테스트가 쓰는 `xs = xs.append(x)` 모양은 속도가 그대로다.
단점: 받는 쪽을 남기는 코드는 복사 비용이 생긴다. 지금은 그 코드가 틀린 결과를 내므로 받아들일 만하다.

#### C. 빌림의 비어휘적 수명 — 첫 소비자 후보 2

빌림 지역의 수명을 블록 끝이 아니라 마지막 사용까지로 줄인다. Rust 2018의 NLL과 같은 변화이고, 매뉴얼이 이미 약속한 동작이라
언어 규칙을 새로 정하지 않는다. `project_borrow_model.md`의 계수(`active_borrows` · `active_ex_borrows`)를 블록 끝이 아니라
마지막 사용 뒤에 내리면 된다.

~~~cy
a := Array[int]{1, 2, 3}
elem := &a[2]
print(elem.*)
a << 4            -- 지금: `Expected exclusive access.` / 제안: `elem`이 끝났으므로 허용
~~~

#### D. `NoCopy` 값의 암시적 이동

값 매개변수에 넘기는 자리가 마지막 사용이면 `move`를 적지 않아도 이동한다(Nim move-to-sink).
뒤에서 다시 쓰면 Nim은 복사하지만 `NoCopy`는 복사할 수 없으므로 지금처럼 오류를 내되, 두 자리를 함께 짚는다.

~~~cy
xs := Array[int]{1, 2, 3}
print(total(xs))      -- 제안: 마지막 사용이므로 이동
print(xs.len())
--> error: `xs` was moved into `total` at line 2. Borrow it with `&xs` or clone it to use it here.
~~~

명시적 `move`는 남는다. 뜻은 "여기서 끝낸다"는 단언(Nim `ensureMove`)이 되고, 마지막 사용이 아닌 자리의 `move`는 지금처럼
뒤의 사용을 오류로 만든다. 복사 가능 타입에는 적용하지 않는다. 복사가 싸므로 이동으로 바꿀 이득이 작고, `@deinit`이 있는
복사 가능 타입은 이동 여부에 따라 소멸 횟수가 달라진다.

#### E. 분기 안의 이동 — 런타임 플래그 없이

지금은 바깥 블록의 변수를 `if` 갈래 안에서 옮길 수 없다. 마지막 사용 분석이 있으면 플래그 없이 풀 수 있다. 합류 지점 뒤에서
그 변수를 쓰지 않는다면, 옮기지 않은 갈래의 끝에 `@deinit`을 넣는다. 그러면 합류 지점에서 변수는 어느 경로로 와도 죽어 있고,
블록 끝 상태가 컴파일 시점에 정해진다는 지금의 원칙이 지켜진다. Nim처럼 값 안에 "비어 있음"을 두지도, Rust처럼 스택 플래그를
두지도 않는다.

~~~cy
f := open_log()!
if verbose:
    archive(f)        -- 마지막 사용, 이동
-- 제안: else 갈래 끝에 `f.@deinit()`이 들어간다
print('done')
~~~

반복문은 보수적으로 둔다. 바깥 변수를 반복 본문에서 옮기는 것은 바로 뒤에 `break` · `return`이 오거나, 다음 반복 전에 다시
대입될 때만 허용한다.

#### 참고만: cursor 추론

Nim의 cursor 추론(바뀌지 않는 원본에서 읽은 값을 복사하지 않고 빌림)은 사이버에서 이득이 작다. 사이버는 빌림을 `&`로 드러내고,
암시적으로 복사되는 `str` · `Slice`는 참조 카운트 하나만 올린다. 측정해서 필요해지면 다시 본다.

### 2.5 Pros vs Cons

장점

- 세 번째 단계에서 알고리즘만 생각할 수 있다. `move` · `&&` · `NoCopy`는 성능을 다듬을 때 꺼내는 도구가 된다.
- 분석 하나로 미결 셋(`Slice` 별칭, 빌림 NLL, 하위 블록 이동)을 함께 닫는다.
- 호환성을 깨지 않는다. 지금 통과하는 코드는 모두 그대로 통과하고, 지금 오류인 코드 일부가 통과하게 된다(B는 예외. 받는 쪽을
  남기는 코드의 결과가 바뀌지만 지금 결과가 틀렸다).
- tars-agent처럼 LLM이 사이버를 쓸 때, 모델이 의사 코드에 가깝게 써도 컴파일된다.
- Nim과 달리 조용한 복사가 없다. `NoCopy`인 비싼 타입은 이동 아니면 오류이므로 성능 절벽이 숨지 않는다.

단점

- `@deinit` 시점이 코드 모양에 따라 달라진다. D는 호출된 함수 안으로, E는 갈래 끝으로 소멸을 앞당긴다. 파일 닫기처럼 부작용이
  있는 타입에서 보인다. Rust · Nim도 같은 성질이지만, 지금의 "블록 끝에서 역순 소멸"보다 설명이 길어진다.
- 뒤에 줄 하나를 더하면 앞의 이동이 오류(D)나 복사(B)로 바뀐다. 오류 문구가 두 자리를 함께 짚어야 하고, LSP hover로
  "여기서 이동됨"을 보여 줄 필요가 있다(1.4 C, LSP 설계와 연결).
- sema(`sema.zig` 약 10K줄)에 새 분석 단계가 들어간다. 생성기 · fiber의 멈춤 지점, `scope` 블록의 빌림, `try` 블록의 `else` 경로가
  모두 제어 흐름 그래프에 정확히 들어가야 한다.
- 지금 문서의 "`move`는 명시적 연산"이라는 설명을 고쳐야 한다.

### 2.6 영향과 현재 상황

- Nim: 2020년 Nim 1.2의 `--gc:arc`로 들어왔고, 같은 해 1.4에서 순환 수거를 더한 ORC가 나와 Nim 2.0(2023)의 기본이 됐다(일반 지식). 이번에 읽은 문서는 2.4.2판이고
  sink 추론은 여전히 기본으로 꺼져 있으며 알고리즘은 문서화되지 않았다. Nimony(1절)는 이 모델을 그대로 가져갔다.
- Lean 4는 Perceus 계열의 참조 카운트와 재사용을 기본 컴파일 모델로 쓰고, Koka는 Perceus 논문의 언어다. "FBIP"라는 말이 이
  흐름에서 나왔다(일반 지식).
- Swift는 값 의미 + CoW(`isUniquelyReferenced`)로 같은 문제를 런타임 검사로 풀었고, 5.9에서 `consume` 연산자와
  `borrowing` · `consuming` 매개변수를 더해 사용자가 이동을 드러낼 수 있게 했다. 암시적인 쪽에서 출발해 명시적인 도구를 더한
  셈이다(일반 지식).
- Mojo는 한 걸음 더 가서 값을 마지막 사용 바로 뒤에 소멸시킨다(ASAP destruction). 블록 끝 소멸을 버린 설계다(일반 지식).
  E의 "갈래 끝 소멸"은 그 방향의 작은 한 걸음이다.
- Rust 2018의 NLL은 빌림에만 마지막 사용을 적용했고 이동은 여전히 마지막 사용과 무관하다. 사이버가 C만 하면 Rust의 자리, D까지
  하면 Nim의 자리에 선다.
- 정리하면, 명시적 쪽(Rust, 사이버 지금)에서 출발한 언어는 추론을 더하고(NLL), 암시적 쪽(Swift, Nim)에서 출발한 언어는 단언을
  더하는(`consume`, `ensureMove`) 방향으로 서로 가까워지고 있다.

### 2.7 결정할 것

1. 사이버의 정체성을 "세 번째 단계 언어이고, 네 번째 단계 도구는 선택"으로 `project_direction.md`에 적을지. 2.4 D · E의
   판단 기준이 된다.
2. A(마지막 사용 분석)를 0.5 뒤 첫 설계 과제로 둘지. 그렇다면 결정 문서 `project_last_use.md`부터 쓴다.
3. 첫 소비자를 B(`Slice` 값 의미, 알려진 틀린 결과)와 C(빌림 NLL, 매뉴얼이 약속한 동작) 중 무엇으로 할지.
   추천은 C다. 규칙을 새로 정하지 않아 분석의 정확성만 검증하면 되고, 틀려도 거절하던 코드를 허용하는 쪽이라 위험이 작다.
4. D(암시적 이동)를 넣을지, 넣는다면 명시적 `move`를 단언으로 다시 정의할지.
5. E(분기 안 이동)에서 `@deinit`을 갈래 끝으로 앞당기는 것을 받아들일지.
