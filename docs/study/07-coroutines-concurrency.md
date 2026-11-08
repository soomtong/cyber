---
aliases: [코루틴, 동시성, 제너레이터, Day6-오후]
tags:
  - study
  - cyber
  - coroutine
  - generator
  - concurrency
---

# Day 6 오후. 코루틴과 동시성: stackful fiber 에서 stackless generator 와 Thread 로

> 대상 소스: `src/sema.zig`(709~757, 906~935, 2838~2930, 3060~3110, 9930), `src/bc_gen.zig`(703~735, 2173~2200, 2334~2347, 2773~2788), `src/vm.c`(319, 332, 913, 1397~1503), `src/thread.zig`(17~33, 68~95, 857~930, 970~1011, 1081~1130), `src/vm.zig`(974~1045), `src/worker.zig`, `src/sync.zig`, `src/builtins/core.cy`(4097~4180, 4317~4415), `src/builtins/core.zig`(1437~1520, 1597, 1999~2065), `src/vm.h`(496~504, 840~873)
> 옛 구현(0.3 태그): `git show 0.3:src/vm.c`(1570~1625), `0.3:src/fiber.zig`, `0.3:src/bc_gen.zig`(327~405), `0.3:src/vm.h`(477~510)
> 줄 번호는 HEAD b40531a1 기준이다. 0.3 쪽 줄 번호는 `0.3` 태그(2023-12-10) 기준이라고 표시한다.
> 예상 학습 시간: 4시간 (읽기 1.5 / 소스 탐독 1.5 / 실습 1)
> 선행: [05-vm-runtime.md](05-vm-runtime.md)(프레임과 호출 규약), [06-memory-ownership.md](06-memory-ownership.md)(ARC, 빌림)
> 다음: [09-agent-loop-and-roadmap.md](09-agent-loop-and-roadmap.md)

## 한줄 요약

0.3 은 "호출 스택째 멈추는" fiber 하나로 모든 협력 실행을 했고, 0.4 는 그것을 프레임 하나만 저장하는 stackless generator 와 자기 힙과 스택을 가진 Thread + Future 로 쪼갰다.
쪼갠 대가로 "호출 중간에서 yield" 와 "호스트 함수 안에서 멈췄다 재개" 가 사라졌고, 현재 generator 는 본문 지역 변수를 yield 너머로 보존하지 못한다(실행으로 재현, 원인은 코드로 확인).

## 오늘의 학습 목표

- [ ] 0.3 의 fiber 가 스택과 pc 를 어떻게 들고 다녔는지 `coinit` / `coresume` / `coyield` 구현으로 설명할 수 있다.
- [ ] `#[generator]` 가 sema 에서 시그니처를 바꾸고, IR(`ret_gen`, `yield`, `gen_next`, `gen_end`)과 명령어(`RET_GEN`, `RET_Y`, `GEN_NEXT`, `GEN_END`)로 내려가는 경로를 따라갈 수 있다.
- [ ] 제너레이터의 프레임이 `next()` 마다 소비자 스택으로 복사되는 방식을 그림으로 그리고, 지역 변수가 사라지는 이유를 덤프 한 장으로 증명할 수 있다.
- [ ] 이 문제가 단위 테스트, 벤치, 예제에서 왜 보이지 않는지, 어떤 패턴이 안전한지 말할 수 있다.
- [ ] `spawn` / `Future.await` / `Thread` 의 격리 모델과 현재 미완 지점(스케줄링, 전송 타입)을 안다. 비-main await 와 패닉 메시지 전달은 2026-11-08 에 고쳐졌다(아래 2.6).
- [ ] 0.3 fiber, 0.4 generator, 0.4 Thread 를 메모리, 전환 비용, 호출 깊이, 색, 빌림, 임베딩 축으로 비교하고 에이전트 루프에 무엇이 모자란지 정리할 수 있다.
- [ ] 이 fork 에서 고칠 수 있는 설계안 2~3개와 건드릴 파일을 말할 수 있다(제안일 뿐 구현은 이 문서의 범위가 아니다).

## 1. 왜 이것이 필요한가?

### 1.1 "멈췄다가 이어서" 가 풀어 주는 세 가지 문제

| 문제 | 예 | 필요한 것 |
| --- | --- | --- |
| 값을 조금씩 내놓기 | 큰 컬렉션 순회, 토큰 스트림 | 호출 사이에 지역 상태를 유지하는 함수 |
| 독립 실행 맥락 | 여러 작업을 번갈아 실행 | 자기 호출 스택을 가진 실행 단위 |
| 비동기 결과 기다리기 | I/O, 네트워크, LLM 응답, 도구 호출 | 기다리는 동안 다른 일을 하거나 호스트에 제어를 돌려주기 |

JS/TS 개발자에게 익숙한 대응(일반 지식)은 다음과 같다. `function*` 은 첫 번째, `async`/`await` 는 세 번째, Web Worker 는 두 번째와 닮았다.
Cyber 0.3 은 세 가지를 모두 fiber 하나로 처리했고, 0.4 는 첫 번째를 generator 로, 두 번째와 세 번째 일부를 Thread + Future 로 갈랐다.

### 1.2 이 fork 가 코루틴에 거는 기대

이 fork 의 최종 용도는 코딩 에이전트 루프(CodeAct 계열)의 실행 언어다. 모델이 스크립트를 쓰고 VM 이 실행한다.
그때 코루틴 계층에 필요한 능력은 네 가지다.

1. 시간 제한과 중단: 폭주하는 스크립트를 호스트가 끊는다. (구현됨: `cl_vm_interrupt`, `cl_vm_set_fuel`, `docs/decisions/project_vm_interrupt.md`)
2. 호스트 대기: 스크립트가 도구(LLM 호출, 파일, 승인)를 부르고, 호스트가 그 결과를 줄 때까지 스크립트를 멈춰 둔다.
3. 재개와 체크포인트: 멈춘 스크립트를 나중에 이어서 실행한다.
4. 격리: 한 스크립트의 오류가 호스트 프로세스를 죽이지 않는다.

이 장은 0.3 -> 0.4 변화가 이 네 가지에 무엇을 얻고 잃었는지 코드로 확인한다. 결론을 미리 말하면 1번은 얻었고, 2와 3은 잃었으며(upstream 이 비워 둔 자리), 4번은 코루틴 쪽에 호스트를 죽이는 경로가 여럿 남아 있다.

## 2. 근본적인 동작 원리

### 2.1 0.3 의 fiber: 스택과 pc 를 통째로 들고 있는 값

0.3 의 문서(`git show 0.3:docs/hugo/content/docs/toc/concurrency.md`)는 fiber 를 "자기 콜 스택과 프로그램 카운터를 가진 별도 실행 컨텍스트이고 first-class 값"이라고 쓴다.
사용법은 `coinit(fn, args...)` 로 만들고, `coresume f` 로 진행하고, `coyield` 로 멈추는 것이다.

```cy
-- 0.3 문법 (현재 파서는 받지 않는다)
func foo():
    print 'foo'
    bar()
func bar():
    coyield          -- 호출 스택 중간에서 yield
    print 'bar'
var fiber = coinit(foo)
coresume fiber
```

구현을 세 군데에서 읽으면 된다.

#### (1) 만들기: `coinit`

`0.3:src/bc_gen.zig:327~405` 의 `genCoinitCall` 은 `coinit` 명령어와, 그 바로 뒤에 fiber 본문 블록(함수 호출 + `coreturn`)을 내보내고, `coinit` 은 그 블록을 점프로 건너뛴다.
새 스택 크기는 컴파일 타임에 정해진다.

```zig
// 0.3:src/bc_gen.zig:376~380
// 1 + (min call ret) + 4 (prelude) + 1 (callee) + numArgs
var initialStackSize = 1 + 4 + 1 + numArgs;
if (initialStackSize < 16) {
    initialStackSize = 16;
}
```

런타임의 `allocFiber`(`0.3:src/fiber.zig:38~70`)는 이 크기만큼 `Value` 배열을 새로 할당하고, 인자를 새 스택의 인자 자리에 복사하고, `Fiber` 구조체를 힙에 만든다.
`Fiber` 는 `typeId = bt.Fiber | CYC_TYPE_MASK` 와 `rc = 1` 을 가진 ARC 객체다. 즉 fiber 는 값이면서 참조 카운트로 수명이 관리되는 힙 객체였다.
`0.3:src/fiber.zig` 의 크기 테스트는 64비트에서 `@sizeOf(vmc.Fiber) == 88` 이라고 적는다.

#### (2) 전환: `coresume` 과 `coyield`

```c
// 0.3:src/vm.c:1586~1608 (앞부분)
CASE(Coyield):
    if (vm->curFiber != &vm->mainFiber) {
        PcSpOff res = zPopFiber(vm, pcOffset(vm, pc), stack, VALUE_NONE);
        pc = vm->instPtr + res.pc;
        stack = vm->stackPtr + res.sp;
    } else {
        pc += 3;
    }
    NEXT();
CASE(Coresume): {
    Value fiber = stack[pc[1]];
    if (VALUE_IS_POINTER(fiber)) {
        HeapObject* obj = VALUE_AS_HEAPOBJECT(fiber);
        if (OBJ_TYPEID(obj) == TYPE_FIBER) {
            if ((Fiber*)obj != vm->curFiber) {
                if (obj->fiber.pcOffset != NULL_U32) {
                    PcSp res = zPushFiber(vm, pcOffset(vm, pc + 3), stack, (Fiber*)obj, pc[2]);
                    pc = res.pc;
                    stack = res.sp;
                    NEXT();
                    // ... (fiber 가 이미 끝났거나 자기 자신이면 release 후 다음 명령으로)
```

`zPushFiber` -> `fiber.zig:72` `pushFiber` 가 하는 일은 단순하다.

```zig
// 0.3:src/fiber.zig:72~85 (요약)
// 현재 fiber 저장
vm.curFiber.stackPtr = @ptrCast(vm.stack.ptr);
vm.curFiber.stackLen = @intCast(vm.stack.len);
vm.curFiber.pcOffset = @intCast(curFiberEndPc);
vm.curFiber.stackOffset = @intCast(getStackOffset(vm.stack.ptr, curFramePtr));
// 새 fiber 로 교체
fiber.prevFiber = vm.curFiber;
vm.curFiber = fiber;
vm.stack = @as([*]Value, @ptrCast(fiber.stackPtr))[0..fiber.stackLen];
```

`popFiber`(`0.3:src/fiber.zig:101`)는 반대 방향이고, 돌려줄 값(`coreturn` 의 반환값)을 부모 fiber 의 `parentDstLocal` 레지스터에 쓴다.
핵심은 이렇다. 전환은 {스택 포인터, 스택 길이, 재개 pc, fp 오프셋} 네 값을 저장하고 다른 네 값을 읽는 것이다. 프레임 크기와 무관하게 O(1) 이다.

```text
   0.3 fiber 전환 (coresume / coyield)

   VM 레지스터                 mainFiber                      fiberA
   ┌──────────────┐          ┌────────────────┐          ┌────────────────┐
   │ vm.stack ────┼─┐        │ stackPtr ──────┼─┐        │ stackPtr ──────┼─┐
   │ vm.curFiber  │ │        │ pcOffset       │ │        │ pcOffset       │ │
   └──────────────┘ │        │ stackOffset    │ │        │ stackOffset    │ │
                    │        └────────────────┘ │        └────────────────┘ │
                    ▼                           ▼                           ▼
              (현재 실행 중인 스택)        [main 스택 ........]      [fiberA 스택 ........]
                                                                       foo 프레임
                                                                       bar 프레임  <- stackOffset
                                                                       (coyield 가 멈춘 곳)
   coresume fiberA:  main 의 {stack, len, pc, fp} 를 mainFiber 에 저장
                     vm.stack = fiberA.stackPtr, 실행은 fiberA.pcOffset / stackOffset 에서 재개
   coyield:          fiberA 의 같은 네 값을 저장하고 prevFiber(main)로 복귀
```

#### (3) 왜 어떤 깊이에서도 yield 할 수 있었나

fiber 는 자기 스택을 통째로 소유한다. `bar()` 안에서 `coyield` 를 만나면 `foo` 프레임과 `bar` 프레임이 둘 다 fiber 의 스택에 남아 있고,
fiber 구조체는 "지금 fp 가 어디인가"(`stackOffset`) 하나만 기억하면 된다. 재개하면 호출 체인 전체가 그대로 살아 있다.
컴파일러는 어떤 함수가 yield 할 수 있는지 알 필요가 없다. 이것이 stackful 코루틴의 본질이고, "함수 색(function coloring)이 없다"는 말의 뜻이다.

0.3 의 `Coyield` 명령어는 피연산자 두 개(`startLocalReg`, `nextLocalReg`)를 가졌다(`0.3:src/bc_gen.zig:327~331`).
fiber 가 yield 중에 해제되면 `releaseFiberStack`(`0.3:src/fiber.zig:133`)이 이 범위와 debug sym 테이블로 각 프레임의 지역을 풀어 release 한다.
스택이 그대로 있으니 "멈춘 지점의 모든 프레임에 있는 지역을 해제"가 가능했다. 뒤에서 0.4 가 같은 문제를 어떻게 푸는지 비교한다.

#### (4) 스택 성장과 비용

fiber 마다 스택이 따로 있으므로 성장도 따로다. `growStackPrecise`(`0.3:src/fiber.zig:508~`)는 새 스택을 할당하고 복사한 뒤
프레임마다 저장된 이전 fp 포인터를 새 스택 기준으로 패치한다(스택이 움직이는 모든 스택형 설계의 공통 과제).

| 항목 | 0.3 fiber (코드 근거) |
| --- | --- |
| 객체 | `Fiber` 88바이트(64비트) + 힙 외부 객체 할당 |
| 스택 | 최소 16슬롯 = 128바이트, 별도 할당, 50% 단위로 성장 |
| 전환 | 왕복 한 번에 `zPushFiber` + `zPopFiber` (C 에서 Zig 로 호출 2회), 필드 약 8개 저장/복원, O(1) |
| 해제 | `releaseFiberStack` 이 debug sym 으로 멈춘 지점의 전 프레임을 해제 |

0.3 의 실제 전환 시간은 측정하지 못했다(0.3 은 Zig 0.11 세대라 이 환경에서 빌드하지 않았다). 위 표는 코드에서 읽은 구조이며 시간 수치가 아니다.

### 2.2 현재 저장소에 남은 fiber 는 죽은 잔재다

`docs/decisions/project_coroutines.md` 는 "`src/fiber.zig` 는 옛 VM 용 코드이며 어디서도 import 하지 않는다"고 적는다. 코드로 다시 확인했다.

```text
$ rg -n -i 'fiber' src/cyber.zig
80:pub const Fiber = vmc.Fiber;                 <- 별칭 한 줄뿐. @import("fiber.zig") 는 없다
$ rg -n '@import\("fiber' src build.zig
(결과 없음, exit=1)
$ rg -n 'Fiber' src/types.zig
(결과 없음, exit=1)                              <- bt.Fiber 같은 내장 타입 id 가 없다
```

- `src/cyber.zig` 의 `pub const xxx = @import(...)` 목록에 `fiber.zig` 가 없다. 그래서 `src/vm.zig:644` 의 `cy.fiber.getStackOffset(...)` 와 `src/vm.zig:833` 의 `bt.Fiber` 는 호출/해석되지 않는다.
  `src/types.zig` 에는 `Fiber` 선언이 없으므로 `bt.Fiber` 는 존재하지 않는 심볼이고, 644행이 쓰는 `self.c.stack` 도 지금의 `ThreadC`(`stack_ptr` / `stack_len`)에는 없는 필드다.
  Zig 는 쓰이지 않는 함수 본문을 분석하지 않아서 컴파일이 통과한다(lazy analysis).
- `src/vm.h:840~873` 에는 `Fiber` / `FiberObject` 구조체가 남아 있지만 `src/vm.c` 의 어떤 명령어도 쓰지 않는다. `src/fiber.zig:43~60` 은 이 구조체에 없는 필드(`typeId`, `rc`, `pcOffset`, `panicPayload`, `tryStack*`)를 참조하므로 import 해도 컴파일되지 않는다. 구조체만 정리되고 파일은 방치된 상태였다. `fiber.zig` 는 2026-11-04, `vm.h` 의 구조체는 2026-11-06 에 삭제했다(F-61).
- `docs/docs.md:2787` 의 "Fibers." 절(`Fiber(fn, args)`, `f.resume()`, `Fiber.yield()`)은 본문에 `*TODO*` 가 붙은 설계 문서이고 소스 어디에도 `type Fiber` 가 없다.
- `src/heap.zig:876~884` 의 `AsyncTaskType` 주석("Invoke callback on a new fiber", "Resumes a fiber")도 옛 모델의 흔적이다.

정리하면 현재 빌드에 fiber 는 없다. 코루틴은 `#[generator]` 하나뿐이다.

### 2.3 0.4 의 generator: 프레임 하나를 힙에 복제해 두는 stackless 코루틴

#### 2.3.1 컴파일 경로 한눈에

```text
 #[generator] fn count(n int) -> int:            (사용자 코드)
        │
        │ parser.zig:24      속성 "generator" -> ast.zig:161
        ▼
 sema.zig:2919~2927   시그니처의 반환 타입을 바꾼다
        │             int  ->  ^Generator[fn(int) -> int]     (func.info.generator = true)
        ▼
 sema.zig:3060~3110   semaFuncBody2: 매개변수 retain, 맨 앞에 ret_gen 한 개, 그 다음 본문
        │             본문의 `yield x` 는 set_ret + yield(IR) 로 내려간다 (sema.zig:709~757)
        ▼
 bc_gen.zig           ret_gen -> RET_GEN, yield -> RET_Y, gen_next -> GEN_NEXT, gen_end -> GEN_END
        ▼
 vm.c:1397~1493       RET_GEN / RET_Y / GEN_NEXT / GEN_END
```

