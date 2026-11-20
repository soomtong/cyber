# HANDOFF (2026-11-19): LSP 다음 후보(VS Code 테스트, 위치 결함, 매개변수 이름 inlay, 선언 rename)

## 목표

- 0.4.15 릴리스: `Slice` 제자리 API(깨지는 변경), `os` 파일 함수 옛 꼴의 힌트, `cyber-lsp`의 코드 지원 · 린트.
  LSP 확장은 사용자 요청(2026-11-18): "기본으로 탑재할 수 있는 LSP 기능을 목록화하고 구현, 패치 버전 릴리스".
- 릴리스 뒤(2026-11-18): `/code-review` 0.4.14..HEAD의 10건을 모두 고치고, CI 시간을 줄이는 방법을 검토 · 적용
  (사용자: "10번까지 작업을 마치고 ... 전체 CI가 시간이 너무 긴데 줄일 수 있는 방법을 검토", 검토 승인은 위임).
- 2026-11-19: HANDOFF "남은 작업"의 LSP 다음 후보 넷(사용자: "3번 진행해").

## 현재 브랜치

`master`. `3da1f688`(리뷰 수정 · CI)까지 push돼 있다(2026-11-19 확인). 그 뒤 커밋 여섯(`15ce5fa8` ~ `b99e0bcb`)은
`lsp-followups`에서 만들어 master로 fast-forward 병합했고, push하지 않았다.

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

- [x] 코드 리뷰 수정 10건(2026-11-18). 목록과 동작 변화는 `docs/releases/unreleased.md` "0.4.14..0.4.15 코드 리뷰에서 나온 수정".
  - 전역 take-and-restore: 값을 인자 뒤에 꺼낸다(`sema.finishGlobalTake`, `sema_func.matchFuncSig` 끝에서 호출).
    결정 문서 `project_slice_append_aliasing.md` 결정 3-1의 "인자" 항목.
  - 컴파일러가 fix를 오류에 싣는다(`Chunk.reportErrorFix`, `sema.suggestedFix`, `CLReport.has_fix`). LSP는 `data.fix`.
  - 확인: `zig build test` Debug · ReleaseSafe 통과(behavior 558개, LSP 41개).
- [x] CI 시간 줄이기(2026-11-18). 원인 넷과 고친 것은 `project_fork_release_ci.md` "CI 시간 줄이기". CI에서의 수치는 push 뒤에 본다.

- [x] 매뉴얼 예제 포맷(2026-11-20, 사용자: "A+B 진행해줘"): `docs.md` · `agent-guide.md`의 `cy` 블록을 `cyber fmt`로(A),
  구문 오류였던 매뉴얼 예제 일곱 곳과 코드가 아닌 `cy` 블록 다섯 개(B). 기록은 `project_fmt.md` "매뉴얼 예제에 적용",
  `unreleased.md` "매뉴얼 예제 코드". 이어서 C(study · specs · decisions 블록)와 D-좁음(두 문서 인라인 코드 14곳)도 했다.
  하지 않은 것: decisions · study의 인라인 코드, 문서 블록 `fmt --check` 검사(E).

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
    목록은 `docs/releases/unreleased.md` "rename · 매개변수 이름 inlay의 리뷰 수정".
- [ ] CI 시간 확인: Latest Build의 job별 시간을 전(`44236296335`, 21분 28초)과 비교해 `project_fork_release_ci.md`에 적는다.
  macOS arm64 Debug 테스트가 여전히 길면 그 step을 빼는 안이 다음 후보다.
- [x] tars-agent `docs/TODO.md`에 다음 빌드에서 안내 105행을 고칠 항목(`4aae2ec`, tars-agent에 커밋됨).

- [x] 0.4.15 릴리스(2026-11-18): 태그 `0.4.15` → `93a9ca4f`, `build-969-93a9ca4`, Latest, 에셋 15개(CI). `install.sh 0.4.15`를 임시
  경로에 설치해 버전 · 스크립트 · `cyber-lsp`의 여러 구문 오류 진단을 확인했다. `/usr/local`의 설치는 사용자가 다시 한다.
- [ ] tars-agent 의존을 0.4.15로 올리기는 tars-agent 쪽 일(TODO 항목).
- [ ] 사용자 결정 대기(이전부터):
  - 정렬: pinned closure(안 A), 키 정렬, 인자 없는 `sort()`의 원소 조건. `project_sort_closures.md` "결정할 것".
  - core `@eq`의 choice 지원(`?json.Value == none`).
  - 설계 원칙 검토(`docs/study/11-design-principles-review.md`) 1.7 · 2.7.
  - 0.5 범위: `spawn f(args)` 호출식 꼴, 임베딩 `CL_YIELD`. 빼면 0.5 릴리스 준비로 간다.
