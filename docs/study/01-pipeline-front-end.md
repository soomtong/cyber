---
aliases: [파이프라인 전반부, front-end, tokenizer-parser-ast]
tags:
  - study
  - cyber
  - compiler
  - tokenizer
  - parser
  - ast
---

# Day 1. 컴파일 파이프라인 지도와 프런트엔드 (Tokenizer, Parser, AST)

> 대상 소스: `src/compiler.zig`(Compiler.compile / compileInner), `src/main.zig`, `src/lib.zig`, `src/tokenizer.zig`, `src/parser.zig`, `src/ast.zig`, `src/builtins/cy.cy`(AST를 Cyber로 노출), `src/tokenizer.cy`(Cyber로 쓴 토크나이저), 보조로 `src/chunk.zig`, `src/debug.zig`
> 줄 번호는 HEAD b40531a1 기준이다. 실행 결과는 `zig-out/bin/cyber`(ReleaseSafe, 0.4.2-DEV)와 `-Dtrace=true`로 만든 트레이스 빌드 CLI로 직접 얻었다.
> 예상 학습 시간: 4시간 (읽기 1.5h / 소스 탐독 1.5h / 실습 1h)
> 선행: [00-language-tour.md](00-language-tour.md)

## 한줄 요약

소스 텍스트는 `Tokenizer`가 8바이트 토큰 배열로 한 번에 잘라 놓고(들여쓰기는 INDENT/DEDENT가 아니라 "줄 맨 앞 공백 수를 담은 indent 토큰"으로 남긴다), `Parser`가 손으로 쓴 재귀 하강 + 우선순위 상승(precedence climbing)으로 청크(파일)마다 AST를 만들며, `Compiler.compileInner`가 이 청크들을 core → 사용자 모듈 순으로 읽고 심볼 예약 → 시그니처 해석 → 본문 분석 → 바이트코드 생성 순으로 지휘한다.

## 오늘의 학습 목표

- [ ] 소스 → 토큰 → AST → 심볼/타입 → IR → 바이트코드 → VM 지도를 그리고 단계마다 담당 파일과 챕터를 말할 수 있다.
- [ ] `Compiler.compileInner`(315~531줄)의 각 단계가 왜 그 순서인지 설명할 수 있다(core 청크 우선, 숨은 `@program_init`/`@program_deinit`, 청크 목록이 순회 중 늘어나는 이유).
- [ ] 토큰 구조(8바이트), 키워드 39개, 들여쓰기 처리 방식(indent 토큰만 있고 dedent는 없음), 문자열 보간 상태기계를 설명할 수 있다.
- [ ] 파서의 문장 디스패치(`parseStatement`)와 식 파싱(우선순위 표, 결합 방향)을 읽고, 실제 우선순위가 C/JS와 다른 곳을 찾을 수 있다.
- [ ] AST 노드의 메모리 배치(앞 1바이트 타입 태그, 아레나, `cast`)와 `cy.parse`로 AST를 Cyber 코드에서 훑는 법을 안다.
- [ ] 파싱 오류를 일부러 내서 메시지/위치 형식을 읽고, 트레이스 로그를 `rg`로 거를 수 있다.
- [ ] 새 키워드/문 하나를 추가할 때 건드릴 파일과 순서를 설계할 수 있다(구현은 하지 않는다).

## 1. 왜 이것이 필요한가?

Cyber 소스를 고치는 사람이 가장 자주 만지는 곳이 프런트엔드다. 새 문법, 오류 메시지 개선, 포매터/린터/에디터 지원 모두 토큰과 AST에서 출발한다. 반대로 sema 이후 단계는 AST 노드를 입력으로 받기 때문에, 노드가 어떤 모양이고 어디서 만들어지는지 모르면 03 챕터 이후의 `c.semaExpr(node)` 같은 코드가 읽히지 않는다.

이 챕터가 해결하려는 문제는 두 가지다.

- 길 잃기: `src/`에 파일이 60개가 넘고 `sema.zig` 하나가 1만 줄이다. "이 파일을 언제, 누가 부르는가"를 `compiler.zig`의 지휘 순서로 먼저 잡아 두면 02~05 챕터를 독립적으로 읽을 수 있다.
- 관찰 수단: 컴파일러는 로그를 거의 7만 줄 쏟아 내는데, 프런트엔드(토크나이저/파서)는 로그가 사실상 없다. 그래서 토큰과 AST를 눈으로 보려면 별도의 방법(`src/tokenizer.cy`, `cy.parse`)이 필요하다. 5절이 그 방법을 실습으로 제공한다.

TS/Node 개발자에게는 `ts.createScanner` → `parseSourceFile` → binder/checker → emitter 흐름과 대응시켜 읽으면 된다(일반 지식). 차이는 두 가지다. Cyber의 토크나이저는 파서가 당겨 쓰는 방식이 아니라 전체 토큰 배열을 먼저 만든다. 그리고 emitter에 해당하는 것이 JS 텍스트가 아니라 레지스터 VM용 바이트코드다.

## 2. 근본적인 동작 원리

### 2.1 전체 파이프라인 지도

```
 .cy 소스 (UTF-8 바이트)
   │
   ▼  tokenizer.zig  Tokenizer.tokenize()            [01 챕터]
 Token[]  (8바이트 * N. indent/new_line 토큰 포함)
   │
   ▼  parser.zig     Parser.parse() -> parseRoot()   [01 챕터]
 AST  (ast.zig 노드. 청크마다 하나. 노드는 소스 바이트 오프셋 pos 를 가진다)
   │
   ▼  compiler.zig   reserveChunkSyms()              [01 지휘 / 02 챕터]
 심볼 예약: 선언 이름만 sym.zig 의 Sym 으로 등록 (type, func, global, const, use ...)
   │
   ▼  compiler.zig   resolveChunkSyms()              [02 챕터: sym/types/sema_type/template]
 시그니처 해석: 필드 타입, 함수 매개변수/반환 타입, 템플릿 확장
   │
   ▼  sema.zig       sema_program(), performChunkSema()   [03 챕터: sema/cte]
 본문 분석: 이름 해석 + 타입 검사 + 컴파일 타임 평가 -> IR (ir.zig)
   │
   ▼  bc_gen.zig     bcgen.genAll()                  [04 챕터]
 바이트코드 버퍼 (bytecode.zig. 16비트 단위 명령어, 레지스터 번호)
   │
   ▼  vm.c           execBytecode()                  [05 챕터]
 실행 (computed goto 디스패치 루프, thread.zig/heap.zig 가 헬퍼)
```

백엔드는 `compileInner`의 `switch (self.config.backend)`(`compiler.zig:494`)에서 갈라진다. 기본은 `BackendVM`(바이트코드). `-cc`/`-tcc`는 `cgen.gen`(C 코드 생성)으로 가고, `BackendJIT`는 `compile()` 맨 앞에서 "The JIT backend is not supported"로 거부된다(`compiler.zig:287-290`). 05 챕터까지는 VM 경로만 본다.

### 2.2 `src/` 파일 지도

| 단계 | 파일 (줄 수) | 역할 |
|---|---|---|
| 진입 | `main.zig`(378), `lib.zig`(724), `capi.zig`(416), `cli.zig`(784) | CLI 인자 처리, 임베딩용 C API(`cl_vm_*`), 모듈 로더/리졸버 |
| 프런트엔드 | `tokenizer.zig`(1218), `parser.zig`(4809), `ast.zig`(2097) | 이 챕터 |
| 지휘 | `compiler.zig`(1516), `chunk.zig`(932) | 단계 지휘, 청크(파일 단위 컴파일 상태) |
| 심볼/타입 | `sym.zig`(1750), `module.zig`(679), `types.zig`(1507), `sema_type.zig`(1339), `template.zig`(540) | 02 챕터 |
| 의미 분석 | `sema.zig`(10594), `sema_func.zig`(1429), `cte.zig`(2803), `ct_inline.zig`(380), `ir.zig`(1140) | 03 챕터 |
| 코드 생성 | `bc_gen.zig`(3432), `bytecode.zig`(1252) | 04 챕터 |
| 실행 | `vm.c`(1813), `vm.h`(959), `vm.zig`(1463), `thread.zig`(1274), `heap.zig`(1865), `heap_value.zig`(1169) | 05, 06 챕터 |
| 표준 | `builtins/core.cy`(4415), `builtins/core.zig`(2302), `std/*.cy` | 08 챕터 |
| 대체 백엔드 | `cgen.zig`(3187), `jit/`, `llvm_gen.zig` | C 백엔드는 실험적, JIT/LLVM은 범위 밖(`docs/decisions/project_direction.md`) |

### 2.3 `Compiler.compile`과 `compileInner`를 따라가기

`Compiler.compile`(`compiler.zig:279`)은 얇은 래퍼다. 컴파일 중 플래그(`compiling`)를 켜고, 이번 컴파일에서 새로 생긴 청크/타입의 시작 인덱스(`chunk_start`, `type_start`)를 기록한 뒤 `compileInner`를 부른다. `CompileError`가 아닌 에러는 `Error: {}` 보고로 감싼다(`compiler.zig:292-306`). 같은 `Compiler`를 REPL처럼 여러 번 쓰기 때문에 `cont`(이어서 컴파일)와 `newChunks()`(이번에 추가된 청크)라는 개념이 곳곳에 보인다.

`compileInner`(315~531줄)의 순서와 이유를 표로 정리한다.

| 순서 | 줄 | 하는 일 | 왜 이 순서인가 |
|---|---|---|---|
| 1 | 318-320 | `reserveCoreTypes`: `bt.Void`, `bt.Bool`, `bt.I8`... 33개 타입 ID를 순서대로 예약 (`!self.cont`일 때만) | Zig/C 코드가 빌트인 타입을 ID 상수(`bt.*`)로 직접 참조한다. 예약 순서가 그 상수와 어긋나면 안 되어 `std.debug.assert(id == type_id)`로 검사한다(`compiler.zig:1291-1296`) |
| 2 | 332-341 | 메인 파일 URI를 해석(`resolveModuleUri`)하고 `ensureModule`로 청크를 만든다 | 이 시점에는 파싱하지 않는다. `ensureModule2`(1114)는 `chunk_map`(URI -> 청크)에 등록하고 빈 청크만 만든다. 파일 하나는 한 번만 로드된다. 순환 `use`가 허용되는 것도 청크가 파싱보다 먼저 존재하는 이 구조와 맞물린 것으로 보인다(추정) |
| 3 | 344-350 | core 청크를 `ensureModule`로 만들고 api 청크의 `fallback_modules`에 넣는다 | 모든 모듈은 이름을 못 찾으면 core에서 찾는다(`print`, `str`, `Slice`가 `use` 없이 보이는 이유). 청크별로는 `loadChunk`가 같은 일을 한다(`compiler.zig:1092-1096`) |
| 4 | 352-391 | `cont && persist_main`: 이전 main의 해석 끝난 최상위 심볼을 새 main에 별칭으로 다시 연결 | REPL에서 선언한 함수/타입을 다음 줄에서 계속 쓰기 위한 것. 숨은 `@program_init`/`@program_deinit`은 매번 새로 만들기 때문에 건너뛴다 |
| 5 | 393-397 | core를 먼저 `loadBuiltinChunk` + `resolveChunkSyms` | sema는 `Option`, `Slice`, `Array`, `Map`, `Generator` 등의 템플릿 심볼과 `str`, `error` 같은 핵심 타입을 `c.sema.*_tmpl`, `c.sema.str_t`에 캐시해서 쓴다(`loadBuiltinChunk`, `compiler.zig:879-1050`). 사용자 코드를 하나라도 분석하기 전에 이 캐시가 채워져야 한다 |
| 6 | 399-407 | 모든 청크에 대해 `loadChunk` -> `resolveChunkSyms` | `loadChunk`가 파싱 + 심볼 예약을, `resolveChunkSyms`가 시그니처 해석을 한다. 루프 조건이 `id < self.chunks.items.len`이라 `use`가 새 청크를 추가하면 같은 루프에서 처리된다 |
| 7 | 409-423 | `main` 함수 검사: 함수여야 하고, 오버로드 1개, 매개변수 0개 | 있으면 최상위 문장이 금지된다(`sema.zig:4588-4610`의 "Body statement is not allowed when main function is declared.") |
| 8 | 425-431 | 숨은 함수 `@program_init`, `@program_deinit`을 예약하고 본문을 직접 IR로 만든다 | 전역 변수 초기화/소멸을 프로그램 시작/끝에 넣을 자리가 필요한데 소스에 대응하는 AST가 없다. `reserve_hidden_func`(762)가 가짜 `funcDecl` 노드(`pos = NullId`)를 만들고 `func.info.emitted = true`로 표시해 일반 본문 분석(`semaChunkFuncs`)이 건드리지 않게 한다 |
| 9 | 433-435 | `sema.sema_program(mainChunk, main_func)`로 프로그램 IR(`program_ir`)을 만든다 | 주석대로 "main을 먼저 생성해 템플릿을 확장"한다. main이 쓰는 함수/타입 템플릿이 이때 인스턴스가 된다. 첫 문장은 `@program_init` 호출이다(`sema.zig:4566-4568`) |
| 10 | 437-450 | 새 청크마다 `performChunkSema`: 청크 `@init` 본문 생성 후 `semaChunkFuncs` | 나머지 함수 본문을 분석한다. 전역이 있는 청크는 `emit_chunk_init_func`(701)가 전역 초기화를 의존 순서로 낸다 |
| 11 | 452-489 | 새 타입을 훑어 `with Trait` 구현 검사 | 모든 메서드가 확정된 뒤에야 "구현 안 함" 오류를 정확히 낼 수 있다 |
| 12 | 491-528 | `skip_codegen`이 아니면 백엔드별 코드 생성. VM이면 `bcgen.genAll(self)` | 결과는 `main_chunk.buf`(바이트코드 버퍼) |

