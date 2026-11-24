# 다른 언어의 설계 원칙 검토: 사이버랭이 가져올 것과 두고 갈 것

다른 언어의 설계 원칙을 사이버랭의 현재 설계와 맞대 보는 검토를 모은다. 결정 문서가 아니다.
채택할 항목은 각각 `docs/decisions/`에 결정을 먼저 적은 뒤 구현한다(`project_direction.md`).

언어 하나, 또는 같은 기법을 공유하는 언어 묶음마다 절 하나를 둔다. 절 안은 같은 순서로 쓴다: 출처와 범위, 개요, 핵심 디자인과
사이버의 현재 위치, 가져올 만한 것, 장단점, 영향과 현재 상황, 결정할 것. 다른 절을 가리킬 때는 절 번호를 쓴다(예: 1.4 A).

| 절 | 언어 | 작성 | 계기 |
| --- | --- | --- | --- |
| 1 | Nim 3.0 (Nimony) | 2026-11-15 | 0.5를 앞두고 Araq의 설계 원칙 글 검토 |
| 2 | Nim 2 · Lean 4 · Koka: 마지막 사용 분석 | 2026-11-15 | 개발 과정에서 사이버가 맡을 단계 논의 |
| 3 | Julia 1.13 | 2026-11-24 | Julia에서 가져올 만한 것이 있는지 질문 |

## 1. Nim 3.0 (Nimony)

### 1.1 출처와 범위

- 원문: Araq, "Nimony: Design principles", https://nim-lang.org/araq/nimony.html (2025-05-03, 2025-05-10 수정).
  "a new compiler for a variant of Nim which will become Nim 3.0, eventually"라고 스스로 소개한다.
- 원문은 사양이 아니라 원칙 글이다. 출시 목표는 2025년 가을이었고, 이 검토는 그 글 한 편만 읽었다.
  nim-lang/nimony 저장소의 지금 상태나 그 뒤의 글은 확인하지 않았다. 아래 "Nimony"는 이 글의 Nimony다.
- 사이버 쪽 근거는 `docs/docs.md`, `docs/history/*`, `docs/decisions/*`, `src/std/os.cy`다.
  처음 쓸 때는 빌드 도구가 없어 코드를 실행하지 못했다. 같은 날 로컬 Debug CLI(master `ab63ffd4`)로 사이버 쪽 주장과 예제를
  다시 확인했고, 확인한 결과를 해당 자리에 적었다. Nimony 원문의 인용은 다시 확인하지 않았다.

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
  검사한다. 실행 확인: trait 매개변수 함수 `fn describe2(s Shape)`의 본문에 없는 메서드(`s.perimeter()`)를 써도 부르기 전에는
  통과하고, `describe2(Circle{r=1})`를 부르면 'Can not find the symbol `perimeter` in `Circle`.'가 본문 위치에 난다. 호출 위치는
  나오지 않는다. 사용자 템플릿 타입의 쓰지 않는 메서드(`Box[Array[int]]`의 복사하는 메서드)도 오류 없이 통과했다.
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
`Unknown` · `UnknownError` · `Unexpected` 셋이다. 앞의 넷과 `Unknown`은 `.cy`(`os.cy` · `os.windows.cy`)에 있고,
`UnknownError`(`os.zig`) · `Unexpected`(`os_ffi.zig` · `builtins/core.zig`)는 Zig 쪽이라 스크립트에 그대로 보이는지는 따로
확인해야 한다. Windows 경로는 `fromErrno` 대신 `os.windows.cy`가 자체 매핑(`AccessDenied` · `Unknown`)을 쓴다.

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
   지금 문서가 Back references 절(옛 Weak references 절, 2026-11-24 약한 참조를 계획에서 뺌)에서 권하는 우회와 같은 말이다.

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
   중". `src/sema*.zig`에서 이런 문구를 찾지 못했고, 위 1.3.4의 실행 확인에서도 오류는 본문 위치만 짚었다.
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

결정(2026-11-20, 사용자): A는 0.5에 넣고 옛 이름은 언어 별칭 없이 릴리스 노트 호환성 절로 처리한다. A는 같은 날 넣었다(`project_os_error_names.md`. 새 모듈 대신 `os`가 이름을 돌려준다). C는 1단계(인스턴스화
경로 오류 문구)만 0.5 전에 한다. 1단계는 2026-11-20에 넣었다('While specializing ... here:' 주석, `docs/releases/0.4.16.md`). B · C 2 · 3단계 · D는 0.5 뒤다.

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
  `project_borrow_model.md`, `docs/history/ownership_memory.md`다. 2.2 · 2.3.3 · 2.4 B · C의 예제는 같은 날 Debug CLI로 돌려 확인했다.

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

`move` 없이 `total(xs)`라 쓰면 'Cannot copy `Array[int]`, type implements `NoCopy`.'다(실행 확인).

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
- 이동은 같은 블록에서 선언한 변수에만 쓸 수 있다(`src/sema.zig` `semaExprNoCheck`의 `.move_expr`, "Can only move variable declared in the same block.").
  이유는 부분 이동 절이 적은 것과 같다. "the state at the end of the block is known without runtime flags". Rust의 drop flag도,
  Nim의 `=wasMoved` 상태도 쓰지 않는 설계다.
