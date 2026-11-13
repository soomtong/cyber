# 0.4.9 이후 변경 (미릴리스)

0.4.9(2026-11-12) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

- 치다 만 소스가 컴파일러를 끝냈다(F-117). `fn f(a`, `return ,`, `type X = #[`, 값 없는 `const a`, 필드 없는 `type Foo cstruct`,
  `const z = h`(함수 이름을 값으로), `fn() => borrow`. 모두 컴파일 오류가 됐다. 저장소 `.cy` 전체의 모든 접두사를 파서와
  컴파일러에 넣어 확인한다.
- 템플릿 인스턴스의 메서드 시그니처가 해석되지 않으면(`fn (&W[]) bad() -> T.nope`) 그 메서드를 다시 부를 때 컴파일러가 죽었다
  (F-118). `persist_main` 세션의 다음 eval과, 오류 복구를 켠 컴파일의 다음 본문에서. 이제 부를 때마다 같은 컴파일 오류다.

- private 필드(`-secret int`)가 있는 struct 값의 `print(v)` · `'%{v}'` 보간 · `v == w`가 컴파일되지 않았다(F-116,
  ``Can not access the private field `secret` in `Vec2`.``, 위치는 `core`). 같은 모듈 안에서도 그랬다. 이 연산들은 `meta.access`로
  모든 필드를 읽는데 그 접근이 `core`에서 쓴 접근으로 검사됐다. `meta.access`는 값의 필드를 가시성과 무관하게 읽는다
  (메타프로그래밍은 가시성을 검사하지 않는다는 기존 규칙). `v.secret`으로 직접 쓰는 접근은 그대로 오류다.
- 한 VM으로 컴파일을 되풀이하면 메모리가 계속 늘었다(F-114). 컴파일마다 컴파일 타임 힙에 주인 없는 객체가 십여 개 남았고
  `cl_vm_reset`(`cl_vm_compile`이 먼저 부른다)이 그 힙을 비우지 않았다. reset이 남은 객체를 지우고 페이지를 하나만 남긴다.
  `cyber-lsp`는 검사 300번에 RSS가 약 250kB 늘었고 이제 늘지 않는다.

- 함수가 없는 트레이트(`type NoCopy trait`)의 선언 노드에서 끝 위치를 구하면 컴파일러가 abort했다(F-115, safe 빌드는
  `integer overflow`). 그 선언을 가리키는 컴파일 오류의 요약과 `cl_vm_compile_report`가 해당된다. 이름의 끝을 돌려준다.

- 컴파일 타임 호출에 문자열 인자를 주면 컴파일러가 호스트를 끝냈다(F-112). `#print('hello')`는 `panic: Unsupported: .eval_ref`,
  `fn f(x %T)`를 `#a := f('abc')`로 평가하면 `Double free`였다(Release 빌드에서는 해제된 메모리를 다시 해제). `type.info`가
  지원하지 않는 타입은 이제 ``` `type.info` does not support the type `EvalStr`. ``` 컴파일 오류이고, 제네릭 함수의 컴파일 타임
  인자는 피호출 쪽만 해제한다.

- `use x 'https://…'`가 해석된 주소 대신 초기화되지 않은 버퍼를 읽었다(F-113). 오류 메시지에 쓰레기 바이트가 들어가고 모듈은
  로드되지 않았다. CLI의 resolver가 http(s) 지정자를 결과 버퍼에 쓰지 않고 길이만 돌려줬다. GitHub 저장소 주소는 원래 맞았다.

- `#meta.log('text')`처럼 컴파일 타임 문자열을 `meta.log`에 넘기면 컴파일러가 죽었다(`panic: integer overflow`,
  Debug 빌드는 `Double free`). 파일 최상위와 함수 본문 모두 그랬다. 호스트가 평가하는 함수의 참조 인자는 호출 자리가
  해제하는데(F-112의 규칙) `log`가 한 번 더 해제했다. 죽지 않은 경우에도 문자열 대신 주소가 숫자로 찍혔다.
