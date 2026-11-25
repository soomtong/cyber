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