- [ ] LSP 다음 후보: 본문 안 문장 단위 복구 · 선언 오류 복구(LSP 설계 문서 13절 앞), call hierarchy, 범위 포맷.
  토크나이저의 `ignoreErrors` 모드는 닫히지 않은 문자열에서 끝없이 토큰을 만든다(쓰는 곳 없음, LSP 14절).
- [ ] 기술 부채(급하지 않음): carry 재시도 루프의 IR 되돌리기, `@destruct_span` 취소 keep 지점, `Scope.run`의 바퀴당 `waiting()`
  질의, 취소 불변식 panic. 기록은 `project_coroutines.md`.

## 핵심 파일

- `src/refs.zig` "Hints" 절, `src/lsp/server.zig` `hintDiagnostics` · `onCodeAction` · `onInlayHint`, `src/lsp/assist.zig`.
- `src/builtins/core.cy` `Slice` 절(`reserve_own` · `clone_copy` · `append` · `appended` 등, `rg -n "fn \(&&?Slice\[\]\)"`).
- `src/sema.zig` `semaOpAssignMethod` · `checkSliceInPlaceResult` · `checkDroppedSliceResult`.
- `src/parser.zig` `isForeignDeclKeyword` · `reportForeignDeclError` · `reportTypedDeclError`.
- `src/std/os.cy` `read_file` · `read_file_bytes` · `write_file` · `write_file_bytes`.
- `docs/releases/0.4.15.md`, `docs/releases/unreleased.md`.
- `docs/decisions/project_fork_release_ci.md`(러너 미배정 · 재태깅 · 로컬 arm64 빌드 절차).

## 다음 에이전트에게

1. 0.4.15가 마지막 릴리스다.
2. 다음 릴리스도 사용자가 지시할 때만. master를 먼저 push하고 그 run이 끝난 뒤 태그를 push한다.
3. tars-agent 저장소에는 쓰기 전에 `git status`를 본다(다른 세션이 동시에 일한다). 회신 절 외에는 쓰지 않는다.

## 알려진 한계

- 양보만 하는 fiber와 Future를 기다리는 fiber가 섞이면 `Scope.run`이 쉬지 않고 돈다(설계대로).
- 실행으로 확인하지 못한 경로: Windows `FallbackReadLine`. 시작한 자식이 멈춘 동안 부모 스택이 옮겨지는 경우는 지금 구조에서
  생기지 않음을 확인했다(`project_coroutines.md` 끝 절).
- 변수에 담은 `FnTuple`로는 빌림을 넘기지 못한다(사용자 코드에 `FnTuple`이 나오지 않아 하지 않기로 함).
- 최상위 `#x := ...` 컴파일 타임 변수는 뒤의 최상위 실행문에서 못 쓴다(선언 단계에서만 평가).
- 보간 안의 보간은 지원하지 않는다(토크나이저 상태가 한 단계). 원인을 말하는 오류만 낸다.
- `?json.Value == none`은 컴파일 오류(core `@eq`가 choice 미지원). `?else` · `Value.eq`를 쓴다.
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
- 전체 발견 이슈 표: `docs/study/10-findings-register.md`(F-163까지, 열린 것은 F-162 `+..` 포맷 · F-163 비ASCII 오류 메시지).

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
3. 13단계 검증 rc=0 → master push → 그 Latest Build가 끝난 뒤 annotated 태그 push(같이 올리면 `concurrency: latest`로 한쪽이 취소된다).
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
- 언어 메모: `Slice`의 `append` 등은 제자리(`xs.append(v)`), 새 목록은 `appended` · `+`. 비트 OR은 `||`, AND는 `&&`. 전역은 `global g int = 5`. `var x = 0`은 문법 오류(`x := 0`). `os.parseArgs`는
  `-name=value`만 받는다. `Map`의 개수는 `size()`. `out.* += fut.await()`는 await 전에 `out.*`를 읽는다.
- 벤치는 다른 프로세스가 CPU를 쓰는지 먼저 본다(tars-linux `services_test`, 종료 금지). 테스트와 동시에 돌리지 않는다.

## 참고 위치

- 동시성 전체(제너레이터 · fiber · 단계 1 · 3 · 취소 · `scope` · `@deinit` 취소): `docs/decisions/project_coroutines.md`.
- JSON · TOON: `project_std_json_toon.md`. 정규식: `project_std_regex.md`. PEG: `project_std_peg.md`. 시간: `project_std_time.md`. 정렬 클로저: `project_sort_closures.md`.
- 임베딩 · tars-agent: `project_embedding_agent_loop.md` · `project_tars_agent_runtime_review.md`, C API `src/include/cyber.h`.
- 컴파일러 한계: `project_compiler_limits.md`. 평가 순서: `project_eval_order.md`. 스택 포인터 보정: `project_stack_ptr_patch.md`.
- 방향(네이티브 · LLVM · JIT는 범위 밖): `project_direction.md`.
- tars-agent는 다른 세션이 동시에 고치고 있을 수 있다. 그 저장소에 쓰기 전에 `git status`를 보고,
  쓸지는 사용자에게 맡긴다.
