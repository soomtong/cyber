# `[&]T{...}` 리터럴을 지역에 넣을 때의 IR 순서

작성일 2026-11-04.

## 증상

`sp := [&]int{1, 2, 3}`이 컴파일 중 bc_gen `genAddressOf2`에서 "expected mapping to IR local `1`." panic으로 죽었다.
함수 안 지역, `=` 대입, REPL 맨 표현식도 같은 경로다. `[]int{...}.span()` · `[3]int{...}[0..3]`은 정상이었고,
기존 테스트는 `[&]int{...}`를 `t.eq_span`의 인자(임시)나 오류 테스트에서만 써서 잡히지 않았다.

## 원인

`semaInitLitTarget`은 `assign_to_local`일 때 Span 리터럴을 숨은 지역 `_vec`(`[N]T`)에 넣고 그 빌림으로 Span을 만들며
`has_aux_local`을 켠다. `localDecl`은 자기 `declare_local` 문을 먼저 push한 뒤 우변을 sema하므로 `_vec`의 `declare_local`은
그 뒤에 온다. 그런데 `has_aux_local`이면 `var_start += 1`로 `_vec`를 문 끝 해제에서 빼는데, 같은 `var_start == varStack.len`
비교로 "임시가 없다"고 보고 우변을 자기 `declare_local`의 `init`에 넣었다. bc_gen은 `sp`의 declare를 먼저 생성하며
아직 선언되지 않은 `_vec`의 주소를 잡으려다 죽는다.

## 결정

`localDecl` · `semaMainResultStmt`에서 `has_aux_local`이면 `init_after_aux`를 켜고 `declare_local`(init 없음) 뒤
`set_local`로 넣는다. 임시가 있을 때 쓰던 기존 경로라 bc_gen 변경은 없다. `_vec`는 그대로 블록 끝까지 살아 `sp`가 빌린
버퍼가 유효하다. 테스트 `src/test/types/Span.cy`(지역 · 대입 · 함수 안 · str 원소 · 슬라이스), `behavior_test.zig` 등록.

## REPL(`persist_main`)

`sp := [&]int{1, 2, 3}`을 REPL 맨 위에서 선언하면 `sp`는 이월되지만 숨은 `_vec`는 이름이 없어 track되지 않는다. 다음 eval에서
`sp.base`는 옛 스택 슬롯을 가리켜 쓰레기나 "Retaining untracked heap object"가 난다. `_vec`를 함께 이월하는 것도 생각했지만
이월된 빌림은 지금도 슬롯 배치가 같다는 우연(`r := &x` 뒤 다음 eval의 `r.*`)에 기대므로 그 위에 더 쌓지 않는다.
`localDecl`과 `=` 대입(`isPersistedMainLocal`: main proc · 블록 0의 지역)에서 `has_aux_local`이면 컴파일 오류
"Cannot persist local `sp` that borrows a temporary vector. Use an owned `[]T{...}`."를 낸다. 중첩 블록 안의 지역(`if` 안)은
이월되지 않으므로 허용한다. lib-test "persist_main keeps main locals across evals."에 두 경우를 넣었다.

REPL 값 포매터(`debug.write_value`)는 `[&]T`를 `{base=, length=3}`로 보여 줬다(빌림 필드는 `else => {}`). `Span`(`base` · `length`) ·
`PtrSpan`(`ptr` · `length`)을 원소 목록으로, `&T` · `&&T`는 `^T`처럼 `&` 뒤에 가리키는 값으로 보이게 했다. lib-test
"value_desc renders values from the type layout."에 `[&]int{7, 8}` · `&x`.
