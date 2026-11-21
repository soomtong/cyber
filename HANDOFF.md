# HANDOFF (2026-11-21): 0.4.16 릴리스 뒤, 마지막 사용(C · D · E · B)

## 목표

- 0.4.15 릴리스: `Slice` 제자리 API(깨지는 변경), `os` 파일 함수 옛 꼴의 힌트, `cyber-lsp`의 코드 지원 · 린트.
  LSP 확장은 사용자 요청(2026-11-18): "기본으로 탑재할 수 있는 LSP 기능을 목록화하고 구현, 패치 버전 릴리스".
- 릴리스 뒤(2026-11-18): `/code-review` 0.4.14..HEAD의 10건을 모두 고치고, CI 시간을 줄이는 방법을 검토 · 적용
  (사용자: "10번까지 작업을 마치고 ... 전체 CI가 시간이 너무 긴데 줄일 수 있는 방법을 검토", 검토 승인은 위임).
- 2026-11-19: HANDOFF "남은 작업"의 LSP 다음 후보 넷(사용자: "3번 진행해").
- 2026-11-19: LSP 다음 후보 셋(사용자: "LSP 다음 후보(문장 단위 파서 복구, call hierarchy, 범위 포맷) 최적의 결정은 위임한다.
  애매한 경우 상위 에이전트 호출하여 처리 (fable 5.2)").
- 2026-11-20: 남은 LSP 후보인 선언 오류 복구(사용자: "continue", 같은 위임 아래).
- 2026-11-20: 남은 LSP 항목인 토크나이저 `ignoreErrors` 결함(사용자: "continue").
- 2026-11-20: 기술 부채 중 carry 재시도 루프의 IR 되돌리기(사용자가 넷 중에서 고름).
- 2026-11-20: 0.5 범위 결정(사용자: "권고대로 진행해"): `spawn f(args)`는 넣고 `CL_YIELD`는 뺀다.
- 2026-11-20: 남은 사용자 결정(사용자가 질문에 답함): 정렬 안 A는 조사만, core `@eq` choice는 0.5에, CI arm64 macOS Debug step은
  뺌, 표준 오류 어휘(설계 원칙 1.7 A)는 0.5에 호환성 절로(언어 별칭 없음), 1.7 C는 1단계(인스턴스화 경로 오류 문구)만 0.5 전,
  2.7은 권고대로(정체성 문서화, 마지막 사용 분석은 0.5 뒤 첫 과제, 첫 소비자 C). 기록은 각 결정 문서의 "결정(2026-11-20" 줄.
- 2026-11-21(사용자: "continue"): 0.4.16 뒤 남은 첫 과제인 2.7의 C(빌림의 비어휘적 수명).
- 2026-11-21(사용자: "A: 해보자 B: 고치자 D: 마지막 사용은 암시적 move 허용 E: 제안 수용", 뒤 질문에 "B는 마지막 사용이면 버퍼
  재사용", "A 없이 D · E"). 결정 `docs/decisions/project_last_use.md`.

## 현재 브랜치

`master`. 0.4.16 태그 `ca000225`와 `5e5765f9`까지 push돼 있다. 그 뒤 커밋(`7e8c5782` CI 기록, `90b55104` 비어휘적
수명, `6e2a0206` D · E, `4149c6b8` B와 HANDOFF 커밋들)은 push하지 않았다.
PR #8의 PR Build가 실패로 남은 것은 arm64 macOS job이 러너를 받지 못해 15분 뒤 취소된 탓이다(나머지 6개 통과).

## 완료된 작업

- [x] `Slice` 제자리 API와 전역 take-and-restore(`e323ebaf`, `221c9c93`). 결정 `project_slice_append_aliasing.md` 결정 3 · 3-1.
- [x] `os` 파일 함수 옛 꼴의 힌트(`86bb5fc5`): `sema.zig`의 `moved_module_syms` · `call_arg_hints` · `result_type_hints`,
  출처 추적 `producerCall`(지역의 초기식은 `LocalVarS.init_node`). 결정 `project_os_file_text_bytes.md` "오류 문구에 새 이름".
  `Local` 크기 검사가 64비트 72/64, 32비트 48/44로 올랐다.
- [x] LSP 확장(`a72c6c5c`). 기능 표 · 설계 · 확인은 `docs/specs/2026-11-12-lsp-design.md` 12절.
  - 컴파일러: `cl_vm_symbol_hints`(`CLHint` · `CLHintKind`): 추론 타입, `scope` 출구, 쓰지 않는 지역 · `use`(오류 없는 컴파일만).
    `refs.zig` "Hints" 절, `Compiler.ref_locals` · `ref_scope_exits`. capture된 지역의 쓰임도 기록한다(references에도 나옴).
  - 서버: 힌트 진단(`code` `unused-local` · `unused-use` · `scope-exit`), `codeAction` quickfix, `inlayHint`, hover의 `--|` 주석.
    판단 함수는 `src/lsp/assist.zig`(단위 테스트).
  - `project_coroutines.md` "우리 쪽 안"의 안 1 · 3을 구현으로 닫았다.
- [x] LSP 파서 복구(`129dec48`): 구문 오류를 모두 진단한다(`ParseOptions.recover`, `Parser.resumePos`). 구문 오류가 있으면
  sema는 돌지 않는다. outline도 복구해서 파싱한다. 설계 · 확인은 LSP 설계 문서 13절.
- [x] tars-agent: `docs/TODO.md`의 0.4.15 항목에 os 힌트를 적었다(`74e0615`, push 안 함).

- [x] 코드 리뷰 수정 10건(2026-11-18). 목록과 동작 변화는 `docs/releases/0.4.16.md` "0.4.14..0.4.15 코드 리뷰에서 나온 수정".
  - 전역 take-and-restore: 값을 인자 뒤에 꺼낸다(`sema.finishGlobalTake`, `sema_func.matchFuncSig` 끝에서 호출).
    결정 문서 `project_slice_append_aliasing.md` 결정 3-1의 "인자" 항목.
  - 컴파일러가 fix를 오류에 싣는다(`Chunk.reportErrorFix`, `sema.suggestedFix`, `CLReport.has_fix`). LSP는 `data.fix`.
  - 확인: `zig build test` Debug · ReleaseSafe 통과(behavior 558개, LSP 41개).
- [x] CI 시간 줄이기(2026-11-18). 원인 넷과 고친 것은 `project_fork_release_ci.md` "CI 시간 줄이기". CI에서의 수치는 push 뒤에 본다.

## 시도했으나 실패한 접근

- `+=` 경로에서 받는 쪽을 `semaExpr`로 읽으면 복사본에 append한다(이중 해제). 메서드 호출처럼 `semaExprSkipSym`을 써야 한다.
- `xs.append(xs.span())`은 빌림 오류다(안전). 같은 구조체의 두 필드(`self.sets.append(self.ops.span())`)도 `self`를 두 번
  빌린다고 막힌다. 지역 사본(`ops := self.ops`)으로 우회한다.
- zsh는 `$files`를 단어로 나누지 않는다. 여러 파일 치환은 `rg -l0 ... | xargs -0`.

## 남은 작업

- [x] LSP 다음 후보(2026-11-19). 설계 · 확인은 `docs/specs/2026-11-12-lsp-design.md` 12절 "매개변수 이름" · "다른 소스의 노드", 14절.
  - VS Code 테스트에 다섯 항목(`15ce5fa8`): 린트 진단, quick fix, inlay, 문서 주석 hover, 여러 구문 오류. 16개 통과.
  - 이름 노드 `pos()` 어긋남의 원인(`f926cbaf`): cte가 core 템플릿 노드를 main 청크에서 해석해, core의 위치가 main 위치로 기록됐다.
    긴 문서의 주석 위 hover에 `void` 등이 떴다. `refs.rangeOf`가 `node.src() != c.id`를 버린다.
  - 매개변수 이름 inlay(`e609c071`): `CL_HINT_PARAM_NAME`, `Compiler.ref_calls`, 훅은 `sema_call_ir` · `matchFuncSym2`.
  - 선언 rename(`9768a272`): 워크스페이스 전체, 모를 수 있으면 거절(컴파일 오류 · 해석 안 된 식별자 · 표준 모듈 · 모듈 이름).
    `refs.findAllTo`가 모듈 심볼을 맞추지 않게 고쳤다(첫 줄 선언과 모듈 위치 0이 겹침).
  - `/code-review high` 6건 수정(`b99e0bcb`): 오버로드는 함께 rename(spec 14절을 바꿈), 키워드 이름 거절, `declAt`이
    enum · choice · union case를 찾음, `@` 내장 호출(`fiber f(a)`)과 인스턴스마다 다른 오버로드의 호출은 inlay 없음.
    목록은 `docs/releases/0.4.16.md` "rename · 매개변수 이름 inlay의 리뷰 수정".
- [x] CI 시간 확인(2026-11-19): `project_fork_release_ci.md` "CI에서 잰 결과". 러너 사용 137 → 77분, 벽시계는 21분 그대로.
  arm64 macOS Debug 테스트(약 13분, 3코어라 병렬화 효과 없음)가 벽시계를 정한다.
- [x] tars-agent `docs/TODO.md`에 다음 빌드에서 안내 105행을 고칠 항목(`4aae2ec`, tars-agent에 커밋됨).
- [x] `/code-review high` 0.4.15..HEAD의 9건 수정(2026-11-21, 사용자: "결정을 위임합니다 ... 자잘한 거 모두 수정 ... 다음 패치
  버전을 준비"). 목록과 동작 변화는 `docs/releases/0.4.16.md` "0.4.15..HEAD 코드 리뷰에서 나온 수정", 발견 이슈 F-164 ~ F-166.
- [x] 빌림 검사의 남은 구멍 셋(2026-11-21, 사용자: "이 문제는 해결 가능한가? 어떤 방식이 나을까 추천" 뒤 "결정을 위임합니다").
  배타 접근을 쓰는 자리에서 검사한다(깨지는 변경: 순회 중 `&&self` 메서드 호출, 빌려 둔 관리형 값의 대입). 결정
  `docs/decisions/project_borrow_model.md` "쓰는 자리 검사", `docs/releases/0.4.16.md` 같은 이름의 절, 발견 이슈 F-167.
  패치로 낼지 0.5로 미룰지는 사용자가 정한다(커밋 하나라 되돌리기 쉽다).
- [x] 그 뒤 탐침에서 나온 구멍의 조사와 수정(2026-11-21, 사용자: "research to fix them", "continue"). 배타 빌림을 담은 값은
  배타로 세고, 공유 빌림 뒤의 배타 사용과 버퍼 속 빌림 타입을 거절하고, 주인이 여럿인 컨테이너를 센다(깨지는 변경). 결정 문서
  "남은 구멍 조사", 발견 이슈 F-168. 남은 것: `&self` 메서드의 관리형 필드 대입(언어 결정, std 59곳 이상).
  빌림 검사에 남긴 구멍(0.5 후보)은 `docs/decisions/project_borrow_model.md` "남은 것" 끝. tars-agent는 `docs/TODO.md` 31행에
  덧붙였고 커밋하지 않았다.
- [x] 재귀 타입의 버퍼 속 빌림(2026-11-21, 사용자: "continue"): `type Tree: kids []Tree`에 빌림 필드가 있으면 그 필드 자리에서
  거절한다(`Compiler.pending_buffer_args`). 전에는 core의 `PtrSpan[Tree]`를 가리켰다.
- [x] R6(`&T`를 거친 쓰기, 2026-11-21, 깨지는 변경). 사용자: "다음 판에서 오류로 할 필요 없음. 이 버전에서 잡고 넘어간다. 1.0
  전까지 깨지는 것을 허용한다." 공유 빌림을 거친 관리형 값의 대입과 `&&` 생성을 거절한다(`sema.placeThroughShared` ·
  `checkNoWriteThroughShared`). std의 `diag &Diag`는 `&&Diag`, 상태를 바꾸는 메서드는 `&&` 수신자, `Scope`의 `start` · `join` ·
  `abort`도 `&&`. 결정 `project_borrow_model.md` "R6 구현", `docs/releases/0.4.16.md` "공유 빌림을 거친 쓰기", F-169. tars-agent는
  `docs/TODO.md` 31행에 덧붙였고 커밋하지 않았다.

- [x] 0.4.15 릴리스(2026-11-18): 태그 `0.4.15` → `93a9ca4f`, `build-969-93a9ca4`, Latest, 에셋 15개(CI). `install.sh 0.4.15`를 임시
  경로에 설치해 버전 · 스크립트 · `cyber-lsp`의 여러 구문 오류 진단을 확인했다. `/usr/local`의 설치는 사용자가 다시 한다.
- [ ] tars-agent 의존을 0.4.16으로 올리기는 tars-agent 쪽 일(TODO 항목).
- [x] LSP 범위 포맷 · call hierarchy · 본문 안 문장 단위 복구(2026-11-19). 설계 · 확인은 LSP 설계 문서 15 · 16절.
  - 범위 포맷: `assist.lineEdits`(포맷터는 줄을 합치거나 나누지 않고 빈 줄만 줄인다).
  - call hierarchy: 서버만(`onPrepareCallHierarchy` · `onIncomingCalls` · `onOutgoingCalls`), 해석 기록과 outline으로.
  - 문장 단위 복구: `compiler.BodyRecover`가 실패한 문장을 건너뛰고 본문을 다시 검사(최대 10번), `sema.semaStmt`가 실패한 문장을
    기록. 문장마다 되돌리는 방식은 fable 검토로 기각(16절). 겹치는 리포트는 `Compiler.dropRepeatedReports`.
  - VS Code 테스트 18개 통과(두 항목 추가).
- [x] LSP 선언 오류 복구(2026-11-20, LSP 설계 문서 17절). fable 검토로 안 A: 서로 관계없는 선언의 오류를 모두 보고하고, 선언에
  오류가 있으면 본문은 검사하지 않는다. `Compiler.failed_decls` · `sema.declFailed` · `markDeclFailed`, `resolveChunkSyms`의
  `recoverableDecl`. 최상위 컴파일 타임 문장 · `use` · 타입 상수 · 템플릿 머리는 그대로 컴파일을 끝낸다.
- [x] 17절의 둘째 단계(템플릿 머리 · `use`) 검토(2026-11-20): 하지 않기로 했다(이득이 없거나 위험이 큼, 17절 끝). 그 길에
  `use os.read_file`의 'TODO' 문구를 고쳤다.
- [x] 토크나이저 `ignoreErrors` 결함(2026-11-20, LSP 설계 문서 14절 끝): 닫히지 않은 문자열은 줄 끝 · 소스 끝까지 `err` 토큰 하나.
  raw 문자열도 같다. 쓰지 않던 `tokenize*RawString`을 지웠다. `tokenizer.zig` · `tokenizer.cy` 둘 다, 테스트도 둘 다.
- [x] carry 재시도 루프(2026-11-20): `compiler.semaCarriedFuncs`가 소스를 해석하기 전에 carry 본문을 검사한다. 실패하면
  인스턴스를 failed로 두고 `RecoverMarks`(`StackMark`가 `ir.func_blocks`까지 되돌림)로 되돌린 뒤 남은 본문을 다시 검사(최대 8번).
  소스를 다시 컴파일하던 `compile`의 루프 · `carried_failed`를 지웠다. lib 테스트 `A carried template instance that does not
  compile is dropped ...`(전에는 로더 5번, 이제 1번). `cyber.h` 로더 주석 · docs.md 세션 절 · F-120에 적음.
- [x] `spawn f(args)`(2026-11-20, 깨지는 변경): `spawn`은 키워드, `sema.semaSpawnExpr`가 core `@spawn(f, {args})`로 푼다.
  `spawn` · `fiber`는 첫 호출까지만 받는다(`Parser.parseEntryCall`, `stop_after_call`). 결정은 `project_coroutines.md` 끝 절,
  사용자 문구는 `docs/releases/0.4.16.md` "`spawn f(args)`: 스레드 생성도 키워드 + 호출식". tars-agent에는 옛 꼴이 `spike/s1`에만 있어 쓰지 않았다.
- [x] 결정 기록 · CI arm64 Debug step 뺌(`1bc5426e`, 벽시계는 다음 push의 run에서 본다).
- [x] core `@eq`의 choice(`064afc9f`): case 비교 뒤 payload `==`. `?json.Value == none`이 된다.
- [x] 정렬 안 A 조사(`9fe2d097`, `project_sort_closures.md` "안 A 조사"): 스택 이동은 F-136으로 이미 안전.
- [x] 그 조사에서 찾은 F-162 · F-163(`17bf7879`): `OpaqueFunc`를 빌림 컨테이너로, 람다 · 구조체 · 튜플 리터럴에 주인
  (`sema.shorterOwner`), 빌림 타입 전역 거절, 빌림 지역 재빌림은 자기 기록을 뺌(`sema.otherBorrows`), pinned closure 해제
  (`@freePinnedClosure`).
- [x] 1.7 C 1단계(`80762140`): 'While specializing `inner[int]` here:' 주석. `Instance.site` · `site_parent`,
  `Compiler.compile_seq`(세션의 앞 컴파일 노드를 쓰지 않게), `Chunk.appendInstanceTrace`, `sema.bodyInstance`.
- [x] 1.7 A 표준 OS 오류 이름(결정 `project_os_error_names.md`): `os.from_errno` · `from_win32_error` · `last_error` ·
  `last_os_error`. 깨지는 변경(옛 이름 표는 `docs/releases/0.4.16.md`). Windows 매핑은 실행 확인 못 함.
- [x] 0.4.16 릴리스(2026-11-21, 사용자: "release patch version 0.4.16"): 0.5로 모으던 변경을 수정 버전으로 냈다. 태그 `0.4.16` →
  `ca000225`, `build-1010-ca00022`, Latest, 에셋 15개. `install.sh 0.4.16`을 임시 경로에 설치해 버전 · 새 규칙의 오류 ·
  `&&diag` · `spawn f(args)` · 예제 · `cyber-lsp initialize`를 확인했다. `/usr/local`의 설치는 사용자가 다시 한다.
  master run이 Linux · Windows에서 두 번 실패해 고쳤다(`39f0af08`, `0b8115fe`). 경위와 push 전 Linux 확인법은
  `project_fork_release_ci.md` "0.4.16".
- [x] CI 벽시계 확인(`7e8c5782`): arm64 Debug step을 뺀 뒤 21분 → 13.5~14.5분. `project_fork_release_ci.md`.
- [x] 빌림의 비어휘적 수명(`90b55104`, 2.7의 C). 지역의 빌림이 같은 블록에서 이름이 마지막으로 나오는 문장 뒤에 끝난다.
  `sema.endBorrowsAfter` · `lastNamingStmt` · `namesWord`(소스 텍스트로 언급을 찾음), 안전망 `Local.borrow_ended` ·
  `reportBorrowEnded`. 소멸자 있는 지역 · REPL 최상위는 제외. 결정 `project_borrow_model.md` "비어휘적 수명", 매뉴얼 Borrows 절,
  `unreleased.md`, 테스트 `memory/borrow_last_use*.cy`. 14단계 검증 rc=0.
- [x] D(`6e2a0206`): `NoCopy` 값을 지역 · 멤버 경로에서 읽어 복사할 자리면 `move`처럼 이동(`sema.semaOwn` →
  `canMoveImplicitly` → `semaMove`). 이동 뒤 사용은 'was moved at L:C'(`Chunk.moved_sites`).
- [x] E(`6e2a0206`): `if` 갈래가 바깥 지역을 옮김. `Block.move_branch` · `canMoveAcross` · `Chunk.branch_moves` ·
  `endIfBranch` · `joinBranchMoves` · `spliceBranchEnd`. 반복 본문 밖 지역은 'Cannot move `a` here: ...'.
- [x] B(`4149c6b8`): `appended` · `inserted` · `removed` · `+`가 마지막 사용에서 버퍼 재사용(`sema.reuseSliceBuffer`,
  `Chunk.stmt_ctx`). 원래의 B 버그는 slice 결정 3에서 이미 없어졌다. A(IR 활성 분석)는 만들지 않기로 했다.
  - 남은 것(결정 문서 "E 구현" · "B 구현" 끝): 반복 본문에서 옮긴 뒤 `break` · `return`, `switch` · `if` 언랩 · `if` 식 갈래의 이동,
    이동한 지역에 다시 대입(`xs = xs.appended(v)`도 이것 때문에 재사용 안 됨), 멤버 수신자 재사용. 성능 수치는 재지 않았다.
  - tars-agent 프롬프트 `prompt/cyber-subset.md` · `.en.md` 168 · 347행이 "`move a`로 넘긴다", "Cannot copy ... `move`"라고 안내한다.
    이제 `move` 없이 이동한다. 그 저장소에는 쓰지 않았다(다른 세션의 미추적 파일 `spike/s2/out/0.4.16/`이 있음).
- [x] tars-agent 요청 `docs/requests/cyber-0.4.16-messages-from-codeact-round.md`의 문구 넷(2026-11-21, 사용자: "update tars-agent
  docs. and check ..."): Python 슬라이스, `|_|` 반복(위치도), 버린 값의 `_ = <문장>`, 모듈의 가까운 이름 · `basename` 등.
  `agent-guide.md`의 `int(z)` 예 · `Array` 이동 · 오류 표. tars-agent에는 요청서 회신 절과 TODO 항목(다음 빌드로 올릴 때 프롬프트
  168 · 347행)을 써서 커밋했다(`8bf3e89`, push 안 함). 프롬프트 본문은 0.4.16 고정이라 지금 고치지 않았다.
- [ ] 기술 부채(급하지 않음): `@destruct_span` 취소 keep 지점(쓰게 되면), `Scope.run`의 바퀴당 `waiting()` 질의(준비 큐 ·
  futex식 대기 표, fiber 수 비용이 문제가 되면), 취소 불변식 panic(닿는 경로 없음). 기록은 `project_coroutines.md`.

## 핵심 파일

- `src/refs.zig` "Hints" 절, `src/lsp/server.zig` `hintDiagnostics` · `onCodeAction` · `onInlayHint`, `src/lsp/assist.zig`.
- `src/compiler.zig` `semaCarriedFuncs` · `carryFailedCompile`(실패 뒤 carry), `BodyRecover` · `semaChunkFuncsRecover` · `resolveChunkSyms` · `recoverableDecl`, `src/sema.zig` `semaStmts` ·
  `semaStmt` · `declFailed`(복구 경로).
- `src/builtins/core.cy` `Slice` 절(`reserve_own` · `clone_copy` · `append` · `appended` 등, `rg -n "fn \(&&?Slice\[\]\)"`).
- `src/sema.zig` `semaOpAssignMethod` · `checkSliceInPlaceResult` · `checkDroppedSliceResult`.
- `src/parser.zig` `isForeignDeclKeyword` · `reportForeignDeclError` · `reportTypedDeclError`.
- `src/std/os.cy` `read_file` · `read_file_bytes` · `write_file` · `write_file_bytes`.
- `docs/releases/0.4.16.md`, `docs/releases/unreleased.md`.
- `docs/decisions/project_fork_release_ci.md`(러너 미배정 · 재태깅 · 로컬 arm64 빌드 절차).

## 다음 에이전트에게

1. 0.4.16이 마지막 릴리스다. 0.5 범위로 정했던 것은 모두 여기에 들어갔다. 그 뒤 변경은 `unreleased.md`.
2. 다음 릴리스도 사용자가 지시할 때만. master를 먼저 push하고 그 run이 끝난 뒤 태그를 push한다.
3. tars-agent 저장소에는 쓰기 전에 `git status`를 본다(다른 세션이 동시에 일한다). 회신 절 외에는 쓰지 않는다.

## 알려진 한계

- 양보만 하는 fiber와 Future를 기다리는 fiber가 섞이면 `Scope.run`이 쉬지 않고 돈다(설계대로).
- 실행으로 확인하지 못한 경로: Windows `FallbackReadLine`. 시작한 자식이 멈춘 동안 부모 스택이 옮겨지는 경우는 지금 구조에서
  생기지 않음을 확인했다(`project_coroutines.md` 끝 절).
- 변수에 담은 `FnTuple`로는 빌림을 넘기지 못한다(사용자 코드에 `FnTuple`이 나오지 않아 하지 않기로 함).
- 최상위 `#x := ...` 컴파일 타임 변수는 뒤의 최상위 실행문에서 못 쓴다(선언 단계에서만 평가).
- 보간 안의 보간은 지원하지 않는다(토크나이저 상태가 한 단계). 원인을 말하는 오류만 낸다.
- `json` 기본 파싱은 17자리 넘는 소수를 `float`으로 근사한다(`exact`면 원문). `json.to`는 struct 필드 기본값을 쓰지 않는다.
- `regex`: look-around · backreference · `(?-u)` · `(?R)` · 일반 범주와 스크립트 밖의 `\p{..}` 속성(`Emoji` 등)은 받지 않는다(컴파일
  오류). 반복자 없이 슬라이스를 돌려주고, 치환에 함수를 받지 않는다.
- `peg`: 시간 보장이 없다(역추적). 함수를 부르는 캡처 · 오류 표지와 복구 · cut · left recursion · 대소문자 무시 리터럴 · Unicode
  속성 클래스가 없다. `find`는 위치마다 다시 맞춰 본다(첫 글자 건너뛰기 없음).
- `time`: 윤초 · 로캘이 없다. 오프셋은 분 단위(±23:59, DB의 초 단위 LMT는 반올림). `DateTime`에 순서 연산자가 없다
  (`a.time() < b.time()`). `parse_format`은 `%Z` · `%U` · `%W` · `%c`를 받지 않고 `%f`가 숫자를 끝까지 먹는다.
  시간대 DB를 내장하지 않아 Windows · wasm에서는 `time.zone(name)` · `time.local()`이 `error.NotFound`다(`UTC`와
  `zone_from_tzif` · `zone_from_posix`는 된다). RFC 9557은 `format_zoned` · `parse_zoned`만 다룬다(`format` · `parse`는 RFC 3339).
  `format_zoned`는 `time.zone` · `time.local`로 읽은 zone만 괄호를 붙인다(데이터로 만든 zone은 오프셋만). 같은 바이트라도 DB에서
  읽은 zone과 `zone_from_tzif`의 zone은 `==`에서 다르다. `parse_format`에서 `%j`는 `%m` · `%d` · `%e` · `%b`와 함께 쓸 수 없다.
  모든 `DateTime`이 `Zone` 값을 통째로 품는다(30칸 가까이). `==` 오버로드가 없어 공유 참조로 못 줄였다.
- 하위 블록에서는 `move` · `meta.consume`을 못 쓴다(`else` 갈래의 consume은 뒤까지 죽은 상태로 남는다). 컴파일 타임
  `#for xs |v|`(EvalBuffer 반복)는 `#case` 바로 아래에서 `for_iter_stmt` 오류라 `#for 0..n |i|`로 돈다.
- VM 생성(`cl_vm_init*`)과 값 생성 C API의 할당 실패는 아직 `fatal`(실패를 알릴 시그니처를 먼저 정해야 함).
- 신뢰하지 않는 스크립트의 C FFI 차단은 미결정(`deny_raw_ptrs` · `deny_spawn`은 있음).
- 전체 발견 이슈 표: `docs/study/10-findings-register.md`(F-169까지, 열린 것 없음).

## 작업 방식

- 순서: scratchpad 재현 → 수정 → Debug CLI 확인(`zig build cli -p <scratchpad>/dbg`) → 회귀 테스트 → 문서 → 13단계 검증 → 커밋.
- 14단계 검증(14단계는 `docs/api.json` 낡음 검사): `src/tools/verify.sh [로그 디렉터리]`(`task verify`, 약 10분, 기본 로그 `zig-out/verify/`). `run_in_background`로
  돌리고 완료 알림을 기다린 뒤 `rc=`를 확인하고 커밋한다(`tail`만 보지 않는다). 도는 동안 `src/`를 고치지 않는다(고쳤으면
  죽이고 다시). 다른 작업을 이어 가려면 git worktree에서 돌리고 끝나면 `git worktree remove`.
- 커밋은 의미 있는 diff면 묻지 않고 한다. push · 태그 · 릴리스는 사용자 지시 때만. `gh`는 `-R soomtong/cyber`.
- 사용자에게 보이는 변경(버그 · 언어 규칙 · 한계)은 같은 커밋에서 `unreleased.md`에, 언어 규칙이면 `docs/docs.md`에도 적는다.
  설계 결정은 `docs/decisions/`, 발견 이슈는 findings register에. 문서는 한국어, `**` 금지. 전체 `zig fmt` 금지(바꾼 줄만).

## 릴리스

1. 버전 세 곳: `build.zig` · `build.zig.zon` · `install.sh`.
2. `unreleased.md` → `docs/releases/<v>.md`(요약 · 호환성 절을 새로 쓴다), `unreleased.md`는 머리말만 남긴다.
3. 14단계 검증 rc=0 → master push → 그 Latest Build가 끝난 뒤 annotated 태그 push(같이 올리면 `concurrency: latest`로 한쪽이 취소된다).
4. 릴리스 run 확인(`gh run list`), `gh release edit <v> --notes-file docs/releases/<v>.md --latest`. Latest는 `gh release list`로 본다.
5. `install.sh <v>`를 scratchpad에 설치해 버전 문자열 · `cyber-lsp initialize` · 예제 하나 확인.
6. 노트에 태그 커밋 · 빌드 번호를 적어 커밋하고 `docs/decisions/project_fork_release_ci.md`에도 기록.
- 재태깅 · macOS arm64 로컬 자산 업로드 절차는 `project_fork_release_ci.md`.

## 테스트 요령

- behavior 테스트는 `src/behavior_test.zig`에 `run.case`로 등록해야 돈다. 파일 끝에 `--cytest: pass` 꼬리가 있어야 한다.
  새 파일을 만들기 전에 같은 이름이 있는지 본다(덮어쓴 적 있음).
- 오류 테스트(`--cytest: error`): 기대 출력은 Debug CLI 출력에서 경로를 `@MainPath()`로 바꿔 만들고, 마지막 `--` 줄 뒤 줄바꿈
  없이 끝낸다(`perl -pi -e 'chomp if eof'`). Debug CLI는 스택 트레이스를 섞으니 `rg -A4 "^(Compile|Parse)Error"`로 문구만 뽑는다.
- lib 테스트 하나: `zig build lib-test -Dtest-filter="lib_test.await"`(필터는 하나만). 로그 끝 `failed command:`는 오류 테스트
  stderr 탓이니 종료 코드로 판정한다.
- sema를 건드리면 lib 테스트도 돌린다(`cy` 모듈 · `deny_raw_ptrs` 경로가 다르게 탄다).
- `spawn`을 쓰는 behavior 테스트는 wasm에서 뺀다(`if (!is_wasm)`).
- ReleaseSafe는 해제된 메모리를 `0xaa`로 채운다. Debug · Fast만 통과한 것은 통과가 아니다.
- 끝나지 않는 테스트는 결함일 수 있다. 탐침은 백그라운드로 띄우고 몇 초 뒤 `pgrep`으로 판정한다(포그라운드 `sleep`은 막혀 있다).
- 취소 탐침은 정상 경로의 `@deinit` 횟수와 비교한다(목록 리터럴은 임시 복사본을 만들고 버린다).
- TOON fixture 갱신은 `src/test/assets/toon-spec/README.md`.
- regex fixture 갱신은 `src/test/assets/regex-spec/README.md`(`convert.py`). Unicode 표는 UCD 파일을 받아
  `cyber src/tools/gen_regex_unicode.cy <ucd 폴더> src/std/regex_unicode.zig`. `regex.cy`의 문법을 고치면 ripgrep 차분 퍼징을
  다시 돌린다: `python3 src/tools/regex_fuzz_gen.py <seed> 5000 <out.json>` 뒤 `cyber src/tools/regex_fuzz_run.cy <out.json>`.
- `peg.cy`의 문법을 고치면 LPeg 차분 퍼징을 다시 돌린다(`lua`에 `lpeg` · `re`가 있어야 한다):
  `python3 src/tools/peg_fuzz_gen.py <seed> 4000 <out.json>` 뒤 `cyber src/tools/peg_fuzz_run.cy <out.json>`. `0 differ`여야 한다
  (`rejected only here`는 LPeg가 보지 않는 닿지 않는 규칙 · 대안의 검사).
- `time.cy`의 달력 · 형식을 고치면 Python 차분 시험을 다시 돌린다: `python3 src/tools/time_fuzz_gen.py <seed> 15000 <out.json>` 뒤
  `cyber src/tools/time_fuzz_run.cy <out.json>`. `0 differ`여야 한다.
  시간대 쪽을 고치면 `time_zone_fuzz_gen.py <seed> 12000 <out.json>` · `time_zone_fuzz_run.cy`도(둘 다 시스템 zoneinfo를 읽는다).
  TZif fixture 갱신은 `src/test/assets/time-zone/README.md`.
- 네이티브 함수가 `str` 인자를 받으면 `defer t.heap.destructStr(&s)`로 놓아야 한다(안 하면 슬라이스의 원본 버퍼가 샌다).
- 실패한 `t.eq`를 한 번에 다 보려면 테스트 파일의 `t.eq(`를 줄 번호를 받는 지역 함수로 바꾼 사본을 돌린다(첫 실패에서 멈추지 않게).

## 구현 함정

- wasm32: 값 칸은 8바이트, 포인터는 4바이트. 칸의 위 32비트는 쓰레기라 포인터로 쓸 때는 아래 절반만 본다(F-140 · F-143).
  구조체는 4바이트 필드 둘을 한 칸에 담는다. 칸을 통째로 쓰면 옆 필드가 지워진다(F-156, `PtrSlot.ptr_hi`).
  native에서 스택 이동은 `alloc.resize`가 제자리로 끝나 안 일어날 때가 많다. 이동 경로는 wasm 단계가 더 잘 잡는다.
  스크립트 하나를 wasm에서 돌리려면 `zig build cli -Dtarget=wasm32-wasi -Doptimize=ReleaseSafe -p <dir>` 뒤 스크립트가 있는 곳에서
  `wasmtime run --dir=.::/ --dir=<repo>/zig-out/bin::/zig-out/bin <dir>/bin/cyber.wasm x.cy`.
  `@intFromPtr`는 `usize`라 `u64`에 넣을 때 `@as(u64, ...)`.
- `Heap` · `Pool` 등 C 미러 구조체(`vm.h`)가 있는 타입에 필드를 더하면 오프셋 검사에 걸린다. 끝(`c` 뒤)에 두거나 전역으로 뺀다.
- opcode 추가: `vm.h` enum과 `vm.c` `JENTRY` 표 같은 위치, `bytecode.zig`의 enum · 길이 · 덤프 · opcode 수 테스트.
- 새 AST 노드: `ast.zig`의 enum · 타입 맵 · `src` · `pos` · `end` 다섯 곳 + 노드 수 테스트 + `cy.cy` 미러 + tree-sitter 코퍼스.
- IR 지역 id는 선언 문장 순서와 같아야 한다(`Expected next IR local to be N, got M.`). 람다 인자는 `pushProc`이 먼저.
- 템플릿 타입의 메서드는 쓰지 않아도 인스턴스마다 본문이 검사되는 경우가 있다(core 타입에서 겪음). 사용자 템플릿 타입의 쓰지 않는
  메서드는 검사되지 않았다(2026-11-15 `Box[Array[int]]`로 확인). 원소 타입에 따라 안 되는 메서드는 `#[cond=...]`로 막는다.
  호출 자리마다 달라지는 검사는 core의 `meta.error`가 아니라 sema 호출 경로에 둔다.
- 검사를 엄격히 하는 수정은 core.cy · std의 숨은 불일치를 드러낸다. 전체 테스트로 확인한다.
- core.cy는 `zig-out/bin/src/`에서 읽힌다. 고친 뒤 `zig build cli`를 다시 한다.
- `@ptr_init` 같은 `@` 함수는 builtin 모듈(`markBuiltinModule`, std `json` · `toon` 포함)만 쓴다. 구조체를 필드별로 만들 때는
  `var res T = undef` + `@ptr_init(*meta.access(res, name), v)`, `#for`로 펼친 본문은 `begin:` 블록으로 감싸 지역 이름이 겹치지 않게.
- behavior 러너에는 파일 필터가 없다(`-Dtest-filter`는 zig test 이름). 파일 하나는 Debug CLI로 돌린다(Debug CLI도 끝에 누수를 보고한다).
- 누수는 테스트 실패다(2026-11-15): behavior 케이스마다 VM이 자기 `SafeAllocator`를 써서 `leaked N blocks in <경로>`로 실패하고
  (`src/test/setup.zig` `VMrunner`), 커스텀 러너(`src/test_runner.zig`)는 테스트 함수마다 allocator를 검사한다.
- `src/parser.zig`에서 지역 이름 `t`는 모듈 수준 `t`를 가려 컴파일 오류다(`tok` · `ty`로 쓴다).
- LSP 탐침: scratchpad에 JSON-RPC 클라이언트(파이썬, `Content-Length` 프레이밍)를 두고 서버에 직접 보낸다. 저장소 `.cy`를 다 열어 진단을 모으면 오탐이 드러난다.
- 언어 메모: `Slice`의 `append` 등은 제자리(`xs.append(v)`), 새 목록은 `appended` · `+`. 값을 바꾸는 메서드는 `fn (&&T)`, 출력 매개변수는 `out &&T`(호출은 `&&x`), `^T`로 `&&` 메서드를 부를 때는 `r.*.m()`. `&T`로는 관리형이 아닌 필드만 쓴다. 비트 OR은 `||`, AND는 `&&`. 전역은 `global g int = 5`. `var x = 0`은 문법 오류(`x := 0`). `os.parseArgs`는
  `-name=value`만 받는다. `Map`의 개수는 `size()`. `out.* += fut.await()`는 await 전에 `out.*`를 읽는다.
- `.cy`를 넓게 고치는 규칙 변경은 변경 전 CLI(worktree에서 `zig build cli -p <dir>`)와 새 CLI로 저장소의 `.cy`를 모두 돌려 첫 오류 줄 · 종료 코드가 달라진 파일만 본다(behavior 러너는 샤드마다 첫 실패에서 멈춘다).
- 벤치는 다른 프로세스가 CPU를 쓰는지 먼저 본다(tars-linux `services_test`, 종료 금지). 테스트와 동시에 돌리지 않는다.

## 참고 위치

- 동시성 전체(제너레이터 · fiber · 단계 1 · 3 · 취소 · `scope` · `@deinit` 취소): `docs/decisions/project_coroutines.md`.
- JSON · TOON: `project_std_json_toon.md`. 정규식: `project_std_regex.md`. PEG: `project_std_peg.md`. 시간: `project_std_time.md`. 정렬 클로저: `project_sort_closures.md`.
- 임베딩 · tars-agent: `project_embedding_agent_loop.md` · `project_tars_agent_runtime_review.md`, C API `src/include/cyber.h`.
- 컴파일러 한계: `project_compiler_limits.md`. 평가 순서: `project_eval_order.md`. 스택 포인터 보정: `project_stack_ptr_patch.md`.
- 방향(네이티브 · LLVM · JIT는 범위 밖): `project_direction.md`.
- tars-agent는 다른 세션이 동시에 고치고 있을 수 있다. 그 저장소에 쓰기 전에 `git status`를 보고,
  쓸지는 사용자에게 맡긴다.
