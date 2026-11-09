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

## 해석의 근거 (upstream 문서 이력)

upstream 문서는 어디에도 이 블록이 컴파일 타임 변환이라고 적지 않았다. 어휘는 오히려 런타임 쪽("catch all errors thrown in a
block")인데, 이력을 보면 옛 모델에서 남은 말이다.

- 2023-03 `f35b7450` "New error handling based on try/catch": 진짜 런타임 예외였다. `throw` 키워드, "bubble up the call stack
  until it is caught by a `try` block", 하위 식에서 던진 오류도 잡힘, 스택 트레이스는 `throw` 지점부터. VM에 `pushTry` · `popTry`
  명령이 있었다.
- 2024-07-10 `8500ea15` "Zero cost exceptions": 구현만 try 스택에서 언와인딩으로 바꿨고 문서는 그대로 throw/catch였다.
- 2025-11-21 `b751ca6c`: 지금의 `!T` 결과 값 모델이 들어오고 "Unwrap or rethrow" · `!else` · Unwrap block(TBD)이 생겼다. Unwrap
  block 문장은 옛 어휘를 그대로 썼고, Unwrap or default 절의 "`try` block catches thrown errors ... `catch err:`" 문단은 옛
  모델에서 지우지 않은 잔재였다(이번에 삭제). `throw` 키워드는 이 시점에 문서에서 사라졌다.

컴파일 타임 변환으로 해석한 근거는 다음 넷이다.

- 현재 모델에서 오류는 `!T` choice 값이고 "Result forces the call site to unwrap"이다. 던져지는 것이 없으니 잡을 것도 없다.
- 현재 VM에 throw · 언와인딩 명령이 없다. 2024-05 옛 VM 삭제와 2024-07 변경 뒤 모두 사라졌고, 남은 `gen_try_stmt`는 주석 처리된
  `catch_op` 뼈대뿐이었다.
- `!`는 이미 sema에서 분기로 펼쳐진다. 블록 안에서 그 분기의 목적지만 바꾸는 것이 가장 작은 구현이다.
- TBD 예제가 모든 호출에 `!`를 붙인다. "블록 안의 모든 실패"를 잡는 설계였다면 `!`를 붙일 이유가 없다.

버린 해석: 블록 안에서 `!`를 안 붙인 `!T` 식 문장도 자동으로 잡는 것. `!`가 전파 지점이라는 규칙이 블록 안에서만 깨지고, 매뉴얼의
`Expected to handle the error case` 오류와 어긋나서 채택하지 않았다.

## 왜 설탕인가, 그래도 넣은 이유

이 블록은 표현력을 더하지 않는다. 다음 둘은 같은 뜻이다.

    try:                              fn body() -> !void:
        a := step1()!                     a := step1()!
        b := step2(a)!                    b := step2(a)!
        finish(b)!                        finish(b)!
    else |err|:                       body() !else |err|:
        log(err)                          log(err)

의미도 "여러 Result 반환 호출을 한 블록으로 감싸고, `!`를 붙인 것 중 처음 실패한 하나의 오류를 한 곳으로 넘긴다"이다. 첫 실패에서
본문이 끊기므로 오류를 누적하는 구조가 아니다. 누적하려면 `!`를 안 붙인 `!T` 값을 그대로 들고 다니면 된다.

JavaScript의 `try/catch`와는 하는 일이 다르다. JS의 `try`는 어느 줄이든 보이지 않게 throw할 수 있고 호출된 함수 깊숙한 곳의
예외도 스택을 풀며 올라오기 때문에 필요한 런타임 표시이고, 버그(`TypeError`)와 예상된 실패를 같은 통로로 잡는다. Cyber는 전파
지점이 `!`로 소스에 드러나고 버그는 panic으로 분리되어 잡을 수 없다. 그래서 이 블록이 잡는 것은 "본문에 적힌 `!`"뿐이며, JS에서
온 독자가 기대할 "블록 안에서 일어난 모든 실패"가 아니다. 매뉴얼에 이 점을 명시했다.

블록이 주는 것은 셋이다.

- 여러 단계의 실패를 한 곳에서 처리. 보조 함수로 뽑지 않아도 되고, 본문이 바깥 지역을 그대로 쓴다(함수로 뽑으면 캡처 제약에 걸린다).
- `!else` 블록의 "끝에서 반드시 빠져나가야 한다" 제약 회피. `!else`는 값을 내는 식이라 그 제약이 필연적이고, `try`는 문이라
  `else` 뒤로 이어진다.
- main 블록에서 `!`가 panic인 상황에서 함수로 감싸지 않고 몇 줄을 묶어 처리할 수단.

넣은 이유는 둘이다. 매뉴얼이 이미 Unwrap block을 약속해 문서와 코드의 간극(F-32)이었다는 것, 그리고 용도가 LLM이 쓰는 에이전트
스크립트라 Python `try/except`와 같은 모양이 있으면 잘못 쓴 코드가 줄 수 있다는 것. 위험은 바로 그 익숙함 때문에 "다 잡아 준다"고
오해하는 것이다. 비용은 가볍다. 새 IR · 바이트코드 · 런타임 오버헤드가 없어, 빼기로 하면 `sema_try_stmt`와 파서 한 곳을 되돌리면
된다. 구문을 유지할지는 사용자 판단에 맡긴다(2026-11-09 논의).

## 같은 의미를 쓰는 언어

- Swift `do { try … } catch`: 던질 수 있는 호출마다 `try`(`!`에 해당)를 붙이고 `do` 블록 안의 그 호출 중 하나가 실패하면 `catch`로
  간다. 구현도 언와인딩이 아니라 오류를 반환 값처럼 돌려준다. 가장 가깝다. 차이는 `throws`가 시그니처에 있고 `try`를 빼면 컴파일
  오류라는 점. Cyber는 `!T` 값을 그냥 들고 있어도 된다.
- Pony `try … else … end`: 부분 함수 호출에 `?`를 붙이고 블록 안의 어느 `?`든 실패하면 `else`로 간다. 모양이 가장 닮았다. Pony의
  오류는 값이 없어 캡처가 없다.
- Rust `try` 블록: `try { step1()?; step2()? }`가 `Result`로 평가되고 블록 안 `?`의 목적지가 함수가 아니라 블록이 된다. 식이고 값을
  내며 nightly 전용. 안정 버전은 클로저 · 보조 함수로 같은 효과를 낸다(위 등가 변환).
- 뿌리는 함수형: Haskell `Either` 모나드의 `do`, F# `result { let! … }` 계산식, Scala `Either`의 `for` 내포. "블록 안의 표시된
  단계 중 첫 실패에서 끊고 그 오류를 블록의 결과로 낸다"는 같은 규칙이다.
- Zig는 반대쪽 선택이다. `try`는 식 단위 전파뿐이고 묶고 싶으면 함수로 뽑는다. "있어도 되고 없어도 되는 설탕"이라는 평가는 이
  분기점과 맞는다.

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
