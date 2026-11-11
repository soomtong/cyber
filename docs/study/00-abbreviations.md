---
aliases: [약어집, abbreviations]
tags:
  - study
  - cyber
  - glossary
---

# Cyber 소스 약어집

> 소스 파일 이름과 식별자에 나오는 약어를 풀어 쓰고, 이 저장소에서 가리키는 대상을 적는다.
> 개념 설명은 [용어집](00-glossary.md)과 각 장에 있고, 이 문서는 "이 글자가 무엇의 줄임인가"에 집중한다.
> 위치는 master e4c0347 기준이다. "유래" 열은 일반 지식이며 이 저장소의 사실이 아니다.

## 읽는 법

- 같은 약어가 모듈마다 다른 타입을 가리키는 경우가 있다. 대표가 `Cstr`다(3절).
- 약어 하나를 찾을 때는 `rg -n "pub const <이름>\b|fn <이름>\b" src`로 정의부터 본다. 정의 위 `///` 주석이 가장 정확한 설명이다.

---

## 1. 핵심 세 개: IR, cte, Cstr

### IR: Intermediate Representation (중간 표현)

| 항목 | 내용 |
| --- | --- |
| 파일 | `src/ir.zig` |
| 만드는 곳 | sema 패스(`src/sema.zig`)가 AST를 훑으면서 동시에 만든다 |
| 쓰는 곳 | 백엔드 `bc_gen`(바이트코드), `cgen`(C AOT). LLVM 백엔드는 `compiler.zig`에서 `error.TODO`이고 `llvm_gen.zig`는 `bc169c5`에서 삭제됐다 |
| 수명 | 코드젠이 소비한 직후 버려진다 |

`ir.zig` 머리 주석이 설계 의도를 직접 밝힌다. AST는 sema 결과를 담기에 맞지 않으므로, 타입 검사 · 수명 · ARC · 소멸자 같은
무거운 일은 IR 단계에서 끝내고 코드젠은 "단순 번역"만 하게 한다는 것이다. 그래서 IR에는 소스에 없는 노드가 들어간다
(관리 임시값을 지역으로 꺼내기, 값 복사, retain/release, 정적 변수 초기화, zero 값).

~~~text
source ─▶ tokenizer ─▶ parser(AST) ─▶ sema ──▶ IR ──▶ bc_gen ─▶ bytecode ─▶ VM
                                        │            └▶ cgen   ─▶ C 소스 ─▶ TCC/cc
                                        └▶ cte (컴파일 타임 평가)
~~~

- 유래: 컴파일러가 소스와 기계어 사이에 두는 표현. 대부분의 현대 컴파일러(LLVM IR, Zig AIR/ZIR, Rust MIR)가 여러 단계의 IR을 둔다.
  Cyber는 IR이 한 단계이고 트리 모양이며 SSA가 아니다.

### cte: Compile-Time Evaluation (컴파일 타임 평가기)

| 항목 | 내용 |
| --- | --- |
| 파일 | `src/cte.zig`, 연결부 `src/ct_inline.zig` |
| 진입점 | `cte.evalFunc`, `cte.evalCall` |
| 방식 | VM이 아니라 AST를 직접 도는 인터프리터. `Compiler.heap`(compile-time heap)을 쓴다 |
| 쓰이는 곳 | `#if`, `#for`, `#[consteval]`, 템플릿 인자, 타입 계산(`type.fn_ret(...)` 등) |

관련 약어:

| 약어 | 풀이 | 뜻 |
| --- | --- | --- |
| `ct` | compile time | `ct_value`, `ct_inline`, `allow_ct_sym`, `push_ct_block`. 컴파일 타임에만 존재하는 값 · 블록 |
| `rt` | runtime | `rt_id` 등. 실행 시점의 id |
| `ct_inline` | compile-time inline | cte가 계산한 값을 IR 상수로 바꿔 끼워 넣는 모듈 |
| `EvalInt` / `EvalStr` | evaluated int/str | 컴파일 타임에만 존재하는 타입 |
| `eval_ref` | evaluation reference | const eval에서 쓰는 rc 타입. 대상 플랫폼과 무관하게 항상 8바이트(`types.zig:36`) |
| `host_const_eval` | host constant evaluation | Zig로 구현해 컴파일 타임에 부르는 함수 종류 |

