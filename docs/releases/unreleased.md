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
- 중첩 `scope`의 대기가 빨라졌다. 안쪽 `scope`에서 Future를 기다리는 fiber에 바깥 `scope`가 바퀴마다 `Fiber.waiting()`을 물을 때
  매번 스레드의 fiber를 전부 훑었다(바퀴 수 × 그룹 수 × fiber 수). 이제 답을 Future가 완료될 때까지 기억한다. 안쪽 그룹
  400개 · fiber 2401개 · 한 바퀴에 Future 하나를 완료하는 경우가 2.8초에서 0.24초(ReleaseFast). 테스트 `concurrency/scope_nested_wait.cy`.
- `@deinit`이 여러 번 다시 멈추는 fiber의 취소가 빨라졌다. 멈출 때마다 fiber의 프레임을 처음부터 다시 걷고 프레임마다 취소
  표를 선형으로 훑어, 프레임마다 `@deinit`이 멈추는 깊이 4000의 취소가 0.51초였다(깊이의 제곱). 이제 이미 패드로 돌려진
  프레임에서 걷기를 멈춘다: 깊이 4000이 0.01초 미만, 20000이 0.01초(ReleaseSafe).

## 버그 수정

- wasm32에서 빌림(`&T`)을 둘 이상 가진 구조체나 `[N]&T`가 있는 프레임의 스택이 옮겨지면 메모리가 깨졌다(F-156). 4바이트
  포인터 둘이 값 칸 하나에 들어가는데, 위 절반의 포인터는 보정되지 않았고 아래 절반을 보정할 때 위 절반이 지워졌다. `scope`
  블록에서 빌림을 받은 fiber가 시작하기 전에 부모 fiber의 스택이 자라면 `Retaining untracked heap object`로 죽었다. native는 영향이
  없다. 테스트 `functions/packed_borrow_stack_grow.cy`, `concurrency/scope_block_borrow_cancel.cy`.
- choice의 앞 case가 빌림 하나(`case one &int`)이고 뒤 case가 빌림 벡터(`case many [3]&int`)이면, 스택이 옮겨질 때 벡터의
  둘째 원소부터 보정되지 않아 옛 스택을 읽었다(F-157). `case Pair` 뒤의 `case [3]Pair`도 같다. 0.4.12 전부터 있던 결함이다.
  포인터가 없는 원소의 벡터(`[N]i32` 등)는 wasm32에서 지역을 잡을 때마다 원소 수만큼 돌던 것도 없앴다. 테스트
  `functions/payload_borrow_stack_grow.cy`.
- fiber를 취소하거나 버릴 때 `@deinit`이 fiber의 스택을 키우면(깊은 호출), 그 뒤에 도는 `@deinit`이 읽는 빌림(`&T` ·
  `Ptr[T]` 필드)이 해제된 옛 스택을 가리켰다(F-158). 빌림이 같은 함수에 있든 아래 함수에 있든 같다. fiber 스택이 64칸에서
  시작해 `@deinit`이 조금만 깊어도 걸렸다. 0.4.12 전부터 있던 결함이다. 테스트 `concurrency/fiber_cancel_stack_grow.cy`.