- `math.random()`이 고정 시드 0으로 시작해 실행마다 같은 수열을 돌려줬다(첫 값이 늘 `0.3650744641604983`).
  이제 첫 호출 때 시스템 엔트로피로 시드한다.
- WASI 빌드의 CLI가 사전 개방 디렉터리 이름과 소스 경로를 구분자 없이 붙였다. `cyber main.cy`는 `.main.cy`를 찾다
  `error.FileNotFound`였고, `cyber ./main.cy`는 `../main.cy`를 열었다. 이제 `./main.cy`로 합친다.

## 언어와 표준 라이브러리

## 임베딩 API

- `cl_vm_set_symbol_info(vm, true)`를 켜고 컴파일하면 `cl_vm_symbol_at(vm, pos, &info)`가 main 소스의 바이트 오프셋 `pos`에 있는
  이름이나 식을 설명한다(에디터의 hover · 정의로 이동용, 기본 꺼짐). `CLSymbolInfo.detail`은 한 줄이다: 선언의 첫 줄
  (`fn add(a int, b int) -> int`), 지역 · 매개변수 · 필드는 `이름 타입`, 그 밖의 식은 타입. `has_def` · `def_uri` · `def_pos` ·
  `def_end_pos`는 선언의 위치다(표준 모듈이면 `def_uri`가 `core` 같은 이름). 컴파일이 실패해도 오류 전에 해석된 것은 답한다.
  main 소스만 기록한다. `info.kind`는 `CL_SYMBOL_EXPR` · `CL_SYMBOL_LOCAL` · `CL_SYMBOL_DECL`. `cl_vm_symbol_refs(vm, pos, &ranges)`는
  같은 것을 가리키는 main 소스의 모든 범위(`CLRange`)를 준다(쓰인 곳과 선언의 이름, 정렬 · 중복 없음, VM 소유).
  `cl_vm_members_at(vm, pos, &items)`는 `pos`에서 끝나는 식의 멤버(타입의 필드 · 메서드, 또는 모듈 · 타입이 선언한 것)를,
  `cl_vm_names_at(vm, pos, &items)`는 `pos`에서 쓸 수 있는 이름(지역 · 매개변수 · main 소스의 선언 · `use`한 것 · 내장)을
  `CLItem{name, detail, kind}`로 준다(이름순, VM 소유).
  `cl_vm_symbol_at` · `cl_vm_symbol_refs`는 main 소스의 선언에 있는 이름 자리에서도 답한다. `cl_vm_symbol_refs_to(vm, def_uri,
  def_pos, &ranges)`는 그 자리에 선언된 것을 가리키는 main 소스의 범위를 준다(다른 소스들에서 쓰인 곳을 찾을 때 소스마다
  main으로 컴파일해 묻는다). `cl_vm_symbol_tokens(vm, &tokens)`는 해석된 이름과 종류(`CLItemKind`)를 위치순으로 준다.
  `CLItemKind`에 `CL_ITEM_METHOD`(수신자가 있는 함수)가 생겼다. 이 조회 함수들은 기록이 없으면(첫 컴파일 전, `cl_vm_reset` 뒤,
  기록을 끄고 한 컴파일 뒤, main 소스에 이르기 전에 실패한 컴파일 뒤) false · 0을 돌려준다. 설계는 `docs/specs/2026-11-12-lsp-design.md` 8 · 9절.

- `cl_vm_set_error_recovery(vm, true)`를 켜면 컴파일러가 오류 뒤에도 계속해 여러 오류를 낸다(기본은 꺼짐, `cl_vm_reset`을 넘어 유지).
  본문(main 블록 · 함수 · 메서드 · 함수 템플릿 인스턴스) 하나가 첫 오류에서 버려지고 나머지 본문은 검사된다. 본문당 오류는 하나다.
  구문 오류와 선언(타입 · 시그니처 · 전역)의 오류는 지금처럼 컴파일을 끝낸다. 결과는 그대로 `CL_ERROR_COMPILE`이고 아무것도
  실행하지 않는다. 요약 문자열과 `cl_vm_compile_error`는 첫 오류를, `cl_vm_compile_report_count` · `cl_vm_compile_report`는 전부를 준다.
  실패한 템플릿 인스턴스를 다른 본문이 다시 쓰면 그 본문은 새 오류 없이 건너뛴다. 설계는 `docs/specs/2026-11-12-lsp-design.md` 7절.

