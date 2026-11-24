# 0.4.19 이후 변경 (미릴리스)

0.4.19(2026-11-24) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 매뉴얼의 Planned 항목 정리와 `os.open_lib` 삭제 (2026-11-24)

C 백엔드를 지운 뒤 `docs/docs.md`에 남은 흔적과 `Planned Feature` 표시를 검토했다. 남길 계획과 뺄 계획은 사용자가 정했다.
결정과 항목별 대안은 `docs/decisions/project_planned_features.md`.

- 호환성: `os.open_lib`과 `os.DynLib`이 없어졌다. 전에도 호출하면 'TODO' panic이었다. 이제 'Can not find the symbol `open_lib` in `os`.'
  컴파일 오류다. C 라이브러리는 `#c.bind_lib(path)`로 묶는다.
- 매뉴얼에 남은 계획: optional chaining, named parameters, `error` set 타입, 더 많은 `Sendable` 타입, destructure import.
  destructure import의 꼴은 `use { cos, pi } from 'math'`로 바꿨다.
- 계획에서 뺀 것: `fmt`의 이름 있는 자리표시자, line-join 리터럴, 가변 `Str`, `?else` 블록의 `break 값`, `+..` 슬라이스, 내용 없는
  호출 절 둘, `defer`, 반환값 구조 분해, 타입 템플릿의 제네릭 타입, 내장 `clone`, weak reference, `@check_cycles`, 할당마다 고르는
  allocator, `error` payload, Future chain, 스레드 사이 공유 메모리 · 채널, 타입이 다른 future의 `await`, 스레드 상태 조회,
  언어 차원의 SIMD, sandbox 모드. 매뉴얼에는 대신 쓰는 방법이 남는다(Cloning은 `clone` 메서드, Back references는 인덱스 · 키,
  Errors는 `Diag`, 타입 템플릿은 `MyContainer[%T]`).
- C 백엔드의 흔적: 매뉴얼 소개의 "Compilation ahead-of-time to C"와 `extern`의 "static or runtime binding"을 고쳤다.
  `MEMORY.md`, `project_direction.md`, `project_coroutines.md`, `docs/study`의 해당 줄에 삭제 사실을 덧붙였다.

## 수 피연산자의 대칭 변환 (2026-11-24)

산술 연산자와 비교에서 정수와 float를 어느 순서로 써도 된다. 결정과 구현은 `docs/decisions/project_number_operands.md`,
계기는 Julia 검토(`docs/study/11-design-principles-review.md` 3.4 B).

- `i * f`가 `f * i`와 같다. 전에는 'Expected `int`, found `float`.' 오류였다. `+ - * / % **`와 `< <= > >= == !=`에 적용된다.
  정수가 float 피연산자의 타입으로 변환되고 결과는 float다. `i * 2.5`, `i < 7.5`, `i == 7.0`도 된다.
- `f32`와 `float`를 섞으면 어느 순서든 `float`다. 비교에서는 폭이 다른 정수도 왼쪽이 넓혀진다(`i8 < int`).
- 결과는 정수로 되돌아가지 않는다. `i += f`, `var n int = i * f`는 'Expected type `int`, got `float`.' 오류다. `int(i * f)`로 쓴다.
- 두 정수의 나눗셈은 그대로 정수 나눗셈이다(`i / 2`). 비트 연산자는 정수만 받는다(`i && f`는 전과 같은 오류).
- 컴파일 타임 평가도 같은 규칙이다. `const r = k * 2.5`가 된다. float의 컴파일 타임 연산은 여전히 `*`뿐이다.
- 호환성(전에 틀린 값을 내던 코드가 오류나 다른 값이 된다):
  - `f + 'abc'`, `f * true`처럼 왼쪽이 float이고 오른쪽이 수가 아닌 산술이 컴파일 오류가 됐다('Expected `float`, found `str`.').
    전에는 오른쪽의 비트를 float로 읽은 값이 나왔다(F-196).
  - `f32 op float`의 결과가 바뀐다. `var g f32 = 1.5`, `f := 2.5`에서 `g * f`는 `0.0`이 아니라 `3.75`(`float`)다.
    `g += f`는 아무 일도 하지 않던 것이 'Expected type `f32`, got `float`.' 오류가 됐다(F-196).
  - `const r = 2.5 * k`(정수 상수 `k`)가 비정규 수 대신 맞는 값을 낸다(F-197).
