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
