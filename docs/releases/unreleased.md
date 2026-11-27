# 0.4.23 이후 변경 (미릴리스)

0.4.23(2026-11-26) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 정수 넘침은 panic (2026-11-26)

- 깨지는 변경: 부호 있는 정수(`int`, `i32`, `i16`, `i8`)의 `+ - * **`, 단항 `-`, `/`가 타입에 들어가지 않으면 'Integer overflow.'
  panic이다. 전에는 조용히 감겼다(`int.max + 1`이 `int.min`). 상수 식은 같은 문구의 컴파일 오류다(`const k = int.max + 1`).
  `x % -1`은 언제나 0. raw 정수(`byte`, `r16`, `r32`, `r64`)는 그대로 감긴다.
- 새 메서드: `wrapping_add` · `wrapping_sub` · `wrapping_mul`(감김을 뜻하는 자리: 해시, 난수), `checked_add` · `checked_sub` ·
  `checked_mul`(`?Self`, 넘치면 `none`). 매뉴얼 "Integer overflow.", 결정 `docs/decisions/project_int_overflow.md`.
- 결함 수정: 컴파일 타임 `-(int.min)`의 호스트 panic(F-219), 런타임 `int.min / -1` · `% -1`의 C 정의되지 않은 동작(F-220).
- 바이트코드: `s += 1`이 4칸에서 5칸이 됐다. 함수 본문 크기 한계('Function body too large.')에 조금 일찍 닿는다.

## 예제 `fibonacci_sequence.cy` (2026-11-27)

- 피보나치 수열을 N개까지(최대 93개, F(92)가 `int`에 들어가는 마지막 수). 각 수를 앞 두 수의 합으로 만들어 마지막 수 다음을 미리
  계산하다 넘치는 일이 없다. `pi_digits.cy`와 같은 꼴로 인자 · 프롬프트 · 파이프로 받는다.

## 다중 대입과 한 줄 `?else return` (2026-11-26)

- `a, b = b, a + b`와 `a, b := 0, 1`. 오른쪽 값을 왼쪽부터 모두 계산한 뒤 대입하므로 맞바꾸기(`x, y = y, x`)에 임시 변수가 필요 없다.
  자리는 변수 · 필드 · 원소, `NoCopy` 값은 옮긴다. 개수가 다르면 '2 places take 2 values, found 3. ...'.
- `?else` · `!else`(`!else |err|` 포함) 뒤에 `return` · `break` · `continue` 하나를 `:` 없이 쓴다: `n := o ?else return none`.
  전에는 'Expected default expression.'.
- 매뉴얼 "Local variables.", "Unwrap or default.", 결정 `docs/decisions/project_multi_assign.md`. tree-sitter 문법도 고쳤다.

## 예제 `prime_factors.cy`와 정수의 자릿수 구분자 (2026-11-27)

- 예제: 1부터 10^12까지의 수를 소인수분해해 거듭제곱의 곱으로 쓴다(`360 = 2^3 × 3^2 × 5`). 나눗셈으로 나누는 수를 제곱근까지 시험하고,
  조건은 `d <= rest / d`라 `d * d`가 넘치지 않는다. 인자 · 프롬프트 · 파이프로 받는 꼴은 `pi_digits.cy`와 같다.
- 예제가 드러낸 빈틈: 한도 `1000000000000`을 읽기 쉽게 쓸 방법이 없었다. `NumberFormatConfig`에 `sep ?byte`를 더하고, 정수에도
  `fmt(format, config)`를 열었다(전에는 `Raw`만, `int`의 꼴은 테스트에 주석으로만 있었다). `1234567.fmt(.dec, {sep=','})`는
  `1,234,567`. 10진수는 3자리, 다른 진법은 4자리로 묶는다(Python의 `,` · `_`). width는 구분자와 부호를 센다. 128 이상의 구분자는
  'Invalid sep: 200, expected an ASCII rune' panic.
