# 0.4.23 이후 변경 (미릴리스)

0.4.23(2026-11-26) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 정수 넘침은 panic (2026-11-26)

- 깨지는 변경: 부호 있는 정수(`int`, `i32`, `i16`, `i8`)의 `+ - * **`, 단항 `-`, `/`가 타입에 들어가지 않으면 'Integer overflow.'
  panic이다. 전에는 조용히 감겼다(`int.max + 1`이 `int.min`). 상수 식은 같은 문구의 컴파일 오류다(`const k = int.max + 1`).
  `x % -1`은 언제나 0. raw 정수(`byte`, `r16`, `r32`, `r64`)는 그대로 감긴다.
- 새 메서드: `wrapping_add` · `wrapping_sub` · `wrapping_mul`(감김을 뜻하는 자리: 해시, 난수), `checked_add` · `checked_sub` ·
  `checked_mul`(`?Self`, 넘치면 `none`). 매뉴얼 "Integer overflow.", 결정 `docs/decisions/project_int_overflow.md`.
- 결함 수정: 컴파일 타임 `-(int.min)`의 호스트 panic(F-219), 런타임 `int.min / -1` · `% -1`의 C 정의되지 않은 동작(F-220).
- 바이트코드: `s += 1`이 4칸에서 5칸이 됐다. 함수 본문 크기 한계('Function body too large.')에 조금 일찍 닿는다.
