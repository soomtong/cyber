# 0.4.19 이후 변경 (미릴리스)

0.4.19(2026-11-24) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 매뉴얼의 Planned 항목 정리와 `os.open_lib` 삭제 (2026-11-24)

C 백엔드를 지운 뒤 `docs/docs.md`에 남은 흔적과 `Planned Feature` 표시를 검토했다. 남길 계획과 뺄 계획은 사용자가 정했다.
결정과 항목별 대안은 `docs/decisions/project_planned_features.md`.

- 호환성: `os.open_lib`과 `os.DynLib`이 없어졌다. 전에도 호출하면 'TODO' panic이었다. 이제 'Can not find the symbol `open_lib` in `os`.'
  컴파일 오류다. C 라이브러리는 `#c.bind_lib(path)`로 묶는다.
- 매뉴얼에 남은 계획: optional chaining, named parameters, `error` set 타입, 더 많은 `Sendable` 타입, destructure import.
  destructure import의 꼴은 `use { cos, pi } from 'math'`로 바꿨다.
- 계획에서 뺀 것: `fmt`의 이름 있는 자리표시자, line-join 리터럴, 가변 `Str`, `?else` 블록의 `break 값`, `+..` 슬라이스, 내용 없는
  호출 절 둘, `defer`, 반환값 구조 분해, 타입 템플릿의 제네릭 타입, 내장 `clone`, weak reference, `@check_cycles`, 할당마다 고르는
  allocator, `error` payload, Future chain, 스레드 사이 공유 메모리 · 채널, 타입이 다른 future의 `await`, 스레드 상태 조회,
  언어 차원의 SIMD, sandbox 모드. 매뉴얼에는 대신 쓰는 방법이 남는다(Cloning은 `clone` 메서드, Back references는 인덱스 · 키,
  Errors는 `Diag`, 타입 템플릿은 `MyContainer[%T]`).
- C 백엔드의 흔적: 매뉴얼 소개의 "Compilation ahead-of-time to C"와 `extern`의 "static or runtime binding"을 고쳤다.
  `MEMORY.md`, `project_direction.md`, `project_coroutines.md`, `docs/study`의 해당 줄에 삭제 사실을 덧붙였다.