- sema에는 마지막 사용 분석이 없다(`last use` · `liveness` 같은 이름을 grep으로 찾지 못함).
- 그 결과 세 군데에 구멍이 있다.
  1. `Slice` 별칭: `Slice.clone_on_resize`(`src/builtins/core.cy`)는 빌린 `&Slice` 수신자에서 `@isUniqueRef`가 참이면 버퍼를
     그대로 돌려준다. 2026-11-01 결정은 해제 정확성만 버퍼 헤더로 고쳤고, 값 의미는 마지막 사용 분석이 필요해 남겼다(후보 2).
  2. 빌림의 비어휘적 수명: 빌림 수명은 어휘적이다. 매뉴얼은 한때 `elem := &a[2]; a << 4`가 된다고 약속했지만, F-25를 닫으며
     구현에 맞춰 "The compiler does not shorten a borrow to its last use."로 고쳤다(`project_borrow_model.md`, `33ba575e`).
     지금은 `elem`을 안쪽 블록에 두라고 안내한다.
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

갱신(2026-11-21): 아래의 틀린 결과는 `project_slice_append_aliasing.md` 결정 3(2026-11-17)으로 없어졌다. 대신 마지막 사용의 버퍼
재사용을 넣었다. D · E도 넣었고 A는 따로 만들지 않았다. `project_last_use.md`.

`append` · `+` · `insert`처럼 `clone_on_resize`를 거치는 연산에서, 수신자가 마지막 사용이면 소유로 넘겨 제자리 갱신을 허용하고,
아니면 갱신 전에 복사한다. 슬라이스 문서의 후보 2이고 Lean 4 · Koka의 소유 인자와 같은 규칙이다.

~~~cy
a := []str{'x', 'y'}
b := a.size_down(0)
print(a[0])       -- 지금: `a`와 `b`가 버퍼를 나눠 써서 해제된 칸을 읽는다(06장 미완 지점)
                  -- 제안: `a`가 뒤에서 쓰이므로 `size_down` 전에 복사, 'x'

xs := []int{}
for 0..1000 |i|:
    xs = xs.append(i)   -- `xs`는 대입 직전 마지막 사용이라 지금처럼 제자리
~~~

실행 확인: 원소를 힙 문자열(`'x'.repeat(40)`)로 바꾸면 Debug CLI가 `print(a[0])`에서 `retain dangling ptr`를 낸다. 짧은
문자열은 힙 객체가 아니라 그대로 `x`가 찍혀 증상이 숨는다.

장점: 이미 알려진 미결을 닫는다. 문서와 테스트가 쓰는 `xs = xs.append(x)` 모양은 속도가 그대로다.
단점: 받는 쪽을 남기는 코드는 복사 비용이 생긴다. 지금은 그 코드가 틀린 결과를 내므로 받아들일 만하다.

#### C. 빌림의 비어휘적 수명 — 첫 소비자 후보 2

구현(2026-11-21): A 없이 sema 안의 문장 단위 선행 조사로 했다. 빌림 검사가 IR을 만들며 함께 돌기 때문이다. 경계와 근거는
`project_borrow_model.md` "비어휘적 수명".

빌림 지역의 수명을 블록 끝이 아니라 마지막 사용까지로 줄인다. Rust 2018의 NLL과 같은 변화다. 매뉴얼은 지금 어휘적 수명을
규칙으로 적고 있으므로 이 절은 규칙을 넓히는 변경이고, 매뉴얼의 Borrows 절과 `project_borrow_model.md`의 결정을 함께 고친다.
다만 지금 거절하는 코드를 허용하는 쪽이라 기존 코드는 깨지지 않는다. `project_borrow_model.md`의 계수(`active_borrows` ·
`active_ex_borrows`)를 블록 끝이 아니라 마지막 사용 뒤에 내리면 된다. 그 문서도 "필요해지면 선행 패스로 각 빌림 지역의 마지막
사용 문장을 구한다"고 남겨 두었다.

~~~cy
a := Array[int]{1, 2, 3}
elem := &a[2]
print(elem.*)
a << 4            -- 지금: ``Expected exclusive access. There is another active borrow to `a`.``(실행 확인) / 제안: `elem`이 끝났으므로 허용
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
- sema(`sema.zig` 약 12.7K줄)에 새 분석 단계가 들어간다. 생성기 · fiber의 멈춤 지점, `scope` 블록의 빌림, `try` 블록의 `else` 경로가
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
3. 첫 소비자를 B(`Slice` 값 의미, 알려진 틀린 결과)와 C(빌림 NLL, 어휘적 수명 규칙을 넓힘) 중 무엇으로 할지.
   추천은 C다. 거절하던 코드를 허용하는 쪽이라 기존 코드가 깨지지 않고, 틀려도 피해가 "허용하지 말았어야 할 빌림"에 한정되어
   검증 범위가 작다. 매뉴얼의 어휘적 수명 규칙은 함께 고쳐야 한다(2.4 C).
4. D(암시적 이동)를 넣을지, 넣는다면 명시적 `move`를 단언으로 다시 정의할지.
5. E(분기 안 이동)에서 `@deinit`을 갈래 끝으로 앞당기는 것을 받아들일지.

결정(2026-11-20, 사용자, 권고대로): 1은 `project_direction.md`에 적는다. 2는 0.5 뒤 첫 설계 과제로 두고
`project_last_use.md`부터 쓴다. 3은 C(빌림 NLL)다. 4 · 5는 그 문서에서 따로 정한다.

## 3. Julia 1.13

### 3.1 출처와 범위