`skip_codegen`이 켜지면 10~11까지만 하고 끝난다. 임베딩 API의 `cl_vm_validate`(`lib.zig:360`)가 이 경로이고, 코드를 실행하지 않고 문법/타입만 검사하고 싶은 에이전트 루프에 쓸 수 있다.

### 2.4 프런트엔드가 끼는 자리: `loadChunk`

프런트엔드는 `loadChunk`(`compiler.zig:1052-1098`) 안에서 일어난다.

```
loadChunk(c)
 ├─ pending_load_src 면 로더 콜백(compiler.loader)으로 소스 얻기
 │    · 라이브러리 기본 default_loader (compiler.zig:1449-1470): core/meta/math/cy/c/io/test 는
 │      각 모듈 bind 함수가 돌려주는 내장 소스(@embedFile, 예: core.zig:26,241)
 │    · CLI 의 cli.loader (cli.zig:173): bind 는 호스트 함수 등록용으로만 부르고
 │      소스는 mod_root 아래 .cy 파일이나 URL 에서 읽는다
 ├─ performChunkParse(c)        -> chunk.parser.parse(src)       (compiler.zig:616)
 │      Tokenizer.tokenize()  ->  Parser.parseRoot()  ->  AST
 └─ reserveChunkSyms(c)         -> 최상위 선언만 훑어 Sym 예약     (compiler.zig:1148)
```

CLI에서는 표준 모듈의 `.cy` 소스를 실행 파일에 박힌 사본이 아니라 `mod_root`(빌드 옵션 또는 실행 파일 디렉터리, `cli.zig:66-71`) 아래 `src/builtins/core.cy` 같은 경로에서 매번 읽는다(내장 사본은 임베딩용 `default_loader`가 쓴다). 에러 스택에 `zig-out/bin/src/builtins/core.cy:148:5`가 찍히는 이유다(00 챕터 참고). `build.zig:145-160`이 이 파일들을 `bin/src/` 아래에 설치한다.

`reserveChunkSyms`는 루트의 문장을 선언 종류별로 분기한다(`import_stmt`, `type_alias_decl`, `struct_decl`, `enumDecl`, `template`, `const_decl`, `global_decl`, `funcDecl` 등). 선언이 아닌 문장이 imported 모듈에 있으면 여기서 `Top level statement is not allowed from imported module.`(`compiler.zig:1240-1242`)로 거부한다. 메인 청크만 최상위 문장을 가질 수 있다.

## 3. 핵심 개념 정리

### 3.1 진입점: CLI(`main.zig`)와 라이브러리(`lib.zig`)

`main.zig`의 `main`(29-133)은 인자를 한 번 훑어 명령과 옵션을 정하고(`main.zig:56-109`), 명령에 따라 `evalPath`, `compilePath`, `repl`, `help`, `version`으로 간다. `fmt`는 `std.debug.panic("TODO: Embed src/tools/fmt.cy")`뿐이다(3.7절).

| 옵션 | 효과 | 근거 |
|---|---|---|
| `-v` | `verbose = true`. ReleaseSafe 빌드에서는 실행 전 바이트코드 덤프(`vm.zig:452`의 `C.verbose()` 분기)와 비-void `main`의 반환값 출력(`main.zig:303-308`)을 한다. 트레이스 빌드에서는 추가로 모든 단계 로그가 나온다 | `main.zig:59`, `vm.zig:452` |
| `-r` | URL import/캐시 재요청(`reload`) | `main.zig:61`, `cli.App.config.reload` |
| `-vm` / `-cc` / `-tcc` | 백엔드 선택: 바이트코드(기본) / C 컴파일 / TinyC. `-jit`는 도움말에 없고 `compile()`에서 거부된다 | `main.zig:63-70`, `compiler.zig:287` |
| `-h`, `--help` | 도움말 | `main.zig:71-74` |
| 그 외 `-xxx` | 에러 없이 무시(스크립트가 자기 옵션을 쓰도록). 트레이스 빌드만 `-stats` 인식 | `main.zig:75-83` |

`cyber file.cy a b`처럼 첫 비옵션 인자가 파일이면 `os_mod.argv_start = i`를 기억하고 멈춘다(`main.zig:96-100`). 그 뒤 인자는 스크립트의 `os.args()`로 간다.

`evalPath`(255-323)의 흐름은 다음과 같다.

```
vm_initx -> cli.init_cli(vm)         표준 모듈 표(mod_uris/mod_bindings), 로더/리졸버/프린터 설치
         -> vm_eval_path(vm, path, config{ single_run, backend, spawn_exe=true })
                └ lib.zig:320 -> VM.eval (vm.zig:421) -> Compiler.compile -> execBytecode
         -> 결과 코드: Success | ErrorPanic | ErrorCompile  -> 보고서 출력 -> exit(1)
```

`compilePath`(151-180)는 `vm_compile_path`로 컴파일만 하고 `vm_dump_bytecode`로 덤프한다(덤프는 stderr로 나간다). `repl`(182-253)은 소스 `use cli / cli.repl()`를 인메모리 청크 `main`으로 평가한다. REPL 본체는 Cyber 코드(`std/cli.cy`의 `cli.repl()` -> `builtins/cy.cy`의 `cy.repl`)다.

임베딩 API는 `lib.zig`의 `export fn cl_vm_*`다. 컴파일러 입장에서 의미 있는 것만 추리면 다음과 같다.

| 함수 | 줄 | 동작 |
|---|---|---|
| `cl_vm_eval` / `cl_vm_evalx` | 281 / 286 | 소스 문자열을 컴파일하고 실행 (`uri`는 기본 `"eval"`) |
| `cl_vm_eval_path` | 320 | 파일 경로를 컴파일하고 실행 (CLI가 사용) |
| `cl_vm_compile` / `cl_vm_compile_path` | 351 / 342 | 컴파일만 (`CompileConfig`, `skip_codegen` 포함) |
| `cl_vm_validate` | 360 | `skip_codegen`으로 파싱 + 분석까지만. 내부 테스트가 `"_ = 1 + 2"`는 성공, `"_ = 1 +"`는 `ErrorCompile`임을 확인한다(`src/lib_test/api.zig`의 "cl_vm_validate()") |
| `cl_vm_compile_error_summary` | 392 | 보고서 목록의 첫 항목만 문자열로 만든다(`reports.items[0]`) |

마지막 줄이 중요하다. 이 컴파일러는 첫 오류에서 멈추고 보고서에도 첫 항목만 노출한다(3.3절). 한 번에 여러 오류를 모아 보여 주는 에이전트 UX가 필요하면 파서 수준의 오류 복구부터 만들어야 한다.

### 3.2 Tokenizer (`tokenizer.zig`)

토크나이저는 소스 전체를 `Token` 배열로 만든다(`Tokenizer.tokenize`, 679-741). 파서는 이 배열 위에서 `peek()/advance()`만 한다. 토큰에는 텍스트가 없고 시작/끝 위치만 있다. 텍스트가 필요하면 파서가 `src[pos..end]`로 잘라 쓴다.

#### Token 구조

```zig
pub const Token = extern struct {          // tokenizer.zig:164
    head: u32,                              // 하위 8비트 = TokenType, 상위 24비트 = 시작 바이트 위치
    data: extern union { end: u32, indent: u32 },   // 끝 위치, 또는 indent 토큰의 공백/탭 수
};
```

`@sizeOf(Token) == 8`이라는 테스트가 있다(`tokenizer.zig:1212`). `pos()`는 `head >> 8`(192-194)이므로 위치는 24비트, 즉 소스가 16 MiB를 넘으면 시작 위치가 잘릴 수 있다(코드 읽기로만 확인한 추정이며 큰 파일로 재현하지 않았다). `TokenType`은 110개 값이다(`1216`의 테스트).

#### 토큰 종류

| 분류 | 토큰 |
|---|---|
| 공백 구조 | `new_line`, `indent`(줄 맨 앞 공백/탭 수), `null`(끝) |
| 식별자/리터럴 | `ident`, `at_ident`(`@x`), `dec`, `dec_u`(`5u`), `float`, `hex`, `oct`, `bin`, `string`, `sq_string`, `raw_string` 및 각 `_multi`, `err` |
| 문자열 템플릿 | `stringt`, `stringt_multi`, `stringt_part`, `stringt_expr` |
| 구두점 | `( ) { } [ ]`, `space_left_bracket`(공백 뒤의 `[`), `,` `.` `:` `;` `#` `?` `_` |
| 합성 연산자 | `:=`(colon_equal) `::`(colon2) `..` `..=` `..>` `..>=` `.!` `.?` `.*` `->` `=>` `==` `!=` `<=` `>=` `<<` `>>` `&&` `\|\|` `<>`, 별표 두 개(`double_star`, 거듭제곱) |
| 단일 연산자 | `+ - * / % ~ ^ & \| ! = < >` |
| 키워드 | 39개(아래 표) |

`+=`, `-=` 같은 복합 대입 토큰은 없다. `+`와 `=`가 따로 나오고 파서가 문장 수준에서 합친다(3.3절). `%=`와 별표 두 개 복합 대입이 안 되는 이유도 여기서 나온다.

#### 키워드 39개와 0.3 대비

`keywords` 표(`tokenizer.zig:7-47`)는 `std.StaticStringMap`이다. 테스트가 개수를 고정한다(`tt.eq(39, keywords.kvs.len)`, 1217).

```
and as begin break case const continue cstruct cunion else enum error false for fn fnsym
global if move none not or pass return scope sink struct switch trait true try type undef
use var void while with yield
```