#### 2.3.2 시그니처가 바뀐다

```zig
// src/sema.zig:2919~2927
if (has_generator) {
    func.info.generator = true;
    // Modify func signature return type.
    const decl_sig = try c.sema.ensureFuncSig(sig.params(), sig.ret);
    const funcptr_t = try getFuncPtrType(c, decl_sig);
    const gen_t = try getGeneratorType(c, funcptr_t);
    const ret_t = try getRefType(c, gen_t);
    sig = try c.sema.ensureFuncSig(sig.params(), ret_t);
}
```

사용자가 쓴 `-> int` 는 "next() 가 돌려줄 값의 타입"이 되고, 함수 자체의 반환 타입은 `^Generator[fn(int) -> int]` 가 된다(`getGeneratorType` 은 `sema.zig:9930`, `Generator` 템플릿을 확장한다).
`^` 는 이 값이 참조 카운트되는 힙 박스라는 뜻이다. 실제로 `print(gen)` 은 `^Generator[fn() -> int]` 를 찍는다(실습 1).
`docs/decisions/project_coroutines.md` 가 지적한 "표기가 호출 결과 타입을 바꾼다"는 문제가 바로 이 코드다.

`yield` 를 쓰는 곳에서 값 타입을 다시 꺼내는 방식(`sema.zig:709~716`)도 같은 형태다.

```zig
// src/sema.zig:709~716
.yield_stmt => {
    const yield = node.cast(.yield_stmt);
    const gen_t = c.proc().getReturnType(c.sema).cast(.pointer).child_t;
    const funcptr_t = gen_t.sym().instance.?.params[0].asPtr(*cy.Type);
    const val_t = funcptr_t.cast(.func_ptr).sig.ret;
    const opt_t = try getOptionType(c, val_t);
```

`yield` 가 있는 함수의 반환 타입이 `^Generator[...]` 라고 가정한 코드다. `#[generator]` 가 없는 함수에서 `yield` 를 쓰면 이 `.cast(.pointer)` 가 실패한다(실습 7 참고: 컴파일러가 죽는다).
`yield` 에 값이 없는 형태(`yield` 만)는 `return c.reportErrorFmt("TODO", ...)` 로 막혀 있다(`sema.zig:748`).

#### 2.3.3 ret_gen: 호출은 본문을 실행하지 않고 제너레이터만 돌려준다

`semaFuncBody2`(`sema.zig:3066~3110`)는 generator 함수의 IR 맨 앞에 `ret_gen` 문장 하나를 넣고 그 뒤에 본문을 붙인다.

```zig
// src/sema.zig:3104~3111
// Returns the generator.
_ = try c.ir.pushStmt(.ret_gen, @ptrCast(node), .{
    .gen_t = func.sig.ret,
    .next_t = opt_t,
    .deinit_head = block.first,
});
}
try semaStmts(c, node.stmts.slice());
```

그래서 `count(3)` 을 호출하면 함수의 첫 명령어가 `RET_GEN` 이고, 이것이 "프레임 스냅샷을 힙 객체로 만들어 `frame[0]` 에 넣고 호출자에게 돌아간다". 본문은 아직 한 줄도 실행되지 않았다.
`deinit_head` 는 "이 시점(본문 시작 전)에 살아 있는 매개변수를 해제하는 코드"를 담은 블록이고 `RET_GEN` 바로 뒤에 놓인다.

매개변수 처리 한 가지가 중요하다(`sema.zig:3072~3083`, `4709~4715`). 일반 함수는 `^T` 같은 참조 매개변수를 호출자가 관리하므로 callee 가 retain/release 하지 않는데,
generator 는 본문이 호출이 끝난 뒤에도 매개변수를 쓰므로 `semaOwn` 으로 복사(retain)해서 자기 소유로 만든다("Params are managed by generator functions").

`bc_gen.zig:2334~2347` 의 `gen_ret_gen` 이 이 IR 을 명령어로 바꾼다.

```zig
// src/bc_gen.zig:2334~2347
fn gen_ret_gen(c: *Chunk, stmt: *ir.ReturnGen, node: *ast.Node) !void {
    const pc = c.buf.ops.items.len;

    var reg_size = stmt.gen_t.reg_size();
    if (stmt.next_t.reg_size() > reg_size) {
        reg_size = stmt.next_t.reg_size();
    }
    const box_t = stmt.gen_t.cast(.pointer).child_t;
    try c.pushFCode(.ret_gen, &.{ @intCast(box_t.id()), @intCast(reg_size), c.cur_proc.reg_end, 0 }, node);
    try genStmts(c, stmt.deinit_head);
    c.buf.ops.items[pc + 4].val = @intCast(c.buf.ops.items.len - pc);
}
```

네 개의 피연산자는 (박스 타입 id, 반환 슬롯 수 `ret_size`, 프레임 끝 레지스터 `reg_end`, 재개 오프셋)이다.
`ret_size` 는 `^Generator`(1레지스터)와 `?T`(next() 의 결과)의 레지스터 수 중 큰 쪽이다. `?int` 는 태그 + 값이라 2레지스터다.
`pushFuncBlockCommon`(`bc_gen.zig:2773~2788`)도 같은 이유로 함수의 반환 슬롯을 `?T` 크기로 넓힌다.
이 문서 전체에서 중요한 것은 세 번째 피연산자 `c.cur_proc.reg_end` 다. 이것은 `ret_gen` 을 내보내는 "그 순간"의 값이다. 2.4 에서 다시 본다.

#### 2.3.4 yield: 값을 반환 슬롯에 쓰고 RET_Y

`yield i` 는 IR 에서 `set_ret`(반환 슬롯에 `?T` 를 쓴다) + `yield` 문장으로 내려가고(`sema.zig:717~757`), bc_gen 은 `RET_Y` 를 내보낸다(`bc_gen.zig:709~714`).

```zig
// src/bc_gen.zig:709~714
fn gen_yield_stmt(c: *Chunk, stmt: *ir.Yield, node: *ast.Node) !void {
    const pc = c.buf.ops.items.len;
    try c.pushCode(.ret_y, &.{@intCast(stmt.ret_opt_t.reg_size()), 0, @intFromBool(stmt.end)}, node);
    try genStmts(c, stmt.deinit_head);
    c.buf.ops.items[pc + 2].val = @intCast(c.buf.ops.items.len - pc);
}
```

`RET_Y` 바로 뒤에는 "이 지점에서 제너레이터를 버릴 때 실행할 해제 블록"(`deinit_head`)이 붙고, 마지막에 `ret_y end=true` 가 들어간다.
정상 재개는 그 블록을 건너뛴 곳(`resume_off`)에서 이어진다. 실제 덤프로 보면 구조가 분명하다(`count(n int, tag str)` 를 `cyber compile` 한 결과의 일부).

```text
0:148 .chk_stk: ret=2, frame=14
0:151 .ret_gen: ret gen(type=115, %6..%10, resume_off=14, ret_size=2)
0:156 .addr: %10 = *%7
0:159 .dtor_str: destruct [%10]              <- RET_GEN 직후 해제 블록: 매개변수 tag(str) 를 해제
0:161 .ret_y: yield ret=2, resume_off=4, done=true
0:165 .const_16s: %10 = 0                    <- 본문 시작 (`i := 0`). 첫 next() 는 여기서 시작한다
...
0:189 .ret_y: yield ret=2, resume_off=13, done=false   <- `yield i`
0:193 .addr: %12 = *%7
0:196 .dtor_str: destruct [%12]              <- 이 yield 에서 버려질 때의 해제 블록
0:198 .ret_y: yield ret=2, resume_off=4, done=true
0:202 .add_i16: %10 = %10 + 1                <- 정상 재개 지점 (resume_off=13 이 건너뛴 곳)
```

`ret_gen(... %6..%10 ...)` 에 주목하자. `%6` 은 `ret_size + 4`(반환 슬롯 2개 + 호출 정보 4개 다음)로, 첫 매개변수가 놓이는 곳이다. `%10` 은 스냅샷의 끝(`reg_end`)이다.
본문의 `i := 0` 은 `%10` 에 놓인다. 즉 `i` 는 스냅샷 범위 `[%6, %10)` 밖에 있다. 이것이 2.4 의 핵심 발견이다.

#### 2.3.5 Generator 객체와 core.cy

`Generator` 는 `src/builtins/core.cy:4317~4351` 에 Cyber 코드로 선언돼 있고, `src/vm.h:496~504` 의 C 구조체와 필드가 같다.

```cy
-- src/builtins/core.cy:4319~4329
type Generator[FnPtr Any]:
    frame_ptr Ptr[int]
    frame_len i32
    resume_pc Ptr[byte]
    deinit_pc Ptr[byte]

    -- Since generators can not be resumed while active,
    -- save the prev_fp here and store the generator handle in frame[3]
    prev_fp Ptr[int]
    running bool
    done    bool
```

| 필드 | 의미 |
| --- | --- |
| `frame_ptr`, `frame_len` | 힙에 복제해 둔 스냅샷(`Value` 배열)과 길이 |
| `resume_pc` | 다음 `next()` 가 이어서 실행할 명령어 |
| `deinit_pc` | 버려질 때 실행할 해제 블록 시작(없으면 NULL) |
| `prev_fp` | 지금 `next()` 를 부른 소비자의 fp (재개 중에만 유효) |
| `running`, `done` | 상태. `status()` 는 이 둘로 `paused` / `running` / `done` 을 계산한다(`core.zig:2058~2067`) |

크기는 48바이트다(`Generator.@size()` 는 `core.zig:2052`, 트레이스 빌드의 free 로그 `free type=115(Generator) ... 48` 로 확인).
`next()` 와 `end()` 는 Cyber 로 감싼 얇은 함수이고(`core.cy:4339~4351`), 실제 일은 `@gen_next` / `@gen_end` 라는 컴파일 타임 빌트인이 `gen_next` / `gen_end` IR 노드를 만들어 한다(`core.zig:1999~2024`).
`@deinit()` 은 `end()` 로 해제 블록을 돌린 뒤 `deinit()` 으로 스냅샷 버퍼를 free 한다(`core.cy:4331~4337`, `core.zig:2027`).

#### 2.3.6 한 번의 next() 에서 스택에 일어나는 일

`next()` 는 평범한 함수 호출이다(`fn Generator[].next` 는 인라인되지 않고 자기 프레임을 가진다). 그 안의 `GEN_NEXT` 가 제너레이터의 프레임을 `next` 프레임 바로 위에 "펼친다".

```c
// src/vm.c:1434~1459 (GEN_NEXT, 일부 줄을 압축해 옮김)
Generator* gen = (Generator*)stack[pc[3]];
if (gen->running)  { panicStaticMsg(t, "Generator is already running."); RETURN(RES_PANIC); }
if (gen->done)     { panicStaticMsg(t, "Generator is already done.");    RETURN(RES_PANIC); }

Value* base_ptr = stack + base;
base_ptr[0] = buildGenCallInfo(true, 4, 128);   // 호출 정보 (type=gen, call_inst_off=4, stack_size=128)
base_ptr[1] = (u64)(pc + 4);                     // 돌아올 pc
base_ptr[2] = (u64)gen;                          // 이전 fp 자리에 gen 핸들을 둔다
gen->prev_fp = stack;                            // 이전 fp 는 gen 에 보관
gen->running = true;

memcpy(base_ptr + CALL_ARG_START, gen->frame_ptr, gen->frame_len * sizeof(Value));
pc = gen->resume_pc;
stack = stack + ret;                              // 제너레이터의 fp
```

일반 호출(`CALL`, `vm.c:928`)은 호출 정보, 돌아올 pc, 이전 fp 를 `base` 의 세 슬롯에 쓴다. `GEN_NEXT` 는 이전 fp 슬롯에 대신 `gen` 핸들을 쓰고 이전 fp 는 `gen->prev_fp` 에 둔다.
같은 제너레이터가 동시에 두 곳에서 재개될 수 없으므로(`running` 검사) 이렇게 해도 된다. 스택 트레이스 코드가 이 프레임을 `FrameType.gen`(`thread.zig:1124`)으로 구분한다.

```text
   next() 호출 중의 소비자 스택 (낮은 주소 -> 높은 주소)

   ... 소비자 프레임 ...  │ Generator.next 프레임 (fp = N, frame=13)         │ 제너레이터 프레임 (fp = N+7)
                          │ N+0..1 ret(Option<int> 2슬롯)                     │ G+0..1 ret  <- RET_Y 가 값을 쓰는 곳
                          │ N+2  호출 정보                                    │ G+2   call_info (type=gen)
                          │ N+3  돌아올 pc                                    │ G+3   돌아올 pc
                          │ N+4  이전 fp                                      │ G+4   gen 핸들 (이전 fp 자리)
                          │ N+5  callee 슬롯                                  │ G+5   callee 슬롯
                          │ N+6  self (^Generator)                            │ G+6.. 스냅샷에서 복원된 매개변수
                          │ N+7.. 제너레이터 프레임이 여기서 시작 -------------> │ G+6+k.. 본문 지역/임시 (스냅샷 밖!)

   RET_Y:  gen->running = false; (재개 pc 기록) pc = stack[ret_size+1]; stack = gen->prev_fp;
```

`Generator.next` 의 덤프 한 줄(`gen_next: %7..%6 = next(%0)`)에서 `ret` 은 7이다. 즉 제너레이터의 fp 는 `next` 프레임 시작 + 7 이고, 제너레이터의 첫 매개변수/지역 슬롯 `G+6` 은 `N+13` 이다.
`N+13` 은 `next` 의 `chk_stk frame=13` 이 끝난 바로 다음 슬롯, 곧 `next` 를 부른 소비자가 이후에 호출을 하면 그 호출 프레임이 쓰는 영역의 첫 칸이다. 2.4.5 의 핵심이다.
(참고: 이 덤프 줄의 두 번째, 세 번째 숫자는 잘못 출력된다. `bytecode.zig:717~722` 가 피연산자를 `pc+1`, `pc+3`, `pc+5` 에서 읽는데 `Inst` 는 u16 단위라 실제 위치는 `pc[1]`, `pc[2]`, `pc[3]` 이다. `ret` 외에는 믿지 말 것. 7장에 기록한다.)

`RET_Y` 는 상태만 갱신하고 돌아간다.

```c
// src/vm.c:1415~1432 (RET_Y, 일부 줄을 압축해 옮김)
u16 ret_size = pc[1];
Generator* gen = (Generator*)stack[ret_size + 2];
gen->running = false;
if (pc[3] == 1) {
    gen->done = true;
} else {
    gen->resume_pc = pc + pc[2];
    if (pc[2] == 4) { gen->deinit_pc = NULL; } else { gen->deinit_pc = pc + 4; }
}
pc = (Inst*)stack[ret_size + 1];
stack = gen->prev_fp;
```

이 코드에는 스택의 프레임을 힙으로 되돌려 쓰는 줄이 없다. `memcpy` 는 `GEN_NEXT` 에만 있고(힙 -> 스택), `RET_Y` 에는 없다(스택 -> 힙).

### 2.4 [핵심 발견] generator 본문의 지역 변수는 yield 를 넘어 보존되지 않는다

> 2026-11-04 수정됨. 6.5 의 안 A(`ret_gen` 이 프레임 전체를 저장, `RET_Y` 가 힙에 되저장)에 재개 시 스택 검사를 더했다. 경위와 함께 고친 결함은 `docs/decisions/project_coroutines.md` 의 "제너레이터 프레임 보존 수정". 아래 분석은 수정 전 b40531a1 기준이다.

여기서부터가 이 장의 하이라이트다. 결론을 먼저 쓰고 증거를 쌓는다.

> 결론: `RET_GEN` 이 힙에 복제하는 범위는 "매개변수 레지스터"뿐이다. 본문에서 선언한 지역 변수와 루프 상태는 소비자의 스택 위에서만 살고,
> `RET_Y` 는 그것을 힙으로 되돌려 저장하지 않는다. 다음 `next()` 는 (같은 위치라면 운 좋게 남아 있는) 소비자 스택 슬롯을 그대로 읽는다.
> 소비자가 그 영역을 덮어쓰거나 다른 호출 지점에서 `next()` 하면 값이 바뀌거나 쓰레기를 읽는다. 관리 타입(str, ^T 등) 지역이면 segfault 가 난다.

이 동작은 `docs/docs.md` 의 Generators 절이나 `docs/history/coroutines_concurrency.md`("프레임 하나만 저장한다")가 말하는 의미와 다르다. 문서는 제한을 언급하지 않는다.

#### 2.4.1 재현: 최소 케이스 (모두 ReleaseSafe CLI 로 실행)

아래 코드를 `.cy` 파일로 저장해 `cyber 파일.cy` 로 실행하면 된다(각 예제는 임시 폴더에서 이 이름으로 실행했다). 소비자는 전부 `while g.next() |v|:` 형태다.

```cy
-- b1.cy: 직선 코드에서 지역 변수를 바꿔 가며 yield
#[generator]
fn b() -> int:
    i := 10
    yield i
    i += 1
    yield i
    i += 1
    yield i

gb := b()
while gb.next() |v|:
    print('B1 %{v}')
```

