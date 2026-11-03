---
aliases: [VM 런타임, vm.c, 인터프리터 루프]
tags:
  - study
  - cyber
  - vm
  - runtime
  - interpreter
---

# Day 5. VM 런타임: 바이트코드가 실제로 실행되는 곳

> 대상 소스: src/vm.c (인터프리터 루프), src/vm.h (Zig와 공유하는 구조체와 opcode 표), src/vm.zig (VM 구조체, 진입 함수), src/thread.zig (Thread, 스택 성장, 언와인드), src/debug.zig (pc -> 소스 위치, 트레이스 출력), src/bytecode.zig (명령어 길이와 덤프), src/builtins/core.zig (호스트 함수 예), src/lib.zig (fuel/interrupt API와 테스트)
> 줄 번호는 모두 HEAD b40531a1 기준이다. 문서(docs/decisions 등)와 코드가 다르면 코드를 따랐다.
> 예상 학습 시간: 4~5시간 (읽기 1.5 / 소스 탐독 2 / 실습 1.5). 이 가이드에서 가장 낯선 영역이므로 다른 날보다 길게 잡았다.
> 선행: [04-bytecode-gen.md](04-bytecode-gen.md) (IR -> 바이트코드). 이 챕터의 호출 프레임 그림(2.5절)은 04 챕터가 참조하는 기준 그림이다.
> 실험 환경: 기본 CLI는 ReleaseSafe 빌드(zig-out/bin/cyber), 런타임 트레이스는 -Dtrace 빌드 CLI(cyber -v). 실험 파일의 절대 경로가 긴 탓에 출력에서는 앞부분을 `...`로 줄였다. 그 외에는 실제 출력 그대로다.

## 한줄 요약

컴파일러가 만든 u16 배열(바이트코드)을 `pc`(다음 명령어 주소)와 `stack`(현재 프레임 시작 주소) 두 개의 CPU 레지스터 변수로 훑어 가며 실행하는 C 함수 `execBytecode` 가 VM 의 전부이고, 나머지(스레드, 스택 성장, 패닉, 힙)는 Zig 가 이 함수 바깥에서 뒷받침한다.

## 오늘의 학습 목표

- [ ] 소스 파일을 실행했을 때 `main` 에서 `execBytecode` 까지 가는 호출 체인을 말할 수 있다.
- [ ] `vm.h` 의 padding 트릭(ZThread, ZVM)이 왜 필요하고 어떻게 검증되는지 설명할 수 있다.
- [ ] `execBytecode` 의 구조(레지스터 변수, computed goto, NEXT/CASE, RETURN)를 읽고, 새 opcode 를 추가할 때 건드려야 할 곳을 안다.
- [ ] 함수 호출 한 번이 스택에 남기는 흔적을 CALL / CHK_STK / RET 단계별로 그릴 수 있고, 바이트코드 덤프의 `%N` 과 대응시킬 수 있다.
- [ ] 호스트 함수(Zig 로 쓴 builtin)가 인자를 받고 값을 돌려주는 방식(HostFn ABI)을 core.zig 의 실제 코드로 설명할 수 있다.
- [ ] 패닉이 발생해서 스택 트레이스가 출력되기까지의 경로와, interrupt/fuel 이 VM 을 멈추는 원리를 설명할 수 있다.
- [ ] 이 코드베이스에서 죽은 코드와 실제로 살아 있는 코드를 구분하고, 이 챕터에서 발견한 버그 목록(7절)을 알고 있다.

## 1. 왜 이것이 필요한가?

### 1.1 컴파일러의 산출물은 아직 "실행된 것"이 아니다

01~04 챕터를 거치면 소스 코드는 `ByteCodeBuffer` 안의 `ops`(16비트 정수 배열)와 상수, 디버그 테이블이 된다. 이 배열은 TypeScript 로 치면 `tsc` 가 만든 `.js` 파일과 같다. 그 자체로는 아무 일도 하지 않는다. 누군가 첫 명령어부터 읽어 "이 번호는 덧셈이니 슬롯 5와 6을 더해 슬롯 2에 넣자" 하고 수행해야 한다. 그 누군가가 VM(Virtual Machine, 가상 머신)이다.

### 1.2 실행 방식의 선택지

실행 방식은 크게 AST 순회(트리를 재귀로 평가), 바이트코드 VM(평평한 명령어 배열을 루프로 해석), 네이티브 코드 생성(C 코드 생성 `-cc`/`-tcc`는 cgen.zig 의 실험 단계, JIT 는 동작하지 않음. `docs/decisions/project_direction.md` 20행 이하)으로 나뉜다. 기본은 바이트코드 VM(`-vm`)이고 이 챕터의 주제이다. 이 fork 의 목적(스크립트 CLI + 에이전트 루프용 임베딩)에서는 맞는 선택이다. 빌드가 빠르고, 한 프로세스에서 여러 번 eval 할 수 있고, 실행 중단/스택 트레이스/메모리 정리 같은 "호스트가 VM 을 통제하는 기능"을 넣기 쉽다.

### 1.3 VM 이 해결해야 하는 문제

1. 빠른 디스패치(dispatch): 명령어 하나를 읽고 해당 처리 코드로 점프하는 비용이 전체 속도를 좌우한다. 그래서 `vm.c` 는 `pc` 와 `stack` 을 CPU 레지스터에 고정하고 computed goto 를 쓴다(2.4절).
2. 함수 호출 규약: 인자를 어디에 두고 반환값을 어디로 돌려주며 호출자의 상태를 어떻게 복원하는가(2.5절).
3. Zig 와 C 의 협업: 인터프리터 루프는 C 이고, 스레드/힙/패닉 처리는 Zig 이다. 두 언어가 같은 구조체를 같은 메모리 배치로 보게 해야 한다(2.2절).
4. 비정상 상황: 0 나눗셈, 범위 밖 인덱스, 무한 루프, 폭주 재귀. 패닉이면 스택 트레이스를 만들고 힙을 정리해야 하고, 무한 루프는 호스트가 끊을 수 있어야 한다(2.8, 2.9절).

### 1.4 TypeScript/Node 개발자를 위한 대응

(일반 지식) `execBytecode` 의 디스패치 루프는 V8 의 Ignition 인터프리터(바이트코드 핸들러 테이블)에, `stack` 은 호출 스택의 프레임에 해당한다. 단 V8 은 레지스터 파일에 누산기(accumulator)를 더해 쓴다. 호스트 함수(`#[bind]`)는 N-API 네이티브 바인딩에, 패닉 + 스택 트레이스는 잡히지 않은 `throw` 와 `Error.stack` 에(단 Cyber 0.4 에는 catch 가 없다), `cl_vm_interrupt`/fuel 은 `vm.runInContext(..., { timeout })` 의 타임아웃에 비유할 수 있다.

## 2. 근본적인 동작 원리

### 2.1 큰 그림: 실행이 시작되어 execBytecode 에 이르기까지

`cyber file.cy` 를 실행했을 때의 호출 체인이다. 모두 코드에서 확인한 것이다.

```
src/main.zig        evalPath (255)                       CLI 가 VM 을 만들고 eval 요청
  └ c.vm_eval_path  -> src/lib.zig cl_vm_eval_path (262)  C API 경계(임베딩도 같은 길)
      └ VM.eval (src/vm.zig:421)
          ├ self.compiler.compile(...)                    소스 -> ByteCodeBuffer (01~04 챕터)
          └ VM.exec_bytecode (src/vm.zig:593)
              ├ prepEval (579)    main_thread.c.pc = &ops[main_pc]
              │                    stackEnsureTotalCapacity(buf.mainStackSize)
              │                    main_thread.c.fp = stack_ptr          <- fp 는 슬롯 0
              ├ main_thread.resetStop()   (thread.zig:458)             interrupt 지우고 fuel 채움
              └ Thread.exec_auto (src/thread.zig:469)
                    while (true) {
                        res = vmc.execBytecode(t)       <- src/vm.c:416, 핫 루프
                        RES_SUCCESS        -> break
                        RES_STACK_OVERFLOW -> growStackAuto(); continue    (스택 키우고 재진입)
                        RES_INTERRUPT      -> handleStop(...)
                        RES_PANIC/UNKNOWN  -> handleExecResult -> 패닉 처리, error.Panic
                    }
```

진입 함수의 이름은 `exec_bytecode`(vm.zig:593)와 `exec_auto`(thread.zig:469)이다(`evalByteCode` 같은 이름은 없다).

핵심 관찰은 `execBytecode` 가 "한 번 호출되면 프로그램이 끝나거나, Zig 가 처리해야 할 일이 생길 때까지" 도는 함수라는 점이다. 스택이 모자라면 `RES_STACK_OVERFLOW` 를 돌려주며 빠져나오고, Zig 가 스택을 키운 뒤 같은 `pc`/`fp` 로 다시 들어간다. 느리고 드문 일(스택 확장, 패닉 처리)을 핫 루프 밖으로 빼서 루프 코드를 작게 유지하는 설계이다(thread.zig:467 주석: "To reduce the amount of code inlined in the hot loop, handle StackOverflow at the top and resume execution").

`execBytecode` 의 결과 코드(vm.h:875~885):

| ResultCode | 의미 | 발생 위치 | exec_auto 의 반응 |
|---|---|---|---|
| RES_SUCCESS (0) | `END` 명령어에 도달 | vm.c:1767 | 루프 종료 |
| RES_AWAIT (1) | await 가 현재 스레드를 멈춰야 함 | vm.c:1494 AWAIT | error.Await 반환 |
| RES_PANIC (2) | 패닉 발생. 메시지는 `t->c.panic_payload` | 0 나눗셈, CALL_HOST 실패 등 | 패닉 언와인드(2.8절) |
| RES_STACK_OVERFLOW (3) | 프레임이 남은 스택보다 큼 | vm.c:923 CHK_STK | 스택 확장 후 재진입 |
| RES_UNKNOWN (4) | Zig 헬퍼의 할당 실패 등 | zAlloc* 실패 경로 | 패닉과 같은 경로 |
| RES_INTERRUPT (5) | interrupt 또는 fuel 소진 | CHECKPOINT | handleStop (2.9절) |

### 2.2 Zig 와 C 의 경계: padding 트릭

인터프리터는 C(`vm.c`)이고 나머지 런타임은 Zig 이다. C 코드는 `t->c.pc`, `t->c.fp`, `t->c.stack_end` 같은 Thread 필드를 읽고 쓰고, `t->heap.c.ctx` 같은 Heap 필드도 만진다. 그런데 이 구조체의 실체는 Zig 의 `Thread` 이다(thread.zig:209).

```zig
// src/thread.zig:209
pub const Thread = struct {
    alloc: std.mem.Allocator,
    c: ThreadC,
    heap: cy.Heap,

    unwinding: bool,
    compact_trace: std.ArrayList(vmc.CompactFrame),
    stack_trace: cy.StackTrace,
    ...
```

`Thread` 는 `extern struct` 가 아닌 평범한 Zig struct 라서 Zig 컴파일러가 필드 순서를 바꿀 수 있고, `std.mem.Allocator` 나 `std.ArrayList` 같은 C 가 이해할 수 없는 타입이 들어 있다. 그래서 C 쪽(vm.h:817)은 다음처럼 "앞쪽 크기만큼 비워 두고 공유할 부분만 선언"하는 방법을 쓴다.

```c
// src/vm.h:817  (ZThread)
typedef struct ZThread {
#if !defined(__wasm__)
    u8 padding[16];      // Zig 쪽 앞부분(추정: Allocator 필드, 포인터 2개 = 16바이트)을 건너뜀
#endif
    Thread c;            // C 도 보는 부분: pc, fp, stack_end, fuel, interrupt ...
    ZHeap heap;
} ZThread;
```

```
Zig 쪽 cy.Thread 메모리                      C 쪽 ZThread 가 보는 같은 메모리
+-----------------------------+              +-----------------------------+
| alloc  (Allocator, 16B 추정)|   <------>   | padding[16]                 |
+-----------------------------+              +-----------------------------+
| c: ThreadC (extern struct)  |   <------>   | Thread c  (pc, fp, ...)     |
+-----------------------------+              +-----------------------------+
| heap: cy.Heap               |   <------>   | ZHeap { padding[96/120];    |
|   (그 안에 c: vmc.Heap)     |              |         Heap c; }           |
+-----------------------------+              +-----------------------------+
| unwinding, compact_trace,   |              (C 는 이 뒷부분을 모른다)
| stack_trace ...             |
+-----------------------------+
```

`VM` 도 같은 방식이다(vm.h:827 `ZVM`: padding 432 바이트(RT_SAFETY 가 켜지면 536), 그 뒤에 `VM c`). Zig 쪽 `VM.c: VMC`(vm.zig:35)가 그 위치에 있어야 한다.

이 방식의 위험은 Zig 가 필드를 재배치하거나 디버그 락 필드가 추가되어(주석: "With runtime safety on, every std.ArrayList and std.HashMapUnmanaged carries a usize pointer-stability lock") 오프셋이 바뀌는 것이다. 조용히 틀린 오프셋으로 읽으면 메모리가 깨진다. 그래서 빌드 타임에 검증한다.

```zig
// src/thread.zig:158
comptime {
    if (@offsetOf(Thread, "c") != @offsetOf(vmc.ZThread, "c") or @offsetOf(Thread, "heap") != @offsetOf(vmc.ZThread, "heap")) {
        @compileError(std.fmt.comptimePrint("ZThread padding: Zig Thread.c/heap are at {}/{}, C ZThread.c/heap are at {}/{}", .{ ... }));
    }
}
```

같은 검사가 heap.zig:1780(ZHeap)과 vm.zig:747(ZVM)에도 있다. `comptime` 블록은 파일이 분석될 때마다 평가되므로 테스트 빌드뿐 아니라 모든 빌드 모드에서 오프셋 불일치가 컴파일 에러로 드러나고, 에러 메시지에 두 쪽 오프셋이 모두 찍힌다. 이 방식은 커밋 ce521d5d("Measure ZHeap and ZVM padding per build mode, check offsets at comptime")에서 들어왔다. 새 필드를 `Thread` 나 `VM` 앞쪽에 넣는 변경을 하면 이 컴파일 에러를 보게 되고, vm.h 의 padding 숫자를 에러 메시지 값에 맞춰 고치면 된다. 반면 `ThreadC`(thread.zig:180)와 C `Thread`(vm.h:771)는 필드 이름과 순서를 똑같이 맞춰야 하고, thread.zig:166 의 테스트가 각 필드의 `@offsetOf` 를 비교한다.

> 정리: C 와 Zig 의 공유 구조체는 `extern struct`(ThreadC, VMC, Heap.c)이고, 그 구조체가 담긴 바깥 Zig 구조체는 자유 배치이므로 "바깥에서의 오프셋만 padding 으로 맞추고 컴파일 타임에 감시"한다.

### 2.3 스레드와 메인 스택

VM 은 시작할 때 main thread 하나를 만든다(vm.zig:184~185: `alloc.create(cy.Thread)` 후 `Thread.init(0, ...)`). 각 Thread 는 자기 스택(`Value` = 8바이트 슬롯의 배열)과 자기 힙(`t.heap`)을 가진다. 스크립트가 `spawn` 으로 만드는 스레드(core.zig:1597 `new_thread`)도 같은 구조의 Thread 이고 워커 풀이 `callFunc2` 로 실행한다(worker.zig:154). 이 챕터는 main thread 의 동작을 기준으로 한다.

```zig
// src/thread.zig:255  Thread.init 끝부분
// 4KB default stack size.
try self.stackEnsureTotalCapacityPrecise(511);
self.c.fp = self.c.stack_ptr;
```

처음 스택은 511 슬롯(약 4KB)이고, eval 직전에 `prepEval`(vm.zig:579)이 `stackEnsureTotalCapacity(buf.mainStackSize)` 로 main 블록이 필요한 만큼 늘린다. 그 뒤로는 호출이 깊어질 때 CHK_STK 가 부족을 감지해 `RES_STACK_OVERFLOW` 로 빠져나오고, `growStackAuto`(thread.zig:857)가 50%(최소 16 슬롯)씩 키운다. 상한은 없다(실험은 5절 실습 5). 따라서 `RES_STACK_OVERFLOW` 는 패닉이 아니라 "스택 확장 요청"이고, 확장이 실패하면(할당 실패) `error.OutOfMemory` 가 `exec_auto` 를 빠져나가 `ErrorUnknown` 이 될 것으로 보이지만 메모리를 소진하는 실험이라 시도하지 않았다(추정).

