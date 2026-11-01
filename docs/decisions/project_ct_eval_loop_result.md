# 컴파일 타임 본문의 루프 · switch 결과

작성일 2026-11-01.

## 증상

프로세스의 두 번째 이후 VM에서 인자 없는 `spawn(f, {})`를 컴파일하면 ReleaseSafe에서 "incorrect alignment"로 죽었다.
위치는 `resolve_type_const`(`src/sema_type.zig`)의 `res.asPtr(*cy.Type)`이다. Debug와 첫 VM에서는 드러나지 않았다.

## 원인

`spawn`의 매개변수 타입 `FnTuple[Sig]`(`src/builtins/core.cy`)는 `type ... const:` 본문에서 `for 0..Sig.num_params()`로
필드를 채운 뒤 `meta.new_struct`를 반환한다. 컴파일 타임 평가기(`src/cte.zig` `evalStmt`)는 `for_range_stmt` ·
`switch_stmt` · switch 식의 결과를 `.res = undefined`로 두고 반복 본문이나 맞는 case가 채우기를 기다렸다. 매개변수가
없으면 루프가 0회라 결과가 채워지지 않고, undefined 바이트(0xaa)의 `ret`가 참으로 읽히면 본문이 거기서 "반환"한 것으로
처리되어 쓰레기 `ret_value`가 타입 포인터로 쓰였다. undefined 값을 읽는 것이라 빌드 모드와 메모리 상태에 따라
드러나기도 숨기도 했다.

같은 자리의 두 번째 문제: 루프 안의 `return`이 결과를 채워도 다음 반복이 `evalStmts`의 결과(ret=false)로 덮어써서
반환이 사라지고 루프 뒤 문장이 실행됐다.

## 결정

- 세 곳 모두 결과를 `.{ .ret = false, .ret_value = undefined }`로 시작한다.
- `forRangeInner`는 이미 반환했으면 남은 반복의 본문을 평가하지 않는다. 루프 자체(`forRangeStmt`)는 콜백이 중단을
  알릴 수단이 없어 그대로 돌지만, 반복 변수 선언 외에는 하는 일이 없다.
- 테스트: `src/test/meta/ct_eval_loop.cy`(0회 루프, 루프 안 반환), lib "Spawn without args works in every VM."

## 남은 문제

- `resolve_type_const`는 반환된 타입의 sym 이름 · parent · instance를 type const의 것으로 덮어쓴다. 본문이 `int`처럼
  기존 타입을 그대로 반환하면 그 타입이 오염된다(예: `int`의 메서드를 찾지 못함). 지금 내장 type const는 모두 새 타입을
  만들어 반환하므로 드러나지 않는다. 기존 타입이면 alias로 다루거나 이름을 바꾸지 않아야 한다.
