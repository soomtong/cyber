# 정렬과 지역을 캡처하는 클로저: 설계 검토

2026-11-13. tars-agent M0 스파이크 검토 02(`tars-agent/docs/spikes/2026-11-13-m0-spikes-review-02.md` 6.2, 7절 1)에서
나온 요청: Map 값으로 정렬할 길이 없다. 사용자 지시로 바로 구현하지 않고 Swift 같은 언어의 쓰임새를 참고해 설계를 고른다.
이 문서는 결정 전의 검토이고, 결정은 사용자가 한다.

## 지금의 상태

`sort`의 선언(`src/builtins/core.cy`):

```cy
type LessFn[T Any] = fn(T, T) -> bool
fn (&Slice[]) sort(less &OpaqueFunc[LessFn[T]])
fn (&Span[]) sort(less &OpaqueFunc[LessFn[T]])     -- 삽입 정렬
fn (&Array[]) sort(less &OpaqueFunc[LessFn[T]])
```

master `78b23f89` Debug 빌드로 실행한 결과:

| 쓰는 법 | 예 | 결과 |
|---|---|---|
| 캡처 없는 람다 | `xs.sort(\|a, b\| a < b)` | 된다 |
| 원소의 필드 | `cs.sort(\|a, b\| a.n > b.n)` (`[]Count`) | 된다 |
| 문자열 | `names.sort(\|a, b\| a.less(b))` | 된다. `str`에는 `<`가 없다(`a < b`는 'Can not find the symbol `<` in `str`.') |
| 이름 있는 함수 | `names.sort(by_len)` | 된다 |
| 전역 | `global counts ...` 뒤 `names.sort(\|a, b\| counts[a] > counts[b])` | 된다(전역은 캡처가 아니다) |
| `^T`를 캡처한 람다 | `counts := ^Map[...]` 뒤 같은 식 | 'Expected argument `&OpaqueFunc[fn(str, str) -> bool]`, found `Func[...]` ' |
| `&T`를 캡처한 람다 | `c := &counts` 뒤 `names.sort(\|a, b\| c[a] > c[b])` | '... found `OpaqueFunc[...]` ' |
| `Func` 변수 | `var f Func[F] = ...` 뒤 `xs.sort(&f)` | '... found `&Func[...]` ' |
| 일반 지역을 캡처 | `names.sort(\|a, b\| counts[a] > counts[b])` | 'Can only capture variables declared with the reference types `^T` or `&T`.' |

관련 코드:

- 람다의 타입(`sema.zig` `popLambdaProc`): 캡처가 없으면 `FuncPtr`, `^T`만 캡처하면 `Func[Sig]`, 참조가 아닌 것(`&T`)을
  캡처하면 `OpaqueFunc[Sig]`(pinned closure, `ir.Lambda.pinned_closure`). 둘 다 힙 클로저 객체다(`bc_gen.gen_lambda`,
  VM `CLOSURE`의 0x8000 비트, `zAllocClosure`).
- 캡처 제한: `sema.zig` `lookupIdent2` · `lookupSelf`의 "TODO: Capture non-reference stack variables too." 선언 타입이
  객체(`^T`)나 빌림(`&T`)일 때만 캡처한다.
- 암시 변환(`sema.zig`의 `.borrow` 목표 분기): `FuncPtr`만 `&Func` · `&OpaqueFunc`로 바꾼다(임시 값을 만들어 빌림).
  `Func` · `OpaqueFunc` 값은 바꾸지 않는다.
- `core.cy`의 `OpaqueFunc` 주석: "Cannot be moved or copied. These constraints allow it to contain a pinned closure which
  can capture locals as well as references." `sort`가 `&OpaqueFunc`를 받는 이유가 이것이다. 문서(`docs.md` Closures)는
  pinned closure를 *Still experimental*로 적는다.