문서(`docs/docs.md:262-286`)는 일반 키워드 23개 + "contextual" 키워드(`struct`, `enum`, `trait`, `scope`, `sink`, `void` 등)를 나누지만 토크나이저에서는 모두 똑같이 예약어 토큰이다. 다만 파서의 처리는 균일하지 않다. `scope := 1`은 `ParseError: Unknown token: scope_k`로 거부되지만 `struct := 1`과 `void := 1`은 에러 없이 통과한다(실행 확인). 파서가 `struct_k`, `void_k` 등을 식 위치에서 이름처럼 받아들이는 분기(`parseTightTermLeft`의 `.struct_k`, `.void_k`, 3528·3610줄)가 있기 때문으로 보인다(추정). `self`/`Self`는 토큰이 아니라 일반 `ident`다(`parseFuncDecl`이 메서드 수신자를 `self`라는 이름의 ident 노드로 합성한다, `parser.zig:1589-1597`).

0.3 태그의 키워드 표(`git show 0.3:src/parser.zig`의 22-55줄, 당시에는 토크나이저가 `parser.zig` 안에 있었다)와 직접 비교한 결과다. 0.3은 `await`가 주석 처리되어 31개였다.

| 구분 | 키워드 |
|---|---|
| 사라진 것 (9) | `catch` `coinit` `coresume` `coyield` `func` `import` `my` `object` `throw` |
| 생긴 것 (17) | `begin` `const` `cstruct` `cunion` `fn` `fnsym` `global` `move` `scope` `sink` `struct` `trait` `undef` `use` `void` `with` `yield` |
| 이름만 바뀐 것 | `func` -> `fn`, `import` -> `use`, `object` -> `struct`(`type X:`), `my` -> `:=` |
| 그대로 (22) | `and as break case continue else enum error false for if none not or pass return switch true try type var while` |

`docs/history/cyber_0_3_to_0_4_overview.md`의 표("사라진: await catch coinit context coresume coyield def dyn mod symbol throw")는 기준 커밋이 다르다. 그 문서는 `c992b94e`(2024-09) 대 HEAD이고 위 표는 `0.3` 태그(2023-12) 대 HEAD다. `context` `def` `dyn` `mod` `symbol`은 그 사이 구간에 생겼다 사라진 키워드다. 두 표는 모순되지 않는다. `TokenType`에는 `mod_k`가 남아 있지만 키워드 표에는 없다(`tokenizer.zig:112`, 죽은 값).

#### 들여쓰기: indent 토큰은 있고 dedent 토큰은 없다

JS/TS 파서에는 없고 Python 토크나이저에 있는 INDENT/DEDENT를 기대하기 쉬운데, Cyber는 다르다. 줄이 시작할 때(`.whitespace` 상태) 토크나이저는 연속된 공백(또는 탭) 수를 세어 `indent` 토큰 하나를 만들 뿐이다(`tokenizeIndentOne`, 630-677; 탭이면 최상위 비트를 켠다: `count | 0x80000000`, 1182). 들여쓰기가 0인 줄에는 indent 토큰이 없다. 줄이 줄어드는 것(dedent)은 토큰이 아니라 파서가 "다음 줄의 indent가 현재 블록 기준(`reqIndent`)과 같은가"를 비교해서 알아낸다.

```
소스                         토큰 열
fn add(a, b int) -> int:     fn_k ident ( ident , ident ident ) -> ident : new_line
    return a + b             indent(4) return_k ident + ident new_line
x := add(1, 2)               ident := ident ( dec , dec ) new_line       <- indent 없음 = 블록 끝
```

파서 쪽 규칙은 `parseBodyStatements`(`parser.zig:362-384`)가 한다. 블록 첫 문장의 들여쓰기가 `reqIndent`가 되고(`parseFirstChildIndent`, 387-405: 부모보다 커야 하며 아니면 "Block requires an indented child statement. Use the `pass` statement as a placeholder."), 이후 줄마다 `consumeNextLineIndent(reqIndent)`(234-287)가 다음 줄 indent가 `reqIndent`와 같으면 같은 블록의 다음 문장(`true`), 같은 종류(공백/탭)이면서 다르면 `false`(보통 블록 끝. 더 깊은 들여쓰기는 호출자가 이어서 `Unexpected indentation.`으로 거부한다)를 돌려준다. 탭과 공백이 섞이면 최상위 비트 비교(`res ^ req_indent < 0x80000000`)로 감지해 `Expected spaces for indentation.` / `Expected tabs for indentation.`을 낸다(00 챕터에서 본 메시지).

이 설계의 결과:

- 줄 이음(line continuation)은 토크나이저가 아니라 파서의 몫이다. 연산자 뒤 `new_line`은 `parseRightExpr`(`parser.zig:3173-3176`)가, 식의 맨 앞 `new_line`은 `parseExpr`(3877-3880)가 `consumeWhitespaceTokens`로 건너뛴다. 괄호/중괄호 안은 각 파싱 함수가 건너뛴다.
- 들여쓰기 규칙이 파서의 상태(`cur_indent`)에 의존한다. 그래서 `exts/tree-sitter`는 외부 scanner를 써서 같은 규칙을 흉내 낸다(3.7절).

#### 문자열, 보간, 룬, 숫자

- 따옴표 4종(`'`, `"`, 각 3중)은 모두 같은 의미이고 토큰 종류만 다르다(`sq_string`, `string`, `sq_string_multi`, `string_multi`). 백틱은 raw 문자열(`raw_string`, `raw_string_multi`)로 이스케이프/보간이 없다(`tokenizer.zig:548-563`). 단일 줄 리터럴 안의 줄바꿈은 `TokenError: Encountered new line in single line literal.`, 백틱은 `Expected raw string on a single line.`다(5절에서 확인).
- 룬(문자) 리터럴 토큰은 없다. `'a'`는 그냥 `sq_string`이고, 정수가 필요한 자리에서 sema가 코드포인트로 바꾼다(00 챕터의 `f('s')` -> 115). 파서에는 접두 식별자 + 따옴표 형태의 "특수 문자열" `c'..'`, `a'..'`, `u'..'`가 있다(`parser.zig:31-35`의 `special_strings`, 처리는 `parseTightTermWithLeft`의 `.sq_string` 분기 3378-3407). 아래처럼 쓴다.

```cy
print(a'x')
print(u'🐶')
```

```text
120
128054
```

- 보간은 상태기계다. `TokenizeState.stateT`가 `whitespace -> token -> stringt_part <-> stringt_expr -> end`로 움직인다(`tokenizer.zig:204-224`). 문자열 안에서 `%{`를 만나면(842-869) 첫 식이면 여는 따옴표를 `stringt`(또는 `stringt_multi`)로, 이어서 앞쪽 글자를 `stringt_part`로, `%{`를 `stringt_expr`로 내보내고 상태를 `.stringt_expr`로 바꾼다. 식 안에서는 일반 토큰을 만들되 `{`마다 `open_braces`를 올리고 `}`가 0일 때 `.stringt_part`로 돌아간다(321-340). 닫는 따옴표는 마지막 `stringt_part`와 `stringt` 토큰이 된다(758-770). 결과 열은 `stringt ( stringt_part stringt_expr <식 토큰> right_brace )* stringt_part stringt` 모양이고, `parseStringTemplate`(`parser.zig:846-903`)이 part와 expr가 번갈아 나오는지 검사한다. `%{}` 안의 `}`는 중괄호 개수를 세어 구분하므로 식 안에 `{...}` 초기화 리터럴을 써도 된다. 문자열 템플릿 안에 템플릿을 중첩할 수는 없다(`docs.md:653`).
- 숫자(`tokenizeNumber`, 1047-1179): 십진 `dec`, 소수점/지수는 `float`, `0x` `0o` `0b`는 각각 `hex` `oct` `bin`, 접미사 `u`는 `dec_u`. `1.`처럼 점 뒤에 숫자가 없으면 `dec`와 `dot`으로 쪼개져 `Expected ident.`가 나고, `1_000`은 지원되지 않으며(`Expected closing parenthesis.`), `0b102`는 `0b10`과 `2`로 쪼개진다(`Got dec`). 5절에서 확인했다.

#### 오류 보고

토크나이저 오류는 `reportErrorAt`(1197-1200)이 `has_error = true`로 표시하고 `reportFn` 콜백을 부른다. 컴파일러는 이 콜백(`compiler.zig:627-631`)으로 `token_err` 보고서를 만들고 `error.TokenError`를 던진다. 처리할 수 없는 문자는 `TokenError: unknown character: $ (36) at 5`(620)다. `ignoreErrors`가 켜진 토크나이저는 `err` 토큰을 내고 계속 진행하는데, 구문 강조용 모드(필드 주석 "For syntax highlighting")다. `tokenizer.zig` 밖에서 이 필드를 켜는 곳은 없다(`rg ignoreErrors src`로 확인).

### 3.3 Parser (`parser.zig`)

#### 구조: 토큰 배열 위의 재귀 하강

`Parser`(53-93)는 `tokens`(위 토큰 배열), `next_pos`(현재 토큰 인덱스), `ast`(노드 아레나), `node_stack`(임시 자식 노드 스택), `cur_indent`(현재 블록의 들여쓰기), 오류 콜백(`reportFn`, `tokenizerReportFn`)을 가진다. 청크마다 `Parser`가 하나씩 있다(`chunk.zig:60`, 초기화는 267).

```
Parser.parse (136)            토크나이저 실행 -> self.tokens
 └ parseRoot (196)            첫 줄 indent 검사 -> parseBodyStatements(0, allow_decls)
    └ parseStatement (2612)   첫 토큰으로 분기
       ├ 선언: parseTypeDecl / parseFuncDecl / parseConstDecl / parseGlobalDecl / parseUseStmt
       ├ 제어: parseIfStatement / parseSwitch / parseForStatement / parseWhileStatement / ...
       └ 나머지: parseExprOrAssignStatement (4446) -> parseExpr (3876)
```

자식 목록을 모으는 관용구가 파일 전체에 반복된다. 먼저 `const start = self.node_stack.items.len`을 기억하고 `pushNode`로 자식을 쌓은 뒤 `self.ast.dupeNodes(self.node_stack.items[start..])`로 아레나에 복사하며, `defer self.node_stack.items.len = start`로 스택을 되돌린다(`parseBodyStatements`, 362-384 참고). 선행 토큰 1개(`peek`)와 필요할 때 `peekAhead(1)`만 보며, 되돌아가기(백트래킹)는 `consumeNextLineIndent` 실패 시 `next_pos = start`로 복원하는 정도뿐이다(374-379).

#### 문장 디스패치

`parseStatement`(2612-2761)는 첫 토큰의 `switch`다. 위치를 주의해서 읽을 곳만 정리한다.

| 첫 토큰 | 처리 | 줄 |
|---|---|---|
| `ident` | 바로 뒤가 `:`이면 `Unsupported block statement.`. 아니면 식/대입 문장 | 2615-2625 |
| `#` | `#[`면 속성 + 선언(`parseAttrsDecl`), 그 외는 컴파일 타임 문(`ct_stmt`; `#if`, `#for` 등) | 2626-2645 |
| `-` | 뒤가 `type`/`fn`/`const`/`global`/`use`이면 `hidden = true`인 비공개 선언 | 2646-2679 |
| `type`, `with`, `fn` | `parseTypeDecl`(1016), `parse_with_decl`(1527), `parseFuncDecl`(1563) | 2680-2693 |
| `if`, `begin`, `try`, `case`, `switch`, `for`, `while` | 각 전용 함수 (`try`는 뒤가 `:`일 때만) | 2694-2717 |
| `use` | `parseUseStmt`(1983) | 2718 |
| `pass`, `continue`, `break`, `yield`, `return` | 토큰 노드(`passStmt` 등) 또는 단순 구조 | 2721-2744 |
| `const`, `global`, `var` | `parseConstDecl`(4222), `parseGlobalDecl`(4349), `parseVarDecl`(4272) | 2745-2753 |
| 그 외 | `parseExprOrAssignStatement`가 못 읽으면 `Unknown token: <tag>` | 2756-2760 |

