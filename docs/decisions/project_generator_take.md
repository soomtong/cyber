# 제너레이터의 `take` (2026-11-27)

상태: 구현됨. 사용자 결정(2026-11-27): `map` · `filter` · `take` · `reduce` 가운데 무엇이 값어치가 있느냐는 질문에 권고(`take`만
넣고, `map` · `filter`는 클로저 캡처 규칙과 함께 다시 보고, `reduce`는 넣지 않는다)를 "ok agree let's go"로 받았다. Next Prime Number
예제(`examples/next_prime.cy`)에서 끝없는 제너레이터의 앞 N개를 꺼내려고 `gen := primes()` 뒤 `for 0..count: print(gen.next().?)`로
쓴 것이 계기다.

## 비교

- Rust: `Iterator::take(self, n) -> Take<Self>`. 지연 평가, 원본을 옮겨 받는다. 원본을 이어 쓰려면 `by_ref().take(n)`. 원본이 먼저
  끝나면 그보다 적게 낸다.
- Python: `itertools.islice(it, n)`. 지연 평가. 원본 반복자를 함께 전진시켜 뒤에 이어 쓸 수 있다. 음수는 `ValueError`.
- Zig 0.17.1: 반복자 어댑터가 없다. `while (it.next()) |x|`에 카운터를 둔다.
- Nim: 표준 라이브러리에 반복자의 지연 `take`가 없다(`sequtils`는 seq를 다룬다). 카운터를 둔 `for`.

## 결정

1. `Generator`에만 둔다: `fn (^Generator[]) take(n int) -> GeneratorTake[FnPtr]`. 제너레이터 호출은 `^Generator`를 돌려주므로
   수신자도 `^Generator`다. 슬라이스 등 컬렉션에는 두지 않는다(`xs[0..n]`이 있다). 다른 반복자로 넓히는 것은 쓰는 곳이 생기면 본다.
2. 지연 평가: 결과를 돌 때만 제너레이터를 재개한다. 끝없는 제너레이터에도 쓴다.
3. 결과는 제너레이터를 공유한다(Python `islice` 쪽). 변수에 담긴 제너레이터는 꺼낸 값 뒤에서 이어 간다(Rust의 `by_ref()`가
   따로 필요 없다). 결과만 들고 있던 제너레이터는 결과가 사라질 때 끝난다(`Generator.@deinit`).
4. 원본이 먼저 끝나면 그보다 적게 내고, 마지막 값 뒤의 `next`는 계속 `none`이다(원본의 'Generator is already done.' panic을 내지
   않는다).
5. 음수 `n`은 panic 'Expected a count of 0 or more, found -1.'(Python과 같이 오류, 조용히 0개로 보지 않는다).
6. `GeneratorTake`는 `NoCopy`가 아니다. 복사본은 같은 제너레이터를 공유하고 남은 개수는 따로 센다.

## 하지 않은 것

- `map` · `filter`: 2026-11-25 결정(설계 원칙 3.7 D, `for` 루프로 쓴다)을 그대로 둔다. 걸림돌은 클로저 캡처 규칙이다
  (`^T` · `&T`만 캡처하므로 `|x| x > limit`는 먼저 `l := &limit`). 캡처 규칙을 넓힐 때 함께 다시 본다.
- `reduce`: 누적 변수를 둔 `for`가 더 읽기 쉽다. 필요해지면 `sum` · `min` · `max`처럼 이름 있는 메서드를 본다.

## 구현

- `src/builtins/core.cy` `Generator.take`, `GeneratorTake`(`next` · `iterator` · `next(idx)`). `for`는 공유 빌림으로 `next(idx)`를
  부르므로 수신자는 `&`이고, 남은 개수(`int`)는 관리형이 아니라 `&`로 쓸 수 있다.
- 테스트 `src/test/concurrency/generator_take.cy`, `generator_take_negative_panic.cy`(trace에 `core:` 줄 번호가 있어 `core.cy`의
  그 앞부분이 바뀌면 고친다). 매뉴얼 Generators "Taking the first values.".
