# 시작 · 끝이 없는 범위

결정일 2026-11-12. 사용자 결정: 시작 생략(`a[..n]`)을 문법에 넣는다.

## 규칙

- `a[..n]`은 `a[0..n]`, `a[n..]`은 끝까지, `a[..]`은 전체다. `@slice(start, end)`가 있는 타입 전부에 적용된다.
- 시작이나 끝이 없는 범위는 슬라이스 인덱스에서만 쓴다. 값(`r := ..3` · `r := 1..`), `for ..3 |i|`, `case ..5` · `case 1..`은
  컴파일 오류다. 범위 값 `Range`는 양 끝이 있어야 하고, `for`와 `case`에는 생략한 끝이 가리킬 길이가 없다.
- 부분 벡터 타입 `[..4]T`는 식의 범위가 아니다. 타입 파싱 경로(`partial_vector_type`)가 따로 처리한다.

## 구현

- 파서: 항의 접두 `.dot2`가 끝 식을 받는다(`parseTermExpr` 뒤 `parseRightExpr2(.range, …)`). 중위 `a..b`의 끝과 같은 우선순위라
  `a[..n - 1]`의 끝은 `n - 1`이다. 이전에는 접두 `..`가 끝을 받지 않아 `a[..-1]`이 `(..) - 1`이었다.
- sema: `semaSliceExpr`이 시작이 없고 끝이 있으면 상수 0을 시작 인자로 넣는다. 새 `@slice` 오버로드는 없다.
- 오류: `for`는 파서(`Expected left range expression.`), 값과 `case`는 sema. `case 1..:`는 `range.end.?`로 컴파일러를 끝내던 자리다.
- tree-sitter `range_expression`에 `..end` 형태를 더했다. `cyber fmt`는 토큰을 그대로 내보내므로 바꾸지 않았다.

테스트 `core/Slice.cy`의 "A slice without a start" 절, `core/Slice_open_start_neg_panic.cy`, `syntax/range_no_start_error.cy` ·
`range_no_end_error.cy`, `control_flow/for_range_no_start_error.cy` · `switch_range_open_error.cy`.