트레이스 빌드에서 `cyber -v` 로 재귀 깊이 20000 짜리 프로그램을 돌렸을 때 실제로 찍힌 로그이다(deep.cy: `sum(20000)` 재귀).

```
thread: grow stack to size=68259
thread: grow stack to size=102388
thread: grow stack to size=153582
vm: main stack size: 43690
```

마지막 줄의 `main stack size: 43690` 은 `buf.mainStackSize`(vm.zig:606)인데, 이 값은 사실 쓰레기이다. 43690 은 16진수 0xAAAA 이고 Zig 가 `undefined` 메모리를 안전 검사 빌드에서 채우는 패턴이다. 근거는 다음과 같다.

1. bc_gen.zig:628~630 은 `popProc(c)` 로 main 의 `Proc` 을 스택에서 꺼낸 다음에 `c.buf.mainStackSize = c.getMaxUsedRegisters()` 를 읽는다. `Reg` 는 `u16` 이다(bc_gen.zig:17).
2. Zig 0.17 의 `ArrayList.pop` 은 꺼낸 슬롯을 `undefined` 로 덮는다(`/opt/homebrew/Cellar/zig/0.17.0/lib/zig/std/array_list.zig:577`). main 이 마지막 Proc 이면 `cur_proc` 포인터는 갱신되지 않고(bc_gen.zig:2866의 `if len > 0`) 방금 비운 슬롯을 가리킨다.
3. 따라서 안전 검사가 켜진 빌드(Debug, ReleaseSafe, 이 트레이스 빌드)에서는 0xAAAA 가 읽힌다. 트레이스 빌드의 로그가 그 증거이고, ReleaseSafe 도 같은 코드 경로이므로 같을 것으로 추정한다. ReleaseFast 에서는 비운 슬롯의 옛 값이 그대로 남아 정상 값을 읽을 것으로 추정한다(미확인).

부수 효과로 안전 검사 빌드에서는 main 스택이 항상 약 45506 슬롯(11번의 1.5배 성장으로 도달하는 첫 값: 511 -> 774 -> ... -> 45506) 이상으로 시작한다. 이 숫자는 첫 번째 성장 로그가 45506 * 1.5 = 68259 인 것과 일치한다. 이것이 의도된 설계는 아니므로 7절 이슈 목록에 올렸다.

스택이 `realloc` 으로 다른 주소로 옮겨지면, 스택 안의 값 중 "스택 내부를 가리키는 포인터"(예: `&x`, 빌림 `&T`)는 새 주소로 고쳐 써야 한다. `growStackPrecise`(thread.zig:868)가 프레임을 거슬러 올라가며 `patch_frame_ptrs`(thread.zig:68)로 고치는데, 어느 레지스터가 스택 포인터인지는 바이트코드 생성기가 호출 지점마다 기록해 둔 `ptr_table`/`ptr_layouts` 로 알아낸다(bc_gen.zig:3103 `pushCall`). 이 메커니즘에는 구멍이 있다(7절 이슈 3, 실습 6에서 재현).

### 2.4 인터프리터 루프 해부

`execBytecode`(vm.c:416)의 뼈대는 다음 몇 줄이 전부이다.

```c
// src/vm.c:605
register Inst* pc; 
register Value* stack;

pc = t->c.pc;
stack = t->c.fp;
#if CGOTO
    // Goto first instruction.
    NEXT();
```

- `pc`: 지금 실행할 명령어의 주소. `Inst` 는 `uint16_t`(vm.h:350)이다. 명령어는 u16 단위의 배열이고 첫 단위의 하위 바이트가 opcode 이다(`*(u8*)pc`).
- `stack`: 현재 함수 프레임의 시작 주소(fp). 바이트코드의 레지스터 `%N` 은 `stack[N]` 이다.

둘을 지역 변수로 두고 `register` 로 표시하는 이유는 속도이다. 이들을 `t->c.pc` 같은 메모리 필드로 두면 명령어마다 메모리를 읽고 써야 한다. 지역 변수이면 컴파일러가 CPU 레지스터에 상주시킨다. 이 판단이 맞았는지 어셈블리로 확인했다(`vm.c` 첫머리 주석이 알려주는 방법: `zig cc -S -O2 -DCGOTO=1 -DTRACE=0 ...`, aarch64 호스트). `MOV` 처리 코드는 이렇게 컴파일되었다.

```
; CASE(MOV): stack[pc[1]] = stack[pc[2]]; pc += 3; NEXT();
ldrh  w8, [x20, #4]            ; pc[2]          (x20 = pc)
ldr   x8, [x19, x8, lsl #3]    ; stack[pc[2]]   (x19 = stack)
ldrh  w9, [x20, #2]            ; pc[1]
str   x8, [x19, x9, lsl #3]    ; stack[pc[1]] = ...
add   x21, x20, #6             ; pc += 3  (u16 3개 = 6바이트)
mov   x20, x21
ldrb  w8, [x21]                ; 다음 opcode
ldr   x8, [x25, x8, lsl #3]    ; jumpTable[opcode]   (x25 = jumpTable)
br    x8                       ; 간접 점프 = 다음 핸들러로
```

`pc` 와 `stack` 이 x20, x19 에 상주하고, 핸들러 하나가 끝나면 그 자리에서 곧바로 다음 핸들러로 `br` 한다. 이것이 computed goto(label as value) 디스패치이다. 반대편인 `switch` 방식은 모든 핸들러가 루프 맨 위의 한 지점으로 돌아가므로 분기 예측기 입장에서 "다음에 어느 핸들러로 갈지"의 예측 정보가 한 점에 뭉친다. 핸들러마다 자기 `br` 을 가지면 명령어 순서 패턴이 분기 예측에 더 잘 반영된다(일반 지식).

#### NEXT, CASE, jumpTable

```c
// src/vm.c:588~594
STATIC_ASSERT(sizeof(jumpTable) == (CodeEND + 1) * sizeof(void*), JUMP_TABLE_INCOMPLETE);
#define CASE(op) Code_##op
#define NEXT() \
    do { \
        PRE_TRACE(); \
        goto *jumpTable[*(u8*)pc]; \
    } while (false)
```

`jumpTable`(vm.c:446)은 `&&Code_CONST_64` 같은 라벨 주소의 배열이고, `vm.h` 의 `OpCode` enum(vm.h:151~307)의 정의 순서와 같은 순서로 나열되어야 한다. 실제로 맞는지 스크립트로 확인했다: jumpTable 의 `JENTRY` 132개와 enum 의 `Code*` 132개가 같은 순서이고, `CASE(...)` 라벨 집합도 일치한다. 다만 `STATIC_ASSERT` 가 검사하는 것은 "개수"(`CodeEND + 1`)뿐이다. 두 항목의 순서가 바뀌어도 개수가 같으면 통과하므로, 순서 일치는 사람이 지켜야 한다. Zig 쪽 `OpCode`(bytecode.zig:1068)는 `const_64 = vmc.CodeCONST_64` 처럼 값을 C enum 에서 가져오므로 번호 자체가 어긋날 일은 없다. 새 opcode 를 추가할 때 손댈 곳은 다섯 군데이다: (1) vm.h 의 `OpCode` enum(`CodeEND` 앞), (2) vm.c 의 `jumpTable`(enum 과 같은 위치)과 `CASE(...)` 핸들러, (3) bytecode.zig 의 `OpCode`(1068)와 `getInstLenAt`(898, 명령어 길이), (4) bytecode.zig 의 덤프 포맷(`write_inst`, 304 이하), (5) bc_gen.zig 에서 해당 명령어를 내보내는 곳.

`switch` 대체 경로(`#else`, vm.c:595~603, 615~616, 1771~1774)는 사실상 죽은 코드이다. build.zig:642 가 항상 `-DCGOTO=1` 을 주고, `-DCGOTO=0` 으로 문법 검사를 해 보면 `NEXT()` 매크로의 `goto beginSwitch` 뒤에 세미콜론이 없어 `vm.c:622: error: expected ';' after goto statement` 로 컴파일되지 않는다(직접 확인).

#### 명령어 인코딩

모든 피연산자는 u16 단위로 연속해서 놓인다. 레지스터 번호도, 점프 오프셋도, 즉시값도 마찬가지이다. 큰 값은 여러 단위에 나눠 저장하고 `READ_U32/U48/U64` 매크로(vm.c:417~419)가 조립한다.

```c
// src/vm.c:618  CONST_64: [op][dst][64비트 즉시값 4단위]  = 6단위
CASE(CONST_64): {
    u16 dst = pc[1];
    stack[dst] = READ_U64(2);
    pc += 6;
    NEXT();
}
// src/vm.c:928  CALL: [op][base][함수 주소 u48 = 3단위]   = 5단위
pc = (Inst*)READ_U48(2);
```

함수 주소를 48비트로 바이트코드에 박아 넣는 이유는 CALL 이 상수 테이블이나 함수 테이블을 거치지 않고 곧바로 점프하게 하기 위해서이다(컴파일러가 마지막에 `relocations` 로 주소를 채운다. bc_gen.zig:3107~3108). 대가로 포인터가 48비트에 들어간다고 가정한다(x86-64 와 arm64 의 사용자 영역 주소). `CONST_STR` 도 같은 방식으로 문자열 포인터(48비트)와 길이(16비트)를 한 u64 에 담는다(vm.c:627~628). 문자열 리터럴 길이가 65535 바이트를 넘으면 안 된다는 뜻이다(이 한계는 코드에서 유추한 것이고 실험하지 않았다).

명령어 길이는 컴파일러/디버거가 알아야 하므로 `getInstLenAt`(bytecode.zig:898)에 표로 있다. 예: `ret`/`ret_0` 은 1단위, `mov` 는 3, `add` 는 4, `call`/`call_host` 는 5, `const_64` 는 6, `const_str` 은 7, `closure` 는 7 + 캡처 개수.

#### 산술 명령어의 매크로

세 피연산자(dst, 왼쪽, 오른쪽) 형태의 연산은 `INTEGER_BINOP`, `UINT_BINOP`, `FLOAT_BINOP` 같은 매크로(vm.c:351~409)가 `dst = pc[1]`, `left = stack[pc[2]]`, `right = stack[pc[3]]`, `pc += 4; NEXT();` 를 찍어낸다. 그래서 `CASE(IMUL)` 은 `INTEGER_BINOP(stack[dst] = BITCAST(u64, left * right))` 한 줄이다(vm.c:1605). 3-주소 형태이고 누산기(accumulator)가 없다는 점이 V8 Ignition 과의 가장 큰 차이이다. 의미 세부는 2.6절에서 다룬다.

#### RETURN 매크로와 문맥 저장 시점

핫 루프 안에서 `pc` 와 `stack` 은 지역 변수이므로, 루프를 떠날 때만 Thread 에 되써 준다.

```c
// src/vm.c:323
#define RETURN(code) \
    do { \
        t->c.pc = pc; \
        t->c.fp = stack; \
        return code; \
    } while (false)
```

vm.c 안에서 문맥(pc, fp)을 Thread 에 저장하는 시점은 다음 네 곳뿐이다(Zig 쪽 `callPtrInst` 등이 호스트 함수를 부르기 직전에 `self.c.pc/fp` 를 따로 쓰는 경우는 2.7절에서 다룬다).

| 시점 | 위치 | 이유 |
|---|---|---|
| `RETURN(code)` | vm.c:323 | 루프를 나갈 때. Zig 가 `t->c.pc/fp` 를 보고 이어받거나(스택 확장) 스택 트레이스를 만든다 |
| `CALL_HOST` | vm.c:944~945 | `t->c.pc = NULL; t->c.fp = stack + base`. 호스트 함수가 자기 프레임(인자 위치)을 `t->c.fp` 로 찾게 하고, `pc == NULL` 은 "호스트 프레임"의 표시이다(2.7절) |
| `AWAIT` | vm.c:1497~1498 | 재개 지점 저장 |
| 트레이스 빌드의 `PRE_TRACE` | vm.c:429~430 | 매 명령어 직전에 `trace_pc/trace_fp` 저장. 크래시 시 "어디서 죽었나"를 알기 위한 것이고 일반 빌드에서는 없음 |

그 외의 명령어는 아무것도 저장하지 않는다. 이것이 핫 패스 비용 0 의 비결이면서 함정이기도 하다. `zAllocClosure`, `zDestroyObject` 같은 Zig 헬퍼를 부르는 동안 `t->c.pc` 는 마지막으로 저장된 값(오래된 값)일 수 있다. 그 안에서 스택 트레이스를 찍어야 하는 디버깅 코드는 그래서 `trace_pc` 를 쓰는 `getTraceFiberContext`(thread.zig:383)를 사용한다.

참고로 `SAVE_STATE`/`RESTORE_STATE` 매크로(vm.c:339~349)는 정의만 있고 어디에서도 쓰지 않으며, 존재하지 않는 `vm->c.curPc` 를 참조하는 옛 코드이다.

### 2.5 호출 프레임: 기준 그림

이 절이 04 챕터와 공유하는 기준이다. 모든 내용은 vm.c 와 실제 덤프/트레이스로 확인했다.

#### 프레임 한 개의 레이아웃

함수 한 개의 프레임은 다음 순서의 슬롯(각 8바이트)이다. 슬롯 번호가 바로 덤프의 `%N` 이다.

```
          callee 함수 본문에서 본 번호
          +---------------------------+
   %0     | 반환 슬롯 0               |  <- ret_size 개 (0, 1, 3 ...). 타입이 str 이면 3개
   ...    | 반환 슬롯 ret_size-1      |
          +---------------------------+  <- 여기부터가 "base" (CALL 이 쓰는 위치)
 %ret+0   | callinfo                  |  비트 필드: 호출 명령어 길이, 프레임 종류(vm/host/gen)
 %ret+1   | 반환 주소 (호출자의 pc)   |
 %ret+2   | 이전 fp (호출자의 stack)  |
 %ret+3   | callee 슬롯               |  클로저/트레이트 객체 같은 "호출 대상 값" (CALLEE_START = 3)
          +---------------------------+
 %ret+4   | 첫 번째 인자              |  CALL_ARG_START = 4
   ...    | 나머지 인자               |
          +---------------------------+
          | 지역 변수와 임시 값       |  frame 크기(CHK_STK 의 둘째 피연산자)까지
          +---------------------------+
```

`ret` 는 반환 슬롯 개수(`CHK_STK` 의 `ret=` 값)이다. 예를 들어 `ret=1` 이면 `%0` 이 반환 슬롯, `%1` 이 callinfo, `%2` 가 반환 주소, `%3` 가 이전 fp, `%4` 가 callee 슬롯, `%5` 가 첫 인자이다. 이 숫자는 vm.h:146~149 의 상수(`CALL_ARG_START 4`, `CALLEE_START 3`)와 `bc_gen.zig:2179` 의 "Reserve return info, return address, previous frame pointer, and optional callee" (`reg_end += 4`)가 맞물려 나온다.

#### 실제 덤프와 대응: 재귀 함수 sum

인라인되지 않는 재귀 함수로 확인한다(sum3.cy).

```
fn sum(n int) -> int:
    if n == 0:
        return 0
    return n + sum(n - 1)
print(sum(3))
```

```
--0 `fn sum`
0:114 .chk_stk: ret=1, frame=13        <- 반환 슬롯 1개, 프레임이 쓰는 슬롯은 %0~%12
0:117 .const_16s: %7 = 0
0:120 .cmp: %6 = (%5 == %7)            <- %5 가 인자 n
0:124 .jump_f: if (!%6) jmp @131
0:127 .const_16s: %0 = 0               <- 반환값을 %0 에 직접 쓴다
0:130 .ret:
0:131 .const_16s: %12 = 1
0:134 .sub: %11 = %5 - %12             <- n - 1 을 %11 에 만든다
0:138 .call: %6 = sum3.sum(%11..%12) 0 <- 호출. 결과는 %6, 인자는 %11
0:143 .add: %0 = %5 + %6
0:147 .ret:
```

