# REPL 조회 명령: `.doc` · `.which` · `.bc` (2026-11-24)

## 배경

REPL의 명령은 `.exit` 하나였다. 문서, 호출이 고르는 함수, 바이트코드를 보려면 REPL을 나가 `cyber doc`, `cyber compile`을
돌려야 했고, `cyber compile`은 core까지 6천 줄을 찍는다. 2단계 오버로드와 템플릿 특수화가 있는 언어에서 "이 호출은 어디로
가는가"는 자주 묻는 질문인데 답을 볼 곳이 없었다.

Julia 검토(`docs/study/11-design-principles-review.md` 3.3.6 · 3.4 E)가 Julia REPL의 도움말 모드(`?`)와 `@which` ·
`@code_lowered` 계열에서 원칙을 뽑았다. 컴파일 단계를 언어 안에서 들여다본다.

## 결정 (사용자, 2026-11-24: "E의 REPL 조회 명령도 넣자")

검토가 든 세 명령을 모두 넣고 목록을 보여 주는 `.help`를 더했다.

| 명령 | 하는 일 |
| --- | --- |
| `.help` | 명령 목록 |
| `.doc [topic]` | `cyber doc`이 찍는 것을 찍는다. `.doc optionals`, `.doc --list`, `.doc --api os` |
| `.which <expr>` | 식을 세션에 대해 컴파일만 하고, 가장 바깥 호출이 고른 함수를 보여 준다. 호출이 없으면 끝의 이름이 무엇인지 |
| `.bc <function>` | 그 이름의 컴파일된 함수의 바이트코드 |

~~~text
> fn largest(a %T, b T) -> T:
    | return if (a > b) a else b
    |
> .which largest(1.5, 2.5)
fn largest(a %T, b T) -> T
  as fn largest[float](float, float) -> float
  at eval:1:1
> xs := []int{3, 1, 2}
> .which xs.sort()
fn (&Slice[]) sort()
  one of 2 overloads
  at core:1636:1
  Sorts in ascending order with `<`. The element type needs a `<` operator.
> .bc largest
fn largest[float](float, float) -> float  (eval)
6:69 .chk_stk: ret=1, frame=9
...
~~~

### 정한 것

1. 표기는 점으로 시작하는 명령이다. 검토가 함께 든 `?name`은 넣지 않았다. REPL 명령은 이미 `.exit`처럼 점으로 시작하고,
   `?`는 옵셔널 타입의 접두라(`?int(none)`) 줄 맨 앞의 `?`가 식과 헷갈린다.
2. 명령은 입력이 시작하는 자리에서만 읽는다. 블록 안의 같은 글은 블록의 한 줄이다(그래서 컴파일 오류가 된다). 명령이 아닌
   점 시작 줄(`.red`)은 전처럼 코드다.
3. `.which`는 아무것도 실행하지 않는다. `VM.validate`가 세션의 선언과 지역을 본 채로 컴파일만 한다. 템플릿의 새 인스턴스는
   컴파일되지만(코드 생성은 `validate`의 계약이다, `project_vm_validate.md`) 검증한 소스의 선언은 다음 입력으로 넘어가지 않는다.
   컴파일 오류는 그 요약이 답이다. 세션은 그대로 이어진다.
4. `.which`가 보여 주는 것: 선언의 첫 줄, 템플릿이면 `as fn name[T](...)` 인스턴스, 오버로드가 둘 이상이면 그 수, 선언 위치
   (`uri:줄:열`), 선언 바로 위의 `--|` 문서 주석. 호출이 없으면 LSP의 hover와 같은 한 줄(`n int`, 선언의 첫 줄, 식의 타입)이다.
5. 가장 바깥 호출은 기록된 호출 가운데 범위가 가장 넓은 것이다. `sq(count())`는 `sq`다.
6. `.bc`는 이름이 같은 컴파일된 함수를 모두 찍는다(오버로드, 템플릿의 인스턴스들). 이름은 함수 이름만(`len2`) 또는 전체 덤프가
   찍는 이름(`Vec2.len2`)이다. 호출이 인스턴스를 만들기 전의 템플릿은 바이트코드가 없다.
7. `.doc`은 CLI의 REPL에만 있다. 매뉴얼은 CLI 실행 파일에 들어 있고 라이브러리에는 없다. `cy.repl(read_line)`로 띄운 REPL은
   'The manual is not available here.'라고 답하고, `cy.repl(read_line, doc)`로 호스트가 자기 문서 함수를 줄 수 있다.

### 하지 않은 것

- `?name`, Julia의 shell 모드(`;`). shell은 `os.cmd`가 맡는다.
- `.which`의 임베딩 API. 호스트는 `cl_vm_validate` 뒤 `cl_vm_symbol_at`으로 같은 정보를 이미 얻는다. 호출이 고른 함수를 돌려주는
  함수(`refs.which`의 C 꼴)는 쓰는 호스트가 생기면 더한다. 스크립트에서는 `cy.VM.which(code)` · `cy.VM.bytecode(name)`로 쓸 수 있다.
