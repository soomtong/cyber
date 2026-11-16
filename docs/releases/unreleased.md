# 0.4.12 이후 변경 (미릴리스)

0.4.12(2026-11-16) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## CLI

- `cyber doc [topic]`: 실행 파일에 넣은 매뉴얼(`docs/docs.md`)을 출력한다. 토픽은 문서 사이트의 anchor와 같은 id(`optionals`,
  `for-range`)이고, 제목 글자나 id의 일부로도 찾는다(여럿이 맞으면 후보를 보이고 종료 코드 1). `--list`는 id 전체를 수준별 들여쓰기로 낸다.
- `cyber doc --for-agents`: 코딩 에이전트용 안내 `docs/agents.md`(Python과 다른 점, 흔한 메서드, 모듈, 예제 11개, 고치는 법을
  말하지 않는 오류)와 장 · 절 id 목록을 낸다. 바이너리에 들어 있어 `cyber version`과 항상 맞는다. 안내의 예제는 `cli-test`가 모두
  실행해 낡지 않게 한다. tars-agent `prompt/cyber-subset.en.md`에서 호스트 전용 내용을 뺀 것이 바탕이다.
- `doc`이 명령이 되어 확장자 없는 스크립트 `doc`은 `cyber ./doc`으로 실행한다.

## 동시성

- 취소 도중 `@deinit`이 다시 멈춰도(`suspend` · `await`) panic하지 않는다. 그 `@deinit`은 fiber가 있던 다른 함수처럼 멈춘
  자리에서 끝나고, 값의 나머지(필드 등)와 다른 값의 해제가 이어진다. 전에는 `panic: A fiber was suspended while it was
  cancelled.`이었다. `Fiber.cancel()` · fiber 소멸 · `scope`의 취소에 모두 해당한다. 바뀐 점: 취소될 때 `@deinit`의 `suspend` ·
  `await` 뒤 코드는 돌지 않는다. 테스트 `concurrency/fiber_cancel_deinit_suspend.cy`.
