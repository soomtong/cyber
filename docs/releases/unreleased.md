# 0.4.15 이후 변경 (미릴리스)

0.4.15(2026-11-18) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 고치는 법을 말하지 않던 컴파일 오류 셋 (tars-agent 요청, 0.4.15 비교 회차)

요청 원문: tars-agent `docs/requests/cyber-0.4.15-messages-from-codeact-round.md`. 동작은 그대로이고 문구만 바뀐다.

- `!T` · `error`를 돌려주지 않는 함수 안의 `!`: 'Expected `Result` or `error` return type for enclosing function.'이
  'Expected a `!T` or `error` return type for `!`. The function `size` returns `int`, so `!` can not pass the error on.
  Declare it `-> !int`, or handle the error here with `!else` or `try`.'가 됐다. 람다는 'The lambda returns ...'.
- 케이스 이름 없는 `.!`(`idx.!`): 'Expected ident.'가 'Expected a choice case name after `.!` (`c.!line`). Unwrap an option
  with `.?`, and an error with `!` after the call (`f()!`).'가 됐다(ParseError).
- `^[]T`에 제자리 메서드(`rows.append('a')`): 원래 문구 뒤에 'To change the value that `rows` points to, write
  `rows.*.append(...)`.'를 붙인다. `insert` · `remove` 등 다른 제자리 메서드도 같다. `^T`를 `&&T`로 저절로 바꾸지는 않는다
  (다른 참조가 같은 목록을 나눠 가질 수 있다).
