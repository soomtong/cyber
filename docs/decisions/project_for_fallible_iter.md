# `for`: 실패할 수 있는 반복자 (2026-11-25)

## 배경

`os.Process`의 줄을 `for`로 돌려고 `next() -> !?str`인 반복자를 만들었더니 'Expected `Option` type.' 컴파일 오류였다. `for`는
`next`가 `?T`를 돌려주는 반복자만 받았다. 읽기 · 디렉터리 순회처럼 반복하는 장치 자체가 실패할 수 있는 반복자는 `while
p.read_line()! |line|:`로 써야 했다.

`!?T`는 결과가 옵션을 감싼 것이다. 오류(장치의 실패), 성공 + `none`(끝), 성공 + 값의 세 상태다. 원소 하나가 실패하는
`?!T`(Rust `Iterator<Item = Result<T, E>>`)와 다르다. `?!T`는 지금 `for`로도 된다(원소가 `!T` 값일 뿐이다).

## 결정 (사용자, 2026-11-25)

물은 것: 오류가 나면 (1) `!`처럼 둘러싼 함수로 넘김, (2) `else |err|:` 갈래 필수, (3) 둘 다. 답: "`else |err|:` 갈래 필수".
사이버는 오류가 넘어가는 자리마다 `!`가 보이는 원칙이었다. (1)은 `!`가 보이지 않는 전파가 된다.

~~~cy
for p.lines() |line|:
    print(line)
else |err|:
    print('stopped: %{err}')
~~~

### 정한 것

1. `next`가 `!?T`이면 `else` 블록이 필수다. 오류가 나면 반복이 끝나고 블록이 돈다. `|err|` 캡처는 `try:`의 `else`처럼 생략할 수 있다.
2. 오류 없이 끝나면 블록은 돌지 않는다. Python의 `for ... else`(break 없이 끝나면 도는 블록)와 뜻이 다르다. 사이버의 `else`는
   `try:` · `!else`와 같이 오류 갈래다.
3. `next`가 `?T`인 반복 뒤의 `else`는 컴파일 오류다. 오류가 없는 반복에 오류 갈래를 두지 않는다.
4. 블록 안의 `continue`는 컴파일 오류다. 실패한 반복자를 다시 부르면 같은 오류가 되풀이될 수 있다(시간 제한이 지난 읽기는 끝없이
   `error.TimedOut`). 블록 안의 다른 반복문의 `continue`는 된다. 블록은 끝에 닿아도 되고(반복 뒤로), `break` · `return`도 된다.
5. 문법은 `else` 한 갈래만이다(`else cond:` 갈래 없음). `else` 뒤에는 `|err|` 또는 `:`가 와야 한다.

## 구현

- AST: `ForIterStmt.else_stmt: ?*CatchStmt`(`try:`의 `else`와 같은 노드). `ast.CatchStmt`를 pub으로.
- 파서: `parseForElse`가 본문 뒤 같은 들여쓰기의 `else`를 읽는다. 전에는 그 자리의 `else`가 `if` 없는 `else`라 오류였으니
  기존 코드의 뜻이 바뀌지 않는다.
- sema: `x !else |err|: block`의 처리를 `sema_expr.semaUnwrapResElse`로 떼었다. `for`는 `next` 호출의 결과에 이것을
  `.break_loop`로 붙인다: 블록이 끝에 닿으면 `semaBreak`. 나온 `?T`가 전과 같이 `semaIfUnwrapBlock2`로 간다. 블록 표지
  `Block.for_else`를 `semaContinue`가 본다.
- 포맷터는 줄 단위라 바꾸지 않았다(`cyber fmt`가 `else` 갈래를 그대로 둔다).

## 확인

- behavior 테스트 `control_flow/for_iter_else.cy`(오류로 끝남, 오류 없이 끝남, 인덱스, 함수 안의 `return`, 블록 안의 다른
  반복문의 `continue`), 오류 테스트 셋(`_missing_error`, `_not_failing_error`, `_continue_error`).
- `os.Process.lines()`(`modules/os_cmd.cy`, 예제 `examples/stream_lines.cy`).