`call: %6 = sum(%11..%12)` 를 해석하는 법이 중요하다. bytecode.zig:403~442 의 덤프 코드가 `base` 피연산자(=7)에서 `%(base - ret_size) = ...(%(base+4) ..)` 를 계산해서 찍은 것이다. 즉 CALL 의 피연산자 `base` 는 "반환 슬롯 다음, callinfo 가 놓일 슬롯의 번호"이고, 호출 결과의 목적지는 `base - ret_size = 6`, 인자 시작은 `base + 4 = 11` 이다.

#### 단계별 스택 상태

호출자 프레임의 fp 를 `F` 라 하자. 아래는 `sum` 안에서 `call: %6 = sum(%11..%12)` 를 실행하는 동안의 스택이다(인덱스는 `F` 기준 절대 슬롯).

단계 1. 호출 직전 (`sub %11 = %5 - %12` 까지 끝남)

```
 F+0   F+1  F+2  F+3  F+4    F+5   F+6   F+7   F+8   F+9   F+10  F+11  F+12
+-----+----+----+----+------+-----+-----+-----+-----+-----+-----+-----+-----+
| ret | ci |rpc |pfp |callee|  n  |  ?  |  ?  |  ?  |  ?  |  ?  | n-1 |  1  |
+-----+----+----+----+------+-----+-----+-----+-----+-----+-----+-----+-----+
  %0   %1   %2   %3   %4     %5    %6    %7    %8    %9    %10   %11   %12
^ stack = F                          ^dst  ^---- 컴파일러가 callee 정보용으로 비워 둔 자리 ----^
```

호출자는 "인자를 callee 가 기대하는 위치(`base + 4`)"에 미리 만들어 둔다. `%7~%10` 은 아직 쓰레기이다.

단계 2. CALL 직후 (vm.c:928~938)

```c
u16 base = pc[1];                              // 7
uintptr_t ret_fp = (uintptr_t)stack;           // F 를 기억
stack += base;                                 // stack = F+7
stack[0] = VALUE_CALLINFO(false, CALL_INST_LEN, 0);   // F+7 : callinfo
stack[1] = (uintptr_t)(pc + CALL_INST_LEN);           // F+8 : 반환 주소 = CALL 다음 명령어
stack[2] = ret_fp;                                    // F+9 : 이전 fp
pc = (Inst*)READ_U48(2);                              // callee 의 첫 명령어(CHK_STK)로
```

```
 F+5   F+6   F+7      F+8       F+9    F+10   F+11
+-----+-----+--------+---------+------+------+------+
|  n  |  ?  |callinfo| 반환pc  | F    |  ?   | n-1  |
+-----+-----+--------+---------+------+------+------+
                ^ stack (임시로 callinfo 를 가리킴)
```

이 순간의 `stack` 은 callee 의 fp 가 아니라 "base"이다. 반환 슬롯이 아직 계산에 들어가지 않았기 때문이다.

단계 3. CHK_STK 직후 (vm.c:913~927, `ret=1, frame=13`)

```c
stack -= ret_size;                                  // stack = F+6
if (stack + frame_size >= t->c.stack_end) {
    RETURN(RES_STACK_OVERFLOW);
}
```

```
 F+5   F+6   F+7      F+8      F+9   F+10    F+11
+-----+-----+--------+--------+-----+-------+------+
|  n  | %0  |  %1    |  %2    | %3  |  %4   |  %5  |   <- callee 에서 본 번호
+-----+-----+--------+--------+-----+-------+------+
        ^ stack = G = F+6 (callee fp)
        callee 의 %0 은 호출자의 %6 과 같은 슬롯이고, callee 의 %5(인자 n)는 호출자의 %11 이다.
```

핵심은 두 프레임이 겹친다는 것이다. 호출자가 결과를 받으려고 잡아 둔 `%6` 이 callee 의 반환 슬롯 `%0` 그 자체이고, 호출자가 만들어 둔 인자 `%11` 이 callee 의 `%5` 이다. 인자도 반환값도 복사가 일어나지 않는다. 코드 주석(vm.c:919~920)은 "Don't zero the ret memory since the parameters may depend on it. e.g. a = foo(&a)" 라고 적어, 반환 영역을 초기화하지 않는 이유(호출자가 자기 변수의 주소를 인자로 넘길 수 있으므로)를 밝힌다. 스택 검사에 `frame_size` 가 쓰이므로 callee 가 쓰는 가장 높은 레지스터는 `G + 12` 이고, `G + 13 >= stack_end` 이면 `RES_STACK_OVERFLOW` 이다.

CHK_STK 는 `stack -= ret_size` 를 검사보다 먼저 한다. vm.c:916 주석은 "Update fp before stack check so it can be reliably at ret" 라고만 적는다. 이렇게 하면 오버플로로 빠져나갈 때(`RETURN` 이 `t->c.fp = stack` 을 저장) `t->c.fp` 가 이미 callee 의 fp 이고, 스택 워커는 이 fp 에서 `ret_size` 를 더해 callinfo 를 찾는 규칙(`getFrame`, thread.zig:1104)을 그대로 쓸 수 있다. 반대로 확장 후 같은 CHK_STK 를 다시 실행하려면 fp 를 base 로 되돌려야 하므로 `growStackPrecise` 는 `pc` 가 `chk_stk` 인지 단언하고 `fp += ret_size` 를 한다(thread.zig:876~878, 908). 두 가지 모두 코드에서 확인한 사실이고, "왜 그렇게 설계했나"는 이 연결에서 읽어낸 해석이다.

단계 4. RET 직후 (vm.c:1010)

```c
CASE(RET): {                       // ret_size == 1 전용
    pc = (Inst*)stack[2];          // G+2 = F+8 : 반환 주소
    stack = (Value*)stack[3];      // G+3 = F+9 : 이전 fp = F
    NEXT();
}
```

`RET` 는 반환값 복사도, 슬롯 정리도 하지 않는다. 반환값은 callee 가 이미 `%0` 에 써 두었고, 그 자리는 호출자의 `%6` 이므로 다음 명령어 `add %0 = %5 + %6` 은 바로 결과를 읽는다. `ret_size` 별 변형은 세 개이다: `RET_0`(vm.c:1004, 반환 슬롯 0개: `stack[1]`, `stack[2]` 를 읽음), `RET`(1개: `stack[2]`, `stack[3]`), `RET_N`(vm.c:1016, `ret_size` 를 피연산자로 받아 `stack[ret_size+1]`, `stack[ret_size+2]`). 덤프의 `RET_N` 표기 `ret %0..%3` 는 `ret_size=3` 이라는 뜻이다(`to_print_string` 이 `str` 3슬롯을 돌려준다).

0.3 의 `Ret1/Ret0` 는 callinfo 의 `retFlag` 를 읽어 VM 루프를 빠져나갈지 결정했지만, 0.4 의 RET 는 그 검사를 하지 않는다. `ret_flag` 필드는 Zig 쪽 `CallInfo`(thread.zig:1155)에 남아 있고 값은 쓰지만 읽는 곳이 없다(`rg ret_flag src` 로 확인). 대신 Zig 가 VM 을 재진입시킬 때(`callFunc2`, thread.zig:356~359)는 반환 주소에 `END` 명령어 하나짜리 배열의 주소를 넣어 둔다. 그러면 최상위 함수가 `RET` 한 뒤 `END` 를 실행하고 `RETURN(RES_SUCCESS)` 로 루프가 끝난다. "반환 목적지를 바이트코드에 심어 두는" 방식이다.

#### 중첩 호출과 실제 fp 값

`down(2)` 의 가장 깊은 곳에서 패닉을 일으키고 트레이스 빌드의 `-v` 로 언와인드 로그를 찍으면 프레임들의 fp 가 그대로 나온다(p2.cy, 실습 3).

```
thread: unwind on frame pc=[*]bytecode.Inst@2cb1f43811a, fp=13, type=.vm
thread: unwind on frame pc=[*]bytecode.Inst@2cb1f438132, fp=7,  type=.vm
thread: unwind on frame pc=[*]bytecode.Inst@2cb1f438132, fp=1,  type=.vm
thread: unwind on frame pc=[*]bytecode.Inst@2cb1f4380a4, fp=0,  type=.init
```

`down` 은 `call: %6 = down(%11..%12)` 로 자신을 부르고 (main 은 `call: %1 = down(%6..%7)`) 각 프레임의 fp 는 이전 fp 에 "호출의 목적지 번호"를 더한 값이다: main(0) -> 1 -> 7(= 1+6) -> 13(= 7+6). 이것이 위의 겹침이다.

```
abs slot    0    1    2    3    4    5    6    7    8    9    10   11   12   13   14   15   16   17   18   19
main  fp=0  %0   %1   %2   %3   %4   %5   %6
down#1 fp=1      %0   %1   %2   %3   %4   %5   %6   %7   %8   %9   %10  %11  %12
down#2 fp=7                                    %0   %1   %2   %3   %4   %5   %6   %7   %8   %9   %10  %11  %12
down#3 fp=13                                                                 %0   %1   %2   %3   %4   %5   %6
```

각 줄은 한 프레임이 자기 번호(`%N`)로 부르는 절대 슬롯이다. 세로로 읽으면 `down#1` 의 `%6`(절대 7)이 `down#2` 의 `%0` 이고, `down#2` 의 `%6`(절대 13)이 `down#3` 의 `%0` 이다. 각 프레임에서 `%0` 이 반환 슬롯, `%1~%3` 이 callinfo/반환 주소/이전 fp, `%4` 가 callee 슬롯, `%5` 가 인자 `n` 이다.

main 의 fp 는 0 이다. main 은 `CHK_STK` 가 없고(`--start` 아래 덤프에 없음), `%0` 한 칸을 "BC main frame check"용으로 비워 두고(bc_gen.zig:2370) `%1` 부터 지역을 쓴다. 스택 워커가 main 을 알아보는 방법은 단순히 `fp == 0` 이다(thread.zig:1106~1109, 타입 `.init`).

같은 현상을 소스 수준에서도 확인했다. 지역 변수의 주소를 정수로 뽑아 재귀마다 차이를 찍는 프로그램(addr1.cy, 실습 2)이 `-72`(바이트) 즉 9슬롯을 일관되게 찍었고, 그 함수의 덤프는 `call: %9 = depth(%14..%16)` 로 목적지 번호가 9 이다.

#### 호스트 함수 호출의 프레임

`CALL_HOST`(vm.c:940)는 같은 레이아웃을 쓰되 callinfo 의 프레임 종류가 host 이고, callee 로 점프하는 대신 Zig 함수를 부른다.

```c
// src/vm.c:940~961 (요약)
u16 base = pc[1];
t->c.pc = NULL;                        // "호스트 프레임" 표시
t->c.fp = stack + base;                // 호스트 함수가 인자를 찾는 기준
stack[base]   = VALUE_HOSTCALLINFO(false);
stack[base+1] = (Value)pc;             // 반환 주소: CALL_HOST 자신 (CALL 과 달리 pc 가 아직 안 넘어감)
stack[base+2] = (Value)stack;          // 이전 fp
HostFn fn = (HostFn)READ_U48(2);
Ret res = fn(t);
if (res != 0) { RETURN(RES_PANIC); }
pc += CALL_INST_LEN;                   // 호스트 함수는 RET 없이 제자리로 돌아옴
```

차이점 둘. (1) 반환 주소에 CALL 은 `pc + 5`(다음 명령어)를 넣지만 CALL_HOST 는 `pc`(자기 자신)를 넣는다. 스택 워커가 호스트 프레임의 호출 명령어를 찾을 때 `retPcPtr - call_inst_off` 를 쓰는데(debug.zig:517), 호스트 callinfo 의 `call_inst_off` 가 0 이기 때문에 두 값을 맞추는 선택으로 보인다(추정. 주석은 없다). (2) 호스트 호출 전에는 `CHECKPOINT()` 가 없다. 호스트 함수는 자기 안에서 오래 걸려도 인터럽트에 반응하지 못한다(`docs/decisions/project_vm_interrupt.md` "미정" 절이 인정한 한계).

덤프 `call_host: %13 = int_fmt(%20..%22)` 를 해석하면: 반환 슬롯은 `%13~%15`(str 3개), `base = 16`, 호스트 함수의 `t->c.fp` 는 `F+16`, 인자 2개는 `F+20`, `F+21` 이다. 다음 절의 ABI 설명에서 이 숫자가 그대로 쓰인다.

callinfo 의 비트 배치는 C 매크로(vm.h:107~108)와 Zig 의 `packed struct`(thread.zig:1155)가 같은 모양이어야 한다.

```
bit 0        : ret_flag      (쓰기만 하고 읽지 않음)
bit 1~7      : call_inst_off (이 프레임을 만든 호출 명령어의 길이. 언와인드에서 호출 명령어 위치 복원)
bit 8~15     : stack_size    (옛 설계의 흔적. CALL 은 0 을 넣고 호스트는 4)
bit 16~17    : type          0 = vm, 1 = host, 2 = init, 3 = gen
```

`VALUE_CALLINFO(false, CALL_INST_LEN, 0)` 은 `5 << 1 = 10`, `VALUE_HOSTCALLINFO` 는 `(4 << 8) | (1 << 16)` 이고 제너레이터용 `buildGenCallInfo`(vm.c:319)는 `3 << 16` 을 넣는다. `init` 타입(2)은 callinfo 에 실제로 쓰이지 않고 "fp == 0 이면 main"이라는 판정 결과로만 나온다.

### 2.6 명령어 클래스별 구현

132개 opcode 를 다 읽을 필요는 없다. 클래스별 대표를 읽으면 나머지는 같은 모양이다. 아래 `dump` 줄은 모두 `cyber compile` 로 얻은 실제 출력이다.

#### (a) 상수와 이동

- `CONST_16S`(635, 부호 확장), `CONST_16`(641), `CONST_32`(647, 아래 32비트만 쓰고 위 32비트는 그대로), `CONST_64`(618, 4단위 즉시값). `CONST_STR`(624)은 3슬롯 `String{buf=NULL, ptr, len}` 을 만든다(`buf == NULL` 은 정적 문자열, 소유권 없음). `True`/`False`(653)는 1/0.
- `MOV`, `MOV_2/3/4`, `MOV_N`(675~714)은 슬롯 1/2/3/4/n 개를 복사한다. 값 타입이 여러 슬롯(str 3개, Option 2개)이라 크기별 변형이 있다.

값이 슬롯 한 개보다 클 수 있다는 점이 NaN boxing VM(0.3)과의 큰 차이이다. 0.3 은 모든 값이 8바이트 NaN-boxed `Value` 하나였고, 0.4 는 정적 타입을 알기 때문에 타입 정보를 값에 싣지 않고, `str` 은 `{buf, ptr, len}` 세 슬롯, `?int` 는 `{tag, value}` 두 슬롯처럼 펼쳐 둔다(dump 에서 `%6..%9 = 'text'` 로 보임).

#### (b) 점프와 CHECKPOINT

```c
// src/vm.c:851  JUMP_F: 조건이 거짓이면 앞으로 점프 (부호 없는 u16 오프셋)
if (*(bool*)&stack[pc[1]]) { pc += 3; } else { pc += pc[2]; }

// src/vm.c:867  JUMP: 부호 있는 오프셋. 뒤로 가면(루프 되돌이) 체크포인트
int16_t offset = (int16_t)pc[1];
if (offset < 0) { CHECKPOINT(); }
pc += offset;
```

`bc_gen` 이 실제로 내는 점프는 조건부 앞 점프 `jump_f`(`pushEmptyJumpNotCond`), 무조건 `jump`(앞/뒤)뿐이다. `JUMP_T`(vm.c:859)를 내는 `pushEmptyJumpCond` 는 bc_gen.zig 어디에서도 부르지 않는다(rg 로 확인). 모든 루프는 맨 끝에서 `pushJumpBackTo`(chunk.zig:454)로 뒤로 `jump` 하므로 "역방향 JUMP == 루프 한 바퀴"이고, 이것이 interrupt/fuel 검사점이 된다(2.9절). 점프 오프셋이 u16 이라는 한계가 있다(7절 이슈 4).

#### (c) 호출과 반환

앞 절에서 CALL / CHK_STK / RET / RET_0 / RET_N / CALL_HOST 를 봤다. 나머지 호출 방식은 모두 "callee 슬롯(`base+3`)에 호출 대상 값을 두는" 규약을 쓴다. 이 예제(calls.cy)의 덤프로 확인하자.

