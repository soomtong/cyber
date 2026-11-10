# 컴파일 오류 요약의 ANSI 색 · 구조화된 위치 · eval 결과 주석 (2026-11-10, F-52)

## 배경

`docs/study/08-embedding-builtins-tests.md` §7.2 · §7.4와 발견 이슈 표 F-52의 남은 부분이다(`persist_main`의 마지막 맨 표현식은
2026-11-04 `project_repl_result.md`로 해결).

- `debug.writeUserErrorTrace2`가 컴파일 오류의 캐럿 줄(`^~~~`)을 `\x1b[31m` · `\x1b[0m`으로 무조건 감쌌다. `cl_vm_error_summary` ·
  `cl_vm_compile_error_summary`를 받는 호스트(로그 · LLM 프롬프트 · 파일)와 파이프로 넘긴 CLI 출력(`cyber bad.cy 2> err.txt`)에
  이스케이프 코드가 섞였다. 테스트 하네스(`setup.zig`)와 `host_tool.c` 예제 설명은 각자 지우고 있었다. 코드에는
  `TODO: Should not emit escape codes. Instead, expose stack trace as data for consumer.`가 남아 있었다.
- 컴파일 오류는 문자열 요약으로만 나온다. panic은 `cl_thread_panic_trace`(`CLStackFrame`)로 줄 · 열을 주는데 컴파일 오류는 호스트가
  요약 문자열에서 `uri:line:col:`을 파싱해야 했다.
- `cl_vm_compile_error_summary`는 리포트가 없으면 `cy.panic("No report.")`, `cl_thread_panic_summary`는 panic이 없으면
  `allocPanicMsg`의 `Unexpected panic type.`으로 호스트를 abort시켰다(성공한 eval 뒤에 부르는 호스트의 실수가 프로세스 종료가 됨).
  스크립트에서도 닿는다. `use cy` 뒤 `cy.VM().compile_error_summary()` · `cy.VM().panic_summary()` 한 줄이 `cyber`를 종료 코드 134로
  끝냈다(수정 전 `ad88ce11` ReleaseSafe에서 재현). 신뢰하지 않는 스크립트를 돌리는 호스트에는 서비스 거부다.
- `cyber.h`의 `cl_vm_eval` 주석 "If the last statement of the script is an expression, `outVal` will contain the value."는 0.3 시절
  문장이다. 매개변수 이름도 `res`다. 실제로는 `fn main() -> T`의 반환값, 또는 `persist_main` eval의 마지막 맨 표현식만 값이 된다.
- 캐럿 줄은 `'~' * (cp_len - 1)`인데 노드 범위가 그 줄에서 비면(`cp_len == 0`) safe 빌드에서 정수 언더플로 panic이 된다.

리포트 목록(`Compiler.reports`)은 실제로는 항상 한 개다. `reportError`가 곧바로 `error.CompileError`를 돌려주고 컴파일이 멈추기 때문이다
(오류 복구 없음, F-78). 표의 "첫 리포트만"은 API가 나머지를 버린다는 뜻이 아니라 컴파일러가 첫 오류에서 멈춘다는 뜻이다.
한 리포트는 `next` 사슬로 문맥(`First declared at:`)과 템플릿 확장 호출 지점을 달고 있고, 요약 문자열이 이를 모두 적는다.

## 결정

- 요약 문자열은 기본으로 이스케이프 코드를 넣지 않는다. 요약은 데이터다.
- 색은 호스트가 켠다: `cl_vm_set_error_color(vm, bool)`. 값은 `Compiler.report_color`에 둔다(VM 구조체는 `vm.h` padding 때문에 필드를
  못 늘린다. Compiler는 `cl_vm_reset`을 넘어 살아 있으므로 설정이 유지된다). 켜면 컴파일 오류 요약의 캐럿 줄만 이전처럼 빨강이다.
  panic 요약은 원래 색이 없다.
- CLI(`main.zig`)는 stderr가 ANSI를 받는 터미널일 때만 켠다. `std.Io.Terminal.Mode.detect`를 쓰고 `NO_COLOR`(비어 있지 않으면 끔) ·
  `CLICOLOR_FORCE`(비어 있지 않으면 켬)를 따른다. Windows 콘솔은 `detect`가 VT 처리를 켜는 데 성공했을 때만 켠다.
  테스트 러너는 `init_cli`만 부르고 색을 켜지 않으므로 터미널에서 돌려도 기대 문자열이 같다.