정리하면 원래 설계는 "지역을 캡처한 클로저를 복사 · 이동이 막힌 값으로 만들어 그 자리에서만 쓰게 한다"이고, 구현이 그 앞에서
멈춰 있다.

## 다른 언어

아래는 언어 문서에서 널리 알려진 동작만 적었다. 구현 전에 각 언어 문서로 다시 확인한다.

Swift:

- 함수 매개변수로 받는 클로저는 기본이 non-escaping이다. 호출이 끝난 뒤에 남지 않으므로 지역을 그대로 캡처해도 안전하다.
  밖에 저장하는 클로저만 매개변수에 `@escaping`을 붙인다.
- `sort()`는 원소가 `Comparable`일 때 인자가 없다. `sort(by:)`는 비교 클로저를 받고, `sorted(by:)`는 새 배열을 돌려준다.
- 후행 클로저와 축약 인자: `names.sort { counts[$0]! > counts[$1]! }`.

Rust:

- `sort_by(|a, b| ...)`는 비교 클로저(`FnMut`)를 받고, 클로저는 지역을 빌려 캡처한다. 빌림 검사가 호출 안에서만 살아
  있음을 보장한다.
- `sort_by_key(|x| key)`는 키를 뽑는 클로저를 받는다. `sort()`는 원소가 `Ord`일 때.

공통점: 인자 자리에 바로 쓴 클로저는 그 호출 안에서만 산다고 보고 지역 캡처를 허용한다. 비교 가능한 원소는 인자 없이
정렬하고, 키를 뽑는 정렬이 따로 있다.

## Cyber에 옮기는 안

### A. `&OpaqueFunc` 자리를 non-escaping 자리로 본다 (원래 설계의 완성)

람다가 일반 지역을 쓰면 그 지역을 빌려 캡처하는 pinned closure(`OpaqueFunc`)로 만든다. `OpaqueFunc`는 복사 · 이동이
막혀 있으므로 매개변수 `&OpaqueFunc`로 빌려 줄 수는 있어도 밖으로 내보낼 수 없다. Swift의 non-escaping과 같은 성질을 타입이
준다.

```cy
counts := Map[str, int]{app=7, db=8, web=23}
names := counts.keys()
names.sort(|a, b| counts[a] > counts[b])
```

필요한 것:

1. 캡처: 일반 지역을 캡처하면 클로저에 그 지역의 주소를 담고, 본문의 사용은 역참조로 바꾼다(`captures_scope_locals`가 이미
   이 표시를 한다. 지역의 주소를 담는 경로와 사용 자리의 역참조가 새로 필요하다).
2. 새지 않음: pinned closure를 담은 지역도 복사 · 이동 · 반환 · 전역 대입이 막혀야 한다. 지금 `OpaqueFunc`의 제약이 이것을
   하는지 테스트로 확인한다. 캡처한 지역보다 클로저가 오래 살 수 없어야 한다(같은 블록 안에서 먼저 선언된 지역만 캡처).
3. 스택 이동: fiber 스택이 옮겨지면 클로저 객체(힙) 안의 스택 주소가 낡는다. `thread.patch_frame_ptrs`는 프레임 안의 포인터만
   고친다. 처음에는 fiber 안에서 지역을 캡처하는 것을 막거나, 클로저 안의 주소도 고친다. `&T` 캡처가 이미 같은 문제를 가지고
   있는지 먼저 확인한다.
4. 문서: Closures 절의 *Still experimental* 정리.

비용: 크다. sema(캡처, 사용, 제약 검사)와 런타임(스택 이동)에 걸친다. 얻는 것은 가장 자연스러운 쓰임새다.

### B. 변환과 안내만

- `Func` · `OpaqueFunc` 값과 `&Func`를 `&OpaqueFunc` 매개변수로 넘기는 암시 변환(같은 시그니처일 때, 임시 값을 만들어 빌림).
  `^T`나 `&T`를 캡처한 람다를 `sort`에 바로 쓸 수 있게 된다.
