# 마지막 사용: 암시적 이동 · 갈래 안 이동 · 버퍼 재사용

`docs/study/11-design-principles-review.md` 2.4의 A ~ E를 어떻게 넣을지 정한 문서다. C(빌림의 비어휘적 수명)는
`project_borrow_model.md` "비어휘적 수명"에 있다.

## 결정 (2026-11-21, 사용자)

- A(IR 위 역방향 활성 분석): 따로 만들지 않는다. D · E는 sema가 앞에서부터 이동 상태를 따라가는 것으로 된다(Rust의 이동 검사와
  같은 꼴). 뒤에서 다시 쓰면 오류이므로 "마지막 사용인지"를 미리 알 필요가 없다. 쓸 곳이 생기면 다시 본다.
- B(`Slice` 값 의미): 2.4 B가 말한 틀린 결과(`b := a.size_down(0)` 뒤 `a[0]`)는 `project_slice_append_aliasing.md` 결정 3
  (2026-11-17)이 API를 제자리 `&&` 메서드와 항상 복사하는 `-ed` 메서드로 나누면서 없어졌다(지금 CLI로 확인). 대신 "받는 쪽이
  마지막 사용이면 버퍼를 재사용한다"를 한다. 결과는 같고 복사만 줄어든다. 결정 3은 이 안을 "성능만 바꾸는 최적화"로 버렸는데,
  이번에 사용자가 넣기로 했다.
- D(암시적 이동): 마지막 사용은 `move` 없이 이동한다. `NoCopy` 값을 값으로 넘기는 자리(인자, 초기값, 대입, 필드 · 원소)가
  대상이다. 뒤에서 다시 쓰면 지금처럼 오류이고, 문구가 이동한 자리를 함께 짚는다. 복사 가능한 타입은 그대로 복사한다.
- E(갈래 안 이동): 제안대로. 바깥 블록의 변수를 `if` 갈래 안에서 옮길 수 있고, 옮기지 않은 갈래의 끝에 소멸을 넣는다.
  합류 뒤에는 변수가 죽어 있다(쓰면 오류). 반복문 밖의 변수는 반복 본문에서 옮기지 못한다(다음 반복이 읽는다).

## 순서

1. D: 같은 블록에서 선언한 지역의 암시적 이동. 명시적 `move`와 같은 경로를 탄다(`semaOwn`이 `move x`와 같은 결과를 만든다).
2. E: 갈래 블록을 거친 이동. 갈래마다 이동 상태를 되돌리고 합류에서 합친다.
3. B: 마지막 사용의 버퍼 재사용.

## D 구현 (2026-11-21)

- `sema.semaOwn`(값을 새 주인에게 넘기는 자리 44곳이 모두 거친다)이 복사 전에 `canMoveImplicitly`를 본다. `NoCopy` 값이고
  IR이 지역 읽기 또는 지역에서 시작하는 필드 사슬이면(`@deinit`이 있는 구조체의 필드는 빼고, 부분 이동된 지역 전체는 빼고,
  참조 매개변수 · 빌림 타입은 빼고) `move_expr`의 본문을 뽑은 `semaMove`를 부른다. 그래서 결과가 사용자가 `move x`를 적은 것과
  같고, 그 뒤의 처리(IR `local.moved`, 지역 `.dead`, 블록 끝 소멸 생략)도 같다.
- 이동한 자리는 `Chunk.moved_sites`(지역 id → 노드)에 둔다. id가 새 지역에 주어질 때(`pushLocalVar`) 지운다. 죽은 지역을 읽으면
  'was moved at L:C. Borrow it with `&x` or clone it to use it here.'(`semaLocal`).
- 복사 오류였던 코드만 바뀐다. 테스트 둘을 고쳤다(`array_nocopy_literal_var_error.cy`는 이동 뒤 사용으로, `move_use_after_error.cy`는
  새 문구).

## E 구현 (2026-11-21)

