# 에러 처리: throw/catch 예외에서 `!T` Result 값으로

2026-11-01 작성. 개요는 `cyber_0_3_to_0_4_overview.md`.

## 0.3 상태 (2023-12)

- 예외 모델이었다. `throw error.Oops`가 콜 스택을 되감고 `try:` … `catch err:` 블록이나 `try f() catch 123` 표현식이 잡았다.
  `catch`를 생략한 `try f()`는 값 또는 에러를 돌려줬다. 하위 표현식에서 던진 에러도 잡혔다.
- `error` 값은 심볼을 담는 원시 값이고 `err.sym()`으로 꺼냈다. `Error` trait를 구현한 타입만 던질 수 있었다(enum 에러는 Planned).
- `throws` 지정자. 반환 타입이 없는 함수는 암시적으로 `throws`. 타입이 있으면 `func f() throws, int:`.
  `throws` 없는 함수에서 안 잡은 throw를 컴파일 에러로 내는 검사는 Planned.
- 스택 트레이스는 `errorTrace()` · `errorReport()`. 패닉 `panic(error.x)`은 현재 fiber를 끝내고 다른 fiber는 계속 돌 수 있었다.
- Planned: `caught` 변수, `catch` 매칭, 에러 payload, 에러 set 타입.

## 구간 A에서 바뀐 것 (2024-01 ~ 2024-09)

| 날짜 | 커밋 | 변화 |
|---|---|---|
| 2024-03-08 | `439863b3` `52ffd04c` | 에러 처리 설계 단순화, 표현식 타입 IR에 throws 비트 |
| 2024-03-08 | `d3ce6405` `52338a2f` | Map 인덱스 · 없는 필드 접근은 패닉 |
| 2024-04-15 | `58906d31` | `test.throws` |
| 2024-05-13 | `61db4fd8` | 메시지 있는 panic |
| 2024-07-10 | `8500ea15` | zero-cost 예외, 하위 표현식에서 catch |

`c992b94e` 시점 문서는 여전히 throw/catch였다. 달라진 것은 `throws` 지정자가 반환 타입 접두사 `!`로 바뀐 것이다.
`fn foo() !void:`, `fn result(cond bool) !int:`. "throw할 수 있는 함수는 `!`가 필요하다"는 검사는 여전히 Planned.
`caught` · `catch` 매칭 · payload · error set도 Planned 그대로.

## 구간 B에서 바뀐 것 (2025-11 ~ 2025-12)

`b751ca6c`에서 `throw` · `catch` 키워드가 사라졌다. `try`는 남았다. `!T`가 "throws 지정자"에서 "Result 타입"으로 뜻이 바뀌었다.

## 0.4.2 현재 상태

- `error` 값: `error.Oops` 리터럴, `==` 비교. payload와 error set 타입은 TBD.
- Result `!T`: 에러 또는 payload를 담는 choice 타입. `var res !str = error.Failed`처럼 추론으로 만들고, 함수에서는
  `return error.X`로 에러를 돌려준다. 실패만 알리는 함수는 `!void`.
- 풀기: `f()!`(payload 또는 호출자로 rethrow, main 블록에서는 패닉), `f() !else 0`, `f() !else |err|: ...` 블록.
  Unwrap or guard와 Unwrap block(`try:` … `else |err|:`)은 TBD.
- 패닉: `panic('msg')`. 잡을 수 없고 현재 스레드를 끝낸다. main 스레드가 패닉하면 다른 스레드를 되감지 않고 프로그램이 끝난다.
  자식 스레드 상태 조회는 TBD.
- 스택 트레이스: 문서는 `stack_trace()` · `stack_trace_info()`를 적지만 `src/builtins/core.cy`에 그 이름의 함수가 없다. 문서가 앞선 상태다.
- 테스트: `src/test/control_flow`(try.cy · try_error.cy · try_panic.cy), `src/test/core`(Result.cy · result_infer_return.cy ·
  error_values.cy · panic_panic.cy · *_panic.cy 다수).
- 문서 잔재: "Unwrap or default." 절 끝에 옛 `try:` … `catch err:` 예제가 남아 있다. 현재 문법이 아니다.

## 미완 지점

- Unwrap block과 Unwrap or guard가 TBD다. 스크립트에서 `!` 호출 여러 개를 한 블록으로 묶어 한 곳에서 처리하는 관용구가 없다.
  지금은 호출마다 `!else`를 붙이거나 함수로 감싸 `!`로 올려야 한다.
- `error` payload · error set 타입이 TBD다. 에러에 메시지나 코드를 붙일 수 없어 심볼 이름으로만 구분한다.
- 스택 트레이스 API가 문서와 소스에서 다르다.
- 문서 잔재 정리.

## fork의 결정 · 미결

- 결정: 없음. 아직 손대지 않았다.
- 미결: Unwrap block을 fork가 구현할지. 스크립트 CLI 용도에서 1순위다. error payload는 그 다음.

## 해석

- 예외에서 Result로 간 것은 소유권 모델과 맞물린다. 되감기 중에 소멸자를 올바른 순서로 돌리는 일은 어렵고, 값으로 돌려주면
  제어 흐름이 보이는 자리에서 deinit이 일어난다. Zig의 에러 union과 같은 선택이다.
- A 구간의 `!` 접두사 도입이 B 구간의 Result 타입으로 이어졌다. 표기는 그대로 두고 의미만 "던질 수 있음"에서 "에러일 수 있는 값"으로
  바꿨다. 그래서 0.4 코드의 `-> !int`는 옛 문서를 본 사람에게 익숙해 보이지만 뜻이 다르다.
- `try`가 살아남은 것은 Unwrap block의 자리를 남겨 둔 것으로 보인다. 그 블록이 구현되면 0.3 `try/catch`와 모양이 가까워진다.