- Julia 공식 매뉴얼의 다섯 장을 2026-11-24에 읽었다: Running External Programs, Conversion and Promotion, Methods(앞부분),
  Functions, Strings. 주소는 `https://docs.julialang.org/en/v1/manual/` 아래다. 페이지 바닥글은 "Using Julia version 1.13.4"이고,
  내려받기 페이지는 안정판 1.13.4(2026-11-13), LTS 1.10.14라고 적는다. 아래의 인용은 이 장들에서 왔다.
- 매뉴얼에서 확인하지 못해 일반 지식으로 적은 것: `ignorestatus`의 뜻, `r"..."`가 `@r_str` 매크로 호출로 바뀐다는 것,
  specificity의 정확한 계산 규칙, 3.5 · 3.6의 역사와 평가. 해당 자리에 "(일반 지식)"이라고 적었다.
- 사이버 쪽 근거는 `docs/docs.md`, `src/sema_expr.zig`(`semaBinExpr`), `src/builtins/core.cy`, `src/std/os.cy` · `os.zig`,
  `src/std/regex.cy`, `docs/decisions/*`다. 이번에는 코드를 실행하지 못했다. 컨테이너에 Zig가 없었고 릴리스 바이너리 실행은
  세션 권한에서 막혔다. 사이버의 동작은 매뉴얼과 소스를 읽어 적었고, 채택 결정 전에 로컬 CLI로 다시 확인해야 한다.
  제안의 예제 코드는 모두 가상이다.

### 3.2 개요

Julia(2012 공개, 2018 1.0)는 "두 언어 문제"를 풀려고 만든 언어다. 탐색은 Python · MATLAB으로, 속도가 필요한 부분은 C · Fortran으로
쓰던 과학 계산을 한 언어로 하겠다는 것이다(일반 지식). 설계는 한 문장으로 줄일 수 있다. 동적 타입 언어의 모든 함수를 다중
디스패치의 제네릭 함수로 만들고, 호출된 인자 타입 조합마다 JIT(LLVM)으로 특수화한다.

사이버와는 출발점이 반대다. Julia는 동적 타입 + JIT + tracing GC이고, 사이버는 정적 타입 + 바이트코드 VM + 소유권 · ARC다.
그래서 Julia의 핵심(동적 다중 디스패치, 매크로, JIT 특수화)은 거의 옮길 수 없다. 가져올 만한 것은 핵심의 바깥, Julia가 "스크립트
언어로도 쓰기 좋게" 다듬은 자리에 몰려 있다. 사이버의 용도(Python · Perl · Shell 대용, `project_direction.md`)와 겹치는 자리다.

| 영역 | Julia의 선택 | 동기 |
| --- | --- | --- |
| 디스패치 | 모든 인자의 런타임 타입으로 가장 구체적인 메서드를 고름. 모호하면 오류 | 수치 코드의 이항 연산은 왼쪽 인자의 소유가 아니다 |
| 수치 승격 | 인자를 자동 변환하지 않음. `promote`를 부르는 포괄 메서드와 `promote_rule` | 승격 규칙을 라이브러리가 정의하고 확장한다 |
| 원소별 연산 | `f.(xs)` 점 문법. 겹친 점 호출은 한 루프로 합쳐짐(문법 차원의 보장) | 벡터화 코드의 임시 배열 제거를 최적화기에 맡기지 않는다 |
| 외부 명령 | 백틱은 `Cmd` 값을 만듦. shell을 거치지 않음. `pipeline`으로 조립 | shell 문자열 조립의 인용 · 주입 문제 제거 |
| 문자열 리터럴 | 접두 식별자가 붙은 비표준 리터럴(`r"..."`) | 정규식 같은 작은 언어를 리터럴로 |
| 도구 | REPL의 도움말 · shell 모드, `@which` · `@code_lowered` 계열(일반 지식) | 컴파일 단계를 언어 안에서 들여다본다 |

### 3.3 핵심 디자인과 사이버의 현재 위치

각 항목은 "Julia / 사이버 지금 / 판정" 순서다.

#### 3.3.1 다중 디스패치와 모호성

- Julia: "the most specific method applicable to those arguments is applied." 가장 구체적인 메서드가 하나로 정해지지 않으면
  "Julia raises a `MethodError` rather than arbitrarily picking a method."다. 매뉴얼의 예는 `g(x::Float64, y)`와
  `g(x, y::Float64)`를 두고 `g(2.0, 3.0)`을 부르는 것이고, 오류는 `g(::Float64, ::Float64)`를 정의하라고 알려 준다.
- 사이버 지금: 오버로드는 컴파일 시점에 정해진다. 1단계는 암시적 변환 없는 정확한 일치(선언 순서 무관), 2단계는 선언 순서대로
  암시적 변환을 허용한 첫 후보다(`project_overload_exact_match.md`). 매뉴얼도 그대로 적는다. "When more than one overload can take
  the argument, the first declared one is used". `tag(x ?str)`와 `tag(x ?int)`가 있을 때 `tag(none)`은 먼저 선언한 `?str`로 간다.
  런타임 디스패치는 trait 객체(`^Dyn[T]`)의 수신자 하나뿐이다.
- 판정: 동적 다중 디스패치는 가져오지 않는다. 런타임 타입 격자와 메서드 표, 그리고 그것을 빠르게 만들 JIT가 필요한데 사이버는
  JIT를 지웠다. 정적 타입 언어에서 오버로드 + 템플릿 특수화는 이미 컴파일 시점의 다중 디스패치다.
  가져올 것은 규칙 하나다. "임의로 고르지 않고 오류를 낸다"(3.4 C).