- 매뉴얼: Arithmetic operators · Comparison operators · Implicit casts · Inline evaluation 절. 에이전트 안내의 정수 · float 항목과
  오류 문구 둘.
- 하지 않은 것: 사용자 타입 연산자의 양쪽 조회(`2.0 * v`), 컴파일 타임의 float 연산 확장.
- 확인: 14단계 검증에서 1~8 · 13 · 14단계 rc=0. 9~12단계(wasm 실행)는 세션 컨테이너에 `wasmtime` 실행 파일이 없어 Python `wasmtime`
  패키지로 같은 wasm 파일을 돌렸고 넷 다 통과했다(behavior 820개, cli 13개, lib 181개, trace 15개).

## `os.cmd`: 명령을 값으로 (2026-11-24)

외부 프로그램을 파이프 · 작업 디렉터리 · 환경 변수 · stdin과 함께 돌린다. shell을 거치지 않는다. 결정과 구현은
`docs/decisions/project_os_cmd.md`, 계기는 Julia 검토(`docs/study/11-design-principles-review.md` 3.4 A).

- `os.cmd(args)`가 `Cmd` 값을 만든다. `pipe(next)` · `dir(path)` · `env(name, value)` · `stdin(text)`는 새 `Cmd`를 돌려주고,
  `run()` · `read()` · `run_status()`를 부를 때 시작한다.
  - `run() -> !void`: 출력이 이 프로세스의 stdout · stderr로 간다.
  - `read() -> !str`: 마지막 프로그램의 stdout.
  - `run_status() -> !ExecResult`: stdout, 모든 프로그램의 stderr, 종료 코드. 0이 아닌 코드가 오류가 아니다.
- 실패한 종료는 `run` · `read`에서 `error.ExitStatus`다. 파이프라인은 어느 프로그램이든 실패하면 실패이고, 다음 프로그램이 입력을
  닫아 끝난 프로그램(`yes | head -1`의 `yes`)은 성공이다. `run_status`의 `code`는 실패한 것 가운데 마지막 프로그램의 코드, 신호는
  128 + 신호 번호다.
- 시작하지 못한 프로그램은 오류 값이다: `error.NotFound` · `error.PermissionDenied` · `error.InvalidArgument` 등 OS 오류의 표준 이름.
- 잡는 출력은 stdout · stderr 각각 10 MiB까지(`error.TooBig`), 파이프라인은 16개까지다.
- 호환성:
  - `os.exec`와 `os.cmd`의 자식이 `os.set_env`로 정한 변수를 받는다. 전에는 받지 못했다(F-198). 변수를 정해 놓고 자식에게는
    안 보이기를 기대한 스크립트가 있다면 달라진다.
  - `os.exec`는 그대로다(반환 타입, 시작 실패의 panic). 문서 주석의 "Runs a shell command"만 고쳤다. shell은 전에도 거치지 않았다.
- 매뉴얼: Builtin modules의 Running programs 절. 에이전트 안내의 `os` 항목. `docs/api.json`.
- 확인 못 한 것: macOS · Windows에서의 실행. 세 대상 모두 교차 컴파일은 된다. 테스트는 POSIX 프로그램을 써서 Windows에서는
  본문을 건너뛴다.
- 하지 않은 것: 파일 리다이렉션, 줄 단위 스트리밍, 실행 중 중단 · 시간 제한.
- 확인: 14단계 검증 rc=0(9~12단계는 Python `wasmtime` 패키지로 만든 `wasmtime` 대역으로 실행).

## REPL 조회 명령 `.doc` · `.which` · `.bc` (2026-11-24)

REPL에서 문서, 호출이 고르는 함수, 바이트코드를 본다. 결정과 구현은 `docs/decisions/project_repl_commands.md`, 계기는 Julia
검토(`docs/study/11-design-principles-review.md` 3.4 E).