- `cy.VM`(Cyber 쪽 `VM()` · REPL의 자식 VM)은 printer처럼 부모 VM의 색 설정을 물려받는다. REPL은 자식 VM의 요약을 `eprint`로 찍기 때문이다.
- 구조화된 위치: `bool cl_vm_compile_error(CLVM* vm, CLCompileError* out)`.
  `CLCompileError{ kind, msg, uri, has_loc, line, col, len }`.
  - `kind`는 요약의 제목과 같은 `CL_REPORT_TOKEN_ERROR` · `CL_REPORT_PARSE_ERROR` · `CL_REPORT_COMPILE_ERROR`(`CLReportKind`),
    `msg`는 제목 뒤 한 줄.
  - `uri`는 오류가 난 청크의 해석된 uri. 청크가 없으면(모듈 해석 실패 · JIT 거절) 빈 문자열.
  - `line` · `col`은 `CLStackFrame`과 같이 0부터 세고 `col`은 바이트 단위다(요약의 `uri:line:col`은 1부터). `len`은 그 줄에서 표시되는
    소스 바이트 수(캐럿 줄의 폭에 해당, 토큰 · 파싱 오류는 1).
  - `has_loc`이 false면(노드 없는 오류) `line` · `col` · `len`은 0.
  - 마지막 eval · compile · validate가 컴파일 오류로 끝나지 않았으면 false를 돌려주고 `out`은 0으로 채운다.
  - `msg` · `uri`는 VM 소유다. 그 VM의 다음 eval · compile · validate · reset 전까지만 유효하고 해제하지 않는다.
  - 문맥 · 템플릿 호출 지점 사슬은 주지 않는다(요약 문자열에는 그대로 있다). 필요해지면 프레임 배열을 따로 더한다.
- `cl_vm_compile_error_summary`는 리포트가 없으면, `cl_thread_panic_summary`는 panic이 없으면 빈 `CLBytes`(`ptr == NULL`, `len == 0`)를
  돌려준다. `cl_vm_freeb`에 그대로 넘겨도 된다.
- `cl_vm_eval` 주석을 실제 동작으로 고친다. 결과 코드가 `CL_SUCCESS`가 아니면 `res`는 정의되지 않는다는 것도 적는다.
- 캐럿 줄의 `~` 수는 포화 뺄셈으로 센다.

## 하지 않는 것

- 오류 복구(여러 오류 보고). 파서 · sema가 첫 오류에서 `error.CompileError`로 풀리는 구조라 범위가 다르다(F-78).
- 열 번호의 표시 폭 보정(한글 등 다바이트 문자 뒤 캐럿 어긋남, F-78).
- panic 요약 · 스택 프레임의 색.
- CLI 옵션(`--color`). 환경 변수로 충분하다.
- `PANIC_INFLIGHT_OOM` 상태의 `cl_thread_panic_summary`. `allocPanicMsg`가 여전히 `cy.panicFmt`로 끝난다. 이 상태는
  `z_panic_unexpected_choice`가 메시지를 할당하지 못했을 때만 생기고, 컴파일 · 런타임의 할당 실패 처리(F-41 남은 것)와 같이 다룬다.

## 확인

- lib 테스트 `Compile error summaries have no escape codes unless the host asks.` · `cl_vm_compile_error returns the location of a compile error.` ·
  `Error summaries are empty when there is no error.`
- CLI: `cyber bad.cy 2>&1 | /bin/cat -v`에 `^[[31m`이 없고, `CLICOLOR_FORCE=1`이면 있고, `NO_COLOR=1`이 이긴다. `script -q /dev/null`로
  pty를 주면 색이 켜진다. REPL(`printf 'print(nope)\n' | CLICOLOR_FORCE=1 cyber`)의 자식 VM도 같다.
- `cy.VM().compile_error_summary()` · `cy.VM().panic_summary()` 스크립트가 빈 문자열을 받고 종료 코드 0으로 끝난다.

## 같이 고친 것

- `docs/docs.md` 임베딩 절 예제의 `summary.buf`(`CLBytes`의 필드는 `ptr`), `fn main() -> int:` 뒤에 빠진 `\n`, 선언 없는 `code`.
- `src/test/setup.zig`의 `expectErrorReport2`가 요약에서 이스케이프 코드를 지우던 두 줄을 없앴다.