#### 3.3.2 수치 승격과 이항 연산자

- Julia: "the arguments of functions are never automatically converted." 섞인 타입의 산술은 포괄 메서드가 받는다.

~~~julia
+(x::Number, y::Number) = +(promote(x,y)...)

promote_rule(::Type{Float64}, ::Type{Float32}) = Float64
~~~

  규칙은 한 방향만 적는다. "one does not need to define both `promote_rule(::Type{A}, ::Type{B})` and
  `promote_rule(::Type{B}, ::Type{A})`"이고 대칭은 승격 과정이 보장한다. `1 + 2.5`와 `2.5 + 1`은 같은 길을 간다.
- 사이버 지금: 이항 산술은 왼쪽 피연산자가 정한다. `semaBinExpr`은 왼쪽이 `float`이면 오른쪽을 `float`에 맞추고, 왼쪽이 `int`이고
  오른쪽이 `float`이면 'Expected `int`, found `float`.' 오류를 낸다. 폭이 다른 정수끼리는 큰 쪽으로 넓힌다(여기는 대칭이다).
  왼쪽이 숫자 리터럴이면 오른쪽에서 타입을 가져온다. 사용자 타입의 연산자는 왼쪽 타입의 메서드에서만 찾는다(소스 주석
  "Look for sym under left type's module").

~~~cy
i := 7
f := 2.5
print(f * i)    -- 17.5
print(i * f)    -- CompileError: Expected `int`, found `float`.

v := math.Vec2[float]{x=1, y=2}
print(v * 2.0)  -- `fn (Vec2[]) *(scale T)`가 받는다
print(2.0 * v)  -- 왼쪽이 `float`라 오른쪽을 `float`에 맞추려다 오류(소스 읽기 기준)
~~~

- 판정: 가져올 가치가 크고 작다. 암시적 변환 표는 이미 `Int[X]` → `Float[W]`를 허용한다. 빠진 것은 대칭뿐이다. 곱셈의 교환
  법칙이 타입 검사에서 깨지는 것은 Python 대용 언어에서 첫날 만나는 걸림돌이다(3.4 B).

#### 3.3.3 원소별 연산과 루프 융합

- Julia: "any Julia function `f` can be applied elementwise to any array (or other collection) with the syntax `f.(A)`."
  겹친 점 호출은 "_fused_ into a single `broadcast` loop"이고 이것은 "a _syntactic guarantee_"다. 결과 배열 하나만 할당한다.
  융합은 점이 없는 호출을 만나면 멈춘다. 함수 연결은 `1:10 |> sum |> sqrt`, 마지막 인자의 익명 함수는 `do` 블록으로 쓴다.
- 사이버 지금: `Slice`에는 `map` · `filter` · `reduce`가 없다(`core.cy`의 `Slice` 메서드 목록). 매뉴얼은 `filter`를 손으로 쓴 예를
  싣는다. 고차 함수를 더해도 걸림돌이 남는다. 클로저는 `^T` · `&T` 변수만 캡처한다. "A local variable that is not a reference can
  not be captured yet: borrow it first." 그래서 지역 변수 `limit`와 비교하는 `|x| x > limit`는 먼저 `l := &limit`를 적어야 한다.
  `do` 블록에 해당하는 것은 이미 있다(`queue_task(.high_priority, |_|):` 뒤의 블록).
- 판정: 점 문법 자체는 가져오지 않는다. 다차원 배열과 broadcast 규칙이 있어야 값을 하고, 사이버에는 그 타입이 없다.
  가져올 것은 원칙이다. 융합을 최적화기의 약속이 아니라 문법이 정하는 사실로 만든다. 사이버에서는 "식이 루프로 낮춰진다"는
  형태가 되고, 클로저 캡처 제약을 피해 가는 길이기도 하다(3.4 D).

#### 3.3.4 외부 명령: `Cmd`

- Julia: "Instead of immediately running the command, backticks create a `Cmd` object to represent the command." 그리고
  "The command is never run with a shell." 보간은 문자열 붙이기가 아니라 인자 단위다. 공백이 든 경로를 보간하면
  "Julia knows that `file` is meant to be interpolated as a single argument"이고, 배열을 보간하면 원소마다 인자 하나가 된다.

~~~julia
files = ["/etc/passwd", "/Volumes/External HD/data.csv"]
run(`grep foo $files`)                         # 인자 3개. 공백이 든 경로도 인자 하나

run(pipeline(`echo hello`, `sort`))            # '|' 대신 pipeline
run(pipeline(`do_work`, stdout=pipeline(`sort`, "out.txt"), stderr="errs.txt"))
run(Cmd(`pwd`, dir="/"))
out = readchomp(`echo hello`)                  # "hello"
~~~

  실패는 값이 아니라 예외다. "If the external command fails to run successfully, the run method throws an
  `ProcessFailedException`." 종료 코드를 직접 보려면 `ignorestatus`를 쓴다(일반 지식).