- 유래: Zig `comptime`, C++ `constexpr`/`consteval`, D CTFE(Compile-Time Function Execution). Cyber의 `#` 접두 구문은 Nim 매크로나
  Zig `inline for`와 비슷한 자리다.

### Cstr: Constraint (제약)

`Cstr`는 constraint의 줄임이다. 공통 뜻은 "**이 식을 처리할 때 바깥이 안쪽에 거는 조건**"이다. 그런데 모듈마다 다른 타입이다.

| 정의 위치 | 무엇을 제약하나 | 주요 필드 |
| --- | --- | --- |
| `sema.zig:3690` `sema.Cstr` | **기대 타입**과 맞춤 정책 | `target_t`(기대 타입), `reqTypeCstr`(안 맞으면 오류), `fit_target`(맞춰 변환), `use_as_borrow`, `assign_to_local`, `return_infer_error`, `allow_ct_sym` |
| `bc_gen.zig:3464` `bc_gen.Cstr` | 값을 **어느 레지스터**에 둘지 | `type: CstrType`(`simple` · `tempReg` · `localReg` · `captured` · `discard` · `none`), `data.slot.dst` |
| `cgen.zig:505` `cgen.Cstr` | (C 백엔드용 자리) | 비어 있다 |
| `cte.zig:767` `CallCstr` | cte 호출이 값을 요구하는지 | `req_value` |
| `cte.zig:826` `ExprCstr` | cte 식의 기대 타입 | `type`, `check`, `fit_target`, `match_generic_type`, `resolve_new_type` |
| `sym.zig:566` `WithCstr` | 템플릿 `with` 절의 타입 제약 | `name`, `cstr_t` |

`bc_gen.Cstr`의 `retain` 규칙은 정의 위 주석(`bc_gen.zig:3456~3463`)에 있다. 호출자가 `retain`을 요구하면 값은 RC가 +1된 상태로 와야 한다.

~~~zig
// sema 쪽: "이 식은 int여야 한다, 안 맞으면 오류"
const cstr = sema.Cstr.initRequire(int_t);   // target_t = int, reqTypeCstr = true, fit_target = true

// bc_gen 쪽: "결과를 지역 레지스터 r3에 써라"
// Cstr{ .type = .localReg, .data = .{ .slot = .{ .dst = 3 } } }
~~~

- 유래: sema의 Cstr는 양방향 타입 검사(bidirectional type checking)의 "checking mode", 즉 기대 타입을 아래로 내려보내는 기법이다.
  bc_gen의 Cstr는 레지스터 VM 코드젠에서 흔한 "destination hint"(Lua `luaK_exp2reg`의 목표 레지스터와 같은 발상)다.

---

## 2. 파일 · 모듈 이름

| 약어 | 풀이 | 파일 | 비고 |
| --- | --- | --- | --- |
| `ast` | Abstract Syntax Tree | `ast.zig` | 파서 산출물 |
| `sema` | semantic analysis | `sema.zig`, `sema_func.zig`, `sema_type.zig` | 이름 해석 · 타입 검사 · 소유권 삽입 · IR 생성 |
| `sym` | symbol | `sym.zig` | 이름 있는 모든 것의 공통 머리 |
| `bc_gen` / `bcgen` | bytecode generation | `bc_gen.zig` | IR → 바이트코드 |
| `cgen` | C (code) generation | `cgen.zig` | IR → C 소스 (AOT) |
| `dce` | Dead Code Elimination | (삭제됨) | `dce.zig`는 `enable_dce = false` 뒤의 죽은 코드라 `bc169c5`에서 지웠다. 약어는 결정 문서에 남아 있다 |
| `cte` | compile-time evaluation | `cte.zig` | 1절 |
| `ct_inline` | compile-time inline | `ct_inline.zig` | 1절 |
| `capi` | C API | `capi.zig` | `cyber.h`의 Zig 쪽 미러. 소스에서는 보통 `const C = @import("capi.zig")` |
| `lib` | library | `lib.zig` | `libcyber` 임베딩 진입점. lib 테스트는 `lib_test/` |
| `vm` | Virtual Machine | `vm.zig`, `vm.c`, `vm.h` | 인터프리터 루프는 C(`vm.c`) |
| `aot` | Ahead-Of-Time | `aot.c`, `aot.h` | C 백엔드 런타임 지원 |
| `jit` | Just-In-Time | `src/jit/` | 동작하지 않는 복사-패치 JIT. 컴파일 오류로 거절된다 |
| `ffi` | Foreign Function Interface | `os_ffi.zig`, 빌드 옵션 `-Dffi` | `zig build lib`는 FFI를 끈다 |
| `tcc` | Tiny C Compiler | `tcc_stub.zig`, `-Dtest-backend=tcc` | C 백엔드 결과를 컴파일 |
| `dynlib` | dynamic library | `dynlib.zig` | `dlopen` 계열 |
| `cli` | Command-Line Interface | `cli.zig`, `std/cli.cy` | CLI 전용 모듈 로더(`os` · `libc` · `cli`) |
| `ln` | linenoise | `ln_stub.zig` | REPL 줄 편집 라이브러리 |
| `stdx` | standard library extensions | `src/stdx/` | Zig `std` 보충 |
| `fmt` | format | `fmt.zig` | 오류 메시지 포맷. 소스에서 `const v = cy.fmt.v` |
| `cy` | Cyber | `cyber.zig`, `builtins/cy.cy` | Zig 쪽 루트 네임스페이스이자 스크립트용 `cy` 모듈 |
| `cache` | — | `cache.zig` | URL 캐시(`os.cacheUrl`) |
| `utils` / `bounded_array` | — | 같은 이름 | 범용 자료구조 (`fifo.zig`는 `a7b51ce`에서 삭제) |

