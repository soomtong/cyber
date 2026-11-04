# REPL 맨 표현식의 값 출력

작성일 2026-11-04.

## 배경

`docs/docs.md`의 REPL 절은 `> a * 2` 뒤에 `` `int` 246 ``이 찍히는 것으로 적혀 있고, `cy.cy`의 `REPL.eval_print`도
`res.val_t != TypeVoid`이면 `value_desc`를 출력한다. 그런데 `vm.eval`의 `res_t`는 선언된 `main` 함수의 반환 타입에서만
오고(REPL에는 `main`이 없음), sema의 `semaExprStmt`는 값이 있는 맨 표현식을 "Expected assignment to a variable or
placeholder"로 거절한다. 그래서 REPL에서 `1 + 2` · `x`는 컴파일 오류였다(2026-11-01 메모: "REPL이 값을 바로 보여 주지는
않는다"). `return 1 + 2`도 main 블록에서는 허용되지 않는다.

## 결정

- `persist_main`(REPL) 모드에서만, 최상위 마지막 문이 식문이고 그 식에 값이 있으면(void · never · `!T`가 아니면) 그 값을
  eval 결과로 돌려준다(`CLEvalResult.res` · `res_t`). 값이 없으면 지금처럼 식문 규칙을 따른다(`print(1)`은 void라 결과 없음,
  `!T`는 여전히 오류). 일반 스크립트(`persist_main` 꺼짐)는 바뀌지 않는다.
- 구현은 `localDecl`을 본뜬다(`sema.semaMainResultStmt`): 숨은 지역 `_main_res`를 먼저 예약하고 식을 sema한 뒤 `semaOwn`으로
  소유권을 가져와 지역에 넣고, 호스트 함수 `@mainResult(type_id, addr)`로 VM에 레지스터 위치를 알린다. `persist_main`은
  main 범위 지역을 해제하지 않으므로(`shouldGenMainScopeReleaseOps`) 실행이 끝난 뒤에도 값이 살아 있고, `VM.eval`이 그 레지스터를
  VM 소유 버퍼로 복사해(`Compiler.main_res`, `VM` 구조체는 `vm.h`가 패딩으로 레이아웃을 미러하므로 필드를 더하지 않음) 결과로 돌려준다. 지속 지역(`@trackMainLocal`)과 같은 방식이다.
- 복사본은 다음 eval 시작 때나 VM deinit 때 타입에 맞게 해제한다(`destructValueAt`). panic은 힙을 비우므로 그때는 해제 없이 버린다.
  숨은 지역 자체는 추적하지 않으므로 다음 eval에 복원되지 않는다.
- 결과 식이 지역 하나(`x` · `m`)면 복사하지 않고 그 지역의 주소를 넘긴다(`borrowed`). `Map`처럼 복사할 수 없는 타입도 보여 줄 수 있고,
  지속 지역이 값을 계속 소유하므로 VM은 스냅샷 버퍼만 해제한다. 다른 식은 `semaOwn`으로 소유권을 가져온다(지역의 필드 등은 복사).
- 결과 식이 임시값을 빌리는 경우(`borrow_only` + temp)는 `localDecl`과 같은 이유로 오류다.
- `VM.deinit`은 힙 페이지를 쓸기 전에 결과를 해제한다(버린 main 지역과 힙 객체를 공유하므로 순서가 바뀌면 이중 해제).

## 표시 형식

`debug.write_value_desc`는 docs.md의 REPL 예시대로 `` `타입` 값 ``으로 찍는다(`` `int` 3 ``, `` `str` 'abc' ``). error · symbol은
id 대신 이름(`error.Oops`)을 보인다. `destructValueAt`에 `error` 타입이 빠져 있어
`error.Oops`를 결과로 돌려준 뒤 다음 eval에서 "Unsupported: error"로 죽던 것도 고쳤다.

2026-11-04 값 포매터: 처음에는 Map · struct · 배열이 타입 이름만 보였다. `write_value`가 타입 레이아웃을 따라 값을 걷는다
(core.cy의 `dump_str`를 Zig로 옮긴 셈이지만 REPL 결과는 호스트 쪽 `TypeId` + 레지스터 포인터라 Cyber 코드로는 받을 수 없다).

