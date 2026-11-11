# 0.4.6 이후 변경 (미릴리스)

0.4.6(2026-11-11) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

## 언어와 표준 라이브러리

- 제너레이터 선언이 `#[generator]` 속성에서 `generator fn` 선언으로 바뀌었다. 호환되지 않는 변경이다.
  ```cy
  -- 이전
  #[generator]
  fn count() -> int:
      yield 1

  -- 이후
  generator fn count() -> int:
      yield 1
  ```
  - `generator`는 예약어가 아니다. 바로 뒤에 `fn`이 올 때만 수식어이고, 그 밖에는 이름으로 쓸 수 있다.
  - 숨김 선언은 `-generator fn`, 속성은 수식어 앞에 둔다(`#[inline] generator fn`).
  - `#[generator]`는 ``ParseError: The `#[generator]` attribute was replaced by `generator fn`.``이다.
  - 오류 문구가 바뀌었다: `` `yield` is only allowed in a `generator fn`. ``,
    ``A `generator fn` can not take the borrow type `&int` as a parameter. ...``
  - `cy` 모듈의 `FuncDecl`에 `generator bool` 필드가 생기고 `AttributeKind.generator`가 없어졌다.
  - tree-sitter 문법에 `generator_fn` 노드를 더했다(`generator fn`이 한 토큰). 속성 형태는 더 이상 제너레이터로 읽지 않는다.
  - 근거와 `generator f()` 대신 `generator fn f()`를 고른 이유는 `docs/decisions/project_coroutines.md`의
    "선언 모양 변경과 구현 (2026-11-11)" 절.

## 임베딩 API

## 변경

## 문서
