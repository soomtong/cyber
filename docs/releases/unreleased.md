# 0.4.7 이후 변경 (미릴리스)

0.4.7(2026-11-12) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

- `yield` 식의 임시 값이 해제되지 않았다. `yield make().get()`이나 `yield tool(x).await()`처럼 식 안에서 만든 객체가
  반복마다 하나씩 샜다. 이제 재개된 뒤에 해제하고, 그 `yield`에서 멈춘 채 generator가 버려지면 정리 블록이 해제한다(F-97).

- `cy.parse`가 구문 오류에서 panic했다. 스크립트가 잡을 수 없어 스택 트레이스와 함께 끝났다. 이제 오류를 기록하고
  `root`가 `none`인 `ParseResult`를 돌려준다. 토큰 오류(끝나지 않은 문자열 등)도 위치와 함께 기록한다(F-96).

- `fn main() -> !T`가 돌려준 오류가 버려졌다. `os.read_file_str('nofile')!`로 끝나도 아무것도 출력하지 않고 종료 코드 0이었다.
  이제 최상위의 `expr!`처럼 ``panic: Unwrapped error `error.FileNotFound`.``로 끝나고 `cyber`의 종료 코드는 1이다.
  `fn main() -> error`가 돌려준 오류도 같다.
  임베딩 호스트는 이 경우 `!T` 값 대신 `CL_ERROR_PANIC`을 받는다(F-96).
- `str.trimLeft` · `trimRight` · `trim`에 구분자를 여럿 주면 구분자마다 한 번씩만 훑었다.
  `'abc  \r'.trimRight({' ', '\r', '\t'})`가 `'abc  '`였다. 이제 어느 구분자도 남지 않을 때까지 깎는다.
  빈 구분자(`'abc'.trim('')`)는 끝나지 않는 루프였고 이제 아무것도 깎지 않는다(F-96).
- `[]T.join` · `Array[T].join`이 길이에 대해 제곱 시간이었다(10만 개에 6초). 바이트로 모아 한 번에 `str`을 만든다(F-96).

- 16진 · 8진 · 2진 리터럴이 `float` · `f32` 자리에 오면 자릿수를 10진 소수로 읽었다. `var f float = 0x10`이 16이 아니라 10,
  `0b101`이 101, `0o17`이 17이었고, 10진 숫자가 아닌 글자가 있으면(`float((0x7fffffffffffffff))`) 위치 없는
  `CompileError: Error: InvalidCharacter`였다. 이제 리터럴의 값(부호 없는 64비트)을 float으로 바꾼다(F-95).
- 끝이 없는 범위(`..` · `a..`)를 슬라이스 인덱스가 아닌 자리에 쓰면 위치 없는 `CompileError: Error: Unexpected`였다.
  이제 위치와 함께 `Expected range end. A range without an end is only allowed as a slice index.`를 보고한다.
  `case 1..:`는 컴파일러를 끝냈고 이제 `Expected a range with a start and an end.`다(F-95).

## 언어와 표준 라이브러리

- `Future.wait_any(futures [&]Future[T]) -> int`: 여러 Future 중 먼저 끝난 것의 인덱스를 돌려준다. 여럿이 끝나 있으면 목록에서
  앞선 것이다. spawn한 스레드의 Future는 VM 안에서 기다리고, 목록에 그런 Future가 없으면 호스트가 하나를 완료시킬 때까지
  eval이 멈춘다(`CL_AWAIT`). 빈 목록은 `panic: No futures to wait for.`
- 피연산자의 평가 순서가 왼쪽에서 오른쪽으로 지켜진다(F-98). 이전에는 식 안에서 임시 값을 만드는 부분(메서드 수신자의 임시,
  `await`, `!` 등)이 그 문장의 다른 피연산자보다 먼저 실행됐다. `say(1) + mk(2).get()`가 `mk(2)`를 먼저 불렀고,
  `ask(2).await() + ask(3).await()`는 요청 둘을 먼저 보냈다. 이항 연산, 호출 인자(제네릭 · 오버로드 포함), 배열 · 구조체 초기화,
  문자열 템플릿에 적용된다. 구조체 초기화의 순서는 타입의 필드 순서다.

