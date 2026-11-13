# 0.4.9 이후 변경 (미릴리스)

0.4.9(2026-11-12) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

## 언어와 표준 라이브러리

## 임베딩 API

## 변경

## 문서

- `docs/docs.md`의 Concurrency 장을 다시 구성했다: Overview(thread · fiber · generator 비교), Threads, Futures, Fibers,
  Structured concurrency(`scope` 블록 · `Scope`), Cancellation, Generators, Planned concurrency features.
  fiber 절은 Threads 아래에서 독립된 절로 옮겼다. 앵커 `#fibers` · `#generators` · `#futures`는 그대로다.
- 구현된 것인데 TBD · Planned로 남아 있던 절을 채웠다: Manual memory(`alloc` · `free`), Unwrap or guard,
  Conditional compilation, Resolving futures(`FutureResolver.new`), Type binding 예제, 제너레이터 `end`.
  libcyber 장에 Limiting an eval(`cl_vm_interrupt` · `cl_vm_set_fuel` · 스택 · 메모리 한도)을 추가했다.
- 구현되지 않은 것은 TBD 대신 Planned Feature · Incomplete로 통일하고 지금 쓸 수 있는 대안을 적었다
  (`aio` 모듈 예제 삭제, `then_spawn` · 채널 · 공유 메모리 · `await` union · SIMD · `os.openLib` · `c.source` 등).
- 최상위 `#if` 예제가 컴파일 오류가 나는 형태였다. 함수 본문 안의 예제로 바꿨다. 깨진 앵커 세 개를 고쳤다.
- 문서 사이트의 Edit Page 링크와 libcyber 장의 헤더 · 예제 링크가 이 저장소를 가리킨다.