- 사이버 지금: `os.exec(args) -> ExecResult{out, err, code}` 하나다(`src/std/os.cy`, `os.zig`). 인자 목록을 받아
  `std.process.run`으로 바로 실행하므로 shell을 거치지 않는다. 가장 중요한 원칙은 이미 지킨다. 없는 것은 나머지 전부다.
  stdin 입력, 파이프 연결, 작업 디렉터리 · 환경 변수, 파일 리다이렉션이 없다. 출력은 10 MiB까지 모아서 한 번에 돌려준다.
  0이 아닌 종료 코드는 오류가 아니라 `code` 필드라서 확인을 빼먹으면 조용히 지나간다. 신호로 죽으면 `code`는 -1이다.
  문서 주석은 "Runs a shell command"라고 적는데 사실과 다르다. 파이프가 필요하면 shell에 문자열을 넘기는 수밖에 없다.
  0.3 문법으로 남아 있는 `src/test/cli_test.cy`의 `runPipeInput`이 그렇게 쓴다(`'/bin/bash', '-c', '$(cmd) | $(cyber) temp.cy'`).
  Julia가 없애려던 바로 그 모양이다.
- 판정: 이 절에서 가장 먼저 가져올 항목이다. Shell 대용이 용도인 언어에서 프로세스 조립은 표준 라이브러리의 중심이고,
  에이전트가 쓴 스크립트가 외부 입력을 shell 문자열에 넣는 것은 주입 문제다(3.4 A).

#### 3.3.5 비표준 문자열 리터럴

- Julia: "A non-standard string literal looks like a regular double-quoted string literal, but is immediately prefixed by an
  identifier". 정규식은 `r"..."`이고 보간과 이스케이프 해석 없이 만들어진다. `xyz"..."`는 `@xyz_str` 매크로 호출이라 리터럴은
  코드가 읽히는 시점에 한 번 처리되고, 사용자가 새 접두를 정의할 수 있다(일반 지식. Strings 장은 이 부분을 적지 않는다).
- 사이버 지금: 백틱이 이스케이프 없는 raw 문자열이라 `r"..."`의 절반(이스케이프)은 이미 있다. 나머지 절반이 없다.
  `regex.compile(pat)`은 런타임에 `!Regex`를 돌려주므로, 상수 패턴의 오타도 실행해야 드러나고 호출마다 `!`가 붙는다.
  `peg`와 `time`의 형식 문자열도 같다. 컴파일 타임 평가기는 "can not emulate the entire language"이고 `float` 덧셈 같은 연산을
  아직 평가하지 못한다. `regex.cy`의 패턴 컴파일러를 컴파일 타임에 돌릴 수 있는지는 확인하지 않았다.
- 판정: 방향은 좋지만 지금은 이르다(3.4 F).

#### 3.3.6 REPL과 들여다보기

- Julia: REPL에서 `?`는 도움말 모드, `;`는 shell 모드다. `@which f(1, 2.0)`은 그 호출이 고르는 메서드를, `@code_lowered` ·
  `@code_typed` · `@code_native`는 컴파일 단계별 결과를 보여 준다(일반 지식).
- 사이버 지금: REPL 명령은 `.exit` 하나다. 재료는 CLI에 흩어져 있다. `cyber doc <절>`은 매뉴얼을, `cyber doc --api <모듈>`은
  시그니처와 문서 주석 첫 줄을, `cyber compile`은 바이트코드를 낸다(core까지 6천 줄).
- 판정: 작고 이득이 분명하다. 2단계 오버로드와 템플릿 특수화가 있는 언어에서 "이 호출은 어디로 가는가"는 사람도 에이전트도
  묻는 질문이다(3.4 E).

#### 3.3.7 이미 같은 자리에 있는 것

- 반복 프로토콜: Julia의 `iterate(iter, state)`는 상태를 컬렉션 밖에 둔다(일반 지식). 사이버의 `iterator() -> S`와
  `next(state &S) -> ?T`가 같은 모양이다(`Slice.iterator() -> int`, `Slice.next(idx &int) -> ?T`).
- `do` 블록과 줄 끝 람다 블록(3.3.3). 자원 정리는 Julia가 `open(f) do io ... end`로, 사이버가 `@deinit`으로 한다.
- 구체 타입은 상속하지 않고 추상 쪽으로만 묶는다. Julia는 추상 타입, 사이버는 trait다.
- 구조적 동시성: Julia의 `@sync` 블록과 사이버의 `scope` 블록.

### 3.4 가져올 만한 것

우선순위는 용도(스크립트 CLI, 에이전트 루프)에 닿는 순서다. A · B · E는 0.5의 일(fiber 동시성 완성)을 밀어내지 않는 크기다.

#### A. 명령을 값으로 (Julia `Cmd` · `pipeline`) — 작음~중간, 언어 변경 없음

원칙 넷을 가져온다. 문법(백틱)은 가져오지 않는다. 사이버의 백틱은 raw 문자열이다.

1. 명령은 문자열이 아니라 값이다. 만드는 것과 실행하는 것이 나뉜다.
2. shell을 거치지 않는다. 인자는 다시 쪼개지지 않는다(지금도 지킨다).
3. 파이프와 리다이렉션은 값의 조립이다. shell 문자열로 돌아갈 이유를 없앤다.
4. 실패한 종료는 기본이 오류다. 사이버에서는 예외가 아니라 `!T`이므로 호출 지점마다 `!`로 보인다. Julia보다 낫다.

~~~cy
-- 제안 모양(가상, 아직 없는 API).
use os

-- 실행하고 stdout을 받는다. 0이 아닌 종료는 error.ExitStatus.
branch := os.cmd({'git', 'rev-parse', '--abbrev-ref', 'HEAD'}).read()!.trim()

-- 파이프: shell 없이 프로세스 둘을 잇는다.
top := os.cmd({'du', '-sk', dir}).pipe(os.cmd({'sort', '-rn'})).read()!

