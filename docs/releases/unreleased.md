# 0.4.23 이후 변경 (미릴리스)

0.4.23(2026-11-26) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 예제 `e_digits.cy` (2026-11-26)

- e를 N째 소수 자리까지(Sale의 spigot, 최대 1000자리). `pi_digits.cy`와 같은 꼴로 인자 · 프롬프트 · 파이프로 받는다.
  `pi_digits.cy`의 혼합 기수 배열 이름을 `terms`로 바꿨다(소수 자리 수 `places`와 겹쳤다).
