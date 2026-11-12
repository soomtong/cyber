# 0.4.8 이후 변경 (미릴리스)

0.4.8(2026-11-12) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

## 언어와 표준 라이브러리

- 한 번도 `resume`하지 않은 fiber를 소멸할 수 있다. 진입 함수는 불리지 않고 인자만 해제된다. 이전에는
  `panic: Fiber is still in progress.`였다. 한 번이라도 resume한 뒤 끝나지 않은 fiber의 소멸은 여전히 panic이다.
- `fiber obj.work()`는 ``Type `T` does not have a field named `work`.`` 대신 대체 표기를 알려 주는 오류를 낸다.
  메서드를 진입점으로 쓰려면 타입으로 이름을 대고 수신자를 첫 인자로 넘긴다: `fiber Job.work(job, 2)`.

## 임베딩 API

## 변경

## 문서