-- 디렉터리 · 환경 · stdin · 종료 코드 직접 확인.
res := os.cmd({'make', 'test'}).dir('build').env('CI', '1').run_status()
if res.code != 0:
    eprint(res.err)

-- 인자 목록 조립은 슬라이스 연산 그대로다. 경로에 공백이 있어도 인자 하나다.
args := []str{'grep', '-n', pattern} + files
hits := os.cmd(args).read() !else ''
~~~

할 일: `Cmd` 타입(인자 · 디렉터리 · 환경 · stdin · 다음 단계), `run() -> !void` · `read() -> !str` · `run_status() -> ExecResult`,
`os.exec`는 `run_status`의 별칭으로 남기고 문서 주석의 "shell command"를 고친다. 줄 단위로 읽는 스트리밍과 실행 중 중단
(`project_vm_interrupt.md`가 남긴 "호스트 함수 안에서는 끊지 못한다")은 다음 단계로 둔다.

장점: 용도의 한가운데다. 언어 규칙을 건드리지 않는다. `deny_raw_ptrs`처럼 호스트가 막을 표면도 `os` 모듈 하나로 유지된다.
단점: 플랫폼마다 구현이 갈린다(Windows의 파이프 · 인자 인용). `Cmd`가 `NoCopy`인지, 파이프 양쪽의 실패 중 무엇을 오류로 올릴지
(bash `pipefail`의 문제) 정해야 한다.

#### B. 대칭 수치 승격과 양쪽 연산자 조회 (Julia `promote`) — 1은 작음, 2는 중간

1. 수치: `int op float`를 `float op int`와 같게 한다. 왼쪽이 `int` · `raw`이고 오른쪽이 `float`이면 왼쪽을 오른쪽 타입에 맞춘다.
   새 변환을 만드는 것이 아니라 표에 이미 있는 `Int[X]` → `Float[W]`를 양쪽에 적용하는 것이다. 지금 오류인 코드만 통과하게
   되므로 기존 스크립트는 깨지지 않는다. `promote_rule` 같은 사용자 확장 장치는 가져오지 않는다. 내장 수치 타입이 닫혀 있다.
2. 사용자 타입: 왼쪽 타입에서 연산자 메서드를 찾지 못하면 오른쪽 타입의 모듈에서 찾는다. `2.0 * v`를 `Vec2` 쪽이 정의할 수
   있게 된다. 정의하는 꼴은 결정 문서에서 정한다. 후보는 Python의 `__rmul__`처럼 반사 메서드를 두는 것과, Julia · C++처럼 두
   피연산자 타입을 다 적는 자유 함수 `` fn `*`(s float, v Vec2) ``를 두는 것이다. 사이버는 자유 함수 오버로드가 이미 있어 뒤쪽이
   새 개념을 덜 만든다.

지켜야 할 경계는 Julia의 교훈에서 온다. 연산자 정의는 두 피연산자 타입 중 하나를 선언한 모듈에만 둔다(Rust의 orphan rule과
같은 뜻). Julia는 이 제한이 없어 남의 타입에 남의 함수를 정의하는 "type piracy"가 관례로만 금지된다(일반 지식).

