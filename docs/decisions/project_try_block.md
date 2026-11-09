# `try` 블록 (2026-11-09, F-32)

## 배경

매뉴얼(`docs/docs.md` Unwrap block)은 `try: … else |err|: …` 블록을 TBD로 적어 두었고, Unwrap or default 절에는 더 오래된
`try:/catch err:` 문단이 남아 있었다. 코드는 파서가 `try:` 본문과 `else err:`(맨 식별자 캡처)를 AST(`tryStmt` · `catchStmt`)로
만들고 sema가 항상 `Unsupported statement: tryStmt`로 거부했다. IR `tryStmt`와 `bc_gen.gen_try_stmt`는 아무도 만들지 않는
죽은 코드였다(03장 §7.2 · §7.3). 스크립트 CLI 용도에서 "여러 `!`를 한 곳에서 처리"하는 수단이 `!else` 블록(끝에서 반드시
빠져나가야 함)뿐이라 로드맵 5번(언어 완성도)의 1순위였다.

## 결정

- 이 언어의 오류는 값이다. `!T`는 `error` 또는 payload를 담는 choice이고, `!`(`unwrap_res`)는 sema가
  `if is_error: return err`(함수) 또는 `panic`(main)으로 펼친다. 런타임에 던지는 동작이 없으므로 `try` 블록도 런타임 catch가 아니라
  컴파일 타임 변환이다. 본문 안의 `!`가 실패하면 함수 반환 · panic 대신 `else` 블록으로 뛴다.
- 영향을 받는 것은 본문의 `!`뿐이다. `!else`, `return error.X`, `!`를 붙이지 않은 `!T` 값, panic은 그대로다. 호출만 하고 `!`를
  안 붙인 결과는 지금처럼 `Expected to handle the error case` 오류다.
- 캡처는 `else |err|:`(타입 `error`, 생략 가능)이고 `!else |err|:` · `if opt |v|:`와 같은 모양이다. 이전 파서의 `else err:` 맨
  식별자 형식은 쓸 수 있던 적이 없으므로 버렸다. `else`가 없으면 `Expected else block.`, 캡처가 식별자가 아니면
  `Expected error variable.`.
- 두 경로 모두 문 다음으로 이어진다. 본문이 끝에 닿으면 `else`를 건너뛰고, `else` 블록은 `!else:` 블록과 달리 끝에 도달해도 된다.
  문 다음의 도달 가능성은 "본문 끝 도달 가능 or `else` 끝 도달 가능"이다(본문에 `!`가 없어 `else`가 죽은 코드여도 보수적으로 도달
  가능으로 본다).
- 본문은 자기 스코프다. 본문의 지역은 밖에서 보이지 않고, `!`가 실패하면 `break`와 같은 규칙으로 `else` 전에 파괴된다.
- 중첩은 안쪽 우선. `else` 블록 안의 `!`는 바깥 `try`로, 바깥이 없으면 함수 반환 · panic으로 간다(Zig의 `catch`와 같다). 람다 ·
  함수는 새 Proc라 상속하지 않고 자기 반환 타입을 따른다.
- 함수 안에서는 `try` 본문의 `!` 때문에 반환 타입이 `!T`일 필요가 없다.

## 구현

sema만 바뀐다. 새 IR · 바이트코드는 없다.

- `sema.Proc.try_ctx: ?TryCtx{body_block, err_local}`. `sema_try_stmt`가 다음으로 낮춘다.

      block outer:
          _try_err: error      -- 숨은 지역, dead 표시(파괴자 없음)
          block body:
              <본문>            -- `!` 실패: _try_err = err; break body
              break outer      -- 본문 끝 도달 가능할 때만
          err := _try_err      -- 캡처가 있을 때
          <else 본문>

  `_try_err`는 `outer` 안 · `body` 밖에 선언해 본문의 파괴자(`semaBreakTo(body)`는 `body.varStart`까지만 파괴)에 살아남게 하고,
  `outer`가 끝나면 varStack에서 빠져 문 단위 `check_locals`(Trace 빌드의 `Expected var_start` 검사)를 통과한다.
- `unwrap_res`의 오류 분기: `proc.try_ctx`가 있으면 `semaUnwrapResultErrorNoCheck` → `set_local(_try_err)` → `semaBreakTo(body)`.
  없으면 이전과 같이 함수면 `return`, main이면 `panic_unwrap_error_fn`.
- 기존 인프라(`semaBreakTo` · IR `.block` · `bc_gen.gen_block`의 `patchBreaks`)만 쓰므로 루프 · `if` · 식 안의 `!`도 같은 점프로
  빠져나가고, 인라인되는 작은 함수(`check_inline_stmts`가 `.block` · `.break_` 허용)에서도 동작한다.
- 파서 `parseTryStmt`: `else` 뒤 `|ident|` 캡처. AST(`TryStmt` · `CatchStmt`)는 그대로라 `cy.cy` 미러는 바뀌지 않는다.
- 삭제: `ir.TryStmt` · `ir.StmtCode.tryStmt` · `bc_gen.gen_try_stmt` · `cgen.zig`의 주석 한 줄.

## 테스트

- `control_flow/try_block.cy`: main · 성공 경로 · 캡처 없음 · 함수(반환 타입 `int`) · 중첩(else 안의 `!`가 바깥으로) · 힙 지역
  파괴 · 루프 안 `!` · `!else` 공존 · 람다 경계 · `while` 조건의 `!` · `!T` 함수에서 try 뒤 rethrow · 양쪽 모두 `return`(Missing
  return 없음) · 인라인될 작은 함수 · 소유 Result 이동 · 캡처 지역 복사.
- `control_flow/try_block_else_error.cy`(`Expected else block.`), `try_block_capture_error.cy`(`Expected error variable.`).

## 남은 것

- `else` 블록이 값을 내는 식 형태(`x := try: … else |e|: …`)는 없다. `!else` 블록의 `break value`(Planned)와 함께 볼 일이다.
- 캡처는 `error` 하나다. error payload · error set(둘 다 TBD)이 생기면 캡처 타입이 넓어진다.
- `try` 본문 안에서 `.?`(옵션 unwrap or panic)는 영향받지 않는다. 옵션은 오류가 아니다.
