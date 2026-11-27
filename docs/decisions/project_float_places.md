# float의 소수 자릿수 `fmt` (2026-11-27)

상태: 구현됨. Find Cost of Tile 예제(`examples/tile_cost.cy`)가 계기다. 사용자 요청은 "다음 예제 진행해 (Find Cost of Tile)",
예제가 드러낸 빈틈은 spec · std에서 고친다는 이전 지시를 따랐다. 돈 `187.056`을 `187.06`으로 찍을 방법이 없었다. `float.fmt()`는
가장 짧은 자릿수(`187.056`)만 내고, 정수의 `fmt(format, config)`는 float에 없었다. `math.round(x * 100) / 100`은 `187.06`이 되지만
`10.0`을 `10.0`(`10.00`이 아니라)으로 찍는다.

## 비교

- Rust: `format!("{:.2}", x)`, `{:>8.2}`. 정확한 이진 값을 반올림한다(`2.675`는 `2.67`). 자릿수 구분자는 없다.
- Python: `format(x, ',.2f')`. 정확한 이진 값을 반올림한다(`2.675`는 `2.67`). `,` · `_` 구분자, 너비 · 채움.
- Zig 0.17.1: `std.fmt.float.render(buf, x, .{ .mode = .decimal, .precision = 2 })`, `{d:.2}`. 가장 짧은 자릿수를 0에서 먼 쪽으로
  반올림한다(`2.675`는 `2.68`). 구분자는 없다.
- Nim: `formatFloat(x, ffDecimal, 2)`, `strformat`의 `&"{x:.2f}"`. C의 `snprintf`처럼 이진 값을 반올림한다.

## 결정

1. `fn (Float[]) fmt(config FloatFormatConfig) -> str`. `FloatFormatConfig`는 `NumberFormatConfig`의 `pad` · `width` · `sep`에
   `places ?int`를 더한다. 정수의 `fmt(.dec, config)`와 같은 꼴이지만 진법 인자는 없다(float는 10진수만). `places`를 정수 쪽
   설정에 넣지 않은 것은 정수에서 뜻이 없어서다.
2. 반올림은 Zig를 따른다: `print`가 보이는 자릿수를 0에서 먼 쪽으로 반올림한다. `2.675`라고 쓰고 `2.675`로 찍히는 값이
   `2.68`이 되는 편이 읽은 대로다. 특히 돈에서 그렇다. `fmt()`의 "가장 짧은 자릿수" 원칙과도 맞는다. Python · C와 다른 점은 매뉴얼에 적었다.
3. `places`가 없으면 `fmt()`와 같은 자릿수(정수 값의 `.0` 포함)에 구분자 · 너비만 더한다.
4. `sep`은 소수점 앞의 3자리씩만 묶는다(Python과 같다). 너비는 구분자와 부호를 세고, `0` 채움은 부호 뒤에 온다(정수와 같다).
5. `places`는 0 ~ 100. 벗어나면 'Invalid places: -1, expected 0 to 100' panic(정수의 `width` · `pad` 검사와 같은 자리). 100은
   스택 버퍼를 묶는 한도이고, 의미 있는 자릿수(17)보다 넉넉하다.
6. `inf` · `nan`은 이름 그대로다(구분자는 없고 너비 · 채움만 따른다).
7. `f32`는 자기 가장 짧은 자릿수를 반올림한다(`f64`로 넓히지 않는다).

## 하지 않은 것

- 문자열 보간의 서식 지정(`'%{x:.2}'`): 보간 문법을 넓히는 일이라 따로 본다. 지금은 `'%{x.fmt({places=2})}'`.
- 지수 꼴(`1.5e10`) 출력: 쓰는 곳이 없다.

## 예제에서 함께 본 것

- 슬라이스 `const`(`const Fields = []Field{...}`)는 'Expected eval eligible type, found `[]Field`.'로 막힌다. 컴파일 타임 평가가
  힙 값을 다루지 않아서다. 예제는 함수 안의 지역으로 썼다. 고칠지는 따로 본다.