장점: 수학 표기와 맞는다. 1은 몇 줄이다. 단점: 2는 연산자 조회가 한 곳에서 두 곳으로 늘어 오류 문구("어느 쪽에서 찾았고 왜
없는가")를 다시 써야 한다. 1을 넣으면 `int`로 계산할 생각이던 식이 조용히 `float`가 되는 경우가 생기지만, 반대 순서에서는 이미
그렇다.

#### C. 오버로드 모호성은 오류 (Julia `MethodError: ... is ambiguous`) — 중간, 호환성 주의

2단계에서 둘 이상의 후보가 암시적 변환으로 맞고 어느 쪽도 더 구체적이지 않으면, 먼저 선언한 것을 고르는 대신 오류를 내고
Julia처럼 고칠 길을 알려 준다. `project_overload_exact_match.md`가 "하지 않은 것"으로 남긴 항목이다.

~~~cy
fn tag(x ?str) -> str: return 'str'
fn tag(x ?int) -> str: return 'option int'

print(tag(none))
--> 지금: 'str'(먼저 선언한 쪽)
--> 제안: error: `tag(none)` is ambiguous between `fn tag(?str)` and `fn tag(?int)`. Write `tag(?str(none))`.
~~~

선언 순서가 뜻을 정하지 않는다는 원칙은 F-21에서 1단계로 반쯤 세웠다. 이 항목은 나머지 반이다. 기존 스크립트가 깨질 수 있으므로
먼저 LSP의 Warning 진단으로 넣고, core · std의 오버로드가 몇 곳 걸리는지 센 뒤에 오류로 올린다. "더 구체적"의 정의는 좁게
잡는다(`T`가 `?T` · `!T`보다, `int`가 `float`보다 구체적). Julia의 specificity 규칙은 타입 격자 전체를 다뤄 복잡하고, 생태계가
커지면 패키지 조합에서 모호성이 터지는 문제로 이어졌다(일반 지식). 사이버는 오버로드 집합이 모듈 안에 닫혀 있어 그 문제는 작다.

#### D. 루프로 낮추는 컬렉션 식 (Julia의 문법 차원 융합) — 중간, 문법 추가

컬렉션을 만드는 식을 클로저 호출이 아니라 `for` 루프와 `append`로 낮춘다. 본문은 바깥 블록의 문장이 되므로 지역 변수를 그대로
읽는다. 캡처도, 중간 슬라이스도 없다는 것이 문법으로 정해진다.

~~~cy
-- 제안 모양(가상). 문법은 결정 문서에서 정한다.
limit := 3
big := []int{x * 2 for xs |x| if x > limit}

-- 낮춘 결과
big := []int{}
for xs |x|:
    if x > limit:
        big += x * 2
~~~

원소가 먼저 온다(Python · Julia의 순서, 2026-11-24 사용자 결정). 처음 초안은 문장이 먼저인 `{for xs |x| if x > limit: x * 2}`였다.
그 꼴은 중괄호 안이 블록으로 읽혀 안쪽에 빈칸을 두고 싶어지고, 블록을 여는 `:`가 한 줄 식 안에 들어온다. 원소가 먼저면
`{x * 2`가 보통 리터럴 `[]int{a * 2, b}`와 같은 모양으로 시작해 "중괄호 안쪽은 붙여 쓴다"는 포매터 규칙
(`project_fmt_brace_style.md`)이 그대로 맞는다. 대가는 `x`가 선언(`|x|`)보다 먼저 나온다는 것이다.

절을 여는 낱말은 정하지 않았다. `for`는 사이버에서 늘 줄 맨 앞에서 블록을 여는 문장 키워드이고, `for xs |x|`는 반복 대상이
먼저라 Python의 `for x in xs`처럼 영어 문장으로 읽히지도 않는다. 후보:

~~~cy
big := []int{x * 2 for xs |x| if x > limit}     -- 문장과 같은 낱말. 새 낱말이 없다
big := []int{x * 2 from xs |x| if x > limit}    -- 권고. "xs에서 꺼낸 x * 2"
big := []int{x * 2 each xs |x| if x > limit}    -- 매뉴얼의 용어("for each", "each variable")
~~~

- `from`: 반복 대상이 먼저 오는 순서와 맞게 읽힌다. destructure import(`use { cos, pi } from 'math'`)로 이미 들어올 낱말이고 뜻도
  같다(출처에서 꺼낸다). SQL · LINQ의 `select ... from ...` 계보다. `json.from` 함수와 `regex.cy`의 지역 변수 `from`이 있어
  예약어가 아니라 문맥 키워드여야 한다. 원소 식 바로 뒤에 식별자가 오는 자리는 지금 문법에 없어 모호하지 않을 것으로 보지만,
  파서로 확인하지는 않았다.
- `each`: 매뉴얼의 용어와 맞지만 새 낱말이고, 영어로는 "for each"의 반쪽이다.
- `loop`: `for`와 같은 문장 낱말이라 어색함이 그대로 남고, 새 예약어가 필요하며, Rust에서는 무한 루프다. 권하지 않는다.
- 거르는 절은 어느 쪽이든 `if`로 둔다(Python · Julia와 같다). `where`는 낱말을 하나 더 들인다.

`xs = xs.append(x)` 꼴의 제자리 재사용(`project_last_use.md`)이 이미 있어 낮춘 루프의 비용은 손으로 쓴 것과 같다.
장점: Python에서 오는 사용자와 모델이 가장 먼저 찾는 표현이다. 클로저 캡처 규칙을 넓히지 않고 얻는다.
단점: 문법이 늘고 포매터 · tree-sitter · LSP가 따라가야 한다. `map` · `filter` 메서드를 먼저 더하고 캡처 규칙을 푸는 쪽이
일반적인 답일 수 있다. 둘은 배타가 아니지만 순서는 정해야 한다. `|>` 연산자는 가져오지 않는다. 메서드 연결이 같은 일을 하고
`|`는 캡처 절이 쓴다.

#### E. REPL 조회 명령 (Julia `?` · `@which`) — 작음

- `?name` 또는 `.doc name`: `cyber doc`의 절이나 `--api`의 시그니처 · 문서 주석을 REPL 안에서 보여 준다. 재료는 실행 파일에 있다.
- `.which f(1, 2.5)`: 식을 실행하지 않고 sema만 돌려, 고른 오버로드의 시그니처와 선언 위치, 템플릿이면 특수화 인자를 찍는다.
  `matchFuncSym`의 결과를 내보이는 것이다. C의 모호성 진단과 재료가 같다.
- `.bc f`: 함수 하나의 바이트코드만 덤프한다(`cyber compile` 출력에서 한 구간).

임베딩에서는 같은 것을 `libcyber` 함수로 주면 에이전트가 "이 이름이 있는가, 어떤 인자를 받는가"를 실행 전에 물을 수 있다.
Julia의 shell 모드(`;`)는 가져오지 않는다. A가 들어가면 `os.cmd`로 충분하다.

#### F. 컴파일 타임에 검증되는 리터럴 (Julia 비표준 문자열 리터럴) — 큼, 나중

상수 패턴을 컴파일 시점에 검사해 오류를 `CompileError`로 올리고 `!`를 없앤다. 문법보다 능력이 먼저다. 컴파일 타임 평가기가
`regex.cy`의 파서를 돌릴 수 있어야 하는데 지금은 "Unsupported inline eval"이 남아 있다. 평가기를 넓히는 일이 따로 정해지면 그때
첫 사용처로 본다. 그 전의 싼 대안은 LSP가 `regex.compile`의 문자열 리터럴 인자를 미리 컴파일해 진단으로 보여 주는 것이다.

### 3.5 Pros vs Cons: Julia 접근 자체

장점

- 다중 디스패치가 표현 문제(expression problem)를 실용적으로 푼다. 새 타입과 새 연산을 서로 다른 패키지가 더해도 조합된다.
  수치 생태계의 조합성이 여기서 나왔다(일반 지식).
- 승격 규칙이 언어 핵심이 아니라 라이브러리 코드다. `Int`, `Float64`조차 같은 장치로 정의된다. 사이버의 `int`가 `core.cy`의
  `Int[64]`인 것과 같은 태도다.
- 문법이 성능을 약속한다(점 융합). 사용자가 최적화기의 기분을 추측하지 않는다.
- 외부 명령 설계는 범용 언어 가운데 가장 잘 다듬어진 축에 든다. shell 없이 shell의 편의를 낸다.

단점

- 지연. 호출된 타입 조합마다 JIT로 특수화하므로 첫 호출이 느리고("time to first plot"), 새 메서드 정의가 이미 컴파일된 코드를
  무효화한다. 1.9의 네이티브 코드 캐시로 크게 줄었지만 구조의 비용이다(일반 지식). 사이버의 첫 eval은 2.8 ms다
  (`project_embedding_agent_loop.md`). 지켜야 할 자산이다.
- 인터페이스가 비공식이다. `AbstractArray`나 반복 프로토콜의 계약이 문서와 관례에 있어, 제네릭 코드가 가정한 것(예: 인덱스가
  1에서 시작)을 새 타입이 어기면 오류 없이 틀린 답이 나온다. 조합성의 그늘로 여러 번 지적됐다(일반 지식).
  사이버는 trait가 계약을 적고, 1.4 C가 본문 검사를 정의 시점으로 당기려 한다. 방향이 반대이고 사이버 쪽이 맞다.
- 모호성과 type piracy는 규모가 커질수록 는다. 둘 다 "누구나 어떤 함수에든 메서드를 더한다"의 대가다.
- REPL과 파일의 전역 스코프 규칙이 달라 1.0에서 혼란이 컸고 1.5에서 REPL 쪽을 고쳤다(일반 지식). 사이버 REPL도 재선언과
  `move`에서 스크립트와 다르다. 이런 차이의 목록은 짧게 유지한다.
- 1부터 시작하는 인덱스, 열 우선 배열은 수치 계산의 관습이다. 사이버의 용도와 무관하다.

### 3.6 영향과 현재 상황

- 다중 디스패치의 계보는 Common Lisp의 CLOS, Dylan이다. Julia는 그것을 타입 추론 · JIT와 묶어 성능의 수단으로 만들었다.
  정적 쪽의 대응물은 Haskell의 타입 클래스, Rust의 `impl Mul<Vec2> for f64`(이항 연산자를 두 타입의 쌍으로 구현),
  Swift의 연산자 오버로드다(일반 지식). 3.4 B의 2는 이 계보의 가장 좁은 형태다.
- 외부 명령을 값으로 다루는 설계는 Julia 초기(2012~2013)의 글에서 shell 호출의 문제를 정리하며 나왔다(일반 지식).
  Python의 `subprocess.run(list)`, Rust의 `std::process::Command`, Zig의 `std.process`가 같은 원칙(인자 목록, shell 없음)을
  따르지만 파이프 조립까지 값으로 만든 것은 Julia와 그 뒤의 shell 대용 라이브러리들이다. 사이버의 `os.exec`는 지금 Python의
  `subprocess.run` 자리에 있다.
- 점 융합(2017, Julia 0.6)은 "벡터화는 빠르다"는 MATLAB · NumPy의 통념을 뒤집고, 벡터화를 표기의 문제로 되돌렸다(일반 지식).
- 현재 상황: 안정판 1.13.4(2026-11-13), LTS 1.10.14. 매뉴얼의 해당 장들은 위 인용 그대로다. 채택 결정을 할 때 A는 `Cmd`의
  API 문서(`ignorestatus` · `detach`와 스트리밍용 `open(cmd)`)를, C는 Methods 장의 뒷부분을 한 번 더 읽는 것이 좋다.

### 3.7 결정할 것

1. A(`os.cmd`)를 0.5에 넣을지. 넣는다면 실패한 종료를 기본 오류로 할지, 파이프의 어느 쪽 실패를 올릴지.
2. B의 1(`int op float` 대칭)을 넣을지. 지금의 비대칭이 의도한 규칙인지부터 확인한다. B의 2는 결정 문서로.
3. C는 LSP Warning으로 먼저 넣고 세어 볼지.
4. D와 `map` · `filter` 메서드 중 무엇을 먼저 할지, 또는 둘 다 하지 않을지. D를 한다면 절을 여는 낱말(`for` · `from` · `each`).
5. E의 세 명령 중 무엇을 넣을지. `.which`는 C와 함께 하는 것이 싸다.
6. F는 컴파일 타임 평가기를 넓히는 일이 정해질 때까지 미루는 데 동의하는지.

가져오지 않기로 권하는 것: 동적 다중 디스패치와 JIT 특수화(시작 시간과 단일 백엔드), 매크로와 `@` 표기(`@`는 hook 13개의
자리이고 메타프로그래밍은 컴파일 타임 실행이 맡는다, `project_sigils.md`), 점 broadcast 문법(대상 타입이 없다), `|>`, REPL
shell 모드, 스레드 사이 채널(`project_planned_features.md`에서 이미 뺐다), 1 기반 인덱스.