- `int`의 `0` 채움은 부호 뒤에 온다: `(-42).fmt(.dec, {pad='0', width=6})`는 `-00042`(Python과 같음). 다른 채움 문자는 부호 앞.
- 매뉴얼 "String formatting."의 `fmt` 문단.

## 예제 `next_prime.cy` (2026-11-27)

- 소수를 하나씩 보여 주고 다음 것을 물어본다. 터미널에서는 Enter로 다음, `q`나 입력 끝으로 멈춘다. 파이프에서는 줄마다 하나씩 더
  보여 준다. 인자로 개수를 주면 묻지 않고 그만큼(최대 100,000개) 찍는다. 소수는 끝없이 도는 `generator fn primes()`가 만들고, 찾은
  홀수 소수 가운데 제곱근 아래의 것으로만 나눠 본다. 언어 변경은 없다.

## 제너레이터의 `take` (2026-11-27)

- `gen.take(n)`은 제너레이터의 다음 `n`개 값(먼저 끝나면 그보다 적게)을 지연 평가로 준다: `for primes().take(10) |p|`. 결과는
  제너레이터를 공유해 변수에 담긴 제너레이터는 꺼낸 값 뒤에서 이어 간다. 마지막 값 뒤의 `next`는 계속 `none`, 음수는 'Expected a
  count of 0 or more, found -1.' panic. `examples/next_prime.cy`의 개수 인자가 이것을 쓴다.
- 슬라이스의 `take` · `map` · `filter` · `reduce`는 넣지 않았다(`for` · `xs[0..n]`). 매뉴얼 Generators "Taking the first values.",
  결정 `docs/decisions/project_generator_take.md`.

## span `[&]T`를 거친 쓰기의 구멍 (2026-11-27)

- 깨지는 변경(결함 수정, F-221): span `[&]T`를 거쳐 관리형 원소를 바꾸는 코드가 컴파일 오류다. `xs [&][]int`의 `xs[0] = {7}`,
  `xs[0].append(1)`, `&&xs[0]`은 'Cannot replace a managed value through a span `[&]T`, which is a shared borrow of its elements.
  Take the slice as `&&[]T`.'(또는 'Cannot borrow exclusively ...'). 전에는 통과했고, 같은 버퍼를 빌린 다른 span이 놓인 메모리를
  읽을 수 있었다. `&[]T`는 이미 막혀 있었다(R6). 관리형이 아닌 원소(`int`, 그런 필드만 가진 구조체)는 그대로 제자리에 쓴다.
  고치는 법: 매개변수를 `&&[]T`로 받고 `f(&&xs)`로 부른다.
- 매뉴얼 Slices에 "Passing a slice to a function." 절: `[&]T` · `&[]T` · `&&[]T` · `[]T` 네 꼴이 하는 일의 표와 예, `[]T` 매개변수는
  복사이지만 크기가 바뀌기 전까지 원소를 공유해 제자리 쓰기(`xs[0] = 9`, `sort`)가 호출한 쪽에 보인다는 것.

## 예제 `tile_cost.cy`와 float의 소수 자릿수 (2026-11-27)

- 예제: 바닥의 너비 · 길이(m)와 m²당 타일 값으로 넓이와 비용을 찍는다(`4.5 3.2 12.99`는 `Area: 14.40 m²`, `Cost: 187.06`). 인자
  셋, 터미널의 프롬프트 셋, 파이프의 세 줄로 받는다. 0 이하 · 한도 초과 · NaN은 거절한다.
- 예제가 드러낸 빈틈: 돈을 소수 둘째 자리로 찍을 방법이 없었다(`float.fmt()`는 가장 짧은 자릿수만). `FloatFormatConfig`
  (`pad` · `width` · `sep` · `places`)와 `x.fmt(config)`를 넣었다. `1234.5.fmt({places=2, sep=','})`는 `1,234.50`. `places`는
  `print`가 보이는 자릿수를 반올림(0.5는 0에서 먼 쪽)해 `2.675`는 `2.68`이다(Python · C는 이진 값을 반올림해 `2.67`). `sep`은
  소수점 앞만 묶는다. `places`는 0 ~ 100, 벗어나면 'Invalid places: -1, expected 0 to 100' panic. `f32`는 자기 자릿수를 쓴다.