```text
$ cyber b1.cy
B1 10
B1 11
B1 11        <- 기대는 12
```

| 파일 | 시나리오 | 기대 | 실제 출력 |
| --- | --- | --- | --- |
| b1.cy | 직선 코드, `i += 1` 두 번, 소비자가 `print` | 10 11 12 | 10 11 11 |
| b2.cy | `i := 0; while i < 3: yield i; i += 1` | 0 1 2 | `B2 0` 한 줄 뒤 종료 |
| b3.cy | `for 0..3 \|i\|: yield i` | 0 1 2 | `B3 0` 뒤 `B3 11` 이 끝없이 반복(5초 래퍼로 절단) |
| d1.cy | b1 의 제너레이터, 소비자는 호출 없이 합산(`total += v`) | 합 33, 3회 | `total=33 n=3` (정상) |
| d2.cy | 같은 호출 지점, 루프 안에서 `deep(30)` 호출 | 합 33 | `total=882 n=3` (오염) |
| c1.cy | `a := g.next().?`, `b := ...`, `c := ...` 호출 지점 3곳 | 10 11 12 | `10`, 그리고 큰 쓰레기 두 개(실행마다 다름, 포인터처럼 보이는 값) |
| h1.cy | 상태를 `^Cursor` 힙 객체에 두고 매개변수로 전달 | 0 1 2 3 | 정상, 중간에 `deep(30)` 호출해도 정상 |
| f1.cy / f2.cy | `examples/fiber.cy` 의 제너레이터, 소비자에 `print('tick')` 추가 / 없음 | 7회 | f1: 3회로 조기 종료 / f2: 7회 정상 |

b3 와 c1 의 출력은 이렇다.

```text
$ perl -e 'alarm 5; exec @ARGV' cyber b3.cy | head -4
B3 0
B3 11
B3 11
B3 11
$ for i in 1 2 3; do cyber c1.cy; done
C1 10 5267588645201 5267588645209
C1 10 5761912537425 5761912537433
C1 10 2896930275665 2896930275673
```

d1 과 d2 는 같은 제너레이터에 같은 소비자 구조이고 루프 안에 호출 하나(`deep`, 지역을 쓰며 재귀)가 끼었을 뿐이다. 호출이 스택을 쓰는 것은 정상 동작이고, 문제는 제너레이터가 그 영역에 상태를 두는 쪽이다. 깊이별 결과는 실습 3 에 있다(`deep(1)` 만으로도 오염된다).

#### 2.4.2 원인 증거 1: 바이트코드 덤프의 `ret_gen` 범위

```text
$ cyber compile b1.cy        (함수 b 부분)
0:280 .chk_stk: ret=2, frame=9
0:283 .ret_gen: ret gen(type=115, %6..%6, resume_off=5, ret_size=2)   <- 스냅샷 범위가 비어 있다
0:288 .const_16s: %6 = 10                                             <- i 는 %6
0:291 .addr: %7 = *%0
0:294 .const_16s: %8 = 1
0:297 .store_64: [%7 + 0] = %8
0:301 .store_64: [%7 + 8] = %6
0:305 .ret_y: yield ret=2, resume_off=4, done=false
0:309 .add_i16: %6 = %6 + 1                                           <- 재개 후 %6 을 그대로 읽는다
```

`ret gen(... %6..%6 ...)` 은 `[ret_size+4, reg_end) = [6, 6)` 즉 빈 범위다. 지역 `i` 는 `%6` 이다. `chk_stk frame=9` 는 이 함수가 9개 레지스터를 쓴다는 뜻인데 스냅샷은 0개를 저장한다.
매개변수가 있는 `count(n int, tag str)` 는 `ret gen(... %6..%10 ...)` 로 `n`(%6)과 `tag`(%7..%9)를 저장하고, 본문 지역 `i`(%10)는 범위 밖이다(2.3.4 의 덤프).

#### 2.4.3 원인 증거 2: 레지스터 할당 순서

`ret_gen` 이 내보내는 `reg_end` 는 그 시점의 값이라고 했다(`bc_gen.zig:2345`). 지역 변수는 본문을 생성하면서 `reserve_reg`(`bc_gen.zig:2214`)가 `reg_end` 를 늘려 가며 할당한다.
트레이스 빌드(`-v`)의 `bc_gen` 로그가 순서를 그대로 보여 준다.