- `.help`: 명령 목록. 시작 줄이 `Commands: .exit, .help`가 됐다.
- `.doc [topic]`: `cyber doc`이 찍는 것(`.doc optionals`, `.doc --list`, `.doc --api os`). CLI의 REPL에만 있다.
- `.which <expr>`: 식을 세션에 대해 컴파일만 하고, 가장 바깥 호출이 고른 함수의 선언 첫 줄 · 템플릿 인스턴스 · 오버로드 수 ·
  선언 위치 · `--|` 문서 주석을 보여 준다. 호출이 없으면 끝의 이름이 무엇인지. 아무것도 실행하지 않는다.
- `.bc <function>`: 그 이름의 컴파일된 함수(오버로드, 템플릿 인스턴스 전부)의 바이트코드.
- 명령은 입력이 시작하는 자리에서만 읽는다. 블록 안에서는 전처럼 코드의 한 줄이다.
- 스크립트용: `cy.VM.which(code) -> str`, `cy.VM.bytecode(name) -> str`, `cy.repl(read_line, doc)` 오버로드, `cli.repl_doc(query)`.
- 호환성: 줄 맨 앞의 `.help`, `.doc ...`, `.which ...`, `.bc ...`가 REPL에서 코드로 평가되지 않는다. 전에는 컴파일 오류였다.
- 매뉴얼: REPL 장의 REPL commands 절. `docs/api.json`.
- 작업 중 찾은 기존 결함: 세션에서 앞 입력의 타입에 메서드를 선언하면 호스트가 죽는다(F-199, 아래 절에서 고침), CLI의 REPL에서
  `use os`가 실패한다(F-200, 고치지 않음).
- 확인: 14단계 검증 rc=0(9~12단계는 Python `wasmtime` 패키지로 만든 `wasmtime` 대역으로 실행).

## PR #12 리뷰에서 나온 수정 (2026-11-24)

위 세 절(수 피연산자, `os.cmd`, REPL 명령)을 묶은 PR의 코드 리뷰 10건. 릴리스 전의 변경이라 사용자에게는 위 절들의 최종 동작만 보인다.

- 수 피연산자: 왼쪽 변환을 수 타입으로 좁혔다. `symbol` · `error`(distinct raw)는 변환하지 않고, 비교에서 부호 있는 정수는 raw
  타입으로 변환하지 않는다(`i8 < r64`는 타입 오류). 처음 꼴에서는 `-1 < r64(5)`가 `false`, `symbol.a * 2.5`가 `125.0`이었다.
- 호환성: `symbol` · `error`가 float 자리에서 수로 변환되지 않는다(F-201). 0.4.19에서는 `2.5 * symbol.a`가 `125.0`,
  `var f float = symbol.a`가 통과했다. 이제 'Expected `float`, found `symbol`.' 타입 오류다.
- `os.cmd`: 입력 글이 있는 명령이 출력 한도를 넘는 등 시작 뒤에 실패하면 멈추던 것을 고쳤다. Windows에서는 환경 map을 만들지
  않아 `os.exec`의 Windows 경로가 0.4.19와 같다. `a.pipe(b)`가 `b`의 입력 글을 쓰지 않는다고 문서에 적었다.
- `os.cmd`: `yes | head -1` 꼴의 파이프라인이 `error.ExitStatus`가 되는 길 둘을 막았다(PR의 macOS CI에서 드러남). 이 프로세스가
  `SIGPIPE`를 무시하면 자식도 물려받으므로, 파이프라인을 시작하기 전에 무시를 아무 일도 하지 않는 핸들러로 바꾼다. 그리고
  입력 글을 쓰는 스레드가 macOS에서 프로세스 전체의 신호 mask를 바꾸던 것을 고쳤다(`sigprocmask` 대신 그 파이프의
  `F_SETNOSIGPIPE`, 다른 POSIX는 `pthread_sigmask`).