- 매뉴얼 "String formatting."의 float 문단, 결정 `docs/decisions/project_float_places.md`.

## 문자열을 가진 const 구조체 · 고정 배열, 슬라이스 const 오류 (2026-11-27)

- `const`가 `str` 필드를 가진 구조체와 그 고정 배열을 받는다: `const Fields = [3]Field{{name='Width', max=10.0}, ...}`. 전에는
  'Expected eval eligible type, found `Field`.'였다. 상수는 쓰는 자리마다 펼쳐져 복사본은 따로 바뀐다. 타입을 적은 꼴(`const S str
  = 'abc'`, `const W [2]str = {...}`)도 된다. 사용자가 정의한 `@copy`나 `NoCopy`를 가진 타입은 여전히 안 된다.
- 깨지는 변경(결함 수정): 상수의 원소 · 필드에 대입하면 컴파일 오류다('Cannot assign to a part of the constant `nums`. It is
  copied at each use; declare it with `global` to change it.'). 전에는 `const nums = [2]int{1, 2}`의 `nums[0] = 5`가 통과했고 펼친
  임시 값만 바꿔 아무 일도 하지 않았다.
- 슬라이스 `const`는 전용 오류다: 'A slice cannot be a constant: its copies share one buffer. Use a fixed array `[2]str`, or
  `global` for a value that changes.' 오류에 fix가 실려 LSP가 `[]` → `[2]` quick fix를 보인다(원소 개수는 리터럴에서 센다).
- 매뉴얼 Constants, 결정 `docs/decisions/project_const_aggregates.md`. 예제 `tile_cost.cy`가 `const Fields = [3]Field{...}`를 쓴다.

## 예제 `mortgage.cy`, const의 수 변환, float → int 범위 panic, 옵션 목표의 `.case` (2026-11-27)

- 예제: 고정 금리 대출의 월 상환액(`payment 300000 6.5 30` → `1,896.21`, 마지막 회차 · 총이자 · 총액)과, 월 상환액으로 갚는 데 걸리는
  기간(`payoff 300000 6.5 2500` → 16년 3개월, 195회)을 낸다. 돈은 센트 정수로 다루고 매달 이자를 센트로 반올림해 상환 일정을 따라간다.
  첫 달 이자도 못 갚는 상환액, 50년을 넘는 상환은 이유를 말하고 끝난다.
- 예제가 드러낸 빈틈 셋:
  - `const Years = Field{..., max=float(MaxYears)}`가 'Unsupported const eval of `@intToFloat`.'였다. 컴파일 타임 `@intToFloat` ·
    `@floatToInt`과 `int(x)`의 float · `f32` · `bool` 갈래(전에는 'TODO')를 넣었다.
  - 깨지는 변경(결함 수정): `int(x)`가 NaN이나 `int` 밖의 float를 C 캐스트로 바꿔 미정의 동작이었다(arm64는 포화, x86은 다른 값).
    이제 'The float is NaN or out of the range of `int`.' panic, 상수에서는 같은 문구의 컴파일 오류다(정수 넘침 panic과 같은 원칙).
  - `?Mode`를 돌려주는 함수의 `return .payment`가 'Can not infer symbol from `.payment`.'였다. 옵션 목표는 안쪽 타입에서 추론한다.
- 남은 마찰: 람다가 바깥 지역(`field`)을 캡처하지 못해 묻는 함수를 둘로 썼다(2026-11-25 결정 D, 캡처 규칙은 그대로).
- 매뉴얼 "Integer overflow."의 변환 문단, Enums의 옵션 목표 문장.
