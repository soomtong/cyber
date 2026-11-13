# 0.4.9 이후 변경 (미릴리스)

0.4.9(2026-11-12) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

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
  `CLItem{name, detail, kind}`로 준다(이름순, VM 소유). 설계는 `docs/specs/2026-11-12-lsp-design.md` 8절.

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
  Windows 번들에는 아직 없다(빌드는 되지만 실행을 확인하지 못했다). `zig build test`는 Windows 타깃에서 `lsp-test`를 뺀다.

- 언어 서버 `cyber-lsp`를 더했다(`zig build lsp`, `task build:lsp`). CLI와 같이 `libcyber` 위의 별도 프로그램이고 stdin · stdout으로
  Language Server Protocol을 말한다. 문서를 실행 없이 프로그램으로 컴파일해 컴파일 오류를 진단으로 내고(`First declared at:` ·
  템플릿 확장 호출 지점은 관련 정보), `cyber fmt`와 같은 결과의 문서 포맷, 개요(타입 · 필드 · 함수 · 메서드 · 상수 · 전역),
  들여쓰기 기준 접기, hover(선언의 첫 줄 또는 `이름 타입`), 정의로 이동, 문서 안의 references · 강조, 지역과 매개변수의 rename, completion(`.` 뒤의 멤버와 범위의 이름), signatureHelp를 준다. 편집기에 열린 모듈은 디스크가 아니라 편집기의 내용으로 읽는다. 위치는 클라이언트가 `utf-8`을
  받으면 바이트, 아니면 UTF-16이다. 오류 복구를 켜서 본문(main 블록 · 함수 · 메서드)마다 첫 오류를 진단으로 낸다. 검사 한 번은 ReleaseFast에서 약 5ms다.
  설계와 단계는 `docs/specs/2026-11-12-lsp-design.md`(P1).
- `exts/vscode/test`: 확장을 실제 VS Code에서 돌리는 테스트(`task test:vscode`, `@vscode/test-electron`). 진단 · hover ·
  definition · references · rename · 개요 · 접기 · completion · signatureHelp · 포맷 · 서버 재시작을 에디터의 명령으로 확인한다.
  VS Code 1.146.0에서 아홉 항목이 통과한다.
- `exts/vscode`가 `cyber-lsp`의 클라이언트가 됐다(`vscode-languageclient`, 설정 `cyber.lsp.enabled` · `cyber.lsp.path`, 명령
  `Cyber: Restart Language Server`). TextMate 문법의 키워드를 지금 문법으로 바꿨다(`fn` · `use` · `fiber` · `suspend` · `scope` 등).

## 문서
