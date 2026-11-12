# 0.4.8 이후 변경 (미릴리스)

0.4.8(2026-11-12) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

- 스택이 커지며 다른 주소로 옮겨질 때 배타 빌림(`&&T`, `<<` · `append` 같은 변경 메서드의 수신자)이 가리키는
  주소가 보정되지 않았다. 옮겨진 뒤 메서드가 옛 스택에 쓰고 읽어 Segmentation fault가 났다. fiber는 스택이 512바이트에서
  시작해 자주 옮겨지므로 "fiber 안에서 다른 fiber를 만든 뒤 지역 배열에 `<<`"로 재현됐다. main 스택에서도 같은 결함이다.
  struct · 옵션 · 벡터 안에 든 스택 포인터도 같았다: 배열 리터럴 `[]T{a, b}`를 만드는 도중 스택이 옮겨지면 원소를
  해제된 옛 스택에서 읽었다. 둘 다 고쳤다.

- `fn main() -> T`가 돌려준 힙 값(`str`, 참조를 가진 struct, `!T` · `?T` 안의 값, 클로저)이 해제되지 않았다.
  VM을 닫아도 메모리가 남았고 Debug · Trace CLI는 `unreleased refcount: 1`과 객체 덤프를 찍었다. 이제 VM이
  결과를 소유하고 다음 eval · `cl_vm_reset` · `cl_vm_deinit` · `cl_vm_release_result`에서 해제한다. 사용자
  `@deinit`은 이 해제에서 불리지 않는다(REPL 결과와 같다).
- `type.info(T)`가 `TypeInfo`를 쓰는 다른 코드보다 먼저 평가되면 컴파일러가 abort했다(`No such field` ·
  `Can not find case`). 파일 최상위의 `#info := type.info(int)`가 그랬다. `type.info`가 `TypeInfo`를 먼저 해석한다.
- 파일 최상위 `#switch`의 case 블록이나 `#for` 본문에 실행문이 있으면 컴파일러가 abort했다(`integer overflow`).
  이제 `Only compile-time statements are allowed in this context.` 컴파일 오류다(최상위 `#if`와 같다).

- `r64` → `float` · `f32` 변환이 값을 부호 있는 정수로 읽었다. `var r r64 = 0xFFFFFFFFFFFFFFFF` 뒤 `float(r)`이
  `-1.0`이었고 이제 `18446744073709551615.0`이다(VM 명령 `U2F` · `U2F32`). `byte` · `r16` · `r32`는 원래 맞았다.
- `float` → raw 정수(`r64(x)` · `byte(x)` 등)는 `x`가 `float` 변수이면 `Expected type f32, got float.` 컴파일 오류였다.
  이제 부호 없는 값으로 변환한다. 2^63 이상도 `r64`에 들어가고, 음수 · NaN · 범위 밖은
  ``panic: Lossy conversion to `r64`.``다. `f32`에서 오는 변환도 같은 규칙을 따른다(이전에는 `r32(4294967295.0)`에
  해당하는 값이 panic이었다).

- `fiber Job.peek(&job)`처럼 타입 경로로 댄 진입점은 빌림 매개변수 검사를 건너뛰었다. `&T` 수신자 메서드가
  fiber에 스택 빌림을 넘길 수 있었다. 이제 이름 하나로 댄 진입점과 같이
  `Cannot borrow a stack value across fibers.` 컴파일 오류다. generator · 비-void 반환 검사도 같이 적용된다.

## 언어와 표준 라이브러리

- `Fiber.cancel() -> bool`: 끝나지 않은 fiber를 나머지 코드를 실행하지 않고 끝낸다. fiber가 들어가 있는 호출이 안쪽부터
  차례로 바로 반환하고, 각 호출이 가진 값은 `return` 때처럼 해제된다(`@deinit` 호출 포함). 실행 중인 fiber와 제너레이터
  본문 안에서 멈춘 fiber는 취소되지 않고 `false`를 돌려준다. 식 중간의 임시 값은 연산자의 피연산자 · 호출 인자 ·
  리터럴 원소일 때 해제되고, 그 밖의 자리에서는 해제되지 않고 남는다.
- 호환성: 진행 중인 fiber의 소멸이 `panic: Fiber is still in progress.` 대신 취소가 됐다. 그 fiber의 프레임이 가진
  fiber도 연쇄로 취소된다. 취소할 수 없는 fiber(제너레이터 본문 안에서 멈춘 것)의 소멸은 여전히 panic이다.