- 블록에 `move_branch` 표지를 둔다. `semaIfBlock2`의 갈래 본문은 `branch`, `semaIfStmt`의 바깥 블록은 `if_outer`(`else` 문장을
  검사하는 동안만 `branch`). 조건식은 바깥 블록에서 평가되므로 조건식 안의 이동은 막힌다.
- `canMoveAcross`: 지금 블록이 `branch`이고, 지역의 블록까지 사이의 블록이 모두 `branch` · `if_outer`면 옮길 수 있다. 반복 본문 ·
  `begin:` 블록 · `if` 언랩 · `switch`는 표지가 없어 막힌다. 갈래 안에서는 지역 전체만 옮긴다(멤버 이동의 상태표는 같은 블록 전제).
- 갈래를 넘는 이동은 `Chunk.branch_moves`에 쌓는다. 갈래가 끝나면(`endIfBranch`) 그 갈래가 옮긴 바깥 지역을 다시 `.local`로
  돌려 다음 갈래가 살아 있는 값으로 검사하고, 끝에 닿는 갈래의 이동만 모아 둔다.
- 합류(`joinBranchMoves`): 모은 지역마다, 끝에 닿으면서 그 지역을 옮기지 않은 갈래의 끝에 소멸을 넣는다. `if_block` 갈래는
  임시 문장 블록에 `semaDestructLocal`을 만들어 본문 끝(바깥으로 가는 `break` 앞)에 잇는다(`spliceBranchEnd`). `else` 문장은 바깥
  블록에서 돌므로 바로 넣는다. `else`가 없으면 마지막 갈래 끝에 `break`를 더해 암시적 `else` 자리로 흘러 들지 않게 하고, 그 자리에
  소멸을 넣는다. 그 뒤 지역을 `.dead`로 둔다. 더 바깥 블록의 지역이면 다시 `branch_moves`에 올려 바깥 `if` 문이 합친다.
- 런타임 플래그가 없다. 어느 경로로 합류해도 지역이 죽어 있으므로 블록 끝 상태가 컴파일 때 정해진다.
- 남은 것: 반복 본문에서 옮긴 바로 뒤 `break` · `return`이 오는 꼴(2.4 E의 허용 조건)은 아직 막혀 있다. `break` 경로와 정상 종료
  경로의 상태가 갈라져 반복문 뒤에도 합류 처리가 필요하다. `switch` · `if` 언랩 · `if` 식의 갈래도 아직이다.
- 테스트: `memory/move_implicit.cy` · `move_branch.cy`(소멸 순서를 로그로 비교) · `move_branch_use_after_error.cy` ·
  `move_loop_error.cy`.

## B 구현 (2026-11-21)

- `sema.reuseSliceBuffer`(`semaCallFuncSymRec` 첫머리): `Slice`의 `appended` · `inserted` · `removed` · `+`이고 수신자가 이
  블록에서 선언한 지역 이름 하나(`Slice` 값 자체, 참조 · 빌림 아님, 빌려진 상태 아님)이면, 지금 문장의 텍스트에 그 이름이 한 번만
  나오고 블록의 뒤 문장이 그 이름을 말하지 않을 때 `_reuse := move xs`, `_reuse.append(v)`, 결과 `move _reuse`로 바꾼다. 제자리
  메서드는 버퍼가 유일하지 않으면 먼저 복사하므로(결정 3) 다른 값과 나눈 버퍼는 그대로다.
- "마지막 사용"은 C와 같은 텍스트 조사(`stmtText` · `countNames` · `lastNamingStmt`)다. 지금 문장과 그 블록은 `Chunk.stmt_ctx`
  (`semaStmts`가 문장마다 둔다)로 안다. 지역이 이 블록 것이어야 하므로 반복문이 사이에 끼지 않는다.
- 빼는 것: `xs = xs.appended(v)`(이름이 두 번, 그리고 이동한 지역에 다시 대입하는 것이 아직 안 된다), REPL 최상위, 멤버
  수신자(`s.xs.appended(v)`).
- 확인: `xs.removed(0)` 결과의 `ptr`이 `xs`의 것과 같다(`memory/slice_reuse_last_use.cy`). 성능 수치는 재지 않았다(복사 하나가
  빠진다).
