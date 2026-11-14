# 0.4.11 이후 변경 (미릴리스)

0.4.11(2026-11-14) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 언어와 표준 라이브러리

- 모델이 쓴 코드에서 나온 문구(tars-agent `docs/requests/cyber-0.4.11-codeact-messages.md`, 0.4.11 CodeAct 회차):
  - `for p |s| in {'a', 'b'}:`처럼 `|x|` 뒤에 `in`이 오면 ``Expected :.`` 대신 "A `for` loop has no `in`. The values come first
    and the name goes in `|x|`: `for {'a', 'b'} |s|:`."(범위 `for 0..n |i| in ...`도 같다).
  - `q: byte = 0`은 ``Unsupported block statement.`` 대신 "To declare a typed variable, write `var q byte = 0` or `q := byte(0)`."
    (값이 숫자 리터럴이 아니면 `var` 꼴만).
  - `in_s str = ''`처럼 `var` 없는 타입 선언은 ``Expected end of line or file. Got ident.`` 대신 "To declare a typed variable,
    write `var in_s str = ''`."
  - `out == none` · `out != none`의 왼쪽이 `none`을 담을 수 없는 타입이면 ``Expected `?T` to infer `none` value, found `str`.``
    대신 "`out` is `str`, which is never `none`. Compare with a value of the same type"(`str`이면 `out.len() == 0` 예시).
  - 옵션이 아닌 값의 `?else`는 ``Expected type instance of `Option`, found `bool`.``에 "This value is `bool`, not an option.
    Remove `?else false`."를 덧붙인다(`?else:` 블록이면 "Remove the `?else` block.").
  - `<` · `<=` · `>` · `>=`와 산술 · 비트 연산자의 오른쪽 타입이 맞지 않으면 ``Expected argument `str`, found `int`, when calling
    `fn >(str, str) -> bool`.`` 대신 연산자로 말한다: "Can not compare `str` with `int`. Convert one side: `int(i)` or `'%{0}'`.",
    "Can not apply `+` to `str` and `int`. To join them, write `'%{s}%{1}'`."(그 밖의 타입 쌍은 "Convert one side so that both
    have the same type.").