- 일반 지역 캡처 오류에 안내: "Declare `c := &counts` before the lambda and use `c`."

```cy
counts := Map[str, int]{app=7, db=8, web=23}
c := &counts
names := counts.keys()
names.sort(|a, b| c[a] > c[b])
```

비용: 작다. A의 일부라 A로 가도 버려지지 않는다. 쓰는 사람이 빌림 지역을 하나 더 써야 한다.

### C. API 보강 (A · B와 독립)

- 원소가 비교 가능하면 인자 없는 `xs.sort()`(Swift `sort()`, Rust `sort()`).
- 키를 뽑는 정렬 `xs.sort_by_key(|x| key)`(Rust 이름). 키 클로저도 캡처가 필요하면 A나 B가 있어야 Map 경우가 풀린다.
- `str`의 `<` `>` `<=` `>=`(지금 `less` · `compare`만). 모델과 사람 모두 `a < b`를 먼저 쓴다.

```cy
names.sort()                                  -- []str
cs.sort_by_key(|c| c.n)                       -- []Count, 오름차순
```

비용: 작다. 정렬 방향(내림차순)을 어떻게 쓸지 정해야 한다(`sort_by_key` 뒤 `reverse()`, 또는 키를 음수로).

## 추천

1. C의 `str` 비교 연산자와 B를 먼저 넣는다. 작고, 지금 막힌 쓰임새(`^T` · `&T` 캡처, 문자열 `<`)를 바로 푼다.
2. A는 fiber 스택 이동과의 관계를 먼저 조사하고 정한다. `&T` 캡처가 이미 안전한지가 갈림길이다.
3. `sort()` · `sort_by_key`는 이름과 방향 규칙을 정한 뒤.

## 진행 (2026-11-13)

사용자 지시 "C와 B 먼저 진행해".

- B: 넣었다. `sema.zig` 암시 변환의 `.borrow` 분기가 같은 시그니처의 `Func` · `OpaqueFunc` 값을 빌린 뒤 `&OpaqueFunc`로,
  `&Func`는 그대로 `&OpaqueFunc`로 비트캐스트한다(둘 다 같은 힙 함수 유니언이고 `opaque_` 표시만 다르다). 캡처 오류 문구:
  "... Declare it with `^T`, or borrow it before the lambda (`b := &counts`) and use `b` in the lambda." fiber 본문에서도 같은
  오류가 나므로 `^T`를 먼저 적었다.