```
-- 1) 함수 포인터            fp := twice ; fp(21)
0:72  .fn_vm:                          <- 함수 포인터 값을 레지스터에 만듦 (함수의 CHK_STK 주소 자체)
0:77  .mov: %6 = %1                    <- 호출 대상을 callee 슬롯(base+3 = %6)에 복사
0:80  .const_16s: %7 = 21              <- 인자는 base+4 = %7
0:83  .call_ptr: ?..%3 = %6(%7..)      <- base = %3

-- 2) 클로저(Func 유니언)    add_k(5)
0:116 .closure: %3 = closure(id=0, union_t=129, ncap=1, stack=false, vals={ 2, 0 })
0:124 .mov: %8 = %3                    <- 클로저 객체를 callee 슬롯(base+3 = %8)에
0:127 .const_16s: %9 = 5
0:130 .call_union: ?..%5 = call_union(%9..)    <- base = %5
 ...
--5 `fn lambda`
0:267 .chk_stk: ret=1, frame=8
0:270 .captured: %7 = [%4 + 0]         <- callee 슬롯 %4 에서 캡처 0번을 읽음

-- 3) 트레이트 객체          s.area()
0:166 .trait: %10 = trait(type=6, vtable=0, %4)    <- 덤프 오표기. 실제 피연산자는 dst=%4, impl=%6 (7절 이슈 5)
0:171 .mov_2: %10 = %4                             <- {vtable 번호, impl} 두 슬롯을 callee 슬롯(%10)과 첫 인자(%11)로 복사
0:174 .call_trait: ?..%7 = %10.vtable[9](%11..)    <- 덤프의 [9] 도 오표기 (7절 이슈 5)
```

- `CALL_PTR`(vm.c:1023)와 `CALL_UNION`(vm.c:1036)은 Zig 헬퍼 `zCallPtr`/`zCallUnion`(vm.zig:1048, 1077)으로 위임한다. 이유는 대상이 여러 종류(바이트코드 함수, 호스트 함수, 클로저)라서 분기가 많고 그 코드를 핫 루프에 넣고 싶지 않기 때문일 것이다(추정). `callPtrInst`(thread.zig:684)는 callee 슬롯의 값에서 상위 비트(63번)를 보고 호스트 함수인지 바이트코드 함수인지 가른다: 호스트면 `self.c.pc/fp` 를 쓰고 직접 호출한 뒤 `pc + 2` 로 돌아오고, 바이트코드면 CALL 과 같은 callinfo/반환 주소/이전 fp 를 `base_ptr[0..2]` 에 쓰고 `(pc = 함수 주소, fp = base_ptr)` 를 돌려준다. 이 둘은 VM 루프로 돌아와 `pc = res.pc; stack = res.fp;` 로 반영된다.
- 클로저는 힙 객체이다. `CLOSURE`(vm.c:1120)는 캡처할 레지스터 번호들을 명령어 뒤에 붙여 두고(`7 + numCaptured` 단위), `zAllocClosure -> Heap.allocClosure`(heap.zig:1332)가 `{kind=closure, pc, numCaptured, 캡처한 값들...}` 를 만든다. 캡처한 값은 `^T` 박스 포인터이고 pinned 가 아니면 retain 한다. 클로저를 호출하면 클로저 객체가 callee 슬롯에 있으므로 callee 는 `CAPTURED dst, closure_reg(%4), idx`(vm.c:1523)로 읽는다.
- `CALL_TRAIT`(vm.c:963)는 `zCallTrait`(vm.zig:864)가 `fp[base+3]` 의 vtable 번호로 `t.c.vm.vtables[vtable][vtable_idx]` 에서 함수 주소(상위 비트가 호스트 구분)를 꺼내 호출한다. 트레이트 값은 `{vtable 번호, impl 포인터}` 두 슬롯이다(`TRAIT dst, impl, type_id, vtable`, vm.c:1281이 `stack[dst] = vtable; stack[dst+1] = impl;` 로 만든다). `gen_call_trait`(bc_gen.zig:1313)은 이 값을 callee 슬롯과 첫 인자 자리(`base+3`, `base+4`)에 걸쳐 놓으므로("Trait struct is reserved over the callee and the first argument") 구현 함수의 첫 인자 `self` 가 자연히 impl 포인터가 된다.
- `FN_VM`(vm.c:1711)은 함수 주소를 그대로 레지스터에 넣는다. `FN_HOST`(vm.c:1716)는 호스트 함수 주소에 상위 비트 표지를 붙이는 명령어이지만 동작하지 않는다(7절 이슈 1: `1<<63`).
- 체크포인트는 `CALL`, `CALL_TRAIT`, `CALL_PTR`, `CALL_UNION` 에 있고 `CALL_HOST` 에는 없다.

#### (d) 로드, 스토어, ADDR, NEW

구조체는 값으로 레지스터에 펼쳐 있다. 필드를 읽고 쓰려면 "주소 + 바이트 오프셋"으로 접근해야 하므로 두 단계이다.

```
0:6   .addr: %9 = *%5                  <- %5 슬롯의 "스택 주소"를 %9 에 (ADDR, vm.c:1291)
0:39  .store_64: [%9 + 0] = %10        <- %9 가 가리키는 곳 + 0바이트에 8바이트 쓰기 (STORE_64)
0:217 .load_64: %14 = [%15 + 8]        <- %15 가리키는 곳 + 8바이트에서 읽기 (LOAD_64)
```

`ADDR` 는 `(HeapObject*)(&stack[pc[2]])` 를 `stack[dst]` 에 쓴다(힙이 아니라 스택 슬롯의 주소). `LOAD_8/16/32/64`, `LOAD_2W/3W/4W`(2~4슬롯), `LOAD_N`(memcpy)와 `STORE_*` 가 같은 모양으로 폭과 슬롯 수별 변형이다. 힙 객체와 스택 위 구조체가 같은 접근 방식(포인터 + 오프셋)을 쓰므로 `ADDR` 한 번이면 둘을 구분할 필요가 없다. 대가로 "스택 안을 가리키는 포인터"가 생겨서 스택을 `realloc` 할 때 고쳐 써야 한다(2.3절).

`NEW dst, type_id, size`(vm.c:1269)는 `allocObjectInit` 로 `size <= 32` 바이트면 풀 객체(`zAllocPoolObject`), 크면 큰 객체(`zAllocBigObject`)를 할당해 포인터를 `dst` 에 둔다. 힙 객체의 구조와 retain/release 는 [06-memory-ownership.md](06-memory-ownership.md)에서 다룬다.

#### (e) 산술과 비교, 그리고 의미의 세부

`vm.c:1559~1668` 의 정수 산술은 대부분 한 줄이다. 어떤 의미를 갖는지 실제로 돌려 확인했다(arith.cy. `fn id(x int) -> int: return x` 로 값을 통과시켜 상수 폴딩을 피했고, `max := id(9223372036854775807)`, `min := id(-9223372036854775807 - 1)` 에서 `print('max + 1   = %{max + 1}')` 형태로 한 줄씩 찍었다. 덤프에서 `imul`, `idiv`, `imod`, `lsl`, `lsr` 이 쓰였음을 확인했다. 실행 환경은 aarch64 macOS).

```
max + 1   = -9223372036854775808      <- 두 보수 wrap-around
max * 2   = -2
min - 1   = 9223372036854775807
-min      = -9223372036854775808
min / -1  = -9223372036854775808      <- 이 경우 "trap" 이 아니라 wrap
min % -1  = 0
7 / -2    = -3                        <- C 와 같이 0 쪽으로 자름
-7 / 2    = -3
7 % -2    = 1
-7 % 2    = -1
1 << 63   = -9223372036854775808
1 << 64   = 1                         <- 시프트 횟수가 64 이상이면 mod 64
1 << 65   = 2
1 << 256  = 1                         <- (256 & 0xff) == 0
-8 >> 1   = 9223372036854775804       <- 산술 시프트가 아니라 논리 시프트
-8 >> 70  = 288230376151711743
1 << -1   = -9223372036854775808
```

| 연산 | 구현 | 정리 |
|---|---|---|
| `Add`, `Sub`, `MUL` | `UINT_BINOP`, u64 연산 | 정의된 wrap-around. 오버플로 검사 없음 |
| `IMUL`, `Neg` | `INTEGER_BINOP`, i64 연산 | C 의 부호 있는 오버플로(엄밀히는 UB). build.zig:661 이 `sanitize_c = .off` 로 trap 을 껐고 실측은 wrap |
| `IDIV`, `IMOD` | 0 검사 후 `/`, `%` | 0 이면 `panicDivisionByZero`("Division by zero.") + `RES_PANIC`. 0 외에는 검사 없음 |
| `LSL`, `LSR` | `UINT_BINOP`, 횟수는 `right & 0xff` | 횟수 64 이상은 C 에서 UB 이고 실측은 CPU 의 mod 64. 부호 있는 `>>` 도 논리 시프트(산술 시프트 opcode 가 없음) |
| `Pow` | `ipow`(vm.c:274) | 음수 지수는 `1^-1 = 1`, `(-1)^-1 = -1`, 나머지는 0 |
| `F2I` | `(i64)val` | 실측: `1e30 -> 9223372036854775807`, `-1e30 -> 최솟값`, `NaN -> 0`. 이는 arm64 의 변환 명령이 포화(saturate)하기 때문이고 C 로는 UB 라 x86-64 에서는 다르게 나올 수 있다(일반 지식, 미확인) |

`min / -1` 이 wrap 하고 끝나는 것은 arm64 의 `sdiv` 가 이 경우 trap 하지 않기 때문이다. x86-64 의 `idiv` 는 같은 입력에서 하드웨어 예외(SIGFPE)를 낸다(일반 지식). 이 VM 의 `IDIV` 는 0 만 검사하므로 x86-64 에서는 모델이 쓴 스크립트의 `x / -1` 한 줄이 호스트 프로세스를 죽일 수 있다(추정, 미확인). 에이전트 루프용으로 쓸 때 한 번 확인해 둘 항목이다.

폭이 좁은 정수(`i8`, `i32`)는 별도 opcode 없이 64비트 연산을 하고, 필요한 곳에서 `SEXT`/`ZEXT` 로 정규화한다. 실험(narrow.cy, narrow2.cy):

```
i32 max + 1 = -2147483648
i8 127 + 1 = -128
i8 -128 - 1 = 127
i32 max * 2 = -2
i8 100 * 2 = -56
```

덧셈 결과의 위쪽 비트는 정리되지 않은 채 남고(`add` 만 있고 `sext` 가 없음), 비교 직전에 `sext` 가 붙는다(`sext: ...; sext: ...; lt: %16 = %2 < %17`). 좁은 정수 타입의 레지스터 위 비트가 "정의되지 않은 값"이라는 규약이다(vm.h:120 `VALUE_AS_UINTEGER` 주석: "Padding bits returned are undefined"). 새 opcode 를 만들 때 이 규약을 깨면 비교 결과가 틀린다.

비교는 `LT/GT/LE/GE`(부호 있는 i64), `ULT/UGT/ULE/UGE`(부호 없는), `FLT...`(f64), `FLT32...`(f32)로 나뉘고, 동치 검사는 `CMP`(64비트 전체), `CMP_8`(하위 8비트: bool/byte), `CMP_STR`(길이 비교 후 바이트 단위 비교 루프, vm.c:1152)이다.

#### (f) Retain/Release와 소멸

`Retain`, `RetainNZ`(null 이면 건너뜀), `Release`, `ReleaseOpt`, `DTOR_STR`, `COPY_STR` 는 힙 객체의 참조 카운트(rc)를 올리고 내리는 명령어이다. `Release` 는 rc 를 내리고 0 이 아니면 `pc[2]` 오프셋만큼 건너뛴다. 0 이 되면 바로 뒤에 이어진 소멸 코드(`call core.@deinitObject` 등, 앞 호출 예의 덤프 끝부분 참고)가 실행된다. 이 구조는 06 챕터의 소재이다.

### 2.7 호스트 함수 ABI

호스트 함수(host function)는 Zig 로 구현해 VM 에 붙인 함수이다. Cyber 쪽에서는 `#[bind]` 로 선언하고(`core.cy:165~166`: `#[bind]` + `-fn prints_(s str)`) Zig 쪽에서는 이름 표에 등록한다(core.zig:84: `.{"prints_", cFunc(prints)}`). 연결 과정(bindings, 모듈 로더)은 [08-embedding-builtins-tests.md](08-embedding-builtins-tests.md)에서 다루고, 여기서는 호출될 때 스택에서 무슨 일이 일어나는지만 본다.

시그니처는 이것뿐이다.

```c
// src/vm.h:921
typedef uint8_t (*HostFn)(ZThread* t);
```

인자도 반환값도 C 인자/반환으로 주고받지 않는다. 호출 규약은 "스택 프레임에 정해진 위치로"이다. 반환 값 `uint8_t` 는 성공 `0`(`C.RetOk`), 그 외는 패닉이다(vm.c:957 `if (res != 0) RETURN(RES_PANIC)`).

인자와 반환 슬롯의 위치는 CALL_HOST 가 `t->c.fp = stack + base` 로 정해 준다(2.5절). 호스트 함수는 `Thread` 의 도우미로 이 위치를 읽는다.

| 도우미 | 위치 | 하는 일 |
|---|---|---|
| `t.ret(T)` / `t.ret_sized(n)` | thread.zig:543, 547 | `fp_end = fp + 4` 로 "인자 시작"을 세팅하고 `fp - 반환 슬롯 수` 를 포인터로 돌려준다 (반환 슬롯은 fp 앞쪽) |
| `t.param(T)` | thread.zig:561 | `fp_end` 에서 `T` 를 읽고 `fp_end` 를 그 슬롯 수만큼 전진 |
| `t.getValue(i)` / `getInt(i)` ... | thread.zig:605 | `fp[CallArgStart + i]` 를 인덱스로 직접 읽음 |
| `t.ret_panic(msg)` | thread.zig:808 | 메시지를 복사해 `panic_payload`/`panic_type` 에 기록하고 `C.RetInterrupt` 를 돌려줌 |

`prints_` 와 `int_fmt` 가 실제 코드 예이다.

```zig
// src/builtins/core.zig:1256  (print 의 실제 출력 담당)
pub fn prints(t: *cy.Thread) callconv(.c) C.Ret {
    _ = t.ret(void);                         // 반환 슬롯 0개, fp_end 를 인자 시작(fp+4)으로
    const str = t.param(cy.heap.Str);        // 3슬롯(buf, ptr, len)을 읽고 fp_end += 3
    defer t.heap.destructStr(&str);          // 인자로 받은 문자열의 소유권을 넘겨받아 해제
    t.c.vm.print.?(@ptrCast(t.c.vm), C.to_bytes(str.slice()));
    return C.RetOk;
}

// src/builtins/core.zig:2173
fn int_fmt(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(cy.heap.Str);          // fp - 3 슬롯에 str 를 써서 돌려줄 것
    const val = t.param(i64);                // 인자 1: fp[4]
    const format = std.enums.fromInt(NumberFormat, t.param(i64)) orelse return error.InvalidEnumTag;  // 인자 2: fp[5]
    ret.* = try intFmtExt(&t.heap, val, format, .{});
    return C.RetOk;
}
```

앞 절의 `call_host: %13 = int_fmt(%20..%22)` (호출자 fp 를 F 라 하면 base = F+16)에 대입하면:

```
F+13  F+14  F+15 |  F+16     F+17     F+18    F+19     F+20      F+21
[ ret.buf, ret.ptr, ret.len ] | callinfo  반환pc   이전fp   callee   [ val ]   [format]
 <- t.ret(Str) = fp-3 부터 ->   ^ t->c.fp   (host)                    t.param(i64) 두 번
                                                                      (fp_end: F+20 -> F+21 -> F+22)
```

반환값은 호스트 함수가 호출자의 목적지 레지스터(`%13~%15`)에 직접 쓴다. `Str` 가 3슬롯이므로 반환 슬롯도 3개이다. `Value` 하나를 돌려주던 0.3 의 `Value f(VM*, Value* args, u8 nargs)` 와 비교하면(vm.c 0.3: `Value res = fn(vm, newStack + CALL_ARG_START, numArgs); newStack[0] = res;`) 반환이 멀티 슬롯으로 일반화된 것이다(0.3 의 임베딩 C API 쪽 호스트 함수 시그니처와의 비교는 08 챕터). Zig 의 `anyerror!C.Ret` 를 쓰는 함수는 `zErrFunc`/`zErrFunc2`(core.zig:387, 401)가 감싸서, 에러가 나면 `prepPanicZError`(core.zig:419)가 `@errorName(err)` 를 패닉 메시지로 바꾼다. 그래서 `int_fmt` 에 잘못된 포맷 값을 주면 패닉 메시지가 `InvalidEnumTag` 같은 Zig 에러 이름이 된다.

