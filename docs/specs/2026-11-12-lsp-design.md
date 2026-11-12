# LSP 서버 설계와 단계 계획

2026-11-12 작성. 기준 버전 0.4.9(`03d24f4e`). 상태: P0 구현(2026-11-12, 아래 "P0 구현" 절). P1 이후는 미구현.
앞선 결정은 `docs/decisions/project_fmt.md`의 "내장 도구의 기준"(LSP는 CLI에 넣지 않고 라이브러리 위의 별도 프로그램),
사실 근거는 `docs/study/01-pipeline-front-end.md` 6절과 `docs/decisions/project_compile_error_report.md`이다.

---

## 1. 개요

Cyber용 LSP 서버 `cyber-lsp`를 `libcyber` 위의 별도 프로그램으로 Zig로 쓴다. 컴파일러 프런트엔드(토크나이저 · 파서 · sema)를
그대로 쓰고, 문서가 바뀔 때마다 파일 전체를 다시 검사한다. 증분 분석과 질의 기반 재작성은 하지 않는다.

계획의 전제가 되는 현재 상태(0.4.9):

| 항목 | 현재 상태 | LSP에 주는 영향 |
| --- | --- | --- |
| 진단 | 파서 · sema가 첫 오류에서 `error.CompileError`로 풀린다. `Compiler.reports`는 항상 한 개(F-78) | 오류 복구 전에는 진단이 파일당 한 개 |
| 위치 | `Report.loc`은 토큰 · 파싱 오류면 바이트 위치, sema 오류면 `*ast.Node`. 열은 바이트 단위 | 범위와 UTF-16 변환이 필요 |
| 심볼 해석 | sema가 노드 → `Sym` 대응을 남기지 않는다. `ir.Expr.node` · `ir.Stmt.node`로 IR에서 노드로만 간다 | hover · 정의 이동에는 해석 기록이 필요 |
| 분석 범위 | `semaChunkFuncs`가 청크의 모든 함수 본문을 분석한다. 템플릿은 확장될 때만 | 확장되지 않은 템플릿 본문은 진단이 없다 |
| 있는 것 | `cl_vm_validate`(실행 없이 컴파일), `cl_vm_format`, `cl_vm_set_loader`, `Node.pos()` · `Node.end()` | 진단 · 포맷 · 저장 전 버퍼 overlay는 바로 가능 |
| 에디터 | `exts/vscode`는 TextMate 문법만, `exts/tree-sitter`는 문법과 쿼리 네 개 | VS Code 클라이언트를 더한다 |

0.4.9에서 달라진 문법(`scope |s|:` 블록, 0.4.7 · 0.4.8의 `generator fn` · `fiber` · `suspend`)은 P0와 무관하다.
P1에서 `documentSymbol` · `foldingRange`가 `scope` 블록 노드를 다뤄야 하고, 에디터 문법은 따로 맞춘다
(`exts/tree-sitter/grammar.js`에 `scope |s|:` 블록 문장이 없고, `exts/vscode`의 TextMate 문법에는 `fiber` · `suspend` ·
`generator`가 없다).

## 2. 핵심 디자인

1. 프로세스 구조: 서버는 `src/lsp/`에 두고 `cy` 모듈을 직접 import한다. AST와 `Sym`을 읽어야 해서 C API만으로는 모자라다.
   빌드 단계는 `zig build lsp`, 산출물은 `zig-out/bin/cyber-lsp`. 전송은 stdio와 `Content-Length` 프레이밍, JSON은 `std.json`.
2. 문서 모델: full sync로 시작한다. 열린 버퍼는 loader 콜백으로 덮고 나머지는 `default_loader`가 디스크에서 읽는다.
3. 분석 단위: 변경 뒤 약 150ms를 기다렸다가 파일 전체를 컴파일한다. 결과의 문서 버전이 지금과 다르면 버린다.
4. 위치 인코딩: LSP 3.17 `positionEncoding`으로 `utf-8`을 협상한다. 받지 않는 클라이언트에만 UTF-16으로 바꾼다.
   컴파일러는 바이트 위치만 낸다(P0의 `pos` · `end_pos`).
5. 격리: 컴파일러 panic(F-80 같은 것)과 컴파일 타임 평가의 무한 루프가 서버를 끝낼 수 있다. 분석은 워커 스레드에서 돌리고
   컴파일 타임 평가에 연료를 건다. 서버가 죽으면 클라이언트가 다시 띄운다.

### 단계

| 단계 | 내용 | 컴파일러 변경 |
| --- | --- | --- |
| P0 | 리포트의 범위(시작 · 끝)와 목록 · 문맥 사슬을 데이터로 노출 | 작음 |
| P1 | 서버 뼈대, `publishDiagnostics`, `formatting`, AST 기반 `documentSymbol` · `foldingRange`, VS Code 클라이언트 | 없음 |
| P2 | 오류 복구: 파서는 들여쓰기 기준 블록 동기화, sema는 함수 단위로 계속 진행 | 중간. 가장 위험 |
| P3 | 해석 기록으로 `hover` · `definition` · `references` · `completion` · `signatureHelp` | 중간 |
| P4 | core 청크를 든 VM 재사용, `semanticTokens`, workspace 심볼 | 작음 |
| P5 | `rename`, code action, inlay hint | 없음 |

## 3. pros vs cons

