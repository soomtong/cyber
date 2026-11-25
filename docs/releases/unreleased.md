# 0.4.21 이후 변경 (미릴리스)

0.4.21(2026-11-25) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 0.4.20..HEAD 리뷰 수정 (2026-11-25)

`/code-review high` 0.4.20..HEAD의 결과를 고쳤다(커밋 제목 길이 1건은 고치지 않음).

- 모듈 수준 연산자 함수: 오른쪽 수 리터럴이 매개변수 타입을 따른다. `fn `*`(c Cents, f float)`에 `c * 2`가 'Can not apply `*`
  to `Cents` and `int`' 오류였다(`2 * c`는 됐다). `-2`도 같다.
- 모듈 수준 연산자 함수: 왼쪽이 다른 모듈의 타입(`str` 등)이고 메서드가 없으면 오른쪽 타입의 모듈에서도 찾는다. 전에는 선언은
  되는데 `'abc' * v`가 'Can not find the symbol' 오류였다.
- 모호한 오버로드 호출 검사가 런타임 템플릿 후보(`fn f(x %T)`)를 빼고 맞춰 봐서, 템플릿이 고르는 호출을 모호하다고 거짓 오류로
  냈다. 템플릿 후보가 있는 함수는 검사하지 않는다. 오버로드가 하나인 호출도 검사하지 않는다(컴파일이 빨라진다).
- `os.cmd` · `os.Process`: VM 중단 요청으로 명령을 멈췄는데 호출한 스레드가 검사점에서 멈추지 않으면(끝까지 도는 drop의
  `@deinit`) 명령을 되풀이해 다시 실행할 수 있었다. 이제 그 스레드에서는 `error.Interrupted`다. `run` · `read` · `run_status`는
  호출한 스레드의 중단 요청을 본다.
- 깨지는 변경: `os.File` · `os.Dir`의 `closed` 필드는 비공개다. 닫혔는지는 `is_closed()`로 본다. 밖에서 `closed = true`로 두면
  panic · VM 끝의 정리가 그 번호의 핸들(그사이 다른 파일일 수 있다)을 닫았다.
- `#for` 뒤의 `else`를 `#for`의 것으로 읽지 않는다(컴파일 타임 반복은 실패하지 않는다).

## `os.cmd`: `2>&1`, `detach`, `Process.pid` (2026-11-25)

- `Cmd.stderr_to_stdout()`: 지금까지의 단계마다 stderr를 그 단계의 stdout이 가는 곳으로 보낸다(`2>&1`). 다음 단계로 가는 파이프,
  `read` · `start`가 읽는 출력, `stdout_file`의 파일, 이 프로세스의 stdout. 두 스트림은 프로그램이 쓴 순서대로 섞인다.
- `Cmd.detach() -> !int`: 기다리지 않고 시작해 마지막 단계의 pid를 돌려준다. stdin은 빈 입력, stdout · stderr는 파일로 보내지
  않으면 버린다. eval · VM이 끝나도, `cl_vm_interrupt`에도 멈추지 않는다. POSIX에서는 따로 프로세스 그룹을 둔다. 호스트의 스레드가
  끝을 기다려 회수한다. 시간 제한과 함께 쓰면 `error.InvalidArgument`.
- `Process.pid() -> int`: 마지막 단계의 pid.