```text
$ ../../trace-out/bin/cyber -v b1.cy > b1.trace 2>&1 ; rg -n 'reg_end=6|reserve reg: 6|declare local 0' b1.trace
26926:bc_gen:     | ret_gen: `#[generator] fn b() -> int: ` reg_end=6
26930:bc_gen:     | end ret_gen reg_end=6                  <- RET_GEN 이 받는 reg_end = 6
26935:bc_gen:     | declare_local: `i` reg_end=6
26936:bc_gen: reserve reg: 6 Int                           <- i 가 이제서야 6번을 받는다
26937:bc_gen: declare local 0 -> %6, type: Int
```

(줄 번호는 이 실행의 로그 파일 기준이다. 여러 줄에 걸친 로그 항목은 가독성을 위해 한 줄로 줄였다.)

반대로 `chk_stk` 의 프레임 크기는 본문 생성이 끝난 뒤에 되돌아가 채워 넣는다(`bc_gen.zig:679~688`: `const stack_size = c.getMaxUsedRegisters(); c.buf.ops.items[chk_stk_pc + 2].val = stack_size;`).
`ret_gen` 의 `reg_end` 는 같은 기법으로 채우지 않았다. 이 차이가 버그의 정확한 위치다.

#### 2.4.4 원인 증거 3: 힙 -> 스택은 있고 스택 -> 힙은 없다

`vm.c:1454` 의 `GEN_NEXT`(와 `GEN_END`, 1487)는 `memcpy(base_ptr + CALL_ARG_START, gen->frame_ptr, gen->frame_len * sizeof(Value))` 로 스냅샷을 스택으로 복원한다.
`vm.c:1415~1432` 의 `RET_Y` 는 상태 플래그와 `resume_pc` 만 쓰고 프레임을 저장하지 않는다. `thread.zig:17~33` 의 `ret_generator` 는 `RET_GEN` 때 단 한 번 `frame[ret_size + 4..]`(`frame` 은 `fp[0..reg_end]`)를 `dupe` 한다.
따라서 스냅샷은 호출 시점의 매개변수 값으로 영원히 고정이다.

```zig
// src/thread.zig:17~33
pub fn ret_generator(heap: *cy.Heap, type_id: cy.TypeId, ret_size: u16, frame: []cy.Value, resume_pc: ?*cy.Inst, deinit_pc: ?*cy.Inst) !void {
    // Only persists the locals. Assumes generator is 1 reg return.
    const locals = frame[ret_size + 4..];
    const obj: *vmc.Generator = @ptrCast(try heap.new_object_undef(type_id, @sizeOf(vmc.Generator)));
    const locals_dup = try heap.alloc.dupe(cy.Value, locals);
    ...
```

주석의 "Only persists the locals"(여기서 locals 는 사실 매개변수 영역)와 "Assumes generator is 1 reg return" 은 이 설계의 가정을 드러낸다. 앞 문장은 "지역은 어디엔가 보존된다"는 기대였고, 뒤 문장은 2.5 (1) 의 ret_size 가정과 이어진다.

#### 2.4.5 왜 "처음엔 되는 것처럼" 보이나: 지역이 사는 곳은 소비자 스택이다

제너레이터의 프레임은 `next()` 호출마다 `next` 프레임 위(`fp + 7`)에 펼쳐진다(2.3.6). 따라서 제너레이터 지역 `%6` 의 절대 위치는 "그 `next()` 를 부른 지점의 base + 상수"다.
이 위치는 소비자 코드가 정한다.

- 같은 호출 지점에서 반복해서 `next()` 하고 사이에 아무것도 호출하지 않으면 같은 슬롯이 그대로 남아 있다. d1 이 33 을 낸다.
- 같은 호출 지점이지만 사이에 호출이 있으면 그 호출의 프레임이 같은 슬롯을 덮는다. d2 와 b1(세 번째 값)이 이 경우다. `print` 는 `to_print_string`, `int_fmt`, `interpolate`, `prints` 로 이어져 스택을 깊게 쓴다.
- 호출 지점이 다르면 base 가 달라 슬롯 자체가 옮겨진다. c1.cy 의 덤프:

```text
$ cyber compile c1.cy
0:83  .call: %3..%5 = Generator.next(%9..%10) 3     <- 첫 next(): base = %9
0:103 .call: %4..%6 = Generator.next(%10..%11) 3    <- 둘째: base = %10
0:123 .call: %5..%7 = Generator.next(%11..%12) 3    <- 셋째: base = %11
```

각 호출은 `a`, `b`, `c` 로 지역을 하나씩 늘리므로 base 가 한 칸씩 밀린다. `i := 10` 은 첫 호출의 영역에 쓰였고 둘째 호출은 한 칸 옆을 읽는다. 그래서 첫 값만 10 이고 나머지는 이전 호출이 남긴 값(포인터처럼 보이는 쓰레기)이다.

`examples/fiber.cy` 가 정상 동작하는 이유도 같다. 그 제너레이터의 `for 0..100 |i|` 상태는 `ret_gen` 범위 밖이지만, 소비자가 `while gen.status() != .done: _ = gen.next()` 로 같은 호출 지점에서 `status()`(작은 호스트 함수)만 부르는데 관측상 그 호출은 제너레이터 지역 슬롯을 건드리지 않았고,
제너레이터 본문 안의 `print(i)` 는 제너레이터 자신의 지역보다 위(더 깊은 쪽)에 프레임을 쌓기 때문이다. f2 가 그것을 확인하고(7회 정상), f1 이 소비자에 `print('tick')` 하나만 더해도 깨짐을 보인다(3회에서 종료).

#### 2.4.6 관리 타입 지역은 메모리 안전성 문제가 된다

정수 오염은 "조용한 오답"이지만 관리 타입(`str`, `^T`, `Array` 등)은 다르다. 각 `yield` 뒤에는 "버려질 때의 해제 블록"이 있고(2.3.4), 이 블록은 범위에 있는 관리 지역의 스택 슬롯을 읽어 destruct 한다.
슬롯이 쓰레기면 쓰레기 포인터를 해제하려 한다. (크래시 지점을 디버거로 확인하지는 않았다. 해제 블록의 destruct 가 유일한 후보이고 아래 대조군 결과와 일치한다.)

```cy
-- e5.cy: 힙 문자열 지역을 yield 전에 만들고, 제너레이터를 중간에 버린다
#[generator]
fn g(n int) -> int:
    s := 'item-%{n}-padding-padding-padding-padding'
    print(s)
    yield 1
    yield 2

fn use_it():
    x := g(5)
    _ = x.next()
    print('dropping')

use_it()
print('E5 ok')
```

```text
$ cyber e5.cy
item-5-padding-padding-padding-padding
dropping
Segmentation fault at address 0x8000000000000004
Cannot print stack trace: stack tracing is disabled
thread 55133717 panic: integer does not fit in destination type
```

e1.cy(첫 yield 뒤에 `print(s)` 가 있지만 `next()` 를 한 번만 하고 버리는 경우)와 e2.cy(`next()` 를 두 번 해서 `print(s)` 까지 가는 경우)도 각각 segfault 로 끝났다. e2 는 어느 줄에서 죽는지(읽기인지 종료 시 해제인지) 확인하지 않았다.
대조군은 정상이다. e3.cy(문자열을 마지막 yield 뒤에 만들어 yield 를 넘지 않음)와 e4.cy(yield 전에 만들고 끝까지 돌려 완료)는 정상 종료한다.
e4 는 완료 경로가 같은 슬롯을 읽어서 우연히 맞은 경우다. 이것은 "yield 를 넘는 관리 지역"이 안전하지 않다는 증거이지 안전하다는 증거가 아니다.

반대로 관리 타입 매개변수는 안전하다. 매개변수는 스냅샷에 들어 있고 `next()` / `end()` 마다 복원되기 때문이다(p2.cy: `str` 매개변수를 yield 너머로 읽고, 다른 인스턴스는 중간에 버려도 정상 종료).

#### 2.4.7 영향 범위

| 상황 | 결과 | 근거 |
| --- | --- | --- |
| 매개변수 읽기 | 안전 | 스냅샷이 `next()` 마다 복원됨 (p2.cy) |
| 매개변수가 가리키는 힙 객체의 필드 갱신 | 안전 | 상태가 힙에 있음 (h1.cy, generator.cy) |
| yield 를 넘는 정수 등 비관리 지역 | 값 오염 (조용한 오답) | b1, d2, c1 |
| 루프 카운터(`for`, `while`) | 조기 종료 또는 무한 루프 | b2, b3, f1 |
| yield 전에 만든 관리 지역 | 읽기와 해제에서 segfault 가능 | e1, e2, e5 |
| yield 뒤에 만든 지역(다음 yield 전에 소멸) | 안전 | e3 |
| 제너레이터 안에서 호출한 함수의 지역/임시 | 안전 | 호출 프레임은 제너레이터 지역보다 위에 쌓임 (examples/fiber.cy) |

#### 2.4.8 왜 테스트, 벤치, 예제가 못 잡았나

- `src/test/concurrency/generator.cy`: 모든 케이스가 상태를 `^ArrayStore[int]` 매개변수(힙)에 두거나 상태가 없다(`foo6` 의 `list << 123; yield list.len()`). 본문 지역 변수 + yield 조합이 하나도 없다. `genSum` 은 `yield sum(n)` 으로 지역 없이 호출만 한다.
- `src/test/bench/fiber/fiber.cy`: 상태는 전역 `count` 이고 `yield 0` 뿐이다.
- `src/lib.zig` 의 "single_run frees big heap objects at deinit." 테스트: `yield 0` 뿐.
- `examples/fiber.cy`: 지역(`for` 상태)이 있지만 소비자 루프가 같은 호출 지점에서 얕은 호출만 한다(f2).
- 모든 테스트가 `next()` 사이에 스택을 건드리지 않거나(건드려도 같은 슬롯에 값을 쓰지 않거나) 지역을 yield 너머로 쓰지 않는다. 버그는 "지역 + yield + 소비자 쪽 호출" 세 조건이 겹칠 때만 드러난다.

수정은 이 문서의 범위가 아니다. 설계안은 6.5 에 제안으로 적는다.

### 2.5 generator 와 스택 트레이스/언와인드: 호스트를 죽이는 경로 세 개

패닉이나 중단이 제너레이터 프레임을 지나갈 때의 동작을 확인했다. 세 가지가 서로 다른 원인으로 실패한다.

> 2026-11-04 수정됨. 세 결함 모두 고쳤다((2)는 프레임 보존 수정에서 `pushFCode`로). 이전 fp는 이제 `FrameInfo.prev_context()` 한 곳에서 읽는다. 경위는 `docs/decisions/project_coroutines.md`의 "제너레이터 프레임을 지나는 언와인드 · 스택 트레이스 수정". 아래는 수정 전 b40531a1 기준이다.

#### (1) `unwindStack` 의 `.gen` 분기가 반환 슬롯 1개를 가정한다

```zig
// src/thread.zig:1006~1009
if (frame_t == .gen) {
    const gen = tstack[fp+3].asPtr(*vmc.Generator);
    pc = tstack[fp + 2].retPcPtr - tstack[fp + 1].call_info.call_inst_off;
    fp = getStackOffset(tstack.ptr, @ptrCast(gen.prev_fp));
```

다른 프레임 타입은 `getFrame` 이 구한 `base`(= fp + 반환 슬롯 수)를 기준으로 호출 정보를 읽는다(`thread.zig:1081~1121`). `.gen` 분기만 `fp+1`, `fp+2`, `fp+3` 으로 하드코딩했다.
반환 슬롯이 1개일 때만 맞다. `-> int` 제너레이터의 `next()` 결과 `?int` 는 2슬롯이므로 호출 정보는 `fp+2`, gen 핸들은 `fp+4` 에 있다.

```text
$ cyber st4.cy        (-> int 제너레이터가 첫 next() 에서 panic)
thread 55153200 panic: incorrect alignment
Cannot print stack trace: stack tracing is disabled
exit=134
```

트레이스 빌드의 Zig 스택은 `value.zig:132 asPtr` <- `thread.zig:58 panic`(안에서 `unwindStack` 인라인) 를 가리킨다. 호스트 프로세스가 SIGABRT(종료 코드 134)로 죽는다. 같은 스크립트가 임베딩 환경이면 호스트가 죽는다.
반환 타입이 `^int` 같은 1슬롯 Option(zero_union) 이면 이 분기는 맞게 동작한다(트레이스 빌드의 st2 / st3 가 `walker` -> `Generator.next` -> `drive` -> `main` 순으로 정상 출력).

#### (2) `GEN_NEXT` 에 debug sym 이 없어서 릴리스 빌드에서는 트레이스를 못 만든다

`gen_next` 와 `gen_end` 는 `c.pushCode`(`bc_gen.zig:720`, `733`)로 내보낸다. `pushCode` 는 `pushOptionalDebugSym` 을 쓰고(`chunk.zig:681~685`), 이는 `cy.Trace` 이거나 `gen_all_debug_syms` 일 때만 심볼을 만든다.
그런데 `GEN_NEXT` 는 실패할 수 있다("Generator is already running." / "already done." 패닉, `vm.c:1439~1444`). 실패 가능 명령은 `pushFCode` 로 내보내야 항상 심볼이 붙는다(`await_op` 은 그렇게 한다, `bc_gen.zig:703~707`).
릴리스 CLI 에서는 트레이스를 만들려는 순간 `NoDebugSym` 이 나서 eval 결과가 `CL_ERROR_UNKNOWN`(4)이 되고 CLI 가 `unexpected 4` 만 찍는 것으로 보인다.

```text
$ cyber dn1.cy       (끝난 제너레이터에서 next() 를 한 번 더 호출)
1
none
GeneratorStatus.done
unexpected 4             <- 릴리스 CLI. 메시지도 트레이스도 없다. exit=1
$ trace-out/bin/cyber dn1.cy
...
panic: Generator is already done.
.../core.cy:4346:12 Generator.next:
    return @gen_next(self.*)
.../dn1.cy:10:7 main:
print(g.next())
```

`docs/decisions/project_vm_interrupt.md` 가 같은 종류의 문제를 `.jump` 에서 겪고 `pushFCode` 로 고친 이력이 있다. `GEN_NEXT` / `GEN_END` 는 아직 고치지 않은 같은 유형이다.
(증상은 실행으로 재현했다. 원인 설명은 코드 읽기와 위 선례에 근거한 것이고, 릴리스 빌드에서 `gen_all_debug_syms` 를 켜서 증상이 사라지는지는 확인하지 않았으므로 추정으로 분류한다.)

`-> ^int` 제너레이터 안의 panic(st2/st3)도 릴리스 CLI 에서는 `unexpected 4` 가 된다. 트레이스에 `gen_next` 의 pc 가 들어가기 때문에 같은 원인일 것으로 추정한다.

#### (3) `recordCurFrames` 에는 `.gen` 분기가 없다

`thread.zig:930` 의 `recordCurFrames`(내장 `meta.stack_trace()` 가 쓴다, `builtins/meta.zig:191`)는 `.vm` / `.host` / `.init` 만 다루고 `.gen` 프레임은 `.host` 쪽 분기로 떨어져 `prev_context()` 가 gen 핸들을 fp 로 해석한다.

```text
$ cyber stt1.cy       (제너레이터 본문이 부른 함수에서 meta.stack_trace() 호출)
thread 55172569 panic: integer overflow
Cannot print stack trace: stack tracing is disabled
exit=134
```

같은 호출을 제너레이터 밖에서 하면(stt2.cy) 텍스트를 돌려준다.

세 경로의 공통점은 "제너레이터 프레임이 이전 fp 슬롯에 gen 핸들을 넣는" 비표준 프레임이라는 점이다(2.3.6). 이 프레임을 이해하는 코드가 `unwindStack` 한 곳에만 있고, 그마저 ret_size 가정이 틀렸다.

### 2.6 Thread, spawn, Future, await: 격리된 실행 컨텍스트

generator 가 "값을 조금씩 내는 쪽"이라면 Thread 는 "독립 실행 컨텍스트" 쪽이다. 문서(`docs/docs.md:2740`)는 Thread 를 "자기 실행 컨텍스트와 힙을 가진 가벼운 가상 스레드"라고 설명한다.
코드를 따라가 보면 실제 구현은 이렇다.

```text
 spawn(f, {args})                                   (core.cy:4381~4402)
   │
   ├─ thread := @new_thread()                        core.zig:1597  Thread 구조체 + 자기 Heap + 스택 511슬롯(약 4KB, thread.zig:256)
   │                                                 interrupt 플래그와 fuel 한도는 main 것을 물려받는다
   ├─ 각 인자를 @send(thread, &arg) 로 복사           core.cy:2661  int 는 값 복사, struct 는 `@send` 메서드가 있어야 함
   │                                                 str 은 대상 스레드의 힙에 새 문자열을 만든다 (core.cy:3342)
   ├─ future.inner.shared_state = 새 u8 (0=pending)   core.zig:1477
   └─ @start_thread(...)                             core.zig:1488 -> worker_pool.add_thread_task (worker.zig:83)
                                                      │ 큐에 작업을 넣고, 필요하면 OS 스레드(16MB 스택)를 하나 만든다
                                                      ▼
 Worker.run (OS 스레드)                              worker.zig:122
   thread.callFunc2(...)  ->  entry 가 f(args) 를 호출, 결과를 @send(result_thread) 로 복사
   성공: future.data 에 쓰고 state 0 -> 1(writing) -> 2(completed)
   실패(panic): state 3,  중단(interrupt/fuel): state 4          -> 스레드를 해제하고 다음 작업으로

 f.await()  (main 스레드)                            core.cy:4105 -> @await_ -> AWAIT (vm.c:1494) -> zAwait (vm.zig:981)
   state 가 2 가 될 때까지 spin 루프 (3 이면 panic, 4 이면 interrupt)
```

핵심 사실을 코드 위치와 함께 정리한다.

#### 격리: 스레드마다 힙, 인자와 결과는 복사

`Thread` 는 `heap: cy.Heap` 을 자기가 가진다(`thread.zig:209~212`). 인자는 `@send` 로 대상 스레드의 힙에 복사되고(`core.cy:2661~2675`), 결과도 `@send(result_thread, *res)` 로 되돌아온다(`core.cy:4411~4412`).
따라서 참조 카운트를 스레드 간에 공유하지 않는다. 스레드 사이에서 공유되는 것은 `FutureValue` 와 그 `shared_state` 바이트뿐이다.

보낼 수 있는 타입은 코드가 문서보다 훨씬 좁다. `@send`(`core.cy:2661`)는 `int` 계열과 `@send` 메서드를 가진 struct 만 받고 나머지는 컴파일 에러다. 지금 `@send` 를 가진 것은 `str` 뿐이다(`core.cy:3342`).

```text
$ cyber t2.cy     (spawn(half, {3.0}), float 인자)
CompileError: Expected sendable: float
$ cyber t5.cy     (bool)    CompileError: Expected sendable: bool
$ cyber t6.cy     (byte)    CompileError: Expected sendable: byte
$ cyber t3.cy     (Array[int])    CompileError: Cannot copy `Array[int]`, type implements `NoCopy`.
```

`docs/docs.md:2765~2785` 의 `Sendable` 목록(`byte`, `bool`, `[]T`, `Array[T]`, `Map` ...)과 `Sendable` 라는 trait 은 소스에 없다(`rg Sendable src` 결과 없음).

#### await: 어느 스레드에서나 spin 으로 블록 (2026-11-08 이전에는 비-main 이 abort)

아래 코드는 2026-11-08 수정 전(F-07) 의 모양이다. 수정 후의 동작은 이 절 끝에 있다.

```zig
// src/vm.zig:981~1000 (요약)
fn zAwait(t: *cy.Thread, fut_value_bits: u64) callconv(.c) vmc.ResultCode {
    const future = fut_value_ptr.asPtr(*cy.heap.FutureValue);
    if (future.shared_state) |shared_state| {
        var state = @atomicLoad(u8, shared_state, .acquire);
        if (state == 2) return vmc.RES_SUCCESS;
        if (t == t.c.vm.main_thread) {
            while (true) {                       // main 스레드: 완료될 때까지 spin
                state = @atomicLoad(u8, shared_state, .acquire);
                if (state == 2) break;
                if (state == 3) { _ = t.ret_panic("Spawned thread did not finish."); return vmc.RES_PANIC; }
                if (state == 4) return vmc.RES_INTERRUPT;
                if (@atomicLoad(u8, t.c.interrupt, .acquire) != 0) return vmc.RES_INTERRUPT;
                std.atomic.spinLoopHint();
            }
            return vmc.RES_SUCCESS;
        } else {
            // ... (continuation 큐에 넣고 RES_AWAIT 를 돌려주려던 코드가 전부 주석 처리됨)
            @panic("TODO");
        }
```

세 갈래다.

1. 로컬 future(`shared_state == null`, `Future.complete(v)` 나 `FutureResolver`): 완료됐으면 즉시 성공, 아니면 `panic: Local future will never complete.`(`vm.zig:1029~1033`, 실습 5 의 fu2). 같은 스레드에서 아무도 완료시킬 수 없기 때문이다.
2. 공유 future 를 main 스레드가 await: 위 spin 루프. 이 루프는 스크립트 안의 역방향 점프나 CALL 이 아니라 호스트 코드 안이라 `CHECKPOINT()` 를 지나지 않는다. 그래서 `interrupt` 플래그를 루프 안에서 직접 읽는다(`project_vm_interrupt.md` 의 spawn 절).
3. 공유 future 를 비-main 스레드가 await: 수정 전에는 `@panic("TODO")`. 이것은 Zig 의 `@panic` 이라 해당 스크립트 오류가 아니라 호스트 프로세스 abort 였다. 실습 5 의 t7.cy(스레드 안에서 `spawn(...).await()`)가 `exit=134` 로 확인했다.

2026-11-08 수정(`56af553f`, F-07, `docs/decisions/project_spawn_nested_await.md`) 뒤의 `zAwait` 는 main 과 비-main 을 가르지 않는다. 어느 스레드든 상태가 2 가 될 때까지 같은 루프를 돌고, 3 이면 panic, 4 이면 interrupt 다. 한 가지가 더해졌다. 기다리는 스레드는 매 바퀴 worker 풀의 큐에서 작업을 하나 꺼내 자기 OS 스레드에서 실행한다(`Pool.run_queued_task`, `worker.zig`). 풀이 `CPU 수 - 1` 개로 고정이라 그냥 블록하면 풀 크기만큼의 스레드가 각자 자식을 기다리는 순간 자식이 큐에서 영영 안 꺼내져 교착하기 때문이다. main 도 같은 방식으로 돕는다. t7.cy 는 `41`, 깊이 30 · 200 의 await 체인은 `30` · `200` 을 찍는다.

스레드 panic 의 메시지도 같이 고쳐졌다(아래 표 10번). worker 가 스레드를 해제하기 전에 메시지를 공유 상태(`sync.zig` `FutureSyncState`, 이제 `state` 바이트와 메시지 포인터를 가진 구조체)에 복사해 두고 3 으로 바꾸면, 기다리던 쪽이 `Spawned thread panicked: boom` 으로 panic 한다. 중첩이면 `Spawned thread panicked: Spawned thread panicked: boom` 처럼 겹친다.

`AWAIT` 명령어는 `RES_AWAIT` 를 받으면 VM 루프를 빠져나가게 만들어져 있다(`vm.c:1499~1502`, `thread.zig:483~485` 의 `error.Await`, `lib.zig:240` 의 `CL_AWAIT`, `include/cyber.h:42`). 그러나 지금은 `RES_AWAIT` 를 돌려주는 곳이 없다(`vm.zig:1025` 주석 처리).
continuation 큐(`vm.task_nodes`, `FutureValue.cont_head`, `completeFuture`)도 마찬가지다. `completeFuture`(`core.zig:1437~1446`)는 대기 노드를 `.dead` 로 표시만 하고 ready 큐에 넣는 줄은 주석이다. `cl_run_ready_tasks`(`lib.zig:289~`, `include/cyber.h:404`)도 주석이다.
이 부분이 6.4 의 에이전트 루프 논의의 출발점이다.

#### 스케줄링: 풀 크기 `CPU 수 - 1`, 그리고 동시에 던지면 직렬화될 수 있다

`VM.init` 은 `worker.Pool.init(self, num_cpus - 1)` 로 최대 워커 수를 정한다(`vm.zig:134~141`; 이 머신은 `hw.ncpu = 10` 이라 9). 워커는 필요할 때 하나씩 만든다.

```zig
// src/worker.zig:69~80
pub fn request_idle_worker(self: *Pool) !void {
    if (self.active_workers < self.num_workers) return;
    if (self.num_workers == self.workers.len) return;
    self.workers[self.num_workers] = .{ ... std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024, ... }) ... };
    self.num_workers += 1;
}
```

`active_workers` 는 워커가 작업을 큐에서 꺼낸 뒤에 올라간다. 첫 `spawn` 직후 워커가 아직 작업을 집기 전에 둘째 `spawn` 이 오면 `active(0) < num(1)` 이라 "놀고 있는 워커가 있다"고 판단해 새 워커를 만들지 않는다. 그러면 두 작업이 한 워커에서 순서대로 실행된다.
측정은 이렇다(2천만 번 도는 CPU 작업 2개, 이 머신에서 3회). `work(n)` 은 `total += i % 7` 을 n 번 도는 함수이고 `burn` 은 main 이 사이에 하는 작은 일이다.

```cy
-- sp4.cy (발췌)
a1 := spawn(work, {20000000})
a2 := spawn(work, {20000000})      -- 연달아
...
b1 := spawn(work, {20000000})
_ = burn(3000000)                   -- main 이 사이에 일을 함
b2 := spawn(work, {20000000})
```

```text
$ cyber sp4.cy
back to back : 194.4 ms      <- 연달아 spawn 2개: 단독 1개(약 78 ms)의 2배 이상, 직렬 실행의 모양
with a gap   :  93.7 ms      <- 사이에 main 이 작업을 조금 하면 병렬
back to back : 158.8 ms
with a gap   :  88.7 ms
back to back : 158.2 ms
with a gap   : 110.2 ms
```

작업 개수를 늘린 sp3.cy 는 1개 78 ms, 2개 157 ms, 4개 약 160~200 ms, 8개 약 250~280 ms 였다. 완전 병렬이면 8개도 78 ms 근처여야 한다.
이 직렬화의 원인(`request_idle_worker` 의 판단 시점)은 코드 읽기로 세운 가설이고, 워커 로직을 바꿔서 확인하지는 않았다(추정).
(참고: 풀 크기가 `num_cpus - 1` 이므로 CPU 가 1개인 환경에서는 `workers.len == 0` 이라 `request_idle_worker` 가 워커를 만들지 않고 돌아온다. 작업이 큐에 쌓이기만 하고 main 은 spin 하게 되는지는 이 머신에서 재현할 수 없어 확인하지 못했다. `build_config.threads` 가 꺼진 빌드(예: wasm)에서는 `add_thread_task` 가 `@panic("unsupported")` 다, `worker.zig:84~86`.)

비용은 작다. 빈 함수를 `spawn(...).await()` 하는 데 평균 약 1.8~2.1 µs 가 들었다(2000회 평균, 3회 실행, 실습 5). 스레드 구조체, 힙, 4KB 스택을 만들고 워커 큐를 왕복하는 비용이다.

#### 패닉 전파와 중단

스레드가 패닉하면 워커가 스레드를 해제하고 future 상태를 3 으로 바꿔서, `await` 하는 main 이 "Spawned thread did not finish." 패닉을 낸다(`worker.zig:153~163`). 원래 메시지("boom in thread")는 어디에도 남지 않는다.

```text
$ cyber t4.cy
before
panic: Spawned thread did not finish.
.../core.cy:4106:5 Future.await:
    @await_(as[&FutureValue[T]] self.inner)
.../t4.cy:8:7 main:
print(r.await())
```

반대로 `cl_vm_interrupt` 와 fuel 한도는 모든 스레드가 main 의 플래그를 공유하므로 전파된다(`core.zig:1597~1608`, `project_vm_interrupt.md`). 이 장의 에이전트 루프 논의에서 쓰는 사실이다.

## 3. 핵심 개념 정리

| 용어 | 뜻 | TS/Node 에서의 대응 (일반 지식) |
| --- | --- | --- |
| 스택형 코루틴(stackful coroutine) | 자기 호출 스택을 가져서 호출 중간에서 멈출 수 있다. 0.3 fiber, Lua coroutine, Go goroutine | 대응 없음. 가장 가까운 것은 (비표준) fiber 라이브러리 |
| 스택리스 코루틴(stackless coroutine) | 프레임 하나(또는 상태 기계)만 저장한다. 해당 함수 본문에서만 멈출 수 있다 | `function*` / `async function` |
| `#[generator]` | 함수를 호출하면 본문을 실행하지 않고 `^Generator[Fn]` 을 돌려주게 하는 속성 | `function*` 의 `*` (표기 위치는 반대: 반환 타입이 바뀜) |
| `yield v` | 값을 `next()` 호출자에게 돌려주고 멈춘다. 호출자가 다시 `next()` 하면 다음 줄부터 이어 간다 | `yield v` (단 값을 되받는 `yield` 표현식은 없다) |
| `g.next()` | `?T` 를 돌려준다. 끝나면 `none` | `g.next()` 의 `{value, done}` 대신 Option |
| `g.status()` | `paused` / `running` / `done` | 대응 없음 |
| 스냅샷(snapshot) | `RET_GEN` 이 힙에 복제한 매개변수 레지스터 배열(`frame_ptr`/`frame_len`) | V8 의 generator 객체에 저장되는 레지스터 파일(일반 지식)과 같은 역할을 해야 하는 자리 |
| 소비자(consumer) | `next()` 를 부르는 쪽. 제너레이터의 프레임은 소비자 스택 위에 펼쳐진다 | `for...of` 루프 |
| 해제 블록(deinit block) | 각 yield 뒤에 붙는, 제너레이터가 중간에 버려질 때 실행할 destruct 코드 | `finally` 와 `return()` 에 해당 |
| Thread | 자기 힙과 스택을 가진 격리된 VM 스레드. OS 워커 풀에서 실행된다 | Web Worker / `worker_threads` |
| `spawn(f, {args})` | Thread 를 만들고 `Future[T]` 를 돌려준다. 인자는 복사된다 | `new Worker()` + `postMessage`(structured clone) |
| `Future[T]` | 비동기 결과 핸들. `await()` 로 결과를 얻는다 | `Promise<T>` (단 `then` 체인은 없다) |
| `FutureValue[T]` / `shared_state` | 결과를 담는 힙 값과 스레드 간 동기화 바이트(0 대기, 1 쓰는 중, 2 완료, 3 실패, 4 중단) | 대응 없음 (`SharedArrayBuffer` + `Atomics` 쪽에 가깝다) |
| `@send` / Sendable | 스레드 경계를 넘길 때 값을 상대 힙에 복사하는 훅 / 그것을 허용한 타입 | structured clone |
| colorless | `await` 를 일반 함수 어디서나 쓸 수 있음 (함수 색이 없음) | JS 의 `async`/`await` 는 색이 있다 (`await` 는 `async` 함수 안에서만) |
| continuation | 대기 중인 실행 상태. 스택형 fiber 에서는 스택 + pc, 0.4 는 옛 구현이 주석 처리됨 | Promise 의 `.then` 콜백 / 마이크로태스크 |
| 포인터 레이아웃(ptr layout) | 호출 지점마다 "이 레지스터는 스택을 가리킬 수 있다"를 기록한 표. 스택 재할당 때 패치한다 | 대응 없음 (Go 의 stack map 이 비슷, 일반 지식) |

세 가지 코루틴 모델의 차이를 한 장으로 줄이면 이렇다.

```text
                  어디서 멈출 수 있나        상태가 어디에 사는가              재개하려면
 0.3 fiber        호출 스택 어디서나        fiber 소유의 별도 스택            스택 포인터와 pc 교체 (O(1))
 0.4 generator    #[generator] 본문에서만   소비자 스택 위에 펼친 프레임      스냅샷 복사 + 재개 pc 로 점프
                  (현재: 매개변수만 스냅샷)  (지역은 힙에 저장되지 않음)
 0.4 Thread       (멈추지 않는다)           별도 VM 스레드(힙 + 스택)         OS 워커가 계속 실행, 결과는 Future 로
```

## 4. 소스 읽기 지도

이 순서로 읽으면 한 번의 `next()` 에서 컴파일러에서 VM 까지 이어진다. (각 항목 20~30분)

| 순서 | 파일과 위치 | 볼 것 |
| --- | --- | --- |
| 1 | `docs/docs.md:2940~2976` (Generators), `docs/decisions/project_coroutines.md` | 문서가 약속하는 것. "stackless", `yield`, `status()`, reset TBD |
| 2 | `src/builtins/core.cy:4317~4351` | `Generator` 필드와 `next` / `end` / `@deinit`. 필드가 곧 `vm.h:496~504` |
| 3 | `src/sema.zig:2838~2930`, `9930` | 속성 수집 -> `getGeneratorType` -> 반환 타입을 `^Generator[...]` 로 교체 |
| 4 | `src/sema.zig:3060~3111` (`semaFuncBody2`), `709~757` (yield), `906~935` (return), `9117~9145` (`procPrologue`) | 맨 앞의 `ret_gen`, yield 마다 `set_ret` + `yield`(해제 블록), 본문 끝의 `none` 반환 |
| 5 | `src/ir.zig:55, 174~175, 252~269` | `ret_gen` / `gen_next` / `gen_end` / `yield` 노드 정의 |
| 6 | `src/bc_gen.zig:2773~2788` -> `2334~2347` -> `709~735` | 반환 슬롯 넓히기 -> `ret_gen` 피연산자(`reg_end`!) -> `ret_y` / `gen_next` / `gen_end` |
| 7 | `src/bc_gen.zig:679~688` 와 `2214~2240` | 대조: `chk_stk` 프레임 크기는 본문 생성 뒤 채워지고, `reserve_reg` 가 지역을 순서대로 할당한다 |
| 8 | `src/vm.c:1397~1493` | `RET_GEN` / `RET_Y` / `GEN_NEXT` / `GEN_END`. `memcpy` 가 몇 개 있고 어느 방향인지 세어 보기 |
| 9 | `src/thread.zig:17~33`, `src/builtins/core.zig:1999~2065` | 스냅샷 생성(`ret_generator`), `gen_next` 빌트인(IR 생성), `status()` |
| 10 | `src/thread.zig:930~1011`, `1081~1130` | 스택 트레이스 코드의 `.gen` 처리 (2.5 의 세 문제) |
| 11 | `src/builtins/core.cy:4097~4180`, `4379~4415` | `Future`, `FutureValue`, `FutureResolver`, `spawn`, `@thread_entry` |
| 12 | `src/builtins/core.zig:1437~1520, 1597` | `completeFuture`, `start_thread`, `new_thread` |
| 13 | `src/vm.zig:974~1045` (`zAwait`), `src/worker.zig`, `src/sync.zig` | spin-wait, 워커 풀, 상태 바이트 |
| 14 | `src/thread.zig:68~95, 857~930` | 스택 성장과 `patch_frame_ptrs`. 포인터 레이아웃으로 스택 포인터를 패치하는 기계장치 |
| 15 | `git show 0.3:src/vm.c`(1570~1625), `0.3:src/fiber.zig`, `0.3:src/bc_gen.zig`(327~405) | 옛 stackful 구현. 2.1 과 비교 |
| 16 | `src/fiber.zig`, `src/vm.h:840~873` | 죽은 잔재. import 되지 않음을 `rg` 로 확인 |

찾기 도구 모음.

```text
rg -n 'ret_gen|ret_y|gen_next|gen_end' src --glob '*.zig' --glob '*.c'     # 제너레이터 전 경로
rg -n 'info.generator' src/sema.zig src/bc_gen.zig                         # generator 함수에서 갈라지는 곳
rg -n 'frame_t == .gen|FrameType' src/thread.zig                           # 트레이스에서 gen 프레임 처리
rg -n 'RES_AWAIT|error.Await|CL_AWAIT' src                                 # await 의 탈출 경로
git show 0.3:src/vm.c | rg -n 'Coinit|Coyield|Coresume|Coreturn'           # 0.3 fiber 명령어
```

## 5. 실습

아래 코드는 모두 작업 폴더에 `.cy` 파일로 만들어 `cyber 파일.cy`(`zig-out/bin/cyber`, ReleaseSafe)로 실행한 결과다.
무한 루프 가능성이 있는 것은 `perl -e 'alarm 5; exec @ARGV' cyber 파일.cy | head -15` 로 5초 타임아웃을 걸었다. 트레이스 빌드(`zig build -Dtrace=true`)가 필요한 항목은 따로 적는다.
출력에 나오는 큰 수(c1 의 쓰레기 값)나 시간은 실행마다 다르다. 그 밖의 출력(b1, b2, b3, d1, d2, f1, f2, e1~e5, p2, h1, st1, st3, st4, dn1, pm1)은 각각 3회 실행해 같았다.

### 실습 1. 제너레이터 기본과 바이트코드 보기

```cy
-- g0.cy
#[generator]
fn iterate() -> int:
    yield 123
    yield 456

gen := iterate()
print(gen)
print(gen.status())
while gen.next() |res|:
    print(res)
print(gen.status())
```

```text
$ cyber g0.cy
^Generator[fn() -> int]
GeneratorStatus.paused
123
456
GeneratorStatus.done
```

관찰 포인트: (1) `print(gen)` 이 `^Generator[fn() -> int]` 다(`docs/docs.md` 의 `Generator[fn()->int]` 와 표기가 다르다, 7.2). (2) `status()` 가 `done` 이 되는 것은 `none` 을 돌려준 뒤다.

```text
$ cyber compile g0.cy       (fn iterate 부분)
0:240 .chk_stk: ret=2, frame=9
0:243 .ret_gen: ret gen(type=115, %6..%6, resume_off=5, ret_size=2)
0:248 .addr: %6 = *%0
0:251 .const_16s: %7 = 1
0:254 .const_16s: %8 = 123
0:257 .store_64: [%6 + 0] = %7          <- ?int 의 태그(1 = some)
0:261 .store_64: [%6 + 8] = %8          <- ?int 의 값
0:265 .ret_y: yield ret=2, resume_off=4, done=false
```

`%0..%1` 이 `?int` 반환 슬롯이고 `yield 123` 은 거기에 `(1, 123)` 을 써 넣은 뒤 `ret_y` 한다. `%6 = *%0` 은 반환 슬롯의 주소를 잡는 `addr` 이다.

변형 과제: (a) `yield` 를 세 번으로 늘리고 `ret_y` 의 `resume_off` 가 어떻게 바뀌는지 본다(해제 블록이 없으므로 모두 4). (b) 매개변수 `tag str` 를 추가하고 `ret_gen` 범위와 `resume_off` 가 어떻게 달라지는지 본다(2.3.4 의 덤프).

### 실습 2. 상태를 힙에 두는 안전한 패턴

```cy
-- h1.cy
type Cursor:
    n int

#[generator]
fn count_to(cur ^Cursor, limit int) -> int:
    while cur.n < limit:
        yield cur.n
        cur.n += 1

fn deep(n int) -> int:
    if n == 0:
        return 0
    x := n * 1000
    return deep(n - 1) + x - x + n

cur := ^Cursor{n=0}
g := count_to(cur, 4)
total := 0
while g.next() |v|:
    _ = deep(30)
    print('v=%{v}')
    total += v
print('total=%{total} status=%{g.status()}')
```

```text
$ cyber h1.cy
v=0
v=1
v=2
v=3
total=6 status=GeneratorStatus.done
```

소비자가 `deep(30)` 과 `print` 로 스택을 마구 덮어도 정상이다. 상태(`cur.n`)가 힙 객체에 있고 제너레이터 본문에는 yield 를 넘는 지역이 없기 때문이다.
`cur` 은 매개변수라 스냅샷에서 복원된다(`^Cursor` 는 retain 되어 제너레이터가 소유한다).

규칙: yield 를 넘어 살아야 하는 모든 가변 상태는 힙 객체(매개변수로 받은 `^T`)에 두고, 본문 지역 변수는 다음 yield 전에 소멸하게 쓴다. `for` / `while` 의 카운터가 지역이므로 루프 조건도 힙 상태로 써야 한다(위 예의 `while cur.n < limit`).

### 실습 3. 소실 재현과 원인 확인

b1(10 11 11), b2, b3, d1, d2, c1, f1, f2 를 2.4.1 의 코드와 표대로 만들어 실행한다. 대표 출력만 다시 적는다.

```text
$ cyber b1.cy
B1 10
B1 11
B1 11
$ cyber d1.cy
D1 total=33 n=3
$ cyber d2.cy
D2 total=882 n=3
$ cyber f2.cy
iterations=7
$ cyber f1.cy | tr '\n' ' '
tick tick tick iterations=3
```

원인 확인 3단계를 직접 해 본다.

```text
$ cyber compile b1.cy | rg 'ret_gen|ret_y|const_16s: %6'
0:283 .ret_gen: ret gen(type=115, %6..%6, resume_off=5, ret_size=2)     <- 범위 [6,6)
0:288 .const_16s: %6 = 10                                               <- i 는 %6, 범위 밖
...
$ trace-out/bin/cyber -v b1.cy > b1.trace 2>&1
$ rg -n 'end ret_gen|reserve reg: 6|declare local 0' b1.trace          <- reg_end=6 시점에 ret_gen, 그 뒤에 i 가 6번을 받음
$ rg -n 'CASE\(RET_Y\)' -A18 src/vm.c | rg memcpy                      <- (결과 없음, exit=1) RET_Y 에는 memcpy 가 없다
$ rg -n 'memcpy.*frame_ptr' src/vm.c
1454:        memcpy(base_ptr + CALL_ARG_START, gen->frame_ptr, gen->frame_len * sizeof(Value));   <- GEN_NEXT
1487:        memcpy(base_ptr + CALL_ARG_START, gen->frame_ptr, gen->frame_len * sizeof(Value));   <- GEN_END
```

호출 깊이를 바꿔 본 결과(d2.cy 의 `deep(30)` 만 교체, 정상 합은 33).

```text
deep(0): D2 total=33 n=3        <- 이 경우만 정상 (이유는 확인하지 않았다)
deep(1): D2 total=12 n=3
deep(2): D2 total=14 n=3
deep(3): D2 total=18 n=3
deep(5): D2 total=32 n=3
deep(8): D2 total=68 n=3
deep(30): D2 total=882 n=3
```

호출 하나(`deep(1)`)만으로 오염이 시작된다. 제너레이터 지역이 `next` 프레임 바로 위(2.3.6 의 `N+13`)에 있어서 소비자의 호출 프레임이 같은 슬롯을 덮기 때문으로 해석한다.
매개변수를 본문에서 바꾸는 경우도 확인했다.

```cy
-- pm1.cy
#[generator]
fn g(n int) -> int:
    n += 1
    yield n
    yield n
x := g(5)
print(x.next().?)
print(x.next().?)
```

```text
$ cyber pm1.cy
6
5            <- 둘째 next() 에서 n 이 스냅샷의 원래 값 5 로 되돌아가 있다
```

변형 과제: (a) c1.cy 의 호출 지점 세 곳을 하나의 `while` 루프로 합쳐 정상이 되는지 본다. (b) 제너레이터 지역을 매개변수로 옮겨(`fn counter(i int)`) 값이 보존되는지 본다(pm1 이 보여 주듯 매개변수도 변경은 보존되지 않는다).

### 실습 4. 관리 타입 지역이 만드는 segfault

2.4.6 의 e5.cy(`s := '...'` 을 yield 전에 만들고 제너레이터를 중간에 버림)를 그대로 실행한다.

```text
$ cyber e5.cy
item-5-padding-padding-padding-padding
dropping
Segmentation fault at address 0x8000000000000004
Cannot print stack trace: stack tracing is disabled
thread 55133717 panic: integer does not fit in destination type
```

`E5 ok` 는 출력되지 않는다. 대조군 두 개.

```text
$ cyber e3.cy     (문자열을 마지막 yield 뒤에 만듦)                      -> "E3 ok", 정상 종료
$ cyber p2.cy     (str 을 매개변수로 받아 yield 너머로 읽음, 한 인스턴스는 중간에 버림)
dropping while paused
second-heap-string-4-padding-padding-padding
P2 ok
```

p2 가 정상이고 e5 가 죽는 차이(스냅샷에 있느냐)를 2.4.6 과 연결해 설명해 본다. segfault 뒤의 "integer does not fit in destination type" 은 Zig 시그널 핸들러가 이어서 낸 메시지로 보이며 1차 원인은 잘못된 해제다(이 부분은 확인하지 않았다).

### 실습 5. spawn, Future.await, 그리고 실패 모양

```cy
-- t1.cy
fn sum_to(n int) -> int:
    total := 0
    for 0..n |i|:
        total += i
    return total

fn shout(s str) -> str:
    return s + '!'

f1 := spawn(sum_to, {1000000})
f2 := spawn(sum_to, {10})
f3 := spawn(shout, {'hello from main'})
print('main continues while threads run')
print(f2.await())
print(f1.await())
print(f3.await())
```

```text
$ cyber t1.cy
main continues while threads run
45
499999500000
hello from main!
```

실패 모양 모음 (각각 한 줄짜리 파일).

```text
fu2.cy   r := FutureResolver.new(int); print(r.future().await())
         -> panic: Local future will never complete.   (core.cy:4106 Future.await, 호출 지점 트레이스 포함)
fu3.cy   r.complete(1); r.complete(2)
         -> panic: Future is already completed.        (core.cy:4171)
t2.cy    spawn(half, {3.0}).await()      -> CompileError: Expected sendable: float
t4.cy    spawn(boom, {1}).await()  (boom 은 panic('boom in thread'))
         -> panic: Spawned thread did not finish.      <- 'boom in thread' 메시지는 사라진다
            (2026-11-08 부터 panic: Spawned thread panicked: boom in thread)
t7.cy    fn mid(): return spawn(leaf, {}).await() + 1 ; print(spawn(mid, {}).await())
         -> thread 55141545 panic: TODO / exit=134      <- 호스트 프로세스 abort
            (2026-11-08 부터 정상 실행. 2.6)
fu1.cy   Future.complete(100).get()      -> CompileError: Can not find the symbol `get` in `Future[int]`.
fu4.cy   use aio                          -> CompileError: Import path does not exist: .../aio
```

마지막 두 줄은 문서가 보여 주는 `f.get()` / `use aio` 가 소스에 없다는 확인이다(7.2).

비용과 병렬성.

```text
$ cyber sp1.cy        (빈 함수 2000번 spawn + await)
n=2000 total=1999000 per spawn+await: 1.84 us      (3회: 1.84, 1.84, 1.77)
$ cyber sp4.cy        (CPU 작업 2개, 연달아 vs main 이 사이에 일을 함)
back to back : 158.8 ms
with a gap   :  88.7 ms
```

변형 과제: (a) 연달아 `spawn` 하는 개수를 1, 2, 4, 8 로 바꿔 전체 시간을 재고 완전 병렬 대비 몇 배인지 표를 만든다(이 머신의 결과는 2.6 에 있다). (b) 스레드에 넘기는 인자로 `Array[int]` 대신 `str` 만 써서 `@send` 가 왜 `str` 만 지원하는지(`core.cy:3342`) 읽는다. (c) 두 번째 `spawn` 앞에 `os.now()` 호출 정도의 작은 일만 넣어도 병렬이 되는지 본다.

### 실습 6. 제너레이터 100만 개와 next() 왕복 비용

```cy
-- m1.cy
use os

#[generator]
fn inc() -> int:
    yield 1
    yield 2

type IncFn = fn() -> int

n := 1000000
gens := Array[^Generator[IncFn]]{}
start := os.now()!
for 0..n |i|:
    g := inc()
    _ = g.next()
    gens.append(g)
mid := os.now()!
total := 0
for gens |g|:
    total += g.next().?
done := os.now()!
print('n=%{n} create+next: %{float(mid - start) / 1000000} ms, second next: %{float(done - mid) / 1000000} ms, total=%{total}')
```

```text
$ perl -e 'alarm 20; exec @ARGV' /usr/bin/time -l cyber m1.cy
n=1000000 create+next: 98.552 ms, second next: 30.9 ms, total=2000000     (3회: 92.7~100.3 ms / 30.9~35.6 ms)
        156663808  maximum resident set size
$ (같은 스크립트에서 n := 0)
        10387456  maximum resident set size
```

차이 146 MB / 100만 = 제너레이터당 약 146바이트다(`Generator` 48바이트 + 힙 헤더/정렬 + 배열 슬롯 8바이트를 포함한 RSS 차이이며 정밀 분해는 하지 않았다). 생성 + 첫 `next()` 에 100 ns 안팎, 두 번째 `next()` 에 약 31~36 ns 다.
`src/test/bench/fiber/fiber.cy`(10만 개)는 이 환경에서 12~13 ms 였다(`docs/decisions/project_coroutines.md` 는 28 ms 로 적었다, 머신이 다르다).

왕복 비용 하나만 보려면 제너레이터 상태를 힙에 두고 500만 번 `next()` 한다.

```cy
-- m2.cy (발췌)
#[generator]
fn count(n int) -> int:
    st := ^ArrayStore[int]{}
    st << 0
    while st[0] < n:
        yield st[0]
        st[0] = st[0] + 1
```

```text
$ cyber m2.cy
generator: 159.9 ms (12499997500000), plain loop: 15.1 ms (12499997500000)       (3회: 159.9, 159.9, 159.6 ms)
```

500만 번에 160 ms 이므로 한 번에 약 32 ns 다. 일반 `for` 루프 반복(약 3 ns)과 비교하면 `next()` 의 호출(`Generator.next` 프레임) + `GEN_NEXT` + `RET_Y` + Option 풀기 비용이 합쳐 약 30 ns 라는 뜻이다.
(주의: `st[0]` 같은 힙 접근이 포함된 값이라 순수 전환 비용의 상한이다. 0.3 의 `coresume` 비용은 측정하지 못해서 비교 수치는 없다.)

### 실습 7. 제너레이터 안의 panic 과 스택 트레이스

세 변종을 릴리스 CLI 와 트레이스 빌드(`trace-out/bin/cyber`, `zig build -Dtrace=true`)로 각각 실행한다.

```cy
-- st4.cy (-> int)                          -- st3.cy (-> ^int)
#[generator]                                #[generator]
fn walker() -> int:                         fn walker() -> ^int:
    panic('first next panics')                  panic('first next panics')
    yield 1                                     yield ^1
g := walker()                               g := walker()
_ = g.next()                                _ = g.next()
```

```text
$ cyber st4.cy                          (릴리스)
thread 55153200 panic: incorrect alignment
Cannot print stack trace: stack tracing is disabled        exit=134  <- 호스트 abort
$ trace-out/bin/cyber st4.cy            (트레이스 빌드도 같다: value.zig:132 asPtr <- thread.zig:58 panic)
$ cyber st3.cy                          (릴리스)
unexpected 4                                                 exit=1   <- CL_ERROR_UNKNOWN
$ trace-out/bin/cyber st3.cy            (트레이스 빌드만 정상)
panic: first next panics
.../st3.cy:3:5 walker:
    panic('first next panics')
.../core.cy:4346:12 Generator.next:
    return @gen_next(self.*)
.../st3.cy:7:5 main:
_ = g.next()
```

`-> int` 는 abort, `-> ^int` 는 릴리스에서 `unexpected 4`, 트레이스 빌드에서만 정상 트레이스. 2.5 의 (1)(2)와 연결해 보라. 끝난 제너레이터에 `next()` 를 한 번 더 부르는 dn1.cy 도 릴리스에서 `unexpected 4` 를 낸다.
`#[generator]` 없는 함수에서 `yield` 를 쓰면(y4.cy: `fn plain() -> int: yield 1 ...`) 컴파일러가 죽는다.

```text
$ cyber y4.cy
Segmentation fault at address 0x8
segfault without thread context
$ trace-out/bin/cyber y4.cy
thread ... panic: Expected .pointer, found .int.
.../src/types.zig:461:32: ... in cast__func_786
.../src/sema.zig:302:21: ... in semaStmts           <- yield_stmt 의 .cast(.pointer)
```

변형 과제: 반환 타입을 `str`, `float`, 구조체로 바꿔 어느 것이 abort 이고 어느 것이 `unexpected 4` 인지, `?T` 의 레지스터 수와 대응시켜 본다.

### 실습 8. 스택은 이미 움직인다: 성장과 빌림 패치, 그리고 제너레이터가 놓치는 빌림

```cy
-- s1.cy
fn rec(n int, p &int) -> int:
    if n == 0:
        p.* += 1
        return p.*
    return rec(n - 1, p)

x := 100
r := rec(20000, &x)
print('r=%{r} x=%{x}')
r = rec(200000, &x)
print('r=%{r} x=%{x}')
```

```text
$ cyber s1.cy
r=101 x=101
r=102 x=102
$ trace-out/bin/cyber -v s1.cy > s1.trace 2>&1 ; rg -c 'grow stack to size' s1.trace
9                                       <- 스택이 9번 재할당됐고 빌림 p 는 계속 x 를 가리킨다
```

스택이 재할당되어도 `&int` 빌림이 유효하다는 증거다(`growStackPrecise` 가 포인터 레이아웃으로 패치, `thread.zig:68~95, 868~915`).
이 장치가 있기 때문에 스택형 설계는 "스택이 움직여도 빌림이 산다"는 전제를 이미 일부 갖고 있다. 이제 제너레이터가 같은 전제를 어기는 경우를 본다.

```cy
-- br2.cy
#[generator]
fn watch(p &int) -> int:
    yield p.*
    yield p.*

type WatchFn = fn(&int) -> int

fn make() -> ^Generator[WatchFn]:
    local := 41
    return watch(&local)

g := make()
print(g.next().?)
print(g.next().?)
```

```text
$ cyber br2.cy
41
1
```

`make` 의 지역 `local` 은 함수가 끝나면 사라진다. 제너레이터는 그 주소(빌림 `&int`)를 스냅샷에 넣어 힙으로 가져왔다. 컴파일 에러가 없었다(2026-11-08 `a7418c29` 부터는 `A \`#[generator]\` function can not take the borrow type \`&int\` as a parameter.` 컴파일 오류다. `[&]T`, 빌림 필드를 가진 구조체, `&self` 수신자, `?&T` 도 같다. `docs/decisions/project_generator_borrow_params.md`).
첫 값 41 은 그 스택 슬롯에 우연히 남은 값이고 둘째 값 1 은 이미 덮인 값이다(use-after-return).
보통은 `^b`(빌림을 힙으로 올림)가 `semaLift` 에서 막힌다(`sema.zig:5834~5845`, `src/test/memory/lift_borrow_error.cy`: "Cannot lift the borrow type `&int`."). 제너레이터의 스냅샷은 이 검사를 거치지 않는다.
같은 코드를 `x := 7; g := watch(&x)` 처럼 호출자가 `x` 를 살려 두면 정상이다(br1.cy: 7, 8).

변형 과제: (a) `s1.cy` 의 재귀 깊이를 줄여 스택 재할당이 없는 경우와 결과를 비교한다. (b) `thread.zig:81` 의 `get_ptr_layout` 이 어떤 pc 에서만 레이아웃을 돌려주는지(`bc_gen.zig:3128` 의 호출 지점 기록) 읽고, `yield` 지점에는 레이아웃이 없음을 확인한다.

## 6. 0.3 -> 0.4 변경 관점 / 설계 철학 메모

### 6.1 무엇이 어떻게 바뀌었나

| 시점 | 변화 | 근거 |
| --- | --- | --- |
| 0.3 (2023-12) | fiber 하나. `coinit` / `coresume` / `coyield`, stackful, ARC 객체, 동적 타입 | 2.1, `0.3:test/fiber_test.cy` |
| 2024-05-23 `16cfe032` | `await` 키워드 + `Future` + `FutureResolver` + `queueTask`(단일 스레드 스케줄링) | `docs/history/coroutines_concurrency.md` |
| 2025-11-21 `b751ca6c` | `coinit` / `coresume` / `coyield` / `await` 키워드 삭제, `yield` 추가, Thread / `spawn` / `Sendable` 문서 추가 | 같은 문서, `docs/decisions/project_coroutines.md` |
| 2026-10~11 (이 fork) | 벤치/예제를 generator 로 포팅, `FutureValue` 누수 수정, spawn 스레드에 interrupt/fuel 전파 | `project_coroutines.md`, `project_vm_interrupt.md` |

upstream 은 "코루틴"을 둘로 갈랐다. 값을 조금씩 내는 쪽은 stackless generator 로, 독립 실행 맥락은 자기 힙을 가진 Thread 로 보냈다.
두 모델 사이의 자리, 즉 "같은 힙을 공유하는 stackful 코루틴"이 문서에만 있는 `Fiber` 이고 구현이 없다. 이 자리가 비어서 호스트 경계에서 멈췄다 재개하는 길도 같이 사라졌다.

### 6.2 장단점 분석표

| 축 | 0.3 stackful fiber | 0.4 stackless generator | 0.4 Thread + Future |
| --- | --- | --- | --- |
| 메모리 | `Fiber` 88바이트 + 별도 스택 최소 16슬롯(128바이트). 둘 다 따로 할당 (`0.3:src/fiber.zig`, `0.3:src/bc_gen.zig:377`) | 객체 48바이트 + 매개변수 스냅샷. 100만 개 RSS 증가 약 146바이트/개 (실측, 실습 6) | Thread 구조체 + 힙 + 스택 511슬롯(4KB) (`thread.zig:256`). 워커 OS 스레드는 최대 CPU 수 - 1 개, 스택 16MB (`worker.zig:76`) |
| 컨텍스트 전환 | 스택/pc 포인터 교환 O(1) (`zPushFiber` / `zPopFiber`). 수치는 미측정 | `next()` 한 번 약 30 ns (실측, 힙 접근 포함). 복사량은 O(스냅샷 크기) | spawn + await 한 번 약 1.8~2.1 µs (실측). 이후는 OS 스케줄 |
| 호출 깊이 중간에서 yield | 가능 (`0.3:test/fiber_test.cy` 의 "yield in nested function") | 불가. `#[generator]` 본문에서만. 위임(`yield*`)은 `generator.cy` 에 주석 처리된 TODO | 해당 없음 (멈춤이 아니라 병렬 실행) |
| 함수 색 | 없음 | 있음 (속성이 반환 타입을 바꾸고, 호출자는 `next()` 로 구동해야 함) | `await` 는 colorless. 어느 스레드에서나 블록 (비-main abort 는 2026-11-08 수정) |
| 소유권 / 빌림 | 스택이 fiber 에 고정되고 성장 때만 이동. 0.3 에는 빌림 개념이 없었다 | 프레임이 `next()` 마다 소비자 스택 위치로 옮겨 다니고 스냅샷은 힙에 있다. 스택 주소를 담은 값이 무효화되고, 빌림 매개변수가 `semaLift` 검사를 우회한다 (br2) | 격리. 인자/결과는 `@send` 로 복사. 빌림은 전송 불가 (문서) |
| 호스트 경계(임베딩, 에이전트) | 호스트 함수 안 yield 는 0.3 소스에서 확인하지 못함(미확인). VM 스택 전체가 보존되므로 호스트 경계 재개에 가장 가까운 모델 | 호스트 함수/중첩 호출 안에서 불가. 지역 소실 버그로 "요청 스트림" 패턴도 제한 | interrupt / fuel 은 전파됨. 호스트가 future 를 만들거나 완료시킬 C API 없음. 호스트 함수 안에서 대기 중이면 못 끊음 |
| 디버깅 / 스택 트레이스 | fiber 마다 일반 프레임 체인 | 트레이스 코드에 결함 3개 (2.5). 릴리스 빌드에서는 `unexpected 4` | 스레드 패닉의 원래 메시지가 사라지고 await 지점의 일반 패닉만 보임 |
| 구현 복잡도 | opcode 4개 + `fiber.zig` 543줄 + 해제 시 debug sym 으로 프레임별 지역 해제 | opcode 4개 + IR 노드 4개 + 호스트 함수 3개. 코드는 작지만 이전 fp 슬롯에 gen 핸들을 넣는 비표준 프레임이 트레이스/언와인드 코드에 퍼져야 함 | `worker.zig` 196줄 + `sync.zig` 82줄 + `core.cy` 일부. 풀 휴리스틱과 continuation 은 미완 |

장단점을 문장으로 줄이면 이렇다.

- generator 의 장점: 가볍다(객체 하나 + 인자 스냅샷). 스택을 따로 관리하지 않으니 스택 성장/패치 문제가 없고, 시그니처만으로 값 타입이 결정되어 정적 타입과 어울린다.
- generator 의 단점: 호출 중간 yield 불가(재귀 순회, 헬퍼 함수 안 yield 불가), 색이 생김, 값을 되받는 yield 가 없음(`next(arg)` 불가), 그리고 지금은 프레임 보존이 구현되지 않았다.
- Thread 의 장점: 격리가 강하다. 참조 카운트를 스레드 간에 공유하지 않으므로 데이터 레이스 걱정이 없고, 패닉이 스레드 단위로 끝난다.
- Thread 의 단점: 통신이 전부 복사이고 지원 타입이 `int`/`str` 뿐이다. 협력 스케줄링이 없다(await 는 어느 스레드에서나 바쁜 대기, continuation 미구현). 한 스크립트 안에서 "잠깐 멈췄다 이어서"를 값싸게 할 수단이 아니다.
- 사라진 것: 같은 힙을 공유하는 stackful 코루틴. 에이전트 루프가 가장 필요로 하는 모양이다.

### 6.3 다른 언어와의 비교 (일반 지식, 이 저장소의 사실이 아님)

| 언어 | 모델 | 중간 호출 yield | 함수 색 | 비고 |
| --- | --- | --- | --- | --- |
| JS `function*` / `async` | stackless | 불가(`yield*` 로 위임) | 있음 | V8 Ignition 은 `SuspendGenerator` / `ResumeGenerator` 로 레지스터 파일을 generator 객체에 저장/복원한다 |
| Python generator / `async def` | stackless | 불가(`yield from`) | `async` 는 있음 | 3.11 이후 프레임이 generator 객체 안에 들어 있고 지역/값 스택이 그대로 유지된다 |
| Lua coroutine | stackful | 가능 | 없음 | C 호출 경계를 넘는 yield 는 별도 API(`lua_yieldk`)가 필요하다 |
| Go goroutine | stackful(스택 복사로 성장) | 가능 | 없음 | 스택 복사 시 컴파일러가 만든 포인터 맵으로 포인터를 조정한다. 이 VM 의 포인터 레이아웃과 같은 발상 |
| Kotlin `suspend` | stackless(CPS 상태 기계) | 불가(suspend 함수끼리 연쇄) | 있음 | 컴파일러가 지역을 continuation 객체 필드로 옮긴다 |
| Rust `async` | stackless 상태 기계 | 불가(`.await` 연쇄) | 있음 | `await` 를 넘어 살아 있는 지역만 상태 구조체에 넣는다. 자기참조는 `Pin` 으로 해결 |

분류하면 Cyber 0.3 fiber 는 Lua/Go 쪽, 0.4 generator 는 Python/JS/Kotlin/Rust 쪽이다. 스택리스를 고른 언어는 모두 "yield 를 넘는 지역을 어디에 두는가"를 설계의 중심에 둔다.
Cyber 0.4 의 generator 는 그 부분을 비워 둔 채 나머지(시그니처, IR, opcode, ARC)만 구현된 상태다.

### 6.4 에이전트 루프 관점: 호스트 대기를 지원하려면

CodeAct 루프의 이상적인 모양은 이렇다. 스크립트가 `r := tool('read_file', ...)` 를 부르면 호스트가 LLM 이나 도구 호출을 시작하고, 그동안 스크립트는 멈춰 있다가 결과가 오면 `r` 에 값을 받고 이어진다.
필요한 능력은 (a) 호스트 함수 안(또는 그 호출 지점)에서 멈추기, (b) 멈춘 상태를 보존하기, (c) 호스트가 나중에 결과를 넣고 재개하기다.

#### 현재 상태 (모두 코드로 확인)

- `CALL_HOST`(`vm.c:940~`)는 동기 C 호출이다. 호스트 함수가 돌아와야 다음 명령으로 간다. 그동안 VM 은 블록된다.
- 호스트 함수 안에서 막히면 `cl_vm_interrupt` 로 못 끊는다(`project_vm_interrupt.md` "미정").
- `AWAIT` -> `RES_AWAIT` -> `error.Await` -> `CL_AWAIT` 의 반환 경로는 끝까지 이어져 있다(2.6). 그러나 `RES_AWAIT` 를 만드는 곳이 없다(`vm.zig:1025` 주석).
- 호스트가 Future 를 만들거나 완료시킬 C API 가 없다(`include/cyber.h` 에 future 관련 선언이 없다). `@new_shared_state` 는 스크립트 안에서만 쓰인다.
- generator 의 `yield` 는 `#[generator]` 본문 직접 문장으로만 쓸 수 있다. 호스트 함수 호출 지점도 그 본문 안에 있어야 한다.

#### 길 1. 동기 호스트 함수 + VM 당 OS 스레드 (지금 가능)

`#[bind]` 도구 함수가 호스트 안에서 블록하고 값을 돌려준다. 세션마다 OS 스레드를 하나 쓴다. `docs/decisions/project_tars_agent_runtime_review.md` 가 이 길을 먼저 권고했다.
취소는 `cl_vm_interrupt` 와 호스트 함수 자신의 취소 확인으로 한다. 코루틴이 필요 없다.

#### 길 2. VM 루프에서 빠져나가는 중단점 (제안, 미검증)

코드에서 확인한 사실 네 가지가 근거다.

1. `execBytecode` 는 `t->c.pc` / `t->c.fp` 에서 시작하고(`vm.c:608~609`), `RETURN(code)` 는 둘을 `t->c` 에 되돌려 놓는다(`vm.c:322~327`). 스크립트 상태가 C 스택에 없고 스레드 구조체와 스택 배열에 있다.
2. `exec_auto` 는 `RES_AWAIT` 를 `error.Await` 로 올리고(`thread.zig:483~485`), `cl_vm_eval*` 는 이를 `CL_AWAIT` 로 돌려준다(`lib.zig:240, 275`). 즉 "중단됐지만 실패 아님"을 나타내는 결과 코드가 이미 ABI 에 있다.
3. 메인 스택은 힙 할당이고 재할당되어도 포인터 레이아웃으로 패치된다(실습 8). 멈춘 동안 스택이 그대로 남는다.
4. VM 이 실행 도중 `RETURN` 해서 호스트 코드가 처리한 뒤 `execBytecode` 를 다시 불러 이어가는 구조가 이미 있다. 스택 오버플로(`RES_STACK_OVERFLOW`)가 그 예로, `exec_auto` 의 `while (true)` 루프가 스택을 키운 뒤 `continue` 한다(`thread.zig:471~499`).

필요한 변경(제안): `CALL_HOST` 가 호스트 함수의 "대기" 반환 코드를 받으면 `pc` 를 다음 명령으로 저장해 `RES_AWAIT` 로 `RETURN` 하고, 호스트는 결과를 반환 슬롯에 쓴 뒤 `execBytecode` 를 다시 부르는 재개 API(예: `cl_vm_resume`)를 추가한다.
세부 위험: `CALL_HOST` 는 호스트 프레임 표시로 `t->c.pc = NULL` 을 쓴다(`vm.c:944`)는 점, `VM.exec_bytecode` 의 `defer`(eval 횟수 증가)와 `prepEval` 이 재진입을 가정하지 않는 점, 호스트 함수가 다시 VM 을 부르는 중첩(호스트 -> 스크립트 -> 호스트)에서는 C 스택이 끼어 있어 멈출 수 없는 점이다.
이 길은 스택형 `Fiber` 보다 변경이 훨씬 작다. 단 "스크립트 하나가 통째로 멈추는" 모델이라 같은 힙에서 여러 실행 맥락이 번갈아 도는 용도는 해결하지 못한다.

#### 길 3. 스택형 `Fiber` 재도입

`project_coroutines.md` 가 첫 후보로 적은 길이다. 건드릴 곳과 위험(모두 제안/추정, 구현 안 함):

- `vm.c` / `vm.h`: 생성, resume, yield 의 opcode 또는 호스트 함수. `ThreadC` 의 `pc`, `fp`, `stack_ptr`, `stack_len`, `stack_end` 를 fiber 사이에 교체한다. 이 필드들은 `thread.zig` 의 `ThreadC` 와 `vm.h` 의 `Thread` 가 레이아웃을 맞춰야 하고 테스트가 `@offsetOf` 로 검사한다(`thread.zig:166~178`).
- `thread.zig`: `growStackPrecise` 는 현재 fiber 의 스택만 순회한다(`getFrame` 이 `fp == 0` 을 init 프레임으로 본다). fiber 마다 스택 시작이 init 프레임이어야 한다. `unwindStack` / `recordCurFrames` 에는 fiber 경계를 건너는 부모 체인이 필요하다.
- 소유권: fiber 스택에 있는 값을 다른 fiber 로 빌려주면 그 주소는 성장 때 패치 대상이 아니다. fiber 경계를 넘는 빌림을 sema 에서 막는 규칙(`Sendable` 과 비슷한 검사)이 필요하다.
- 호스트 프레임: yield 가 `.host` 프레임을 넘으면 C 스택이 끼므로 막아야 한다(Lua 의 "attempt to yield across a C-call boundary" 와 같은 문제, 일반 지식).
- 패닉: 문서(`docs.md:2797`)는 "fiber 가 패닉하면 같은 스레드의 모든 fiber 가 종료된다"고 쓴다. 현재 패닉 경로는 힙을 통째로 비우는 `freeHeapPages` 라(`thread.zig:65`, `108`) 이 규칙과 잘 맞는다. 0.3 처럼 프레임별 지역을 풀 필요가 없다.
- 포인터 레이아웃: 레이아웃은 호출 지점에만 기록된다(`bc_gen.zig:3128`). fiber 가 멈춘 pc 가 호출 지점이어야 성장 때 패치된다. 또 `is_stack_ptr` 는 레지스터 타입 자체만 보므로(`types.zig:304~314`) 구조체 안에 든 포인터는 누락될 수 있다(추정, 코드 읽기).
- 메모리: Thread 기본 스택은 4KB 다. 0.3 처럼 128바이트로 시작해 키우려면 성장 복사 비용이 든다.

#### 길 4. generator 를 "요청 스트림"으로 쓰기

스크립트 본문을 `#[generator]` 로 만들고 도구 호출을 `yield` 로 호스트에 넘기는 패턴이다. 호스트는 `next()` 로 요청을 받아 처리하고 응답을 힙 객체(우편함)에 쓴 뒤 다시 `next()` 한다.
제약이 둘 있다. (1) stackless 라 모델이 정의한 헬퍼 함수 안에서 도구를 부르면 yield 할 수 없다(색이 퍼진다). (2) 2.4 의 버그 때문에 yield 를 넘는 지역은 쓸 수 없고, 상태는 전부 힙 객체에 둬야 한다. 지금 형태로는 에이전트 스크립트에 권할 수 없다.

#### 길 5. Future 만으로

`Future` 에는 완료시키는 쪽이 `spawn` 의 워커와 같은 스레드의 `FutureResolver` 뿐이다. 호스트가 완료시키는 길이 없고, main 의 `await` 는 spin 이라 호스트 스레드를 블록한다. 길 1 과 사실상 같다.

### 6.5 [제안] generator 의 지역 보존 수정안

이 절은 설계안이다. 구현하거나 검증하지 않았다. 근거가 되는 코드 사실만 확인했다.

#### 다른 언어가 하는 일 (일반 지식)

- V8 Ignition: yield 지점에서 `SuspendGenerator` 가 레지스터 파일(범위)을 generator 객체에 저장하고 `ResumeGenerator` 가 복원한다.
- Python: 프레임(지역 + 값 스택 + 명령 포인터)이 generator 객체에 상주한다.
- Rust async: 컴파일러가 `await` 를 넘어 살아 있는 지역을 계산해 상태 구조체의 필드로 배치한다. 나머지는 레지스터/스택에 둔다.

스택리스 코루틴이 해야 하는 일은 한 문장이다. "재개 후에도 읽을 값을 suspend 시점에 소비자 스택 밖에 둔다."

#### 코드에서 이미 확인한 재료

- 저장 범위의 끝을 늦게 채우는 선례: `chk_stk` 의 프레임 크기(`bc_gen.zig:679~688`, `getMaxUsedRegisters`).
- yield 지점에서 살아 있는 지역의 끝: `ret_y` 를 내보내는 순간의 `c.cur_proc.reg_end` 는 statement 경계라 임시 레지스터가 없고, 그 값이 곧 "범위 안 지역의 끝"이다. 예: b1 의 트레이스에서 `yield i` 문장의 `reg_end=7`(i 가 `%6`).
- 스냅샷 복사 기계장치: `GEN_NEXT` 의 `memcpy` 와 `ret_generator` 의 `dupe`.
- 각 yield 가 이미 가진 정보: 해제 블록이 "범위 안 관리 지역"을 알고 있다(`sema.zig:717~757` 에서 호출하는 `semaDestructBlock2`, 정의는 `sema.zig:4794`).
- 스택 주소를 담은 값을 재배치할 때 패치하는 기계장치: `patch_frame_ptrs` / `get_ptr_layout`(`thread.zig:68~95`).
- 이전 fp 슬롯에 항상 gen 핸들이 있다: `stack[ret_size + 2]` 는 재개마다 유효하다(`vm.c:1448~1450`).

#### 안 A. RET_Y 에서 되돌려 저장 (권장 후보)

- 변경: (1) `gen_ret_gen` 의 `reg_end` 를 본문 생성 뒤 `getMaxUsedRegisters()` 로 채워 스냅샷 버퍼를 최대 프레임 크기로 잡는다. (2) `gen_yield_stmt` 가 `ret_y` 에 `reg_end` 피연산자를 추가한다. (3) `RET_Y` 가 `memcpy(gen->frame_ptr, stack + ret_size + 4, (reg_end - ret_size - 4) * sizeof(Value))` 를 하고 `frame_len` 을 갱신한다. (4) `GEN_NEXT` / `GEN_END` 는 그 길이만큼 복원한다.
- 건드릴 파일: `src/bc_gen.zig`(2334 부근, 709 부근, proc 정보에 ret_gen pc 보관), `src/vm.c`(1397~1493), `src/vm.h`(opcode 길이 정의), `src/bytecode.zig`(덤프와 `getInstLenAt`), `src/thread.zig`(`ret_generator` 의 버퍼 크기), `src/test/concurrency/generator.cy`(지역/루프/관리 지역 케이스).
- 장점: 변경이 작다. 관리 지역도 같이 해결될 것으로 본다(비트 단위 이동이라 RC 변화가 없고, 스택 쪽 사본은 죽은 값이 되며, 해제 블록은 `GEN_END` 가 복원한 힙 사본을 읽는다. 구현해서 확인한 것은 아니다). 전환 비용은 프레임 크기에 비례한다.
- 위험: (a) 스택 주소를 담은 지역(빌림, `Ptr`)은 소비자마다 프레임이 옮겨 다녀서 복사만으로는 틀린다. yield 지점에도 포인터 레이아웃을 기록하고 `GEN_NEXT` 에서 이동량만큼 패치하거나, yield 를 넘는 빌림을 sema 에서 컴파일 에러로 막아야 한다. (b) 스냅샷이 커지면 모든 `next()` 가 그만큼 복사한다. 이 장의 예제에서 `chk_stk` 의 프레임 크기는 9~14 슬롯이었다. (c) 해제 블록이 어느 yield 에서 실행되든 같은 길이 규칙을 따라야 한다.
- 별개로 필요: `br2` 같은 빌림 매개변수 탈출은 안 A 와 무관하게 `semaLift` 류 검사가 필요하다(제너레이터 호출 시 `borrow_only` 매개변수 거부).

#### 안 B. 지역을 힙 프레임에 두고 gen 포인터로 접근

- 변경: yield 를 넘어 살 수 있는 지역(보수적으로는 generator 함수의 모든 비매개변수 지역)을 레지스터가 아니라 Generator 가 소유한 힙 레코드의 필드로 할당하고 `[gen + offset]` 로 읽고 쓴다. gen 핸들이 매 재개마다 `stack[ret_size+2]` 에 있으므로 접근 경로가 이미 있다.
- 건드릴 파일: `src/sema.zig`(`semaFuncBody2`, 지역 선언 경로), `src/ir.zig`(필드 접근 재사용 또는 새 노드), `src/bc_gen.zig`(`reserve_local`, `bc_local_map`, `gen_local`/`set_local`), `src/thread.zig`(`ret_generator` 의 레코드 할당 크기), `src/vm.c`(복사 제거).
- 장점: 힙 레코드는 움직이지 않으므로 지역을 가리키는 빌림이 yield 를 넘어서도 유효하다. 전환 때 복사가 없다(매개변수만 남는다). 개념적으로 Rust/Kotlin 의 "상태 구조체"에 가장 가깝다.
- 단점: 지역 접근이 전부 메모리 연산이 된다. sema/IR/bc_gen 을 모두 건드리는 가장 큰 변경이다. 해제 블록이 주소 기반 destruct 가 되어야 한다.

#### 안 C. 안전망만 먼저 (임시)

- 변경: sema 에서 generator 본문의 지역이 어떤 `yield` 의 범위 안에 들어 있으면 컴파일 에러(또는 경고)로 알린다. 가장 보수적인 규칙은 "generator 본문에 매개변수 외의 지역을 두지 않는다"이다.
- 장점: 2.4.6 의 segfault 를 막는다. 몇십 줄이면 된다. 단점: 거의 모든 실용적인 generator 가 막힌다. 안 A 가 들어올 때까지의 가드로만 의미가 있다.

| 안 | 변경 크기 | 복사 비용 | 빌림 안전 | 위험 |
| --- | --- | --- | --- | --- |
| A. RET_Y 되돌려 저장 | 작음(파일 5~6개) | 프레임 크기 x 2 / 전환 | 패치 또는 금지 규칙 필요 | 스택 주소 지역 |
| B. 힙 프레임 지역 | 큼(sema/IR/bc_gen) | 없음(접근마다 메모리 연산) | 안전 | 컴파일러 변경 폭 |
| C. 컴파일 에러 가드 | 매우 작음 | 없음 | 해당 없음 | 표현력 상실 |

권장 순서(제안): C 로 안전망 -> A 로 정상 동작 -> 필요하면 B 로 빌림까지. A 를 하기 전에 `generator.cy` 에 2.4.1 의 케이스(b1, b2, b3, d2, c1, e5, h1)를 회귀 테스트로 먼저 넣는다.
테스트가 실패하는 모양으로 먼저 고정되어 있어야 수정이 올바른지 알 수 있다.

### 6.6 설계 철학 메모와 fork 유지보수 시사점

- upstream 은 정적 타입 전환과 함께 "yield 가 반환 타입을 갖는 코루틴"만 남기고 나머지를 Thread 로 보냈다. 이 판단 자체는 일관되지만, generator 의 프레임 모델이 완성되지 않은 채 멈췄다.
  `ret_generator` 의 주석("Only persists the locals", "Assumes generator is 1 reg return")과 `core.cy` 의 "store the generator handle in frame[3]" 은 같은 가정에서 나온다. 반환 슬롯은 1개이고 지역은 어딘가에 보존된다는 가정이다. 둘 다 `?int` 에서 깨진다.
- 이 fork 가 코루틴 계층에서 먼저 해야 할 일은 새 기능이 아니라 안전이다. 우선순위(제안): (1) generator 지역 보존(6.5), (2) `unwindStack` / `recordCurFrames` / debug sym 의 gen 프레임 처리, (3) `yield` 가 `#[generator]` 밖에서 컴파일러를 죽이는 문제, (4) 비-main `await` 의 `@panic("TODO")`.
  (4)는 임베딩에서 스크립트 한 줄로 호스트를 죽이는 경로라 에이전트 루프에 가장 직접적이었고 2026-11-08 에 고쳐졌다(2.6).
- 에이전트 루프에 필요한 "호스트에서 멈추고 재개"는 길 2(VM 루프 탈출)가 가장 싸다. `Fiber` 는 그 위에서 같은 힙의 여러 실행 맥락이 정말 필요해질 때 검토해도 늦지 않다. 이는 판단이 아니라 6.4 의 변경 크기 비교다.
- 문서와 코드가 어긋나는 곳이 많다(7.2). 이 영역은 문서를 믿지 말고 `rg` 로 소스 존재 여부부터 확인하는 습관이 필요하다.

## 7. 알려진 이슈, 문서와 코드의 차이, 미완 지점

### 7.1 이 장에서 확인한 이슈 (재현 방법 포함)

| # | 이슈 | 영향 | 재현 | 상태 |
| --- | --- | --- | --- | --- |
| 1 | generator 본문 지역이 `ret_gen` 스냅샷 밖 (`bc_gen.zig:2345`) 이고 `RET_Y` 가 저장하지 않음 | 조용한 오답, 무한 루프 | 실습 3 (b1, b2, b3, d2, c1) | 실행으로 재현, 원인 코드 확인 |
| 2 | yield 를 넘는 관리 타입 지역이 해제/읽기에서 쓰레기 포인터를 씀 | segfault | 실습 4 (e5) | 실행으로 재현 |
| 3 | 빌림 `&T` 매개변수가 `semaLift` 검사 없이 힙 스냅샷으로 들어감 | use-after-return | 실습 8 (br2) | 실행으로 재현. 2026-11-08 수정 `a7418c29` (F-14, 빌림 매개변수는 컴파일 오류) |
| 4 | `unwindStack` 의 `.gen` 분기가 반환 슬롯 1개를 가정 (`thread.zig:1006~1009`) | `-> int` generator 안 panic 이 호스트를 abort (exit 134) | 실습 7 (st4) | 실행으로 재현 |
| 5 | `gen_next` / `gen_end` 에 debug sym 이 없음 (`bc_gen.zig:720, 733`) | 릴리스에서 generator 관련 panic 이 `unexpected 4`(`CL_ERROR_UNKNOWN`) | 실습 7 (st3, dn1) | 증상 재현, 원인은 추정 |
| 6 | `recordCurFrames` 에 `.gen` 분기 없음 (`thread.zig:930`) | generator 안에서 `meta.stack_trace()` 가 호스트 abort | `stt1.cy` (exit 134) | 실행으로 재현 |
| 7 | `yield` 를 `#[generator]` 없이 쓰면 sema 가 `.cast(.pointer)` 에서 죽음 (`sema.zig:711`) | 컴파일러 segfault / 임베딩 시 호스트 abort | 실습 7 (y4) | 실행으로 재현 |
| 8 | 비-main 스레드의 `Future.await` 가 `@panic("TODO")` (`vm.zig:1026`) | 스크립트가 호스트를 abort (exit 134) | 실습 5 (t7) | 실행으로 재현. 2026-11-08 수정 `56af553f` (F-07, 2.6) |
| 9 | 연달아 `spawn` 하면 한 워커에 쌓여 직렬 실행될 수 있음 (`worker.zig:69~72`) | 병렬성 저하 | 실습 5 (sp4) | 증상 재현, 원인은 추정 |
| 10 | 스레드 패닉의 원래 메시지가 소실됨 (`worker.zig:153~163`) | 디버깅 곤란 | 실습 5 (t4) | 실행으로 재현. 2026-11-08 수정 `56af553f` (`Spawned thread panicked: <msg>`) |
| 11 | `bytecode.zig:717~722` 의 `gen_next` 덤프가 피연산자를 `pc+3`, `pc+5` 에서 읽음 (VM 은 `pc[2]`, `pc[3]`) | 덤프의 둘째/셋째 숫자가 틀림 | `cyber compile` 로 `Generator.next` 보기 | 코드와 덤프 비교로 확인 |
| 12 | `GEN_NEXT` 에 `CHK_STK` 류 스택 여유 검사가 없음 (`vm.c:1434~1459`) | `next()` 를 스택 끝 근처에서 부르면 제너레이터 프레임이 스택 밖을 쓸 수 있음 | 재현 안 함 | 미확인 (코드 읽기) |
| 13 | `yield` 만 쓰는 형태는 sema 에서 "TODO" (`sema.zig:748`). 파서는 다음 줄 내용을 식으로 읽어 ParseError 를 내는 경우가 있음 (y2.cy) | 값 없는 yield 불가 | y2.cy | 관찰 |
| 14 | generator reset TBD, 값을 되받는 yield 없음 | 표현력 | 문서(TBD) | 미구현 |

12번은 코드 읽기만으로 세운 것이다. `GEN_NEXT` 의 프레임은 `next` 함수가 `CHK_STK` 로 확보한 영역(`frame=13`) 위에 얹히는데 제너레이터 자신의 프레임 크기(`chk_stk` 의 `frame`)는 호출 때 한 번 검사될 뿐 재개 때는 검사되지 않는다.
메인 스택이 크고(43690 슬롯) 성장도 50% 단위라 평소에는 드러나지 않을 것으로 본다. 스레드의 기본 스택(511슬롯)에서 깊은 호출 뒤에 큰 제너레이터를 재개하면 가능성이 있지만 재현하지 않았다.

### 7.2 문서와 코드의 차이

| 문서 | 코드 (확인 방법) |
| --- | --- |
| `docs/docs.md` Generators: `print(gen)` -> `Generator[fn()->int]` | `^Generator[fn() -> int]` (실습 1) |
| `docs/docs.md` Generators: 지역 상태 언급 없음. `docs/history/coroutines_concurrency.md`: "프레임 하나만 저장" | 매개변수 영역만 저장되고 본문 지역은 저장되지 않는다 (2.4) |
| `docs/docs.md:2787` Fibers (`Fiber(fn, args)`, `f.resume()`) | `type Fiber` 선언 없음. `rg 'type Fiber' src` 결과 없음 |
| `docs/docs.md:2765~2785` Sendable: `byte`, `bool`, `[]T`, `Array`, `Map`, 합성 타입 | `int` 계열과 `@send` 가 있는 struct(`str`)만. `float`, `bool`, `byte` 는 "Expected sendable", `Array[int]` 는 `NoCopy` 오류 (실습 5). `Sendable` trait 없음 |
| `docs/docs.md:2745` spawn: "`Result[Future[T]]` ... 디스패치 못 하면 panic" | `fn spawn(...) -> Future[Sig.ret()]` (`core.cy:4381`) |
| `docs/docs.md:2876` Future await: "현재 스레드를 중단하고 스케줄러가 다른 스레드를 재개" | 어느 스레드든 spin 으로 블록하며 큐의 작업을 돕는다. 비-main 의 `@panic("TODO")` 는 2026-11-08 수정 (2.6). 매뉴얼은 같은 날 고쳤다 |
| `docs/docs.md` Futures: `f.get().?`, `use aio`, `aio.delay` | `Future.get` 없음, `aio` 모듈 없음 (실습 5). `docs/history/coroutines_concurrency.md` 의 "f.get()" 도 같다 |
| `docs/docs.md` Future chains(`then_spawn`), Channels, Shared memory, OS threads, `await` union, Gas mileage | 전부 TBD 이거나 소스 없음 |
| `docs/docs.md` 람다 `spawn(\|_\| -> int, {})`, `FutureResolver(int)` 문법 | `FutureResolver.new(int)` 만 동작 (`src/test/memory/future_resolver.cy`). 람다 spawn 은 TBD |
| `docs/docs.md:2826` Growable stacks: 포인터 레이아웃으로 스택 포인터 패치 | 구현되어 있다 (일치. 실습 8) |

### 7.3 확인하지 못한 것 (추정 또는 미확인)

- 0.3 의 `coresume` / `coyield` 전환 시간: 0.3 빌드를 하지 않았다. 2.1 과 6.2 의 O(1) 은 코드 구조에 근거한 것이고 시간 수치가 아니다.
- 0.3 에서 호스트 함수(네이티브 프레임)를 가로지르는 yield 의 동작: 0.3 소스에서 해당 분기를 찾지 못했다(미확인).
- e2.cy 가 어느 줄에서 죽는지, segfault 뒤의 "integer does not fit in destination type" 이 왜 나오는지.
- 이슈 5 의 원인(debug sym 부재)은 증상과 코드 읽기, `project_vm_interrupt.md` 의 선례로 설명했으나 `gen_all_debug_syms` 로 증상이 사라지는지는 확인하지 않았다.
- 이슈 9 의 원인(`request_idle_worker` 의 판단 시점)은 가설이다. 워커 코드를 바꿔 보지 않았다.
- CPU 가 1개인 환경(`workers.len == 0`)에서 `spawn(...).await()` 가 영원히 spin 하는지: 이 머신(10코어)에서 재현할 수 없었다.
- generator 본문 안에서 fuel/interrupt 로 멈출 때 `unwindStack` 가 같은 경로로 죽는지: 코드상 같은 경로(`handleStop` -> `handleInterrupt` -> `panic` -> `unwindStack`)이나 CLI 에 fuel 옵션이 없어 실행하지 못했다.
- 람다 안의 `yield` 와 `yield` 값 없는 형태: 파서가 먼저 거절해서 sema 동작을 보지 못했다.
- 안 A / B / C 는 모두 제안이고 구현·검증하지 않았다.

### 7.4 미완 지점 (upstream 이 비운 자리, `docs/decisions/project_coroutines.md` 와 일치)

- 스택형 `Fiber`: 문서만 있다. 에이전트 루프에 중단/재개가 필요해지면 길 2 또는 길 3 을 이 fork 가 설계해야 한다.
- generator reset, 값을 되받는 yield, 위임(`yield*`): 없다.
- continuation 큐, `cl_run_ready_tasks`: 주석 처리. 비-main await 는 2026-11-08 부터 블록한다(2.6).
- 패닉한 자식 스레드 상태 조회, Channels, Shared memory, OS threads: TBD.

## 8. 이해도 확인 Q&A

### Q1. 0.3 의 fiber 는 호출 중간에서 yield 할 수 있었는데 0.4 generator 는 왜 못 하나? 못 하게 되면서 설계는 무엇을 얻었나?

A: fiber 는 자기 스택 전체를 소유해서 yield 시점의 fp 하나만 저장하면 호출 체인이 그대로 남는다. generator 는 프레임 하나만 힙에 복제하고, 재개 때 그 프레임을 소비자 스택 위에 펼친다.
호출 체인(스택)을 저장하지 않으므로 `bar()` 안에서 부모 제너레이터를 멈출 방법이 없다. 얻은 것은 비용이다. 스택을 따로 할당·성장·패치하지 않아도 되고 객체 하나(48바이트 + 스냅샷)로 끝난다.
대가는 색이다. 호출 체인을 가로지르는 yield 가 필요하면 중간 함수를 모두 generator 로 바꿔 `yield*`(소스에는 없음)로 위임해야 하는데, 지금은 그것도 없다(`generator.cy` 의 주석 처리된 테스트).

### Q2. `RET_Y` 에 `memcpy(gen->frame_ptr, stack + ret_size + 4, ...)` 한 줄을 넣으면 지역 소실 문제가 끝나나?

A: 정수 같은 값 지역에는 충분하다. 그러나 (1) `ret_gen` 의 `reg_end` 가 그 시점 값이라 먼저 본문 끝에서 채우거나 yield 별 `reg_end` 를 쓰도록 바꿔야 하고, (2) 스택 주소를 담은 지역(`&T` 빌림, `Ptr`)은 프레임이 `next()` 마다 소비자 스택의 다른 위치로 옮겨지므로 그대로 복사하면 옛 주소를 가리킨다.
스택이 재할당될 때 `patch_frame_ptrs` 가 하는 일(포인터 레이아웃으로 스택 범위 안의 값을 새 기준으로 옮김)을 `GEN_NEXT` 에도 해야 하거나, yield 를 넘는 빌림을 컴파일 에러로 막아야 한다. (3) 빌림 `&T` 매개변수가 스냅샷으로 힙에 들어가는 문제(br2)는 이것과 별개의 검사 문제다.

### Q3. `src/test/concurrency/generator.cy` 가 통과하는데 버그가 있다. 어떤 테스트를 추가해야 이를 잡고, 왜 하나의 케이스로는 부족한가?

A: 버그는 "yield 를 넘는 지역 + 소비자가 같은 스택 영역에 쓰는 호출 또는 다른 호출 지점" 두 조건이 겹쳐야 보인다. 그래서 최소 네 가지를 따로 넣는다. 지역을 바꾸며 yield 하는 직선 코드(b1), 루프 카운터(b2/b3), 소비자 쪽 deep call(d2), 서로 다른 호출 지점(c1).
같은 호출 지점에서 호출 없이 반복하는 케이스(d1)는 버그가 있어도 통과하므로 대조군으로만 의미가 있다. 관리 타입 지역(e5)은 값 오염과 다른 실패 모드(메모리 안전성)라 따로 필요하다. 테스트 파일 끝의 `--cytest: pass` 규칙에 맞춰 `test.eq` 로 값을 단정해야 한다.

### Q4. `unwindStack` 의 gen 분기는 왜 `-> int` 제너레이터에서만 죽고 `-> ^int` 에서는 (트레이스 빌드에서) 동작하나?

A: `.gen` 분기가 호출 정보를 `fp+1`, 돌아올 pc 를 `fp+2`, gen 핸들을 `fp+3` 에서 읽는다. 반환 슬롯이 1개일 때의 위치다. 반환 슬롯 수는 `max(^Generator, ?T)` 의 레지스터 수이고(`bc_gen.zig:2778~2786`), `?int` 는 태그 + 값이라 2개, `?^int` 는 널 가능 포인터 하나(zero_union)라 1개다.
`-> int` 에서는 base 가 `fp+2` 라 실제 gen 핸들이 `fp+4` 에 있는데 `fp+3`(돌아올 pc)을 gen 핸들로 읽어 `asPtr` 의 정렬 검사에서 죽는다. 다른 프레임 타입은 `getFrame` 의 `base` 를 쓰는데 이 분기만 하드코딩했다는 것이 원인이다.

### Q5. "await 는 colorless" 라는 말은 무슨 뜻이고, 지금 구현에서 지켜지는가?

A: `await()` 가 메서드라서 `async` 같은 함수 표식 없이 어느 함수에서나 부를 수 있다는 뜻이다(`docs/history` 의 "colorless 유지"). 문법상은 지켜진다. 동작상으로도 2026-11-08 부터는 어느 스레드에서나 블록한다(그 전에는 비-main 스레드의 await 가 `@panic("TODO")` 로 호스트를 죽였다. t7). 다만 블록하는 동안 그 스레드는 큐의 다른 작업을 돕는 것 말고는 바쁜 대기다.
JS 의 `await` 가 이벤트 루프에 제어를 돌려주는 것과 달리, Cyber 의 main `await` 는 호스트 스레드를 spin 으로 붙잡는다(2.6). "colorless" 가 "블록하지 않음"을 뜻하지 않는다는 점에 주의한다.

### Q6. 에이전트 루프에서 도구 호출을 기다리려면 스택형 Fiber 가 반드시 필요한가?

A: 필요하지 않다. 스크립트 하나가 통째로 멈추면 충분한 구조(한 번에 하나의 도구 호출 대기)에서는 VM 루프 탈출(6.4 길 2)이 더 싸다. `execBytecode` 는 `t->c.pc` / `t->c.fp` 에서 시작해 `RETURN` 시 그 둘을 되돌려 놓고, `CL_AWAIT` 결과 코드도 이미 ABI 에 있다.
Fiber 가 필요해지는 경우는 같은 힙에서 여러 실행 맥락이 번갈아 도는 구조(여러 도구 호출을 동시에 기다리는 스크립트 등)다. 그때도 호스트 프레임을 넘는 yield 는 막아야 한다. 어느 쪽도 지금은 구현되어 있지 않고 6.4 의 변경 크기 비교는 제안이다.

### Q7. `spawn` 이 인자를 복사하는 이유와, 지금 `str` 과 `int` 만 보낼 수 있는 이유는?

A: 스레드마다 힙이 따로라서 힙 객체를 스레드 사이에서 공유하지 않는 설계다. `@send(thread, ptr)` 가 값을 대상 스레드의 힙에 새로 만들어 주는 훅이다(`core.cy:2661`, `str` 은 `core.cy:3342`).
`@send` 는 `int` 계열과 `@send` 메서드를 가진 struct 만 허용하고 지금 메서드를 가진 것이 `str` 하나뿐이라 `float`, `bool`, `byte` 도 "Expected sendable" 이 된다. 문서의 `Sendable` 목록은 앞서 나간 설계이고 소스의 현재 상태가 아니다.

### Q8. 제너레이터 100만 개가 RSS 150MB, `next()` 가 30ns 라는 숫자를 0.3 fiber 와 어떻게 비교해야 정직한가?

A: 0.3 은 빌드해서 재지 않았으므로 숫자 대 숫자 비교는 못 한다. 코드 구조에서 읽은 것만 비교한다. 0.3 의 fiber 는 객체 88바이트에 스택을 따로 할당하고(최소 128바이트) 전환이 포인터 교환이다. 반면 0.4 generator 는 객체 48바이트에 스냅샷이고 전환마다 스냅샷 크기만큼 복사한다.
메모리는 generator 가 가볍고, 전환 비용은 fiber 가 프레임 크기와 무관하다는 점이 구조적 차이다. 다만 현재 generator 는 지역을 저장하지 않으므로 "가볍다"에는 정확성이 포함되지 않은 가벼움이다. 6.5 의 수정이 들어가면 복사량이 늘어나 전환 비용 수치가 달라질 것이다(추정).

## 9. 더 알아보기

- 키워드: stackful / stackless coroutine, one-shot continuation, CPS 변환, state machine transform, SuspendGenerator / ResumeGenerator(V8), generator frame(CPython 3.11), liveness analysis, stack map(Go), `Pin`(Rust), "attempt to yield across a C-call boundary"(Lua).
- 이 저장소의 관련 문서: `docs/decisions/project_coroutines.md`, `project_embedding_agent_loop.md`, `project_vm_interrupt.md`, `project_tars_agent_runtime_review.md`, `docs/history/coroutines_concurrency.md`, `docs/docs.md` 의 Concurrency 장.
- 관련 챕터: 프레임과 호출 규약, `CHK_STK`, 스택 성장은 [05-vm-runtime.md](05-vm-runtime.md). ARC, 빌림, `semaLift`, 소멸자는 [06-memory-ownership.md](06-memory-ownership.md). `bc_gen` 의 레지스터 할당(`reserve_reg`)은 [04-bytecode-gen.md](04-bytecode-gen.md). 속성 파싱은 [01-pipeline-front-end.md](01-pipeline-front-end.md). 임베딩 API(`cl_vm_interrupt`, `CL_AWAIT`)는 [08-embedding-builtins-tests.md](08-embedding-builtins-tests.md).
- 다음 날: [09-agent-loop-and-roadmap.md](09-agent-loop-and-roadmap.md) 에서 이 장의 길 1~5 를 로드맵으로 정리한다.
- 더 해 볼 것: (1) `generator.cy` 에 2.4.1 의 케이스를 "현재 실패" 형태로 추가해 보고 `behavior_test.zig:303` 의 등록 방식을 읽는다. (2) `0.3` 의 `fiber_test.cy` 를 현재 문법으로 옮길 수 있는 부분(제너레이터)과 없는 부분(중첩 yield)으로 나눈다. (3) 길 2 를 위해 `CALL_HOST` 가 반환 코드를 받는 지점(`vm.c:940~`)과 `exec_bytecode`(`vm.zig:590~`)의 재진입 가정을 읽는다.