#### fp/pc 보존과 스택 트레이스

CALL_HOST 의 `t->c.pc = NULL; t->c.fp = stack + base;` 는 호스트 함수가 불린 동안 "현재 프레임은 호스트 프레임"이라는 상태를 만든다. 이것이 스택 트레이스에 미치는 영향을 실험으로 확인했다.

1. 호스트 함수가 패닉을 반환하면 CALL_HOST 의 `RETURN(RES_PANIC)` 가 `t->c.pc/fp` 를 다시 VM 프레임(`CALL_HOST` 명령어와 호출자 fp)으로 덮어쓴다. 그래서 `panic('boom')` 같은 호스트 함수가 낸 패닉의 트레이스에는 호스트 프레임이 나오지 않고, 호출 지점이 `down:` 프레임의 한 줄로 찍힌다(5절 실습 3, p2.cy).
2. 호스트 프레임이 트레이스에 나오는 경로는 둘뿐이다. 하나는 호스트 함수 안에서 현재 위치의 트레이스를 요구할 때이다. `meta.stack_trace()`(meta.zig:189)는 `recordCurFrames`(thread.zig:930)로 현재 프레임부터 걷고, 첫 프레임이 호스트 프레임(`pc == NULL`)이어서 `<host>: stack_trace` 줄이 나온다(실습 3). 다른 하나는 트레이스 빌드의 크래시/Zig 패닉 핸들러(`thread_signal_host_panic`, debug.zig:181)로, 매 명령어 직전에 저장한 `trace_pc/trace_fp` 를 쓰고 CALL_HOST 에서는 `trace_pc = NULL` 이므로(vm.c:947~948) 호스트 프레임부터 시작해 `panic at t0@host_call:` 로 출력한다.
3. Zig 쪽에서 VM 을 재진입시키는 `callFunc2`(thread.zig:326)는 호출 전에 `pc`, `fp`, `fp_end` 를 저장했다가 성공하면 복원한다(thread.zig:331~333, 369~371). 주석(327~330)이 이유를 밝힌다: `fp_end` 는 호스트 함수가 `param()` 으로 인자를 소비할 때 움직이므로, 복원하지 않으면 재진입을 반복할 때 스택이 한없이 자란다.

### 2.8 패닉과 언와인드

패닉(panic)은 "복구할 수 없는 오류로 이 스레드의 실행을 끝내는 것"이다. 0.4 에는 `catch` 도 `PushTry/Throw` 도 없다(0.3 에는 있었음, 0.3 vm.c 의 `CASE(PushTry)`, `CASE(Throw)`). 에러 값은 `Result` 로 돌려주고, 못 다루는 것은 패닉이 된다. 패닉이 시작되고 출력되기까지의 전체 경로이다.

```
[발생]  VM 명령어                        호스트 함수
        panicStaticMsg(t, "Division by zero.")   t.ret_panic("msg")
          panic_payload = ptr | (len << 48)        dupe 한 메시지, panic_type = PANIC_MSG
          panic_type = PANIC_STATIC_MSG            return C.RetInterrupt
        RETURN(RES_PANIC)                        CALL_HOST: res != 0 -> RETURN(RES_PANIC)
            │                                          │
            └────────────────┬─────────────────────────┘
                             ▼
[Zig]   Thread.exec_auto (thread.zig:469)   res == RES_PANIC
          └ handleExecResult (415) -> handleInterrupt (426)
               ├ main thread 면 stopSpawnedThreads()   (워커가 힙을 건드리지 않게)
               ├ self.unwinding = true  (패닉 중 패닉이면 abort)
               └ thread.panic (thread.zig:35)
                    ├ unwindStack (970)        프레임을 거슬러 올라가며 compact_trace 에 (pc, fpOffset) 기록
                    ├ allocStackTrace (debug.zig:592)   pc -> 소스 위치/함수 이름
                    └ freeHeapPages (108)      이 스레드의 힙 객체를 전부 해제
[출력]  CLI: thread_panic_summary -> "panic: msg\n\n" + 프레임들, exit(1)   (main.zig:280, 299)
```

#### unwindStack: 스택 워크

`unwindStack`(thread.zig:970)은 패닉이 난 `(pc, fp)` 에서 시작해 프레임 하나씩 거슬러 올라간다. 프레임에서 callinfo 위치를 찾는 일이 `getFrame`(thread.zig:1104)이다.

```zig
// src/thread.zig:1104 (요약)
pub fn getFrame(t, stack, fp_off, opt_pc) FrameInfo {
    if (opt_pc) |pc| {
        if (fp_off == 0) return .{ .base = null };               // main 프레임 (.init)
        const metadata = cy.debug.get_pc_func_metadata(t.c.vm, pc);   // pc 가 속한 함수의 ret_size
        return .{ .base = stack.ptr + fp_off + metadata.ret_size };   // callinfo 위치
    } else {
        return .{ .base = stack.ptr + fp_off };                  // pc == null: 호스트 프레임, fp 가 곧 base
    }
}
```

VM 프레임의 fp 는 반환 슬롯 맨 앞이므로(2.5절) callinfo 를 찾으려면 `ret_size` 를 알아야 하고, 이것은 pc 로 "이 pc 를 포함하는 함수"를 찾아 그 함수의 첫 명령어(`chk_stk`)의 피연산자를 읽어서 얻는다(`get_pc_func_metadata`, debug.zig:46: 함수 시작 오프셋 테이블 `func_table` 을 이진 탐색한 뒤 `metadata_pc + 1` 에서 `ret_size`, `+3` 에서 `stack_size`). 프레임 종류(`FrameType`)별 처리는 이렇다.

| 종류 | 판정 | 기록 | 다음 프레임 |
|---|---|---|---|
| `.init` (main) | `fp_off == 0` | (pc, fp) 기록 후 종료 | 없음 |
| `.vm` | callinfo.type == 0 | (pc, fp) | `prev.pc = 반환주소 - call_inst_off`(= 호출 명령어 자신), `prev.fp = 이전 fp` |
| `.host` | type == 1 | (null, fp) | 위와 같음 |
| `.gen` | type == 3 | (pc, fp) | `gen.prev_fp` 로 제너레이터를 부른 쪽으로 (thread.zig:1006~1010) |

"반환 주소 - call_inst_off" 가 핵심 요령이다. CALL 은 반환 주소로 다음 명령어를 저장하지만(`pc + 5`), 소스 위치는 호출 명령어에 붙어 있으므로 callinfo 의 `call_inst_off`(CALL 이면 5, CALL_PTR 이면 2...)를 빼서 호출 명령어의 주소를 복원한다. `call_inst_off` 가 비트 필드에 있는 이유가 이것이다(thread.zig:1159~1163 주석: "the call convention prefers to advance the pc before saving it so stepping over the call will already have the correct pc").

#### pc -> 소스 위치: 디버그 테이블

`compactToStackFrame`(debug.zig:506)은 `getDebugSymByPc` 로 pc 에 대응하는 `DebugSym{pc, loc, frameLoc, file}` 를 찾고, `loc`(소스 오프셋)에서 줄/열을 계산한다(`computeLinePos`). 두 가지를 알아야 한다.

1. 탐색이 선형이다. `indexOfDebugSymFromTable`(debug.zig:110)은 "TODO: Binary search" 주석이 붙은 for 루프이고 pc 가 정확히 일치하는 항목만 찾는다. 즉 패닉이 나는 바이트코드 명령어마다 정확히 debug sym 이 있어야 한다. 이는 컴파일러가 보장한다: 실패할 수 있는 명령어는 `pushFCode`(chunk.zig:717)로 내보내 debug sym 을 붙이고, 일반 `pushCode` 는 트레이스 빌드나 `gen_all_debug_syms` 일 때만 붙인다(chunk.zig:681~685). 릴리스 빌드에서 새 "패닉할 수 있는" 명령어를 만들면서 `pushCode` 를 쓰면 트레이스가 `error.NoDebugSym` 으로 실패한다. fuel 검사점을 넣을 때 실제로 `.jump` 가 그랬다고 `project_vm_interrupt.md` 가 적는다.
2. 인라인된 함수는 가짜 프레임을 만든다. `allocStackTrace`(debug.zig:592~611)는 인라인된 callee 의 pc 를 만나면 `getInlineSite`(debug.zig:620)로 호출자 프레임을 한 줄 더 추가한다. `src/test/functions/inline_call_panic.cy` 가 이 동작의 테스트이다. 실제 실행에서 `outer` 가 `main` 에 인라인되어도 `inner`, `outer`, `main` 세 줄이 모두 나온다(다음 실행 결과).

패닉 직후 실제로 출력되는 모양은 이렇다(`src/test/functions/inline_call_panic.cy` 실행, 경로 줄임).

```
panic: Division by zero.

.../inline_call_panic.cy:2:12 inner:
    return 10 / x
           ^
.../inline_call_panic.cy:5:12 outer:
    return inner(x) + 1
           ^
.../inline_call_panic.cy:8:7 main:
print(outer(0))
      ^
```

각 프레임은 `{파일}:{줄}:{열} {함수이름}:` + 소스 한 줄 + `^` 이다(`writeStackFrames`, debug.zig:459). 호스트 프레임은 `<host>: {이름}` 한 줄이다(debug.zig:484~491).

#### freeHeapPages: 힙 정리

언와인드는 스택 프레임을 하나하나 풀면서 지역 변수의 소멸자를 부르지 않는다. `thread.panic` 의 주석이 "TODO: Run stack error destructors."(thread.zig:40) 라고 적고, `project_vm_interrupt.md` 도 "panic 경로는 지역 소멸자를 돌리지 않는다" 고 적는다. 대신 `freeHeapPages`(thread.zig:108)가 이 스레드가 할당한 모든 힙 페이지를 훑으며 살아 있는 객체를 `destroyObject(obj, true)` 로 한꺼번에 해제하고 `freeAllBuffers` 한다. "객체 사이의 의존 관계를 무시하고 해제"하므로 사용자 정의 소멸자(예: 파일 닫기)는 실행되지 않는다. 임베딩에서 패닉이 난 뒤에도 같은 VM 을 계속 쓸 수 있는 것(`lib.zig` 의 REPL 테스트와 결정 문서가 확인)은 힙이 이렇게 비워지기 때문으로 보인다. 힙 구조와 ARC 는 06 챕터에서 다룬다.

흔히 `ptr_table`/`ptr_layouts` 가 패닉 때 힙을 해제하는 데 쓰인다고 짐작하기 쉽지만, 이 둘의 소비자는 `get_ptr_layout`(thread.zig:81)이고 호출하는 곳은 스택 성장의 `growStackPrecise`(thread.zig:891) 하나뿐이다(`rg get_ptr_layout`로 확인). 패닉 경로에서는 쓰이지 않는다.

### 2.9 인터럽트와 fuel

에이전트 루프는 모델이 쓴 코드를 실행한다. 무한 루프가 나오면 호스트가 끊을 방법이 있어야 한다. 이 요구에 대한 설계가 `docs/decisions/project_vm_interrupt.md`(2026-11-01)이고, 구현은 코드와 일치함을 확인했다.

```c
// src/vm.c:332
#define CHECKPOINT() \
    do { \
        if (UNLIKELY(*(volatile u8*)t->c.interrupt || --t->c.fuel < 0)) { \
            RETURN(RES_INTERRUPT); \
        } \
    } while (false)
```

- `t->c.interrupt` 는 `u8*` 이고 스레드마다 갖는 것이 아니라 main thread 의 `interrupt_flag` 를 가리킨다(`Thread.init`, thread.zig:253, 그리고 spawn 스레드는 core.zig:1603 에서 main 의 포인터를 복사). 그래서 `cl_vm_interrupt`(lib.zig:254)의 `@atomicStore(u8, main.interrupt, 1, .release)` 한 번이 모든 스레드에 닿는다. `volatile` 로 읽어서 컴파일러가 루프 밖으로 끌어올리지 못하게 한다.
- `t->c.fuel` 은 스레드별 카운터이다. `cl_vm_set_fuel(vm, n)`(lib.zig:258)은 `main_thread.c.fuel_limit` 만 쓰고, 실제 `fuel` 은 eval 시작마다 `resetStop -> resetFuel`(thread.zig:458, 463)이 `fuel_limit > 0 ? fuel_limit : maxInt(i64)` 로 채운다. 무제한은 사실상 "2^63 번 이상"이라 분기가 하나로 합쳐진다. `--fuel < 0` 이므로 `n` 번의 체크포인트는 통과하고 `n+1` 번째에서 멈춘다(문서의 "n번 지나면 멈춘다"와 한 칸 차이).
- 체크포인트 위치는 `JUMP`(오프셋 < 0), `CALL`, `CALL_TRAIT`, `CALL_PTR`, `CALL_UNION`. `CHK_STK` 에 두지 않은 이유는 프레임 전환 도중이라는 점이다(결정 문서). `CALL` 안에서도 `stack[0..2]` 를 쓰기 전, `stack += base` 이전에 검사하므로 `RETURN` 이 저장하는 `(pc, stack)` 은 호출자 프레임의 일관된 상태이다(vm.c:929~930).
- `CALL_HOST` 에는 체크포인트가 없다. 호스트 함수가 오래 걸리면 끊을 수 없다.

멈춘 뒤의 동작은 `exec_auto` 의 `RES_INTERRUPT` 분기(thread.zig:492)가 `handleStop`(thread.zig:443)으로 처리한다: `atomicLoad(interrupt) == 1` 이면 "Interrupted.", 아니면 "Out of fuel." 을 `ret_panic` 으로 패닉 메시지에 넣고, 패닉과 같은 언와인드(스택 트레이스, 힙 정리)를 한 뒤 `error.Interrupted` 를 돌려준다. 처리한 요청은 `defer` 로 0 으로 지운다(thread.zig:447). 임베더에게는 `CL_ERROR_INTERRUPT`(cyber.h:41~48)로 보이고, 같은 VM 을 다시 쓸 수 있다. 사용법은 [08-embedding-builtins-tests.md](08-embedding-builtins-tests.md)에서 다룬다.

비용을 어셈블리로 확인했다. 앞서 `-S -O2` 로 만든 어셈블리에서 `JUMP` 핸들러(출력에서 `Code_JUMP` 라벨 아래)는 이렇다.

```
ldrsh x8, [x20, #2]        ; offset = (int16_t)pc[1]
tbz   x8, #63, LBB1_23     ; 부호 비트가 0(앞쪽 점프)이면 검사점을 건너뜀
ldr   x9, [x23, #136]      ; t->c.interrupt (포인터)
ldrb  w9, [x9]             ; *interrupt
cbnz  w9, LBB1_61          ; != 0 이면 RES_INTERRUPT 경로
ldr   x9, [x23, #120]      ; t->c.fuel
subs  x9, x9, #1           ; --fuel
str   x9, [x23, #120]
b.lt  LBB1_61              ; < 0 이면 RES_INTERRUPT 경로
LBB1_23: add x21, x20, x8, lsl #1 ...   ; pc += offset 후 다음 디스패치
```

뒤로 점프할 때만 로드 3번, 감소 1번, 저장 1번, 분기 2번이 추가된다(앞쪽 `jump`, `jump_f`, 일반 명령어에는 0). 결정 문서는 ReleaseFast 에서 hyperfine 15회로 측정한 결과 fib 30.6 -> 30.9 ms(+0.9%), for 94.1 -> 96.0 ms(+2.1%)라고 적는데, 이 챕터에서 재현하지는 않았다(문서 인용). `x23 = t`, 오프셋 120/136 은 `ZThread` 의 16바이트 padding 뒤 `Thread.fuel`(104)/`interrupt`(120)에 해당한다. 같은 padding 계산이 어셈블리까지 이어진다는 점이 2.2절 설계를 확인해 준다.

