# 수 피연산자의 대칭 변환 (2026-11-24)

## 배경

이항 산술과 비교는 왼쪽 피연산자의 타입이 오른쪽의 목표 타입이었다. 오른쪽이 왼쪽 타입으로 암시적 변환되면 통과하고,
아니면 오류였다. 그래서 같은 두 값의 연산이 순서에 따라 갈렸다.

~~~cy
i := 7
f := 2.5
print(f * i)    -- 17.5
print(i * f)    -- CompileError: Expected `int`, found `float`.
print(f < i)    -- true
print(i < f)    -- CompileError: Expected type `int`, got `float`.
~~~

에이전트 안내(`docs/agent-guide.md`)도 이것을 규칙으로 적고 있었다("`int + float` is an error, and the right operand is fitted
to the type of the left one"). Julia 검토(`docs/study/11-design-principles-review.md` 3.3.2 · 3.4 B)에서 이 비대칭을 짚었다.
Julia는 `+(x::Number, y::Number) = +(promote(x,y)...)`로 두 순서가 같은 길을 가게 한다.

## 결정 (사용자, 2026-11-24: "B의 int op float 대칭부터 넣자")

산술 연산자(`+ - * / % **`)와 비교(`< <= > >= == !=`)의 두 피연산자가 수(`Int[W]` · `Raw[W]` · `Float[W]`)이고 타입이 다르면,
암시적 변환 표(매뉴얼 Implicit casts)의 변환을 어느 쪽에나 쓴다.

1. 오른쪽이 왼쪽 타입으로 변환되면 그렇게 한다(전과 같다).
2. 안 되면 왼쪽이 오른쪽 타입으로 변환된다(새로 생긴 길).
3. 둘 다 안 되면 오른쪽 피연산자의 타입 오류다.

따라오는 결과:

- `int op float`와 `float op int`는 같은 `float` 연산이다. 결과 타입은 float 피연산자의 타입이다(`i8 * f32`는 `f32`).
- `f32 op float`와 `float op f32`는 같은 `float` 연산이다.
- 비교에서는 폭이 다른 정수도 왼쪽이 넓혀진다(`i8 < int`). 산술은 전부터 큰 폭으로 맞췄다.
- 새 변환은 없다. 표에 이미 있는 `Int[X]` → `Float[W]`, `Raw[X]` → `Float[W]`, `f32` → `f64`, 정수 넓히기를 왼쪽에도 쓸 뿐이다.
- 결과는 정수로 되돌아가지 않는다. `i += f`, `var n int = i * f`는 'Expected type `int`, got `float`.' 오류다.
- 두 정수의 나눗셈은 그대로 정수 나눗셈이다. `var h float = i / 2`는 3.0이다. 변환은 피연산자 한 쌍마다 정해지고 목표
  타입이 식 안으로 번지지 않는다.
- 비트 연산자(`&& || ~ << >>`)는 바뀌지 않았다. `i && f`는 전과 같은 'Expected `int`, found `float`.'다.
- 컴파일 타임 평가(`const`, `#{}`)도 같은 규칙이다.

지금 오류이던 코드만 통과하게 되므로 기존 스크립트의 뜻은 바뀌지 않는다. 예외는 아래 "함께 고친 결함"의 세 가지다.
그 코드들은 전에 틀린 값을 냈다.

## 함께 고친 결함

같은 코드 경로에서 조용히 틀린 값을 내던 것들이다. 이번 규칙을 넣으려면 그 자리의 타입 검사가 필요했다.

1. F-196: 왼쪽이 float인 산술이 오른쪽 타입을 검사하지 않았다. 변환되지 않은 오른쪽이 그대로 float 명령으로 넘어가 비트가
   float로 읽혔다. `f + 'abc'`가 오류 없이 `2.5`, `f * true`가 비정규 수였다. 이제 'Expected `float`, found `str`.' 컴파일 오류다.
2. F-196의 같은 원인: `f32 op float`. 오른쪽 `float`가 `f32`로 변환되지 않은 채 `f32` 명령이 돌았다.
   `var g f32 = 1.5`, `f := 2.5`에서 `g * f`가 `0.0`, `g + f`가 `1.5`, `g += f`가 아무 일도 하지 않았다. 이제 `g * f`는 `3.75`이고
   `g += f`는 'Expected type `f32`, got `float`.' 오류다.
3. F-197: 컴파일 타임 평가에서 왼쪽이 float 리터럴이고 오른쪽이 정수 상수이면(`const r = 2.5 * k`) 정수의 비트를 float로
   읽어 비정규 수가 나왔다. 반대 순서 `k * 2.5`는 'Expected type `int`. Found `float`.' 오류였다. 이제 둘 다 `7.5`다.

## 구현

- `src/sema_expr.zig` `semaBinExpr`:
  - 산술, 왼쪽이 `int` · `raw`: 오른쪽이 `float`이고 산술 연산자(`isArithmeticOp`)이면 `sema_lit.semaFitTarget`으로 왼쪽을
    오른쪽 타입으로 바꾼 뒤 `sema_bin_expr2`로 간다.
  - 산술, 왼쪽이 `float`: 오른쪽 타입이 다르면 오른쪽이 float일 때만 왼쪽을 넓히고, 아니면 `reportOperandType`
    ('Expected `{}`, found `{}`.'). 오른쪽이 `never`이면 전처럼 지나간다.
  - 비교: `semaComparedOperand`. 왼쪽이 수이면 오른쪽을 `reqTypeCstr = false`로 분석하고, 타입이 다르면 왼쪽을 오른쪽 타입으로
    바꾼다. 안 되면 전과 같은 `sema_lit.reportExpectedType`('Expected type `int`, got `str`.'). 왼쪽이 수가 아니면 전과 같다.
- 평가 순서는 그대로다. 왼쪽은 오른쪽보다 먼저 분석 · 실행되고(`semaRightOperand`의 `seqPushRes`), 변환은 이미 계산된 왼쪽
  값을 감쌀 뿐이다. 테스트가 호출 순서 `LRLR`을 확인한다.
- `src/cte.zig` `eval_bin_expr`: `evalFitNumbers`가 같은 순서(오른쪽 → 왼쪽 타입, 안 되면 왼쪽 → 오른쪽 타입)로 값을 바꾼다.
  변환은 `evalNumberToFloat` · `evalIntToFloat`(부호 있는 정수는 값으로, raw는 부호 없는 값으로). 왼쪽이 float 리터럴인 갈래도
  같은 함수를 거친다. 시프트(`<<`)는 전처럼 오른쪽을 왼쪽 타입으로 검사한다.

## 하지 않은 것

- 사용자 타입의 양쪽 연산자 조회(검토 3.4 B의 2). `v * 2.0`은 되고 `2.0 * v`는 안 되는 것은 그대로다. 정의하는 꼴(반사
  메서드인가 자유 함수인가)을 먼저 정해야 한다.
- 사용자 확장 승격 규칙(Julia `promote_rule`). 내장 수 타입은 닫혀 있다.
- 컴파일 타임 평가기의 float 연산 확장. float는 여전히 `*`만 된다. `const b = k + 2.5`는 변환 뒤 'Unsupported inline eval: plus'다.
- 컴파일 타임의 정수 폭 넓히기. `const z = k * a`(`a`가 `i8`)는 전과 같은 'Expected type `int`. Found `i8`.'다.
  런타임 산술은 넓힌다. 이 차이는 전부터 있었다.
- 오버로드 선택. `fn show(x float)` 하나에 `int`를 넘기는 2단계 변환은 그대로다(`project_overload_exact_match.md`).

## 검증

- behavior 테스트 일곱(`src/test/core`): `number_mixed_ops.cy`(산술 · 비교 · 폭 · 평가 순서 · 복합 대입 · 필드와 원소 ·
  컴파일 타임), 오류 케이스 `number_mixed_bitwise_error.cy` · `number_mixed_op_assign_error.cy` ·
  `number_mixed_compare_str_error.cy` · `float_op_str_error.cy` · `float_op_bool_error.cy` · `float_op_assign_wider_error.cy`.
- 실행 결과는 `docs/releases/unreleased.md`의 같은 이름의 절에 적는다.