---

## 3. 소스에서 자주 쓰는 짧은 별칭

파일 머리의 `const X = ...` 별칭은 한 번 익히면 모든 파일에서 같은 뜻이다.

| 별칭 | 원래 이름 | 예 |
| --- | --- | --- |
| `cy` | `@import("cyber.zig")` | `cy.Chunk`, `cy.Type` |
| `C` | `@import("capi.zig")` | `C.BackendJIT` |
| `bt` | `cy.types.BuiltinTypes` | `bt.Null`, `bt.I64`, `bt.EvalInt` |
| `v` | `cy.fmt.v` | `reportErrorFmt("... `{}`", &.{v(t)}, node)` |
| `c` (함수 인자) | 대개 `*cy.Chunk` | `fn semaOwn(c: *cy.Chunk, ...)`. `Compiler`일 때도 있으니 타입을 본다 |
| `t` (함수 인자) | 대개 `*cy.Thread` | `zAwait(t: *cy.Thread, ...)` |
| `vmc` | C 쪽 `vm.h` 선언 | `vmc.RES_SUCCESS` |

---

## 4. 식별자 안의 약어

### 4.1 컴파일러

| 약어 | 풀이 | 뜻 / 예 |
| --- | --- | --- |
| `decl` | declaration | `FuncDecl`, `declNode()` |
| `sig` | signature | `func.sig.ret`, `FuncSig` |
| `func` / `fn` | function | `funcptr_t`, `fn_ret` |
| `recv` | receiver | 메서드의 `self` 인자 |
| `expr` / `stmt` | expression / statement | `ExprResult`, `semaReturnExprStmt` |
| `lhs` / `rhs` | left/right-hand side | 이항식 양쪽 |
| `ctx` | context | `ConstEvalContext`, resolve context |
| `ret` | return | `ret_size`, `RET_GEN` |
| `tmp` | temporary | 임시 레지스터 · 임시값 |
| `idx` | index | |
| `elem` | element | `elem_t` |
| `inst` | instruction | VM 명령(`vm.h`의 `Inst* pc`). 컴파일러 쪽 템플릿 인스턴스는 `instance`로 풀어 쓴다(`cy.Instance`, `instance_cache`) |
| `cont` | continuation 또는 continue | `cont_head`(Future 대기 큐) / 루프 `continue`. 문맥으로 구분한다 |
| `opt` | option 또는 options | `?T` 타입 / 빌드 · 함수 옵션 |
| `res` | result | `ExprResult`, `CLEvalResult.res` |
| `src` / `dst` | source / destination | 레지스터 이동 |
| `_t` 접미사 | type | `target_t`, `elem_t`, `res_t`, `cstr_t` |
| `NullId` | null id | `maxInt(u32)`. 없는 id를 뜻하는 센티널(`cyber.zig:114`) |

### 4.2 VM · 런타임

