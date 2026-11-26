# 다중 대입과 한 줄 `?else return` (2026-11-26)

상태: 구현됨. 사용자 결정(2026-11-26): "다중 대입과 한 줄 ?else return 둘 다 넣자". Fibonacci 예제를 쓰다 드러난 두 빈틈이다.
`a, b = b, a + b`를 쓸 수 없어 임시 변수 셋이 필요했고, `next := a.checked_add(b) ?else return none`은 'Expected default
expression.'이라 두 줄 블록으로 써야 했다.

## 비교

다중 대입:

- Python: `a, b = b, a + b`. 오른쪽은 튜플 하나로 먼저 다 계산되고, 왼쪽은 순서대로 받는다. 개수가 다르면 `ValueError`(런타임).
- Go: `a, b = b, a+b`와 `a, b := 0, 1`. 오른쪽 피연산자와 왼쪽의 인덱스 · 포인터 식을 먼저 계산한 뒤 왼쪽부터 대입한다. 개수는 컴파일
  시간에 맞춘다. 함수의 여러 반환값도 같은 꼴로 받는다.
- Zig 0.17.1: 분해 대입 `a, b = .{ b, a + b }`와 `const q, const r = .{ ... }`. 오른쪽은 튜플 하나다.
- Rust: `(a, b) = (b, a + b);`(1.59부터), `let (a, b) = (0, 1);`. 튜플 분해.
- Nim: `(a, b) = (b, a + b)`, `let (q, r) = divmod(...)`.
- Lua: `a, b = b, a + b`. Go와 같은 순서.

한 줄 탈출:

- Zig: `const n = o orelse return null;`, `catch |e| return e`. `return`은 `noreturn` 식이다.
- Kotlin: `val n = o ?: return null`.
- Swift: `guard let n = o else { return nil }`(블록 필수). Rust: `let Some(n) = o else { return None };`(블록 필수).

## 결정

1. `a, b = x, y`와 `a, b := x, y`(Go · Lua · Python의 꼴). 괄호 없이 쉼표만 쓴다. 다중 반환이 없어 오른쪽은 늘 값의 목록이고,
   개수가 다르면 파서 오류('2 places take 2 values, found 3. Write one value for each: `a, b = x, y`.').
2. 오른쪽 값을 왼쪽부터 모두 계산한 뒤 왼쪽부터 대입한다(Python · Go · Lua). 맞바꾸기에 임시 변수가 필요 없다.
3. `=`의 자리는 변수 · 필드 · 원소 · 역참조, `:=`의 이름은 새 변수다. `+=` 등은 한 자리만('Expected `=` or `:=` after the list of
   variables. ...').
4. 튜플 분해(`q, r := divmod(7, 2)`)는 넣지 않았다. 함수는 값 하나를 돌려주고(매뉴얼 "Functions can only return one value"), 분해는
   튜플 타입의 필드 이름 · 개수 규칙을 따로 정해야 한다. 쓸 곳이 생기면 이 꼴 위에 더한다.
5. `?else` · `!else`(포획 `|err|` 포함) 뒤에 `return` · `break` · `continue` 하나는 `:` 없이 같은 줄에 온다(Zig · Kotlin). 이미 있던
   한 줄 블록(`?else: return none`)과 같은 노드다. `panic(...)`은 원래 식이라 기본값 자리에 그대로 쓴다.

## 구현

- 파서: `parseExprOrAssignStatement`가 첫 식 뒤의 `,`를 보면 `parseMultiStmt`. 쌍마다 `assign_stmt`나 `var_decl`을 만들어 새 노드
  `multi_stmt{stmts, decl}`에 담는다(`ast.zig` 다섯 곳, 노드 수 테스트, `cy.cy` 거울). `?else` · `!else` 뒤의 `isJumpKeyword`.
- sema(`sema_assign.semaMultiStmt`): 리터럴이 아닌 오른쪽을 먼저 숨은 지역(`_multi`)에 소유해 담고, `place_subst`에 `take`로 등록한다.
  그다음 각 쌍을 평소의 `semaAssignStmt` · `localDecl`로 분석하면 오른쪽 노드가 숨은 지역을 읽는다. `take`는 숨은 지역에서 값을 꺼내
  (지역은 죽음) 복사하지 않는다. 그래서 `NoCopy` 맞바꾸기(`xs, ys = ys, xs`)는 두 변수를 옮긴 뒤 되살린다(단일 대입의 규칙). 리터럴은
  제자리에 두어 자리의 타입을 받는다.
- tree-sitter: `multiple_assignment` · `multiple_declaration`(첫 이름 뒤 `,`의 충돌 하나), `unwrap_or_block`의 `_jump_statement`.
  포매터는 토큰 기반이라 그대로다.

## 검증

- `control_flow/multi_assign.cy`(피보나치, 문자열 맞바꾸기, 평가 순서, `i32` 리터럴, 필드 · 원소, `Array` 맞바꾸기, 바깥 이름을 읽는
  선언, 함수 안), 오류 테스트 넷(개수, `+=`, 선언의 이름 아닌 것, 옮긴 값의 재사용), `control_flow/else_jump.cy`.
- tree-sitter 코퍼스 두 항목.