설계적 의미를 정리하면 이렇다. (1) 명령어 단위 카운터가 아니라 "루프 한 바퀴/호출 한 번" 단위이므로 직선 코드는 비용이 없다. 대신 검사점 없이 오래 도는 직선 코드의 길이는 바이트코드 크기가 상한이다. (2) fuel 은 시간이 아니라 사건 수라서 같은 입력이면 항상 같은 지점에서 멈추므로 에이전트 실행을 재현/테스트하기 좋다. (3) 정지는 재개가 아니라 패닉과 같은 경로의 종료이다(힙이 정리됨). "멈췄다가 이어서 실행"은 지원하지 않는다. (4) 호스트 함수 안과 `AWAIT` 의 spin 대기 같은 "VM 루프 밖"은 따로 처리해야 해서, `zAwait`(vm.zig:981)의 spin 루프가 interrupt 플래그를 직접 확인한다(vm.zig:1005).

CLI 에서는 fuel 도 interrupt 도 쓸 수 없다. `rg 'fuel|interrupt' src/cli.zig src/main.zig` 결과가 비어 있다. 따라서 직접 실행 증거는 없고, 근거는 `src/lib.zig` 의 테스트 두 개(915행 "cl_vm_set_fuel stops runaway loops and recursion.", 959행 "cl_vm_interrupt stops a running eval.")를 읽은 것이다. 첫 테스트는 `vm_set_fuel(vm, 10000)` 뒤 `while true: i += 1` 과 `fn f(n): return f(n+1)` 이 모두 `C.ErrorInterrupt` 를 돌려주고 보고서가 "panic: Out of fuel." 로 시작함을 확인한 다음, 같은 VM 에서 `0..100` 루프가 정상 완료됨을 확인한다. 직접 빌드는 하지 않았다.

### 2.10 관찰 도구: 트레이스 빌드

`zig build -Dtrace=true` 로 빌드한 CLI(이 실험에서는 `trace-out/bin/cyber`)는 `TRACE=1` 로 vm.c 를 컴파일하고 `cyber -v file.cy` 가 컴파일 단계 로그와 런타임 로그를 낸다. vm.c 에서 정의를 확인한 내용이다.

| 매크로 | 정의 위치 | 동작 |
|---|---|---|
| `PRE_TRACE()` | vm.c:422 | 매 명령어 직전: opcode 별 실행 횟수 `opCounts[*pc].count++`, `totalOpCounts++`, `heap.ctx = pc`, `trace_pc/trace_fp` 저장 |
| `DUMP_OP()` | vm.c:434 | `clVerbose` 이면 `z_dump_thread_inst` 로 그 명령어를 `t0@주소 .op: ...` 형식으로 출력 |
| `TRACE_DUMP_OPS` | vm.c:12, 값 0 | 1 로 바꾸면 `PRE_TRACE` 가 모든 명령어를 출력(재빌드 필요, 시도하지 않음) |
| `TRACE_DUMP_NOP` | vm.c:13, 값 0 | `NOPS` 출력 여부 |

기본값(`TRACE_DUMP_OPS = 0`)에서 `DUMP_OP()` 가 들어 있는 명령어는 `CALL`, `CALL_HOST`, `CALL_TRAIT`, `CALL_PTR`, `CALL_UNION`, `RET_0`, `RET`, `RET_N`, `TRAP`, `TRAP_DEBUG` 열 개뿐이다(vm.c 에서 `DUMP_OP()` 검색). 그래서 `-v` 의 런타임 트레이스는 "호출과 반환의 흐름"이다. 앞의 sum(3) 예에서 실제로 찍힌 것은 이렇다.

```
thread: begin eval loop
t0@3d84d038094 .call: core.@init(%5..%5) 146
t0@3d84e100094 .ret_0:
t0@3d84d0380a4 .call: %1 = sum3.sum(%6..%7) 0
t0@3d84d038122 .call: %6 = sum3.sum(%11..%12) 0
t0@3d84d038122 .call: %6 = sum3.sum(%11..%12) 0
t0@3d84d038122 .call: %6 = sum3.sum(%11..%12) 0
t0@3d84d038112 .ret:
t0@3d84d038134 .ret:
t0@3d84d038134 .ret:
t0@3d84d038134 .ret:
t0@3d84d0380b4 .call: core.prints(%6..%7) 4
...
```

주소(`t0@...`)는 pc 이고 호출 4번 후 반환 4번이 나온다. 첫 `ret` 가 `...112`(기저 사례의 `ret`, pc 오프셋 130), 나머지 세 `ret` 가 `...134`(`add` 뒤의 `ret`, 오프셋 147)라는 것까지 덤프와 맞다.

`cyber -stats file.cy`(트레이스 빌드 전용, main.zig:77)는 실행 끝에 opcode 별 실행 횟수를 내림차순으로 출력한다(실습 1). 활용 요령은 세 가지다. (1) `-v` 출력은 7만 줄이 넘으므로 항상 파일로 받고 `rg -n 'begin eval loop' x.trace` 로 런타임 부분의 시작을 찾는다. (2) 패닉 재현에는 `thread: unwind on frame ...`, `build stackframe pc=..., fp=...` 줄이 스택 워크를 그대로 보여 준다. (3) 크래시가 나면 `trace_pc` 덕분에 어느 명령어에서 죽었는지가 `panic at t0@...` 로 나온다.

## 3. 핵심 개념 정리

| 개념 | 한 줄 설명 | 위치 |
|---|---|---|
| `Inst`, `Value` | 명령어 단위 u16, 데이터 슬롯 8바이트(타입 태그 없음. 정적 타입이라 필요 없음) | vm.h:350, 351 |
| `pc` | 다음에 실행할 `Inst*`. CPU 레지스터에 상주 | vm.c:605 |
| `stack` (fp) | 현재 프레임의 첫 슬롯 주소. `%N == stack[N]` | vm.c:606 |
| 프레임 | `[반환 슬롯][callinfo][반환pc][이전fp][callee][인자][지역]` | 2.5절 |
| `CHK_STK ret, frame` | 함수 첫 명령어. fp 를 반환 슬롯 앞으로 내리고 스택 여유 검사 | vm.c:913 |
| `HostFn` | `uint8_t f(ZThread*)`. 인자와 반환은 스택 슬롯으로 | vm.h:921 |
| padding 트릭 | C 가 Zig 구조체의 일부(`c` 필드)를 같은 오프셋에서 읽게 하는 장치. FFI 구조체 정렬 문제와 비슷 | vm.h:760~838 |
| `CHECKPOINT` | 역방향 점프/호출에서 interrupt 플래그와 fuel 을 검사 | vm.c:332 |
| 패닉 payload | 메시지 포인터(하위 48비트) + 길이(상위 16비트)를 u64 한 칸에 | vm.c:299 |
| compact trace | 언와인드가 모으는 `(pc, fpOffset)` 목록. 소스 위치는 나중에 변환. `Error.stack` 의 원본 프레임 목록에 해당 | thread.zig:218, 970 |
| 디버그 심볼 | `pc -> (소스 위치, 함수)`. 실패 가능한 명령어에만. source map 에 해당 | debug.zig:66 |
| `ptr_table` | 호출 지점마다 "이 프레임의 어느 슬롯이 스택 포인터인가". 스택 맵과 비슷 | bc_gen.zig:3127 |

세 가지 사고방식만 정리한다. (1) 레지스터는 프레임 안의 번호일 뿐이며 호출할 때 호출자와 피호출자의 프레임이 겹친다(2.5절). (2) VM 루프는 상태를 `pc`, `stack` 두 값으로 압축하고, 그 외의 모든 것(스레드, 힙, 스택 크기)은 `t` 를 통해 Zig 와 공유한다. (3) 느리고 드문 일은 `RETURN(code)` 로 루프를 나가서 Zig 가 처리하게 한다.

## 4. 소스 읽기 지도

한 번에 다 읽으려 하지 말고 이 순서로 한 줄씩 따라가자. 괄호는 예상 소요 시간이다.

1. src/vm.h:100~149, 151~307, 875~885 (15분). 상수(`CALL_ARG_START`, `CALLEE_START`), opcode 표 132개, `ResultCode`. opcode 이름을 눈에 익힌다.
2. src/vm.c:323~337, 416~444, 589~616 (15분). `RETURN`, `CHECKPOINT`, `NEXT`/`CASE`, 시작부. 루프의 뼈대만 본다.
3. src/vm.c:618~714 (10분). `CONST_*`, `MOV*`. 가장 단순한 핸들러의 모양.
4. src/vm.c:913~1022 (30분). `CHK_STK`, `CALL`, `CALL_HOST`, `RET*`. 이 챕터의 중심. 2.5절 그림을 손으로 다시 그려 보자.
5. src/thread.zig:469~505 와 src/vm.zig:579~610 (10분). `exec_auto`, `prepEval`, `exec_bytecode`.
6. src/thread.zig:1081~1171 (15분). `FrameInfo`, `getFrame`, `FrameType`, `CallInfo`.
7. src/thread.zig:970~1016 과 src/debug.zig:46~117, 459~613 (30분). 언와인드와 pc -> 소스 위치 변환.
8. src/builtins/core.zig:1256~1262, 2173~2179 와 src/thread.zig:543~566 (15분). 호스트 함수의 실제 모양.
9. src/vm.c:1559~1710 (20분). 산술/변환/비교. 의미 세부는 2.6절 표와 실습 4 로 확인한다.
10. src/lib.zig:254~260, 915~1000 과 docs/decisions/project_vm_interrupt.md (20분). interrupt/fuel 의 API 와 테스트.
11. src/vm.zig:864~1104 (20분). C 가 부르는 Zig 헬퍼들(`zCallTrait`, `zAwait`, `zCallPtr`, `zCallUnion`, `zAlloc*`). 에러를 `ResultCode` 로 번역하는 패턴이 반복된다.
12. src/bytecode.zig:898~1066 (10분). 모든 명령어의 길이 표. 새 opcode 를 추가하는 사람이 반드시 고치는 곳.

읽다가 막히면 `cyber compile x.cy` 로 해당 명령어가 어떤 소스에서 나오는지 먼저 본다. 반대 방향(소스 -> 명령어)이 가장 이해가 빠르다.

## 5. 실습

아래에서 `cyber` 는 ReleaseSafe 빌드(zig-out/bin/cyber), `cyber-trace` 는 `-Dtrace=true` 빌드 CLI 이다. 모든 출력은 실제로 실행한 결과이고 환경은 aarch64 macOS 이다. 실험 소스는 본문에 실었다. 무한 루프/폭주 재귀 가능성이 있는 실험은 `perl -e 'alarm 5; exec @ARGV' cyber x.cy` 로 5초 제한을 걸어 실행했다.

### 실습 1. 재귀 함수의 call/ret 트레이스와 opcode 통계

목표: 인라인되지 않는 재귀 함수에서 CALL/RET 쌍과 프레임 크기를 눈으로 대응시킨다. 소스는 2.5절의 `sum3.cy` 이다.

```
cyber compile sum3.cy                       # fn sum 의 덤프 (2.5절에 실림)
cyber-trace -v sum3.cy > sum3.trace 2>&1    # 7만 줄 이상이므로 파일로
awk '/begin eval loop/{p=1} p' sum3.trace | head -12
```

출력은 2.10절의 `t0@... .call` / `.ret` 목록이다. 관찰 포인트: (1) `sum(3)` 은 호출 4번(main -> 3 -> 2 -> 1 -> 0)과 `ret` 4번. (2) 호출 줄마다 `%6 = sum(%11..%12)` 의 `%6` 이 결과, `%11` 이 인자이다. (3) 첫 `.call: %1 = sum3.sum(%6..%7)` 의 목적지 `%1` 은 main 의 레지스터이고 다음에 `mov %6 = %1` 로 `prints` 에 넘어간다.

opcode 통계(트레이스 빌드 전용):

```
$ cyber-trace -stats fib20.cy       # fn fib(n int) -> int 재귀, print(fib(20))
6765
main ops evaled: 169689
	const_16s 43782
	jump_f 21891
	lt 21891
	chk_stk 10949
	call 10949
	ret 10946
	...
```

`fib(20)` 의 순수 재귀 호출 수는 21891 인데 `call` 은 10949 번이다(그중 3번은 `core.@init`, `prints`, `core.@deinit`). 04 챕터의 인라이너가 재귀 한 단계를 호출자 안에 전개하기 때문이다(`cyber compile` 덤프에서 `fn fib` 본문 안에 같은 비교/뺄셈 패턴이 두 번 나오는 것으로 확인). 함수 진입(`chk_stk`) 10949 회에 명령어 169689 개이므로 진입 한 번당 평균 약 15.5개를 쓴 셈이다. 이런 감을 잡는 용도로 `-stats` 가 좋다.

### 실습 2. 지역 변수의 주소로 프레임 간격 재기

목표: "호출자의 목적지 레지스터 번호 = 프레임 사이 간격" 이라는 2.5절의 주장을 소스 수준에서 검증한다.

```
fn depth(n int, prev int) -> int:
    local := n
    a := @unsafeCast(int, *local)        # 지역 변수의 스택 주소를 정수로
    if prev != 0:
        print('depth=%{n} addr_delta_bytes=%{prev - a}')
    if n == 0:
        return 0
    return depth(n - 1, a) + 1

print(depth(5, 0))
```

```
depth=4 addr_delta_bytes=-72
depth=3 addr_delta_bytes=-72
depth=2 addr_delta_bytes=-72
depth=1 addr_delta_bytes=-72
depth=0 addr_delta_bytes=-72
5
```

덤프의 `depth` 는 `chk_stk: ret=1, frame=42` 이고 재귀 호출은 `call: %9 = addr1.depth(%14..%16) 0` 이다. 목적지 `%9` -> 9슬롯 -> 72바이트. 깊이가 하나 늘 때마다 같은 지역 변수의 주소가 정확히 72바이트(= 9 * 8) 높아진다. 변형: 지역 변수를 더 만들어 `%9` 가 달라지게 한 뒤 간격이 따라서 변하는지 확인해 보자(간격은 프레임 크기가 아니라 호출 지점의 목적지 번호이다. `frame=42` 와 72바이트가 다르다는 점이 증거다).

### 실습 3. 일부러 패닉을 내고 트레이스 읽기

```
fn down(n int) -> int:                 # p1.cy
    if n == 0:
        return 10 / n
    return down(n - 1) + 1
print(down(3))
```

```
panic: Division by zero.

.../p1.cy:3:16 down:
        return 10 / n
               ^
.../p1.cy:4:12 down:
    return down(n - 1) + 1
           ^
.../p1.cy:4:12 down:
    return down(n - 1) + 1
           ^
.../p1.cy:4:12 down:
    return down(n - 1) + 1
           ^
.../p1.cy:6:7 main:
print(down(3))
      ^
```

가장 안쪽(`down(0)`)이 맨 위, main 이 맨 아래이다. 첫 줄의 `3:16` 은 나눗셈 식의 시작 열이고, 나머지 `down` 프레임은 모두 호출 지점 `4:12` 를 가리킨다(각 프레임은 "자신이 다음 함수를 호출하려던 CALL 명령어"의 위치를 보이기 때문이다. 2.8절의 `반환주소 - call_inst_off`). 프레임이 4개 + main 인 것은 `down(3), down(2), down(1), down(0)` 때문이다.

호스트 함수가 낸 패닉은 호스트 프레임 없이 호출 지점에서 끝난다(p2.cy: `panic('boom at the bottom')` 를 `down(0)` 에서 호출).

```
panic: boom at the bottom

.../p2.cy:3:9 down:
        panic('boom at the bottom')
        ^
        (이어서 4:12 의 down 프레임 2개, 6:7 의 main. `<host>: panic` 줄은 없다)
```

호스트 프레임이 보이는 경우는 `meta.stack_trace()` 이다(st.cy: `use meta` 후 `inner(2)` 의 가장 안쪽에서 `print(meta.stack_trace())`).

```
<host>: stack_trace
.../st.cy:5:15 inner:
        print(meta.stack_trace())
              ^
.../st.cy:7:12 inner:
    return inner(n - 1) + 1
           ^
```

기대한 프레임은 `<host>`, `inner`(n=0), `inner`(n=1), `inner`(n=2), `main` 인데 안쪽 두 개만 남았다. `meta.zig:194~195` 가 "Remove top two frames since it contains the stackTrace call" 이라며 `compact_trace.pop()` 을 두 번 부르는데 `pop` 은 목록의 끝(가장 바깥, main 쪽)을 제거한다. 7절 이슈 7.

