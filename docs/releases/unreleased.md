# 0.4.7 이후 변경 (미릴리스)

0.4.7(2026-11-12) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

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