`x := 값`(변수 선언)은 별도 키워드가 아니라 `parseExprOrAssignStatement`가 처리한다. 먼저 `x`를 식으로 읽은 뒤 다음 토큰이 `colon_equal`이면 `parseVarDeclInfer`로 간다(4456-4465). 이름이 식별자가 아니면 `Expected identifier for variable declaration.`다. 반면 `var x T = 값`은 `var` 키워드를 보고 `parseVarDecl`로 간다. 이 구조 때문에 `x = 1`(대입)과 `x := 1`(선언)을 같은 함수가 구분한다.

복합 대입(`+=` 등)도 같은 함수가 처리하며 꽤 독특하다(4473-4486). 토크나이저에 `+=` 토큰이 없으므로, 식을 읽다가 `+`, `-`, `*`, `/`, `~`, `||`, `&&`, `<<`, `>>` 다음에 `=`가 오면 식 파서가 연산자로 읽지 않고 멈추고(`parseExprWithLeft`의 `peekAhead(1).tag() == .equal` 검사, 4029-4031), 문장 파서가 `self.advance(); self.advance()`로 두 토큰을 버리고 `op_assign_stmt`를 만든다. 그래서 두 토큰이 붙어 있는지는 검사하지 않아 `a + = 2`도 `a += 2`와 같다(5절에서 12 확인). `%`와 별표 두 개 연산자(거듭제곱)는 그 목록에 없어 `a %= 3`은 `Expected right operand.`다.

#### 식: term -> tight term -> 이항 연산 루프

식 파싱은 세 겹이다.

1. `parseTermExpr`(3893-4008): 접두 형태를 처리한다. `as[T] x`, `move x`, `not x`, `if (c) a else b`, `fn(...)` 람다, `(...)` 그룹, `|x| 식` 추론 람다, 범위의 앞쪽 생략(`..`), 첫 식일 때의 `switch` 식.
2. `parseTightTermOpt`/`parseTightTermLeft`(3499 이후)와 `parseTightTermWithLeft`(3294-3485): 리터럴과 접두 연산자(`^` `&` `*` `-` `~` `!` `?` `%`), 그리고 후위 연산자 루프. 루프가 도는 후위 연산자는 `.이름`, `!`(Result 언랩, 뒤에 `else`가 오면 제외), `.!이름`(choice 언랩), `.?`(Option 언랩), `.*`(역참조), `[...]`(인덱스, 비어 있으면 `generic_expand`), `{...}`(`T{...}` 초기화 `init_expr`), `(...)`(호출), 접두 식별자가 붙은 특수 문자열이다.
3. `parseExprWithLeft`(4010-4215): 왼쪽 항을 받아 이항 연산자를 반복해서 읽는다. `!else`, `?else`도 여기서 처리한다. 토크나이저는 `!`와 `else`를 따로 내보내고(`bang`, `else_k`) 파서가 두 토큰을 이어 본다(4134-4182). 그래서 `x !else 0`의 공백은 의미가 없고 `x != y`는 `bang_equal` 한 토큰으로 구분된다.

이항 연산의 우선순위는 `getBinOpPrecedence`(4699-4731)에 있다.

| 우선순위 | 연산자 |
|---|---|
| 10 | `<<` `>>` |
| 9 | `&&`(비트 AND) |
| 8 | `~`(XOR), `\|\|`(비트 OR) |
| 7 | 별표 두 개(거듭제곱) |
| 6 | `*` `/` `%` |
| 5 | `+` `-` |
| 4 | `as` 캐스트(`.cast`) |
| 3 | `<` `<=` `>` `>=` `==` `!=` |
| 2 | `and` |
| 1 | `or` |
| 0 | 범위 `..` `..=` `..>` `..>=` |

구현은 클래식 Pratt(바인딩 파워 하나와 재귀 하나)와 다르다. `parseExprWithLeft`가 연산자를 읽으면 `parseRightExpr(op)`(3172)로 오른쪽 항을 받는다. `parseRightExpr2`(3186-3241)는 다음 연산자의 우선순위가 현재 연산자보다 엄격하게 크면(`right_op_prec > op_prec`) 오른쪽 안으로 더 파고들고, 같거나 작으면 돌려준다. 그래서 같은 우선순위는 모두 왼쪽 결합이다. 이 때문에 JS/Python 경험과 다른 동작이 나온다. 아래는 모두 실행으로 확인했다(5절).

| 식 | 결과 | JS/C와 다른 점 |
|---|---|---|
| 거듭제곱을 두 번 겹친 식 (5.5절 첫 줄) | 64 | 왼쪽 결합 (JS는 오른쪽 결합이라 512) |
| `1 << 2 + 1` | 5 | 시프트가 `+`보다 강하다 (C/JS는 8) |
| 음수 리터럴을 거듭제곱의 밑으로 쓴 식 (5.5절 일곱째 줄) | 4 | 단항 `-`가 거듭제곱보다 강하다 (JS는 SyntaxError, Python은 -4) |
| `1 \|\| 2 ~ 3` | 0 | 비트 OR(`\|\|`)과 XOR(`~`)이 같은 우선순위라 왼쪽부터 `(1 \|\| 2) ~ 3` (C/JS는 XOR가 더 강해 1) |
| `not false and false` | true | `not`은 뒤의 식 전체를 받는다(`parseExpr`, 3931-3941). `!false and false`는 false |

즉 `not`과 `!`는 둘 다 논리 부정이지만 우선순위가 전혀 다르다. `docs.md:290-313`의 연산자 표에서 이항 연산자의 순서(시프트 > `&&` > `\|\|`,`~` > 거듭제곱 > 곱셈류 > 덧셈류 > 비교 > `and` > `or` > 범위)는 코드와 일치한다.

#### 선언 파싱

