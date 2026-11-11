# 제너레이터는 빌림 매개변수를 받지 않는다, `?&T`는 빌림 컨테이너다 (2026-11-08)

상태: 구현됨(`a7418c29`). 발견 이슈 F-14(07장 표의 3번).

## 배경

이 문서의 `#[generator]`는 적을 당시의 문법이다. 2026-11-11부터 선언은 `generator fn f(...)`이고 `#[generator]` 속성은 없어졌다(`docs/decisions/project_coroutines.md`의 "선언 모양 변경과 구현" 절). 오류 문구도 ``A `generator fn` can not take the borrow type ...``로 바뀌었다.

`#[generator]` 함수를 호출하면 본문이 바로 돌지 않고 `^Generator[Fn]`이 돌아온다. 매개변수와 지역은 힙 스냅샷에 들어가고
`next()`마다 소비자 스택 위로 복사되어 이어서 돈다. 그래서 제너레이터는 자기를 만든 호출보다 오래 산다.
빌림 `&int` 매개변수는 호출자 스택의 주소다. `fn make(): local := 41; return watch(&local)`처럼 호출자가 끝난 뒤 `next()`를
부르면 스냅샷의 주소가 이미 사라진 프레임을 가리킨다(07장 실습 8 br2: 첫 값 41은 우연히 남은 값, 둘째 값 1은 덮인 값).
보통 빌림이 힙으로 가는 길(`^b`)은 `semaLift`가 `Cannot lift the borrow type`으로 막는데, 제너레이터의 스냅샷은 그 검사를
거치지 않는다. 같은 이유로 `[&]T`, 빌림을 필드로 가진 구조체(`borrow_only`), 메서드의 `&self` 수신자도 같은 구멍이다.

같은 조사에서 `?&int`가 어디서도 빌림으로 취급되지 않는 것을 찾았다. `Option` 타입이 `borrow_only`를 자식에서 물려받지
않아 `^(?&int(&x))` lift, `scope` 없는 `-> ?&int` 반환, 제너레이터 매개변수 모두 통과했다.

## 결정

1. `#[generator]` 함수의 매개변수는 `borrow_only` 타입이면 컴파일 오류다. 수신자(`&self`)도 매개변수라 같다.
   `A \`#[generator]\` function can not take the borrow type \`&int\` as a parameter. The generator outlives the call, so pass
   an owned value or a \`^T\` pointer instead.` 검사는 시그니처를 만드는 곳(`sema.zig`의 `has_generator` 분기)에서 하므로
   호출되지 않은 선언도 잡는다. 스냅샷에 빌림이 들어갈 길은 매개변수뿐이다(지역 빌림은 `yield` 사이에 살아 있는 지역을 스냅샷이
   함께 보존하지 못하는 F-01 영역이고, 본문의 빌림은 어차피 스냅샷에 안 들어간다).
   `^T` · 값 타입(`int` · `str` · `^ArrayStore[int]` 등)은 그대로다. 기존 테스트 `concurrency/generator.cy`는 모두 `^T` 또는 값이다.
2. `?T`는 `T`가 `borrow_only`면 자신도 `borrow_only`다(`sema_type.zig` `resolveOptionType`). 이로써 `?&T`는 `&T`와 같이
   lift 불가(`Cannot lift the borrow container type \`?&int\`.`), 반환하려면 `scope`, REPL 최상위 지역으로 이월 불가, 제너레이터
   매개변수 불가다. `fn f(scope a &int, some bool) -> scope ?&int`는 된다.
3. core의 `fn Option[] :: @init(x Self) -> Self`는 `scope x Self -> scope Self`로 바꿨다. 2번 때문에 `?&int(&a)`가 "Returning a
   borrow container requires a `scope` modifier"로 막혔기 때문이다. 다른 인스턴스(`?int(5)` · `?str('abc')`)에는 영향이 없다
   (`control_flow/if_unwrap.cy` 등 통과). core · std · 테스트에 `?&T`를 쓰는 곳은 없었다.

## 구현 메모

- `src/sema.zig` 함수 선언 해석의 `has_generator` 분기: AST 매개변수(`decl.params`, 템플릿 매개변수 건너뜀)와 `sig.params()`를
  나란히 돌며 `info.borrow_only`면 `reportErrorFmt`(위치는 매개변수 노드).
- `src/sema_type.zig` `resolveOptionType`: `option_t.base.info.borrow_only = child_t.info.borrow_only`.
- `src/builtins/core.cy` `Option.@init`에 `scope`. 오류 메시지의 시그니처가 `fn @init(scope ?int) -> scope ?int`로 바뀌어
  `core/optionals_incompat_value_error.cy`의 기대 텍스트를 고쳤다.
- 테스트: behavior `concurrency/generator_borrow_param_error.cy`(`&int`), `concurrency/generator_borrow_option_param_error.cy`
  (`?&int`), `memory/lift_borrow_option_error.cy`(`^opt`), `memory/scope_return.cy`에 `scope ?&int` 반환의 some · none 케이스.
- 재현(scratchpad): br2(`&int`) 41 · 1 → 컴파일 오류. `[&]int`, `&Foo` 수신자, `&int` 필드 구조체 `Holder`, `?&int` 모두 오류.
  `^int, int, str` 매개변수의 제너레이터는 그대로 `44`.

## 남은 것

- 빌림을 담는 다른 합성 타입은 `borrow_only` 전파를 각자 확인해야 한다. 구조체는 필드에서 전파하고(`has_borrow_child`),
  Option은 이번에 추가했다. choice · 튜플 · `Vector[&T]` 등은 보지 않았다(F-25 빌림 검사 구멍과 같이 볼 것).
- 제너레이터 안에서 `yield` 사이에 살아 있는 지역 변수가 사라지는 F-01은 별개다. 그쪽이 고쳐져 지역이 스냅샷에 들어가면 지역
  빌림(`p := &x`가 `yield`를 건너는 경우)도 같은 규칙으로 막아야 한다.