| 약어 | 풀이 | 뜻 |
| --- | --- | --- |
| `pc` | program counter | 현재 명령 위치 |
| `fp` | frame pointer | 현재 호출 프레임의 시작 |
| `sp` | stack pointer | |
| `reg` | register | 레지스터 VM의 슬롯(8바이트). `reg_size`, `reg_end` |
| `rc` | reference count | |
| `ARC` | Automatic Reference Counting | 컴파일러가 retain/release를 넣는 방식 |
| `vtable` | virtual (method) table | trait 메서드 디스패치 표 |
| `chk` | check | `CHK_STK` |
| `stk` | stack | `CHK_STK` = 함수 진입 시 스택 여유 검사 |
| `dyn` | dynamic | 0.3의 동적 타입. 0.4에는 흔적만 |
| `i8`~`i64` / `r8`~`r64` / `f32`·`f64` | signed integer / **raw** integer / float | `r`은 unsigned가 아니라 "부호 비트를 해석하지 않는 raw 정수"다. `byte`는 `r8`의 별칭(`docs/docs.md:467`). `bt.R8` 등 |
| `u48` | unsigned 48-bit | `setOpArgU48`: 6바이트 피연산자에 호스트 함수 포인터를 담는다 |
| `debug sym` | debug symbol | pc → 소스 위치 표. `pushFCode`의 F는 "실패할 수 있는(failable)" 명령이라 debug sym을 붙인다는 뜻(`chunk.zig:595`) |

### 4.3 opcode (`vm.h`)

| opcode | 풀이 |
| --- | --- |
| `CHK_STK` | check stack. 함수 진입 시 스택이 모자라면 키운다 |
| `CALL_HOST` | 호스트(Zig/C) 함수 호출 |
| `CALL_TRAIT` | trait 메서드 호출(vtable) |
| `CALL_UNION` | 함수 union(클로저 등) 호출 |
| `CALL_PTR` | 함수 포인터 호출 |
| `RET_GEN` | return generator. generator 함수 호출이 본문을 실행하지 않고 `Generator`를 돌려준다 |
| `RET_Y` | return (from) yield. `yield v`가 값을 반환 슬롯에 쓰고 소비자로 돌아간다 |
| `GEN_NEXT` / `GEN_END` | generator `next()` / `end()` |
| `AWAIT` | `Future.await()`의 명령 |

### 4.4 접두사 규칙

| 접두사 | 뜻 | 예 |
| --- | --- | --- |
| `cl_` / `CL` | 임베딩 C API(`include/cyber.h`). 무엇의 줄임인지는 헤더에 적혀 있지 않다(Cyber Library로 추정) | `cl_vm_eval`, `CLVM`, `CL_AWAIT` |
| `z` / `z_` | Zig로 구현해 C(`vm.c`)에 export한 함수(`vm.zig:1133~`) | `zAwait`, `zAllocPoolObject`, `z_ret_generator` |
| `Z` | C 쪽에서 본 Zig 구조체 | `ZThread`, `ZVM` (`vm.h`) |
| `RES_` | VM 실행 결과 코드(C) | `RES_AWAIT`, `RES_INTERRUPT` |
| `@` (Cyber 소스) | 컴파일러 · 런타임 내부 함수 | `@send`, `@await_`, `@program_init` |
| `#` (Cyber 소스) | 컴파일 타임 구문 | `#if`, `#for`, `#[inline]` |
| `#[bind]` | Zig/C 구현과 연결되는 선언 | `#[bind] fn @new_thread() -> Thread` |

---

## 5. 혼동하기 쉬운 쌍

| 쌍 | 구분 |
| --- | --- |
| `sema.Cstr` vs `bc_gen.Cstr` | 타입 제약 vs 레지스터 배치 제약 |
| `cte` vs `vm` | AST 인터프리터(컴파일 중) vs 바이트코드 인터프리터(실행 중) |
| `cgen` vs `bc_gen` | C 소스 생성 vs 바이트코드 생성. 둘 다 같은 IR을 입력으로 받는다 |
| `aot` vs `jit` | 미리 C로 컴파일(동작) vs 실행 중 기계어 생성(동작 안 함) |
| `inst` vs `instance` | VM instruction(약어) vs 템플릿 instance(풀어 씀) |
| `cont` | Future continuation vs 루프 continue |
| `fiber` | 0.3의 `fiber.zig`는 `bc169c5`에서 삭제됐다. 현재 코루틴은 generator(`RET_GEN` 계열)이고 `Fiber`는 문서에만 있다 |