- `Scope`: fiber 묶음을 돌리는 타입. `Scope.new()`, `start(func, {args})`, `join() -> !void`, `active()`.
  `join`은 모든 fiber가 끝날 때까지 차례로 resume하고, 전부 Future를 기다리면 `Fiber.wait_ready()`처럼 기다린다.
  진입 함수는 `void` 또는 `!void`를 돌려주고 `join`은 첫 오류를 돌려준다. 오류 뒤에는 나머지 fiber를 취소한다
  (`Fiber.cancel`). `join` 없이 블록을 나가면 소멸 때 먼저 합류한다. 그때 남은 오류는 panic이다.

- fiber 안의 `Future.await()`와 `Future.wait_any`가 미완료 Future에서 기다리지 않고 그 fiber를 멈춘다
  (`resume`은 `.suspended`를 돌려준다). 다른 fiber가 그동안 돈다. 대기 중인 fiber의 `resume`은 본문에 들어가지
  않고 바로 `.suspended`다. 루트 맥락(fiber 밖)의 `await`는 그대로다.
- `Fiber.waiting()`: fiber가 미완료 Future에서 멈춰 있는지. `suspend`로 멈춘 fiber와 구분한다.
- `Fiber.wait_ready()`: 멈춘 fiber가 기다리는 Future 중 하나가 끝날 때까지 루트를 재우고 `true`를 돌려준다.
  기다리는 fiber가 없으면 바로 `false`. spawn의 Future는 VM 안에서 기다리고, 호스트만 완료할 수 있으면 eval이
  `CL_AWAIT`로 나간다. fiber 안에서 부르면 그 fiber가 멈춘다.

- `type.info(Trait)`가 `TypeInfo.trait`(`TraitInfo{name}`)를 돌려준다. 이전에는
  ``type.info does not support the trait`` 컴파일 오류로 막아 두었다.

- 한 번도 `resume`하지 않은 fiber를 소멸할 수 있다. 진입 함수는 불리지 않고 인자만 해제된다. 이전에는
  `panic: Fiber is still in progress.`였다. 한 번이라도 resume한 뒤 끝나지 않은 fiber의 소멸은 여전히 panic이다.
- `fiber obj.work()`는 ``Type `T` does not have a field named `work`.`` 대신 대체 표기를 알려 주는 오류를 낸다.
  메서드를 진입점으로 쓰려면 타입으로 이름을 대고 수신자를 첫 인자로 넘긴다: `fiber Job.work(job, 2)`.

## 임베딩 API

- 호환성: fiber 안에서 호스트 Future를 await해도 eval이 더는 `CL_AWAIT`로 나가지 않는다(0.4.8에서는 나갔다).
  fiber만 멈추고 스크립트는 resume한 쪽에서 계속된다. eval이 나가는 것은 루트 맥락이 기다릴 때다: 루트의
  `await` · `Future.wait_any` · `Fiber.wait_ready()`. fiber를 resume하는 루프는 `Fiber.wait_ready()`를 불러야
  호스트가 Future를 완료할 기회를 얻는다. 부르지 않으면 연료 · 시간 상한까지 돈다.
- `cl_vm_pending_futures`는 `Fiber.wait_ready()`로 멈춘 eval에서 멈춘 fiber들이 기다리는 Future 전부를 돌려준다
  (순서 없음, 태그로 식별). 그중 하나를 완료하고 resume하면 된다.

- `cl_vm_release_result(vm)`: 마지막 eval이 `CLEvalResult`로 돌려준 값을 바로 해제한다. 그 뒤에는 `res->res`를
  읽을 수 없다. `cl_thread_rc`로 누수를 세는 호스트는 먼저 이것을 부른다. `CLEvalResult`의 값은 VM 소유이고
  다음 eval · reset · deinit까지 유효하다는 규칙을 `cyber.h`에 적었다.

## 변경

- `cyber fmt`가 리터럴 필드의 `=` 양쪽을 한 칸 띄운다: `Vec2{x=1, y=2}` → `Vec2{x = 1, y = 2}`. 이전에는 쓴 그대로
  두었다. 속성(`#[extern='puts']`) 안의 `=`는 계속 쓴 그대로 둔다. 이미 포맷한 파일도 `x=1`로 쓴 곳이 있으면
  다시 바뀐다. `examples/fmt.cy`도 같은 규칙을 따른다.

## 문서