- `cl_vm_compile_report_count(vm)` · `cl_vm_compile_report(vm, idx, &rep)` · `cl_vm_compile_report_note(vm, idx, note_idx, &rep)`가
  컴파일 오류의 전체 범위와 딸린 위치를 `CLReport`로 준다. `cl_vm_compile_error`는 시작 위치와 첫 줄 안의 길이만 줬고
  `First declared at:` · 템플릿 확장 호출 지점은 요약 문자열에만 있었다. `CLReport`는 `line` · `col` ~ `end_line` · `end_col`
  (0부터, 열은 바이트, 끝은 범위 밖)과 같은 범위의 바이트 오프셋 `pos` · `end_pos`를 가진다. 여러 줄에 걸친 노드는 끝 줄까지 간다.
  토큰 · 파싱 오류는 그 자리의 코드포인트 하나(줄 끝 · 소스 끝이면 빈 범위)다. 딸린 위치의 `kind`는 `CL_REPORT_NOTE`이고
  템플릿 확장 호출 지점은 `msg`가 비어 있다. 오류 복구를 켜지 않으면 개수는 0 또는 1이다.
  `cl_vm_compile_error` · `CLCompileError`는 그대로다. LSP 서버 계획의 P0다(`docs/specs/2026-11-12-lsp-design.md`).

## 변경

- Linux · macOS 릴리스 번들에 `cyber-lsp`가 들어간다. `install.sh`가 `cyber` 옆에 `cyber-lsp`도 `CYBER_BIN`에 심링크하고,
  서버가 없는 번들(0.4.9까지)을 설치하면 이전 설치의 `cyber-lsp`를 지운다(실행 파일과 버전이 다른 서버를 남기지 않는다).
  `install.sh`는 번들을 임시 파일로 먼저 받으므로 다운로드가 실패하면 아무것도 바뀌지 않는다.
  Windows 번들에는 아직 없다(빌드는 되지만 실행을 확인하지 못했다). `zig build test`는 Windows 타깃에서 `lsp-test`를 뺀다.

- 언어 서버 `cyber-lsp`를 더했다(`zig build lsp`, `task build:lsp`). CLI와 같이 `libcyber` 위의 별도 프로그램이고 stdin · stdout으로
  Language Server Protocol을 말한다. 문서를 실행 없이 프로그램으로 컴파일해 컴파일 오류를 진단으로 내고(`First declared at:` ·
  템플릿 확장 호출 지점은 관련 정보), `cyber fmt`와 같은 결과의 문서 포맷, 개요(타입 · 필드 · 함수 · 메서드 · 상수 · 전역),
  들여쓰기 기준 접기, hover(선언의 첫 줄 또는 `이름 타입`), 정의로 이동, references · 강조, 지역과 매개변수의 rename, completion(`.` 뒤의 멤버와 범위의 이름), signatureHelp, workspace 심볼, 워크스페이스 전체의 references, semantic tokens를 준다. 편집기에 열린 모듈은 디스크가 아니라 편집기의 내용으로 읽는다. 위치는 클라이언트가 `utf-8`을
  받으면 바이트, 아니면 UTF-16이다. 오류 복구를 켜서 본문(main 블록 · 함수 · 메서드)마다 첫 오류를 진단으로 낸다. 검사 한 번은 ReleaseFast에서 약 5ms다.
  설계와 단계는 `docs/specs/2026-11-12-lsp-design.md`(P1).