- 정수 · raw · float은 비트 수대로 읽고, enum은 `.case`, choice는 `.case(payload)`(void payload면 괄호 없음).
- option은 `zero_union`이면 8바이트가 0일 때 `none`, 아니면 tag(i64, 오프셋 0) 뒤 오프셋 8의 payload.
- struct는 `{a=1, b='x'}`(record 리터럴 모양). `Slice`(`ptr` · `_len`) · `Array`(`buf` · `length`) · `Vector`는 `{1, 2, 3}`,
  `Map`은 `base` HashMap의 `meta`(1이면 값 있음) · `_keys` · `vals`를 걸어 `{'a': 1}`(해시 순서). 10개 넘으면 `...N more`.
- `^T`는 `^` 뒤에 가리키는 값, `Ptr[T]`는 주소. 중첩은 깊이 3에서 `...`로 끊어 순환 참조도 짧게 끝난다.
- `[&]T`(`Span`: `base` · `length`) · `PtrSpan`(`ptr` · `length`)은 `{1, 2}`로, `&T` · `&&T`는 `&` 뒤에 가리키는 값으로
  (2026-11-04, 이전에는 빌림 필드가 비어 `{base=, length=3}`로 보였다). 맨 표현식 `&x`는 eval 직후 복사해 바로 보여 주므로
  가능하지만, 빌림 타입 지역은 이월하지 않는다(`project_span_literal_local.md`).
- 결과 해제 `destructValueAt`에 choice가 없어 `Shape.circle(5)` 다음 eval에서 "Unsupported: Shape"로 죽던 것을 tag로 payload를
  해제하게 고쳤다.

lib-test "value_desc renders values from the type layout."가 위 경우를 문자열로 검사한다(누수 검사 allocator).

## 테스트

lib-test "persist_main returns the last top level expression as the eval result.": `1 + 2` → int 3, 문자열 지역을 결과로
돌려준 뒤에도 그 지역을 계속 쓸 수 있음, 값 없는 문은 `TypeVoid`, 결과가 임시 문자열(`s + '!'`)인 경우. 누수 검사 allocator로
VM 소유 복사본이 해제되는지 확인한다.

## 입력 줄 묶기: 속성 줄 (2026-11-04)

REPL 입력은 `cy.cy`의 `REPL.read`가 줄 단위로 모은다. `:`로 끝나는 줄이 블록을 열고 빈 줄이 닫는다. `#[generator]` 같은 속성 줄은
`:`로 끝나지 않아 그 줄만 따로 제출되었고, 파서가 "Expected declaration statement."로 거절해 REPL에서 제너레이터를 선언할 수 없었다.

- `#[`로 시작하는 줄은 버퍼에 두고 들여쓰기를 바꾸지 않은 채 다음 줄을 읽는다. 다음 줄이 `:`로 끝나면 블록이 열리고 빈 줄로 닫히면서
  속성과 함께 제출된다. `#[bind] fn foo() -> int`처럼 한 줄 선언이 뒤따르면 빈 줄 하나가 제출 신호다.
- 버퍼에 줄을 더할 때는 항상 줄바꿈과 들여쓰기를 넣는다(`append_line`). 이전에는 `:`로 끝나는 줄이 줄바꿈 없이 이어져
  `fn f():if true:`처럼 붙었는데 파서가 받아들여서 드러나지 않았을 뿐이다.
- 프롬프트는 버퍼가 비어 있지 않으면 들여쓰기 0에서도 `| `를 보여 이어지는 입력임을 알린다.
- 들여쓰기 0에서 빈 줄이 들어오면 음수로 내려가지 않는다.
- 제너레이터를 `for` 루프로 돌리는 것(`for g() |v|:`)은 `^Generator`에 `iterator`가 없어 별개 과제다. `g().next().?`는 된다.

테스트는 `src/test/modules/cy.cy` 끝의 `REPL.read()` 절. 전역 `[]str`에서 줄을 공급하는 `ReadLineFn`으로 세 경우(단일 줄 ·
중첩 블록 · 속성 줄)의 제출 문자열과 프롬프트 열을 확인한다.