- IR 덤프(`@code_lowered`에 해당). 바이트코드 하나로 시작한다.
- REPL에서 선언한 함수의 위치는 `eval:줄:열`이다. 입력마다 uri가 같아 몇 번째 입력인지는 알 수 없다.
- 여러 줄 입력의 문서 주석만 붙는다. `--|` 줄을 한 줄 입력으로 따로 넣으면 그 줄만 컴파일되고 뒤의 선언과 이어지지 않는다.

## 구현

- `src/builtins/cy.cy`: `REPL.command(line) -> bool`이 명령을 실행하고, `REPL.read`가 입력이 시작하는 자리(`indent == 0`, 빈
  버퍼)에서 부른다. `REPL.doc_fn ?DocFn`, `cy.repl(read_line, doc)` 오버로드, `VM.which(code)` · `VM.bytecode(name)` bind.
- `src/refs.zig` `which`: `record_refs`를 켜고 `vm.validate("which", src)`를 돌린 뒤 `compiler.ref_calls`(call hierarchy가 쓰는
  기록)에서 가장 넓은 호출을 고른다. `writeFuncDesc`가 `headerLine` · `sym.writeFuncName` · `Sema.writeFuncSigStr`로 쓰고,
  `writePlace` · `writeDocComment`가 위치와 주석을 붙인다. 호출이 없으면 `refs.find`(hover의 길)다.
- `src/debug.zig` `allocFuncBytecode`: 청크마다 `buf.markers`(함수 시작 pc)를 정렬해 이름이 맞는 함수의 구간만
  `bytecode.write_inst`로 쓴다. 구간의 끝은 다음 marker 또는 main 청크의 `main_pc`다.
- `.doc`: `src/std/cli.cy`의 `repl_doc` bind → `src/cli.zig` `replDoc`이 질의를 공백으로 나눠 `cli.doc_hook`을 부른다. hook은
  `src/main.zig`가 REPL을 띄울 때 `doc_cli.main`으로 건다(`os.process_args`와 같은 방식: 라이브러리는 CLI 모듈을 import하지 못한다).

## PR 리뷰에서 고친 것 (2026-11-24, soomtong/cyber#12)

`.which`가 선언 위치와 문서 주석을 uri로 찾았다. 세션의 eval은 모두 uri가 `eval`이라 첫 eval의 소스에서 줄을 셌다.
`refs.Info.def_chunk`를 더하고 `writePlace`가 청크를 받게 했다. 테스트는 `modules/cy.cy`의 `second_later`.

## 작업 중 찾은 기존 결함 (이 작업에서는 고치지 않음)

둘 다 이 변경 전의 빌드에서도 같다. 이 작업의 범위 밖이라 고치지 않고 기록한다.
1번(F-199)은 같은 날 뒤의 작업이 고쳤다: `docs/decisions/project_session_methods.md`.

1. F-199: 세션에서 앞 입력이 선언한 타입에 뒤 입력이 메서드나 타입 함수를 선언하면 호스트 프로세스가 죽는다.
   REPL에 `type V:` 블록을 넣고 `fn (&V) twice() -> float:` 또는 `fn V :: make() -> V:`를 넣으면
   `module.reserveFunc`의 `parent.getMod().?`가 'attempt to use null value' panic이다(`compiler.reserveChunkSyms`에서 옴).
   REPL에서는 타입과 메서드를 한 입력에 넣을 수 없으므로(빈 줄이 입력을 끝낸다) REPL에서 메서드를 선언할 길이 없다.
   `persist_main` 세션을 쓰는 임베딩 호스트도 같은 길을 탄다.
2. F-200: CLI의 REPL에서 `use os`가 'Failed to load module: os'다. REPL의 VM은 `cy.VM()`으로 만든 격리된 VM이고
   CLI의 resolver · loader · user data를 받지 않는다(`UserVM_init`은 printer만 물려준다). `math` 같은 builtin만 된다.
   매뉴얼은 `cy.eval`의 새 VM이 호스트 설정을 받지 않는다고 적으므로, REPL만 물려받게 할지는 따로 정해야 한다.
   2026-11-24 고쳤다. `cy.VM()`은 격리된 채 두고 CLI가 자기 VM에 모듈을 준다(`cli.new_vm()`). 결정
   `docs/decisions/project_repl_modules.md`.

## 확인

behavior 테스트 `modules/cy.cy`에 `REPL.command`, `VM.which`(함수 · 가장 바깥 호출 · 오버로드와 문서 주석 · 템플릿 인스턴스 ·
core 메서드 · 이름 · 컴파일 오류 · 실행되지 않음 · 세션이 이어짐), `VM.bytecode`(함수 · 인스턴스 전부 · 오버로드 전부 · 없는
이름)를 넣었다. `.doc`은 CLI에서 손으로 확인했다(절, 없는 절, `--api path`, 틀린 옵션).
