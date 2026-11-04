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
id 대신 이름(`error.Oops`)을 보이고, 렌더링을 모르는 타입(Map · struct · 배열)은 타입 이름만 보인다. 값을 펼쳐 보이려면
일반 값 포매터가 필요한데 `print`도 struct는 타입 이름만 찍으므로 별도 과제다. `destructValueAt`에 `error` 타입이 빠져 있어
`error.Oops`를 결과로 돌려준 뒤 다음 eval에서 "Unsupported: error"로 죽던 것도 고쳤다.

## 테스트

lib-test "persist_main returns the last top level expression as the eval result.": `1 + 2` → int 3, 문자열 지역을 결과로
돌려준 뒤에도 그 지역을 계속 쓸 수 있음, 값 없는 문은 `TypeVoid`, 결과가 임시 문자열(`s + '!'`)인 경우. 누수 검사 allocator로
VM 소유 복사본이 해제되는지 확인한다.
