# 오버로드 선택: 정확한 타입 일치 우선 (2026-11-08, F-21)

## 배경

`matchFuncSym`(`src/sema_func.zig`)은 오버로드 후보를 선언 순서대로 시도해 처음 맞는 것을 골랐다. 인자는 후보의 매개변수 타입을
목표로 `semaExpr(fit_target=true)`로 평가되므로 `int` → `float` 같은 암시적 변환이 "맞음"으로 잡힌다. 그래서 `fn show(x float)`을
`fn show(x int)`보다 먼저 선언하면 `n int`를 넘긴 `show(n)`도 `float` 쪽으로 갔다(발견 이슈 F-21, 02장 §5.7 · 03장 §7.1). 선언 순서가
의미를 바꾸는 조용한 오답이다. 또 매개변수가 같고 반환 타입만 다른 오버로드는 `isFuncUnique`가 전체 시그니처(반환 포함)로 비교해
거부되지 않았고, 호출은 항상 먼저 선언된 쪽으로 갔다.

## 결정

cf4aa84a.

- 두 단계 선택. 1단계는 후보마다 `exact=true`로 시도한다. `resolveRtArg`가 `fit_target=false`로 인자를 평가하고 `matchArg`의
  `isTypeCompat`(포인터 `*void` · C 가변 인자를 뺀 동일 타입)만 통과하면 맞음이다. 정수 리터럴(`decLit` · `binLit` · `octLit` · `hexLit`)은
  매개변수가 `int` · `raw` 계열일 때만 1단계에서 맞는다(`int_literal_fits_exact`). 1단계에서 아무도 맞지 않으면 2단계는 이전과 같은
  선언 순서 · 암시적 변환 허용 탐색이다. 1단계는 `numFuncs > 1`인 런타임 호출(`req_value=false`)에서만 돌고, 제네릭 후보와
  `const_eval_only` 후보는 2단계에서만 본다.
- 후보 시도마다 생긴 IR 문장 · 지역의 되돌리기는 기존 코드(`start_stmt.next = null`, `varStack` 길이 복원)를 `matchRtOverload`로
  묶어 두 단계가 같이 쓴다. 표현식 노드 자체는 arena에 남는다(기존 TODO 그대로).
- 선언 시 `resolveFunc`(`src/module.zig`)가 매개변수만의 시그니처(`ensureFuncSig2(params, void)`)를 `overloadedParamsMap`에 넣고,
  이미 있으면 `X has already been declared with the same parameters. Overloads must differ in their parameter types, not only in the
  return type.` 컴파일 오류다. 반환 타입만 다른 오버로드는 호출 지점에서 구분할 수 없기 때문이다.

## 하지 않은 것

- 2단계의 "가장 적합한 후보" 점수 매기기나 모호성 오류. 1단계가 비면 이전 동작(선언 순서)이라 기존 스크립트의 의미는 바뀌지 않고,
  1단계가 잡는 경우만 선언 순서와 무관해진다.
- 컴파일 타임 호출(`matchOverloadedFuncCt`)의 1단계. cte는 인자를 값으로 평가하므로 별도 작업.
- 리터럴 외 인자에서 목표 타입 힌트는 1단계에서도 유지한다(`fit_target=false`이지만 `target_t`는 넘김). 레코드 리터럴 · enum 케이스처럼
  목표 타입이 필요한 인자가 1단계에서 오류가 되지 않게 하기 위해서다.

## 검증

- behavior 테스트 `functions/call_overload_exact.cy`: `float` 먼저 · `int` 먼저 두 순서, 지역 변수 · 리터럴, 두 인자 혼합, 메서드,
  단일 `float` 오버로드에 `int`를 넘기는 2단계 경로. `functions/call_overload_ret_only_error.cy`: 반환만 다른 오버로드가 컴파일 오류.
- core.cy · std의 기존 오버로드는 전부 테스트를 통과해야 한다(1단계가 잡는 호출이 이전과 다른 후보를 고르면 여기서 드러난다).