- `.which`: 선언 위치를 uri가 아니라 청크로 찾는다. 세션의 뒤 eval에서 선언한 함수의 줄 번호가 맞다.
- 문서: 컴파일 타임의 `==` · `!=`는 정수와 float를 섞지 못한다고 고쳤다. `semaRightOperand`의 문서 주석 자리.
- 테스트: `core/number_signed_raw_compare_error.cy` · `symbol_op_float_error.cy` · `float_op_symbol_error.cy` ·
  `error_eq_float_error.cy`, `modules/os_cmd.cy`(입력 중의 `TooBig`, 파이프 뒤 명령의 입력, `pwd -P`), `modules/cy.cy`(뒤 eval의 위치).

## 세션의 뒤 입력이 앞 입력의 타입에 메서드를 선언한다 (2026-11-24, F-199 · F-202)

`persist_main` 세션(REPL, `cy.VM`, 임베딩 호스트)에서 앞 입력이 선언한 타입에 뒤 입력이 메서드나 타입 함수를 선언하면 호스트
프로세스가 죽었다(`module.reserveFunc`의 'attempt to use null value'). 이제 같은 소스에서 선언한 것처럼 동작한다. 결정과 구현은
`docs/decisions/project_session_methods.md`.

- 받는 선언: 메서드(`fn (&V) twice()`), 타입 함수(`fn V :: make()`), 타입의 상수 · 함수 템플릿, 템플릿 타입의 멤버
  (`fn (&Box[]) get() -> T`). struct · enum · choice 타입.
- 매개변수 타입이 다른 같은 이름은 오버로드로 더한다. 같은 시그니처는 한 소스에서와 같은 오류다
  ('`twice` has already been declared with the same function signature.'). 메서드를 바꾸려면 타입을 다시 선언한다.
- 템플릿 타입: 새 메서드와 새 오버로드가 앞 입력이 만든 인스턴스(`Box[int]`)에도 생긴다.
- 실패한 입력과 `cl_vm_validate` · `.which`는 타입에 아무것도 남기지 않는다. 같은 선언을 다시 넣을 수 있다.
- 새 컴파일 오류(전에는 모두 호스트 panic):
  - 'Can not declare `@deinit` for `V` after the input that declares `V`. ...': `@deinit` · `@copy` · `@clone` · `@send`는 타입과
    같은 입력에 선언한다. 앞서 컴파일된 코드가 그것 없이 값을 없애고 복사하고 보내기 때문이다.
  - 'Can not declare `twice` for `V`: `V` belongs to another module. ...': 다른 모듈 타입의 `use` 별칭, 모듈 이름. 한 소스에서도 같다.
  - 'Can not declare `bar` for `foo`: `foo` is not a type. ...': 부모가 함수 · 전역 · 상수. 한 소스에서도 같다.
- `cl_vm_validate`와 `.which`가 eval이 받는 소스를 거절하던 것을 고쳤다(F-202): 세션의 uri가 `main`이 아니면 앞 eval 타입의 `-`
  필드를 읽는 소스가 'Can not access the private field'였다. `persist_main` 컴파일의 main 청크들은 uri와 상관없이 한 모듈이다.
- 호환성: 전에 컴파일되던 소스 중 달라지는 것은 없다(위의 경우는 모두 panic이었다). 세션의 eval마다 다른 uri를 주는 호스트는
  앞 eval의 `-` 심볼이 뒤 eval에서 보이게 된다(매뉴얼이 적은 대로).
- 한계: CLI의 REPL은 타입 블록이 한 입력이라 `@deinit` 등 네 메서드를 가진 타입은 여전히 REPL에서 선언할 수 없다(스크립트와
  호스트는 한 소스에 함께 넣는다). 템플릿 인스턴스는 전개할 때 찾은 것을 갖고 있다(`meta.has_decl(T, 'twice')`로 갈래를 고른 인스턴스는 뒤에 생긴 `twice`를
  보지 못한다). 템플릿 메서드의 중복 선언은 어떤 인스턴스도 그 이름을 쓰지 않았으면 다음 사용에서 드러난다.
- 매뉴얼: Methods 절(모듈 규칙), REPL 장, `cl_vm_validate` 절, 가시성 절.
- 확인: 14단계 검증 rc=0(9~12단계는 Python `wasmtime` 패키지로 만든 `wasmtime` 대역으로 실행). 그 뒤 매뉴얼의 REPL 문장 둘만
  고쳤다.