| 접근 | 장점 | 단점 |
| --- | --- | --- |
| A. 컴파일러 재사용(선택) | 진단이 `cyber` 실행 결과와 같다. 버전이 함께 잠긴다. 타입 정보가 정확하다 | fail-fast 구조를 고쳐야 한다. 컴파일러 버그가 서버 종료가 된다 |
| B. tree-sitter 구문 전용 | 오류 복구가 이미 있다. 컴파일러를 건드리지 않는다 | 타입 · 오버로드 · 템플릿을 모른다. 문법이 이미 컴파일러와 두 군데서 다르다(`project_tree_sitter.md`) |
| C. Cyber로 작성 | dogfooding | JSON이 없다. `cy.parse`가 노드 페이로드를 `void`로 숨긴다. sema에 닿지 못한다 |

A에서 감수하는 것:

- 편집 중인 미완성 코드(`a.`)에서 completion을 주려면 파서가 불완전한 식을 노드로 남겨야 한다(P3).
- sema를 함수 단위로 복구하면 실패한 함수의 proc · block 스택을 되감아야 한다. 반쯤 만들어진 상태가 남는 버그
  (`first_compile_failed`와 같은 종류)가 생기기 쉽다(P2).

## 4. 선례와 이 설계의 자리

- LSP(2016): 에디터 m개 × 언어 n개를 프로토콜 하나로 줄였다. 뿌리는 Roslyn의 "서비스로서의 컴파일러"다.
- RLS → rust-analyzer: RLS는 배치 컴파일러의 분석 덤프를 썼고 응답이 느려 밀려났다. rust-analyzer는 질의 기반(salsa)으로
  프런트엔드를 다시 썼다.
- zls: 컴파일러가 sema를 내주지 않아 분석기를 따로 유지한다. comptime의 정확도에서 비용을 치른다.
- Cyber: 파일은 스크립트 크기이고 컴파일러는 약 6만 줄이다. RLS식 재사용의 약점(느림)은 작고, zls식 이중 구현의
  약점(불일치)은 `#` 컴파일 타임 평가 때문에 크다. 그래서 A를 고르고 질의 기반 재작성은 하지 않는다.

P0와 P2는 LSP가 없어도 에이전트 루프에 쓸모가 있다(`01-pipeline-front-end.md` 6절의 "한 번 실행에 여러 진단").

## 5. P0 구현 (2026-11-12)

LSP의 `Diagnostic`은 `range`(시작 · 끝), `message`, `relatedInformation`(다른 위치와 설명)으로 이뤄진다.
`cl_vm_compile_error`는 시작 위치와 첫 줄 안의 길이, 사슬의 머리만 준다. P0는 나머지를 데이터로 낸다.

- `debug.ReportLoc`에 `pos` · `end_pos`(소스의 바이트 오프셋)와 `end_line` · `end_col`을 더했다. `len`은 그대로다.
  - sema 오류: 노드의 `pos()` ~ `end()`. 여러 줄에 걸친 노드는 끝 줄까지 간다(`len`은 지금처럼 첫 줄에서 끊는다).
  - 토큰 · 파싱 오류: 위치 하나만 알고 있으므로 그 자리의 코드포인트 하나. 줄 끝이나 소스 끝이면 빈 범위다.
    토큰 전체로 넓히는 일은 서버가 한다(파싱이 끝난 뒤 토큰 배열은 남지 않는다).
- C API(`cyber.h`):
  - `size_t cl_vm_compile_report_count(CLVM* vm)`: 마지막 eval · compile · validate의 컴파일 오류 수. 지금은 0 또는 1이고
    P2부터 늘어난다.
  - `bool cl_vm_compile_report(CLVM* vm, size_t idx, CLReport* out)`.
  - `bool cl_vm_compile_report_note(CLVM* vm, size_t idx, size_t note_idx, CLReport* out)`: 리포트에 달린 사슬을 순서대로 준다.
    `kind`는 `CL_REPORT_NOTE`. `First declared at:` 같은 문맥은 `msg`가 있고, 템플릿 확장을 부른 지점은 `msg`가 비어 있다.
    끝을 넘으면 false.
  - `CLReport{ kind, msg, uri, has_loc, line, col, end_line, end_col, pos, end_pos }`. 줄 · 열은 0부터, 열은 바이트 단위,
    끝은 범위에 들지 않는다. `msg` · `uri`는 VM 소유이고 다음 eval · compile · validate · reset까지 유효하다.
- `cl_vm_compile_error` · `CLCompileError`는 그대로 둔다(ABI). 첫 리포트의 머리를 준다.

하지 않은 것:

- UTF-16 열. 서버가 `pos` · `end_pos`와 소스로 바꾼다(2절 4번).
- 진단의 심각도 · 코드. 컴파일러는 오류만 낸다.
- `cy.VM`(Cyber 쪽)에 같은 API. 필요해지면 더한다.

확인: lib 테스트 `Compile reports give the range and the notes of a compile error.`

## 6. P1에서 먼저 확인할 것

- 컴파일 시간: `cl_vm_validate` 한 번이 core 로드를 포함해 얼마인지 잰다. 수십 ms를 넘으면 P4의 VM 재사용을 당긴다.
- 검사 중 부작용: validate가 `use` 대상의 extern 바인딩(dlopen)과 컴파일 타임 코드를 어디까지 실행하는지 확인하고
  서버에서는 막는다.
