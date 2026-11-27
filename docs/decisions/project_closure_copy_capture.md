# 람다의 값 캡처 (2026-11-27)

상태: 구현됨. Mortgage Calculator 예제(`examples/mortgage.cy`)가 계기다. 입력을 묻는 함수 하나에 파싱 함수를 넘기려 했는데
`|line| parse_field(field, line)`가 'Can only capture variables declared with the reference types `^T` or `&T`.'로 거절되어
`ask_field` · `ask_mode` 두 함수로 나눠 썼다. 사용자 질문 "람다가 바깥의 지역변수를 캡처하려면 어떻게 해야해? 클로저?"에
값 복사 캡처를 권했고, 사용자가 "그래 진행해. 문서화 잘 해줘."로 받았다.

## 이전 상태

- 람다는 바로 위 함수의 지역 중 `^T`(참조)와 `&T`(빌림)로 선언한 것만 캡처했다. 다른 지역은 위 오류였다
  (`sema_local.zig`의 "TODO: Capture non-reference stack variables too.").
- `^T` 캡처는 `Func[F]` 클로저(힙 객체, 캡처 값을 retain), `&T` 캡처는 pinned closure `OpaqueFunc[F]`(빌림 컨테이너, 캡처한
  지역보다 오래 살 수 없다, F-162)다.
- 그래서 `|x| x > limit` 같은 흔한 꼴을 쓰려면 `l := &limit`을 먼저 쓰거나 `limit := ^0`으로 선언해야 했다. 2026-11-25에
  `map` · `filter`를 미룬 걸림돌도 이것이다(`project_generator_take.md`).
- 2026-11-13 정렬 검토(`project_sort_closures.md`)의 안 A는 "일반 지역을 빌려 캡처하는 pinned closure"였다. 2026-11-20 결정으로
  조사만 했고 구현은 미뤘다.

## 비교

| 언어 | 캡처 방식 | 캡처한 변수에 대입 | 밖으로 내보내기 |
|---|---|---|---|
| Rust | 필요한 만큼 빌림(`&`, `&mut`), `move`면 값(복사 · 이동) | `&mut` 캡처면 바깥이 바뀜(`FnMut`) | `move` 클로저만 |
| Zig | 클로저가 없다. 상태는 문맥 구조체로 넘긴다(`std.sort`의 `context`) | 해당 없음 | 해당 없음 |
| Nim | 참조. 캡처한 지역은 힙 환경으로 옮겨진다. 반복마다 새 값은 `closureScope` · `sugar.capture` | 바깥이 바뀜 | 된다 |
| Python | 참조(셀). 늦은 바인딩이라 반복 안의 람다는 마지막 값을 본다(`lambda i=i: i`로 우회) | `nonlocal` 선언 뒤 바깥이 바뀜 | 된다 |
| Java | 사실상 final인 지역의 값 복사 | 컴파일 오류(바깥에서 바꿔도 오류) | 된다 |
| Swift | 참조. 캡처 목록 `[x]`는 만들 때 값 복사 | 참조면 바깥이 바뀜, 캡처 목록 값은 불변 | `@escaping` |
| Go | 참조. 1.22부터 `for` 변수는 반복마다 새 변수 | 바깥이 바뀜 | 된다 |
| C++ | `[=]` 복사 · `[&]` 참조를 쓰는 쪽이 고름 | `[=]` 복사는 `mutable` 없이 대입 불가 | 복사면 안전 |

참조 캡처(Nim · Python · Swift · Go)는 캡처한 지역을 힙으로 옮긴다. Cyber에서 그것은 `^T`로 선언하는 것과 같고 이미 있다.
빌림 캡처(Rust 기본)는 `&T` 캡처로 이미 있고, 클로저가 밖으로 나갈 수 없다. 빠진 것은 "만들 때의 값을 들고 다니는" 캡처
(Rust `move` · Swift 캡처 목록 · C++ `[=]` · Java)다.

## 결정

1. `^T` · `&T`가 아닌 지역을 캡처하면 람다는 그 값의 복사를 갖는다. 복사는 람다가 만들어지는 순간 한 번 한다. 그 뒤 바깥
   지역을 바꿔도 람다는 옛 값을 보고, 반복 안에서 만든 람다는 저마다 자기 반복의 값을 갖는다(Python의 늦은 바인딩, Go 1.22
   전의 `for` 변수 문제가 생기지 않는다).
2. 람다 안에서 복사한 지역이나 그 일부에 대입하면 컴파일 오류다: 'Cannot assign to `count` in the lambda. The lambda keeps
   a copy of it from when it was created; declare it with `^T` to share it with the lambda.' 바깥이 바뀐다고 오해할
   대입(Python의 `nonlocal`이 필요한 자리)을 막고, 바꾸려면 지금처럼 `^T`로 공유한다. C++ `[=]`(`mutable` 없이)와 같다.
   메서드로 값을 바꾸는 것(`&self`)은 막지 않는다. 바뀌는 것은 람다의 복사다.
3. 복사의 깊이는 그 타입의 복사와 같다. `str`과 수는 그대로, 구조체는 필드별로, 슬라이스 `[]T`는 원소 버퍼를 공유하고 길이는
   제 것을 갖는다(`project_slice_append_aliasing.md`의 Go 같은 공유). 사용자 `@copy`가 있으면 그것을 부른다.
