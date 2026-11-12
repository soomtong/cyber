# `main`이 돌려준 오류

결정일 2026-11-12. 사용자 확인: 최상위 예외로 다룬다.

## 문제

`fn main() -> !T`가 오류를 돌려주면 아무 일도 일어나지 않았다. `os.read_file_str('nofile')!`로 끝나도 출력이 없고
`cyber`의 종료 코드는 0이었다. 함수 안의 `expr!`는 오류를 호출자에게 돌려주는데, `main`의 호출자인 프로그램 부트스트랩이
결과를 보지 않았다.

## 결정

`main`이 돌려준 오류는 최상위의 `expr!`와 같은 panic이다.

- ``panic: Unwrapped error `error.FileNotFound`.``로 끝나고 `cyber`의 종료 코드는 1이다. 트레이스의 위치는 `main` 선언이다.
- 임베딩 호스트는 이 경우 `!T` 값 대신 `CL_ERROR_PANIC`을 받는다. `cl_thread_panic_summary`로 메시지를 읽는다.
- 오류가 아니면 결과 타입은 `!T` 그대로다. 호스트가 받는 값의 모양은 바뀌지 않는다.

CLI에서만 결과를 검사하는 방법은 쓰지 않았다. 최상위 문과 `main`의 규칙이 갈리고, 임베딩 호스트마다 같은 검사를 써야 한다.

## 구현

`sema.zig` `sema_program`: `main` 호출 결과의 타입이 result면 `_main_res`가 오류일 때 `panic_unwrap_error`를 부르는 분기를 넣는다.
최상위 `expr!`의 panic 분기(`.unwrap_res`에서 `proc.func == null`)와 같은 IR이다.

테스트 `functions/main_func_error_panic.cy` · `main_func_result.cy`.

## 남은 것

- `fn main() -> error`가 돌려준 오류는 여전히 버려진다.
- `fn main() -> str`처럼 힙 값을 돌려주면 Debug · Trace CLI가 `unreleased refcount: 1`을 찍는다(`_main_res`는 deinit을 건너뛴다).
