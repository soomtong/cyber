# 0.4.7 이후 변경 (미릴리스)

0.4.7(2026-11-12) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

- `cy.parse`가 구문 오류에서 panic했다. 스크립트가 잡을 수 없어 스택 트레이스와 함께 끝났다. 이제 오류를 기록하고
  `root`가 `none`인 `ParseResult`를 돌려준다. 토큰 오류(끝나지 않은 문자열 등)도 위치와 함께 기록한다(F-96).

- `fn main() -> !T`가 돌려준 오류가 버려졌다. `os.read_file_str('nofile')!`로 끝나도 아무것도 출력하지 않고 종료 코드 0이었다.
  이제 최상위의 `expr!`처럼 ``panic: Unwrapped error `error.FileNotFound`.``로 끝나고 `cyber`의 종료 코드는 1이다.
  임베딩 호스트는 이 경우 `!T` 값 대신 `CL_ERROR_PANIC`을 받는다(F-96).
- `str.trimLeft` · `trimRight` · `trim`에 구분자를 여럿 주면 구분자마다 한 번씩만 훑었다.
  `'abc  \r'.trimRight({' ', '\r', '\t'})`가 `'abc  '`였다. 이제 어느 구분자도 남지 않을 때까지 깎는다.
  빈 구분자(`'abc'.trim('')`)는 끝나지 않는 루프였고 이제 아무것도 깎지 않는다(F-96).
- `[]T.join` · `Array[T].join`이 길이에 대해 제곱 시간이었다(10만 개에 6초). 바이트로 모아 한 번에 `str`을 만든다(F-96).

- 16진 · 8진 · 2진 리터럴이 `float` · `f32` 자리에 오면 자릿수를 10진 소수로 읽었다. `var f float = 0x10`이 16이 아니라 10,
  `0b101`이 101, `0o17`이 17이었고, 10진 숫자가 아닌 글자가 있으면(`float((0x7fffffffffffffff))`) 위치 없는
  `CompileError: Error: InvalidCharacter`였다. 이제 리터럴의 값(부호 없는 64비트)을 float으로 바꾼다(F-95).
- 끝이 없는 범위(`..` · `a..`)를 슬라이스 인덱스가 아닌 자리에 쓰면 위치 없는 `CompileError: Error: Unexpected`였다.
  `a[..-1]`도 `(..) - 1`로 파싱되어 여기에 닿는다. 이제 위치와 함께
  `Expected range end. A range without an end is only allowed as a slice index.`를 보고한다(F-95).

## 언어와 표준 라이브러리

## 임베딩 API

## 변경

## 문서