트레이스 빌드의 `-v` 로 같은 p2.cy 를 돌리면 언와인드 로그가 프레임의 fp 를 그대로 보여 준다(2.5절에 실림: `fp=13`, `7`, `1`, `0 type=.init`).

### 실습 4. 정수 오버플로, 0 나눗셈, 시프트

소스와 출력은 2.6절 (e)에 있다(arith.cy, narrow.cy, narrow2.cy, f2i.cy). 0 나눗셈은 나머지 연산에서도 같은 패닉이다(`print(id(7) % id(0))` -> `panic: Division by zero.` 와 `main:` 한 프레임). 관찰 포인트: `-8 >> 1` 이 큰 양수로 나오는 것(논리 시프트), `1 << 64 == 1`(횟수 mod 64), `min / -1` 이 wrap 하는 것. 변형: 같은 식을 `-cc`(C 백엔드, 실험 단계)로 돌려 결과가 같은지 비교해 보자(이 챕터에서는 시도하지 않았다).

### 실습 5. 스택 성장과 폭주 재귀

깊이 20000 짜리 재귀를 트레이스 빌드로 돌린 로그는 2.3절에 실려 있다(`grow stack to size=68259, 102388, 153582`). 일반 빌드에서 깊이만 키워 보면(deep2.cy: `sum(1000000)`):

```
$ /usr/bin/time -l cyber deep2.cy
500000500000
        0.06 real         0.05 user         0.00 sys
           133758976  maximum resident set size
```

100만 단계 재귀가 0.06초, 최대 RSS 134MB 로 끝난다(프레임 6슬롯 * 8B * 100만 = 48MB 에 성장 중 복사본). 상한이 없다는 증거로 끝없는 재귀를 1초 제한으로 실행했다.

```
fn f(n int) -> int:                 # inf.cy
    return f(n + 1) + 1
print(f(0))
```
```
$ /usr/bin/time -l perl -e 'alarm 1; exec @ARGV' cyber inf.cy
time: command terminated abnormally
        1.06 real         0.71 user         0.26 sys
          4560535552  maximum resident set size
```

1초 만에 최대 RSS 4.5GB 에 도달했다. 스택 오버플로 오류는 나오지 않는다(`RES_STACK_OVERFLOW` 는 확장 요청). 이것이 fuel 이 필요한 이유 중 하나다. fuel 은 `CALL` 마다 하나씩 소비하므로(2.9절) 이런 재귀를 `n` 단계에서 끊는다. 이 실험은 반드시 `alarm` 같은 시간 제한을 걸고 돌릴 것. 제한 없이 돌리면 16GB 컴퓨터에서 몇 초 안에 메모리를 소진한다(추정. 직접 확인하지는 않았다).

### 실습 6. 이 챕터에서 발견한 버그 재현

모두 현재 HEAD 에서 재현되는 것이다. 7절에 원인과 위치를 정리했다.

(6a) `FN_HOST` 가 동작하지 않는다. 호스트 함수 값을 변수에 담아 부르면 죽는다(fnhost.cy).

```
use math
fn twice(x float) -> float:
    return x * 2

f := twice
print(f(4.0))
g := math.sqrt
print(g(16.0))
```
```
8
Segmentation fault at address 0x4020000000000000
Cannot print stack trace: stack tracing is disabled
thread 55140452 panic: integer does not fit in destination type
Cannot print stack trace: stack tracing is disabled
```

`f`(바이트코드 함수)는 되는데 `g`(호스트 함수 값)에서 죽는다. 주소 `0x4020...` 는 8.0 의 비트 패턴, 즉 직전 `f(4.0)` 의 결과가 아직 남아 있는 레지스터를 함수 포인터로 쓴 것이다. `FN_HOST` 가 목적지 레지스터에 아무것도 쓰지 않았다는 뜻이다. 이유는 어셈블리로 확인했다(`zig cc -S -O2` 로 만든 `Code_FN_HOST` 핸들러가 `add x21, x20, #10` 만 하고 `br` 한다. 즉 `pc += 5` 만 한다. 컴파일러 경고 `vm.c:1718: shift count >= width of type`).

(6b) 함수 포인터(`CALL_PTR`)로 부른 호출 중에 스택이 옮겨지면 스택 포인터가 갱신되지 않는다(ptrpatch.cy). 지역 변수 `x` 의 주소 `p := *x` 를 잡고 깊은 재귀를 부른 뒤 `p` 가 현재 `x` 의 주소와 같은지 비교한다.

```
# 발췌: 함수 direct() 와 via_ptr() 의 본문 (deep 은 sum 과 같은 재귀 함수)
x := 7
p := *x                              # x 의 스택 주소
before := @unsafeCast(int, p)
d := deep(200000)                    # via_ptr 는 `f := deep` 후 `d := f(200000)`
after := @unsafeCast(int, p)
now := @unsafeCast(int, *x)          # x 의 현재 주소
print('... stored==current? %{after == now}  (moved during call? %{before != now})')
```
```
direct   : stored==current? true  (moved during call? true)  d=200000
call_ptr : stored==current? false  (moved during call? true)  d=200000
```

(각 줄은 별도 프로세스에서 하나씩 실행한 결과이다. 한 프로세스에서 이어 부르면 첫 호출이 스택을 이미 키워서 두 번째는 이동이 일어나지 않는다.) 직접 호출은 스택이 이동했는데도 포인터가 새 주소로 고쳐졌고, `call_ptr` 은 고쳐지지 않았다.

(6c) 한 번의 앞 점프가 32767 단위를 넘으면 크래시한다. else 쪽 본문이 `y += 1` 문 N 개인 if/else 를 생성했다.

```
n=8000: 0:95 .jump: jmp @32097   ->  100          (정상)
n=8200: 0:95 .jump: jmp @32897   ->  Illegal instruction ... panic: integer does not fit in destination type
n=17000 (offset > 65535): 컴파일 단계에서 같은 패닉
```

(6d) 제너레이터 본문 안에서 패닉하면 언와인드가 죽는다(genpanic.cy).

```
#[generator]
fn gen() -> int:
    yield 1
    panic('inside generator')
g := gen()
total := 0
while g.next() |v|:
    total += v
```
```
thread 55168648 panic: incorrect alignment
Cannot print stack trace: stack tracing is disabled
```

`panic('inside generator')` 의 정상 출력(스택 트레이스)이 나오지 않고 Zig 안전 검사가 호스트 프로세스를 중단시킨다. 트레이스 빌드의 `-v` 로 보면 `unwind on frame ... fp=10, type=.gen` 직후에 죽는다.

### 실습 7 (읽기 전용). fuel 이 무한 루프를 끊는 방법

CLI 로는 실행할 수 없으므로 `src/lib.zig:915` 의 테스트를 읽는다. 질문: (1) `vm_set_fuel(vm, 10000)` 후 `while true: i += 1` 은 어디서 멈추는가(`JUMP` 의 역방향 체크포인트). (2) `fn f(n): return f(n+1)` 은(`CALL`). (3) 멈춘 뒤 같은 VM 이 계속 쓰이는 근거는(같은 테스트 안에서 `0..100` 루프가 정상 완료되고, 누수 검사 allocator 로 통과했으므로 패닉 경로가 힙을 비웠다는 뜻이다).

### 변형 과제

1. `sum` 을 반복문으로 바꾸고 `-stats` 로 `call`/`chk_stk` 수가 어떻게 달라지는지 비교한다. 실습 2 의 함수가 `-> str`(`ret=3`)을 돌려주게 바꿔 간격이 달라지는지도 본다.
2. `src/test` 아래의 `*_panic.cy` 중 하나를 `-v` 로 돌려 `unwind on frame` 로그와 실제 출력 프레임을 대응시킨다.
3. (자기 브랜치에서) `vm.c:1718` 의 `(1<<63)` 을 `((u64)1 << 63)` 으로 고치고 실습 6a 가 통과하는지 확인한다. 이 챕터는 소스를 수정하지 않았다.
4. 실습 6c 의 스크립트 생성기(perl 한 줄)로 임계 N 을 직접 찾고 `JUMP` 의 `int16_t` 해석(vm.c:868)과 맞는지 확인한다.

## 6. 0.3 -> 0.4 변경 관점 / 설계 철학 메모

### 6.1 0.3 과 0.4 의 VM 비교

0.3 의 값은 `git show 0.3:src/vm.c`, `0.3:src/vm.h` 로 확인했다.

| 항목 | 0.3 (2023-12) | 0.4 (이 fork) |
|---|---|---|
| 명령어 단위 | `typedef uint8_t Inst` (vm.h:391), 레지스터 번호 8비트 | `uint16_t`, 레지스터 번호 16비트 (한 프레임에 큰 값 타입을 펼칠 수 있음) |
| 값 표현 | NaN boxing (`TAGGED_*` 마스크로 타입 판별) | 태그 없는 8바이트 슬롯, 정적 타입으로 해석 |
| 프레임 상수 | `CALL_ARG_START 5`, `CALLEE_START 4` | 4, 3. 반환 슬롯이 가변이라 `CHK_STK` 가 `stack -= ret_size` |
| 호스트 함수 | `Value fn(VM*, Value* args, u8 nargs)`, 반환은 `newStack[0] = res` 한 칸 | `uint8_t fn(ZThread*)`, 반환/인자는 스택 슬롯, 멀티 슬롯 가능 |
| 반환 | `Ret1`/`Ret0` 가 `retFlag` 를 보고 VM 루프 종료 여부 결정 | `RET*` 는 검사 없이 복원만. 재진입은 `END` 센티널로 |
| 예외 | `PushTry`/`Throw` opcode | 없음. 패닉(종료)과 `Result` 값 |
| 코루틴 | stackful fiber (`Coresume`/`Coyield`) | stackless 제너레이터 (RET_GEN 등, 07 챕터) |
| 스택 오버플로 | 호출 시 `stack + ret + numLocals >= end` 검사 후 `growStackAuto` | `CHK_STK` 가 callee 입구에서 검사, `growStackAuto`. 상한 없음은 동일 |
| opcode | 핸들러 112개 | 132개 (`CodeEND` 까지) |

0.3 도 스택 확장에 상한이 없었다는 점은 변하지 않은 성질이다(`git show 0.3:src/fiber.zig` 485행 `growStackAuto`: 50% 증가, 상한 검사 없음. vm.c 의 `RES_CODE_STACK_OVERFLOW` 가 호출 쪽 신호). 0.4 에서 새로 생긴 것은 interrupt/fuel(커밋 f21993e2) 정도이다.

### 6.2 다른 VM 과의 비교 (일반 지식)

이 절은 코드에서 확인한 사실이 아니라 일반 지식이다.

| VM | 명령어 모델 | 디스패치 | 값 표현 |
|---|---|---|---|
| Cyber 0.4 | 레지스터 3-주소, 누산기 없음, u16 가변 길이 | computed goto | 8바이트 슬롯, 정적 타입 |
| Lua 5.x | 레지스터, 32비트 고정 폭 명령어 | `switch`, 5.4 는 computed goto 옵션 | 태그 달린 값(TValue) |
| CPython | 스택 기반, 16비트 코드 단위(3.6+) | computed goto | 객체 포인터 |
| V8 Ignition | 레지스터 + 누산기(accumulator) | 핸들러 테이블(CodeStubAssembler 로 생성) | 태그 달린 포인터/Smi |

NaN boxing 이 필요 없어진 이유는 정적 타입이라서 값이 스스로를 설명할 필요가 없기 때문이다. 대신 힙 객체의 정리나 스택 포인터 갱신처럼 "이 슬롯이 포인터인가"를 알아야 하는 일에는 컴파일러가 만든 별도 표(`ptr_layouts`, 타입 ID)가 필요하고, 그 표가 불완전하면 7절의 이슈 3 같은 문제가 생긴다.

### 6.3 죽은 코드 목록 (모두 `rg` 로 확인)

살아 있는 것과 죽은 것을 구분하는 것이 유지보수의 첫걸음이다.

- vm.c: `ENTER_JIT`(976)와 `i2c`(1780)와 `JitEntry`(vm.h:919): JIT 경로는 동작하지 않음(`project_direction.md`). `SAVE_STATE/RESTORE_STATE`(339~349): 정의만 있음. `switch` 대체 경로(595~603): 컴파일 불가. `JUMP_T`(859): opcode 는 있으나 bc_gen 이 내지 않음. 주석 처리된 옛 opcode `SetIndexList` ... `SliceList`(715~850, vm.h:172~183).
- 엔진: `-Dvm=zig` 는 `exec_auto` 가 `error.Unsupported` 를 돌려준다(thread.zig:472~473). `FRAME_VM/HOST/JIT`(vm.h:100~102)는 쓰이지 않는다(실제 프레임 종류는 Zig 의 `FrameType`).
- 옛 Fiber: `vm.h:840~873` 의 `Fiber`/`FiberObject` 는 `src/fiber.zig` 에서만 쓰이는데, 이 파일은 어디에서도 import 하지 않는다(`rg fiber.zig` 결과 없음. `docs/history/coroutines_concurrency.md:44`도 같은 사실을 적음). `cyber.zig:80` 의 `pub const Fiber = vmc.Fiber` 만 남은 연결이다. `vm.zig:643` 의 `getNewFramePtrOffset` 는 존재하지 않는 `cy.fiber` 를 참조하는 죽은 함수이다.
- Zig 쪽: `Thread.callUnion`(thread.zig:609)은 첫 줄에서 `error.TODO` 를 반환하고 호출처가 주석뿐이다. `markValue`(1213)는 자기 재귀뿐이다. 호출 규약이 바뀌기 전의 흔적들이다.
- vm.h 의 NaN-boxing 잔재 매크로: 아래 목록은 vm.h 밖(vm.c, `src/*.zig`)에서 한 번도 쓰지 않는다. `SIGN_BIT`, `TAGGED_VALUE_MASK`, `UPPER1_BIT`, `UPPER2_BIT`, `PTR_BIT`, `BOOLEAN_MASK`, `TAG_VOID/BOOLEAN/ERROR/SYMBOL`, `ERROR_MASK`, `SYMBOL_MASK`, `BEFORE_TAG_MASK`, `NULL_U8/U16/U32`, `TYPE_BITS`, `UNUSED_TYPE_BIT(2)`, `VALUE_INTERRUPT/RAW/PTR/BOX_PTR/ERROR`, `VALUE_AS_OBJHEADER/UINTEGER/U32/BOOLEAN/FLOAT_TO_INT(64)`, `VALUE_GET_TAG`, `VALUE_CALLINFO_RETFLAG`, `VALUE_IS_*`, `OBJHEADER_TYPEID`. `VALUE_IS_CLOSURE`(vm.h:132)는 더 이상 없는 `vm->c.typesPtr` 를 참조하므로 쓰면 컴파일되지 않는다. `value.zig:16~21` 은 `TAG_MASK`, `TAGGED_*`, `MIN_*`, `PTR_PAYLOAD_MASK` 를 상수로 가져오지만 `TagMask`(value.zig:286) 말고는 사용처가 없다.
- 살아 있는 것: `VALUE_FLOAT/F32/AS_FLOAT`(부동소수 연산), `VALUE_AS_INTEGER`, `VALUE_AS_HEAPOBJECT`(+`PTR_PAYLOAD_MASK` 48비트), `VALUE_GET_STRPTR/STRLEN`(`CMP_STR`), `OBJ_TYPEID`/`TYPE_MASK`, `VALUE_CALLINFO`/`VALUE_HOSTCALLINFO`, `GC_MARK_BIT`/`EXTERNAL_TYPE_BIT`(heap.zig:617~632), `TYPE_*` 상수, `ResultCode`, `PanicType`, `CALL_*` 상수.

### 6.4 설계 철학과 이 코드를 인수하는 사람에게

이 VM 은 "작고 빠르게 만들되, 느린 일은 Zig 로 내보낸다"는 원칙이 일관되다. `pc`/`stack` 두 변수, `RETURN(code)` 로 나가는 비용 없는 탈출, 문맥 저장은 루프 이탈 시에만, 호출은 프레임을 겹쳐 복사를 없앰, 호스트 호출과 패닉은 Zig 의 일반 코드. 이 원칙을 지키면 핫 루프에 새 기능을 넣을 때 비용 계산이 쉽다(`CHECKPOINT` 가 좋은 예이다. 비용이 어셈블리 몇 줄이라는 것을 확인할 수 있다).