- `exts/vscode/test`: 확장을 실제 VS Code에서 돌리는 테스트(`task test:vscode`, `@vscode/test-electron`). 진단 · hover ·
  definition · references · rename · 개요 · 접기 · completion · signatureHelp · 포맷 · 서버 재시작을 에디터의 명령으로 확인한다.
  VS Code 1.146.0에서 아홉 항목이 통과한다.
- `exts/vscode`가 `cyber-lsp`의 클라이언트가 됐다(`vscode-languageclient`, 설정 `cyber.lsp.enabled` · `cyber.lsp.path`, 명령
  `Cyber: Restart Language Server`). TextMate 문법의 키워드를 지금 문법으로 바꿨다(`fn` · `use` · `fiber` · `suspend` · `scope` 등).

## 문서

- `docs/docs.md`의 Concurrency 장을 다시 구성했다: Overview(thread · fiber · generator 비교), Threads, Futures, Fibers,
  Structured concurrency(`scope` 블록 · `Scope`), Cancellation, Generators, Planned concurrency features.
  fiber 절은 Threads 아래에서 독립된 절로 옮겼다. 앵커 `#fibers` · `#generators` · `#futures`는 그대로다.
- 구현된 것인데 TBD · Planned로 남아 있던 절을 채웠다: Manual memory(`alloc` · `free`), Unwrap or guard,
  Conditional compilation, Resolving futures(`FutureResolver.new`), Type binding 예제, 제너레이터 `end`.
  libcyber 장에 Limiting an eval(`cl_vm_interrupt` · `cl_vm_set_fuel` · 스택 · 메모리 한도)을 추가했다.
- 구현되지 않은 것은 TBD 대신 Planned Feature · Incomplete로 통일하고 지금 쓸 수 있는 대안을 적었다
  (`aio` 모듈 예제 삭제, `then_spawn` · 채널 · 공유 메모리 · `await` union · SIMD · `os.openLib` · `c.source` 등).
- 최상위 `#if` 예제가 컴파일 오류가 나는 형태였다. 함수 본문 안의 예제로 바꿨다. 깨진 앵커 세 개를 고쳤다.
- `extern` 전역의 문서 예제가 틀렸다. `#[extern] global count Ptr[int]`와 "포인터 타입이 필요하다"는 설명대로 쓰면
  C의 `int count`를 포인터로 읽어 Segmentation fault가 난다. 전역은 C 변수의 타입 그대로 선언한다
  (`#[extern] global count i32`). 구현은 바뀌지 않았다.
- 문서 사이트의 Edit Page 링크와 libcyber 장의 헤더 · 예제 링크가 이 저장소를 가리킨다.
- Playground를 문서 사이트의 `play/`에 올린다. 서버 없이 `cyber-wasi.wasm`(CLI)을 브라우저의 Web Worker에서 돌린다
  (`examples/web-playground`: 최소 WASI 호스트 `wasi.js`, `worker.js`, 예제 8개). Stop은 worker를 끝내서 멈추지 않는
  프로그램을 중단하고, Share는 소스를 URL에 담는다. wasm 빌드에는 스레드(`spawn`) · FFI · 파일 시스템이 없다.
  `gen-docs.yml`이 그 커밋에서 wasm을 빌드해 같이 배포한다. 로컬은 `task playground:build` 뒤 `task playground:serve`.
- Playground의 편집기에 언어 서버를 붙였다: 진단(밑줄 · 여백 표시), completion(`.` 뒤와 이름 두 글자부터, Ctrl+Space),
  hover, Format 버튼. `cyber-lsp`의 WASI 빌드(`cyber-lsp.wasm`)를 별도 worker에서 돌린다. 서버는 stdin에서 멈춰
  기다리므로 띄워 두지 않고, 요청마다 새 인스턴스에 `initialize` → `didOpen` → 요청 → `exit`를 넣는다(약 50ms).
  서버 코드는 바꾸지 않았다. `wasi.js`가 stdin을 메시지 하나씩 넘겨 서버가 `didOpen` 뒤에 진단을 내보낸다.
