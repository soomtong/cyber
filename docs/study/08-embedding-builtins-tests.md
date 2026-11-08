---
aliases: [임베딩/빌트인/테스트, libcyber 장]
tags:
  - study
  - cyber
  - embedding
  - libcyber
  - testing
---

# Day 7. 언어 바깥과 만나는 면: 임베딩, 내장 라이브러리, 테스트

> 대상 소스: src/include/cyber.h, src/capi.zig, src/lib.zig, src/vm.zig(init/eval), src/compiler.zig(로더/리졸버),
> src/sema.zig · sema_type.zig · module.zig(#[bind] 해석), src/builtins/{core.cy, core.zig, bindings.zig, cy.cy, cy.zig, c.cy, c.zig},
> src/std/ 전체, src/main.zig, src/cli.zig, src/cache.zig, build.zig, src/behavior_test.zig, src/test/ 아래 전체, examples/libcyber/, .github/workflows/
> 줄 번호는 HEAD b40531a1 기준이다. 실행 결과는 macOS arm64, Zig 0.17.0, 이 저장소의 zig-out/bin/cyber(ReleaseSafe)와
> `zig build lib -Doptimize=ReleaseFast` 로 만든 libcyber.a 에서 직접 돌린 것이다.
> 예상 학습 시간: 4시간 (읽기 1.5 / 소스 탐독 1.5 / 실습 1)
> 선행: [Day 6 오후. 코루틴과 동시성](07-coroutines-concurrency.md), 실행 루프는 [Day 5](05-vm-runtime.md), 소유권은 [Day 6 오전](06-memory-ownership.md)

## 한줄 요약

Cyber 는 "언어 바깥"과 두 가지 면에서 만난다. 하나는 호스트 프로그램이 VM 을 만들고 스크립트를 먹이는 C ABI(libcyber, `CLThread*` 스택 슬롯 규약과
`#[bind]` 선언)이고, 다른 하나는 표준 라이브러리 자체가 core.cy 라는 Cyber 소스로 매 실행마다 컴파일되며 필요한 곳만 Zig 호스트 함수에 `#[bind]` 로
연결된다는 구조다. 이 두 면을 같은 규약으로 쓰기 때문에 사용자가 `#[bind]` 로 도구를 노출하는 방식과 core.cy 가 `alloc_`, `prints_` 를 부르는 방식이 똑같다.

## 오늘의 학습 목표

- [ ] cyber.h 의 113개 선언을 영역별(VM, eval, 스레드/호스트 함수, 모듈, 값, 중단/fuel)로 나누고 `cl_vm_init` 에서 `cl_vm_eval` 까지의 내부 흐름을 말한다.
- [ ] 호스트 함수가 `#[bind] fn` 선언, `cl_mod_add_func`, CALL_HOST 스택 슬롯으로 이어지는 경로와 str/Slice 인자의 소유 규약을 설명한다.
- [ ] 같은 VM 에서 eval 을 반복할 때 `cont`, `persist_main`, `single_run`, `cl_vm_reset` 이 무엇을 보존하고 무엇을 버리는지 구분한다.
- [ ] core.cy 와 core.zig 의 역할 분담을 알고 `Array.append` 에서 `alloc_` 호스트 함수까지 따라간다.
- [ ] 모듈 resolver/loader 콜백, 내장 모듈 7종, CLI 와 라이브러리의 차이, 샌드박스 현황을 사실로 정리한다.
- [ ] 테스트 4종(behavior, lib, cli, trace)과 `--cytest` 지시자를 이해하고 새 테스트를 CLI 로 검증한다.
- [ ] 임베딩의 알려진 한계(7.4절)를 재현 방법과 함께 열거한다.

## 1. 왜 이것이 필요한가?

이 프로젝트의 최종 용도는 코딩 에이전트 루프(CodeAct 계열)의 실행 언어다. 모델이 쓴 스크립트를 한 턴씩 실행하고, 도구 호출은 호스트가 맡고,
실패해도 같은 세션을 이어 가야 한다. 이 요구는 세 가지 질문으로 쪼개진다.

1. 호스트가 VM 을 어떻게 만들고, 스크립트를 먹이고, 에러와 출력을 받고, 도구(호스트 함수)를 어떻게 꽂는가? (cyber.h, lib.zig)
2. 표준 라이브러리는 어디까지가 Cyber 이고 어디부터가 Zig 인가? 호스트 함수 규약이 사용자용과 내부용으로 갈라지지 않는가? (core.cy, core.zig)
3. 컴파일러/VM 을 고칠 때 무엇이 깨졌는지 어떻게 아는가? (behavior/lib/cli/trace 테스트와 CI)

TS/Node 개발자에게 익숙한 대응(일반 지식)을 먼저 깔아 둔다.

| Cyber | Node/TS 쪽에서 비슷한 것 | 다른 점 |
|---|---|---|
| libcyber 의 `cl_vm_init`, `cl_vm_eval` | `vm.createContext` + `vm.runInContext`, 또는 isolated-vm | Cyber VM 은 프로세스 안의 C 라이브러리이고, 컨텍스트가 곧 VM 하나다. 격리 장치(권한, 메모리 한도)는 직접 만들어야 한다 |
| `cl_vm_set_loader`, `cl_vm_set_resolver` | Node 모듈 customization hooks 의 `load`, `resolve` | 둘 다 "문자열 -> 소스" 변환이지만 Cyber 는 C 콜백이고 모듈 하나가 호스트 함수 표(`cl_mod_add_func`)를 함께 받는다 |
| core.cy 와 `#[bind]` | Node core 의 `lib/*.js` 가 `internalBinding('fs')` 같은 C++ 바인딩을 부르는 구조 | Node 는 JS 가 미리 번들/스냅샷되지만 Cyber 는 매 실행마다 core.cy 를 파싱하고 컴파일한다(5.7절 측정) |
| `--cytest: pass\|error\|panic` | Jest 의 파일 단위 스냅샷 테스트에 가깝다 | 기대값이 같은 .cy 파일 끝 주석에 들어 있고 하네스가 그 주석을 읽는다 |

이 장의 모든 사실은 소스 읽기 또는 직접 실행으로 확인한 것이다. "일반 지식", "추정", "미확인" 표시가 붙은 곳만 예외다.

## 2. 근본적인 동작 원리

### 2.1 전체 그림

```
   호스트 프로그램 (C/Zig)                              libcyber (Zig 로 작성, 인터프리터만 C)
   ─────────────────────                              ──────────────────────────────────────────
   cl_vm_init() ─────────────────────────────────────▶ VM.init: Compiler, main Thread, 심볼 표(bindCore)
   cl_vm_set_loader/resolver/printer ────────────────▶ vm.compiler.loader / resolver, vm.print 에 함수 포인터 저장
   cl_vm_evalx(uri, src, cfg, &res) ─────────────────▶ VM.eval
                                                         ├─ Compiler.compile
                                                         │    ├─ resolver(uri) -> 해석된 uri
                                                         │    ├─ loader(mod, uri) -> 소스 + cl_mod_add_func 표
                                                         │    └─ parse -> sema -> IR -> bcgen (바이트코드 버퍼)
                                                         └─ exec_bytecode -> vm.c execBytecode
   호스트 함수 CLRet f(CLThread*) ◀──────────────────── CALL_HOST 명령 (vm.c:940)
   cl_vm_error_summary(vm) ◀──────────────────────────── 컴파일 리포트 또는 panic 요약(스택 트레이스 포함)
```

핵심은 "호스트 함수 표"가 모듈 단위로 붙는다는 점이다. 스크립트에서 `use agent` 를 만나면 컴파일러가 loader 를 부르고,
loader 는 (1) 그 모듈의 `cl_mod_add_func` 로 이름 -> 함수 포인터 표를 채우고 (2) `#[bind] fn tool(...)` 선언이 담긴 소스 문자열을 돌려준다.
이어서 sema 가 소스의 `#[bind]` 선언마다 같은 이름을 표에서 찾아 연결한다.

### 2.2 cl_vm_init 에서 cl_vm_eval 까지

첫 eval 이 하는 일을 순서대로 따라가 보자.

1. 생성. `cl_vm_init` 은 `std.heap.c_allocator` 로 `VM` 을 만들고 `vm.init` 을 부른다(src/lib.zig:27-32). `VM.init`(src/vm.zig:132)은 워커 풀,
   `Compiler.init`(vm.zig:180-182), main `Thread`(184-185)를 만들고 `funcSyms` 용량을 255로 잡은 뒤 `bindCore` 로 내장 symbol 표(`.utf8`, `.little` 같은 리터럴 id)를
   미리 등록한다(vm.zig:196, src/builtins/bindings.zig:98-101). 이 시점에는 어떤 소스도 컴파일되지 않았다. 실험: 같은 프로세스에서 `cl_vm_init` 은 첫 호출 0.5~0.7ms,
   이후 호출 0.01~0.04ms 였다(5.7절).
2. 진입. `cl_vm_eval(vm, src, &res)` 는 uri `"eval"` 과 기본 설정으로 `cl_vm_evalx` 를 부르는 얇은 래퍼다(lib.zig:222-225).
   `cl_vm_evalx` 는 `vm.eval` 의 Zig 에러를 결과 코드로 번역한다.

```zig
// src/lib.zig:227-249 (발췌)
export fn cl_vm_evalx(vm: *cy.VM, uri: C.Bytes, src: C.Bytes, config: C.EvalConfig, out: *C.EvalResult) C.ResultCode {
    var res = C.Success;
    out.* = vm.eval(C.from_bytes(uri), C.from_bytes(src), config) catch |err| b: {
        switch (err) {
            error.CompileError => { res = C.ErrorCompile; },
            error.Panic => { res = C.ErrorPanic; },
            error.Interrupted => { res = C.ErrorInterrupt; },
            error.Await => { res = C.Await; },
            else => { log.tracev("{}", .{err}); res = C.ErrorUnknown; },
        }
        break :b undefined;
    };
    vm.last_res = res;
    return res;
}
```

   `vm.last_res` 가 `cl_vm_error_summary` 의 분기 근거다(lib.zig:453-461). 에러일 때 `out` 은 `undefined` 이므로 호스트는 `res.res` 를 읽으면 안 된다.
3. 컴파일. `VM.eval`(vm.zig:421-512)은 `reinitPerRun`(리포트만 비움, compiler.zig:260)을 부르고 `CompileConfig` 를 채워
   `Compiler.compile`(compiler.zig:279)로 넘긴다. `compileInner`(compiler.zig:315-531)의 순서는 다음과 같다.
   - `!cont` 이면 `reserveCoreTypes`(compiler.zig:318-320).
   - main uri 를 `resolveModuleUri` 로 해석하고 소스를 복제해 main 청크를 만든다(334-341).
   - `!cont` 이면 uri `core` 를 해석해 builtin 청크를 만들고(344-348), `loadBuiltinChunk` 가 loader 를 불러 core 를 읽고 `Generator`, `Future`, `Option`, `Array`, `Map`
     같은 템플릿 심볼 30개를 sema 의 필드에 꽂는다(394-397, 879-918).
   - 새 청크마다 `loadChunk`(1052) + `resolveChunkSyms`. 이때 소스의 `use` 가 resolver -> loader 를 다시 부른다(399-407).
   - `main` 함수 검사, `@program_init`/`@program_deinit` 예약, `sema_program`, 청크별 sema, trait 구현 검사, `bcgen.genAll`(409-526).
4. 실행. `exec_bytecode`(vm.zig:593)가 `prepEval` 로 pc/fp/상수를 잡고 `Thread.exec_auto` 를 돌려 vm.c 의 `execBytecode` 로 들어간다.
   결과 포인터는 main 스레드 스택의 `stack_ptr[1]` 이다(vm.zig:609, 주석에 "%1 happens to be reserved for _main_res"). `res_t` 는 `fn main` 이 있을 때만
   main 의 반환 타입 id 이고 없으면 void(vm.zig:477-480).

호스트가 결과 값을 받는 유일한 경로가 `fn main() -> T` 의 반환이라는 점이 중요하다. cyber.h:383-385 는 "마지막 문장이 표현식이면 값이 `outVal` 에 담긴다"고 쓰지만
실제로는 표현식 문장이 컴파일 에러다(5.3절 실험, 7.2절).

### 2.3 같은 VM 에서 반복 eval: cont, persist_main, single_run, reset

`Compiler` 는 `cont: bool` 을 가진다(compiler.zig:104). 첫 `compile` 이 성공해야 `cont = true` 가 된다(compiler.zig:310). `cont` 가 켜진 컴파일은 core 와 이미 로드된
모듈 청크를 그대로 두고 main 청크만 새로 만든다(compiler.zig:326-330 에서 이전 main 을 `chunk_map` 에서 빼고, 344-348/394-397 에서 core 재로딩을 건너뜀).

```
   cl_vm_evalx #1 (cont=false)                 cl_vm_evalx #2 (cont=true)                cl_vm_reset
   ─────────────────────────────              ──────────────────────────                 ─────────────
   core 청크 로드+컴파일 (약 3~4ms)             core 재사용                                 VM.deinit(reset=true)
   main 청크 생성                               이전 main 청크를 chunk_map 에서 제거         + bindCore 재등록
   성공하면 cont = true  ─────────────────▶   새 main 청크 생성                           + cont=false
                                              loader 는 새 모듈에 대해서만 호출            (모든 청크 폐기, 다음 eval 이 core 재컴파일)
```

보존되는 것과 버려지는 것을 표로 정리한다. 모두 5.3절의 C 실험(rf_probe)과 코드로 확인했다.

| 항목 | 기본 eval 연속 | persist_main=true 연속 | cl_vm_reset 이후 |
|---|---|---|---|
| core(builtin) 청크 | 유지 | 유지 | 폐기, 다음 eval 이 재컴파일 |
| 이미 import 한 모듈 청크 | 유지(loader 는 VM 당 모듈 하나에 한 번만 호출됨) | 유지 | 폐기 |
| 이전 main 의 함수/타입/use | 버려짐(`foo` 를 다음 eval 이 못 봄) | `use` alias 로 이월(compiler.zig:352-390) | 버려짐 |
| 이전 main 의 지역 변수 | 버려짐(`x` 를 다음 eval 이 못 봄) | 이월(아래) | 버려짐 |
| panic/interrupt 이후 | 힙 정리 | 지역 변수 저장본 폐기(`dropMainLocalSaves`, vm.zig:409) | - |

persist_main 의 지역 변수 이월은 REPL 을 위해 e541090a 에서 들어갔고 세 부분으로 되어 있다.

- 기록: persist_main 일 때 main 블록의 지역 변수 선언마다 sema 가 숨은 호출 `@trackMainLocal(name, type_id, &local)` 을 끼워 넣는다
  (sema.zig:3524-3550). 호스트 함수 `trackMainLocal`(core.zig:1533)은 이름, 타입, 스택 시작 기준 슬롯 오프셋(포인터가 아님. 스택이 자라면 재할당되기 때문)을 `env_local_saves` 에 적는다.
- 보관: 실행이 정상 종료하면 `copyMainLocalSaves`(vm.zig:398)가 해당 슬롯을 VM 소유 버퍼로 복사한다. 값의 소유권은 저장본이 가져간다(main 블록 해제 코드를 만들지 않기 때문).
- 복원: 다음 `sema_program` 이 저장본마다 `Ptr[T]` 상수를 역참조해 같은 이름의 지역을 선언한다(비트 단위 move, sema.zig:4570-4589).
  컴파일 에러면 저장본이 그대로 남고, panic 이면 힙이 비워지므로 `dropMainLocalSaves` 가 기록만 지운다.

`single_run` 은 보존과 정반대 성격이다. "이 프로세스는 eval 한 번 하고 끝난다"는 선언이라 컴파일러가 main 블록 지역 변수의 해제 코드를 생략한다.
그래서 `VM.deinit` 이 맨 앞에서 `freeHeapPages` 로 힙을 한꺼번에 쓸어 낸다(vm.zig:204-209). CLI 는 ReleaseFast 일 때만 켠다(src/main.zig:161, 198, 269).
임베딩에서 VM 을 재사용하거나 누수 검사를 하려면 끄는 편이 안전하다는 것이 fork 의 결정이다(docs/decisions/project_embedding_agent_loop.md).

`cl_vm_compile`/`cl_vm_validate` 는 eval 과 다르게 맨 앞에서 `resetVM` 을 부른다(vm.zig:354-356). 컴파일만 하고 결과를 실행하는 공개 API 는 없다
(`exec_bytecode` 호출자는 `VM.eval` 하나뿐: rg 로 확인). 이 때문에 생기는 함정이 7.3절에 있다.

### 2.4 호스트 함수: #[bind] 선언에서 CALL_HOST 까지

경로 전체를 한 장으로 그리면 다음과 같다. 위쪽이 컴파일 시간, 아래쪽이 실행 시간이다.

```
 loader 콜백 안에서                              스크립트 소스(방금 loader 가 돌려준 문자열)
 cl_mod_add_func(mod, "tool", CL_BIND_FUNC(tool))     #[bind] fn tool(name str, args str) -> str
        │ chunk.host_funcs["tool"] = {ptr, kind=VM}            │ sema.ensure_resolved_func (sema.zig:2807)
        │ (lib.zig:582-585)                                    │   bind 속성 발견 (2866-2867)
        │                                                      ▼
        └──────────────────────────────▶ resolveHostBindFunc: 이름 "tool" 로 host_funcs 조회 (sema.zig:2980-2995)
                                                               │ kind 별 분기 resolveHostFunc2 (sema.zig:2942-2962)
                                                               ▼
                                          func.type = .hostFunc, func.data.hostFunc.ptr = tool   (module.zig:334-341)
                                                               │ bc_gen: 호출 지점마다
                                                               ▼
                                          .call_host base, <u48 즉시값 = tool 의 주소>          (bc_gen.zig:3110-3112)
 ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
 실행: vm.c CASE(CALL_HOST) (vm.c:940-961)
        fp = stack + base;  stack[base..base+2] = {hostcallinfo, pc, 이전 stack}
        Ret res = fn(t);    res != 0 이면 RETURN(RES_PANIC)
```

이 흐름에서 읽어야 할 설계 결정이 넷이다.

1. 이름은 "선언된 청크"의 표에서 찾는다. `src_c = c.compiler.chunks.items[func.src()]`(sema.zig:2981)이므로 호스트 표는 모듈마다 따로다. main 청크의 표는 비어 있다(소스를 직접
   받는 eval 은 loader 를 거치지 않고, 파일 실행은 CLI loader 가 내장 모듈 이름에만 표를 채운다). 신뢰할 수 없는 스크립트가 `#[bind] fn foo()` 를 써도 "Host func `foo` failed to load." 컴파일 에러가 날 뿐이다(실험: `#[bind] fn foo(a int) -> int` 만 든
   파일을 CLI 로 실행). 단, 호스트가 `cl_mod_set_fallback_func` 를 켠 모듈은 모든 미등록 이름이 그 함수로 간다(sema.zig:2992).
2. 이름 규칙. `#[bind='name']` 처럼 문자열이 있으면 그 이름, 없으면 `writeFuncName`(src/sym.zig:1472)이 만든 한정 이름이다. 예를 들어 `fn (&str) len()` 은 `str.len`,
   템플릿 타입의 메서드는 `Generator[].status`, 호스트 모듈의 자유 함수는 그냥 `tool`, 타입 생성자는 `MyNode.@init`(examples/libcyber/bind_module.c:68-70).
   오버로드 때문에 이름이 겹치면 `#[bind='str.index_byte']` 처럼 별도 이름을 준다(core.cy:3609).
3. 함수 포인터가 바이트코드 안에 박힌다. `.call_host` 는 포인터를 48비트 즉시값으로 쓴다(bc_gen.zig:3110-3112). 이 주소 -> 함수 id 맵 `vm.host_funcs` 는 스택 트레이스에
   이름을 붙일 때 쓴다(bc_gen.zig:296-298, debug.zig:529). 결과: 컴파일된 바이트코드는 같은 프로세스 안에서만 의미가 있다. 스냅샷/직렬화 API 는 소스에 없다
   (`rg -i 'snapshot|serializ'` 결과 없음). 시작 비용을 줄이려고 core 를 미리 컴파일해 저장하는 길이 막혀 있다는 뜻이다(5.7절).
4. kind 가 넷이다. `CLBindFunc.kind` 는 표(3.3절)의 네 가지이고 사용자 호스트 함수는 대부분 `CL_BIND_FUNC`(= `CL_BIND_FUNC_VM`)만 쓴다. 나머지 셋(`CONST_EVAL`, `BUILTIN`, `DECL`)은
   컴파일러 내부 훅이고 Zig 타입(`cy.Chunk`, `cy.ConstEvalContext`)을 받으므로 C 에서는 만들 방법이 없다.

#### 호출 시점의 스택 슬롯 규약

호스트 함수가 불리는 순간의 메모리 배치는 다음과 같다(thread.zig:543-566, vm.c:940-952).

```
   낮은 주소                                                                                   높은 주소
   ┌──────────────────┬──────────┬────────┬────────┬────────┬──────────┬─────────┬──────────┐
   │ 반환 슬롯 (N개)   │ [base]   │ [+1]   │ [+2]   │ [+3]   │ [+4]     │ [+4+a]  │ ...      │
   │                  │ hostcall │ 복귀pc │ 이전fp │ (예약) │ 인자 0   │ 인자 1  │          │
   └──────────────────┴──────────┴────────┴────────┴────────┴──────────┴─────────┴──────────┘
    ▲                   ▲ t->c.fp = stack + base                          ▲
    cl_thread_ret(t, size) 가                                             cl_thread_param/int/str... 이 fp_end 에서 읽고
    fp - ceil(size/8) 를 돌려줌                                           slots = ceil(size/8) 만큼 fp_end 를 전진
    그리고 fp_end = fp + 4 로 초기화  (thread.zig:547-552)
```

- 슬롯은 8바이트다. `cl_thread_ret(t, size)` 는 반환 영역 포인터를 돌려주고 동시에 `fp_end = fp + 4` 로 인자 읽기 위치를 초기화한다(thread.zig:547-552).
  `cl_thread_param` 계열은 `fp_end` 에서 읽고 `ceil(size/8)` 슬롯만큼 전진한다(thread.zig:554-566).
- 따라서 호스트 함수의 첫 줄은 항상 `cl_thread_ret` 여야 한다. 반환 값이 없어도 `cl_thread_ret(t, 0)` 을 부른다(bind_module.c:37 의 `mynode_deinit`, core.zig 의 `_ = t.ret(void)`).
  `fp_end` 는 `?[*]Value` 이고 CALL_HOST 는 이를 건드리지 않으므로(vm.c:940-961) ret 를 건너뛰고 param 부터 읽으면 이전 호출의 값이나 null 을 쓰게 된다.
  이 부분은 코드 판독이며 일부러 어긴 실험은 하지 않았다.
- 반환 코드. `CL_RET_OK`(0)면 정상, 0 이 아니면 `RES_PANIC` 으로 중단된다(vm.c:956-958). 헤더의 `CL_RET_INTERRUPT`(1)라는 이름과 달리 호스트 함수의 panic 신호다.
  `cl_thread_ret_panic(t, msg)` 는 메시지를 복제해 스레드에 저장하고 1 을 돌려주는 도우미다(thread.zig:808-814). 실험에서 `host says: negative` 가 `panic: host says: negative` 와
  호출 줄 위치로 요약됐다.
- 타입별 접근자와 슬롯 수는 3.2절 표에 있다. `bool` 은 `cl_thread_byte` 로 받는다(실험: `mix(1, 2.5, true)` -> 103.5).

#### 소유 규약: 값으로 받은 str, Slice 는 호스트가 해제한다

컴파일러는 호출 인자를 `ownOrManageArg` 로 정리한다.

```zig
// src/sema_func.zig:821-831 (ownOrManageArg 의 본문)
    // Object types are managed from the caller side.
    // Other types are copied and managed from the callee side.
    if (arg.type.isObjectLike()) {
        if (arg.resType == .value_local) {
            return arg;
        } else {
            const res = try sema.semaOwn(c, arg, node);
            return sema.semaManage(c, res, node);
        }
    } else {
        return sema.semaOwn(c, arg, node);
    }
```

Object 계열(`^T` 등 힙 참조)은 호출자가 관리하므로 피호출자는 빌리기만 한다. 그 밖의 타입(str, 슬라이스, 관리 필드를 가진 구조체)은 복사본이 넘어가고 피호출자가 소유한다.
호스트 함수도 피호출자이므로 규칙이 같다. 이 규약은 fork 가 2026-11-01 에 확정하면서 기존 바인딩 7개의 누수를 고쳤다(docs/history/ownership_memory.md,
docs/decisions/project_embedding_agent_loop.md).

| 선언한 매개변수 | 호스트가 받는 법 | 호스트의 의무 |
|---|---|---|
| `str` | `cl_thread_str` -> `CLstr`(3슬롯) | 다 쓰면 `cl_str_deinit(t, &s)`. 빠뜨리면 힙 문자열을 넘길 때마다 샌다 |
| `[]T` 값 | `cl_thread_slice` -> `CLSlice`(4슬롯) | `cl_slice_deinit(t, elem_t, &s)`. 관리 원소(`[]str` 등)면 `elem_t` 를 NULL 로 주면 원소가 샌다 |
| `[&]T` span, `&T`, `Ptr[T]` | `cl_thread_param(t, 16)`, `cl_thread_ptr` | 해제 금지(빌림) |
| `int`, `float`, `bool` 등 | `cl_thread_int`, `cl_thread_float`, `cl_thread_byte` | 없음 |

`cl_slice_deinit` 의 동작(lib.zig:166-180)은 `Slice.@deinit` 과 같다. 버퍼의 참조 횟수가 1일 때만 버퍼 앞 8바이트에 기록된 초기화 원소 수만큼 원소를 파괴하고
(`destructValueAt`), 어느 경우든 버퍼를 release 한다. 이 단위 테스트는 누수 검사 allocator 로 돌린다(lib.zig:1259-1355). 헤더가 아니라 이 테스트를 읽어야 규약이 보인다.
`cl_thread_count_objects` 로는 이 누수가 잡히지 않는다는 점도 기록돼 있다.

반환 쪽은 호스트가 만든 값을 반환 슬롯에 쓰면 소유권이 스크립트로 넘어간다. `str` 은 `cl_str_init`(lib.zig:623), 슬라이스는 `cl_slice_init`(lib.zig:158)로 만든다
(lib.zig:1189-1225 의 "cl_slice_init." 테스트가 `[]int` 반환 예).

호스트 전역 변수는 `#[bind] global g int` 와 `cl_mod_add_global(mod, "g", CL_BIND_GLOBAL(&host_var))` 로 호스트 메모리를 직접 가리킨다(sema.zig:3295-3316).
스크립트의 읽기/쓰기가 곧바로 호스트 변수에 닿는다(lib.zig:1465-1496 테스트: eval 사이에 값이 유지됨).

### 2.5 내장 라이브러리: core.cy 는 Cyber 이고 필요한 곳만 Zig

`core` 모듈은 모든 모듈의 fallback 이름 공간이다(compiler.zig:1092-1096: `loadChunk` 가 모든 청크에 builtins 를 fallback module 로 붙임). 그래서 `print`, `Array`, `Map`, `str` 은 `use` 없이 보인다.
이 모듈은 세 층으로 되어 있다.

```
 core.cy (4,415줄, Cyber)          core.zig (2,302줄, Zig)                     그 밖의 Zig
 ─────────────────────────         ──────────────────────────────              ──────────────────
 type Array[T]:  buf,length,..     funcs 표 110항목 (core.zig:77-225)           string.zig  (str 연산)
 fn (&&Array[]) append(...)        types 표  38항목 (core.zig:34-75)            heap.zig    (객체 할당)
   ensure_cap -> alloc(T, n)       bind(): 표를 mod_add_func/mod_add_type 으로   thread.zig  (스레드)
     -> alloc_(len)  #[bind]  ───▶   등록하고 @embedFile("core.cy") 를 반환     ...
                                   (core.zig:231-243, Src 26행)
                                   .{"alloc_", zErrFunc(alloc)}  (core.zig:79) ──▶ pub fn alloc(t) (core.zig:1637)
```

`bind` 가 소스 문자열(`@embedFile`)을 돌려주고 `cl_default_loader` 가 이를 그대로 컴파일러에 넘기므로(compiler.zig:1459-1470) 라이브러리 모드의 core 는 디스크 파일이 필요 없다.
CLI 는 다르다. CLI loader 는 같은 `bind` 를 불러 호스트 표만 등록하고 돌려준 소스는 버린 채 `mod_root/src/builtins/core.cy` 를 디스크에서 읽는다(cli.zig:173-215, 5.5절).

호스트 함수 래퍼 네 종류(core.zig:284-398)가 `CLBindFunc.kind` 에 대응한다.

| 래퍼 | kind | 시그니처 | 쓰임 |
|---|---|---|---|
| `cFunc(f)` | VM | `fn(t) callconv(.c) Ret` | 에러 없는 런타임 함수(`prints`, `str.len`) 20개 |
| `zErrFunc(f)` | VM | `fn(t) anyerror!Ret` | Zig 에러를 `t.ret_panic(@errorName(err))` 로 바꿔 줌(core.zig:387-396) 53개(+ 변형 `zErrFunc2` 1개) |
| `zErrConstEvalFunc(f)` | CONST_EVAL | `fn(*Chunk, *ConstEvalContext) !TypeValue` | `EvalStr.len` 처럼 컴파일 타임에 불리는 함수 13개 |
| `zErrBuiltinFunc(f, eval)` | BUILTIN | `fn(*Chunk, *BuiltinContext, *ExprResult) !void` | sema 가 IR 을 직접 만드는 훅(`@bitCast`, `@call`, `@gen_next`) 21개 |
| `zDeclFunc(eval)` | DECL | - | 호스트 포인터 없이 선언의 Cyber 본문을 쓰되 const-eval 훅만 붙임(`Int[].@init`) 2개 |

개수는 core.zig:77-225 에서 주석 줄을 뺀 `rg -o` 집계이며 합(20+53+1+21+13+2)이 표 항목 수 110과 같다. types 표 38항목은 `TYPE_CREATE` 30개와 `TYPE_RESERVE_DECL` 8개다.

`#[bind]` 가 붙은 함수에 Cyber 본문이 같이 있는 경우도 많다(core.cy:3734 `fn (&str) len() -> int:` 와 `return self.header && ~(1 << 63)`).
VM 백엔드에서는 호스트 함수가 쓰이고, sema.zig:2868-2871 은 "백엔드가 VM 이 아닌데 본문이 없으면 `Expected function implementation.`" 오류를 낸다. 이 두 사실에서 본문은
C 백엔드(`-cc`/`-tcc`)가 호스트 함수 대신 컴파일하라고 둔 것이라고 읽을 수 있다(추정. 해당 백엔드의 내부를 읽어 확인하지는 않았다).

대표 사례를 다섯 개 따라가 보자(5.4절에서 직접 추적한다).

- `print`: `print(x)` -> `prints(x)` + `prints_('\n')` (core.cy:158-166). `prints(x)` 는 `to_print_string(x)`(core.cy:168, 컴파일 타임 `#if T == ...` 분기)로 문자열을 만들어 호스트
  함수 `prints_` 에 넘긴다. `prints`(core.zig:1256)는 `vm.print` 콜백을 부른다. 그래서 "print 하나에 콜백이 두 번 불린다"(본문, 개행). 호스트가 `print` 를 가로채는 길이 이것 하나다.
- `Array[T]`: 순수 Cyber 구조체 `{buf Ptr[T], length int, header int}`(core.cy:1662-1670)이다. `append` 는 용량이 모자라면 `ensure_cap`(core.cy:1839) -> `alloc(T, n)`(core.cy:24) ->
  `alloc_`(core.cy:34, `#[bind]`) 순으로 호스트에 내려간다. 용량을 키울 때 호스트에 내려가는 함수는 할당 `alloc_`(core.cy:34)과 해제 `free`(core.cy:142) 둘뿐이고, 원소 복사와 소멸은 Cyber 코드다.
- `str`: 데이터 레이아웃은 `{buf ?^StrBuffer, ptr Ptr[byte], header int}` 3슬롯(core.cy:3237-3248)으로 C 의 `CLstr` 과 같고, 길이는 `header & ~(1<<63)`, 최상위 비트가 ASCII 힌트다.
  문자열 연산 대부분(`len`, `index`, `+`, `lower` 등 표의 `str.` 항목 30개)이 `#[bind]` 로 string.zig 에 구현돼 있다.
- `Option[T]`, `Result[T]`: `#[bind] type Option[T Any] _`(core.cy:4091)처럼 몸체가 `_` 인 타입은 `CL_BIND_TYPE_CREATE` 콜백이 컴파일러 내부 타입을 직접 만든다(core.zig `createOptionType`).
  이 `*Type` 생성은 Zig 내부 API 여서 C 호스트가 따라 할 수 없다(`CLCreateTypeFn` 이 `CLType*` 를 돌려주지만 C 에서 타입을 만드는 함수가 없다).
  Option 의 보조 함수(`?T` 에서 값 꺼내기)는 `meta.access_option_payload`(meta.cy:114) 같은 도우미가 맡고 `Future.await` 가 이를 쓴다(core.cy:4102-4108).
- `Future[T]`, `Generator[F]`, `Thread`: `Future` 는 `FutureValue` 를 가리키는 Cyber 구조체이고 `@await_`(`zErrBuiltinFunc`)와 `@notifyFutureComplete` 만 호스트다(core.cy:4097-4170).
  `Generator` 는 `{frame_ptr, frame_len, resume_pc, deinit_pc, prev_fp, running, done}` 필드의 Cyber 구조체(core.cy:4319-4333)이고 `@gen_next`, `@gen_end` 는 BUILTIN 훅이다.
  `spawn` 은 전부 Cyber 코드(core.cy:4381-4399)이며 `@new_thread`, `@start_thread`, `@new_shared_state` 만 호스트다. 코루틴 내부는 [Day 6 오후](07-coroutines-concurrency.md)가 다룬다.

bindings.zig 는 이름과 달리 "등록 표"가 아니다. 이 파일에는 (1) 내장 symbol 열거형(`Symbol`, bindings.zig:24-87)과 `bindCore`, (2) `asr`, `fabs`, `float_pow` 같은 core.zig 가 참조하는 훅 몇 개,
(3) 0.3 시절 `ModuleBuilder`(이미 없는 `C.declareFunc` 와 `self.modId` 를 부르므로 호출되면 컴파일되지 않는 죽은 코드)가 있다. 등록 표는 각 모듈의 `funcs`/`types` 배열이고 `bind` 함수가
`@export(&bind, .{ .name = "cl_mod_bind_core" })` 로 C 심볼이 된다(core.zig:228-229). 다른 모듈도 같은 패턴이다
(`cl_mod_bind_{cy,c,meta,math,io,test}`).

### 2.6 모듈 해석: resolver 와 loader 두 콜백

`use` 문 하나가 처리되는 경로는 이렇다.

```
 use u 'lib/util'                          sema.declareUseImport (sema.zig:2447, 청크 예약 단계)
   │ specPath = 'lib/util'  (이름만 쓴 `use math` 는 specPath = "math")
   ▼
 resolveModuleUriFrom(chunk, buf, spec)   ── CLResolverFn(vm, {chunkId, curUri, uri, buf}, &len)  (compiler.zig:1472-1491)
   │ 기본 resolver 는 uri 를 buf 에 그대로 복사 (compiler.zig:1439-1443)
   ▼
 ensureModule(resolved uri)               ── chunk_map[uri] 에 있으면 그 청크를 재사용 (compiler.zig:1110-1136)
   │ 없으면 새 청크 + 새 심볼(`name` = 파일명에서 확장자 뺀 것)
   ▼
 loadChunk(chunk)                         ── CLModuleLoaderFn(vm, mod, resolved_uri, &res) (compiler.zig:1052-1098)
   │ false 면 "Failed to load module: <uri>" 컴파일 에러 (사용자 메시지가 있으면 그것)
   ▼
 res.src 를 파싱 -> reserveChunkSyms     (manage_src=true 면 컴파일러가 소스를 해제)
```

- 기본 resolver 는 아무 정규화도 하지 않는다. 그래서 `use 'lib/util'` 의 loader 인자는 문자열 그대로 `lib/util` 이고, 상대 경로(`./x.cy`)도 그대로 loader 에 도착한다
  (실험: loader 가 `uri='./nothere.cy'` 를 받음). 상대 경로를 풀려면 resolver 가 `params.curUri` 와 `params.chunkId` 로 직접 해야 한다.
- 기본 loader(`cl_default_loader`, compiler.zig:1459-1470)는 내장 7종(`core`, `meta`, `math`, `cy`, `c`, `io`, `test`)만 안다(StaticStringMap `mods`, 1449-1457).
  다른 이름은 `false` 를 돌려주므로 "Failed to load module" 이다. 호스트 loader 는 자기 모듈을 처리하고 나머지를 `cl_default_loader` 에 위임하는 것이 관용구다(examples/libcyber/host_tool.c:37-45).
- loader 는 청크당 한 번만 불린다. 같은 VM 에서 모듈 소스를 바꾸고 다시 `use` 해도 이전 청크가 재사용된다(실험: v1 로 로드 후 v2 로 바꿔 eval 해도 loader 호출 없음, `cl_vm_reset` 후에야 v2 로드).
- loader 는 반드시 소스를 돌려줘야 하지만 `res->manage_src = false` 면 소스는 호스트 소유 정적 메모리여야 한다(cyber.h:543-544 주석).
  `true` 면 컴파일러가 `cl_vm_alloc` 계열 할당자로 해제한다.

CLI 는 두 콜백을 자기 것으로 바꾼다(src/cli.zig:64-120, `init_cli`).

- resolver(cli.zig:229-260): 짧은 이름 표 `mod_uris`(`core` -> `<mod_root>/src/builtins/core.cy` 등 10개: core, meta, math, cy, c, libc, os, io, cli, test)에 있으면 절대 경로로, `http(s)://` 는
  github.com 의 `user/repo` 형태를 `raw.githubusercontent.com/.../master/mod.cy` 로 바꾸고, 나머지는 현재 스크립트의 디렉터리 기준으로 붙여 `realpath` 한다(cli.zig:262-307).
  없으면 "Import path does not exist" 에러.
- loader(cli.zig:173-215): `mod_bindings` 에 등록된 내장 모듈이면 `bind` 로 호스트 표를 등록하고, 그다음 소스를 읽는다. `http(s)` 면 `loadUrl`(cli.zig:346)로 `~/.cyber` 캐시를 먼저 보고 없으면
  HTTP GET 한 뒤 캐시에 저장한다. 그 밖에는 `cwd().readFileAlloc(spec)` 로 파일을 읽는다.
- URL 캐시(src/cache.zig): 스킴을 뗀 spec 의 wyhash 16자리를 이름으로 `~/.cyber/entries/<hash>` 에 `@spec` 와 `cacheDate=` 줄을 저장하고 파일 본문은 `~/.cyber/<host/path>` 에 둔다(cache.zig:16-130).
  만료 정책은 없고 `-r`(reload)가 항목을 지워 다시 받게 한다(cli.zig:353-356). 네트워크 경로는 코드로만 확인했고 실행하지 않았다.
- dl_resolver(cli.zig:217-227): `#c.bind_lib('https://...')` 처럼 `https://` 로 시작하면 `os.allocCacheUrl` 이 내려받은 뒤 로컬 경로를 돌려준다. 즉 CLI 에서는 스크립트가 원격 공유 라이브러리를 받아 `dlopen` 하는 길도
  코드상 열려 있다(코드 판독).

### 2.7 CLI 앱과 REPL

CLI 는 libcyber 위에 얹은 호스트 프로그램 하나다. 구조를 `src/main.zig`(378줄)와 `src/cli.zig`(784줄)로 나누어 읽으면 된다.

```
 main(init)                                       (main.zig:29)
  ├─ 인자 파싱: -v -r -vm -cc -tcc -jit -h, 알 수 없는 옵션은 무시(스크립트가 쓰도록)  (main.zig:55-109)
  ├─ cmd = repl(인자 없음) | eval(파일) | compile | fmt | help | version
  │
  ├─ evalPath(path)                               (main.zig:255)
  │     vm = vm_initx(alloc)  ->  cli.init_cli(vm)      resolver/loader/printer/eprinter/logger 를 CLI 것으로 교체
  │     config = { single_run = (ReleaseFast 만), spawn_exe = true, backend }
  │     vm_eval_path(vm, path, config)            src=null 이라 컴파일러가 loader 로 파일을 읽는다
  │     실패하면 요약을 stderr 로 출력하고 exit(1) (Debug 는 error.EvalError)
  ├─ compilePath(path)                            (main.zig:151)  vm_compile_path + vm_dump_bytecode  (`cyber compile`)
  └─ repl()                                       (main.zig:182)  "use cli\n\ncli.repl()" 를 uri `main` 으로 eval
```

- `cyber fmt` 는 도움말에 있지만 `std.debug.panic("TODO: Embed src/tools/fmt.cy")`(main.zig:121)로 끝난다. 실험: `cyber fmt hello.cy` -> `panic: TODO: Embed src/tools/fmt.cy`, 종료 코드 134.
- `init_cli`(cli.zig:64)는 `mod_root` 를 정한다. Debug 빌드는 빌드 시점의 저장소 절대 경로(`build_config.mod_root`), 릴리스는 실행 파일 디렉터리다(build.zig:89-93).
  그래서 릴리스 CLI 는 `<exe 디렉터리>/src/builtins/*.cy` 와 `src/std/*.cy` 가 없으면 core 를 못 읽는다. 번들에 `src/` 를 넣는 이유다(build.zig:132-157, docs/decisions/project_fork_release_ci.md).
  이 저장소의 zig-out/bin/src/ 아래에 builtins/(c, core, cy, meta)와 std/(cli, io, libc, libc.macos, math, os, os.macos, test)가 설치돼 있다.
- CLI 의 `print` 콜백은 stdout 에 쓰고(cli.zig:161), 테스트 빌드(`builtin.is_test`)에서는 러너가 멈추는 것을 피하려고 stderr 로 돌린다(cli.zig:162-167).

REPL 은 "Cyber 로 쓴 Cyber 호스트"다. `cli.repl()`(src/std/cli.cy:13)이 `cy.repl(replReadLine_)`(src/builtins/cy.cy:1213)을 부르고, 이것이 `REPL.new()` 로 격리된 VM 하나를 만든다
(`cy.VM`, cy.cy:1283). 한 줄을 읽을 때마다 `vm.eval('eval', code, {persist_main=true})`(cy.cy:1378-1379)로 내부 VM 에 먹인다. 즉 VM 이 둘이다.

```
  바깥 VM (CLI 가 만든 것, loader=CLI loader)                  안쪽 VM (cy.zig:77 UserVM_init -> C.vm_init())
  ─────────────────────────────────────────────              ─────────────────────────────────────
  main.zig:repl -> eval("use cli; cli.repl()")                loader/resolver = 기본값 (cl_default_*)
    cy.repl(): ctx = REPL.new() ─────────────────────────────▶ VM 생성, printer/eprinter/logger 는 바깥 것을 복사
    while ctx.read(read_line) |code|:                            (cy.zig:77-90)
        ctx.eval_print(code) ───── vm.eval(persist_main=true) ─▶ 사용자의 한 줄을 컴파일/실행, 지역 변수 이월
```

관찰한 결과와 귀결을 정리한다.

- 입력은 `.exit` 로 끝내고, `:` 로 끝나는 줄이면 들여쓰기 블록을 모으며 빈 줄이 오면 제출한다(cy.cy:1346-1376). 값이 void 가 아니면 `value_desc` 를 출력한다(cy.cy:1392-1394).
- panic 이 나면 요약과 함께 `Variables were reset.` 을 출력한다(cy.cy:1384-1388). 5.5절에서 그대로 재현한다.
- 안쪽 VM 은 `C.vm_init()` 으로 만들어져 기본 loader 를 쓰므로 REPL 에서는 `use os` 가 `Failed to load module: os` 로 실패한다(5.5절 실험). CLI 파일 실행과 REPL 의 모듈 환경이 다르다.
- `cy.cy:13-16` 의 결과 코드 상수는 Success, Await, ErrorCompile, ErrorPanic 네 개뿐이라 `CL_ERROR_UNKNOWN`(4)과 `CL_ERROR_INTERRUPT`(5)는 `eval_print` 의 `else` 분기("Unknown error")로 떨어진다(cy.cy:1380-1390).

### 2.8 테스트 체계

`zig build test` 는 5개 스텝의 묶음이다(build.zig:278-284). 각 스텝은 따로 돌릴 수 있다.

```
 zig build test
   ├─ lib-test             src/lib.zig 의 C API 테스트 (+ 도달 가능한 다른 파일의 test)   실행: 53/53 통과
   ├─ lib-standalone-test  examples/libcyber/{main, bind_module, host_tool}.c 를 libcyber.a 에 링크해 실행   실행: 통과
   ├─ cli-test             cli 모듈(main.zig -> cli.zig refAllDecls) 테스트                  실행: 5/5 통과
   ├─ trace-test           src/trace_test.zig  ARC retain/release 횟수 단언 11개 (Trace 빌드 전용 lib 를 따로 빌드)
   └─ behavior-test        src/behavior_test.zig  등록된 .cy 경로 284개(+ chdir 변형 2개) + 예제 컴파일 + FFI + 개행 케이스
```

실행 횟수는 이 세션에서 `zig build lib-test|lib-standalone-test|cli-test --prefix <임시 폴더> --summary all` 로 직접 돌려 얻었다(behavior-test, trace-test 는 시간 때문에 돌리지 않았다).
`lib-test` 의 53개는 lib.zig 의 `test "..."` 블록 28개와 lib 모듈이 끌어오는 다른 파일의 테스트를 합친 값으로 추정한다(블록 수는 `rg -c '^test "'` 로 센 28개뿐이고 나머지 25개의 출처는 따로 추적하지 않았다).

behavior-test 는 이 장의 핵심이다. 파일을 "발견"하지 않는다. 사람이 쓴 목록이 전부다.

- 목록: `test_syntax`, `test_functions`, `test_memory`, `test_types`, `test_modules`, `test_meta`, `test_concurrency`, `test_core`, `test_vars`, `test_control_flow` 가
  `run.case("syntax/indentation.cy")` 식으로 경로를 등록한다(behavior_test.zig:55-417). 거기에 `../tokenizer.cy`(src/tokenizer.cy, Cyber 로 쓴 토크나이저)가 하나 더 붙는다(434행).
  `src/test` 아래 .cy 는 303개이고 `run.case` 로 등록된 것이 283개(+ tokenizer.cy 1개 = 경로 284개)이므로 20개가 목록 밖이다(5.6절에서 분류).
- 실행: `test "Tests."`(419)가 목록을 돌며 `case2`(606)를 부른다. `failFast = true`(49)라 첫 실패에서 멈춘다.
- 지시자: `case2` 는 파일 전체에서 첫 `cytest:` 문자열을 찾고(`std.mem.find(u8, contents, "cytest:")`, 없으면 `error.MissingTestDefinition`), 같은 줄의 단어로 분기한다.

| 지시자 | 파일 수(src/test 의 `cytest:` 줄 집계) | 하네스가 하는 일 |
|---|---|---|
| `--cytest: pass` | 149 | `evalPass`: 실행해서 성공(`CL_SUCCESS`)하고 힙에 남은 객체가 0 이면 통과 |
| `--cytest: error` | 116 | 다음 줄들의 `--` 접두어를 지운 텍스트를 기대 리포트로 보고, 컴파일 에러(또는 panic) 요약과 전체 일치 비교 |
| `--cytest: panic` | 23 | 기대 텍스트 안의 `[trace]` 줄을 경계로 앞부분은 "시작 일치", 뒷부분은 "끝 일치"를 비교(AOT 백엔드는 앞부분만) |

- 기대 텍스트의 `@MainPath()` 는 테스트 파일의 해석된 절대 경로로, `@AbsPath(상대경로)` 는 cwd 기준 절대 경로로 바뀐다(setup.zig:451-491). 요약의 빨간색 ANSI 코드는 하네스가 먼저 지운다(setup.zig:185-187).
  이 지운다는 사실이 "에러 요약에 이스케이프 코드가 들어간다"는 반증이다(7.2절).
- 개별 eval 은 `setup.VMrunner.eval`(setup.zig:239)이 감싼다. `c.vm_reset(vm)`으로 VM 을 초기화하고(292행), 끝나면 `thread_count_objects != 0` 이면 `unfreed objects: N` 으로 panic 하며,
  Trace 빌드에서는 전역 참조 카운트(`thread_rc`)가 0 이 아니어도 panic 한다(setup.zig:300-314). 누수는 곧 테스트 실패다.
- `Config.chdir` 가 있는 사례(behavior_test.zig:256-258)는 cwd 를 바꿔 상대 경로 import 를 시험한다. 러너는 `src/test_runner.zig`(커스텀 `main`)이고 `zpanic` 으로 panic 을 VM 상태 덤프와 연결한다.
- 그 밖의 `test` 블록: `"Compile."`(468)은 examples/*.cy 와 src/tools/*.cy, 벤치마크 .cy, docs/gen-docs.cy 가 "컴파일만" 되는지 본다. `"FFI."`(508)는 `test_config.ffi` 일 때만
  `ffi/ffi.cy`를 돌린다(미리 빌드된 src/test/ffi/test_lib.so/.dylib/.dll 이 저장소에 들어 있다). `"windows new lines"`(520)는 CRLF 파싱 에러를 단언한다.

## 3. 핵심 개념 정리

### 3.1 cyber.h 의 113개 선언 지도

`rg` 로 센 함수 선언은 113개다(docs/history/embedding_cli.md 의 "101개"와 다르다. 7.2절). 영역별로 나누면 다음과 같다.

| 영역 | 개수 | 대표 함수 | 읽을 곳 |
|---|---|---|---|
| 최상위/버전 | 6 | `cl_version`, `cl_full_version`, `clResultName`, `cl_strlen` | lib.zig:440, 766-800 |
| VM 생성/해제/설정 | 9 | `cl_vm_init`, `cl_vm_initx`, `cl_vm_deinit`, `cl_vm_reset`, `cl_vm_set_user_data` | lib.zig:27-60, 218, 615 |
| eval/컴파일/에러 | 10 | `cl_vm_eval`, `cl_vm_evalx`, `cl_vm_eval_path`, `cl_vm_compile`, `cl_vm_validate`, `cl_vm_error_summary`, `clDefaultEvalConfig` | lib.zig:208-262, 367-424, 453-469 |
| 중단/fuel | 2 | `cl_vm_interrupt`, `cl_vm_set_fuel` | lib.zig:254-260, vm.c:330-336 |
| 모듈 resolver/loader | 8 | `cl_vm_set_resolver`, `cl_vm_set_loader`, `cl_default_loader`, `cl_vm_set_dl_resolver` | lib.zig:487-512, 802-805 |
| 출력/로그 | 7 | `cl_vm_set_printer`, `cl_vm_set_eprinter`, `cl_vm_set_logger`, `clReportApiError` | lib.zig:483, 514-536 |
| 메모리/할당 | 6 | `cl_vm_alloc`, `cl_vm_allocb`, `cl_vm_freeb`, `cl_thread_allocator` | lib.zig:182-202 |
| 호스트 함수 슬롯 접근(스레드) | 17 | `cl_thread_ret`, `cl_thread_ret_panic`, `cl_thread_param`, `cl_thread_int`, `cl_thread_str`, `cl_thread_slice` | lib.zig:94-156 |
| panic 정보 | 2 | `cl_thread_panic_summary`, `cl_thread_panic_trace` | lib.zig:471-481 |
| 참조 카운트/진단 | 10 | `cl_thread_retain/release`, `cl_thread_count_objects`, `cl_thread_check_memory`, `cl_thread_signal_host_segfault` | lib.zig:54-86, 542, 607-613, 746-758 |
| 모듈 바인딩 | 15 | `cl_mod_add_func`, `cl_mod_add_type`, `cl_mod_add_global`, `cl_mod_on_load`, `cl_mod_set_fallback_func`, `cl_mod_bind_core` 등 7종 | lib.zig:577-605 |
| 타입/심볼 | 7 | `cl_find_type`, `clExpandTypeTemplate`, `cl_type_id`, `cl_vm_ensure_func_sig`, `cl_new_func_union` | lib.zig:546-575, 651-657, 730-736 |
| 값/문자열/슬라이스 | 14 | `cl_str_init`, `cl_str_deinit`, `cl_slice_init`, `cl_slice_deinit`, `cl_lift`, `cl_value_desc`, `cl_symbol` | lib.zig:158-180, 623-641, 679-685 |

`CLVM`, `CLThread`, `CLSym`, `CLType` 은 불투명 포인터이고 `CLBytes`(포인터+길이, 널 종료 아님), `CLstr`(24바이트), `CLSlice`(32바이트)만 값 구조다. 이름 규칙이 두 가지다.
`cl_` 로 시작하는 snake_case 107개와 `clResultName`, `clDefaultEvalConfig` 같은 camelCase 6개가 섞여 있다(옛 0.3 `cs*` 접두어 흔적).

`src/capi.zig` 는 이 헤더를 Zig 에서 쓰는 얇은 래퍼다. 헤더를 `translate-c` 로 번역한 모듈 `cyber_c` 를 감싸 `to_bytes/from_bytes`, `thread_ret(t, T)`, `thread_param(t, P)` 같은 타입 안전한 도우미를 만든다
(capi.zig:305-332). 즉 core.zig 같은 내부 코드도 호스트 함수를 쓸 때는 이 C ABI 와 같은 규약을 거친다. 헤더에 없는 함수 몇 개(`clGetType`, `clTypeId`)와 `CLSemaFn` 타입을 가리키는
정의가 capi.zig 에 남아 있지만(78-80, 182, 384-388) Zig 는 참조되지 않은 선언을 분석하지 않아 빌드가 깨지지 않는다.

### 3.2 호스트 함수 접근자와 슬롯

| Cyber 매개변수/반환 타입 | C 접근자 | 슬롯 수(8바이트) | 비고 |
|---|---|---|---|
| `int`, `i64` | `cl_thread_int` | 1 | `cl_thread_i32/i16/i8` 은 좁은 정수 |
| `float` / `f32` | `cl_thread_float` / `cl_thread_f32` | 1 | |
| `bool`, `byte`, `r8` | `cl_thread_byte` | 1 | 실험: `bool` 인자를 이것으로 읽어 동작 |
| `r16`, `r32`, `r64` | `cl_thread_r16/r32/r64` | 1 | |
| `str` | `cl_thread_str` -> `CLstr {buf, ptr, header}` | 3 | `cl_str_bytes` 로 `CLBytes` 변환, 다 쓰면 `cl_str_deinit` |
| `[]T` (Slice) | `cl_thread_slice` -> `CLSlice {buf, ptr, len, header}` | 4 | 다 쓰면 `cl_slice_deinit` |
| `[&]T` (Span) | `cl_thread_param(t, 16)` -> `{ptr, len}` | 2 | 빌림. io.zig 의 `indexOfNewLine` 이 `heap.Span` 으로 읽는 형태 |
| `&T`, `Ptr[T]` | `cl_thread_ptr` | 1 | `bind_module.c` 의 `MyNode*` 수신자 |
| 구조체 값 | `cl_thread_param(t, sizeof(S))` | ceil(size/8) | Cyber 구조체는 C 구조체와 같은 배치(docs/history/embedding_cli.md) |

반환은 `cl_thread_ret(t, sizeof(R))` 가 돌려주는 포인터에 쓴다. 이 표에서 틀린 접근자를 쓰면 슬롯이 어긋나 조용히 깨진다(타입 검사가 없다).

### 3.3 설정 구조체와 결과 코드

`CLEvalConfig`(cyber.h:280-290)와 `CLCompileConfig`(297-313)의 필드를 소스에서 따라가면 다음과 같다.

| 필드 | 의미 | 근거 |
|---|---|---|
| `single_run` | main 블록 지역 변수의 해제 코드를 생략하고 `VM.deinit` 이 힙을 쓸어 담는다. 재사용할 VM 에는 쓰지 않는다 | vm.zig:204-209, main.zig:161 |
| `persist_main` | main 의 함수/타입/use 와 지역 변수를 다음 eval 로 이월(REPL). 2.3절 | compiler.zig:352-390, vm.zig:473-476 |
| `gen_all_debug_syms` | 실패 가능한 명령에만이 아니라 모든 명령에 debug sym 을 만든다 | chunk.zig:682 |
| `backend` | `CL_VM`(기본). `CL_JIT` 는 컴파일 에러 "The JIT backend is not supported."(compiler.zig:287-290, lib.zig 테스트 1136), `CL_TCC`/`CL_CC` 는 C 로 내보내 외부 실행(vm.zig:481-511), `CL_LLVM` 은 `error.TODO` | fork 방침상 VM 만 지원 |
| `spawn_exe` | AOT 백엔드 산출물을 spawn 으로 실행할지 | vm.zig:487 |
| `skip_codegen` (Compile 전용) | 바이트코드 생성을 건너뜀. `cl_vm_validate` 가 이것으로 구문/의미 검사만 한다 | vm.zig:347-352 |
| `emit_source_map` (Compile 전용) | C 백엔드 소스맵 | cgen.zig:298 |

`CLResultCode`(cyber.h:40-48)는 다섯 값이다.

| 코드 | 값 | 발생 |
|---|---|---|
| `CL_SUCCESS` | 0 | 정상 |
| `CL_AWAIT` | 1 | main 이 끝나지 않은 future 를 기다리다 멈춤(vm.c:1500, lib.zig:240). 이어 실행하는 API(`cl_run_ready_tasks`)는 주석 처리돼 있다 |
| `CL_ERROR_COMPILE` | 2 | 파싱/의미 오류. `cl_vm_error_summary` 가 첫 리포트를 돌려줌 |
| `CL_ERROR_PANIC` | 3 | 런타임 panic. 스택 트레이스 포함 요약 |
| `CL_ERROR_UNKNOWN` | 4 | 위에 속하지 않는 Zig 에러(OOM 등). 요약 없음 |
| `CL_ERROR_INTERRUPT` | 5 | `cl_vm_interrupt` 또는 fuel 소진. 요약은 `panic: Interrupted.` / `panic: Out of fuel.` |

`clResultName` 은 이 다섯 값 이름(`Success`, `CompileError`, ...)만 처리하고 `CL_AWAIT` 를 넘기면 `fatal()` 이다(lib.zig:440-449).
`cl_vm_error_summary`(lib.zig:453)는 마지막 결과가 COMPILE 이면 컴파일 요약, PANIC 이나 INTERRUPT 면 panic 요약, 아니면 빈 문자열을 돌려준다. 돌려받은 `CLBytes` 는 `cl_vm_freeb(vm, bytes)` 로 해제한다.

`CLBindFuncKind`(cyber.h:172-184) 네 가지의 의미는 2.5절 표와 같다. `CLBindTypeKind` 는 `DECL`(사전 정의 type id 를 받는 `TYPE_RESERVE_DECL`, sema_type.zig:518), `CREATE`(콜백이 `*Type` 생성, sema_type.zig:70-78),
`ALIAS`(콜백이 기존 심볼을 가리킴, sema_type.zig:276)이다. 후자 둘의 콜백은 컴파일러 내부 타입을 요구하므로 사실상 fork 의 Zig 코드 전용이다.

### 3.4 내장 모듈과 CLI/라이브러리 차이

| 모듈 | 소스 | 호스트 함수 | 라이브러리 기본 loader | CLI | 비고 |
|---|---|---|---|---|---|
| core | builtins/core.cy 4,415줄 | core.zig 110 + 타입 38 | 예 | 예 | 모든 모듈의 fallback |
| meta | builtins/meta.cy 338줄 | meta.zig 60 | 예 | 예 | 컴파일 타임 도구(`meta.system()`, `type.info`, `meta.eval`) |
| math | std/math.cy 1,168줄 | math.zig 41 | 예 | 예 | `use c` 를 포함 -> c 가 허용돼야 로드됨(5.2절 실험) |
| cy | builtins/cy.cy 1,407줄 | cy.zig 13 | 예 | 예 | 파서 API, 중첩 VM, REPL |
| c | builtins/c.cy 38줄 | c.zig 6 | 예 | 예 | `to_strz`, `from_strz`, `bind_lib`, `include`, `flag` |
| io | std/io.cy 127줄 | io.zig 1 | 예 | 예 | `Reader`, `Scanner`(파일 I/O 는 없음) |
| test | std/test.cy 52줄 | 없음(순수 Cyber) | 예 | 예 | `eq`, `assert`, `fail`, `eq_span` 등 |
| os | std/os.cy 919줄 + os.macos.cy 등 | os.zig 8, os_ffi.zig | 아니오 | 예 | 파일/프로세스/환경. 대부분 libc extern 호출이라 FFI 필요 |
| libc | std/libc.cy 249줄 | 없음 | 아니오 | 예 | libc 의 extern 선언 모음 |
| cli | std/cli.cy 19줄 | cli.zig 1(`replReadLine`) | 아니오 | 예 | REPL 진입점 |

("호스트 함수" 숫자는 각 .zig 의 `.{"` 로 시작하는 표 항목 수를 센 값이고 meta.zig 는 funcs+types 합계다.)

`test` 모듈의 `eq` 는 `panic('Expected `5`, found `4`.')` 이므로 하네스에서는 panic 으로 보이고 CLI 에서는 `exit 1` 과 스택 트레이스로 보인다(5.6절 실험).

### 3.5 core.cy 목차 (시작 줄 기준)

| 줄 범위 | 내용 |
|---|---|
| 1-12 | `use meta`, 모듈 설명 주석 |
| 13-223 | 유틸 함수: `abort`, `alloc`/`free`, `assert`, `binary_search`, `dump`, `print`/`prints`/`eprint`/`log`, `panic`, `to_print_string`(타입별 `#if` 분기) |
| 225-297 | 기본 타입 선언: `void`, `never`, `bool`, `symbol`, `error`, `EvalInt`/`EvalStr`, 정수 별칭 |
| 299-394 | `Raw[Bits]`(r8..r64, byte) |
| 395-594 | `Int[Bits]`(int, i8..i64), `Endian`, `NumberFormat` |
| 596-660 | `Float[Bits]`(float, f32, f64) |
| 662-718 | `Object` 동적 래퍼, `TaskCallback` |
| 720-875 | `Any`/`dependent`/`Infer`, `RawBuffer`, `Copyable`/`NoCopy` 트레이트, `Ex`/`RtBorrow`(런타임 빌림), `EvalBuffer` |
| 877-1426 | `Buffer[T]`, `Slice[T]` (공유 버퍼 + 복제 후 리사이즈, 버퍼 앞 8바이트에 초기화 원소 수) |
| 1428-1560 | `AsSpan` 트레이트, `ConstSpan`, `Span[T]`(빌림 뷰) |
| 1562-1988 | `ArrayStore[T]`(작은 값 전용), `Array[T]`(배열, `append`, `ensure_cap`, `compute_new_cap`) |
| 1989-2072 | `CompareOrder`, `FnTuple`, `Func`/`OpaqueFunc`/`funcsym_t`, `Table`, `Pair`, `RefChild`, 해시/동등 함수 타입 |
| 2073-2565 | `StaticMap`, `Map[K,V]`(`HashMap` 래퍼), `HashMap`(메타 바이트 + 키/값 배열) |
| 2566-2979 | `ClosureData`, `@eq`, `@copy`, `@send`, `@destruct` 계열, `TraitStruct` 같은 컴파일러가 부르는 내부 도우미 |
| 2980-3223 | `MapEntry`, `AutoHash`/`AutoEq`, `Wyhash`(`Wyhash.hash` 는 `#[bind='Wyhash.hash']`) |
| 3224-3878 | `StrBuffer`, `Str`, `str`(문자열 연산 대부분이 `#[bind]`) |
| 3880-4062 | `GenericVector`, `PartialVector`, `Vector[T,N]`, `Ptr[T]` |
| 4063-4180 | `Range`, `TccState`, `Result[T]`, `Option[T]`, `Future[T]`, `FutureValue`, `FutureResolver` |
| 4181-4300 | `Ref`/`Borrow`/`ExBorrow`, `PtrSpan[T]` |
| 4306-4415 | `@trackMainLocal`(REPL), `SystemKind`, `VaList`, `Generator`, `GeneratorStatus`, `min`/`max`, `Dyn`, `Thread`, `spawn` |

문서 주석은 `--|` 로 쓴다. docs/gen-docs.cy 가 `cy.parse` 로 이 파일들(core, c, cy, meta, cli, libc, io, math, os, test)을 읽어 API 문서를 만든다(docs/gen-docs.cy:722-734).
`.github/workflows/gen-docs.yml` 이 `src/builtins/` 가 바뀌면 문서를 다시 빌드하는 이유다.

### 3.6 std 와 FFI: TinyCC 로 C 접착 코드를 만든다

`os`, `io`, `math`, `test` 의 역할은 3.4절 표와 같다. FFI 는 `c` 모듈과 `#[extern]` 속성으로 이루어지고 libffi 를 쓰지 않는다(`rg -i libffi` 결과 없음). 방식은 다음과 같다.

```
 #c.bind_lib('./libfoo.dylib')      -- c.cy: 컴파일 타임 문(EvalStr 인자). chunk.bind_lib 경로를 기록
 #[extern] fn add(a, b int) -> int  -- sema: func.type = .extern_ (sema.zig:2884-2897; 2894 에서 `func.type = .extern_`), chunk.has_extern_func = true
        │ 프로그램 초기화 직전: has_extern_func 인 청크가 하나라도 있으면 @initBindLib() 호출 (compiler.zig:730-760)
        ▼
 initBindLib (src/builtins/c.zig, "First compile C bindings and link with dll symbols")
   1. getDynLib: dl_resolver 로 경로를 정하고 dlopen (경로 없으면 실행 파일 자신)
   2. cgen 으로 "VM 슬롯 <-> C 인자" 변환 C 소스를 문자열로 생성 (genVmToExternFunc, genExternToVmFunc)
   3. TCC 로 메모리에서 컴파일: tcc_set_options("-nostdlib"), TCC_OUTPUT_MEMORY, tcc_compile_string, tcc_relocate
   4. 생성된 접착 함수 포인터를 FuncSymbol.initHostFunc 로 VM 심볼에 연결  ->  이후 extern 호출은 평범한 CALL_HOST
```

- 속성: `#[extern]`(심볼 이름 = 함수 이름), `#[extern='name']`, 가변 인자 `...`(`c.variadic`), 콜백 타입 `type Callback = #[extern] fn(a int, b int) -> int`(src/test/ffi/ffi.cy:73),
  `type Foo cstruct:` / `cunion`(C 레이아웃, 0 기본값 허용). 이들은 behavior-test 의 `FFI.` 케이스가 검증한다.
- 표준 라이브러리 `os` 와 `libc` 는 플랫폼별 `#[extern]` 선언(libc.macos.cy 등)을 통해 libc 를 부르므로 FFI 가 켜진 CLI 에서만 의미가 있다(behavior_test.zig:268-275 가 `test_config.ffi` 로 거른다).
- `-Dffi=false` 가 뜻하는 것: build.zig 가 `tcc` 모듈을 `src/tcc_stub.zig` 로 바꾸고 `stack_protector` 를 끈다(build.zig:722-727). 프로그램 초기화가 `bindExternFuncsWithoutFFI` 를 불러
  모든 extern 함수의 VM 진입점을 `externWithoutFFI` 로 묶는다(c.zig:181-216). 호출하면 `Calling an extern function requires FFI, which this build disables (-Dffi=false).` panic 이다.
  `zig build lib`(standalone)은 기본이 `ffi=false`(build.zig:166-170)이고 `-Dffi=true` 로 되돌릴 수 있다. 그래도 `math.cos` 같은 `#[bind, extern='cos']` 함수는 호스트 구현이 있어 FFI 없이 동작한다(실험: 5.2절 probe, 5.8절).
- `c` 모듈은 FFI 와 무관하게 남는다. `c.to_strz`, `c.from_strz` 와 `Ptr[byte]` 로 raw 포인터를 만진다(c.cy:11-21). 포인터 역참조는 `use c` 없이도 가능하다(7.4절 실험).

### 3.7 빌드, CI, 릴리스: 유지보수자가 알아야 할 것

`zig build -h` 가 보여 주는 스텝은 `cli`, `lib`, `build-test`, `behavior-test`, `lib-test`, `lib-standalone-test`, `cli-test`, `trace-test`, `test`, `version` 이다.
docs/build.md 는 `zig build test-trace` 라고 쓰지만 실제 이름은 `trace-test` 다(7.2절).

| 옵션 | 기본값 | 의미 | 근거 |
|---|---|---|---|
| `-Doptimize` | debug | CI 의 릴리스 모드는 ReleaseSafe | build.zig:41, pr-build.yml |
| `-Dffi` | 일반 빌드 true(비 wasm), `lib` 스텝 false | TCC 포함 여부 | build.zig:48, 411, 166-170 |
| `-Dtrace` | debug 일 때만 true | Trace 빌드(op 카운트, 객체 추적, 타이머). trace-test 는 항상 trace 로 따로 빌드 | build.zig:50, 548-552 |
| `-Dvm=zig\|c` | c | `zig` 엔진은 `exec_auto` 가 `error.Unsupported` 를 돌려줘 사실상 `c` 뿐 | build.zig:46, thread.zig exec_auto |
| `-Dmalloc` | 비 debug: mimalloc, debug: zig, msvc: malloc, wasm: zig | CLI 할당자. 라이브러리 `cl_vm_init` 은 항상 `c_allocator` | build.zig:434-460(`CliConfig.default`) |
| `-Dstatic` | true | `lib` 이 정적/동적 라이브러리 | build.zig:49 |
| `-Dtest-backend`, `-Dtest-filter`, `-Dno-cache` | vm, 없음, false | 테스트 백엔드(vm/jit/tcc/cc), 필터, 캐시 무시 | build.zig:44-45, 53 |
| `-Dselinux`, `-Dthreads`, `-Dstrip`, `-Djit`, `-Ddev` | false, true(wasm 제외), 비 debug 이면 strip, false(죽은 코드), true | SELinux 에서 TCC 메모리 확보 방식, 워커 풀, 심볼, JIT, 버전 접미사 `-DEV` | build.zig:43-68, 476-483 |

- 버전: `Version = "0.4.2"`(build.zig:10), `-Ddev`(기본 true)이면 `0.4.2-DEV`. 빌드 번호와 커밋은 환경 변수 `BUILD`, `COMMIT` 에서 온다(build.zig:474-475).
  로컬 빌드는 `build-0-local` 이다(실험: `cyber version` -> `Cyber 0.4.2-DEV build-0-local`). CI 는 `git rev-list --count <이전 minor 태그>..HEAD` 로 번호를 센다(latest-build.yml).
- translate-c: `cyber.h`, `vm.h`, `linenoise.h`, `mimalloc.h`, `libtcc.h` 다섯 헤더를 빌드 단계에서 Zig 모듈로 번역한다(build.zig:340-352 `translateC`). 패키지 `translate_c`
  (codeberg ziglang/translate-c)는 build.zig.zon 에 커밋 해시로 고정돼 있고 `zig-pkg/` 로 내려받는다(첫 빌드는 네트워크 필요, `zig-pkg/` 는 gitignore, CI 캐시 경로).
  `default_init = true` 가 없으면 extern 구조체 필드의 0 기본값이 사라져 `CLBindFunc{ .kind=..., .ptr=... }` 초기화가 깨진다(docs/decisions/project_zig_017_upgrade.md).
  귀결: `cyber.h` 를 고치면 capi.zig 의 모양이 자동으로 바뀌지만 lib.zig 의 `export fn` 시그니처와의 일치는 아무도 검사하지 않는다(7.2절의 불일치가 이 때문에 생겼다).
- `vm.h` 의 `ZVM`/`ZHeap` padding 은 Zig `VM`/`Heap` 의 `c` offset 을 모드별로 잰 값이고 어긋나면 comptime 검사가 빌드를 멈춘다. 큰 구조체를 건드리면 가장 먼저 걸리는 곳이다.
- CI(.github/workflows): `pr-build.yml`(PR), `latest-build.yml`(master push 와 버전 태그 `[0-9]+.[0-9]+*`), `gen-docs.yml`(docs/ 또는 src/builtins/ 변경 시 문서 배포).
  매트릭스는 ubuntu-24.04 x86_64-linux-gnu(cli, lib), x86_64 selinux(cli), macos-15-intel x86_64-macos(cli, lib), macos-15 aarch64-macos(cli, lib), windows-2022 x86_64-windows-gnu(cli, lib),
  x86_64-windows-msvc(lib. 테스트는 `-Dffi=false`), wasm32-wasi(cli. 빌드한 테스트를 wasm3 로 실행)이다. 각 job 은 debug -> ReleaseSafe 로 `zig build test`를 돌리고
  x86_64-linux 와 aarch64-macos cli job 은 ReleaseFast 도 돌린다. 교차 빌드는 `-Dcpu=baseline`(pr-build.yml 의 `ZIG_TARGET_FLAG`)이다. Zig 는 0.17.0 고정(`ZIG_VERSION`).
- 릴리스: 태그 push 가 `latest-build.yml` 로 릴리스를 만든다. `concurrency.group: latest` 가 `cancel-in-progress` 라 master push 와 태그 push 를 동시에 하면 한쪽이 취소된다.
  릴리스 번들은 실행 파일 옆에 `src/`(공통 .cy 10개 + 타깃별 모듈)를 포함한다(build.zig:132-157). `install.sh` 가 `CYBER_HOME`/`CYBER_BIN` 으로 푼다(docs/decisions/project_fork_release_ci.md).
- 알려진 플랫폼 제약(같은 문서): msvc 는 translate-c 가 mimalloc.h 의 `__declspec` 을 못 읽어 libc malloc, macOS x86_64 는 `stat$INODE64`, wasm32 는 `Value` C ABI 간접 전달,
  Linux x86_64 의 AVX2 경로는 baseline CPU 에서 컴파일되지 않아 `-Dcpu=skylake` 로 교차 빌드해야 잡힌다.
- Zig 0.17 이후 코드 규칙(docs/specs/2026-10-25-zig-0.17-upgrade-design.md, project_zig_017_upgrade.md): `Io` 는 `stdx.io()`, 바이트코드 `u48` 피연산자는 6바이트만 쓴다(`setOpArgU48`,
  회귀 테스트가 lib.zig:1357), 읽힐 수 있는 필드를 `undefined` 로 두지 않는다, extern 타입 재해석은 `.val`/`stdx.reinterpret`. `bytecode.zig` 안의 `test` 블록은 어느 단계에서도
  참조되지 않아 실행되지 않는다(문서 기록. 이 장에서 재확인하지 않음).

## 4. 소스 읽기 지도

처음부터 끝까지 읽는 순서다. 괄호는 읽는 이유다.

1. examples/libcyber/main.c(37줄) -> host_tool.c(103줄) -> bind_module.c(121줄). (embedding 의 최소 형태, 호스트 도구 패턴, 타입/전역 바인딩)
2. src/include/cyber.h:1-130(타입, enum, 호스트 함수 typedef), 172-250(BindFunc/BindType/Loader), 280-330(Config), 333-445(VM API), 452-530(Thread API). (3.1절 표로 먼저 훑고 주석을 읽는다)
3. src/lib.zig:27-60(생성), 208-287(eval), 440-500(에러/resolver), 577-613(mod_add_*), 821-1000(상태 유지 테스트), 1189-1355(슬라이스/문자열 소유 테스트). (테스트가 사용 설명서다)
4. src/vm.zig:132-197(init), 354-384(compile/resetVM), 398-415(local saves), 421-512(eval), 593-610(exec_bytecode).
5. src/compiler.zig:279-312(compile), 315-531(compileInner), 879-918(builtin 청크 특수 심볼), 1052-1136(loadChunk/ensureModule), 1439-1514(resolver/loader).
6. src/sema.zig:2807-2995(`#[bind]` 해석), src/module.zig:316-345(호스트 함수 심볼), src/sema_type.zig:35-80(호스트 타입), src/bc_gen.zig:286-300, 3104-3120(call_host).
7. src/thread.zig:543-566(ret/param), 808-814(ret_panic), src/vm.c:328-336(CHECKPOINT), 940-961(CALL_HOST).
8. src/builtins/core.zig:34-243(표와 bind), 284-398(래퍼 네 종류), 1186-1262(`panic`, `prints`), 1533-1560(`trackMainLocal`), 1637-1660(`alloc`/`free`). 이어서 core.cy 를 3.5절 목차로 훑는다.
9. src/main.zig:29-120, 151-300, src/cli.zig:64-260, src/std/cli.cy, src/builtins/cy.cy:1205-1407, src/builtins/cy.zig:77-190. (CLI 와 REPL)
10. src/behavior_test.zig:419-470, 585-710, src/test/setup.zig:145-350. (테스트 하네스) 마지막으로 build.zig:30-300, .github/workflows/pr-build.yml.

## 5. 실습

준비. 임시 작업 폴더(S)에 라이브러리를 만들고 C 프로그램을 링크한다. 저장소의 `zig-out` 을 건드리지 않으려고 `--prefix` 와 `--cache-dir` 를 임시 폴더로 돌린다.

```sh
S=/tmp/cyber-lab && mkdir -p $S
cd /Users/kez/Repository/cyber-script
zig build lib --prefix $S/lib-rf -Doptimize=ReleaseFast --cache-dir $S/zig-cache   # libcyber.a 2.1MB, 캐시가 있으면 1초대
clang -o $S/host_tool examples/libcyber/host_tool.c -I src/include $S/lib-rf/lib/libcyber.a
```

주의. 같은 prefix 로 `lib-test` 나 `lib-standalone-test` 를 돌리면 Debug 빌드가 `lib/libcyber.a` 를 덮어쓴다. 이 장의 실험은 ReleaseFast 용 prefix(`lib-rf`)와 분리했다.
Debug 라이브러리는 컴파일 에러마다 Zig 에러 리턴 트레이스를 stderr 에 찍는다(compiler.zig:38, 293-295 `dumpCompileErrorStackTrace`가 debug 모드에서만 켜짐. 직접 확인: 같은 프로그램의 Debug 링크 결과에 `parser.zig:2779 in reportErrorAtSrc` 같은 줄이 나왔다).

### 5.1 예제 세 개 실행

링크 시 `CL_BYTES("...")` 가 `const char*` 를 `char*` 로 받아 경고가 난다(CLBytes.ptr 이 const 가 아니다). 동작에는 영향이 없다.

```
$ ./main
My print: 3
Success!
$ ./bind_module
My print: 2
My print: 234
My print: 12300
MyNode deinit.
Success!
Live objects: 0
$ ./host_tool        (요약은 ANSI 색 코드를 지운 형태)
My print: {"tool":"read_file","args":{"path":"/etc/hosts"},"ok":true}
tool call: Success!
compile error: CompileError: Undeclared variable `undefined_thing`.
...
panic: panic: Out of bounds index: 5      (앞의 panic: 은 예제가 붙인 label, 뒤가 요약의 첫 줄)
core:148:5 panic_oob:  ->  core:1729:9 Array.@index_addr:  ->  eval:2:7 main:
...
use os: CompileError: Failed to load module: os
main: Success!
body after main: Success!
Live objects: 0
```

관찰 포인트.
- `print` 가 `printer` 를 두 번 부르므로(본문, 개행) 예제는 길이 1 인 `\n` 호출을 건너뛴다.
- panic 요약에 라이브러리 내부 프레임(`core:148 panic_oob`, `core:1729 Array.@index_addr`)이 나온다. core.cy 가 매 실행 컴파일되는 소스이기 때문에 스택 트레이스에 보인다.
- `use os` 의 위치 줄이 두 번 출력된다(같은 줄이 두 리포트로 들어감). 내용은 같다.
- 이 세 예제는 `zig build lib-standalone-test` 가 그대로 실행한다. 이 세션에서 돌려 `Build Summary: 37/37 steps succeeded`, 세 프로그램 모두 `Live objects: 0` 을 확인했다.

### 5.2 에이전트 루프용 호스트 직접 만들기

목표: 도구 하나(`agent.tool`)를 노출하고, 허용 목록 loader 로 모듈을 제한하고, 턴마다 fuel 을 걸고, 에러 요약의 색 코드를 지우고, 턴 사이에 상태를 이어 가는 호스트.
아래 세 조각을 한 파일 agent_host.c 로 이어 붙인다(저장소에는 넣지 않았다. 임시 폴더에서 컴파일).

```c
#include <stdio.h>
#include <string.h>
#include "cyber.h"

static char out[4096]; static size_t out_len;          // 한 턴의 print 출력을 모은다
static void on_print(CLThread* t, CLBytes s) {
    (void)t;
    if (out_len + s.len < sizeof out) { memcpy(out + out_len, s.ptr, s.len); out_len += s.len; }
}

// fn tool(name str, args str) -> str : str 값 인자 둘은 호스트가 해제한다.
static CLRet tool(CLThread* t) {
    CLstr* ret = cl_thread_ret(t, sizeof(CLstr));      // 1) 반환 슬롯을 먼저
    CLstr name_s = cl_thread_str(t);                    // 2) 인자를 선언 순서대로
    CLstr args_s = cl_thread_str(t);
    CLBytes name = cl_str_bytes(name_s), args = cl_str_bytes(args_s);
    if (name.len == 6 && strncmp(name.ptr, "forbid", 6) == 0) {
        cl_str_deinit(t, &name_s); cl_str_deinit(t, &args_s);
        return cl_thread_ret_panic(t, CL_BYTES("tool 'forbid' is not allowed"));
    }
    char buf[256];
    int n = snprintf(buf, sizeof buf, "{\"tool\":\"%.*s\",\"args\":%.*s}", (int)name.len, name.ptr, (int)args.len, args.ptr);
    *ret = cl_str_init(t, (CLBytes){ buf, (size_t)n });
    cl_str_deinit(t, &name_s); cl_str_deinit(t, &args_s);
    return CL_RET_OK;
}
```

```c
// 허용 목록 loader: agent 는 호스트 모듈, core/meta/math/c/test 만 내장 모듈로 통과. (math 가 c 를 use 한다)
static bool loader(CLVM* vm, CLSym* mod, CLBytes uri, CLLoaderResult* res) {
    if (uri.len == 5 && !strncmp(uri.ptr, "agent", 5)) {
        cl_mod_add_func(mod, CL_BYTES("tool"), CL_BIND_FUNC(tool));
        res->src = CL_BYTES("#[bind] fn tool(name str, args str) -> str\n");
        res->manage_src = false;
        return true;
    }
    static const char* allow[] = { "core", "meta", "math", "c", "test" };
    for (size_t i = 0; i < 5; i++)
        if (uri.len == strlen(allow[i]) && !strncmp(uri.ptr, allow[i], uri.len))
            return cl_default_loader(vm, mod, uri, res);
    return false;
}

static void strip_ansi(CLBytes s, char* dst, size_t cap) {      // 에러 요약의 ESC[31m ... ESC[0m 제거
    size_t n = 0;
    for (size_t i = 0; i < s.len && n + 1 < cap; i++) {
        if (s.ptr[i] == 0x1b) { while (i < s.len && s.ptr[i] != 'm') i++; continue; }
        dst[n++] = s.ptr[i];
    }
    dst[n] = 0;
}
```

```c
static void turn(CLVM* vm, const char* label, const char* src) {
    out_len = 0;
    CLEvalConfig cfg = clDefaultEvalConfig();
    cfg.persist_main = true;                 // 턴 사이에 지역 변수 · 함수 · use 를 이어 간다
    cl_vm_set_fuel(vm, 100000);              // 턴마다 검사점(루프 역방향 점프, 호출) 상한
    CLEvalResult res;
    CLResultCode code = cl_vm_evalx(vm, CL_BYTES("turn"), (CLBytes){ (char*)src, strlen(src) }, cfg, &res);
    CLBytes name = clResultName(code);
    printf("[%s] %.*s\n", label, (int)name.len, name.ptr);
    if (out_len) printf("  stdout: %.*s", (int)out_len, out);
    if (code != CL_SUCCESS) {
        CLBytes s = cl_vm_error_summary(vm); char clean[1024];
        strip_ansi(s, clean, sizeof clean);
        printf("  error: %s\n", clean);
        cl_vm_freeb(vm, s);
    }
}

int main(void) {
    CLVM* vm = cl_vm_init();
    cl_vm_set_loader(vm, loader);
    cl_vm_set_printer(vm, on_print);
    CLEvalResult warm; cl_vm_eval(vm, CL_BYTES(""), &warm);   // 예열. 첫 eval 이 컴파일 에러면 VM 이 깨지던 F-04 는 2026-11-08 수정돼 이제 없어도 된다 (5.3절, 7.3절)

    turn(vm, "1 setup",    "use agent\nuse math\nn := 0\nfn bump(k int) -> int:\n  return k + 1\n");
    turn(vm, "2 state",    "n = bump(n)\nn = bump(n)\nprint('n=%{n}\\n')\n");
    turn(vm, "3 tool",     "r := agent.tool('read_file', '{\"path\":\"a.txt\"}')\nprint(r + '\\n')\n");
    turn(vm, "4 syntax",   "x := \n");
    turn(vm, "5 after",    "print('n still %{n}\\n')\n");
    turn(vm, "6 forbidden","_ = agent.tool('forbid', '{}')\n");
    turn(vm, "7 os",       "use os\n");
    turn(vm, "8 spin",     "m := 0\nwhile true:\n  m += 1\n");
    turn(vm, "9 after",    "print('alive\\n')\n");
    printf("live objects: %zu\n", cl_thread_count_objects(cl_vm_main_thread(vm)));
    cl_vm_deinit(vm);
}
```

컴파일하고 실행한 결과(stderr 는 비어 있었다).

```
[1 setup] Success
[2 state] Success
  stdout: n=2
[3 tool] Success
  stdout: {"tool":"read_file","args":{"path":"a.txt"}}
[4 syntax] CompileError
  error: ParseError: Expected right expression for assignment statement.   (turn:2:1)
[5 after] Success
  stdout: n still 2
[6 forbidden] PanicError
  error: panic: tool 'forbid' is not allowed   (turn:1:5 main:  _ = agent.tool('forbid', '{}'))
[7 os] CompileError
  error: CompileError: Failed to load module: os
[8 spin] InterruptError
  error: panic: Out of fuel.   (turn:2:1 main:  while true:)
[9 after] Success
  stdout: alive
live objects: 0
```

여기서 확인된 사실들.
- 턴 2 에서 `n` 이 턴 1 의 값(0)을 이어받아 2 가 됐고 턴 5 에서도 유지됐다. 컴파일 에러(턴 4)는 저장본을 건드리지 않는다.
- 턴 6 의 호스트 panic 이후에는 `n` 이 사라진다. 이 데모에서 턴 8 이 `n` 이 아니라 새 변수 `m` 을 쓴 이유는 처음 `n += 1` 로 시도했을 때 `Undeclared variable n` 컴파일 에러가 났기 때문이다
  (persist_main 의 panic 규칙: 힙이 비워지므로 변수 전부 폐기). 에이전트 루프에서 도구 실패가 panic 이면 세션 변수를 잃는다는 뜻이다.
- 문장으로 쓴 호출 `agent.tool(...)` 의 반환 값을 버리면 컴파일 에러다. 처음 시도에서 `Expected assignment to a variable or placeholder for str` 가 나서 `_ =` 를 붙였다.
- 처음에 허용 목록에서 `c` 를 뺐더니 턴 1 이 `Failed to load module: c`(`math:1:1: use c`)로 실패했다. math 가 c 에 의존하므로 `math` 를 허용하려면 `c`(포인터 도구 포함)도 열어야 한다.
- 호스트 함수가 str 인자를 `cl_str_deinit` 하지 않으면 누수다(lib.zig:1259 의 테스트가 누수 검사 allocator 로 증명). 이 데모는 `live objects: 0` 으로 끝났지만, 누수 여부를 `cl_thread_count_objects` 로 확신할 수는 없다
  (docs/decisions/project_embedding_agent_loop.md 가 이 함수로는 이 누수가 잡히지 않았다고 기록한다).

### 5.3 반복 eval 과 상태: C 로 확인한 결과

아래는 임시 폴더의 rf_probe*.c 로 직접 얻은 결과다. 요점만 표로 옮긴다.

| 실험 | 관찰 |
|---|---|
| printer 콜백의 `t` 인자와 `cl_vm_main_thread(vm)`, `vm` 비교 | `t == vm` (yes), `t == main_thread` (no). 콜백이 받는 첫 인자는 CLThread 가 아니라 VM 포인터다. core.zig:1256-1262 가 `@ptrCast(t.c.vm)` 을 넘긴다 |
| `fn main() -> int { return 42 }` | `res_t=6`, `cl_value_desc` -> `42`. `-> str` 은 `res_t=23`, `'abcdef'`. `-> float` 은 `res_t=13`, `1.5`. `-> []int` 의 `cl_value_desc` 는 `(type=174)<주소>` 만 준다 |
| 마지막 줄이 `1 + 2` | `CompileError: Expected assignment to a variable or placeholder for int` (cyber.h:383 주석과 다름) |
| persist_main=false: eval1 에서 `x := 5`, `fn foo`; eval2 에서 `print(x)` / `print(foo())` | 둘 다 `Undeclared variable` |
| persist_main=true: `x := 5; fn foo() -> int: return 7` -> `print(x + foo()); x = x + 1` -> `print(x)` | `12` 다음 `6`. 이어 `panic('boom')` 후 `print(x)` 는 `Undeclared variable x` |
| 호스트 함수 `check_pos(-1)` 이 `cl_thread_ret_panic("host says: negative")` | `PanicError`, 요약 `panic: host says: negative` + `probe:2:7 main:` 줄 |
| `cl_vm_set_fuel(vm, 1000)` + `while true: pass` | `InterruptError`, 요약 `panic: Out of fuel.`, 직후 `print('alive')` 성공 |
| `use u 'lib/util'` | loader 가 받은 uri 는 `lib/util` 문자열 그대로 |
| `use math`, `math.cos(0.0)` (ffi=false 라이브러리) | loader 가 `math` 다음 `c` 를 요청, 결과 `4`(sqrt(16.0)), `1`(cos(0.0)) |
| 모듈 소스를 v1 -> v2 로 바꾸고 같은 VM 에서 재 eval | loader 재호출 없음(v1 유지), `cl_vm_reset` 후 v2 |

가장 중요한 발견은 첫 eval 의 컴파일 실패다. 각 시나리오를 `fork()` 한 자식 프로세스에서 돌려 크래시를 격리했다(rf_probe2, rf_probe3, rf_probe8).

| 시나리오 (같은 VM) | 결과 |
|---|---|
| 첫 eval 이 구문 오류(`x := `), 둘째가 정상 | 둘째 eval 에서 SIGSEGV(신호 11) |
| 첫 eval 이 구문 오류 두 번, 이어서 정상 | SIGSEGV |
| 첫 eval 이 의미 오류(`print(nope)`), 둘째가 정상 | 둘째가 `CompileError: @program_init has already been declared with the same function signature.` |
| 첫 eval 의 uri 와 둘째의 uri 를 다르게 해도 | 의미 오류 뒤 abort(`panic: Unsupported: .null`), 구문 오류 뒤 abort(`panic: No such field name`) |
| 첫 eval 이 성공한 뒤 구문/의미 오류, 이어서 정상 | 정상 동작 |
| 첫 eval 이 panic 인 뒤 정상 | 정상 동작 |
| 구문 오류 뒤 `cl_vm_reset(vm)` 하고 정상 | 정상 동작 |
| 첫 eval 로 빈 소스 `""` 를 먼저 돌린 뒤 구문 오류, 이어서 정상 | 정상 동작 |
| 성공한 eval 뒤 `cl_vm_validate(good)` | persist 변수 `x` 소실(`print(x)` 컴파일 에러), 이후 eval 은 동작 |
| 성공한 eval 뒤 `cl_vm_validate(bad)` | 이후 eval 이 `CompileError`, 그 요약을 읽다 SIGBUS(신호 10). `cl_vm_reset` 을 끼우면 정상 |

원인은 `cont` 와 chunk 상태의 비대칭으로 추정한다. `Compiler.compile` 은 성공해야 `cont = true` 로 바꾸는데(compiler.zig:310), 실패한 첫 컴파일은 core 청크, main 청크와 `@program_init` 예약 등
중간 상태를 남기고 `cont` 는 false 로 둔다. 다음 컴파일이 `!cont` 경로로 core 를 다시 올리면서 이미 만들어진 청크와 충돌한다. `cl_vm_validate`/`cl_vm_compile` 이 `resetVM` 으로
`cont` 를 false 로 되돌린 뒤(vm.zig:383) 컴파일에 실패하면 같은 상태가 된다. 증상과 우회(빈 소스로 데우기, 실패 뒤 `cl_vm_reset`)는 실험으로 확인했고, 위 원인 설명은 코드 판독에서 온 추정이다
(디버거나 trace 빌드로 충돌 지점을 잡지는 않았다). 에이전트 루프에서 첫 입력이 모델이 쓴 코드라면 이 경로가 곧바로 호스트 크래시이므로 최우선으로 고칠 후보다(7.4절).

2026-11-08 수정(`f5f2d241`): 추정대로였다. lib 테스트로 재현하니 구문 오류 두 번째 eval 에서 abort, `cont` 를 core 적재 직후 true 로 바꾸면 그 다음 정상 eval 이 `No such field \`len\`` panic 으로 바뀌었다(core 청크의 sema 와 코드 생성이 `chunk_start` 이후 범위에만 돌아 첫 실패 때 건너뛴 core 가 영영 처리되지 않음). 그래서 `Compiler.first_compile_failed` 를 세우고 다음 `VM.eval` 이 `resetVM()` 으로 처음부터 다시 시작하게 했다(사용자가 하던 `cl_vm_reset` 우회를 자동화한 것. fuel · 스택 상한 · printer · user data 는 reset 이 건드리지 않는다). 같은 테스트에서 둘째 구멍도 드러났다: 성공한 eval 뒤 실패한 eval 의 `fn broken` 이 `persist_main` alias 로 다음 eval 에 넘어가 `broken()` 호출이 SIGSEGV(바이트코드 없음). `last_compile_failed` 면 실패한 main 청크 자신의 선언은 넘기지 않는다. 위 표의 시나리오는 모두 lib 테스트 `Evals after a failed first compile.` 에 있다. 아래 예열 eval 은 더 필요 없다.

### 5.4 core.cy 의 함수 하나를 호스트까지 따라가기

`print('hello')` 가 호스트에 닿는 길을 검색 명령으로 따라간다.

```
$ rg -n 'prints_' src/builtins/core.cy src/builtins/core.zig
src/builtins/core.cy:160:    prints_('\n')
src/builtins/core.cy:163:    prints_(to_print_string(x))
src/builtins/core.cy:166:-fn prints_(s str)          <- 바로 위 줄에 #[bind]. 앞의 `-` 는 비공개(src/test/syntax/visibility.cy)
src/builtins/core.zig:84:    .{"prints_",        cFunc(prints)},
$ sed -n 1256,1262p src/builtins/core.zig            <- 호스트 본문
pub fn prints(t: *cy.Thread) callconv(.c) C.Ret {
    _ = t.ret(void);                                  <- 반환 슬롯 먼저 (void 라도)
    const str = t.param(cy.heap.Str);                 <- 값 인자: 호스트가 소유
    defer t.heap.destructStr(&str);                   <- 그래서 해제
    t.c.vm.print.?(@ptrCast(t.c.vm), C.to_bytes(str.slice()));
    return C.RetOk;
}
$ cyber compile hello.cy | rg call_host
0:97  .call_host: %4 = prints_(%8..%9)                <- main 에 인라인된 print 의 prints_('\n')
0:148 .call_host: %10 = prints_(%14..%15)             <- core.prints 본문의 prints_(to_print_string(x))
```

이 짧은 함수에서 2절이 한꺼번에 보인다. 선언(core.cy:166) -> 표(core.zig:84) -> 본문(core.zig:1256), 슬롯 규약(`ret` 먼저, `param` 다음), 소유 규약(`destructStr`),
그리고 앞서 본 printer 인자 문제: `t.c.vm.print.?(@ptrCast(t.c.vm), ...)` 는 VM 포인터를 `CLThread*` 자리에 넘긴다(7.3절).

같은 방식으로 `Array.append` 도 따라가 보라. `rg -n 'alloc_|fn \(&&Array\[\]\) (append|ensure_cap)' src/builtins/core.cy` 로 core.cy:1784, 1839, 24, 34 가 나오고, core.zig:79 의
`{"alloc_", zErrFunc(alloc)}` 와 core.zig:1637 의 `alloc` 이 마지막 도착지다. `alloc` 은 `t.heap.new_byte_buffer(size)` 를 부르는 것이 전부다.

### 5.5 CLI 와 REPL

```
$ printf 'x := 5\ny := x * 2\nprint(y)\nfn sq(n int) -> int:\n  return n * n\n\nprint(sq(y))\nuse os\nprint(os.cwd())\nuse math\nprint(math.sqrt(16.0))\nz := 1/0\nprint(x)\n.exit\n' | cyber
Cyber 0.4.2-DEV build-0-local REPL
Commands: .exit
10                                     <- print(y): 변수 이월
100                                    <- 함수 정의도 이월 (빈 줄로 블록 제출)
CompileError: Failed to load module: os      <- 안쪽 VM 은 기본 loader 만 쓴다
CompileError: Can not find the symbol `cwd` in `os`.
4
panic: Division by zero.               <- 이후 "eval:1:6 main:" 스택
Variables were reset.
CompileError: Undeclared variable `x`.      <- panic 이 힙을 비우므로 변수 전부 폐기
```

- 맨 이름만 입력하는 표현식 문장(`1 + 2`)은 컴파일 에러(`Expected assignment to a variable or placeholder`)라 REPL 이 값을 바로 보여 주지 않는다. `print(x)` 를 써야 한다.
- 릴리스 CLI 가 `core` 를 어디서 읽는지는 trace 로 확인했다. `-Dtrace=true` CLI 로 `cyber -v empty.cy` 를 돌리면 `Invoke module loader: .../trace-out/bin/src/builtins/core.cy` 와
  `.../meta.cy`, 사용자 파일 세 줄이 나온다. 즉 빈 스크립트도 디스크에서 core.cy, meta.cy 두 파일을 읽는다.

### 5.6 테스트: CLI 로 개별 실행, 새 테스트 만들기

개별 .cy 테스트는 CLI 로 바로 돌아간다. 통과하면 출력이 없고 종료 코드 0, 기대 실패(`_error`, `_panic`)는 기대한 리포트가 나오고 종료 코드 1 이다.

```
$ cyber src/test/control_flow/while_cond.cy ; echo $?          -> (출력 없음) 0
$ cyber src/test/syntax/adjacent_stmt_error.cy                 -> exit 1
ParseError: Expected end of line or file. Got ident.
<절대경로>/src/test/syntax/adjacent_stmt_error.cy:1:20:
if true: foo = 123 foo = 234
                   ^
$ cyber src/test/core/panic_panic.cy                           -> exit 1, "panic: Boom" + 스택
```

`--cytest` 주석은 CLI 에서는 평범한 주석이다. 기대값 비교는 하네스만 한다. 그래서 간이 비교 스크립트를 만들어 쓰면 새 테스트를 빠르게 검증할 수 있다(`error` 형 전용, `panic` 의 `[trace]` 경계는 처리하지 않음).

```sh
#!/bin/sh
# cytest.sh file.cy : `--cytest: error` 뒤 `--` 주석을 기대 리포트로 보고 CLI 출력과 diff
f="$1"; T=$(mktemp -d); abs=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
cyber "$f" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$T/actual"                       # ANSI 제거 (하네스와 같음)
sed -n '/^--cytest:/,$p' "$f" | tail -n +2 | sed 's/^--//' | sed "s#@MainPath()#$abs#" > "$T/expected"
diff "$T/expected" "$T/actual" && echo MATCH; rm -rf "$T"
```

```
$ cat new_error.cy                                   (임시 폴더에서 만든 새 테스트. 저장소에 넣지 않았다)
use test

x := 1
y := x + nope

--cytest: error
--CompileError: Undeclared variable `nope`.
--
--@MainPath():4:10:
--y := x + nope
--         ^~~~
$ ./cytest.sh new_error.cy                           -> MATCH
$ ./cytest.sh src/test/syntax/adjacent_stmt_error.cy -> MATCH       (기존 테스트로 스크립트 자체를 검증)
```

(처음에는 `y := x + 'a'` 를 기대 에러로 썼다가 실패했다. `'a'` 는 한 글자 룬 리터럴로 취급돼 `1 + 'a'` 가 98 로 컴파일되기 때문이다. 기대 에러는 반드시 먼저 CLI 로 실제 출력을 본 뒤 적는다.)

새 테스트 추가 절차.
1. `src/test/<영역>/<이름>.cy` 를 만든다. 실패 기대는 이름 끝에 `_error` 나 `_panic` 을 붙이는 관례다. 마지막에 `--cytest: pass|error|panic` 과 기대 텍스트.
2. 반드시 `src/behavior_test.zig` 의 맞는 `test_*` 함수에 `run.case("영역/이름.cy")` 를 추가한다. 자동 발견이 없으므로 안 넣으면 영원히 실행되지 않는다.
3. 반복 실행은 CLI 로 한다. `zig build behavior-test` 는 전체를 돌리고 `-Dtest-filter` 는 Zig `test` 이름("Tests.")만 거른다. 특정 파일만 돌리려면 behavior_test.zig:47-48 의
   `caseFilter` 상수를 직접 고쳐 다시 빌드해야 한다.
4. 누수는 실패다. 힙 객체가 남으면 `unfreed objects: N` panic.

목록 밖 .cy 20개를 직접 실행해 분류했다.

| 분류 | 파일 | 확인 |
|---|---|---|
| 벤치마크 7 | bench/{alloc, fib, fiber, for, heap}/*.cy, bench/string/index.cy, index_rare.cy | `"Compile."` 케이스가 index_rare 를 뺀 6개를 컴파일만 한다(behavior_test.zig:493-498) |
| 다른 테스트의 부속 5 | modules/test_mods/{a, init_panic_error, init_throw_error, stmt_error}.cy, main.cy | import 대상, 인메모리 eval 의 기본 uri |
| FFI 전용 1 | ffi/ffi.cy | `test "FFI."` 가 `case("ffi/ffi.cy")` 로 실행 |
| 주석 처리 2 | memory/gc_reference_cycle_reachable.cy, meta/dump_locals.cy | 목록에 주석으로 남아 있음 |
| 등록만 빠진 것 2 | syntax/adjacent_stmt_error.cy, memory/scope_return_too_ephemeral_error.cy | CLI 로 실행하면 기대 리포트와 일치(직접 확인). 목록에 넣으면 되는 후보 |
| 옛 문법 3 | core/RawStaticMap.cy, functions/named_parameter_test.cy, cli_test.cy | `var`, 타입 없는 매개변수 등 0.3 문법이라 파싱 에러. 죽은 파일 |

### 5.7 시작 비용: core.cy 는 매 실행 컴파일된다

CLI (hyperfine, 50회, 워밍업 5회, ReleaseSafe 바이너리).

```
$ hyperfine -N --warmup 5 --runs 50 "cyber hello.cy" "cyber empty.cy" "/usr/bin/true"
cyber hello.cy   4.3 ms ± 0.2 ms   (메모리 7.6 MiB)
cyber empty.cy   4.3 ms ± 0.1 ms
/usr/bin/true    0.82 ms ± 0.12 ms
```

`print('hello')` 와 빈 파일의 시간이 같다. 프로세스 기본 비용(약 0.8ms)을 빼면 약 3.5ms 가 core.cy(4,415줄)와 meta.cy(338줄)를 읽고 파싱하고 컴파일하는 고정비용이다.
`cyber compile empty.cy` 로 본 빈 프로그램의 바이트코드는 core 청크 함수 192개, 명령어 5,934개, 사용자 청크는 함수 2개, 명령어 21개다
(`awk` 로 `--chunkN` 구간별 `N:pc .op` 줄 수를 센 값. hello 는 core 182개/5,839개, 사용자 청크 14개/161개). 비템플릿 함수는 호출되지 않아도 전부 생성된다는 뜻이다.

라이브러리(C 프로그램, ReleaseFast libcyber.a, 5회 반복, 단위 ms).

| 단계 | 첫 회 | 이후 4회 범위 |
|---|---|---|
| `cl_vm_init` | 0.73 | 0.017 ~ 0.041 |
| 첫 `cl_vm_eval("")` (core 컴파일 포함) | 6.3 | 2.85 ~ 4.4 |
| 같은 VM 의 둘째 eval (`print('hello')`) | 0.032 | 0.014 ~ 0.034 |
| `for 0..1000` 누적 루프 eval | 0.019 | 0.013 ~ 0.028 |
| `cl_vm_reset` | 0.17 | 0.079 ~ 0.14 |
| reset 직후 eval (core 재컴파일) | 7.8 | 2.7 ~ 3.8 |

해석. (1) 에이전트 루프는 VM 을 한 번 만들어 계속 쓰는 쪽이 압도적으로 싸다(턴당 수십 마이크로초 대 3ms). 턴마다 `cl_vm_reset` 이나 새 VM 은 3ms 를 매번 낸다.
(2) 바이트코드가 호스트 함수 주소를 품고 직렬화 API 도 없어서(2.4절) core 를 미리 컴파일해 두는 최적화는 코드 변경이 필요하다. (3) docs/decisions/project_embedding_agent_loop.md 의 측정
(init 0.2ms, 첫 eval 2.8ms, 둘째 0.01ms, reset 뒤 2.0ms)과 같은 크기다. 머신과 부하에 따라 다르다.

### 5.8 FFI 와 -Dffi=false

```
$ clang -shared -o libfoo.dylib examples/foo.c && cp examples/ffi.cy . && cyber ffi.cy
444
$ cat cs.cy    (cstruct 를 선언하고 extern add 를 호출)    $ cyber cs.cy      ->  3
```

같은 `#c.bind_lib` + `#[extern] fn add` 소스를 `-Dffi=false` 로 만든 libcyber 에 eval 하면(rf_probe6) 다음이 나온다.

```
code=3
panic: Calling an extern function requires FFI, which this build disables (-Dffi=false).
eval:7:9 main:
  print(add(1, 2))
```

컴파일은 통과하고 호출 시점에 panic 이다. 에이전트 루프가 라이브러리 모드로 모델 코드를 돌릴 때 extern 으로 임의 C 함수를 부르는 길이 막혀 있다는 뜻이지만, 포인터 연산은 별개다(7.4절).

### 변형 과제

1. printer 인자 확인. `cl_vm_set_user_data` 로 구조체를 걸고 printer 안에서 `cl_vm_user_data(cl_thread_vm(t))` 를 읽어 보라. 7.3절의 증상(`t` 가 VM 포인터)으로 어떻게 되는지 보고, core.zig:1248-1262 를 `t` 로 고치면 lib 테스트 하나로 회귀를 잡을 수 있는지 설계해 보라.
2. 첫 eval 실패 재현 테스트를 lib.zig 에 추가한다. 구문 오류 첫 eval 뒤에 정상 eval 을 하는 `test` 를 쓰고(현재는 크래시하므로 `fork` 대신 Zig 의 `-Dtrace` Debug 빌드로 어느 단언에서 멈추는지 본다), `Compiler.compile` 의 실패 경로가 남긴 상태를 목록으로 만들어 보라.
3. `CLEvalConfig` 에 모듈 허용 목록 대신 쓸 수 있는 필드를 설계하라. 지금은 loader 에서 걸러야 하므로(5.2절) `math` -> `c` 의존을 어떻게 다룰지가 핵심이다.
4. `[]str` 를 받아 각 길이를 `[]int` 로 돌려주는 호스트 함수를 `cl_slice_deinit(t, str_t, &s)` 로 구현하고, `[&]str` span 으로 받는 버전과 비교하라. `elem_t` 를 NULL 로 주면 어떤 누수가 생기는지 lib.zig:1296-1355 의 테스트 형태로 재현해 본다.
5. 4절의 목록 밖 테스트 중 "등록만 빠진 것 2개"를 `test_syntax`/`test_memory` 에 등록하고 `zig build behavior-test` 가 통과하는지 확인하라(이 장에서는 돌리지 않았다).
6. core.cy 에 `#[bind] fn clock_ms() -> int` 를 추가하고 core.zig 의 `funcs` 에 `zErrFunc` 항목을 더해 보라. 릴리스 CLI 는 `zig-out/bin/src/builtins/core.cy` 를 읽으므로 .cy 만 바꾸면 되지만 .zig 쪽은 재빌드가 필요하다. `cyber compile` 에서 `call_host` 가 보이면 성공이다.

## 6. 0.3 -> 0.4 변경 관점 / 설계 철학 메모

임베딩 API 의 변화는 타입 시스템 변화의 그림자다(docs/history/embedding_cli.md 의 해석을 코드로 다시 확인했다). 0.3 은 값이 모두 `CsValue` 라는 하나의 동적 표현이어서 호스트 함수가
`CsValue f(CsVM*, const CsValue* args, uint8_t nargs)` 형태를 받았다. 0.4 는 값이 unboxed 정적 타입이라 호스트가 스택 슬롯의 크기와 배치를 알아야 하고, 그래서 `cl_thread_float(t)`
같은 타입별 접근자와 "Cyber 타입은 C 구조체와 같은 배치"라는 규칙이 생겼다. 바인딩이 빨라진 대가로 타입 검사가 없다. 틀린 접근자는 조용히 슬롯을 어긋나게 한다. `#[bind]` 가
`@host` 를 대체한 것은 속성 문법으로의 통일(`#[extern]`, `#[generator]` 와 같은 모양)이다.

가장 큰 설계 선택은 "표준 라이브러리를 언어 자신으로 쓴다"는 점이다. `Array`, `Map`, `Slice`, `Future`, `Generator` 가 모두 core.cy 의 일반 타입이고 호스트에 내려가는 것은 할당, 문자열
연산, 컴파일러 훅뿐이다. 이득은 (1) 타입 시스템의 시험대가 된다(템플릿, 빌림, 소멸자가 core.cy 에서 먼저 쓰인다), (2) 호스트 함수 규약이 사용자용과 내부용으로 갈라지지 않는다,
(3) 문서 주석이 곧 API 문서가 된다. 비용은 (1) 매 실행 3ms 의 고정 컴파일(5.7절), (2) 스택 트레이스에 `core:1729 Array.@index_addr` 같은 내부 프레임이 보이는 것, (3) core.cy 의 버그가
곧 모든 프로그램의 버그가 된다는 점이다. 이 fork 는 같은 구조를 유지하면서 `#[bind]` 호스트 함수의 소유 규약 위반 7곳을 고쳤다(`atof`, `atof32`, `str.index`, `str.insert`, `cy.VM.eval`,
`os.fetchUrl`, `os.cacheUrl`).

fork 유지보수 관점의 시사점. (a) 호스트 API 를 고칠 때는 `cyber.h`, `lib.zig`, `capi.zig`, 테스트 네 곳을 같이 본다. 번역 모듈 `cyber_c` 때문에 헤더와 구현의 시그니처 불일치가 빌드 오류가 되지
않는다(7.2절의 `cl_type_from_id`). C 로 컴파일되는 `examples/libcyber/*.c` 가 실제 ABI 의 유일한 검사자이므로 새 API 마다 예제나 `lib-standalone-test` 를 늘리는 것이 안전하다.
(b) 테스트는 목록 방식이라 추가 비용이 있지만 실패 기대 출력까지 한 파일에 있어 리뷰가 쉽다. 목록 밖 파일을 주기적으로 점검할 필요가 있다(5.6절). (c) 에이전트 루프 쪽에서 가장 먼저 손볼 곳은
첫 eval 컴파일 실패와 `cl_vm_validate` 의 VM 리셋 부작용이다. 둘 다 `Compiler.compile` 의 실패 시 상태 정리 문제로 보인다(5.3절 추정).

## 7. 알려진 이슈, 문서와 코드의 차이, 미완 지점

### 7.1 요약

| 구분 | 항목 | 심각도(에이전트 루프 기준) |
|---|---|---|
| 재현 버그 | 첫 eval 이 컴파일 실패하면 다음 eval 에서 SIGSEGV/abort (7.3 의 1). 2026-11-08 수정 | 높음(호스트 프로세스 사망) |
| 재현 버그 | `cl_vm_validate`/`cl_vm_compile` 가 VM 을 리셋하고 실패하면 VM 이 깨짐 (7.3 의 2) | 높음 |
| 재현 버그 | print/eprint 콜백의 첫 인자가 VM 포인터 (7.3 의 3) | 중간 |
| 한계 | 안전 모드 없음, 메모리 한도 없음, raw 포인터로 호스트 크래시 가능 (7.4) | 높음 |
| 문서 차이 | 헤더에 선언만 있고 구현이 없는 함수 3개, 시그니처가 다른 함수 1개 (7.2) | 중간 |

### 7.2 문서, 헤더, 코드의 차이

| 항목 | 문서/헤더가 말하는 것 | 코드/실행 결과 |
|---|---|---|
| 마지막 표현식의 값 | cyber.h:383-385 "마지막 문장이 표현식이면 `outVal` 에 값이 담긴다" | 표현식 문장은 컴파일 에러(`1 + 2` -> `Expected assignment to a variable or placeholder for int`). 값은 `fn main() -> T` 반환에서만 나온다 |
| 구현이 없는 선언 | cyber.h:569 `clResolveType`, 613 `cl_array_empty_new`, 615 `cl_map_empty_new` | lib.zig 에는 없고 대신 `cl_array_empty`(643), `cl_map_empty`(647)가 `export` 됨(헤더에는 없음). 링크하면 undefined symbol |
| 시그니처 불일치 | cyber.h:605 `cl_type_from_id(CLTypeId id)` | lib.zig:734 는 `(vm, type_id)` 두 인자. 헤더대로 부르면 id 가 vm 자리로 들어간다 |
| 없는 함수 이름 | cyber.h:411 `cl_new_compile_error_summary`, 416 · 474 `cl_free` | 실제 이름은 `cl_vm_compile_error_summary`, `cl_vm_freeb`. 헤더 420 의 `clAlloc` 은 lib.zig:89 에 있으나 헤더 선언은 `cl_vm_alloc` |
| 죽은 매크로 | cyber.h:233-238 `CL_CUSTOM_TYPE` 등 | `CLBindTypeEntry`, `CL_STR`, `CL_BIND_TYPE_CUSTOM` 가 정의돼 있지 않다. 쓰는 순간 컴파일 에러 |
| 선언 수 | docs/history/embedding_cli.md "101개" | `rg` 로 센 선언 113개 |
| print 콜백 | cyber.h:252 `CLPrintFn(CLThread* t, CLBytes)` | `t` 자리에 VM 포인터가 들어옴(실험, 7.3 의 3) |
| 테스트 발견 방식 | (브리프의 가정) "setup.zig 가 src/test 를 발견" | 발견 로직 없음. behavior_test.zig 의 수작업 목록이며 `cytest:` 해석은 `case2`(behavior_test.zig:606) |
| bindings.zig 의 역할 | (가정) 호스트 함수 등록 | 등록은 core.zig 의 `funcs`/`types` 표. bindings.zig 는 symbol 열거형 + 훅 + 죽은 `ModuleBuilder` |
| `cyber fmt` | `cyber help` 에 "Reformat the source code" | main.zig:121 `std.debug.panic("TODO: Embed src/tools/fmt.cy")`, 종료 코드 134 |
| 안전 모드 | docs/docs.md:32, 203, 2176, 2522 "Sandbox mode / safe mode" | 소스에 플래그 없음. `rg -i 'safe.?mode\|sandbox'` 는 src/ct_inline.zig:146 주석 한 줄만 찾는다 |
| 빌드 스텝 이름 | docs/build.md `zig build test-trace` | 실제 `trace-test`(build.zig:270) |
| 에러 요약의 색 | (문서 없음) | debug.zig:345-350 이 `ESC[31m ... ESC[0m` 를 무조건 넣는다. 같은 줄에 `TODO: Should not emit escape codes` 주석. 하네스는 이를 지우고 비교한다(setup.zig:185-187) |
| 호스트 타입 에러 문구 | sema_type.zig:43 `Custom type requires a @host attribute.` | 속성은 이미 `#[bind]` 로 바뀜. 문구만 남음 |
| 예제 주석 | bind_module.c:7 `inject_module.c` 참조 | 그런 파일은 없음 |
| lib.zig 주석 | lib.zig:1069-1071 "`spawn(f, {})` 는 두 번째 VM 부터 크래시" | 바로 아래 테스트(1119)가 고쳐졌음을 단언. 주석만 낡음 |
| capi.zig 낡은 참조 | `c.clGetType`, `c.CLSemaFn`, `c.clTypeId` (capi.zig:78-80, 182, 384-388) | 헤더에 없는 이름. Zig 가 참조되지 않는 선언을 분석하지 않아 빌드는 통과 |

### 7.3 재현 가능한 버그

1. 첫 eval 컴파일 실패. 재현: `CLVM* vm = cl_vm_init(); cl_vm_eval(vm, "x := \n"); cl_vm_eval(vm, "print('ok')");` -> 두 번째 호출에서 SIGSEGV. 의미 오류(`print(nope)`)면
   `@program_init has already been declared with the same function signature.` 컴파일 에러. 우회: 첫 eval 로 빈 소스를 돌리거나, 실패 뒤 `cl_vm_reset`. Debug 라이브러리에서도 같다(5.3절 표).
2. `cl_vm_validate`/`cl_vm_compile` 이 `resetVM` 을 부르므로 persist_main 변수를 지우고, 구문 오류가 나면 다음 eval 이 CompileError 를 내고 요약 조회가 SIGBUS 까지 간다. 우회: 에이전트 루프에서는 구문 검증용
   VM 을 따로 두거나 실패 뒤 `cl_vm_reset`.
3. print/eprint 콜백의 `t`. 재현: printer 안에서 `(void*)t == (void*)vm` 이 참, `== cl_vm_main_thread(vm)` 은 거짓. `cl_thread_vm(t)` 등으로 `t` 를 쓰는 콜백은 오작동한다. 제안: core.zig:1248-1262 에서 `@ptrCast(t.c.vm)` 대신
   `@ptrCast(t)` 를 넘긴다(`cl_vm_set_logger` 콜백은 `CLVM*` 이 맞다).
4. 호스트 함수 안에서 일시 중단된 스크립트를 끊을 수 없다(docs/decisions 문서에 기록. 이 장에서 재현하지 않음).
5. 컴파일러 내부의 `std.debug.panic` 경로가 호스트 프로세스를 abort 시킨다(decisions 문서에 기록). 5.3절의 `panic: Unsupported: .null` abort 가 그 사례다. 스크립트 실행 프로세스를 분리할 이유가 하나 더 된다.

### 7.4 임베딩의 한계와 미완 지점 (09 장 인용용 사실 목록)

격리와 권한.
- 샌드박스 플래그는 없다. 호스트가 loader 로 `use` 가능한 모듈을 걸러내는 것이 유일한 수단이다(5.2절). 허용 목록에서 `math` 를 열면 `c` 도 열어야 한다(math.cy 의 `use c`).
- 라이브러리 기본 모듈 중 `c` 는 포인터 도구를 가진다. 더 근본적으로 `use c` 없이도 정수를 `Ptr` 로 캐스팅해 역참조할 수 있다. 실험(CLI): `p := as[Ptr[int]] 8` 후 `print(p.*)` ->
  `Segmentation fault at address 0x8` 이고 CLI 의 시그널 핸들러가 abort(종료 코드 134). 시그널 핸들러는 CLI `main`(main.zig:31)과 테스트 러너에서만 설치되므로
  라이브러리 호스트에서는 프로세스가 그대로 SIGSEGV 로 죽는다고 읽을 수 있다(코드 판독. 라이브러리에서 직접 돌리지는 않았다). 호스트가 자체 핸들러를 설치할 때 쓰라고
  `cl_thread_signal_host_segfault`/`cl_thread_signal_host_panic` 이 있다.
- 저장소의 `meta.load(path)` 는 코드상 절대 경로를 막지 않는다(meta.zig:562-578, meta.cy 주석에 "TODO: This should restrict loading files above the project root"). 다만 시그니처가 `str` 인데
  const-eval 인자는 `EvalStr` 라 `meta.load('/etc/hosts')` 는 `Expected argument str, found EvalStr` 컴파일 에러가 되어 현재는 호출되지 않았다(실험). 시그니처가 고쳐지는 순간 열리는 구멍이다.
- CLI 는 의도적으로 열려 있다: 임의 경로 읽기(`use` 의 파일), `http(s)` URL import 와 `~/.cyber` 캐시, `#c.bind_lib('https://...')` 원격 라이브러리, `os` 의 프로세스 실행. 에이전트 실행 환경으로 CLI 를
  쓸 때는 OS 수준 격리가 필요하다.

자원 제한.
- 있음: `cl_vm_set_fuel`(검사점 = 루프 역방향 점프와 호출, vm.c:330-336), `cl_vm_interrupt`(다른 스레드에서 호출 가능). spawn 된 스레드도 fuel 을 물려받고 중단된다(lib.zig:1035-1117 테스트).
  시간 제한은 호스트의 타이머 스레드가 `cl_vm_interrupt` 를 부르는 방식이다.
- 없음: 메모리 한도. `cl_vm_initx(CLAllocator)` 가 있지만 `CLAllocator` 는 Zig 의 `std.mem.Allocator`(`ptr` + `vtable`)와 같은 배치이고(capi.zig:32-38) vtable 함수들은 Zig 호출 규약
  (`alloc(ctx, len, alignment, ret_addr)`, 슬라이스 값을 받는 `resize`/`remap`/`free`)이라 C 호스트가 현실적으로 채울 수 없다. 메모리 상한은 Zig 호스트이거나 프로세스 수준이다(코드 판독).
- 없음: 호스트 함수 안에서 오래 막힌 호출을 끊는 수단, 호스트 함수에서 스크립트를 멈췄다가 나중에 재개하는 수단. `CL_AWAIT` 는 반환되지만 재개 API 는 주석 처리돼 있다(lib.zig:289-365).

상태와 결과.
- 값을 받는 길은 `fn main() -> T` 의 반환 하나다. 문자열/정수/실수/불리언은 `cl_value_desc` 나 슬롯 읽기로 얻고, 구조체/슬라이스는 레이아웃을 호스트가 직접 해석해야 한다. 힙 값 결과의 소유권(누가 해제하는가)은
  문서화돼 있지 않아 이 장에서 확정하지 못했다(미확인).
- `persist_main` 은 panic/interrupt 시 모든 지역 변수를 버린다. 호스트 함수가 실패를 알릴 수단이 `cl_thread_ret_panic` 뿐이라(`Result` 를 만들어 돌려주는 C 도우미가 헤더에 없다. `cl_error(vm, name)` 이
  error 값은 만든다) 도구 실패가 곧 세션 상태 손실이다. 도구 실패를 스크립트가 처리하려면 반환 타입에 오류 정보를 담는 설계(예: 상태 코드가 든 구조체나 `str`)를 호스트가 따로 정해야 한다.
- 컴파일 에러는 첫 리포트 하나만(`reports.items[0]`, lib.zig:463-469) 문자열로 나온다. 구조화된 위치 정보는 panic 쪽만 `cl_thread_panic_trace`(`CLStackFrame {name, line, col, line_pos, chunk}`)로 있다.
  요약에는 ANSI 색 코드가 섞인다.

타입과 ABI.
- 호스트가 새 타입(불투명 핸들 객체)을 `#[bind] type` 으로 만드는 C 경로는 없다. `CLCreateTypeFn` 이 컴파일러 내부 `Type` 을 만들어야 하기 때문이다. 대안은 bind_module.c 처럼 값 구조체나 `Ptr[void]` 필드를 가진
  Cyber 타입에 메서드를 `#[bind]` 하는 것이다. docs/history/embedding_cli.md 도 "타입 바인딩 예제 TODO" 로 남겼다.
- 호스트 함수에는 타입 검사가 없다. 선언과 다른 접근자를 쓰면 조용히 슬롯이 어긋난다. 헤더와 구현의 시그니처 일치를 보장하는 장치가 없어 7.2절의 불일치가 생겼다.
- 성능: VM 하나의 시작에 약 3ms(core 컴파일). 바이트코드 직렬화가 없어 줄일 길이 막혀 있다(2.4, 5.7절). VM 재사용이 전제다.

## 8. 이해도 확인 Q&A

### Q1. 호스트가 스크립트의 결과 값을 받는 유일한 경로는 무엇이고, 왜 마지막 표현식이 아닌가?

A: `fn main() -> T` 의 반환 값이다. `VM.eval` 은 `main_func` 가 있을 때만 반환 타입 id 를 `res_t` 로 주고 값 포인터는 main 스레드 스택의 `%1` 슬롯이다(vm.zig:477-480, 609).
Cyber 0.4 는 표현식 문장 자체를 허용하지 않아(`Expected assignment to a variable or placeholder`) 마지막 표현식이라는 개념이 없고, 값이 정적 타입의 unboxed 슬롯이라 타입 id 없이는 해석할 수 없다.
cyber.h:383 의 주석은 0.3 시절 동작을 설명한 낡은 문구다(5.3절 실험).

### Q2. 호스트 함수는 왜 인자보다 `cl_thread_ret` 를 먼저 불러야 하는가?

A: `cl_thread_ret` 가 반환 영역 포인터(`fp - ceil(size/8)`)를 주면서 `fp_end = fp + 4` 로 인자 읽기 위치를 초기화하기 때문이다(thread.zig:547-552). `cl_thread_param` 계열은 `fp_end` 에서 읽고 전진하는데
CALL_HOST 는 `fp_end` 를 건드리지 않는다(vm.c:940-961). 반환값이 없는 함수도 `cl_thread_ret(t, 0)` 을 부르는 이유다. 어긴 실험은 하지 않았다(코드 판독).

### Q3. 값으로 받은 `str` 을 `cl_str_deinit` 하지 않으면 무슨 일이 생기고, 왜 `cl_thread_count_objects` 가 0 으로 나올 수 있는가?

A: 컴파일러는 object 가 아닌 인자를 복사해 피호출자 소유로 넘기므로(sema_func.zig:817-832) 호스트가 해제하지 않으면 힙 문자열이 샌다. 리터럴은 버퍼가 없어 드러나지 않고, 32바이트를 넘는 문자열은 힙 페이지 밖의
큰 객체로 할당된다(lib.zig:1259-1261 주석). 문서 기록상 `cl_thread_count_objects` 로는 이 누수가 잡히지 않았고, 그래서 회귀 테스트가 누수 검사 allocator(`cl_vm_initx(zt.alloc)`)를 쓴다.

### Q4. `persist_main`, `cl_vm_reset`, 새 VM 중 에이전트 턴 사이의 상태 유지에 무엇을 쓰고, 각각 어떤 대가를 치르는가?

A: `persist_main` 은 core 컴파일을 다시 하지 않으면서(턴당 수십 µs) 함수/타입/use 와 지역 변수를 이월하지만 panic/interrupt 가 나면 변수가 모두 사라진다. `cl_vm_reset` 은 모든 것을 버리고 다음 eval 이
core 를 다시 컴파일한다(약 3ms). 새 VM 도 마찬가지로 3ms 이상이다. 실패가 잦은 도구 호출이라면 중요한 상태를 호스트가 들고 매 턴 스크립트에 넘기거나, 오류를 panic 이 아닌 반환 값으로 전달하는 설계가 필요하다.
첫 eval 컴파일 실패 문제(7.3)도 있으므로 VM 은 빈 소스로 데운 뒤 쓴다.

### Q5. `core.cy` 를 Cyber 로 쓴 대가와 완화책은 무엇인가? 직렬화로 시작 비용을 없앨 수 있는가?

A: 대가는 매 VM 3ms 의 고정 컴파일과 스택 트레이스에 보이는 내부 프레임, core 버그의 전역 영향이다(5.7절, 6절). VM 재사용이 1차 완화책이다. 컴파일 결과를 저장해 재사용하려면 `call_host` 가 함수 주소를 48비트 즉시값으로
품고(bc_gen.zig:3110-3112) 직렬화 코드가 없어서(2.4절) 주소 재배치와 타입/심볼 테이블 직렬화를 새로 만들어야 한다. 구현 난이도는 이 장에서 평가하지 않았다(미확인).

### Q6. behavior-test 가 파일을 자동으로 발견하지 않는 설계의 득실과, 새 테스트가 실행되지 않는 실수를 막는 방법은?

A: 득은 플랫폼/백엔드별로 `if (!is_wasm)`, `if (test_config.ffi)` 같은 조건을 목록에서 줄 단위로 걸 수 있다는 점이다(behavior_test.zig:242-283). 실은 등록 누락이 조용히 생긴다는 점이다. 이 저장소에도 실행하면 통과하는
테스트 2개가 목록 밖에 있다(5.6절). 막는 방법은 (1) CI 에 "src/test 아래 .cy 중 `cytest:` 가 있으나 목록에 없는 파일" 검사를 넣거나 (2) 목록을 디렉터리 순회로 바꾸되 플랫폼 조건은 파일 안의 지시자(`--cytest-skip`)로 옮기는 것이다.
둘 다 이 장에서 구현하지 않았다.

### Q7. `-Dffi=false` 라이브러리에서 되는 것과 안 되는 것은?

A: 안 되는 것은 `#[extern]` 함수 호출(호출 시 panic)과 `os`/`libc`(CLI 전용 모듈이기도 하다). 되는 것은 core, meta, math(`#[bind, extern]` 에 호스트 구현이 있어 `math.cos` 도 동작), cy, c(포인터 도구), io, test, 그리고 호스트가
등록한 모듈이다. `c.bind_lib` 선언 자체는 컴파일되고 extern 이 호출될 때만 실패한다(5.8절). libffi 가 아니라 TinyCC 로 접착 코드를 만들기 때문에 FFI 를 끄면 TCC 가 링크되지 않아 라이브러리가 작아진다(2.1MB).

### Q8. 허용 목록 loader 로 `math` 를 열었는데 `Failed to load module: c` 가 났다. 왜이고 어떻게 해야 하는가?

A: math.cy 첫 줄이 `use c` 이기 때문이다. loader 는 모듈마다 불리므로 `math` 처리 뒤 `c` 가 요청된다(5.3절 실험에서 loader 가 `math`, `c` 순으로 불림). 해결책은 `c` 를 허용하거나, `math` 만 직접 제공하는
호스트 모듈로 대체하는 것이다. `c` 를 허용하면 포인터 도구가 따라 열리지만 raw 포인터 역참조는 이미 `c` 없이도 가능하므로(7.4절) 허용 목록만으로 메모리 안전을 보장할 수는 없다.

## 9. 더 알아보기

- 키워드: `CLThread` 스택 슬롯 ABI, `#[bind]` / `CL_BIND_FUNC_*`, `persist_main` / `@trackMainLocal`, `cont`, `fuel` / `CHECKPOINT`, `translate-c`, `--cytest`, TinyCC FFI.
- 관련 문서: docs/decisions/project_embedding_agent_loop.md(측정과 규약), project_vm_interrupt.md(fuel/interrupt 설계), project_fork_release_ci.md(릴리스), project_zig_017_upgrade.md(Zig 0.17 코드 규칙),
  docs/history/embedding_cli.md(0.3 -> 0.4 API 변천), docs/history/ownership_memory.md(호스트 매개변수 소유 규약).
- 관련 장: 호출 프레임과 `CALL_HOST`, 인터럽트 구현은 [Day 5](05-vm-runtime.md), `ownOrManageArg` 와 소멸자는 [Day 6 오전](06-memory-ownership.md), `Future`/`Generator`/`spawn` 은 [Day 6 오후](07-coroutines-concurrency.md).
  에이전트 루프 설계 제안은 이 장의 7.3, 7.4절을 근거로 [Day 7 오후](09-agent-loop-and-roadmap.md)에서 다룬다.
- 다음 단계 제안: 7.3 의 버그 두 개(첫 eval 실패, validate)와 printer 인자를 고치는 패치를 lib.zig 테스트와 함께 만들어 보는 것이 이 코드를 인수하는 가장 좋은 첫 작업이다.