다음에 건드릴 수 있는 곳을 우선순위 순으로 정리한다(모두 제안이다).

1. `FN_HOST` 를 `((u64)1 << 63)` 으로 고친다(이슈 1). 한 줄이며 호스트 함수를 값으로 넘기는 코드(콜백 인자, 함수 테이블)가 안전해진다. 같은 종류의 UB 가 더 없는지 `zig cc -Wall` 로 vm.c 를 검사한다(경고 목록은 이 챕터에서 `shift-count-overflow` 하나만 확인했다).
2. 스택 상한을 둔다. `growStackAuto`(thread.zig:857)에서 `stack_len + growSize` 가 상한을 넘으면 패닉("Stack overflow.")을 돌려주고, 설정은 `cl_vm_set_*` 류 API 로 열면 된다. 에이전트 루프에서 fuel 을 주지 않은 호스트도 메모리 폭주(실습 5)로부터 보호된다.
3. 스택 포인터 패치의 구멍을 막는다(이슈 3). `call_ptr`/`call_union`/`call_trait` 에도 `ptr_table` 항목을 내보내거나, 스택을 가상 메모리 예약으로 고정 주소에 두어 이동을 없앤다(후자는 2번의 상한과 함께 해결된다. 일반 지식 기반의 제안이며 검증하지 않음).
4. `unwindStack` 의 제너레이터 분기를 `frame.base` 기준으로 고친다(이슈 6). 현재 에이전트 코드가 제너레이터를 쓰고 패닉이 나면 호스트가 죽는다.
5. 점프 오프셋 범위를 검증하거나 넓힌다(이슈 4). 에이전트가 생성한 큰 스크립트에서 가장 먼저 만날 수 있는 한계이다.
6. 산술의 이식성(이슈 9)을 명시적으로 정한다. 시프트 횟수를 `& 63` 으로 마스킹하고 `IDIV/IMOD` 에서 `right == -1` 을 따로 처리하면 x86-64 와 arm64 가 같은 결과를 낸다.
7. 디버그 심볼 탐색을 이진 탐색으로(`debug.zig:110`의 TODO). 패닉 경로의 비용이라 급하지는 않다.

핵심 원칙은 이렇다. 새 기능이 "핫 루프에 들어가는가, 빠져나가서 Zig 가 처리하는가"를 먼저 정한다. 빠져나가는 쪽이 대부분의 경우 옳다.

## 7. 알려진 이슈, 문서와 코드의 차이, 미완 지점

각 항목은 재현 방법과 위치를 적었다. 모두 HEAD b40531a1 에서 확인했다.

1. `FN_HOST` 가 no-op 이다. 위치 vm.c:1716~1721 의 `addr | (1<<63)`. `1` 이 `int` 라서 63칸 시프트가 정의되지 않은 동작(UB)이고, 컴파일러가 대입을 통째로 지운다(컴파일 경고 `shift count >= width of type`, 어셈블리에서 핸들러가 `pc += 5` 만 함). 재현: 실습 6a. 영향: 호스트 함수를 값으로 변수/인자에 담아 부르면 목적지 레지스터가 갱신되지 않아 쓰레기 값으로 점프한다. 호출 쪽 `callPtrInst`(thread.zig:684)는 63번 비트로 호스트 여부를 판정하므로 수정은 한 줄이면 된다.
2. 안전 검사 빌드에서 `buf.mainStackSize` 가 쓰레기(0xAAAA)이다. 위치 bc_gen.zig:628~630 (`popProc` 뒤에 `getMaxUsedRegisters`). 재현: 트레이스 빌드 `-v` 마지막 줄 `main stack size: 43690`. 영향: main 스택이 의도와 무관하게 약 45506 슬롯으로 시작한다. ReleaseFast 의 동작은 미확인.
3. `call_ptr`/`call_union`/`call_trait` 호출 중 스택이 옮겨지면 호출자의 스택 포인터가 갱신되지 않는다. 위치 bc_gen.zig:3103 `pushCall`(직접 호출과 `call_host` 만 `ptr_table` 에 기록)과 thread.zig:891 의 소비 코드. 재현: 실습 6b (`stored==current? false`). 영향: 빌림/주소를 들고 클로저나 함수 값을 호출하는 코드에서 해제된 메모리를 쓰게 된다.
4. `JUMP` 의 오프셋이 `int16_t` 라서 32767 단위(약 64KB 바이트코드)를 넘는 앞 점프가 깨진다. 위치 vm.c:868, chunk.zig:472. 재현: 실습 6c (N=8200 에서 크래시, 17000 에서 컴파일 패닉). 오프셋이 u16 범위를 넘으면 `@intCast` 가 안전 검사 빌드에서 패닉한다. ReleaseFast 에서는 조용히 잘릴 것으로 추정한다(미확인).
5. `cyber compile` 덤프가 일부 명령어의 피연산자를 잘못 해석해서 출력한다. `call_trait`(bytecode.zig:466~471)는 vtable 번호를 `pc+3`(다음 명령어의 첫 단위)에서 읽는데 실제는 `pc[2]` 이다(실습 값 `[9]` 는 다음 명령어 `mov` 의 opcode 9). `trait`(604~612)는 `dst` 와 `src` 를 거꾸로(`src = pc[1]`, `dst = pc[6]`) 읽는다. `sext`/`zext`(758~769)는 `src` 를 `pc+3`(실제로는 비트 폭 `pc[3]`)에서, `bits` 를 `pc[5]`(명령어 밖)에서 읽는다(`sext(17, %32)` 에서 `%32` 가 실제로는 비트 폭). 디버깅할 때 덤프보다 vm.c 를 믿어야 한다.
6. 제너레이터 본문에서 패닉하면 언와인드가 죽는다. 위치 thread.zig:1006~1009 가 gen 프레임의 `callinfo`, 반환 주소, 제너레이터 포인터를 `fp+1`, `fp+2`, `fp+3` 에서 읽는데, 이것은 `ret_size == 1` 일 때만 맞다. `yield` 가 `?int`(2슬롯)이면 `gen` 함수의 `chk_stk ret=2` 라서 실제 위치는 `fp+2`, `fp+3`, `fp+4` 이고, 잘못된 위치를 포인터로 읽다가 `incorrect alignment` 로 중단된다(원인은 코드 읽기와 `ret=2` 덤프에서 추정. 수정은 `frame.base.?` 사용). 재현: 실습 6d. 제너레이터 자체의 결함은 07 챕터 참조.
7. `meta.stack_trace()` 가 가장 바깥 프레임 두 개를 지운다. 위치 meta.zig:194~195 (`pop()` 두 번, 의도는 가장 안쪽 두 개). 재현: 실습 3.
8. 스택에 상한이 없다. 위치 thread.zig:857 `growStackAuto`. 재현: 실습 5 (1초에 RSS 4.5GB). fuel 이 없으면 CLI 에서 폭주 재귀는 호스트 메모리를 소진한다. 할당 실패 시의 동작은 미확인.
9. 정수 연산 결과가 CPU 에 따라 달라질 수 있다(추정). `IDIV/IMOD` 는 `INT64_MIN / -1` 을 막지 않고(x86-64 에서는 SIGFPE), `LSL/LSR` 은 횟수 64 이상을 C 로 정의하지 않은 채 쓰며, `F2I` 는 범위 밖 값과 NaN 을 C 캐스트 그대로 쓴다. 실측은 모두 aarch64 한 곳이다. x86-64 로는 실행하지 못했다. 또 부호 있는 `>>` 가 논리 시프트(`-8 >> 1 = 9223372036854775804`)인 것은 의도인지 미확인이다.

문서와 코드의 차이:

- `docs/decisions/project_vm_interrupt.md` 와 `cyber.h` 는 "eval 마다 검사점을 n번 지나면 멈춘다"고 적지만 코드는 `--fuel < 0` 이므로 `n+1` 번째 검사점에서 멈춘다.
- 같은 문서의 "측정"(fib +0.9%, for +2.1%)은 이 챕터에서 재현하지 못했다.
- 짐작하기 쉽지만 코드와 다른 것: "패닉 시 `ptr_table` 로 힙을 정리"(2.8절), "`STATIC_ASSERT` 가 jumpTable 과 enum 의 순서를 검사"(2.4절), "진입 함수 `evalByteCode`"(2.1절).
- `docs/history/cyber_0_3_to_0_4_overview.md:135` 가 "문서에 있지만 소스에 없는 기능"으로 `type Fiber` 를 꼽는다. `vm.h:840` 이하의 `Fiber` 구조체도 같은 이유로 죽은 코드이다(6.3절).

미완 지점: 호스트 함수 안에서는 interrupt/fuel 이 듣지 않는다(결정 문서 "미정"). OOM 경로(`RES_UNKNOWN`)의 패닉 메시지 처리는 확인하지 못했다(`allocPanicMsg`, debug.zig:430 은 `.none` 타입에서 내부 패닉을 낸다. 어떤 실패가 이 경로에 닿는지는 미확인).

## 8. 이해도 확인 Q&A

### Q1. CALL 은 callee 의 CHK_STK 가 스택 검사를 하기 전에 `stack[0..2]` 에 callinfo, 반환 주소, 이전 fp 를 쓴다. 스택 경계 밖에 쓸 위험은 없는가?

A: 없다. 그 세 슬롯은 호출자 프레임 안의 슬롯이기 때문이다. 2.5절 그림에서 `F+7~F+9` 는 호출자가 callee 정보용으로 비워 둔 임시 레지스터(`%7~%10`)이고, 호출자의 `CHK_STK frame=13` 이 이미 `F+0~F+12` 의 여유를 확인했다. callee 의 CHK_STK 는 callee 쪽 나머지(`G+0~G+12`)를 검사한다. 함수가 "자기가 호출할 callee 의 헤더 자리(`reg_end += 4`와 인자)를 호출 지점마다 자기 프레임 안에서 잡는다"는 컴파일러 규약(bc_gen.zig:2179)이 이 안전을 보장한다.

### Q2. 반환값을 callee 의 `%0` 에 쓰면 호출자의 목적지 레지스터에 곧바로 들어간다. 이 설계의 이점과 위험은?

A: 이점은 반환값/인자 복사가 0 이라는 점이다(멀티 슬롯 값도 마찬가지). 위험은 callee 가 반환 슬롯을 인자 읽기보다 먼저 덮으면 안 된다는 것이다. `a = foo(&a)` 처럼 호출자가 자기 변수의 주소를 넘기면 반환 영역과 인자가 겹칠 수 있어서 CHK_STK 는 반환 메모리를 0 으로 초기화하지 않는다(vm.c:919 주석). 컴파일러가 반환값을 `%0` 에 쓰는 시점을 인자 사용이 끝난 뒤로 맞춰야 할 것이다(추정. 04 챕터에서 확인할 것).

### Q3. 호스트 함수가 낸 패닉의 트레이스에는 호스트 프레임이 없는데, `meta.stack_trace()` 에는 `<host>` 가 있다. 차이는 무엇인가?

A: 패닉은 `CALL_HOST` 의 `RETURN(RES_PANIC)` 가 `t->c.pc/fp` 를 VM 프레임(`CALL_HOST` 명령어)으로 되돌린 뒤에 `unwindStack` 가 시작되므로 가장 안쪽이 VM 프레임이다. `stack_trace` 는 호스트 함수가 실행 중인 시점의 `t->c`(`pc = NULL`)에서 직접 걷기 때문에 첫 프레임이 호스트 프레임이다. 크래시 핸들러(트레이스 빌드)도 `trace_pc = NULL` 을 써서 호스트 프레임부터 걷는다.

### Q4. `thread.zig:158` 의 `comptime` 검사가 통과하면 `ThreadC` 와 C 의 `Thread` 의 필드 순서가 맞다고 확신해도 되는가?

A: 아니다. 그 검사는 바깥 구조체 `Thread` 안에서 `c` 와 `heap` 의 오프셋만 비교한다. `ThreadC`(thread.zig:180)와 `Thread`(vm.h:771)의 필드별 오프셋은 `zig build test` 의 "thread internals." 테스트(thread.zig:166)가 비교하므로, `ThreadC` 에 필드를 추가하고 vm.h 를 고치지 않아도 일반 빌드는 컴파일된다. 필드를 바꿀 때는 두 곳을 같이 고치고 테스트를 돌려야 한다.

### Q5. `p := *x` 로 잡은 스택 포인터가 직접 호출에서는 스택 이동 후에도 맞는데 함수 포인터 호출에서는 틀어진다. 왜 그런가, 어떻게 고치겠는가?

A: 스택이 옮겨질 때 `growStackPrecise` 가 호출 지점의 pc 로 `ptr_table` 을 찾아 "어느 슬롯이 스택 포인터인가"를 알아내 새 주소로 고쳐 쓰는데, 컴파일러(`pushCall`)가 항목을 기록하는 곳이 직접 호출과 `call_host` 뿐이기 때문이다. `call_ptr`/`call_union`/`call_trait` 지점은 항목이 없어서 해당 프레임의 포인터가 옛 스택을 가리킨 채 남는다. 고치는 방법은 이 세 호출에도 `pushCall` 과 같은 기록을 추가하거나, 스택이 이동하지 않게 가상 메모리를 예약해 두는 것이다(후자는 일반 지식 기반 제안).

### Q6. fuel 이 100 이고 `while true: i += 1` 을 실행하면 `i` 는 몇이 되고, 같은 fuel 로 `fn f(n): return f(n + 1)` 은 몇 번째 호출에서 멈추는가?

A: 루프 한 바퀴가 역방향 `JUMP` 를 한 번 지나므로 `fuel = 100` 이면 100번의 바퀴가 통과하고 101번째 체크포인트에서 멈춘다. `i` 는 100 이 될 것이다(코드 읽기 결과이며 실행하지는 않았다). 재귀는 `CALL` 이 체크포인트이므로 호출 100번이 통과하고 101번째 `CALL` 에서 멈춘다. 이 챕터는 이를 실행으로 검증하지 못했다(CLI 에 fuel 설정이 없음).

### Q7. 깊이 20000 짜리 재귀와 100만 짜리 재귀 모두 성공했는데 "스택 오버플로" 오류는 언제 나는가?

A: 이 구현에서는 나지 않는다. `CHK_STK` 의 `RES_STACK_OVERFLOW` 는 오류가 아니라 "스택을 키우라"는 요청이고(2.3절), `growStackAuto` 에 상한이 없어서 할당이 실패할 때까지 자란다. 폭주 재귀는 호스트 메모리를 소진한다(실습 5: 1초에 4.5GB). 호스트가 막으려면 fuel 로 `CALL` 횟수를 제한해야 하고, fuel 을 주지 않은 CLI 에는 방어가 없다.

## 9. 더 알아보기

- 키워드: computed goto (labels as values), threaded code, register VM vs stack VM, frame pointer / base pointer, calling convention, stack unwinding, source map / debug symbol table, FFI struct layout (`extern struct`, `@offsetOf`), cooperative cancellation / fuel metering.
- 같은 저장소의 문서: `docs/decisions/project_vm_interrupt.md`(검사점 설계와 측정), `docs/decisions/project_bc_inline.md`(호출 비용이 가볍다는 전제와 인라인), `docs/history/coroutines_concurrency.md`(fiber 제거 경위), `docs/history/error_handling.md`(0.3 의 try/catch 에서 패닉/Result 로).
- 관련 챕터: 바이트코드가 어떻게 만들어지는가 -> [04-bytecode-gen.md](04-bytecode-gen.md). 힙 객체, retain/release, 패닉 시 힙 정리 -> [06-memory-ownership.md](06-memory-ownership.md). 제너레이터 명령어(`RET_GEN`, `RET_Y`, `GEN_NEXT`)와 gen 프레임 -> [07-coroutines-concurrency.md](07-coroutines-concurrency.md). `#[bind]` 연결, 임베딩 API, `cl_vm_set_fuel` 사용법 -> [08-embedding-builtins-tests.md](08-embedding-builtins-tests.md).
- 다음 날: [06-memory-ownership.md](06-memory-ownership.md). 오늘 본 `Retain`/`Release` 명령어와 `NEW`, `freeHeapPages` 가 가리키는 힙/ARC/소유권이 주제이다.

