# 빌림 모델: 지역에 저장된 빌림만 세고, 블록 끝에 풀린다 (2026-11-08)

상태: 구현됨(`F25HASH`). 발견 이슈 F-25(06장 §7.1의 1 · 2 · 3번).

## 배경

sema의 빌림 검사는 세 조각이 서로 맞물리지 않았다.

- `semaBorrow`(명시적 `&x`)는 부모 지역의 `active_borrows`를 올리기만 한다. 내리는 곳은 `popLocals2`의
  `Local.parent_local`인데 이 필드는 `cy.NullId`로 초기화될 뿐 대입되지 않아 죽은 코드였다. 그래서 `peek(&a)`처럼 호출 인자로
  잠깐 빌려도 그 함수 안에서 `a`는 영원히 "빌림 중"이고 뒤의 `a.append(4)`가 `Expected exclusive access.`로 거부됐다(bb1 · bb3).
- `sema_ex_borrow2`(`&&x`와 `&&self` 수신자)는 `active_borrows > 0`만 보고 아무것도 기록하지 않는다. `&&`를 먼저 쥐고 `&`를
  나중에 만들면(`ex := &&a; r := &a[0]; ex.append(..)`) 통과하고, 재할당된 버퍼를 가리키는 `r`이 남는다(b7). 같은 호출의 인자도
  `grow(&&a, &a[0])`은 통과하고 반대 순서 `append_to(&a[2], &&a)`만 거부된다(b9 · b4). `&&`를 둘 쥐는 것도 통과한다.
- 수신자 `&self`의 암시적 빌림(`semaAddressOf`)은 아무것도 세지 않는다.
- 빌림 재대입(`ref = &b`)에는 수명 검사가 없다. `localDecl`의 검사는 `temp` 수명만 본다. 블록 안의 `b`를 밖의 `ref`에 넣으면
  블록 뒤에 `ref`가 죽은 슬롯을 읽고, 그 슬롯을 재사용한 다음 지역의 값이 나온다(b6: 777).

매뉴얼(`docs/docs.md` Borrows · Exclusive borrows)은 "빌림은 값보다 오래 살 수 없다", "`&&`가 살아 있는 동안 다른 빌림은 없다",
"`&`가 살아 있는 동안 `&&`는 없다", "컴파일러가 다른 빌림의 수명을 먼저 끝내려 시도한다(`elem := &a[2]; a << 4`는 OK)"를
약속한다. 마지막 약속(비어휘적 수명, NLL)은 구현이 없다.

## 모델

빌림의 수명은 어휘적(lexical)이다. 지역 변수에 저장된 빌림은 그 지역의 블록이 끝날 때까지 산다. 저장되지 않은 빌림(호출
인자, 식 안의 `&x`, 수신자 빌림)은 그 문장이 끝나면 끝난다.

1. 지역 `L`의 초기값이나 대입값이 빌림(`&T` · `&&T`, 또는 그 둘을 품은 `borrow_only` 값)이고 부모 지역 `P`를 알 수 있으면
   (`ExprResult.recParentLocal()`), `L.parent_local = P`로 묶고 `P`의 계수를 올린다. 공유 빌림은 `active_borrows`, 배타 빌림은
   `active_ex_borrows`. `L`이 블록을 벗어나 `popLocals2`에서 빠질 때 같은 계수를 내린다. 숨은 지역(`for` 루프의 `_iterable` 등)도
   같다. 대입으로 부모가 바뀌면 옛 부모의 계수를 내리고 새 부모의 계수를 올린다.
2. 배타 빌림을 만들 때(`&&x`, `&&self` 수신자) `P.active_borrows > 0`이거나 `P.active_ex_borrows > 0`이면 오류
   `Expected exclusive access. There is another active borrow to \`a\`.`.
3. 공유 빌림을 만들 때(`&x`, `&self` 수신자, 스코프 반환으로 파생된 빌림) `P.active_ex_borrows > 0`이면 오류
   `Cannot borrow \`a\`. There is an active exclusive borrow to it.`.
4. 한 호출의 인자 안에서, 배타 빌림 인자의 부모 `P`가 다른 인자(빌림이든 값이든 부모가 `P`인 식)의 부모와 같으면 순서와 무관하게
   오류 `Cannot pass \`&&a\` with another argument that borrows \`a\`.`. 호출 안에서는 두 인자가 동시에 살아 있기 때문이다.
5. 빌림 지역 `L`에 부모가 `P`인 빌림을 대입할 때 `P`의 블록 깊이가 `L`의 블록 깊이보다 깊으면 오류
   `\`ref\` can not outlive \`b\`.`. 선언(`localDecl`)은 같은 블록이라 항상 통과하고, 기존 `temp` 검사(`Cannot assign to local
   ... shorter lifetime`)는 그대로 둔다.