- 슬라이스의 시작을 생략할 수 있다. `a[..n]`은 `a[0..n]`이다(`Slice` · `Array` · `str` · span 등 `@slice(start, end)`가 있는
  타입 전부). 이전에는 `Expected closing bracket.`이었고 `a[..-1]`은 `(..) - 1`로 파싱됐다. 시작이나 끝이 없는 범위는
  슬라이스 인덱스에서만 쓴다. `r := ..3` · `for ..3 |i|` · `case ..5`는 컴파일 오류다. 부분 벡터 타입 `[..4]T`는 그대로다.

## 임베딩 API

- 호스트가 VM 밖에서 기다릴 수 있다(코루틴 로드맵 단계 1, `CL_AWAIT`). main 스레드의 `Future.await()`가 아직 완료되지 않았고
  `spawn`이 만든 것도 아닌 Future를 만나면 eval이 `CL_AWAIT`로 돌아온다. 스택 · 지역 변수 · 남은 연료는 그대로이고, 호스트가
  Future를 완료시킨 뒤 `cl_vm_resume`으로 멈춘 `await`에서 이어 실행한다. resume은 멈춘 동안 들어온 interrupt 요청을 지우고
  (벽시계 타이머가 호스트의 대기 시간을 세지 않는다) 연료는 다시 채우지 않는다. 호출 깊이에 제약이 없고 generator 본문과 fiber
  안에서도 같다. 새 함수: `cl_future_new`(호스트 함수가 돌려줄 미완료 `Future[T]`), `cl_future_complete`(값으로 완료,
  `Future[!U]`면 `U`를 넘김), `cl_future_complete_error`, `cl_vm_pending_future`, `cl_vm_resume`, `cl_vm_abandon`(멈춘 eval을
  interrupt처럼 버림), `cl_vm_pending_futures`(`Future.wait_any`가 기다리는 목록 전체. 호스트는 그중 아무것이나 완료시킨다).
  새 결과 코드 `CL_ERROR_SUSPENDED`: 멈춘 동안의 `cl_vm_eval*` · `cl_vm_validate` · `cl_vm_compile*`.
  `cl_vm_reset` · `cl_vm_deinit`은 멈춘 eval을 먼저 버린다. 완료는 eval을 돌리는 스레드에서만 한다.
  호스트가 Future 포인터를 보관하려면 만들 때 `cl_thread_retain`으로 잡는다(버려진 Future의 주소가 다음 Future에 다시 쓰인다).
  완료시킨 뒤나 eval이 `CL_SUCCESS`로 끝났을 때 놓고, panic · interrupt · abandon 뒤에는 힙이 이미 해제됐으므로 놓지 않는다.
  예제 `examples/libcyber/host_await.c`, 결정 문서 `docs/decisions/project_coroutines.md`의 "단계 1 구현" 절.
- 같은 변경으로 바뀐 동작: 같은 스레드의 미완료 Future(`FutureResolver`)를 await하면 `panic: Local future will never complete.`
  대신 `CL_AWAIT`가 된다. `cyber` CLI와 `cy.eval`은 Future를 완료시킬 수 없으므로 그 eval을 버리고
  `panic: Abandoned while awaiting a future.`로 끝난다. spawn한 스레드 안에서는 `Cannot wait in a spawned thread for a future
  that the host or another context completes.`, 호스트 함수가 부른 함수 안에서는 `Cannot await across a host call.` panic이다.
- `clResultName`이 `CL_AWAIT` · `CL_ERROR_SUSPENDED`에서 abort하지 않고 이름을 돌려준다.
- wasm32에서 `CLValue`를 값으로 주고받는 함수 일곱 개의 ABI가 헤더와 달랐다(`cl_thread_retain` · `cl_thread_release` ·
  `cl_object_string` · `cl_array_empty` · `cl_map_empty` · `cl_new_func_union` · `cl_lift`). 헤더는 `uint64_t`인데 export는
  유니언이었다. 64비트 정수로 맞췄다. 64비트 타깃의 동작은 같다(F-99).

## 변경

## 문서