- C: `str`의 `<` `<=` `>` `>=`(`compare`로), 인자 없는 `sort()`(`#[cond=meta.has_decl(T, '<')]`, `<`가 없는 원소에서는
  `sort()`가 없어 호출 자리에서 인자 수 오류). `sort_by_key`는 넣지 못했다:
  - `fn sort_by_key(key &OpaqueFunc[KeyFn[T, %K]])`는 람다 `|c| c.n`의 타입을 추론하지 못한다("Can not infer function
    type."). `inferLambdaFuncSig`는 목표 타입이 정해져 있어야 하고, 제네릭 `%K`를 람다 본문의 반환 타입으로 추론하는 길이 없다.
  - 키 타입별 오버로드(`KeyFn[T, int]` · `KeyFn[T, str]`)도 첫 오버로드의 목표로 람다를 검사해 'Expected type `str`, got
    `int`.'가 난다.
  - 필요한 것: 람다 매개변수는 목표에서, 반환 타입은 본문에서 추론해 제네릭 인자를 정하는 단계. 안 A와 같이 검토한다.

## 결정할 것

- A를 할지, 한다면 B · C 뒤에 할지.
- 키 정렬: 람다 반환 타입으로 제네릭을 추론하는 기능을 넣을지, 넣는다면 이름(Rust의 `sort_by_key` 또는 다른 이름).
- 인자 없는 `sort()`의 원소 조건: `<`를 가진 타입(트레이트로 둘지).

결정(2026-11-20, 사용자): A는 구현하지 않고 조사만 먼저 한다. 갈림길인 "`&T` 캡처가 fiber 스택 이동에 이미 안전한가"를 확인해
아래 절에 적는다. A 구현과 `sort_by_key`는 0.5 뒤에 다시 정한다.

## 안 A 조사 (2026-11-20)

master `1bc5426e` Debug CLI로 확인했다.

- 갈림길이던 "`&T` 캡처가 fiber 스택 이동에 안전한가"는 이미 풀려 있다. F-136(`a80b07ee`)이 pinned closure를 `Heap.pinned_closures`에
  등록하고, `Thread.growStackPrecise`가 스택을 옮길 때 `Heap.patchPinnedClosures`가 캡처 값 중 옛 스택 범위를 가리키는 것을 새
  주소로 고친다. heap은 스레드에 하나라 fiber 스택이 옮겨질 때도 같은 경로를 탄다. 테스트 `functions/closure_borrow_stack_grow.cy`가
  main 스택 · `sort` 비교자 안 · fiber 스택의 이동을 덮는다. 안 A의 필요한 것 3(스택 이동)은 남은 일이 없다.
- 대신 필요한 것 2(새지 않음)가 지켜지지 않는다. `OpaqueFunc`는 문서상 "Cannot be moved or copied"지만 sema가 강제하지 않는다.
  `&T`를 캡처한 클로저(안 B의 꼴)가 지금도 그 지역보다 오래 산다:

  | 꼴 | 결과 |
  |---|---|
  | `fn mk() -> OpaqueFunc[F]`에서 `c := &x` 캡처 클로저를 `return f` | 컴파일되고 `mk()()`가 쓰레기 값(해제된 스택) |
  | 구조체 필드 `f OpaqueFunc[F]`에 담아 반환 | 같음 |
  | `-> ^OpaqueFunc[F]`로 `^fn() ...` 반환 | 같음, 끝에 'unreleased refcount: 1' |
  | 전역 `gf = move f` | 컴파일된다 |
  | `fn keep(f &OpaqueFunc[F]) -> OpaqueFunc[F]: return f.*` | 컴파일된다(복사) |
  | 같은 블록의 `g := f` | 컴파일된다(복사) |

  빌림(`&T`)과 빌림 컨테이너는 `TypeInfo.borrow_only`로 반환(`scope` 필요) · lift · 바깥 블록 대입이 막히는데, `OpaqueFunc`는 그
  표시가 없다. 그래서 안 A 이전에 이것부터 고쳐야 한다. 안 A는 같은 제약 위에 "일반 지역의 주소를 담는 캡처"만 더한다.
- 고칠 방향: `OpaqueFunc`를 빌림 컨테이너(`borrow_only`)로 두고, 빌림을 캡처한 람다 값의 `parent_local`을 캡처한 빌림의 주인으로
  잇는다(`borrowOwner`). 반환 · lift · 전역 · 바깥 블록 대입이 기존 검사로 막힌다. 캡처가 없거나 `^T`만 캡처한 람다는 `Func`라
  영향이 없다. findings register에 올리고 0.5에서 고친다.
- 고쳤다(2026-11-20, F-162): `OpaqueFunc`는 생성 때 `borrow_only`(`core.zig` `createOpaqueFuncType`, 반환 타입 검사가 타입 정보 해석보다
  먼저라 그 자리에 둔다). `sema.popLambdaProc`가 pinned closure의 결과에 캡처한 지역 중 먼저 끝나는 주인을
  `parent_local`로 단다(`shorterOwner`). 구조체 · 튜플 리터럴도 빌림 필드로 같게 한다. 빌림 타입 전역은 `resolveUserVar`에서 거절한다.
  그 테스트를 쓰다 캡처 둘 이상인 pinned closure의 누수(F-163)도 고쳤다. 이제 안 A의 남은 일은 필요한 것 1(일반 지역의 주소를
  담는 캡처)과 문서뿐이다.