6. 세지 않는 것(기존과 같음): 구조체 필드 · 컨테이너에 들어간 빌림(`Holder{p=&a}`), 클로저가 잡은 빌림, 스코프 반환이 아닌
   함수 결과. 매뉴얼의 "컴파일러가 다른 빌림의 수명을 먼저 끝낸다"는 구현하지 않는다. `elem := &a[2]; a << 4`는 `elem`의 블록이
   끝날 때까지 오류이며, `elem`을 안쪽 블록에 두면 된다. 매뉴얼을 이 모델로 고친다.

## 기대 동작(scratchpad `f25/`)

| 스크립트 | 수정 전 | 수정 후 |
|---|---|---|
| bb1 `print(peek(&a)); a.append(4)` | 오류(과잉) | 통과 |
| bb3 `if: r := &a` 뒤 `a.append(4)` | 오류(과잉) | 통과 |
| ok1 블록 안 `ex := &&a` 뒤 밖에서 `r := &a` | 오류(과잉) | 통과(그 뒤 `r`이 살아 있는 동안 다시 `&&a`는 오류) |
| bb6 `r := &a; r.len(); a.append(4)` 같은 블록 | 오류 | 오류(어휘적 수명) |
| b2 `elem := &a[2]; a.append(4)` 같은 블록 | 오류 | 오류(매뉴얼 수정) |
| b7 `ex := &&a; r := &a[0]` | 통과 → 해제된 버퍼 읽기 | 오류(규칙 3) |
| exr `ex := &&a; r := &a` | 통과 | 오류(규칙 3) |
| ex2 `ex := &&a; ex2 := &&a` | 통과 | 오류(규칙 2) |
| b9 `grow(&&a, &a[0])` | 통과 → 해제된 버퍼 쓰기 | 오류(규칙 4) |
| b4 `append_to(&a[2], &&a)` | 오류 | 오류(규칙 4) |
| b6 블록 안 `ref = &b` | 통과 → 777 | 오류(규칙 5) |
| bb5 `a.append(4)` 뒤 `r := &a` | 통과 | 통과 |
| forloop `for a |x|: a.append(x)` | 오류 | 오류(`_iterable`이 `a`를 빌림) |

## 구현 메모

- `src/sema.zig`: `Local.active_ex_borrows` · `ex_borrow` 추가. `borrowOwner`(빌림 지역을 따라 소유 지역까지) · `bindBorrowLocal` ·
  `unbindBorrowLocal` · `checkSharedBorrow` · `checkExclusiveBorrow` · `checkBorrowOutlives`. 묶는 곳은 `localDecl`(지역이 살아난 직후),
  `for` 루프의 `_iterable` 숨은 지역, 지역 대입(`.ident` → `.value_local` 경로, 옛 부모 해제 뒤 새 부모 묶기). 푸는 곳은 `popLocals2`와
  `popBlock`(안쪽 블록은 `popLocals2`를 거치지 않고 `varStack`을 자르므로 거기서도 푼다). `semaBorrow`는 더 이상 계수를 올리지 않고
  배타 빌림 검사만, `sema_ex_borrow2`는 두 계수를 본다.
- `src/sema_func.zig`: 수신자 `T → &T` 변환에 배타 빌림 검사, `matchFuncSig`가 인자마다 소유 지역 · 배타 여부를 모아 같은 호출 안 충돌을
  거부(인자는 최대 255개라 고정 배열).
- `src/builtins/core.cy` `Wyhash.final`: `scratch := [16]byte(0)`이 안쪽 `if` 블록에 있고 밖의 `input`이 그것을 빌려 블록 뒤에 썼다
  (규칙 5가 잡은 실제 use-after-scope. 슬롯이 재사용되지 않아 우연히 동작). `input`과 같은 깊이로 올렸다.
- `src/test/core/Array.cy`: `a2_view := a2[0..1]`이 최상위에 살아 있어 뒤의 `a2.remove(1)`이 규칙 2에 걸린다. 블록으로 감쌌다.
- 테스트: behavior `memory/borrow_scope_release.cy`(임시 빌림 뒤 `append`, 블록 안 `&` · `&a[0]` · `&&` 뒤 밖에서 다시, 빌림 복사,
  루프 뒤 `append`, 같은 깊이 재대입), 오류 `memory/borrow_outlive_error.cy` · `borrow_while_exclusive_error.cy` ·
  `exclusive_borrow_twice_error.cy` · `exclusive_borrow_arg_conflict_error.cy` · `receiver_borrow_while_exclusive_error.cy`.

## 남은 것

- 비어휘적 수명(마지막 사용 뒤 빌림 종료)은 sema가 한 번 훑는 구조라 사용 지점을 미리 알 수 없어 보류. 필요해지면 선행 패스로
  각 빌림 지역의 마지막 사용 문장을 구한다.
- 구조체 · 컨테이너에 저장된 빌림, 클로저 캡처는 세지 않는다. `borrow_only` 전파(F-14의 Option)는 타입 수준의 보호만 한다.
- 06장 §7.1의 5번(`f(a, &a)`: +0 전달 값과 같은 지역의 빌림)은 규칙 4의 "값이든" 쪽으로 일부 잡힌다. 값 인자의 부모를 sema가
  주지 않으면 잡지 못한다.
