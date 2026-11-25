# 0.4.20 이후 변경 (미릴리스)

0.4.20(2026-11-24) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 모듈 수준 연산자 함수: `2.0 * v`

왼쪽 피연산자 타입에 연산자 메서드가 없으면 두 피연산자 타입을 선언한 모듈의 모듈 수준 함수 `` fn `op`(a A, b B) ``를 찾는다.
왼쪽이 수인 `2.0 * v` · `2 * v`를 `Vec2` 쪽 모듈이 정의할 수 있다. 전에는 'Expected `float`, found `Vec2`.' 오류였다.

~~~cy
fn `*`(s float, v Vec2) -> Vec2:
    return {x=s * v.x, y=s * v.y}

d := 2.0 * a
e := 2 * a      -- 리터럴은 매개변수 타입을 따른다.
~~~

- 산술 · 비트 연산자만이다. 비교 연산자(`< <= > >=`)를 모듈 수준에 선언하면 'Declare `<` as a method of the left operand
  type. ...' 오류다.
- 모듈 수준 연산자 함수는 매개변수가 둘이고 그중 하나가 같은 모듈의 타입이어야 한다. 아니면 'The operator function `*` must take
  a type declared in this module, ...' 오류다(깨지는 변경이지만 core · std · 테스트에 해당하는 선언은 없었다).
- 결정 `docs/decisions/project_operator_lookup.md`, 매뉴얼 Operator methods 절.

## 모호한 오버로드 호출의 LSP 경고

두 오버로드가 같이 맞고 먼저 선언한 쪽이 다른 쪽보다 더 구체적이지 않은 호출에 `cyber-lsp`가 Warning을 낸다(동작은 그대로,
먼저 선언한 쪽을 부른다).

~~~cy
fn tag(x ?str) -> str: return 'str'
fn tag(x ?int) -> str: return 'option int'

print(tag(none))
-- warning: This call matches both `fn tag(?str) -> str` and `fn tag(?int) -> str`, and the one declared first is picked. ...
~~~

- 수 타입끼리만 다른 오버로드(`float(x)`에 `i32`), 문자열 리터럴 자리에서 `str`과 정수만 다른 오버로드(`s.index('\n')`,
  json `v['n']`)는 경고하지 않는다. 한 글자 리터럴은 문자열이 먼저다.
- 인자가 이름 · 리터럴일 때만 본다. 임베딩은 `cl_vm_symbol_hints`의 `CL_HINT_AMBIGUOUS_CALL`로 받는다.
- 결정 `docs/decisions/project_overload_exact_match.md` 끝 절. core · std · 테스트에서 걸리는 곳은 의도된 테스트 하나였다.

## `cyber-lsp`: 컴파일되지 않을 정규식 · PEG 리터럴

`regex.compile` · `peg.compile`에 문자열 리터럴을 넘기면 `cyber-lsp`가 실행 전에 그 패턴을 컴파일해 보고, 실패하면 Error
진단을 낸다. 실행할 때 받을 `Diag`의 문구 그대로다.

~~~cy
bad := regex.compile('xa(?=b)')
-- error: `regex.compile` will fail: Look-ahead (`(?=...)`, `(?!...)`) is not supported: ...
~~~

- 이스케이프가 없는 리터럴은 오류가 난 글자를, 있으면 리터럴 전체를 가리킨다. 보간이 있는 문자열은 보지 않는다.
- 임베딩은 `cl_vm_symbol_hints`의 `CL_HINT_PATTERN_LITERAL`로 리터럴의 자리를 받는다. 컴파일 타임 검증(Julia 검토 3.4 F)은
  평가기를 넓힐 때까지 미룬다. LSP 설계 문서 19절.