- `type`(`parseTypeDecl`, 1016-1128): 이름과 선택적 `Parent ::`와 선택적 템플릿 `[T Any]` 뒤 토큰으로 분기한다. `enum`이면 `parseEnumDecl`(case에 타입이 하나라도 있으면 `isChoiceType = true`인 choice, 1226), `cstruct`, `cunion`, `trait`, `=`(타입 별칭: 함수 타입 `fn(...)`, `fnsym`, `#[extern] fn`, 일반 식), `const`(타입 평가 상수), `(`/`struct`/줄바꿈/`:`(struct, `(`이면 튜플), `_`(호스트가 정의하는 커스텀 타입. `core.cy`에서 `#[bind] type void _`처럼 쓴다)가 있다. 템플릿이 있으면 선언 노드를 `template` 노드로 감싼다(1122-1126).
- struct 본문(`parseStructDecl`, 1488-1526): `struct` 키워드는 생략할 수 있다. `:` 뒤 들여쓴 본문은 `with Trait` 줄들(`parseImplDecls`, 1301-1334) 다음에 필드들(`parseTypeFields`)이 온다. 필드 하나(`parseStructField`, 952-997)는 `[-]이름 [use] 타입 [= 기본값]` 형태로, `-`는 모듈 비공개(`hidden`), `use`는 타입 임베딩이다. `type P(x, y float)`처럼 `(`가 오면 튜플 필드(`parseTupleFields`)이고 `is_tuple`이 켜진다. `:`도 `(`도 없으면 멤버 없는 선언만 있는 타입이다.
- enum과 choice는 같은 `enumDecl` 노드다(`parseEnumDecl`, 1226-1271). 멤버(`parseEnumMember`, 925)는 `case 이름 [타입]`이고, 타입이 붙은 멤버가 하나라도 있으면 `isChoiceType = true`가 된다. 이 플래그를 `reserveChunkSyms`가 읽어 `reserve_choice`와 `reserve_enum` 중 하나로 보낸다(`compiler.zig:1187-1193`). 즉 enum과 choice의 구분은 문법이 아니라 멤버에 타입이 있는지로 정해진다.
- trait는 `parseTraitDecl`(1419)이 본문 없는 `fn` 선언들(`parseTraitFuncs`, 1391)만 받는다.
- `fn`(`parseFuncDecl`, 1563-1729): `fn (&T) name(...)`이면 메서드다. 수신자를 `self`라는 이름의 `func_param`으로 합성해 매개변수 맨 앞에 넣고 `sig_t = .method`로 표시한다(1570-1657). 아니면 `fn [Parent ::] name[템플릿](매개변수) -> 반환:`이다. `:` 뒤 본문이 없으면 선언만 있는 함수(`#[bind]`용)다. 본문 앞에서 `pushBlock`/`popBlock`을 해서 블록 스코프를 만든다.
- 속성 `#[...]`(`parseAttr`, 2816-2845): 이름은 `ident`여야 하고 고정 표(`parser.zig:19-29`)에 없으면 `Unknown attribute.`다. 표는 `bind`, `extern`, `reserve`, `call`, `generator`, `cond`, `unsafe`, `consteval`, `jit` 9개이고 AST의 `AttributeType`(`ast.zig:157-167`)과 같은 9개 값으로 매핑된다. `=값`이 붙을 수 있다(`#[cond=meta.system() == .macos]`). 속성 뒤에 `-`가 오면 비공개 선언이다(2866-2870).
- `use`(`parseUseStmt`, 1983-2054), `if`(`parseIfStatement`, 1926-1976; 조건 뒤 `:`면 일반 `if_stmt`, `|캡처|`면 `if_unwrap_stmt`, 아니면 `Expected colon after if condition.`), `else 조건:`(`parseElseStmt`, 1746). `else if`가 안 되는 이유는 `else` 뒤 조건 자리에서 `if`를 읽으면 `if` 식(`parseIfExpr`, 3255)으로 해석되어 `(`를 요구하기 때문이다(`Expected `(`.`).

#### 블록과 오류 복구

블록은 `parseSingleOrIndentedBodyStmts`(343-353)가 맡는다. `:` 다음 토큰이 `new_line`이 아니면 한 문장만 읽고(`parseStatement(.{ .allow_block = false })`), 아니면 줄바꿈 뒤 들여쓰기된 문장들을 읽는다. 선언(`type`, `fn`)은 `allow_decls`가 켜진 최상위 블록에서만 허용된다(`type declarations are not allowed here.`, 1018).

오류 복구는 없다. 모든 `reportError*`는 `has_error = true`로 표시하고 `reportFn`을 부른다. 컴파일러의 콜백(`compiler.zig:621-626`)은 `parse_err` 보고서를 하나 추가하고 `error.ParseError`를 돌려주며, 이 에러가 `try`로 최상위까지 전파되어 `Parser.parse`가 `has_error = true`인 결과를 돌려준다(171-186). 파일에 오류가 세 군데 있어도 첫 번째만 보고된다(5절). 보고서 목록의 첫 항목만 출력되므로(3.1절) 결과적으로 "오류 1개"가 계약이다.

### 3.4 AST (`ast.zig`)

#### 노드의 메모리 배치

AST 노드는 "아레나에서 할당한 `[타입 태그 1바이트][페이로드 구조체]`"다. `Ast.newEmptyNode`(`ast.zig:1852-1856`)를 보면 구조가 그대로 드러난다.

```zig
const slice = try self.node_alloc.alignedAlloc(u8, .@"8", @sizeOf(NodeData(node_t)) + 8);
@as(*NodeType, @ptrFromInt(@intFromPtr(slice.ptr) + 8 - 1)).* = node_t;   // 태그를 8바이트 칸의 맨 끝에
return @ptrFromInt(@intFromPtr(slice.ptr) + 8);                           // 노드 포인터 = 페이로드 시작
```

```
 아레나(8바이트 정렬)
 ┌──────────────────────────────┬───────────────────────────┐
 │ (패딩 7바이트) │ tag(1바이트) │ NodeData(node_t) 페이로드    │
 └──────────────────────────────┴───────────────────────────┘
                               ▲ *ast.Node 가 가리키는 곳 (p).  *(p - 1) 이 NodeType
```

- `Node`(`ast.zig:1044`)는 필드가 하나뿐인 불투명 구조체다. `Node.type()`은 `*(self - 1)`을 읽고(1047-1049), `cast(.binExpr)`는 같은 주소를 `*BinExpr`로 `@ptrCast`할 뿐이다(1063-1070). 타입이 틀려도 `cy.Trace`가 켜진 빌드에서만 `Expected X, found Y.` 패닉이 나고, 릴리스 빌드에서는 검사가 없다.
- `NodeData(node_t)`(914-1037)는 `NodeType` 하나당 페이로드 구조체를 대응시키는 comptime `switch`다. `NodeType`은 120개 값이다(`ast.zig:9-133`).
- 노드 ID나 풀은 없다. 노드의 정체성은 포인터다. 자식은 `*Node` 또는 `Slice(*Node)`(포인터 + 길이, `extern`용) / Zig 슬라이스다. 한 청크의 AST는 `node_alloc_handle`(`ArenaAllocator`) 하나에 몰려 있고, `clearNodes`(1834-1837)가 `reset(.retain_capacity)`로 한꺼번에 비운다. 개별 해제는 없다.
- 0.3과의 차이: 0.3의 `ast.Node`는 `NodeId = u32` 인덱스를 쓰는 고정 크기 구조체(`node_t`, `start_token`, 형제 연결용 `next`, 고정 크기 `head` 유니온)였다(`git show 0.3:src/ast.zig`, 93줄부터). 0.4는 포인터 + 타입별 페이로드로 바뀌었고 위치도 토큰 인덱스(`start_token`)가 아니라 소스 바이트 오프셋(`pos`)이다.

페이로드 구조체는 두 종류다. `BinExpr`처럼 `extern struct`인 것(C ABI 레이아웃)과 `IfStmt`처럼 일반 `struct`인 것이 섞여 있다.

```zig
pub const BinExpr = extern struct {      // ast.zig:342
    left: *Node, right: *Node, op: BinaryExprOp, op_pos: u32,
};
pub const IfStmt = struct {              // ast.zig:432
    cond: *Node align(8), stmts: []const *Node, else_blocks: []*Node, pos: u32,
};
```

이 구분은 `cy.parse`가 Cyber 코드에 AST를 노출할 때 의미가 있다. `builtins/cy.cy`의 `Node` 선택 타입에서 `bin_expr`는 `BinExpr` 페이로드를 가지지만 `if_stmt`는 `void`다(3.6절).

#### 주요 노드 종류 (120개 중)

| 분류 | NodeType |
|---|---|
| 루트/문장 | `root`, `exprStmt`, `assign_stmt`, `op_assign_stmt`, `var_decl`(`:=`/`var`), `if_stmt`, `if_unwrap_stmt`, `else_block`, `elseif_block`, `switch_stmt`, `case_stmt`, `for_range_stmt`, `for_iter_stmt`, `whileInfStmt`, `whileCondStmt`, `while_unwrap_stmt`, `begin_stmt`, `returnStmt`, `returnExprStmt`, `breakStmt`, `continueStmt`, `passStmt`, `yield_stmt`, `tryStmt`, `ct_stmt`(`#` 컴파일 타임 문) |
| 식 | `ident`, `accessExpr`, `callExpr`, `index_expr`, `binExpr`, `unary_expr`, `group`, `if_expr`, `switchExpr`, `range`, `as_expr`, `move_expr`, `borrow`(`&`), `ex_borrow`(`&&`), `ref`(`^`), `deref`(`.*`), `init_expr`(`T{...}`), `init_lit`(`{...}`), `keyValue`, `namedArg`, `lambda_expr`/`lambda_multi`/`lambda_cont` |
| 언랩 | `unwrap`(`.?`), `unwrap_choice`(`.!x`), `unwrap_res`(`!`), `unwrap_or`(`?else`), `unwrap_or_block`, `unwrap_res_or`(`!else`), `unwrap_res_or_block` |
| 리터럴 | `decLit`, `floatLit`, `hexLit`, `octLit`, `binLit`, `string_lit`, `sq_string_lit`, `raw_string_lit`(각 `_multi_lit`), `stringt`/`stringt_multi`(템플릿) + `stringt_part`/`stringt_expr`, `trueLit`, `falseLit`, `noneLit`, `undef_lit`, `error_lit`, `at_lit`(`@x`), `special_string_lit` |
| 선언 | `funcDecl`, `func_param`, `struct_decl`, `cstruct_decl`, `cunion_decl`, `enumDecl`, `enumMember`, `trait_decl`, `impl_decl`(`with`), `type_alias_decl`, `type_const_decl`, `custom_type_decl`, `const_decl`, `global_decl`, `import_stmt`(`use`), `use_alias`, `template`, `attribute` |
| 타입 식 | `option_type`(`?T`), `ptr`, `vector_type`, `generic_vector_type`, `partial_vector_type`, `slice_type`, `span_type`, `fn_type`, `fnsym_type`, `infer_param`(`%T`) |

타입도 별도 문법이 아니라 식 노드다. `?int`나 `[]int`는 `parseTermExpr`/`parseTightTermLeft`가 읽는 같은 식 파서의 산물이고(`parseOptTypeSpec`, `parser.zig:1130-1157`이 허용되는 시작 토큰만 거른다), 해석은 sema가 한다.

### 3.5 위치 정보와 오류 보고

노드마다 소스 바이트 오프셋 `pos`가 있고(`Node.pos()`는 1243번 줄부터의 큰 `switch`, 이항식처럼 왼쪽 자식에서 가져오는 것도 있다), 끝 위치는 `Node.end()`(1368)가 계산한다. 줄/열은 저장하지 않는다. 필요할 때만 `AstView.computeLinePos`(`ast.zig:1905-1922`)가 소스를 처음부터 훑으며 `\n`을 센다.

```zig
for (self.src, 0..) |ch, i| {
    if (i == pos) break;
    if (ch == '\n') { line += 1; lineStart = @intCast(i + 1); }
}
outCol.* = pos - lineStart;      // 바이트 단위 열
```

호출처는 오류 출력과 디버그 심볼 변환(`debug.zig:326,368,557`, `cgen.zig:330`)뿐이라 O(소스 크기) 비용이 문제되지 않는다. 대신 이 방식에는 두 가지 한계가 있다.

- 열이 바이트 기준이다. 한글처럼 UTF-8 3바이트 문자가 앞에 있으면 보고된 열과 눈에 보이는 열이 다르다(5절에서 `print("한글한글") 1+`가 `1:23`으로 보고되는 것을 확인했다. 문자 기준으로는 15번째 열이다).
- 컴파일 오류의 밑줄 길이는 코드포인트 수(`utf8CountCodepoints`)로 세지만, 들여 쓰는 공백 수는 바이트 수(`splatByteAll(' ', col)`)다(`debug.zig:343-348`). 소스 줄에 비ASCII 문자가 앞에 있으면 캐럿이 어긋난다.

오류는 세 종류의 `Report`(`compiler.zig:573-604`)로 모인다.

| 종류 | 출력 머리 | 위치 단위 | 생성 위치 |
|---|---|---|---|
| `token_err` | `TokenError:` | 소스 바이트 오프셋 | 토크나이저(`tokenizer.zig:1197`) |
| `parse_err` | `ParseError:` | 소스 바이트 오프셋(`^` 한 글자) | 파서(`parser.zig:2777`) |
| `compile_err` | `CompileError:` | `*ast.Node`(`^~~~` 노드 범위) | sema 이후 |

머리 모양은 `allocReportSummary`(`debug.zig:267-289`)가 정한다. 컴파일 오류는 `Report.next`로 이어진 역추적(context 보고서)을 덧붙일 수 있어 여러 곳을 가리키는 메시지가 가능하다(`struct` 순환 오류가 선언 위치를 함께 보이는 것을 5절에서 볼 수 있다).

### 3.6 프런트엔드를 Cyber 코드로 관찰하기: `cy.parse`와 `src/tokenizer.cy`

토크나이저/파서는 로그가 없으므로(`parser.zig`와 `tokenizer.zig`의 `log.tracev`는 오류 경로뿐이다) 눈으로 보려면 두 가지 도구가 있다.

- `cy.parse(src)`(`builtins/cy.cy:1170`): 파서를 그대로 돌려 AST를 `ParseResult{src, root, comments}`로 돌려준다. 문서 생성기 `docs/gen-docs.cy`가 이 API로 `.cy` 파일의 선언과 `--|` 문서 주석을 추출한다(`docs/gen-docs.cy:548`). 이 기능을 위해 `builtins/cy.zig:275`는 `parseComments = true`로 파서를 돌린다. 한계가 있다. Zig의 `NodeType` 순서와 `cy.cy`의 `Node` 선택 타입 순서가 정확히 같아야 하고(`ZNode.type()`이 태그 바이트를 곧바로 `Node.Tag`로 해석한다, `cy.cy:642-644`; 120개 모두 이름이 순서대로 대응함을 확인했다), 일부 노드의 `pos()`는 `panic: TODO pos: Node.Tag.var_decl`로 끝난다.
- `src/tokenizer.cy`(1046줄): 토크나이저의 Cyber 포팅이다. 내장된 샘플 소스를 토큰화해 `토큰이름, 위치`를 `eprint`한다. `behavior_test.zig:434`가 테스트로 돌린다. 정확한 오라클은 아니다. 예를 들어 `:`를 만나면 `colon_equal`을 내보내고도 `advance()`를 빠뜨려(`tokenizer.cy:408-409`) `=`가 `equal` 토큰으로 한 번 더 나온다. Zig 토크나이저(`tokenizer.zig:389-399`)는 `advance(t)`를 한다.

### 3.7 `cyber fmt`와 에디터 지원

`cyber fmt`는 구현이 없다. `main.zig:120-121`이 `TODO: Embed src/tools/fmt.cy`로 패닉하고 그 파일은 저장소에 없다. `git log -S'fmt.cy' -- src/main.zig`는 이 문자열이 `b751ca6c`(2025-11-21 "some updates")에서 들어왔음을 보이고, `git log --all -- src/tools/fmt.cy`는 비어 있다. 즉 포매터는 계획만 있었고 적이 없다. `src/fmt.zig`는 포매터가 아니라 Zig 쪽 문자열 보간 도우미다(파일 첫머리 주석 "This provides a simple string interpolation without comptime").

포매터를 만든다면 재료는 이미 있다. AST(노드 `pos`/`end`), 주석(`Tokenizer.parseComments` -> `ast.comments`), 그리고 Cyber에서 접근하는 `cy.parse`다. 부족한 것은 빈 줄과 원본 공백 정보인데 AST는 이를 보존하지 않는다(토큰의 `new_line`만 남는다). "형식을 보존하는 재출력"을 어떻게 할지가 설계 포인트다.

`exts/`에는 sublime, vim, vscode 지원 파일이 있고 `exts/tree-sitter`는 `src/tokenizer.zig`와 `src/parser.zig`를 기준으로 새로 쓴 grammar(`grammar.js` 839줄)다. 외부 scanner로 들여쓰기를 처리하고 생성물(`src/parser.c`)은 커밋하지 않는다. 검증 결과(저장소 `.cy` 333개 중 311개가 오류 노드 없이 파싱, 코퍼스 15건 통과)는 `docs/decisions/project_tree_sitter.md`에 기록되어 있으며 이 챕터에서 재현하지는 않았다.

### 3.8 TypeScript 대응 (일반 지식)

| Cyber | TypeScript 컴파일러 |
|---|---|
| `Tokenizer.tokenize()`가 전체 토큰 배열 생성 | `ts.createScanner`. 파서가 `nextToken()`으로 하나씩 당겨 쓰고, 템플릿/정규식/`>`는 파서가 `reScan*`으로 다시 읽는다 |
| 보간 문자열 상태기계(`stringt_part`/`stringt_expr`) | scanner의 template head/middle/tail 토큰 |
| `indent` 토큰 + 파서가 블록 판정 | JS/TS는 `{}`로 블록이라 해당 없음. Python은 tokenizer가 INDENT/DEDENT를 낸다 |
| 손으로 쓴 재귀 하강 + `getBinOpPrecedence` | `parseBinaryExpressionRest` + `getBinaryOperatorPrecedence`. TS도 precedence climbing이지만 거듭제곱 연산자만 오른쪽 결합으로 예외 처리한다 |
| 오류 1개에서 중단 | TS 파서는 누락 노드를 만들고 이어 가며 진단을 모은다 |
| 아레나 + 태그 1바이트 + 페이로드 | `ts.Node`는 JS 객체. `kind` 필드가 `SyntaxKind` |
| `pos`는 소스 바이트 오프셋 | `Node.pos`는 앞쪽 trivia(공백/주석)를 포함하고 `getStart()`가 실제 시작을 계산한다 |

## 4. 소스 읽기 지도

읽는 순서와 볼 것을 정리한다. 줄 번호는 HEAD b40531a1 기준이다.

| 순서 | 파일 | 함수/위치 | 볼 것 |
|---|---|---|---|
| 1 | `main.zig` | `main`(29), `evalPath`(255), `compilePath`(151) | 명령/옵션 해석, 결과 코드별 보고, 종료 코드 |
| 2 | `compiler.zig` | `Compiler.compile`(279), `compileInner`(315-531) | 2.3절의 표를 옆에 두고 읽는다 |
| 3 | `compiler.zig` | `loadChunk`(1052), `performChunkParse`(616), `reserveChunkSyms`(1148) | 파싱이 끼는 자리, 최상위 선언 분류 |
| 4 | `compiler.zig` | `emit_program_init_func`(731), `reserve_hidden_func`(762), `emit_program_deinit_func`(838) | AST 없이 IR을 직접 만드는 숨은 함수 |
| 5 | `tokenizer.zig` | `Token`(164), `keywords`(7), `tokenize`(679), `tokenizeOne`(305), `tokenizeIndentOne`(630) | 토큰 구조, 키워드 39개, 들여쓰기 토큰 |
| 6 | `tokenizer.zig` | `tokenizeStringOne`(744), `tokenizeNumber`(1047) | 보간 상태기계, 숫자 접두/접미 |
| 7 | `parser.zig` | `Parser.parse`(136), `parseRoot`(196), `consumeNextLineIndent`(234), `parseBodyStatements`(362) | 블록과 들여쓰기 |
| 8 | `parser.zig` | `parseStatement`(2612), `parseExprOrAssignStatement`(4446) | 문장 디스패치, `:=`/`=`/`+=` 구분 |
| 9 | `parser.zig` | `parseExpr`(3876), `parseTermExpr`(3893), `parseTightTermWithLeft`(3294), `parseExprWithLeft`(4010), `parseRightExpr2`(3186), `getBinOpPrecedence`(4699) | 식 문법과 우선순위 |
| 10 | `parser.zig` | `parseTypeDecl`(1016), `parseFuncDecl`(1563), `parseAttr`(2816) | 선언, 메서드 수신자 합성, 속성 |
| 11 | `ast.zig` | `NodeType`(9), `Node`(1044), `Ast.newEmptyNode`(1852), `computeLinePos`(1905) | 노드 배치와 위치 변환 |
| 12 | `debug.zig` | `allocReportSummary`(267), `writeUserErrorTrace2`(318) | 오류 출력 형식 |
| 13 | `builtins/cy.cy` | `parse`(1170), `Node`(46), `from_znode`(1010), `from_znode_auto`(1083) | 프런트엔드를 Cyber로 노출하는 방법 |

테스트로 문법 규칙을 확인하려면 `src/test/syntax/`(들여쓰기, 줄 이음, 탭/공백, 파싱 오류 위치)와 `src/test/vars`, `src/test/control_flow`의 `*_error.cy`를 본다. 파싱 오류 위치를 기대값으로 가진 파일은 `parse_start_error.cy`, `parse_middle_error.cy`, `parse_end_error.cy`, `tabs_spaces_error.cy` 등이다.

## 5. 실습

실험 파일은 임의의 작업 디렉터리에 만든다. 아래 명령은 모두 실제로 실행해 얻은 결과다. `cyber`는 `zig-out/bin/cyber`이고, 트레이스 로그는 `zig build -Dtrace=true --prefix <출력 디렉터리>`로 만든 CLI(아래 `cyber-trace`)로 얻는다. Debug 빌드는 `trace` 옵션이 기본으로 켜진다(`build.zig:50`).

### 5.1 컴파일 단계 로그 따라가기 (`-v`, `rg`)

3줄짜리 프로그램 `sq.cy`를 트레이스 CLI로 돌려 로그를 파일로 받는다. 출력이 7만 줄이므로 터미널에 직접 쏟지 않는다.

```cy
fn sq(x int) -> int:
    return x * x
print(sq(7))
```

```bash
$ cyber-trace -v sq.cy > sq.trace 2>&1
$ wc -l sq.trace
   72690 sq.trace
$ rg -o '^[a-z_]+:' sq.trace | sort | uniq -c | sort -rn
35215 bc_gen:
7267 cte:
6611 sema:
6261 chunk:
6243 ir:
1830 heap_value:
1404 compiler:
 293 sema_type:
   1 vm:
   1 thread:
   1 core:
```

로그는 모듈 범위(`log.scoped(.compiler)` 등)가 줄 머리에 붙는다. 프런트엔드 범위인 `tokenizer`/`parser`/`ast`는 이 표에 없다. 단계 순서를 보려면 `compiler:` 범위의 핵심 줄만 거른다(경로는 줄였다).

```bash
$ rg -n '^compiler: (chunk parse|resolve chunk syms|emit|Perform)' sq.trace
3:compiler: chunk parse: 1
28:compiler: chunk parse: 2
413:compiler: resolve chunk syms: src/builtins/core.cy
3630:compiler: chunk parse: 0
3631:compiler: resolve chunk syms: sq.cy
3639:compiler: resolve chunk syms: src/builtins/meta.cy
4445:compiler: emit @program_init.
4452:compiler: emit @program_deinit.
4459:compiler: emit program.
4485:compiler: Perform sema.
4590:compiler: emit @init.
23889:compiler: Perform codegen.
```

읽는 법과 관찰 포인트:

- 청크 번호는 `ensureModule` 순서다. 사용자 파일은 0번, core는 1번, `use meta`로 끌려 온 meta는 2번이다. 로그 순서는 `compileInner`와 같다. core가 맨 처음 파싱(3행)되고, 핵심 타입을 해석하는 도중에 `type`이 `meta.type`의 별칭이라 meta가 끌려 와 파싱된다(28행, 이 시점의 `cte:` 로그에 `accessExpr "meta.type"`이 보인다). 메인 파일은 core 해석이 끝난 뒤인 3630행에서야 파싱된다(2.3절 표의 5, 6번).
- 사용자 코드 3줄이 전체 로그의 대부분을 만드는 것이 아님도 보인다. `sema func:` 로그가 193건(`rg -c '^compiler: sema func' sq.trace`)인 것은 core의 함수가 전부가 아니라 참조된 것만 본문 분석에 들어간다는 뜻이다(메커니즘은 03 챕터에서 확인).
- `emit @program_init.`부터가 sema다. `bc_gen:` 로그는 청크 단위로 시작한다: `rg -n 'bc_gen: Perform codegen for chunk' sq.trace`는 25412행(chunk0 `sq.cy`), 25833행(chunk1 `core.cy`), 65992행(chunk2 `meta.cy`)을 보여 준다. 바이트코드 대부분(약 4만 줄)이 core 청크에서 나온다.

ReleaseSafe CLI의 `-v`는 로그 없이 바이트코드 덤프만 앞에 붙인다(`cyber -v sq.cy`가 6207줄 출력 후 `49`). 단계 로그가 필요하면 트레이스 빌드여야 한다. 런타임 트레이스(`t0@주소 .op`)도 같은 파일에 섞여 나온다(05 챕터).

### 5.2 파싱 오류를 일부러 내서 읽기

각 줄은 별도 파일로 실행한 결과다. 위치는 `줄:열`(둘 다 1부터, 열은 바이트 기준)이다.

| 소스 | 첫 줄 메시지 | 위치 | 어디서 |
|---|---|---|---|
| `print "hi"` | `ParseError: Expected end of line or file. Got string.` | 1:7 | `consumeNewLineOrEnd`(`parser.zig:2782`) |
| `foo:` + 들여쓴 `pass` | `ParseError: Unsupported block statement.` | 1:1 | `parseStatement`(2619) |
| `#[foo]` | `ParseError: Unknown attribute.` | 1:6 | `parseAttr`(2826) |
| `x := 1` 다음 줄 `  y := 2` | `ParseError: Unexpected indentation.` | 2:3 | `parseRoot`(221) |
| `if x:` 다음 줄이 들여쓰기 없음 | `ParseError: Block requires an indented child statement. Use the `pass` statement as a placeholder.` | 3:1 | `parseFirstChildIndent`(387) |
| `b := if 4 > 3 1 else 0` | `ParseError: Expected `(`.` | 1:9 | `parseIfExpr`(3259) |
| `a %= 3` | `ParseError: Expected right operand.` | 2:4 | `parseRightExpr`(3178) |
| `print(1))` | `ParseError: Expected end of line or file. Got right_paren.` | 1:9 | `consumeNewLineOrEnd` |
| `x := 0b102` | `ParseError: Expected end of line or file. Got dec.` | 1:10 | `0b10`과 `2`로 쪼개짐 |
| `s := 'abc` (닫는 따옴표 없음) | `TokenError: Encountered new line in single line literal.` | 1:10 | `tokenizeStringOne`(895) |
| `x := $5` | `TokenError: unknown character: $ (36) at 5` | 1:6 | `tokenizeOne`(620) |
| `type Node:` + `next Node` | `CompileError: Structs can not contain a circular dependency.` | 2:10 | sema (역추적 보고서가 선언 위치를 이어서 출력) |

오류 세 개가 든 파일은 첫 번째만 보고한다. `x := 1 +` / `y := (2` / `z := [3`을 넣으면 `x := 1 +`가 줄을 잇기 때문에(연산자 뒤 줄바꿈) 실제로는 `1 + y`로 읽히고 다음 `:=`에서 `Got colon_equal`이 첫 오류가 된다. 괄호 `(2`와 `[3`의 오류는 나오지 않는다.

```cy
x := 1 +
y := (2
z := [3
```

```text
ParseError: Expected end of line or file. Got colon_equal.
```

열 계산의 한계도 직접 보인다. 아래는 한글이 앞에 있는 줄이다. 오류 토큰 `1`은 글자 수로는 15번째인데 보고된 열은 바이트 수 기준 23이다.

```cy
print("한글한글") 1+
```

```text
ParseError: Expected end of line or file. Got dec.
```

(위치 줄 `...:1:23:`는 첫 줄만 비교하는 위 블록에는 나타나지 않는다. 표의 열을 참고한다.)

### 5.3 AST 훑어보기: `cy.parse`

`cy.parse`로 얻은 AST를 재귀로 출력하는 40줄짜리 덤퍼다. `a := 1 + 2 * (3 - x)`가 `1 + (2 * (3 - x))`로 묶이는 것(우선순위)과 `(...)`가 `group` 노드로 남는 것을 볼 수 있다. `exprStmt`는 페이로드가 `void`로 노출되어 자식이 안 보인다(3.4절의 `struct` vs `extern struct`).

```cy
use cy
use meta

fn dump_node(n ^cy.Node, depth int):
    pad := '  '.repeat(depth)
    tag := meta.enum_name(meta.choice_tag(n.*))
    switch n.*:
        case .ident |x|:
            print('%{pad}ident %{x.name}')
        case .dec_lit |x|:
            print('%{pad}dec_lit %{x.value}')
        case .var_decl |x|:
            print('%{pad}var_decl')
            dump_node(x.name, depth + 1)
            dump_node(x.right, depth + 1)
        case .bin_expr |x|:
            print('%{pad}bin_expr %{meta.enum_name(x.op)}')
            dump_node(x.left, depth + 1)
            dump_node(x.right, depth + 1)
        case .call_expr |x|:
            print('%{pad}call_expr')
            dump_node(x.callee, depth + 1)
            for x.args |a|:
                dump_node(a, depth + 1)
        case .group |x|:
            print('%{pad}group')
            dump_node(x.child, depth + 1)
        else:
            print('%{pad}%{tag}')

src := 'a := 1 + 2 * (3 - x)\nprint(a)\n'
res := cy.parse(src)
for res.root.?.!root.stmts |s|:
    dump_node(s, 0)
```

```text
var_decl
  ident a
  bin_expr plus
    dec_lit 1
    bin_expr star
      dec_lit 2
      group
        bin_expr minus
          dec_lit 3
          ident x
exprStmt
```

변형 과제: `case .func_decl |x|:` 분기를 추가해 `x.name`, `x.params.len()`, `x.stmts`를 찍어 보자. `FuncDecl`은 `builtins/cy.cy:875-886`에 필드가 있다. `pos()`가 필요한 노드를 만나면 `TODO pos`로 패닉할 수 있음에 주의한다.

### 5.4 토큰 훑어보기: `src/tokenizer.cy`

저장소의 `src/tokenizer.cy`를 복사해 맨 위의 ` src := ... ` 블록을 관찰하고 싶은 소스로 바꾸면 Cyber 포팅 토크나이저로 토큰열을 얻는다. 아래는 `fn add(a, b int) -> int:` 소스로 얻은 결과를 한 줄로 이은 것이다(`토큰, 시작 위치` 형식).

```
fn_k, 0  ident, 3  left_paren, 6  ident, 7  comma, 8  ident, 10  ident, 12  right_paren, 15
minus_right_angle, 17  ident, 20  colon, 23  new_line, 24  indent, 25  return_k, 29  ident, 36
plus, 38  ident, 40  new_line, 41  ident, 42  colon_equal, 44  equal, 45  ident, 47 ...
```

읽을 포인트: 위치 24의 `new_line` 다음에 위치 25의 `indent`가 한 번 나오고, 들여쓰기 없는 다음 줄(`x := ...`)은 위치 41의 `new_line` 직후 곧바로 위치 42의 `ident`다. dedent 토큰은 없다(3.2절). `colon_equal, 44` 다음에 `equal, 45`가 하나 더 나오는 것은 3.6절에서 본 포팅 버그다. Zig 토크나이저라면 `colon_equal` 하나다.

### 5.5 문법 변형 실험

우선순위와 결합 방향, 복합 대입, 줄 잇기를 고쳐 가며 확인한다. 3.3절의 표가 이 출력에서 나왔다.

```cy
print(2 ** 3 ** 2)
print(2 * 3 ** 2)
print(1 << 2 + 1)
print(1 + 2 * 3)
print(10 - 4 - 3)
print(1 || 2 ~ 3)
print(-2 ** 2)
print(not false and false)
print(!false and false)
```

```text
64
18
5
7
3
0
4
true
false
```

복합 대입이 `op` + `=` 두 토큰임을 보이는 실험이다. 공백이 있어도 `+ =`가 `+=`처럼 동작한다.

```cy
a := 10
a + = 2
a ||= 1
a <<= 1
print(a)
```

```text
26
```

```cy
a := 10
a %= 3
```

```text
ParseError: Expected right operand.
```

줄 이음은 토크나이저가 아니라 파서가 한다. 연산자로 끝나는 줄은 다음 줄로 이어진다.

```cy
x := 1 +
    2 +
    3
print(x)
```

```text
6
```

변형 과제 몇 가지:

1. 거듭제곱의 지수에 음수를 준 식과, `x := 3` 뒤에 변수 앞 단항 `-`를 밑으로 쓴 식을 실행해 보고, 단항 `-`의 처리 위치를 `parseTightTermLeft`의 `.minus` 분기(`parser.zig:3793`)에서 찾아라. (`0`과 `9`가 나온다.)
2. `else if` 대신 `else 조건:`을 쓰는 이유를 `parseElseStmt`(1746)에서 확인하라.
3. `print('%{[]int{1, 2, 3}.len()} items')`가 `3 items`로 동작하는 이유를 `open_braces`(`tokenizer.zig:208,321-340`)로 설명하라.
4. 식별자 `struct := 1`은 통과하는데 `scope := 1`은 `Unknown token: scope_k`인 이유를 `parseStatement`와 `parseTightTermLeft`의 분기 차이로 찾아라.

### 5.6 손대보기: 새 키워드/문 하나를 추가하려면 (설계만, 구현 금지)

예: 조건을 뒤집은 `if`인 `unless 조건:` 문을 추가한다고 하자(문서에 없는 가상의 기능이다). 의미는 `if not 조건:`과 같다. 핵심은 새 AST 노드를 만들지 않고 파서에서 기존 노드로 풀어 쓰는(desugar) 것이다. 그러면 sema, IR, 바이트코드 생성을 건드리지 않는다.

| 순서 | 파일 | 작업 | 근거 |
|---|---|---|---|
| 1 | `tokenizer.zig` | `TokenType`에 `unless_k` 추가(`49-162`), `keywords` 표에 `.{ "unless", .unless_k }` 추가(`7-47`) | 키워드는 이 두 곳이 전부다 |
| 2 | `tokenizer.zig` | 테스트 상수 갱신: `tt.eq(110, ...)`를 111로, `tt.eq(39, ...)`를 40으로(`1216-1217`) | 개수를 고정하는 테스트가 있다 |
| 3 | `parser.zig` | `parseStatement`(2612)에 `.unless_k => return self.parseUnlessStatement()` 분기 추가 | 문장은 첫 토큰으로 분기한다 |
| 4 | `parser.zig` | `parseUnlessStatement`를 `parseIfStatement`(1926-1976)의 일반 `:` 경로를 본떠 작성: `advance`, `parseExpr`로 조건, `:` 확인, `parseSingleOrIndentedBodyStmts`, `parseElseStmts`. 조건은 `unary_expr{ .op = .lnot, .child = cond }`로 감싼다(`not`의 생성 코드는 3931-3941). 결과는 `if_stmt` | AST에 새 노드가 필요 없다 |
| 5 | `src/test/control_flow/` | `unless.cy`(정상 동작)와 `unless_error.cy`(조건 없는 `unless:`의 오류 메시지) 추가 | 이 저장소의 명세는 테스트 파일이다 |
| 6 | `behavior_test.zig` | `test_control_flow`(392)에 `run.case("control_flow/unless.cy");` 등 두 줄 등록 | 목록에 있어야 돈다 |
| 7 | `exts/tree-sitter`, `exts/vim` 등 | 에디터 문법에 키워드 추가 | 선택 사항 |
| 8 | `docs/docs.md` | 키워드 목록(262-286) 갱신 | 문서 |

새 AST 노드가 정말 필요한 경우(예: 계획된 `defer`)에는 단계가 늘어난다.

1. `ast.zig`: `NodeType`에 값 추가(9-133). 맨 뒤가 아니라 알파벳 순서 중간에 넣으면 이후 값의 번호가 바뀐다. 페이로드 구조체를 만들고 `NodeData`(914)의 `switch`에 연결하며 `Node.pos()`(1243), `end()`(1368), `src()`(1112)의 `switch`에도 분기를 더한다.
2. `builtins/cy.cy`: `Node` 선택 타입(46-160)에 같은 위치로 `case`를 추가한다. 순서가 어긋나면 `cy.parse`가 엉뚱한 태그를 읽는다(3.6절).
3. `sema.zig`: 문장 분석 `switch`에 분기를 추가한다(03 챕터). 값이 필요하면 IR 노드(`ir.zig`)와 `bc_gen.zig`의 처리도 더한다(04 챕터).

위 설계는 읽은 코드에서 도출했고 실제로 컴파일해 보지는 않았다. 특히 4번 단계에서 `if_stmt`의 `else_blocks`와 `pos`를 어떻게 채울지는 `parseIfStatement`를 그대로 따라가면 된다는 추정이다.

## 6. 0.3 -> 0.4 변경 관점 / 설계 철학 메모

0.3 태그와 HEAD를 직접 비교한 결과다(`git show 0.3:...`).

| 항목 | 0.3 | 0.4 (HEAD) |
|---|---|---|
| 파일 구성 | 토크나이저가 `parser.zig`(4570줄) 안에 있음. `ast.zig` 684줄 | `tokenizer.zig` 1218 + `parser.zig` 4809 + `ast.zig` 2097 |
| 컴파일 지휘 | `vm_compiler.zig`(1093줄) `compileInner`: `declareImportsAndTypes` -> `declareSymbols` -> init sema -> 청크별 `performChunkSema` -> `performCodegen` | `compiler.zig`: `reserveCoreTypes` -> core 먼저 -> 청크 루프(`loadChunk`/`resolveChunkSyms`) -> 숨은 `@program_init`/`@program_deinit` -> `sema_program`(main 먼저) -> 청크별 sema -> `genAll` |
| AST 표현 | `NodeId = u32` 인덱스, 고정 크기 `Node{node_t, start_token, next, head 유니온}`, 형제는 `next` 연결 | 아레나 포인터 `*Node`, 앞 1바이트 태그 + 타입별 페이로드, 위치는 소스 바이트 오프셋 `pos` |
| 오류 | `setErrorAt`이 `lastErr` 문자열 하나를 덮어씀 | `Report` 목록(`reports`)이지만 첫 항목만 노출 |
| 키워드 | 31개 (`func` `import` `my` `object` `throw` `catch` `coinit` ...) | 39개 (`fn` `use` `struct` `trait` `with` `move` `yield` ...) |
| 보간 | `'$(name)'` | `'%{name}'` |
| 에러 처리 문법 | `throw` / `try` / `catch` 키워드 | `!`, `!else`, `?else`: 토큰 `bang` + `else_k`, `question` + `else_k` 조합 |
| CLI | `compile`, `help`, `version` (+`-jit`, `compile -pc`) | `fmt`(미구현), `-cc`/`-tcc` 추가, `-pc` 제거 |

설계 철학을 요약하면 "프런트엔드는 작고 단순하게, 의미는 sema로"다. 토크나이저는 문맥을 모르고, 파서는 한 번의 하향식 읽기로 끝나며, 이름 해석이나 타입 판단은 하지 않는다(예: `?int`, `[]int`도 그냥 식 노드). 대신 "어떤 선언이 최상위에 있는가" 같은 구조 정보는 `reserveChunkSyms`가 파서 직후에 훑는다. 그 결과 새 문법을 추가하는 작업의 80%는 `tokenizer.zig`와 `parser.zig` 안에서 끝날 수 있고(5.6절의 `unless` 설계), 나머지는 노드를 새로 만들 때만 늘어난다.

이 fork를 이어받는 관점에서 건드릴 후보는 세 가지다.

- 오류 복구와 다중 오류 보고: 코딩 에이전트는 한 번의 실행에서 가능한 한 많은 진단을 받는 것이 유리하다. `Compiler.reports`가 이미 목록이므로, 파서에서 "블록 단위 동기화"(다음 줄의 들여쓰기가 현재 블록 이하일 때까지 건너뛰기)만 도입해도 파싱 오류를 여러 개 낼 수 있다. 다만 sema는 파싱 실패한 AST를 받지 않으므로 파싱 진단 전용 모드가 필요하다(`cl_vm_validate`가 좋은 출발점).
- 위치 정보: 열을 코드포인트 수로 내고(3.5절의 두 지점), `Report`가 시작/끝 위치를 모두 갖게 하면 LSP나 에이전트 도구가 정확한 구간을 쓸 수 있다.
- 포매터: 3.7절. `cy.parse`와 주석 목록으로 Cyber 안에서 구현하는 길과, Zig에서 `ast`를 직접 순회하는 길이 있다. 이때 `cy.cy`의 `Node`에서 `void`로 숨겨진 페이로드가 걸림돌이다.

## 7. 알려진 이슈, 문서와 코드의 차이, 미완 지점

문서와 코드의 차이:

| 항목 | 문서 | 코드 |
|---|---|---|
| 일반 키워드 수 | `docs.md:263`은 `23`개라 하지만 아래 분류 목록의 항목은 22개 | 토크나이저는 39개: 목록 22 + `as` `begin` `const` `fnsym` + 문맥 키워드 8(`struct` `cstruct` `enum` `cunion` `trait` `scope` `sink` `void`) + 리터럴 5(`true` `false` `error` `none` `undef`) |
| `cyber fmt` | `main.zig`의 도움말이 "Reformat the source code."라고 소개 | 호출하면 패닉 (`main.zig:120-121`) |
| `cyber compile` 옵션 | 도움말에 "`cyber compile` options:" 제목만 있고 내용이 비어 있음(`main.zig:351`) | 0.3의 `-pc`는 사라졌고 대체 옵션은 없다 |
| 사라진 키워드(`history/cyber_0_3_to_0_4_overview.md`) | `c992b94e` 대 HEAD | `0.3` 태그 대 HEAD로는 `catch` `coinit` `coresume` `coyield` `func` `import` `my` `object` `throw`(3.2절). 기준 커밋이 달라 서로 모순은 아니다 |

코드 상의 문제점과 놀라운 점:

1. 오류 복구가 없다. 파서/토크나이저는 첫 오류에서 멈추고, 컴파일 오류 요약 API도 첫 보고서만 낸다(`lib.zig:392-400`). 오류 3개 파일이 1개만 보고하는 것을 5.2절에서 확인했다.
2. 열은 바이트 기준이고 캐럿 정렬도 바이트 수를 쓴다(5.2절의 한글 예). `computeLinePos`는 오류마다 소스를 처음부터 훑는다(`ast.zig:1905`).
3. 토큰 시작 위치는 24비트다(`tokenizer.zig:176,193`). 16 MiB 이상 소스에서 위치가 잘릴 가능성이 있다(추정).
4. `compiler.zig:560-571`의 `resolveCopyCtor`/`resolveFuncTemplate`는 호출하는 곳이 없고 존재하지 않는 `cy.generics`를 참조하는 죽은 코드다(Zig는 쓰이지 않는 함수를 컴파일하지 않아 빌드가 통과한다). 2026-11-06에 삭제했다(F-61).
5. `compileInner`의 TODO(322-324)가 말하듯 "타입/시그니처 패스"와 "함수 본문 패스"를 나누는 일은 아직 되어 있지 않다. 같은 `loadChunk` 안에서 심볼 예약과 시그니처 해석이 섞인다.
6. `src/tokenizer.cy`가 `colon_equal` 뒤 `advance()`를 빠뜨려 `=` 토큰을 중복 내보낸다(`tokenizer.cy:408-409`). 테스트가 토큰 내용을 검증하지 않아 통과한다.
7. `cy.cy`의 `Node` 선택 타입 순서가 `ast.NodeType`과 어긋나면 `cy.parse`가 조용히 잘못된 태그를 읽는다. 둘을 비교하는 테스트는 보이지 않았다(미확인: `rg`로 `NodeType`과 `cy.cy` 비교 코드를 찾지 못함). `Node.pos()`는 `var_decl` 등에서 `TODO pos` 패닉이 난다.
8. 키워드 처리가 불균일하다. `struct := 1`, `void := 1`은 통과하고 `scope := 1`은 `Unknown token: scope_k`. `TokenType.mod_k`는 키워드 표에 없는 죽은 값이다.
9. 복합 대입은 `op`와 `=`가 붙어 있는지 검사하지 않아 `a + = 2`가 동작하고, `%=`와 별표 두 개 복합 대입은 지원되지 않는다(`parser.zig:4473-4486`).
10. 파서의 `Block.vars`/`isVarDeclaredFromScope`(`parser.zig:3243`)는 변수 선언 추적용 흔적으로 보이며 현재 선언 경로에서는 쓰이지 않는다(미확인: 호출 지점을 끝까지 따라가지 않았다).

## 8. 이해도 확인 Q&A

### Q1. Cyber는 왜 INDENT/DEDENT 토큰 대신 "indent 토큰 + 파서가 블록 경계 판정" 방식을 쓰는가?

A: 코드에서 확인되는 사실은 이렇다. 토크나이저는 줄 맨 앞 공백/탭 수만 `indent` 토큰으로 남기고(`tokenizer.zig:630-677`), 블록 경계는 파서가 현재 블록의 `reqIndent`와 다음 줄의 indent를 비교해 정한다(`parser.zig:234-287`). 덕분에 한 줄 블록(`if c: stmt`), 연산자 뒤 줄 이음, `:` 뒤에 이어지는 람다 본문 같은 문맥 의존 규칙을 파서가 자기 상태(`cur_indent`)로 처리할 수 있다. 비용은 토크나이저만으로는 블록 구조를 알 수 없다는 점이고, 그래서 tree-sitter 문법은 외부 scanner가 필요했다. 왜 이렇게 설계했는지는 upstream의 설명이 없어 추정이다.

### Q2. `x !else 0`에서 `!else`가 한 토큰이 아니라 두 토큰이라는 사실이 문법에 어떤 영향을 주는가?

A: 토크나이저는 `!`를 `bang`으로, 바로 뒤가 `=`일 때만 `bang_equal`로 낸다(`tokenizer.zig:473-479`). `else`는 키워드 `else_k`다. 후위 `!`(Result 언랩)를 읽는 `parseTightTermWithLeft`는 다음 토큰이 `else_k`면 후위 연산을 멈추고(`3310-3313`), `parseExprWithLeft`가 `bang` -> `else_k`를 이어서 `!else`로 해석한다(`4134-4182`). 결과적으로 `x ! else 0`처럼 띄어 써도 같은 의미가 되고, `?else`도 마찬가지다. 문법 도구(tree-sitter, 하이라이터)는 이 두 토큰 결합을 알아야 한다.

### Q3. `compileInner`가 사용자 청크보다 core 청크를 먼저 `loadBuiltinChunk` + `resolveChunkSyms`하는 이유는?

A: sema가 core의 심볼을 `c.sema`에 캐시해 쓰기 때문이다. `Option`, `Slice`, `Array`, `Map`, `Generator`, `Future` 템플릿과 `str`, `error`, `Object` 타입, `@copy`/`@destruct`/`to_print_string` 함수가 그 예다(`compiler.zig:886-965`). 사용자 코드의 첫 식(`x := 'abc'`)을 분석하려면 `str`이 이미 해석되어 있어야 한다. 또 core는 `use meta`와 `type type = meta.type`로 meta 청크를 끌어오므로(로그 28행) 첫 로드 순서가 청크 번호(core=1, meta=2)를 정한다.

### Q4. 같은 우선순위 연산자가 모두 왼쪽 결합인 `parseRightExpr2`를 거듭제곱 연산자만 오른쪽 결합으로 바꾸려면 어디를 고치는가?

A: 이 답은 읽은 코드에서 도출한 설계이며 구현해 보지는 않았다. 결합 방향은 `parseRightExpr2`의 두 비교가 정한다. 첫째, 오른쪽 안으로 더 파고들지 결정하는 `right_op_prec > op_prec`(`parser.zig:3196`). 둘째, 이미 만든 이항식에 이어 붙일지 결정하는 `right2_op_prec > op_prec`(3224). `left_op`가 `.pow`일 때 둘 다 `>=`로 바꾸면 거듭제곱 중첩이 오른쪽부터 묶일 것이다(현재는 64, 바뀌면 512). 다만 단항 `-`와의 상호작용(현재 음수 밑의 거듭제곱은 4)과 기존 테스트의 기대값이 바뀌므로 `src/test/core/` 의 산술 테스트를 같이 확인해야 한다.

### Q5. 코딩 에이전트 환경에서 "첫 오류에서 멈춘다"는 계약은 어떤 비용을 만드는가? 어떻게 줄일 수 있는가?

A: 에이전트가 코드를 한 번 고치고 다시 실행할 때마다 오류를 하나씩만 받으므로, 오류가 n개면 n번의 왕복이 든다. 파서는 오류 시 예외 전파(`return self.reportError(...)`)로 즉시 빠져나오고(`parser.zig:2763-2780`), 컴파일러 API는 첫 보고서만 문자열로 만든다. 줄이는 방법은 (1) 파서에서 블록 단위로 건너뛰며 계속 파싱하는 동기화 도입, (2) `Compiler.reports` 전체를 요약하는 API 추가, (3) sema 단계에서도 함수 단위로 오류를 모으는 것이다. 난이도는 (2) < (1) < (3)이다. (1)과 (3)은 오류 뒤에 불완전한 AST를 하위 단계가 어떻게 다룰지 정해야 한다.

### Q6. `cy.parse`와 Zig `NodeType`의 순서 결합은 어떻게 안전하게 유지할 수 있는가?

A: 확인된 사실은 두 열거가 120개로 길이와 순서가 같고(이름 정규화 후 일대일 대응), `ZNode.type()`이 태그 바이트를 순서 그대로 `Node.Tag`로 변환한다는 점이다(`cy.cy:642-644`). 안전장치는 코드에서 찾지 못했다. 권장안은 `behavior_test`에 "Zig `std.meta.fieldNames(NodeType)`와 `cy.cy`의 `Node` 태그 이름을 정규화해 비교"하는 테스트를 추가하는 것이다(제안이며 미구현). 새 `NodeType`을 중간에 끼워 넣는 변경이 가장 위험하다.

### Q7. 한글 주석이 많은 소스에서 에러 캐럿이 어긋나는 원인과 고치는 위치는?

A: `computeLinePos`가 열을 `pos - lineStart`(바이트)로 계산하고(`ast.zig:1919`), 출력은 그 열만큼 공백을 찍는다(`debug.zig:343`과 파싱 오류용 `381`의 `splatByteAll(' ', col)`). 한글 한 글자가 3바이트라 캐럿이 오른쪽으로 밀린다. 고치려면 `col`을 `std.unicode.utf8CountCodepoints(src[lineStart..pos])`로 계산하면 된다(터미널 폭이 2칸인 전각 문자는 별도 문제이며, 이 제안은 미검증).

## 9. 더 알아보기

- 키워드: precedence climbing vs Pratt parsing, recursive descent, indentation-sensitive grammar(Python tokenizer INDENT/DEDENT), arena allocation, tagged pointer.
- 이 챕터가 남긴 이정표: 심볼 예약과 타입 해석은 [02-symbols-and-types.md](02-symbols-and-types.md), `sema_program`과 IR은 [03-sema-and-ir.md](03-sema-and-ir.md), `bcgen.genAll`은 [04-bytecode-gen.md](04-bytecode-gen.md), `execBytecode`는 [05-vm-runtime.md](05-vm-runtime.md), 모듈 로더와 `core.cy`는 [08-embedding-builtins-tests.md](08-embedding-builtins-tests.md).
- 문법 감각이 필요하면 [00-language-tour.md](00-language-tour.md)의 TS 대조표와 "자주 막히는 지점"을 다시 본다. 표의 오류 메시지가 이 챕터의 `parser.zig` 줄 번호와 일대일로 대응한다.
- 설계 기록: [project_tree_sitter.md](../decisions/project_tree_sitter.md), [project_bc_inline.md](../decisions/project_bc_inline.md), 변화 이력 [cyber_0_3_to_0_4_overview.md](../history/cyber_0_3_to_0_4_overview.md).
- 다음 날: [02-symbols-and-types.md](02-symbols-and-types.md)에서 `reserveChunkSyms`가 만든 심볼이 타입과 템플릿으로 해석되는 과정을 본다.
