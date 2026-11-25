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

## 모호한 호출은 컴파일 오류 (2026-11-25, Julia 검토 3.4 C)

결정(사용자, 2026-11-25): 오류로 올리기 전에 LSP Warning으로 넣고 걸리는 곳을 센다. 센 뒤(아래) 같은 날 사용자가 컴파일 오류로
올리기로 했다("이거는 컴파일 에러로 내는 게 좋겠는데?"). 경고 단계에서 넣었던 힌트 `CL_HINT_AMBIGUOUS_CALL`과 LSP 진단은
릴리스 전에 지웠다(컴파일 오류가 그대로 진단이 된다). 'The call is ambiguous: both `fn tag(?str) -> str` and `fn tag(?int) -> str`
match, and neither is more specific. Write `tag(?str(none))` or `tag(?int(none))`.' 제안은 처음으로 다른 매개변수 자리의 인자를
두 타입으로 변환한 꼴이다(호출이 한 줄 80자 이하일 때).

- `sema_func.checkAmbiguousCall`: 런타임 호출(`req_value` 아님)마다 `matchFuncSym`의 1단계 앞에서 런타임 후보(제네릭 · `const_eval_only` 제외)를 하나씩 맞춰 보고
  매번 되돌린다(`tryRtOverload`의 `probe`, 오류가 나도 리포트까지 되돌림). 정확 일치가 하나라도 있으면 그것들만, 없으면 변환 일치를
  모은다. 둘 이상이고 먼저 선언한 것이 다른 것보다 더 구체적이지 않으면 오류다. 컴파일 시간은 Debug 빌드로 json · time · ints
테스트를 컴파일해 판정을 켜고 끈 차이가 ±1% 안이었다.
- "더 구체적": 매개변수마다 같거나 `T`가 `?T` · `!T`보다 좁다. 처음 안의 "`int`가 `float`보다"는 넣지 않았다.
- 설계상 모호하지 않은 쌍은 뺀다(`interchangeableSigs`): 수 타입끼리만 다른 것(`float(x i32)`가 `float` 쪽으로 가도 값이
  같다), 문자열 리터럴 인자 자리에서 `str`과 정수만 다른 것(`?T` 안도 같다). 한 글자 리터럴은 문자열이 먼저이고 rune은 문자열이
  맞지 않을 때다(`s.index('\n')`의 `byte`, json `v['n']`의 `int` 인덱스).
- 인자가 이름 · 리터럴 · 멤버 접근일 때만 본다. 타입이 매개변수에 따라 달라지는 인자가 이들이다. 람다 · 블록 · 호출은 후보마다
  다시 분석되므로 건너뛴다. 남는 구멍: 호출 결과 `T`를 `?T` · `!T` 두 오버로드에 넘기는 것처럼 타입이 정해진 식의 변환 모호성.

센 결과(2026-11-25, 계측 빌드로 `src/test` · `examples` · `src/tools`의 모든 `.cy`를 컴파일, core · std는 그 과정에서 함께
컴파일됨): 1곳, `functions/call_overload_literal.cy`의 `first(none)`(의도된 테스트). 수 타입 · `str`/`byte` 쌍을 빼기 전에는
12곳이었다(`float(x)` · `f32(x)`에 `i32` · `r64` 등 10곳, `s.index("\n")` 1곳). 작은따옴표 리터럴을 인자로 볼 때는 json
`v['n']` 9곳이 더 걸렸다(`str` 키와 `int` 인덱스). 남은 `first(none)` 테스트는 변환한 꼴로 고치고 오류 테스트
`functions/call_overload_ambiguous_error.cy`를 더했다.
