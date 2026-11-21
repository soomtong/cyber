# `sema.zig` 분할

## 배경

`src/sema.zig`가 15,418줄(약 640 KB)이었다. 저장소 Zig 코드의 5분의 1을 넘고, 둘째로 큰 `parser.zig`의 3배다. 최상위 선언이
593개라 찾기 · 리뷰 · 도구로 읽기가 모두 어려웠다(에디터와 에이전트가 파일을 한 번에 읽지 못한다).
`sema_func.zig` · `sema_type.zig`가 이미 같은 방식으로 떨어져 있었다.

## 결정 (2026-11-22, 사용자 위임)

- 주제별 파일 13개로 나누고 `sema.zig`에는 공용 자료 구조와 진입점만 둔다. 0.4.17에 넣었다.
- 로직은 바꾸지 않는다. 최상위 선언을 통째로 옮기고, 다른 파일의 선언을 부르는 자리에 파일 이름을 붙인다.
- 재수출 별칭(`pub const semaExpr = sema_expr.semaExpr;`)은 두지 않는다. 선언이 사는 파일이 호출 자리에 보이게 하려고
  `src/` 전체의 `sema.name` · `cy.sema.name`을 `sema_x.name`으로 고쳤다. `usingnamespace`는 쓰지 않는다.
- 한 커밋으로 옮긴다. 파일마다 커밋하려던 계획은 버렸다. 기계적 이동이라 중간 단계를 나눠 볼 이유가 없고, 이력은
  `git blame -C -C` · `git log -C --follow`로 따라간다.
- 거대 함수(`sema_expr.semaExprNoCheck` 약 1,090줄, `sema_stmt.semaStmt2` 약 470줄, `sema_assign.semaAssignStmt` 약 290줄,
  `sema_lit.semaFitTarget` 약 280줄)를 쪼개는 일은 하지 않았다. 로직 diff가 생기므로 이동과 섞지 않는다. 하게 되면 큰 `switch`
  갈래를 함수로 뽑는다.

## 파일

| 파일 | 줄 수 | 내용 |
|---|---|---|
| `sema.zig` | 1,500 | `Local` · `Block` · `Proc` · `StmtCtx` · `ExprResult` · `Cstr` · `StackMark` · `FuncSig`, `Sema` 상태, 타입 getter(`getPtrType` 등), `sema_program` |
| `sema_stmt.zig` | 2,160 | `semaStmts` · `semaStmt2`, `break` · `continue` · `return`, 반복문의 이동 검사, `if` · `try` · `begin` · `scope` 문 |
| `sema_expr.zig` | 3,050 | `semaExpr` 계열과 `semaExprNoCheck`, 단항 · 이항 · 비교 · `and` · `or`, 식별자 · `symbol`, 주소 · 역참조 · 복사, 람다 |
| `sema_call.zig` | 1,100 | `semaCallExpr` · `semaCallFuncSym*` · `callSym`, cancel pad, `fiber` · `spawn`, `Slice` 메서드 호출 검사와 버퍼 재사용 |
| `sema_local.zig` | 1,330 | 지역 선언, `pushBlock` · `popBlock` · `pushProc` · `popProc`, 함수 본문, `lookupIdent`, 지역의 소멸 |
| `sema_resolve.zig` | 1,450 | 선언 · 템플릿 · `use` 해소, `ResolveContext`, `ensure_resolved_func`, 호스트 함수, 함수 시그니처, 이름 경로 |
| `sema_borrow.zig` | 580 | 빌림의 주인 · 대출 · 배타/공유 검사 · 수명 검사, `&` · `&&` 식 |
| `sema_move.zig` | 720 | 평가 순서(`seqPush` · `seqFlush`), `semaOwn` · `semaManage` · `semaMove`, 이동 되돌리기, 전역 꺼내기 |
| `sema_assign.zig` | 680 | 대입문, 이동한 지역 되살리기 |
| `sema_access.zig` | 610 | 인덱스 · 슬라이스 · 필드 접근, 부분 이동 경로, `Result` · option 풀기 |
| `sema_init.zig` | 680 | 초기화 리터럴(구조체 · 튜플 · 벡터 · 목록 · 레코드 · choice), `InitBuilder` |
| `sema_switch.zig` | 610 | `switch` 문 · 식 |
| `sema_lit.zig` | 810 | 문자열 · 숫자 리터럴, escape, 리터럴을 목표 타입에 맞추기(`semaFitTarget`), `semaCZero` |
| `sema_hint.zig` | 400 | 오류의 제안: 가까운 이름, 다른 언어의 이름, 옮겨 간 모듈 심볼, 호출 인자 힌트 |

파일끼리는 서로 부른다(순환 import). Zig에서는 문제가 없다.

## 한 방법

scratchpad의 일회용 Python 스크립트로 했다(저장소에는 넣지 않았다).

1. 0열에서 시작하는 `fn` · `const` · `var` · `test`를 최상위 선언으로 보고, 바로 위 주석을 선언에 붙인다.
2. "이 선언부터 저 선언까지는 이 파일" 꼴의 표로 선언마다 갈 파일을 정한다.
3. 토큰 단위로(문자열 · 주석은 건너뛴다) 최상위 선언의 이름이 맨 이름으로 나오고 그 선언이 다른 파일에 있으면 `파일.이름`으로
   고친다. `.` 뒤의 이름, 선언하는 자리, `이름:` 꼴(필드 · 매개변수 · label)은 건드리지 않는다. Zig는 지역이 최상위 선언을 가리는
   것을 금지하므로 맨 이름이 최상위 선언과 같으면 그 선언이다.
4. 다른 파일이 부르게 된 선언에 `pub`을 붙인다(95개). 타입 선언 안의 비공개 메서드 · 상수도 `pub`으로 올린다.
5. 새 파일의 머리에는 `sema.zig` 머리의 별칭(`cy` · `ir` · `bt` · `v` 등) 중 쓰는 것만 옮긴다. `log`의 범위는 `.sema` 그대로다.
6. `src/`의 다른 파일에서 `sema.이름` · `cy.sema.이름`을 고치고 필요한 `const sema_x = cy.sema_x;`를 더한다. 주석 속
   `sema.이름`도 같이 고쳤다.

Zig는 선언되지 않은 이름을 파일 전체에서(부르지 않는 함수에서도) 오류로 잡으므로 3의 누락은 컴파일에서 드러난다. `pub` 누락과
없는 멤버는 분석되는 함수에서만 드러나므로 표에서 계산해 붙였다.

## 확인

- 14단계 검증(`src/tools/verify.sh`: Debug · ReleaseFast · ReleaseSafe · trace 끔 · lib · standalone · wasm · api.json) rc=0.
- `docs/api.json`은 바뀌지 않았다.

## 규칙

- 새 sema 코드는 주제에 맞는 파일에 둔다. `sema.zig`에는 여러 파일이 쓰는 타입과 `Sema` 상태만 더한다.
- 다른 파일의 선언은 `sema_x.name`으로 부른다. 별칭으로 다시 내보내지 않는다.
- 이 문서보다 앞선 결정 문서와 릴리스 노트가 말하는 `sema.zig`의 함수(`sema.semaOwn` 등)는 이제 위 표의 파일에 있다. 옛 문서는
  고치지 않았다. `rg -n "fn semaOwn" src`로 찾는다.