4. `NoCopy` 값과 빌림 컨테이너(빌림을 담은 구조체 등)는 복사할 수 없어 오류다: 'A lambda captures a copy of a local, but
   `m` of the type `Map[str, int]` can not be copied (`NoCopy`). Declare it with `^T`, or borrow it before the lambda (`b := &m`) and
   use `b` in the lambda.' `Map`이 여기에 든다(`HashMap`이 `NoCopy`). 빌림을 자동으로 만드는 안 A는 하지 않았다.
   같은 이름이 지역에 따라 복사도 되고 빌림도 되면 람다의 타입(`Func` · `OpaqueFunc`)과 수명이 보이지 않게 달라진다.
5. 복사만 캡처한 람다는 `Func[F]`다(`^T` 캡처와 같다). 만든 함수 밖으로 돌려줄 수 있고(`fn adder(n int) -> Func[...]`),
   `&OpaqueFunc` 매개변수(`sort`의 비교 함수)에도 그대로 넘어간다. `&T`도 함께 캡처하면 지금처럼 pinned closure다.
6. 캡처 범위는 그대로 바로 위 함수의 지역 하나 층이다. 정적 함수(`fn` 선언)는 여전히 캡처하지 않는다.
7. `spawn`의 진입 람다는 여전히 캡처할 수 없다(클로저는 `Sendable`이 아니다). 값 캡처로 클로저가 흔해지므로 그 오류를
   'Expected template `funcptr_t`. Found `Func`.'에서 'A closure can not be the entry of `spawn`: what it captures stays with
   this thread. Pass the values as arguments of a function instead.'로 바꿨다(`sema_call.entrySig`). `fiber:` 본문은 같은 규칙으로
   복사를 캡처한다.

## 구현

- sema(`sema_local.zig`): `captureParentLocal`이 캡처 종류를 고른다. `^T` · `&T`면 지금처럼, 아니면 `CaptureInfo.copy`를
  세우고 캡처 슬롯의 타입을 `^T`로 둔다. `NoCopy` · `borrow_only`는 위 오류. REPL 최상위(`persist_main`)는 빌림을 입력 사이에
  들고 갈 수 없어 `^T`만 권한다.
- 사용(`sema_expr.semaCaptured`): 복사 캡처는 슬롯의 `^T`를 역참조한 값이다. 지역처럼 읽힌다.
- 대입 검사(`sema_assign.checkConstPart`): 대입 왼쪽의 뿌리 이름이 복사 캡처면(`sema_local.isCopyCapture`, 아직 캡처하지 않은
  이름도 본다) 오류. `const`의 일부 대입 검사와 같은 자리다.
- 생성(`popLambdaProc`): 복사 캡처마다 `^copy(x)` IR(`ir.Lambda.copies`)을 람다 식에 단다. 바깥 문장 앞에 숨은 지역을 두는
  방식은 버렸다. `while` 조건이나 `if` 식 갈래 안의 람다에서 복사 시점이 어긋난다.
- 코드 생성(`bc_gen.gen_lambda`): 복사를 임시 레지스터에 만들고, `CLOSURE`의 캡처 레지스터 피연산자에 높은 비트
  (`heap.owned_capture_bit`)를 세워 넘긴다. VM(`Heap.allocClosure`)은 그 값을 retain하지 않고 넘겨받는다.
- pinned closure의 소유: pinned closure는 캡처 값을 참조 없이 들고 해제하지 않는다. 그래서 복사와 빌림을 함께 캡처한 람다를
  위해 클로저 객체의 `numCaptured: u64`를 `numCaptured: u32` · `owned: u32`로 나눴다(`heap.zig`, `vm.h`). `owned`의 비트 `i`가
  선 값은 pinned closure가 풀릴 때 release한다(`heap_value.zig`, `core.zig` `freePinnedClosure`). 그래서 pinned closure가
  넘겨받을 수 있는 복사는 앞 32개 캡처까지다(넘으면 컴파일 오류 'A lambda that captures a borrow can keep copies of the first
  32 captured locals only.').
  `numCaptured`는 `align(8)`(C는 `_Alignas(8)`)로 둔다. 32비트(wasm32)에서 `pc`가 4바이트라 u32 둘로 나누면 캡처 값 배열이 8바이트
  정렬을 잃어 `zAllocClosure`가 'incorrect alignment' panic을 냈다(`verify.sh` 9단계에서 잡았다).

## 비용

- 복사 캡처 하나에 `^T` 하나를 할당한다. 클로저 하나당 할당이 1 + (복사 캡처 수)다. 한 슬롯짜리 수(`int` · `float`)를 상자
  없이 슬롯에 바로 두는 최적화는 하지 않았다. 슬롯마다 release 여부가 갈려 `owned` 마스크를 일반 클로저에도 써야 한다.
  측정할 쓰임새가 생기면 본다.

## 하지 않은 것

- 안 A(일반 지역을 빌려 캡처): 4의 이유. `Map` 같은 `NoCopy` 지역은 지금처럼 `b := &m`을 먼저 쓴다.
- `map` · `filter`: 걸림돌이던 캡처 규칙이 풀렸으므로 다시 볼 수 있다. 2026-11-25 결정(설계 원칙 3.7 D, `for` 루프로 쓴다)을
  바꾸는 일이라 사용자 결정으로 남긴다.
- 람다 안의 람다가 두 층 위 지역을 캡처하는 것: 지금처럼 바로 위 층만.

## 예제에서 바뀐 것

`examples/mortgage.cy`의 `ask_field` · `ask_mode`를 `fn ask(prompt str, parse Func[fn(str) -> ?%T]) -> !?T` 하나로 합쳤다.
숫자는 `ask('%{field.name}: ', |line| parse_field(field, line))`, 모드는 `ask(ModePrompt, parse_mode)`로 묻는다.
