# HANDOFF (2026-11-25): Julia 검토의 남은 결정(B의 2 · C · D · F) 구현

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
- 2026-11-21(사용자: `/code-review high from 0.4.16` 뒤 "step by step 수정해주세요. 결정을 위임합니다. 서브 에이전트(최대 3개)를
  사용할 수 있으니 병렬 실행 가능한 업무는 함께 진행"): 리뷰 9건(중요 5, 사소 4)을 모두 고쳤다.
- 2026-11-21(사용자: "continue"): 마지막 사용의 남은 것 중 이동한 지역에 다시 대입과 `xs = xs.appended(v)`의 버퍼 재사용.
- 2026-11-21(사용자: "continue"): 마지막 사용의 남은 것 중 같은 갈래에서 옮긴 뒤 대입, `if` 언랩 · `switch` · `begin:` 갈래의 이동,
  반복 본문에서 옮긴 뒤 `break` · `return`, `if` · `while` 언랩의 `NoCopy` payload.
- 2026-11-22(사용자: "continue"): 마지막 사용의 남은 다섯(`if` · `switch` 식 갈래, `try` 문, 옮긴 집합이 다른 `break`, 멤버 수신자
  재사용, 변수에 담긴 `NoCopy` 옵션의 `?else`).
- 2026-11-22(사용자: "continue"): 마지막 사용의 남은 둘(`and` · `or`의 왼쪽의 이동, `scope` 블록의 이동).
- 2026-11-22(사용자: "src/sema.zig too large. are there ways to refactoring?" 뒤 "이 리팩토링이 정상으로 완료되면 다음 패치 버전을
  올리자. 0.4.17 이야. 배포까지 부탁해. ... 남은 결정은 위임합니다."): `sema.zig` 분할과 0.4.17 릴리스.
- 2026-11-22(사용자: `/code-review high from 0.4.16 to head`와 "in tars-agent reports
  docs/requests/cyber-0.4.17-session-crash-after-slice-of-nocopy.md"): 요청서의 셋(세션 세그폴트, `[]T`의 `NoCopy` 원소 문구,
  빌린 값의 `for`)을 고쳤다. 이어서 리뷰 6건도 고쳤다("남은 작업"의 첫 항목).
- 2026-11-22(사용자: "continue" 뒤 질문에 "빌림 검사의 남은 구멍"): 0.4.17 뒤 기능과 빌림 검사가 만나는 자리를 탐침해
  갈래가 주는 빌림의 구멍(F-170)을 고쳤다.
- 2026-11-22(사용자: "continue" 뒤 질문에 "알려진 한계 하나 해소"): `json.to`의 struct 필드 기본값과, 그 길에 찾은 기본값 식의
  이름 해석 결함(F-171)을 고쳤다.

- 2026-11-22(사용자: `/code-review high from 0.4.0 to head` 뒤 "fix them step by step from easy one to difficult one. ok to use sub
  agents max 7", "continue" 두 번, "go release 0.4.18"): 리뷰 10건, 미룬 후보, 남은 것을 고치고 0.4.18을 릴리스했다.
- 2026-11-23 ~ 24(사용자: `/code-review high from 0.4.18 to head` 뒤 "fix step by step. use sub-agents max 20", 이어서
  "fix and clean up them all. then release next patch version 0.4.19 no ask to me"): 리뷰 8건, 남은 한계, 고치며 찾은 결함을
  고치고 0.4.19를 릴리스했다. 서브 에이전트가 worktree에서 고치고 master에 cherry-pick했다. 내용은 `docs/releases/0.4.19.md`.
- 2026-11-24(사용자: "C 백엔드를 제거하고 ... 문서에 보면 아직 옛 흔적이 남아 있어 ... 몇 가지는 구현하지 않아도 된다고 보는 게
  있어", 질문에 항목별로 답함): 매뉴얼의 C 백엔드 흔적과 Planned 항목을 정리하고 `os.open_lib`을 지웠다. 결정
  `docs/decisions/project_planned_features.md`, `unreleased.md` 같은 절. 작업 브랜치 `claude/clever-hypatia-eqz5vt`.
- 2026-11-24(사용자: "우리 Cyber lang 디자인에 Julia 언어에서 차용할만한 좋은 점이 있을까?", 이어서 컬렉션 식의 꼴과
  import 중괄호를 정하고 "B의 int op float 대칭부터 넣자"): Julia 검토(`docs/study/11-design-principles-review.md` 3절)를 쓰고
  3.4 B의 1(수 피연산자의 대칭 변환)을 넣었다. 결정 `docs/decisions/project_number_operands.md`, `unreleased.md` 같은 이름의 절.
  이어서 "A의 os.cmd도 넣자": 3.4 A(`os.cmd`)를 넣었다. 결정 `docs/decisions/project_os_cmd.md`.
  이어서 "E의 REPL 조회 명령도 넣자": 3.4 E(`.doc` · `.which` · `.bc` · `.help`)를 넣었다. 결정
  `docs/decisions/project_repl_commands.md`.
  작업 브랜치 `claude/sharp-faraday-c5yjxa`.
- 2026-11-24(사용자: F-199 수정 지시. "a method or type function declared in a later input of the same session works like one
  declared in the same source, for struct types at least. If some case can not be supported, it must be a compile error with a
  clear message, never a panic of the host."): 세션의 뒤 입력이 앞 입력의 타입에 메서드를 선언하게 했다. 결정
  `docs/decisions/project_session_methods.md`, `unreleased.md` 같은 이름의 절. 작업 브랜치 `claude/wizardly-franklin-xippbd`
  (`claude/sharp-faraday-c5yjxa` 위에 쌓았다: F-199의 기록과 `.which`가 그 브랜치에만 있다).
- 2026-11-24(사용자: F-200을 고치라는 요청, 결정 문서 · 테스트 · 매뉴얼 · 발견 표 · `unreleased.md` · `verify.sh`까지. "ask the user
  if the choice is not clear"): REPL 세션이 CLI의 모듈을 가져오게 했다. 결정 `docs/decisions/project_repl_modules.md`.
  작업 브랜치 `claude/sweet-darwin-55r6jg`(`claude/sharp-faraday-c5yjxa` 위에 쌓았다). 지금은 둘 다 master에 들어왔다.
- 2026-11-24(사용자: "continue"): 남은 치명 결함 F-204(가변 인자 extern 함수의 `int` 인자)를 고쳤다. master에 바로 커밋.
- 2026-11-24(사용자: "@HANDOFF.md continue"): 알려진 한계 "컴파일 타임 평가기의 float 연산 · 정수 폭"을 좇다 호스트 panic
  F-206 · F-207을 찾아 고쳤다. 컴파일 타임 수 연산이 런타임과 같은 값을 낸다. 결정 `project_number_operands.md` "컴파일 타임
  수 연산", `unreleased.md` 같은 이름의 절. master에 바로 커밋.
- 2026-11-24(사용자: "affirmative"(작은 결함 수정 뒤 릴리스 권고에), 이어서 "1번 작업을 마치고 3번 릴리즈 작업 진행 그 다음 다른
  세션에서 2번 줄리아 관련 내용 검토하겠음"): `error` 리터럴의 컴파일 타임 평가, 템플릿 오버로드의 꼴 차이 · 타입 인자 · 컴파일
  타임 호출을 고치고 0.4.20을 릴리스했다(2026-11-25 게시). 노트 `docs/releases/0.4.20.md`.
- 2026-11-25(사용자: "continue from HANDOFF", Julia 남은 결정 질문에 답함 — B의 2 자유 함수 꼴, C LSP Warning 먼저 · 세고 결정,
  D 둘 다 하지 않음, F 미루고 LSP 진단만): 셋을 넣었다. master에 바로 커밋(`f2b52b72` 결정 기록, `3ad0cd31` B의 2,
  `1e62e70d` C, `9987f869` F 대안, `2b4dfd80` 문자열 리터럴의 `str`/정수 쌍 제외). 15단계 검증 rc=0(`2b4dfd80`). push 안 함.
  이어서 사용자: "이거는 컴파일 에러로 내는 게 좋겠는데?" → C를 컴파일 오류로 올리고 LSP 힌트를 지웠다(`eba228f1`, 15단계 rc=0).

## 현재 브랜치

`master`. 0.4.20 태그 `b407c7b9`(`build-1165-b407c7b`, 에셋 15개, Latest). CI의 arm64 macOS 러너가 배정되지 않아 arm64 자산
둘은 로컬에서 빌드해 올렸다(`project_fork_release_ci.md` "0.4.20"). 릴리스 기록 커밋까지 push했다.

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

- [x] 0.4.16..HEAD 코드 리뷰 수정 9건(2026-11-21). 목록은 `unreleased.md` "0.4.16 뒤 변경의 코드 리뷰에서 나온 수정", 구현은
  `project_last_use.md`의 E · B 절 "코드 리뷰 수정".
  - overload 후보 실패 시 이동 되돌리기(`Chunk.move_undo`, `sema.undoMoves` · `noteMove`, `matchRtOverload`).
  - 재사용한 버퍼의 공유 차단(core `Slice.own_buffer`), `#for` 본문의 재사용 끔, 불일치 오류의 메서드 이름(`Chunk.reuse_call`).
  - `if` 갈래 끝 소멸의 cancel pad(`IfBranch.var_end`, `destructBranchEnd`), 첫 조건식의 이동 허용(`MoveBranch.if_cond`),
    조건부 식의 이동 문구.
  - REPL 최상위 지역은 `move`로만 이동, 이동한 것은 다음 입력에 없음(`isPersistedMainLocal`, `@untrackMainLocal`).
  - 값을 반환하는 `op=` 메서드의 문구, behavior 테스트 넷의 분류.
  - 확인: 14단계 검증에서 1~13단계 rc=0. 14단계는 `own_buffer` 탓에 `docs/api.json`이 낡아 실패했고, 다시 만든 뒤 일치를 확인했다.
  - tars-agent `docs/TODO.md`의 "다음 cyber 빌드" 항목에 세션의 `move` 규칙과 새 문구 둘을 적었다(커밋 안 함).

- [x] 이동한 지역에 다시 대입(2026-11-21). 결정 `project_last_use.md` "이동한 지역에 다시 대입", `unreleased.md` 같은 이름의 절.
  - 대입문이 죽은 지역을 되살린다(`sema.reviveLocal`). 오른쪽이 대입 대상을 옮기는 꼴(`x = f(x)`)은 어느 블록에서든 된다
    (`Chunk.assign_revive`, `sema.movesIntoAssign`). 바깥 지역을 옮긴 오른쪽의 `break` · `continue` · `try` 안 `!`는 오류
    (`checkAssignMoveJump`). 문장 전에 옮긴 지역은 선언한 블록에서만, REPL 최상위는 안 됨.
  - `xs = xs.appended(v)`가 버퍼를 재사용한다(반복 본문 포함, `reuseSliceBuffer`의 `assignsToName` 갈래).
  - `?else`가 새 값인 `NoCopy` 옵션을 푼다(`unwrap_or` · `unwrap_or_block`).
  - tars-agent `docs/TODO.md`의 "다음 cyber 빌드" 항목에 덧붙였다(커밋 안 함).

- [x] 갈래 종류와 반복 본문(2026-11-21). 결정 `project_last_use.md` "갈래 종류와 반복 본문", `unreleased.md` "갈래 · 반복 본문에서
  바깥 변수를 옮기는 자리가 늘었다" · "`if` · `while` 언랩이 `NoCopy` payload를 꺼낸다".
  - `MoveBranch.plain`(`begin:` · 반복문의 블록들), `Block.moves_start`, 같은 블록에서 옮긴 뒤 대입(`sema.movedInBlock`).
  - `if` 언랩 문과 `switch` 문의 case가 `if` 문과 같은 합류를 쓴다(`IfBranch.body`, `CaseMoves`, `pushCaseBlock` · `popCaseBlock`).
  - 반복문마다 감싸는 블록(`pushLoopWrap` · `popLoopWrap`): 옮긴 뒤 `break`는 그 끝으로 뛰고(`semaMovedBreak`), 다른 길은 반복문
    뒤의 소멸을 지난다. 옮긴 채 다음 반복으로 가면 오류(`checkLoopMoves`).
  - `semaCaptureUnwrap`이 `NoCopy` payload를 `_opt`에서 꺼낸다.
  - 확인: 14단계 검증 rc=0. 첫 실행은 `memory/array_nocopy_for_copy_error.cy`가 실패했다(`for a |r|`의 오류가 core의
    `Array.next`로 옮겨 감). `for` 순회는 캡처 전에 전의 복사 오류를 내게 했다.
  - tars-agent `docs/TODO.md`의 "다음 cyber 빌드" 항목에 덧붙였다(커밋 안 함).

- [x] 남은 다섯(2026-11-22). 결정 `project_last_use.md` "남은 다섯", `unreleased.md` "남은 자리의 이동" · "멤버에 대입하는 새 목록
  메서드도 버퍼를 재사용한다".
  - 나중에 채우는 자리(`MovedBreak.slot`, 빈 IR `block`): 옮긴 집합이 다른 `break`(`Chunk.moved_breaks`, `popLoopWrap`)와 `try`
    문의 실패한 `!`(`Chunk.try_exits` · `try_moves`, `semaTryExit`, `sema_try_stmt`).
  - `if` 식 · `switch` 식은 문장의 합류(`joinBranchMoves`)를 그대로 쓴다. `reportMoveAcross`는 막는 블록을 찾아 문구를 고른다.
  - `o ?else ...`는 블록 전에 옵션을 소유한다(`semaElseOptionOwner`). `s.xs = s.xs.appended(v)`는 제자리 호출
    (`reuseMemberSliceBuffer`).
  - 확인: 14단계 검증 rc=0.
  - tars-agent `docs/TODO.md`의 "다음 cyber 빌드" 항목에 덧붙였다(커밋 안 함).

- [x] `and` · `or`의 왼쪽과 `scope` 블록(2026-11-22). 결정 `project_last_use.md` 같은 이름의 절, `unreleased.md` "`and` · `or`의
  왼쪽과 `scope` 블록의 이동".
  - `and` · `or`의 내부 블록은 왼쪽을 검사하는 동안만 `.if_cond`(`semaLogicAnd` · `semaLogicOr`). `moveBlock`은 `.if_cond`가
    이어지는 동안 바깥으로 간다.
  - `sema_scope_stmt`의 세 블록이 `.plain`이고 `track_moves`를 켠다(`try` 문과 같은 `semaTryExit`의 자리). 실패한 길은 U_fail이
    죽은 채 오류를 내보낸다. `s`는 옮기지 못한다(`canMoveAcross`의 `scope_block` 검사).
  - 확인: 14단계 검증 rc=0.
  - tars-agent `docs/TODO.md`의 "다음 cyber 빌드" 항목에 덧붙였다(커밋 안 함).
- [x] `sema.zig` 분할(2026-11-22). 결정 `docs/decisions/project_sema_split.md`(파일 표 · 방법 · 규칙).
  - 15,418줄 → `sema.zig` 1,500줄 + 주제별 13개 파일. 선언을 그대로 옮기고 다른 파일의 선언을 `sema_x.name`으로 부른다(재수출
    별칭 없음). `src/`의 다른 파일과 주석의 `sema.name`도 고쳤다. 거대 함수 쪼개기는 하지 않았다.
  - `docs/gen-api-json.cy`와 `.github/workflows/gen-docs.yml`이 `member_aliases`를 읽는 파일은 `src/sema_hint.zig`다.
  - 이 문서와 옛 결정 문서 · 릴리스 노트의 `sema.semaOwn` 같은 이름은 고치지 않았다. `rg -n "fn semaOwn" src`로 찾는다.
  - 확인: 14단계 검증에서 1~13단계 rc=0. 14단계는 생성기가 `sema.zig`에서 `member_aliases`를 못 찾아 실패했고, 경로를 고친 뒤
    `docs/api.json`과 일치를 확인했다.
- [x] 0.4.17 릴리스(2026-11-22). 태그 `0.4.17` → `02c3c425`, `build-1031-02c3c42`, Latest, 에셋 15개. master run과 태그 run 모두
  재실행 없이 통과했다. `install.sh 0.4.17`을 scratchpad에 설치해 버전 문자열, `move` 없는 `Array` 이동 · 빌림의 마지막 사용 예,
  '`x` was moved at ...' 오류, `cyber-lsp initialize`를 확인했다. `/usr/local`의 설치는 사용자가 다시 한다.
  tars-agent `docs/TODO.md`의 "다음 cyber 빌드" 항목에 그 빌드가 0.4.17임을 덧붙였다(커밋 안 함).
- [x] tars-agent 요청 `cyber-0.4.17-session-crash-after-slice-of-nocopy.md`(2026-11-22). 기록은 `docs/releases/unreleased.md`.
  - 세션 세그폴트: 템플릿 본문의 실패를 인스턴스가 아니라 본문 단위로 표시한다(`FuncInfo.body_failed`). 부르는 자리는
    `sema_call.checkCallee`: 넘어온 본문에서 부르면 그 본문도 버리고, 지금 소스에서 부르면 다시 검사한다
    (`Compiler.recheck_funcs`, `semaChunkFuncs`가 `Chunk.funcs` 뒤에 돈다. `Chunk.funcs`는 함수를 소유하므로 거기 넣으면 이중 해제).
  - `semaCarriedFuncs`는 넘어온 본문이 전개한 함수(`main.funcs`의 늘어난 부분)도 같은 패스에서 검사하고, trait 구현 본문이 버려진
    타입은 인스턴스째 버린다(`hasFailedImpl`, 아니면 `bc_gen.fillVtables`가 null).
  - 앞 컴파일에서 실패한 인스턴스는 캐시에서 빼고 다시 전개한다(`template.failedEarlier`, `site_seq` 비교). 실패한 컴파일이
    미해석으로 남긴 타입은 `compiler.resolveCarriedTypes`가 먼저 해석한다.
  - `[]T`의 `NoCopy` 원소는 `sema_type.resolveStructFields` 끝에서 거절한다(`reportNoCopyInSlice`, `pending_slice_args`).
  - `for`는 빌림을 받으면 역참조한다(`sema_stmt.zig`의 `.for_iter_stmt`).
  - 재현 조건: 앞에 성공한 eval이 있는 세션이어야 한다. 첫 컴파일이 실패하면 VM이 리셋되어 보이지 않는다.
  - tars-agent: 요청서에 회신 절, `docs/TODO.md` 36행에 회신 요약(커밋함, push 안 함).

- [x] 갈래가 주는 빌림의 주인(2026-11-22, F-170, 깨지는 변경: `-> !&T`에 `scope`). 결정 `project_borrow_model.md` "갈래가 주는
  빌림", `unreleased.md` 같은 이름의 절.
  - `sema_borrow.joinBranchOwner`를 `if` 식 · `switch` 식(`SwitchInfo.borrow_owner`) · `?else` · `!else`(블록 꼴 포함)에 쓴다.
  - `bindBorrowLocal`이 빌림 지역에도 대여를 기록한다. `resolveResultType`이 `borrow_only` · `ex_borrow`를 전파한다. `!`는 새
    결과의 빌림 payload에 결과의 주인을 넘긴다(전에는 블록 끝에서 panic).
  - 저장소의 `.cy` 전부를 변경 전 · 후 CLI로 컴파일해 비교했다. 탐침 스크립트는 세션 scratchpad에만 있었다.

- [x] `json.to`의 필드 기본값(2026-11-22). 결정 `project_std_json_toon.md` "필드 기본값", `unreleased.md` 같은 절, F-171.
  - meta `has_field_default` · `field_default`. json의 struct 갈래는 멤버가 없을 때만 기본값을 만든다.
  - 기본값 식은 `sema_init.semaFieldDefault`가 struct의 해석 문맥에서 검사하고, 리터럴을 쓴 쪽의 지역은 감춘다
    (`Chunk.hide_locals_below`, `sema_local.lookupIdent2`). `cte`의 컴파일 타임 리터럴도 같은 문맥.
  - 동작이 바뀜: 같은 이름의 지역이 기본값을 가리던 것(전에는 지역 값). 확인: 14단계 검증 rc=0.

- [x] 수 피연산자의 대칭 변환(2026-11-24). 결정 `project_number_operands.md`, `unreleased.md` 같은 이름의 절, F-196 · F-197.
  - `i * f` = `f * i`, `i < f` = `f > i`, `f32 op float` = `float`. 산술(`+ - * / % **`)과 비교 모두. 결과는 정수로 되돌아가지
    않는다(`i += f` 오류). 정수 나눗셈과 비트 연산자는 그대로다.
  - `sema_expr.semaBinExpr`의 세 갈래(정수 왼쪽 산술, float 왼쪽 산술, 비교의 `semaComparedOperand`)와 `cte.evalFitNumbers`.
  - 함께 고친 조용한 오답: 왼쪽이 float인 산술이 오른쪽 타입을 검사하지 않던 것(`f + 'abc'`가 `2.5`, `f32 * float`가 `0.0`),
    컴파일 타임의 `2.5 * k`가 비정규 수이던 것.
  - 같은 날 정한 문법 꼴(구현은 안 함): 컬렉션 식은 `[]int{x * 2 from xs |x| if x > limit}`(검토 3.4 D), destructure import의
    중괄호는 안쪽을 띄운다(`project_fmt_brace_style.md`의 예외).

- [x] `os.cmd`(2026-11-24). 결정 `project_os_cmd.md`, `unreleased.md` 같은 이름의 절, F-198.
  - `os.cy`의 `Cmd` · `CmdStage`와 메서드 여덟, `os.zig`의 `cmdRun` · `cmdRunPipeline` · `cmdFeedInput` · `currentEnvMap`.
  - 검토의 권고대로 정한 것(사용자가 따로 고르지 않음): 실패한 종료는 `error.ExitStatus`, pipefail, `SIGPIPE`로 끝난 앞 단계는 성공,
    `Cmd`는 복사되는 값, `os.exec`는 그대로. 결정 문서 "정한 것"에 이유가 있다.
  - 함께 고친 것: 자식이 `os.set_env` 변수를 받지 못하던 것(`os.exec` 포함).
  - macOS · Windows에서는 실행해 보지 못했다(교차 컴파일만). 테스트 `modules/os_cmd.cy`는 Windows에서 본문을 건너뛴다.

- [x] REPL 조회 명령(2026-11-24). 결정 `project_repl_commands.md`, `unreleased.md` 같은 이름의 절.
  - `cy.cy`의 `REPL.command` · `VM.which` · `VM.bytecode` · `repl(read_line, doc)`, `refs.zig`의 `which`, `debug.zig`의
    `allocFuncBytecode`, `cli.zig`의 `doc_hook` · `replDoc`, `main.zig`의 `replDoc`.
  - 테스트는 `modules/cy.cy` 끝. `.doc`은 CLI에서 손으로 확인했다(자동 테스트 없음: REPL을 stdin으로 모는 테스트가 없다).
  - 확인: 수 피연산자 · `os.cmd` · REPL 명령 각각의 커밋 뒤 14단계 검증 rc=0(wasm 단계는 Python `wasmtime` 대역).

- [x] PR soomtong/cyber#12 리뷰(2026-11-24, 사용자: "PR 검토하고 리뷰하고 수정할 부분 처리 후 병합"). `/code-review high` 10건을 모두
  고쳤고(`unreleased.md` "PR #12 리뷰에서 나온 수정"), 첫 CI의 macOS 실패(`SIGPIPE`를 무시하는 러너에서 `yes | head -1`)를 고쳤다.
  - 구현 함정: 무시된 신호(`SIG_IGN`)와 신호 mask는 exec를 넘어 자식에게 간다. 핸들러는 기본 동작으로 돌아간다.
    Darwin의 `sigprocmask`는 프로세스의 모든 스레드에 적용된다(Zig `std.posix.sigprocmask`의 주석은 "thread signal mask"지만
    Darwin에서는 libc `sigprocmask`를 부른다). 스레드 하나만 막으려면 `pthread_sigmask`, 파이프 하나만이면 `F_SETNOSIGPIPE`.
    무시된 `SIGPIPE`는 Linux에서 `sh -c 'trap "" PIPE; exec zig-out/bin/cyber x.cy'`로 만든다.

- [x] 세션의 뒤 입력이 앞 입력의 타입에 메서드를 선언한다(2026-11-24, F-199 · F-202). 결정 `project_session_methods.md`,
  `unreleased.md` 같은 이름의 절.
  - 원인: 새 main 청크는 앞 eval의 심볼을 선언 없는 `use` 별칭으로 보는데 `sema_resolve.ensureDeclNamePath`가 별칭을 부모로
    돌려주었다. 별칭 · 함수 · 전역 · 상수에는 모듈이 없어 `reserveFunc`의 `getMod().?`가 죽었다(한 소스의 `fn foo :: bar()`도).
  - `lateDeclParent`가 별칭을 세션의 타입으로 푼다. 선언은 타입의 모듈(살아남는 청크의 것)에 들어가므로 실패한 컴파일은
    `Compiler.dropLateDecls`(`module.dropDeclsFrom`)가, `VM.validate`는 `discardLateDecls`가 뺀다. 뒤쪽은 그 컴파일이 전개한
    본문 중 버려지는 선언에 닿는 것도 버린다(생성된 코드가 버려진 메서드를 부른다. `late_refs`로 따라간다). 전개한 것을 통째로
    버리면 안 된다: 타입이 가진 `dtor` · `copy_ctor` 인스턴스가 `failed`가 되어 뒤 컴파일이 깨진다.
  - 템플릿 메서드의 뒤늦은 오버로드: `FuncSym.variant_decls`가 인스턴스가 전개한 선언 수를 세고 `module.expandLateOverloads`가
    나머지를 전개한다. 선언한 입력은 `Compiler.expandLateVariants`로 바로 전개한다.
  - `@deinit` · `@copy` · `@clone` · `@send`는 거절한다. 세션의 main 청크들은 uri와 상관없이 한 모듈이다
    (`Chunk.session_main`, `module.sameModule`): validate(`main`)와 `.which`(`which`)가 앞 eval의 `-` 필드를 읽는다.
  - 테스트: `modules/cy_session_methods.cy`, `functions/decl_parent_not_type_error.cy` ·
    `decl_method_parent_global_error.cy`, `modules/decl_method_other_module_error.cy`, lib `session.zig`의 마지막 테스트.
    탐침은 `cy.VM`으로 입력 목록을 한 세션에 eval하는 스크립트가 빠르다(`?`로 시작하면 `vm.which`: validate 경로).
  - 확인: 14단계 검증 rc=0. 커밋 `012e5a75`은 세션 hook 때문에 검증이 끝나기 전에 push했고, 검증 뒤 매뉴얼 문장만 고쳤다.
  - 남은 것: CLI의 REPL은 타입 블록이 한 입력이라 `@deinit` · `@copy` · `@clone` · `@send`를 가진 타입을 선언할 수 없다.
    같은 시그니처의 메서드를 교체하지 않고 오류로 한 것(결정 문서 규칙 3)과 이 넷의 거절(규칙 5)은 사용자 확인 전이다.

- [x] REPL이 CLI의 모듈을 가져온다(2026-11-24, F-200 · F-203). 결정 `project_repl_modules.md`, `unreleased.md` 같은 이름의 절.
  - `cy.VM()`은 격리된 채 두고 CLI가 준다: `cli.cy`의 `new_vm`(공개, 사용자 결정 2026-11-24) · `use_cli_modules`(private bind), `cli.zig`의 `useCliModules` ·
    `child_resolver`, `cy.cy`의 `REPL.new(vm)` · `REPL.run`. 자식 VM은 부모의 `cli.App`을 가리키기만 한다(해제하지 않음).
  - `cli.zig` `loader`는 파일 · URL 소스를 `C.vm_allocator(vm)`으로 읽는다(자식 VM의 allocator가 CLI의 것과 다르다).
  - F-203(세션의 extern 함수): `builtins/c.zig`의 `newTccState` · `isBound` · `hasUnbound`, `VM.tcc_states`,
    `compiler.emit_program_init_func`이 앞 컴파일의 extern 청크를 본다.
  - 테스트 `modules/cy.cy` · `modules/cli.cy` · `modules/cli_os.cy` · `ffi/session.cy`, `verify.sh` 15단계 `15-repl-stdin`.

## 시도했으나 실패한 접근

- `+=` 경로에서 받는 쪽을 `semaExpr`로 읽으면 복사본에 append한다(이중 해제). 메서드 호출처럼 `semaExprSkipSym`을 써야 한다.
- `xs.append(xs.span())`은 빌림 오류다(안전). 같은 구조체의 두 필드(`self.sets.append(self.ops.span())`)도 `self`를 두 번
  빌린다고 막힌다. 지역 사본(`ops := self.ops`)으로 우회한다.
- zsh는 `$files`를 단어로 나누지 않는다. 여러 파일 치환은 `rg -l0 ... | xargs -0`.

## 남은 작업

- [x] `/code-review high` 0.4.0(3815c4c0)..23df09eb의 10건(2026-11-22, 사용자: "fix them step by step from easy one to difficult one.
  ok to use sub agents max 7", 기존 커밋 제목의 80자 초과는 "no need to change commit messages"). 서브 에이전트 일곱이 worktree에서
  고치고 쉬운 것부터 cherry-pick했다(`cde51cef`..`f4cca264`, 문서 `881c2581` · `91eb1664`). 내용은 `docs/releases/unreleased.md`의
  마지막 두 절, F-172..F-181. 리뷰가 10건 제한으로 뺀 후보(`time.cy:379` Duration 곱셈, spawn Future UAF, 스레드 힙 잠금,
  `str.init_rune(0x200000)` · `seek_pos(-1)` · `Raw.fmt` 큰 width의 호스트 panic, `lsp_main.zig` 응답 버퍼 이중 해제, `json.to(f32)`의
  범위 초과 `inf`, wasm32의 `cl_vm_set_stack_limit` `@intCast`)는 손대지 않았다.
  수정 중 새로 찾은 것: 복합 대입의 좌변 두 번 계산(`arr[say(1)] += 2`), 템플릿 함수 인자의 배타 빌림 충돌 검사 없음
  (`matchGenericFuncRt`), `if o |q|: r = q`의 보수적 거짓 오류, `for` 캡처의 빌림 주인(시험 못 함).
- [x] 0.4.18 릴리스(2026-11-22): 노트 `docs/releases/0.4.18.md`, 기록 `project_fork_release_ci.md`. CI의 Linux에서 spawn 상태
  테스트의 메모리 기준이 실패해 상태 수로 검사하게 고쳤다(`3ff30939`, `80126d0e`). 태그 run의 macOS Intel cpu 시간 테스트는
  한 번 재실행.
- [x] 같은 VM에서 `vm_eval`을 거듭하면 VM 메모리가 eval마다 자라던 것(2026-11-24 조사, 사용자: "continue"). eval마다 main 청크
  하나 분량이 남는다(앞 eval의 함수 · 타입을 뒤 eval이 쓸 수 있어 VM 끝까지 둔다). 그중 쓰지 않는 명령 버퍼 자리와 빈 작업 스택을
  돌려줘 `x := 1` 기준 eval마다 15.2 → 9.6 KB. 청크 자체를 놓으려면 참조 분석이 필요해 하지 않았다.
  `project_memory_limit.md` "eval마다 남는 메모리".
- [x] 위 항목의 남은 것을 정리했다(2026-11-22, 사용자: "continue", F-189..F-194). `unreleased.md` 끝의 "남은 것의 정리" 절.
  spawn 인자 · 결과는 한 규칙(`@sendable`), 버린 future는 끝까지 돈다(결정), `FutureSyncState` 해제. wasm32-freestanding 빌드 복구와
  CI 단계 추가. 빌림 컨테이너 구멍 일곱(깨지는 변경: 매개변수 뒤에는 `scope` 매개변수만 저장).
  남은 것: `borrow_places`가 지역 id 목록이 아니어서 생기는 오탐 둘, 사용자 정의 `scope` `next`의 `for` 캡처는 이터러블에 묶음,
  시험 분석이 끌어올린 문장은 남는다는 가정(`project_eval_order.md`), 스크립트 취소 API 없음.
- [x] 위 항목의 미룬 후보와 새로 찾은 것을 모두 고쳤다(2026-11-22, 사용자: "continue", 서브 에이전트 일곱, F-182..F-188).
  `unreleased.md` "리뷰가 미룬 후보와 수정 중 찾은 결함" 절. spawn 결과 소유권은 결정 `project_spawn_result_ownership.md`.
  남은 것: spawn 인자 쪽 `@send`의 참조 있는 option · result(빈 본문), 큐에 있는 작업은 future를 버려도 끝까지 돈다,
  `VM.shared_states`가 VM 수명 동안 자란다, `r = xs[0]` · `r = h.b`는 컨테이너를 주인으로 본다(보수적), 순수로 보는 연산식
  인덱스의 복합 대입은 사용자 연산자를 두 번 부른다, `intFmtExt`의 64바이트 버퍼(지금은 도달 불가), 4GB 넘는 문자열의 `u32`
  캐스트, `zig build lib -Dtarget=wasm32-freestanding`의 Zig std 오류(기존).

- [x] `/code-review high` 0.4.16..HEAD(2026-11-22)의 6건을 고쳤다(사용자: "let's fix them step by step. use sub agent as you
  can.", 7번 커밋 제목은 "no need to fix"). 서브 에이전트 셋이 worktree에서 고치고 cherry-pick으로 합쳤다. 내용은
  `docs/releases/unreleased.md`와 `docs/decisions/project_last_use.md`의 마지막 절.
  확인하지 못한 것: 조건식 안의 `switch` 식(넣는 문법이 없다), 문장 텍스트에 보이지 않는 점프가 있는 `xs = xs.appended(v)`.

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
  - 남은 것: 없다(`and` · `or`의 오른쪽, `?else` · `!else`의 기본값 · 블록은 열지 않기로 함, 결정 문서 끝 절). 성능 수치는 재지 않았다.
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
- `src/compiler.zig` `semaCarriedFuncs` · `carryFailedCompile`(실패 뒤 carry), `BodyRecover` · `semaChunkFuncsRecover` · `resolveChunkSyms` · `recoverableDecl`, `src/sema_stmt.zig` `semaStmts` ·
  `semaStmt`, `src/sema_resolve.zig` `declFailed`(복구 경로).
- `src/builtins/core.cy` `Slice` 절(`reserve_own` · `clone_copy` · `append` · `appended` 등, `rg -n "fn \(&&?Slice\[\]\)"`).
- `src/sema_call.zig` `semaOpAssignMethod` · `checkSliceInPlaceResult` · `checkDroppedSliceResult`.
- sema 파일 표: `docs/decisions/project_sema_split.md`.
- `src/parser.zig` `isForeignDeclKeyword` · `reportForeignDeclError` · `reportTypedDeclError`.
- `src/std/os.cy` `read_file` · `read_file_bytes` · `write_file` · `write_file_bytes`.
- `docs/releases/0.4.17.md`, `docs/releases/unreleased.md`.
- `docs/decisions/project_fork_release_ci.md`(러너 미배정 · 재태깅 · 로컬 arm64 빌드 절차).

- [x] F-199: `persist_main` 세션에서 앞 입력이 선언한 타입에 뒤 입력이 메서드 · 타입 함수를 선언하면 호스트가 abort하던 것.
  고쳤다(위 "완료된 작업"의 "세션의 뒤 입력이 앞 입력의 타입에 메서드를 선언한다", `project_session_methods.md`).
- [x] F-200(2026-11-24 수정): CLI의 REPL에서 `use os`가 실패하던 것. "완료된 작업"의 "REPL이 CLI의 모듈을 가져온다".
- [x] F-204(2026-11-24 수정, 사용자: "continue"): 가변 인자 extern 함수에 `int` · `float` · `f32` · `r16`을 넘기면 호스트가
  abort하던 것. 변형 함수의 C 래퍼(`cgen.genVmToExternFunc`)가 자기 매개변수 · 반환 타입을 선언한다. 테스트 `ffi/variadic.cy`.
- `os.cmd`의 다음 단계(`project_os_cmd.md` "가져오지 않은 것"): 줄 단위 스트리밍, 실행 중 중단 · 시간 제한, 파일 리다이렉션.
  Windows에서의 실행 확인도 남았다.
- [x] Julia 검토(설계 원칙 3.7)의 남은 결정(2026-11-25). 결정 기록은 3.7 끝 "결정(2026-11-25".
  - B의 2: 모듈 수준 연산자 함수 `` fn `*`(s float, v Vec2) ``를 두 피연산자 타입의 모듈에서 찾는다. 산술 · 비트만, 비교는
    메서드만. 선언은 같은 모듈의 타입을 받아야 한다. 결정 `project_operator_lookup.md`, 매뉴얼 Operator methods. 15단계 rc=0.
  - C: 모호한 오버로드 호출은 컴파일 오류(깨지는 변경, `sema_func.checkAmbiguousCall`). 경고 단계의 힌트는 지웠고
    `CL_HINT_PATTERN_LITERAL`이 5가 됐다. 수 타입끼리, 문자열 리터럴 자리의 `str`/정수만 다른 쌍은 모호하지 않다(json `v['n']`).
    인자가 이름 · 리터럴 · 멤버 접근인 호출만 본다. `project_overload_exact_match.md` 끝 절, F-21 행.
  - D: 하지 않는다(컬렉션 식도 `map` · `filter`도).
  - F: 미룸. 대안으로 `CL_HINT_PATTERN_LITERAL` · `cyber-lsp`가 `regex.compile` · `peg.compile`의 리터럴을 별도 VM에서 컴파일해
    Error 진단. LSP 설계 문서 19절.
  - tars-agent: B의 2 · C · F 대안을 `docs/TODO.md`의 cyber 변경 항목에 덧붙여 커밋했다(`df1a693`, 사용자 지시로 남아 있던
    다른 세션의 0.4.19 미커밋 변경도 함께, push 안 함).
- [x] 컴파일 타임 수 연산(2026-11-24, F-206 · F-207): 내장 수 타입의 모든 산술 · 비트 · 순서 연산, 정수 넓히기, float `==`.
  정수 `/` · `%` 0은 컴파일 오류. `error` 리터럴도 컴파일 타임 식이다. `>>`는 매뉴얼대로 논리 시프트(산술은
  `.asr()`).

## 다음 에이전트에게

1. 0.4.20이 마지막 릴리스다(노트 `docs/releases/0.4.20.md`). `unreleased.md`에 세 절(모듈 수준 연산자 함수, 모호한 호출 오류,
   패턴 리터럴 진단)이 있다. 2026-11-25 사용자 답: master는 push(`b7ee7d36`까지), 릴리스는 아직 하지 않는다.
2. 다음 릴리스도 사용자가 지시할 때만. master를 먼저 push하고 그 run이 끝난 뒤 태그를 push한다.
3. tars-agent 저장소에는 쓰기 전에 `git status`를 본다(다른 세션이 동시에 일한다). 회신 절 외에는 쓰지 않는다.

## 알려진 한계

- 0.4.19에서 남긴 것: 시그니처에 직접 쓴 `fn(T) -> [%N + 1]T`는 이제 `N`을 짚는 'Can not infer the template parameter'
  오류다(2026-11-24, 거꾸로 풀지는 않는다).
  템플릿 오버로드의 꼴 차이 · 타입 인자 · 컴파일 타임 호출은 2026-11-24에 고쳤다(`unreleased.md` "템플릿 오버로드의 남은 한계").
  컴파일 타임 호출의 `str` 인자는 `EvalStr`라 `fn f(x str)`에 맞지 않는다. 실패한 오버로드 후보에서 끝까지 검사된 타입 선언형 람다는 죽은 코드로 남는다. `cyber src/builtins/cy.cy`의 panic은
  F-205로 고쳤다(이제 호스트 함수 로드 실패 컴파일 오류). wasm 빌드의 behavior 테스트는 `-Dtest-filter`를 빌드 때 넣어
  따른다(`test_config.case_filter`, 2026-11-24).
  '변수를 캡처하는 블록 람다를 오버로드 인자로 주면 Missing return statement.'라는 보고는 재현되지 않았다(leak만 고쳤다).
- 이동: 조건부로 평가되는 식의 부분(`and` · `or`의 오른쪽, `?else` · `!else`의 기본값 · 블록)은 바깥 변수를 옮기지 못한다.
  `try` 문 · `scope` 블록 안의 `!`마다 빈 IR `block` 문장이 하나 붙는다(bytecode는 없다).
  `while` 조건식의 이동은 반복문 문구('the next iteration reads it')로 막힌다. `if` 언랩의 옵션 식은 옮길 수 있다. 버퍼를 재사용한 호출의 런타임
  stack trace에는 제자리 메서드(`Slice.remove`)가 나온다. REPL에서 `move a` 뒤 다음 입력의 `a`는
  '`a` was moved by an earlier input.'이다(2026-11-24, `Compiler.moved_main_locals`).
- 양보만 하는 fiber와 Future를 기다리는 fiber가 섞이면 `Scope.run`이 쉬지 않고 돈다(설계대로).
- 실행으로 확인하지 못한 경로: Windows `FallbackReadLine`. 시작한 자식이 멈춘 동안 부모 스택이 옮겨지는 경우는 지금 구조에서
  생기지 않음을 확인했다(`project_coroutines.md` 끝 절).
- 변수에 담은 `FnTuple`로는 빌림을 넘기지 못한다(사용자 코드에 `FnTuple`이 나오지 않아 하지 않기로 함).
- 최상위 `#x := ...` 컴파일 타임 변수는 뒤의 최상위 실행문에서 못 쓴다(선언 단계에서만 평가).
- 보간 안의 보간은 지원하지 않는다(토크나이저 상태가 한 단계). 원인을 말하는 오류만 낸다.
- `json` 기본 파싱은 17자리 넘는 소수를 `float`으로 근사한다(`exact`면 원문).
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
- `g := f(move g)`처럼 선언의 초기식이 같은 이름의 옛 변수를 읽으면 '`g` is no longer alive in this scope.'다(REPL에서 확인).
  `t := f(move g)` 뒤 `g := move t`로 쓴다.
- 하위 블록에서는 `move` · `meta.consume`을 못 쓴다(`else` 갈래의 consume은 뒤까지 죽은 상태로 남는다). 컴파일 타임
  `#for xs |v|`(EvalBuffer 반복)는 `#case` 바로 아래에서 `for_iter_stmt` 오류라 `#for 0..n |i|`로 돈다.
- VM 생성(`cl_vm_init*`)과 값 생성 C API의 할당 실패는 아직 `fatal`(실패를 알릴 시그니처를 먼저 정해야 함).
- 신뢰하지 않는 스크립트의 C FFI 차단은 미결정(`deny_raw_ptrs` · `deny_spawn`은 있음).
- 전체 발견 이슈 표: `docs/study/10-findings-register.md`(F-207까지, 열린 것 없음).

## 작업 방식

- 순서: scratchpad 재현 → 수정 → Debug CLI 확인(`zig build cli -p <scratchpad>/dbg`) → 회귀 테스트 → 문서 → 15단계 검증 → 커밋.
- 15단계 검증(14단계는 `docs/api.json` 낡음 검사, 15단계는 빌드한 `cyber`의 REPL에 줄을 파이프로 넣는 검사. 2026-11-24 전의
  기록은 "14단계 검증"이라고 적는다): `src/tools/verify.sh [로그 디렉터리]`(`task verify`, 약 10분, 기본 로그 `zig-out/verify/`). `run_in_background`로
  돌리고 완료 알림을 기다린 뒤 `rc=`를 확인하고 커밋한다(`tail`만 보지 않는다). 도는 동안 `src/`를 고치지 않는다(고쳤으면
  죽이고 다시). 다른 작업을 이어 가려면 git worktree에서 돌리고 끝나면 `git worktree remove`.
- 커밋은 의미 있는 diff면 묻지 않고 한다. push · 태그 · 릴리스는 사용자 지시 때만. `gh`는 `-R soomtong/cyber`.
- 사용자에게 보이는 변경(버그 · 언어 규칙 · 한계)은 같은 커밋에서 `unreleased.md`에, 언어 규칙이면 `docs/docs.md`에도 적는다.
  설계 결정은 `docs/decisions/`, 발견 이슈는 findings register에. 문서는 한국어, `**` 금지. 전체 `zig fmt` 금지(바꾼 줄만).

## 릴리스

1. 버전 세 곳: `build.zig` · `build.zig.zon` · `install.sh`.
2. `unreleased.md` → `docs/releases/<v>.md`(요약 · 호환성 절을 새로 쓴다), `unreleased.md`는 머리말만 남긴다.
3. 15단계 검증 rc=0 → master push → 그 Latest Build가 끝난 뒤 annotated 태그 push(같이 올리면 `concurrency: latest`로 한쪽이 취소된다).
4. 릴리스 run 확인(`gh run list`), `gh release edit <v> --notes-file docs/releases/<v>.md --latest`. Latest는 `gh release list`로 본다.
5. `install.sh <v>`를 scratchpad에 설치해 버전 문자열 · `cyber-lsp initialize` · 예제 하나 확인.
6. 노트에 태그 커밋 · 빌드 번호를 적어 커밋하고 `docs/decisions/project_fork_release_ci.md`에도 기록.
- 재태깅 · macOS arm64 로컬 자산 업로드 절차는 `project_fork_release_ci.md`.

## 테스트 요령

- 클라우드 세션 컨테이너에는 Zig와 wasmtime이 없다. `pip install ziglang==0.17.1 wasmtime` 뒤 `ziglang` 패키지 안의 `zig`를
  PATH에 건다. Zig의 `git+https` 패키지 받기는 프록시에서 실패한다(`unable to discover remote git server capabilities`).
  `build.zig.zon`의 두 패키지(translate-c, 그 안의 arocc)를 codeberg의 `/archive/<커밋>.tar.gz`로 받아
  `zig-pkg/<zon의 hash 이름>/`에 풀면 빌드된다. `wasmtime run --dir=.::/ x.wasm`은 Python `wasmtime` 패키지(`WasiConfig` ·
  `preopen_dir`)로 같은 일을 하는 스크립트를 PATH에 두면 `verify.sh`의 9~12단계가 돈다(2026-11-24 세션).
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
