---
aliases: [바이트코드 생성, bc_gen, 레지스터 VM 입문]
tags:
  - study
  - cyber
  - bytecode
  - register-vm
  - codegen
---

# Day 4. IR 에서 바이트코드로: 레지스터 할당, 호출 규약, 인라인

> 대상 소스: `src/bc_gen.zig`(3.4K줄), `src/bytecode.zig`(OpCode, 덤프), `src/chunk.zig`(명령어 푸시, 점프 패치), `src/vm.h` · `src/vm.c`(명령어 의미 대조), `src/debug.zig` · `src/thread.zig`(부가 테이블을 쓰는 쪽)
> 줄 번호는 HEAD b40531a1 기준이다. 코드와 실제 출력은 이 시점에 직접 확인한 것만 적었다.
> 예상 학습 시간: 5시간 (읽기 1.5 / 소스 탐독 1.5 / 실습 2)
> 선행: [Day 3. 의미 분석과 IR](03-sema-and-ir.md)
> 후속: [Day 5. VM 실행 루프](05-vm-runtime.md)가 이 장에서 만든 명령어를 실제로 실행한다. 두 장은 같은 프레임 그림을 쓴다.

## 한줄 요약

IR(트리)을 함수 하나당 선형 명령어 배열로 펴면서, 모든 지역 변수와 임시 값에 fp 기준 슬롯 번호(`%N`)를 배정하고(레지스터 할당), 호출자가 깔아 둔 인자 슬롯 위에 피호출자 프레임이 겹치는 호출 규약에 맞춰 `call` / `ret` 을 내보내는 단계다.

## 오늘의 학습 목표

- [ ] 스택 머신, 누산기 머신, 레지스터 머신의 차이를 설명하고 `cyber compile` 출력 한 줄(`0:81 .imul: %6 = %2 * %3`)을 해독한다.
- [ ] `genAll` 에서 `genStmt` / `genExpr` 까지의 생성 흐름과, main 블록과 함수 본문이 바이트코드 버퍼에 놓이는 방식을 설명한다.
- [ ] `reg_end`, `reserve_reg`, `pop_regs`, `Cstr`, `GenValue` 로 임시 레지스터가 스택처럼 할당되고 반납되는 과정을 손으로 추적한다.
- [ ] 호출 프레임 그림(반환 슬롯, callinfo, 반환 pc, 이전 fp, callee, 인자)을 그리고 `chk_stk` 가 하는 일을 설명한다.
- [ ] OpCode 132개를 기능별로 분류하고, 명령어 길이와 피연산자 폭(u16/u32/u48/u64), 점프 오프셋 패치를 설명한다.
- [ ] 이 fork 가 추가한 최적화(상수 접기, `add_i16`, `add_mul_i16`, 작은 함수 인라인)와 스택 트레이스 보존 장치(`inline_sites`)를 설명한다.
- [ ] 10개 이상의 `.cy` 조각을 바이트코드로 덤프하고 줄 단위로 해독한다.

## 1. 왜 이것이 필요한가?

### 1.1 IR 과 VM 사이의 간극

03 장의 IR 은 트리 모양이다. `add(imul(a, b), c)` 처럼 식이 중첩되고, `if_block` 이나 `loop_block` 이 문장 목록을 품는다. VM 은 정반대다. 평평한 `u16` 배열을 pc 로 걷고, 값은 스택 슬롯 배열(`Value`, 슬롯당 8바이트)에 있다. 변환기(`bc_gen.zig`)가 메워야 하는 간극은 다섯 가지다.

| 결정할 것 | 이 장의 답 |
|---|---|
| 각 값이 어느 슬롯에 사는가 | 레지스터 할당. 지역 변수는 선언 순서대로, 임시는 스택처럼 (2.5절) |
| 식 트리를 어떤 순서로 펴는가 | `genExpr` 재귀. 목적지(`Cstr`)를 아래로 내려보내고 결과 위치(`GenValue`)를 위로 받는다 |
| 중첩 제어 흐름을 어떻게 점프로 바꾸는가 | 빈 `jump` 를 먼저 내고 블록이 끝날 때 오프셋을 패치 (2.8절) |
| 인자와 반환값을 어디에 두는가 | 호출 규약. 호출자의 임시 영역이 곧 피호출자의 프레임 앞부분 (2.7절) |
| 패닉 때 어떤 소스 줄을 보여 주는가 | 부가 테이블: debugTable, func_table, ptr_table, inline_sites (2.9절) |

이 변환이 없다면 VM 이 트리를 직접 순회하는 AST 인터프리터가 되어야 한다. 바이트코드 VM 은 분기 예측이 잘 되는 평평한 루프 하나(`vm.c` 의 computed goto 디스패치)로 모든 일을 하므로 빠르다. 그 대가로 "컴파일러가 레지스터와 점프를 직접 계산한다"는 숙제가 생기고, 이 장이 그 숙제를 다룬다.

### 1.2 레지스터 VM 입문

아래 비교는 일반 지식이다. 연산 이름은 설명용 의사 표기이며 VM 마다 다르다.

```
식 a * b + c  (a, b, c 는 지역 변수)

스택 머신 (CPython 류)    누산기 머신 (V8 Ignition 류)   순수 레지스터 머신 (Lua, Cyber)
  LOAD a                    Ldar a   ; acc = a              MUL t, a, b    ; t = a * b
  LOAD b                    Mul  b   ; acc = acc * b        ADD t, t, c    ; t = t + c
  MUL                       Add  c   ; acc = acc + c
  LOAD c
  ADD
  (디스패치 5번)            (디스패치 3번)                  (디스패치 2번)
```

- 스택 머신은 명령어가 작고 컴파일러가 단순하다(피연산자 위치를 따질 필요가 없다). 대신 값을 스택에 올리고 내리는 명령어가 많아 디스패치 횟수가 늘어난다.
- 누산기 머신은 가장 자주 쓰는 피연산자 하나를 암묵 레지스터(누산기)에 둔다. 명령어가 짧아지고 디스패치도 줄지만, 두 번째 값은 별도 레지스터에 있어야 한다.
- 순수 레지스터 머신은 모든 피연산자를 명령어가 직접 이름 붙인다. 디스패치가 가장 적고, 대신 명령어 하나가 커지며(피연산자가 3개), 컴파일러가 레지스터를 배정해야 한다.

Cyber 는 순수 레지스터 머신이다. 다만 Lua 와 다른 점이 있다. Lua 값은 태그를 달고 다니지만 Cyber 는 정적 타입 언어라서 슬롯은 태그 없는 8바이트이고, 타입은 명령어가 정한다(`add`, `fadd`, `fadd32`, `cmp_str`). 0.3 의 NaN-boxing 동적 값(`git show 0.3:src/vm.h` 의 `TAGGED_VALUE_MASK`)과 가장 크게 달라진 점이다.

같은 식을 Cyber 가 실제로 내보낸 결과는 5.1절에서 보게 된다(`imul %6 = %2 * %3` 다음 `add %5 = %6 + %4`, 정확히 두 명령어다).

### 1.3 바이트코드 한 줄 읽기

`cyber compile x.cy` 의 한 줄은 이렇게 해독한다.

```
0:81 .imul: %6 = %2 * %3
│ │    │      └ 피연산자: 슬롯 %6 ← 슬롯 %2 곱하기 슬롯 %3
│ │    └ OpCode 이름
│ └ pc: 이 청크의 명령어 버퍼 안 오프셋 (u16 단위, 바이트 아님)
└ 청크 번호 (0 은 사용자 파일, 1 은 core.cy)
```

- `%N` 은 현재 함수 프레임의 fp 로부터 N번째 슬롯이다. 지역 변수도, 인자도, 임시도, 반환 슬롯도 모두 슬롯이다.
- 출력은 `src/debug.zig:692` 의 `dumpBytecode` 가 `bytecode.write_inst`(`src/bytecode.zig:290`) 로 한 명령어씩 찍은 것이다.
- 3.3절에서 보겠지만 이 덤프는 일부 명령어의 피연산자를 잘못 해독해서 찍는다. 의심스러우면 `vm.c` 의 `CASE` 가 정답이다.

## 2. 근본적인 동작 원리

### 2.1 파이프라인에서의 위치

```
sema (03장)                 bc_gen.zig (이 장)                              vm.c (05장)
Chunk.ir.func_blocks ──▶ genAll ──▶ genChunk ──▶ genFuncBlock / mainBlock ──▶ ByteCodeBuffer.ops
 [FuncBlock, FuncBlock,     │                      └ genStmts ─▶ genStmt        (u16 배열, 청크마다 하나)
  MainBlock, ...]           │                          └ genExpr (재귀)         + 부가 테이블
                            ├─ 준비: 전역 변수 슬롯, 함수 id, vtable
                            └─ 마무리: call/fn_vm 대상 주소 재배치(relocation)
```

입력은 `Chunk.ir.func_blocks` 다. 03 장에서 sema 가 청크마다 `FuncBlock` 과 `MainBlock` 을 쌓아 둔다(`src/sema.zig:4547` `pushFuncProc`, `:4555` `sema_program`). 출력은 `Chunk.buf`(`src/chunk.zig:163`, `ByteCodeBuffer`)이고, 청크마다 자기 명령어 배열을 갖는다. 함수 사이의 `call` 은 다른 청크의 버퍼를 가리킬 수 있으므로 절대 주소를 쓰고, 그래서 재배치 단계가 필요하다(2.8절).

### 2.2 `genAll` 의 여섯 단계

`bc_gen.genAll`(`src/bc_gen.zig:36`)이 컴파일러에서 호출되는 유일한 진입점이다.

| 단계 | 줄 | 하는 일 |
|---|---|---|
| 1. 타입 점검 | 38-82 | 새 타입의 kind 를 훑는다. 실제 일은 없고 `bare` 타입이면 오류로 막는 검사뿐이다 |
| 2. intrinsic 등록 | 85-91 | `str` 의 소멸자, 비교, 복사 함수에 `gen_intrinsic` 표식을 단다. 이 함수들의 호출은 `call` 대신 `dtor_str` / `cmp_str` / `copy_str` 한 명령어가 된다 |
| 3. 청크 준비 | 93-105 | 청크마다 명령어 버퍼를 2048 유닛(4096/2) 미리 확보하고, `prepareSym`(전역 변수 슬롯), `prepareFunc`(함수 id 발급, 호스트 함수 등록) |
| 4. vtable 할당 | 107-126 | trait 을 구현한 struct 마다 vtable 배열을 만든다(채우기는 6단계) |
| 5. 본문 생성 | 128-136 | `genChunk` 를 청크마다 호출 |
| 6. 재배치 | 138-179 | `call` / `fn_vm` / 전역 주소 자리를 실제 주소로 덮어쓰고 vtable 을 채운다 |

뒤에 JIT 단계(181-198)와 Trace 빌드용 런타임 타입 정보(200-217)가 이어진다. JIT 는 `docs/decisions/project_direction.md` 의 결정대로 동작하지 않는 죽은 경로라서 이 장에서 다루지 않는다.

`genChunk`(`:362`)는 `genChunkInner` 를 감싸 모든 Zig 오류를 `CompileError` 로 바꿔 소스 위치와 함께 보고한다. `genChunkInner`(`:438`)가 하는 일은 단순하다. `func_blocks` 를 순서대로 돌며 `funcBlock` 이면 `genFuncBlock`, 아니면 `mainBlock` 을 호출하고, 다 끝난 뒤 함수들의 최종 pc 를 확정한다("Get stable func pcs after final buffer size", `:451-468`). 버퍼가 커지며 재할당되면 주소가 변하므로 끝난 뒤에야 `static_pc`(절대 주소)를 구한다.

### 2.3 청크, 함수, main 이 버퍼에 놓이는 모양

함수 하나의 생성은 `genFuncBlock`(`src/bc_gen.zig:634`)이 한다. 핵심만 줄이면 이렇다.

```zig
// src/bc_gen.zig:642-646, 675-688 (중간 생략)
const header_pc = c.buf.ops.items.len;
try c.buf.pushOpSlice(.nop32, &.{0, 0});          // (1) 함수 id 를 담을 헤더
const pc = c.buf.ops.items.len;
try c.buf.markers.put(c.alloc, @intCast(pc), func);
...
const chk_stk_pc = c.buf.ops.items.len;
try c.buf.func_table.append(c.alloc, chk_stk_pc);
try c.pushFCode(.chk_stk, &.{ 0, 0 }, node);      // (2) 인자는 나중에 채운다
try genStmts(c, stmt.bodyHead);                   // (3) 본문
c.buf.ops.items[chk_stk_pc + 1].val = c.cur_proc.ret_size;
const stack_size = c.getMaxUsedRegisters();
c.buf.ops.items[chk_stk_pc + 2].val = stack_size; // (4) 본문을 다 만든 뒤 패치
```

- `nop32` 헤더는 함수 id(u32)를 함수 진입 주소 바로 앞에 심는다. 덤프가 `call` 대상 이름을 찾을 때 `func_pc - 4` 바이트를 읽는다(`src/bytecode.zig:406`).
- `chk_stk` 의 두 피연산자는 반환 슬롯 수(`ret_size`)와 프레임 크기(`max_regs`)다. 프레임 크기는 본문을 다 만들어야 알 수 있으므로 자리만 잡고 나중에 채운다. 이 값은 실행 때 스택 검사(`vm.c:913`)와 스택 트레이스의 프레임 복원(`debug.get_pc_func_metadata`, `src/debug.zig:46`)에 쓰인다.
- `markers` 는 pc 에서 `*Func` 로의 맵이고 덤프의 `--N fn ...` 줄을 찍는 데만 쓴다. `func_table` 은 chk_stk 의 pc 목록이다.

main 블록은 다르다(`src/bc_gen.zig:612-632`).

```zig
fn mainBlock(c: *Chunk, stmt: *ir.MainBlock, node: *ast.Node) !void {
    try pushProc(c, .main, c.id, null, "main", node);
    try reserveMainRegs(c);
    const main_pc = c.buf.ops.items.len;
    var child_opt = stmt.bodyHead;
    while (child_opt) |child| {
        try genStmt(c, child);
        child_opt = child.next;
    }
    try mainEnd(c, node);        // `end` 명령어
    try popProc(c);
    c.buf.mainStackSize = c.getMaxUsedRegisters();
    c.buf.main_pc = @intCast(main_pc);
}
```

main 에는 `nop32` 헤더도 `chk_stk` 도 없다. 프레임은 VM 이 스택 맨 아래(`fp = stack_ptr`)에 직접 만들고(`src/vm.zig:586-587`), `reserveMainRegs`(`:2369`)가 슬롯 %0 한 개를 예약하므로 main 의 지역 변수는 %1 부터 시작한다. 실행은 `main_pc` 에서 시작해 `end` 에서 끝난다.

`cyber compile` 출력은 이 배치를 그대로 보여 준다. 5.1절 프로그램의 출력에서 구조만 남기면 다음과 같다(`...` 는 생략).

```
--chunk0 .../e1_arith.cy:
0:0 .nop32:                      ← 다음 함수의 헤더
--2 `fn @program_init`           ← 컴파일러가 만든 숨은 함수. 번호는 함수 id
0:3 .chk_stk: ret=0, frame=14
...
0:59 .ret_0:
0:60 .nop32:
--3 `fn @program_deinit`
...
--start                          ← main_pc. 헤더도 chk_stk 도 없다
0:67 .call: core.@init(%5..%5) 147
...
0:133 .end:
0:134 .nop32:
--0 `fn calc`                    ← 사용자 함수. 제네릭 인스턴스(print[int] 등)는 그 뒤에 온다
0:137 .chk_stk: ret=1, frame=10
```

- `--start` 는 `main_pc`, `--N` 은 `markers` 에 등록된 함수 진입(chk_stk)의 위치이고 N 은 `vm.funcSyms` 의 id 다(`src/debug.zig:721-732`). 숨은 함수 `@program_init` / `@program_deinit` 은 `src/compiler.zig:731` / `:838` 이 만들며, 정적 초기화가 있는 청크의 `@init` / `@deinit` 을 호출하는 본문이다.
- main 의 IR 첫 문장은 `@program_init` 호출이고(`src/sema.zig:4566`), 끝에 `@program_deinit` 호출이 붙는다(`:4619-4624`). 그런데 main 의 첫 줄이 `call core.@init` 인 것은 `@program_init` 의 본문이 main 에 인라인되었기 때문이다. 그리고 독립 함수로 생성된 `@program_init`(위 출력의 `--2`)은 반대로 `@init` 본문을 품고 있다. 인라인은 한 단계만 하기 때문이다(2.10절).

### 2.4 Proc, Block, 그리고 두 개의 디스패치

생성기는 두 겹의 상태를 관리한다(`src/bc_gen.zig:2910-2975`).

- `Proc`(함수 하나의 생성 상태): `reg_end`(현재 레지스터 끝), `max_regs`(프레임 크기), `ret_size`, `closure_local`(callee 슬롯 번호), `num_ptr_locals`.
- `Block`(중첩 블록): 블록 진입 시 `reg_start`, `local_start`(지역 변수 맵 길이)를 저장해 두었다가, `popBlock`(`:2888`)이 둘 다 되돌린다. 블록을 나가면 그 안에서 선언한 지역 변수의 레지스터가 자동으로 반납된다.

`pushProc` / `popProc`(`:2845`, `:2855`)는 함수 하나를 시작하고 끝낸다. `popProc` 은 `reg_end == 0` 과 `num_ptr_locals == 0` 을 `assert` 하므로 레지스터 반납이 새면 컴파일러가 바로 알려 준다.

문장은 `genStmt`(`:379`), 식은 `genExpr`(`:483`)가 `switch (code)` 로 `gen_*` 함수에 나눠 준다. 대표 대응은 다음과 같다.

| IR 코드 | 생성 함수 | 내보내는 명령어 |
|---|---|---|
| `const64` | `gen_const64` `:3061` | `const_16s`(0..32767) 아니면 `const_64` (`genConstInt` `:3074`) |
| `string` | `gen_string` `:1253` | `const_str` |
| `local` | `gen_local` `:2117` | 없음. 슬롯 번호만 돌려준다. 목적지를 강제하면 `mov*` |
| `add` / `sub imul div ...` | `gen_add` `:1964` / `genBinOp2` `:1993` | `add_i16`, `add_mul_i16`, `add` / `sub`, `imul`, `idiv`, ... |
| `cmp`, `binary_op` | `genCompare` `:1822`, `genBinOp` `:2003` | `lt le gt ge ult ...`(좁은 정수는 `sext`/`zext` 먼저), `cmp`, `feq`, `!=` 는 뒤에 `lnot` |
| `call` | `gen_call` `:1397` | `call`, `call_host`, 또는 인라인 본문 |
| `field`, `set_field`, `init`, `lift` | `:893`, `:1054`, `:1007`, `:913` | `addr` + `load_*` / `store_*`, `lift` 는 `new` + `store_*` |
| `lambda` | `gen_lambda` `:2796` | `fn_vm`, 캡처가 있으면 `closure` |
| `declare_local` | `gen_declare_local` `:2280` | 슬롯 예약 + 초기화 식 |
| `if_block`, `loop_block`, `forRangeStmt` | `:2604`, `:2489`, `:2501` | 조건 + `jump_f`, 본문, 위로 `jump` |
| `ret_expr` / `ret` | `:2350`, `:2312` | 값을 슬롯 %0 에 쓰고 `ret_0` / `ret` / `ret_n` |
| `release` | `gen_release` `:581` | `release` + 소멸자 `call` (`pushRelease` `:3040`) |
| `break_` / `continue_` | `:1034`, `:1039` | 빈 `jump` + `blockJumpStack` 기록 |

`genStmt` 와 `genExpr` 의 `else => error.TODO` 분기에 걸리는 IR 코드는 bc_gen 이 지원하지 않는 것이다. `elseBlocks`(`:2618`) 같은 함수는 지금 IR 에 대응하는 노드가 없는 옛 코드로 보인다(추정: 호출처가 없고, 인자 개수가 호출 가능한 모양이 아니라서 컴파일되지 않는 코드이며 Zig 가 호출되지 않는 함수를 분석하지 않아 통과된다. 2026-11-06 에 삭제, F-61). if / else 사슬은 sema 가 `if_block` 여러 개와 `break` 로 풀어 놓는다(2.8절).

### 2.5 레지스터 할당: 슬롯 번호를 누가, 언제 정하는가

Cyber 의 레지스터 할당은 별도의 최적화 패스가 아니다. 코드를 내보내는 재귀 함수가 `reg_end` 라는 정수 하나를 올리고 내리면서 즉석에서 정한다. 이 설계가 "임시 레지스터는 스택이다"라는 한 문장으로 요약된다.

함수 프레임의 슬롯 지도는 `reserveFuncSlots`(`src/bc_gen.zig:2173`)의 주석에 있다.

```
[ret 1+] [ret_info 1] [ret_pc 1] [ret_fp 1] [callee 1] [params...] [locals...] [temps...]
 %0..                                                    %(ret_size+4)..
```

함수에 들어가면 `reg_end` 는 반환 슬롯(`ret_size`개) + 4 에서 시작하고, 인자들이 `reserve_local` 로 차례로 슬롯을 받는다. 그 뒤 선언되는 지역 변수와 식의 임시가 이어서 쌓인다.

세 함수가 전부다.

```zig
// src/bc_gen.zig:2214-2227 (ptr 레이아웃 기록은 2.9절)
fn reserve_reg(c: *Chunk, local_t: *cy.Type) !Reg {
    const reg = c.cur_proc.reg_end;
    const reg_size = type_reg_size(local_t);
    try c.buf.ptr_layout_builder.resize(c.alloc, reg + reg_size);

    c.cur_proc.reg_end += @intCast(reg_size);
    if (c.cur_proc.reg_end > c.cur_proc.max_regs) {
        c.cur_proc.max_regs = c.cur_proc.reg_end;
    }

    if (local_t.is_stack_ptr()) {
        c.buf.ptr_layout_builder.items[reg] = true;
        c.cur_proc.num_ptr_locals += 1;
    } else { ... }
    return reg;
}
```

- `reserve_reg`: 다음 빈 슬롯 번호를 돌려주고 `reg_end` 를 타입 크기만큼 올린다. 가장 높이 올라간 값이 `max_regs` 가 되어 `chk_stk` 의 프레임 크기가 된다.
- `pop_regs(c, end)`(`:3384`): `reg_end` 를 `end` 로 되돌린다. 임시 반납이다.
- `reserve_local`(`:2200`): `reserve_reg` 를 부르고 결과 슬롯을 `Chunk.bc_local_map`(`src/chunk.zig:143`)에 추가한다.

지역 변수는 IR 의 local id 가 곧 `bc_local_map` 의 인덱스다. `toLocalReg(c, ir_id)`(`:2062`)가 `bc_local_map[inline_local_base + ir_id]` 를 읽는다(`inline_local_base` 는 인라인 때문에 있다, 2.10절). IR local id 는 `u8`(`src/ir.zig:452`, `Local.id`)이라서 한 함수에 지역 변수가 256개를 넘으면 컴파일러가 죽는다(7절). 블록이 끝나면 `gen_pop_locals`(`:2821`)와 `popBlock`(`:2888`)이 `bc_local_map` 길이와 `reg_end` 를 블록 진입 시점으로 되돌린다.

#### Cstr 과 GenValue: 목적지를 내려보내고 위치를 받는다

모든 `gen_*` 함수는 `(식, Cstr)` 를 받아 `GenValue` 를 돌려준다.

```zig
// src/bc_gen.zig:3287-3305 (주석 생략), 2985-2990
const CstrType = enum(u8) { simple, tempReg, localReg, captured, discard, none };
const GenValueType = enum { discard, constant, local, temp };
```

| Cstr | 뜻 | 쓰는 곳 |
|---|---|---|
| `simple` (`Cstr.localOrTemp()`) | 어디든 좋다. 이미 레지스터에 있으면 그 자리를 알려 달라 | 연산의 피연산자, 조건식 |
| `localReg(r)` | 반드시 슬롯 r 에 써라(지역 변수의 자리) | `x = expr`, 반환값 `Cstr.toLocal(0)` |
| `tempReg(r)` | 반드시 슬롯 r 에 써라(방금 예약한 임시) | 호출 인자 |
| `discard` | 값이 필요 없다 | 값을 버리는 문장(`gen_discard`) |
| `captured`, `none` | 클로저 변수 쓰기용, 미사용 | 아래 참고 |

`GenValue` 의 `local` 은 "이미 있던 변수 자리를 읽기 전용으로 빌려 줌", `temp` 는 "내가 새로 예약한 임시. 다 쓰면 호출자가 반납". `pop_temp_value`(`:3378`)는 `temp` 일 때만 `pop_regs` 를 한다. `local` 은 건드리면 안 되는 남의 슬롯이기 때문이다.

대표 패턴은 `genBinOp2`(`:1993`)가 보여 준다.

```zig
fn genBinOp2(c: *Chunk, expr: *ir.BinOp2, op: cy.OpCode, cstr: Cstr, node: *ast.Node) !GenValue {
    const dst = try bc.selectReg(c, expr.base.type, cstr, node);        // 1. 목적지를 먼저 정한다
    const leftv = try genExpr(c, expr.left, Cstr.localOrTemp());        // 2. 피연산자는 어디든 좋다
    const rightv = try genExpr(c, expr.right, Cstr.localOrTemp());
    try pushInlineBinExpr(c, op, dst, leftv.reg, rightv.reg, node);     // 3. 명령어 하나
    try pop_temp_value(c, rightv, node);                                // 4. 거꾸로 반납
    try pop_temp_value(c, leftv, node);
    return dst;
}
```

이 구조에 설계 의도가 세 가지 들어 있다.

1. 목적지 주도(destination-driven) 생성: `x = a + b` 는 `add %x = %a + %b` 한 줄이 된다. 중간 임시에 계산하고 `mov` 로 옮기지 않는다. 목적지(`localReg`)가 위에서 내려오기 때문이다.
2. 제로 카피 읽기: 피연산자가 지역 변수이면 `gen_local`(`:2117`)이 아무 명령어도 내지 않고 변수의 슬롯을 그대로 돌려준다(`Cstr.simple` 일 때). `imul %6 = %2 * %3` 처럼 피연산자 자리에 지역 변수 슬롯이 바로 들어간다.
3. 임시 레지스터의 LIFO: 목적지를 피연산자보다 먼저 예약하므로 결과가 가장 낮은 임시에 놓이고, 피연산자 임시는 그 위에 쌓였다가 거꾸로 팝된다. 식 하나를 끝내면 `reg_end` 가 결과 바로 위로 돌아온다.

5.1절의 `a * b + c - 3` 이 인라인된 본문을 따라가 보자. IR 은 `sub(add(imul(a, b), c), 3)` 이고 최종 목적지는 반환 슬롯 `%1`(지역 변수 `n`의 자리)이다. 인자 세 개가 임시 %2 %3 %4 에 놓여 `reg_end` 는 5 로 시작한다.

| 단계 | 일 | 내보낸 명령어 | `reg_end` |
|---|---|---|---|
| `sub` 의 목적지 | `localReg(%1)` 이므로 예약 없음 | | 5 |
| `sub.left` = `add` (simple) | `selectReg` 가 %5 예약 | | 6 |
| `add.left` = `imul` (simple) | `selectReg` 가 %6 예약 | | 7 |
| `imul` 의 a, b | 지역 변수 %2, %3 를 그대로 사용 | `imul %6 = %2 * %3` | 7 |
| `add` 의 c | 지역 변수 %4 | `add %5 = %6 + %4` | 7 |
| `add` 가 left 반납 | `pop_regs(%6)` | | 6 |
| `sub.right` = 상수 3 (simple) | %6 예약(방금 반납한 자리 재사용) | `const_16s %6 = 3` | 7 |
| `sub` 명령어 | | `sub %1 = %5 - %6` | 7 |
| right, left 반납 | `pop_regs(%6)`, `pop_regs(%5)` | | 5 |

실제 출력(5.1절)과 한 줄도 다르지 않다. `%6` 이 두 번 다른 용도로 쓰인 것에 주목하라. 이것이 스택 방식 할당이다.

참고로 `Cstr.captured` 는 `gen_set_captured`(`:2291`)만 쓰는데, `selectReg`(`:3251`)는 `captured` 를 `error.Unsupported` 로 거절한다. `selectForDstInst`(`:3223`)는 `captured` 를 처리하지만 호출처가 없다. 클로저 변수 쓰기는 `^T` 박스에 대한 `set_deref` 로 풀리므로 지금은 이 경로를 타지 않는다(추정. 호출처 부재는 `rg` 로 확인했다).

### 2.6 한 값이 여러 슬롯을 차지할 때

`type_reg_size(t) = (size + 7) >> 3`(`src/bc_gen.zig:2270`). 값은 항상 슬롯 단위로 정렬된다.

| 타입 | 크기 | 슬롯 | 구성 (core.cy 정의) |
|---|---|---|---|
| `int`, `float`, 포인터, `bool`, `i32` 등 | 8바이트 이하 | 1 | |
| `str` | 24 | 3 | `buf`, `ptr`, `header` (`core.cy:3237-3246`) |
| `Slice[T]` | 32 | 4 | `buf`, `ptr`, `_len`, `header` (`core.cy:1026-1038`) |
| `Array[T]` | 24 | 3 | `buf`, `length`, `header` (`core.cy:1662-1670`) |
| `?int` | 16 | 2 | 태그, 페이로드 (5.9절에서 확인) |
| `type Pt(x, y int)` | 16 | 2 | x, y |

슬롯 몇 개를 한 번에 옮기는 명령어가 따로 있다. `push_mov`(`:2454`)는 크기 1, 2, 3, 4 에 `mov`, `mov_2`, `mov_3`, `mov_4` 를, 그 이상은 `mov_n dst, src, n` 을 고른다. 메모리 쪽은 `push_load`(`:2086`)와 `push_store`(`:1078`)가 바이트 크기에 따라 `load_8/16/32/64`, `load_2w/3w/4w`, `load_n` 을 고른다(`store` 도 같다). `2w`, `3w`, `4w` 는 8바이트 워드 2, 3, 4개다.

레지스터 안의 struct 필드는 "슬롯 안의 필드"를 가리키는 명령어가 없다. 필드 읽기는 항상 `addr`(슬롯의 스택 주소를 얻는 명령어)로 구조체 시작 주소를 만든 뒤 `load_*` 의 오프셋으로 읽는다(`gen_field`, `:893`). 중첩 필드는 `fold_rec_offset`(`:869`)이 오프셋을 합쳐 `addr` 와 `load` 를 한 번씩만 내보낸다. 5.6절의 `p.x` 가 `addr` + `load_64` 두 줄로 나오는 이유다. `addr` 의 결과는 스택 안을 가리키는 포인터이므로 `ptr_layout` 기록 대상이 된다(2.9절).

8바이트보다 작은 정수(`i8`, `i16`, `i32`)도 슬롯 하나를 통째로 쓰고 상위 비트는 "정의되지 않음"이다. `gen_trunc`(`:1143`)는 아무 명령어도 내지 않는다. 그래서 비교처럼 폭이 중요한 소비 지점에서 `sext` / `zext` 를 레지스터 안에서 제자리로 실행한다(`genCompare` `:1853-1861`, `pushCmp` `:1789-1800`). 실제로 `fn lt32(a i32, b i32) -> bool: ... return a < b` 를 덤프하면 `sext %5, %5, 32`, `sext %6, %6, 32`, `lt %0 = %5 < %6` 세 줄이 나오고, `==` 는 `zext` 두 줄 + `cmp` 가 된다. `a + b` 는 폭 정리 없는 64비트 `add` 라서 `shorter(2147483647, 1)` 이 `-2147483648` 로 출력된다(출력 경로가 `sext(32)` 로 해석한다). 이때 덤프는 `sext(6, %32)` 로 찍는데 `%32` 가 실제로는 `bits` 값이다(3.3절).

슬롯 크기의 한계는 코드 곳곳에 흩어져 있다. 레지스터 번호는 `Reg = u16`(`:17`)이고 `chk_stk` 의 프레임 크기도 u16 이므로 슬롯 번호 자체의 상한은 65535 다. 그런데 `inline_max_reg_end` 의 주석(`:1463`)은 "Registers are u8 indexed by the VM"이라고 적고 있고, 이는 코드와 맞지 않는 옛 표현이다(7절). 실제로 부딪히는 한계는 지역 변수 256개(IR id u8), 호출 인자 수(`Call.numArgs: u8`), 캡처 수(`Captured.idx: u8`), 점프 오프셋(2.8절) 쪽이다.

### 2.7 호출 규약: 호출자의 임시 영역이 피호출자의 프레임이 된다

가장 중요한 그림이다. 05 장도 같은 그림을 쓴다. 호출 한 번은 세 주체가 나눠 한다. 호출자의 `bc_gen`(`beginCall` ~ `endCall`)이 슬롯을 배치하고, `call` 명령어(`vm.c:928`)가 callinfo 와 복귀 정보를 쓰고, 피호출자의 첫 명령어 `chk_stk`(`vm.c:913`)가 fp 를 반환 슬롯 쪽으로 당긴다.

```
 호출자 프레임 (fp = F, 반환 슬롯 수 r)          피호출자 프레임 (chk_stk 이후 fp' = F + b - r)

 F[b-r..b-1]  반환 슬롯 (beginCall 이 예약)  ═▶  fp'[0..r-1]   반환 슬롯 (callee 의 %0 ...)
 F[b+0]       callinfo       (call 이 씀)   ═▶  fp'[r+0]
 F[b+1]       반환 pc        (call 이 씀)   ═▶  fp'[r+1]
 F[b+2]       호출자의 fp    (call 이 씀)   ═▶  fp'[r+2]
 F[b+3]       callee 슬롯 (클로저 값 등)     ═▶  fp'[r+3]
 F[b+4]       인자 0                         ═▶  fp'[r+4]      첫 매개변수
 F[b+5]       인자 1                         ═▶  fp'[r+5]
                                                  fp'[r+6..]   지역 변수와 임시
```

`b` 는 `call base, ...` 의 base 피연산자다. 숫자 하나로 확인하자. 5.4절의 `fib` 에는 `call: %8 = e4_rec.fib(%13..%14)` 가 있다. 반환 슬롯 `%8`, `b = 9`, 인자 `%13 = b + 4` 다. 피호출자의 fp' 는 호출자 F 에서 8 칸 위(`9 - 1`)이고, 그래서 피호출자의 `%5`(첫 매개변수 `n`)가 곧 호출자의 `%13` 이다. 5.5절의 `dump_frame` 이 이 그림을 실제 메모리로 보여 준다.

이 규약의 이득은 복사가 없다는 점이다(일반 지식으로 Lua 의 레지스터 윈도우와 같은 발상).

- 인자를 복사하지 않는다. 호출자는 인자를 처음부터 `F[b+4..]` 에 계산해 놓는다(`gen_call`, `src/bc_gen.zig:1425-1433`).
- 반환값을 복사하지 않는다. 피호출자는 값을 자기 `%0` 에 쓰고, 그 슬롯이 곧 호출자의 반환 임시다. `gen_ret_expr`(`:2350`)는 `Cstr.toLocal(0)` 으로 식을 평가한 뒤 `ret` / `ret_n` 만 낸다.

#### 호출자 쪽: `gen_call` 의 순서

`gen_call`(`:1397`)은 다음 순서로 진행한다.

1. `gen_intrinsic` 표식이 있는 함수(`str` 소멸자, 비교, 복사)면 호출 대신 한 명령어(`genCallIntrinsic`, `:1333`).
2. 인라인 조건을 만족하면 `gen_inline_call` 로 넘어간다(2.10절).
3. `beginCall`(`:2392`): 반환 슬롯과 호출 정보 슬롯 4개(callinfo, 반환 pc, 이전 fp, callee)를 예약하고 `base` 를 얻는다.
4. 인자마다 `reserve_reg` 후 `genExpr(arg, Cstr.toTemp(temp))`. 인자 슬롯이 연속인지 Trace 빌드에서는 검사한다(`:1428-1431`).
5. `pushCall`(`:3103`): 사용자 함수는 `call base, u48`, 호스트 함수와 extern 은 `call_host base, u48`. 대상 주소는 아직 모르므로 재배치 목록에 올린다.
6. `endCall`(`:2479`): 임시를 반납하고 결과 위치를 돌려준다.

`beginCall` 에는 영리한 최적화가 하나 있다.

```zig
// src/bc_gen.zig:2402-2422 (간추림)
// Optimization: Check to use dst cstr as ret.
if (cstr.type == .tempReg or cstr.type == .localReg) {
    if (cstr.data.slot.dst == c.cur_proc.reg_end - ret_reg_size) {
        if (cstr.data.slot.dst != 0) {
            ret = ...;                 // 목적지 슬롯을 그대로 반환 슬롯으로
            allocTempRet = false;
        }
    }
    if (allocTempRet) { has_final_dst = true; final_dst = GenValue.initTemp(cstr.data.slot.dst); }
}
```

목적지가 마침 "현재 레지스터 스택의 맨 위(`reg_end - ret_size`)"이면 그 슬롯을 그대로 반환 슬롯으로 쓴다. 지역 변수를 선언하는 `r := f(x)` 가 이 경우다. 변수 슬롯을 먼저 예약한 직후라 `reg_end` 바로 아래에 있기 때문이다. 이때는 `mov` 가 하나도 없다(5.4절 `call: %1 = ...` 에서 `%1` 이 변수 `x` 의 자리). 아니면 새 임시를 예약하고 `endCall` 이 `push_mov(final_dst, ret)` 를 내보낸다.

#### 피호출자 쪽: `chk_stk`, `ret`

```c
// src/vm.c:913-926 (CHK_STK)와 928-939 (CALL)를 간추림 (원문과 줄 구성이 다르다)
u16 ret_size = pc[1];  u16 frame_size = pc[2];
stack -= ret_size;                                   // fp 를 반환 슬롯 맨 앞으로
if (stack + frame_size >= t->c.stack_end) RETURN(RES_STACK_OVERFLOW);
...
stack += base;                                       // CALL: 새 프레임 기준점(callinfo 자리)
stack[0] = VALUE_CALLINFO(false, CALL_INST_LEN, 0);  // 호출 명령어 길이(5)를 callinfo 에 인코딩
stack[1] = (uintptr_t)(pc + CALL_INST_LEN);          // 반환 pc
stack[2] = ret_fp;                                   // 호출자 fp
pc = (Inst*)READ_U48(2);                             // 대상 주소로
```

- `call` 은 fp 를 `base` 로 옮기고 3개를 저장한 뒤 점프한다. 그 직후 `chk_stk` 가 fp 를 `ret_size` 만큼 도로 당겨 반환 슬롯이 프레임 맨 앞이 되게 한다. 그래서 피호출자 코드는 어디서나 반환값을 `%0`, 첫 매개변수를 `%(ret_size+4)` 로 쓴다.
- 스택이 모자라면 `chk_stk` 가 `RES_STACK_OVERFLOW` 로 빠져나가고, Zig 쪽(`thread.zig:487-490`)이 스택을 키운 뒤 같은 pc(chk_stk)에서 다시 실행한다. `chk_stk` 는 매 호출의 맨 앞에 정확히 한 번 있으므로 재실행해도 안전하다.
- callinfo 값은 `retFlag | (call_inst_off << 1) | (stack_size << 8)` 다(`vm.h:107`). `dump_frame` 에서 `info=10` 이 나왔는데 `5 << 1` 이다. 호출 명령어의 길이(5)를 저장해 두는 이유는 스택을 거슬러 올라갈 때 `반환 pc - 5` 로 "호출 명령어 자신의 pc"를 복원하기 위해서다(`FrameInfo.prev_context`, `src/thread.zig:1092-1099`). 이 pc 로 디버그 심볼과 ptr 레이아웃을 찾는다.
- `ret_0`, `ret`, `ret_n n` 은 반환값이 이미 `%0..` 에 있으므로 복귀 정보만 읽는다(`vm.c:1004-1022`). 반환 슬롯 수에 따라 읽는 위치가 다르다: `stack[ret_size+1]` 이 pc, `stack[ret_size+2]` 가 이전 fp.
- main 프레임에는 반환 슬롯이 없고 `end` 가 실행을 끝낸다(`vm.c:1767`).

#### 호출 명령어 다섯 가지

| 명령어 | 피연산자 | 대상이 정해지는 때 | 쓰임 |
|---|---|---|---|
| `call` | base, u48 주소 | 컴파일 때(재배치로 채움) | 사용자 함수 |
| `call_host` | base, u48 `HostFn` | 컴파일 때 | `#[bind]` 호스트 함수, extern |
| `call_ptr` | base | 실행 때. callee 슬롯(`base+3`)의 값이 주소이고 최상위 비트가 1이면 호스트 함수 | `fn` 포인터 값 호출 (`gen_call_ptr` `:1748`, `thread.zig:684`) |
| `call_union` | base | 실행 때. callee 슬롯이 힙의 `Func` 객체(클로저, 함수 값) | `Func[Fn]` 호출 (`gen_call_union` `:1721`) |
| `call_trait` | base, vtable_idx | 실행 때. callee 슬롯이 vtable id, 수신자는 인자 0 | `Dyn[Trait]` 메서드 (`gen_call_trait` `:1313`, `vm.zig:864`) |

`call_ptr` / `call_union` / `call_trait` 는 피호출자의 위치를 실행 중에 알아내야 하므로 Zig 헬퍼(`zCallPtr` 등)로 위임한다. `beginCall` 의 `hasCalleeValue=true` 는 "callee 슬롯을 따로 예약하지 말고 callee 값 자체를 그 자리에 계산해 넣겠다"는 뜻이다(`:2440-2443`).

### 2.8 명령어 인코딩, 점프 오프셋, 재배치

#### Inst 와 피연산자 폭

`Inst` 는 `packed struct { val: u16 }` 다(`src/bytecode.zig:823`). 첫 유닛의 하위 바이트가 opcode 이고(`opcode()`, `:838`, VM 은 `*(u8*)pc` 로 읽는다), 상위 바이트는 "목적지가 임시"라는 힌트 비트(`initOpCode2`, `0x100`)다. 이 힌트를 읽는 곳은 JIT 뿐이라 VM 에는 영향이 없다(`rg temp_dst` 확인).

피연산자는 u16 유닛이다. 레지스터 번호, 즉치 i16, 점프 오프셋이 한 유닛이고 더 큰 값은 리틀 엔디언으로 여러 유닛에 나눠 담는다. VM 의 읽기 매크로(`vm.c:417-419`)가 그대로 폭이다.

| 폭 | 유닛 수 | 매크로 | 쓰는 명령어 |
|---|---|---|---|
| u16 | 1 | `pc[k]` | 레지스터, 오프셋, 즉치 |
| u32 | 2 | `READ_U32(k)` | `const_32`, `nop32`(함수 id) |
| u48 | 3 | `READ_U48(k)` | `call`, `call_host`, `fn_vm`, `fn_host`, `closure` 의 함수 주소 |
| u64 | 4 | `READ_U64(k)` | `const_64`, `const_str`(포인터 48비트 + 길이 16비트), `nops` |

48비트 주소를 쓰는 이유는 x86-64 와 arm64 의 사용자 공간 포인터가 48비트에 들어가기 때문이다(일반 지식). `setOpArgU48`(`bytecode.zig:258`)의 주석이 흥미롭다. `*u48` 로 쓰면 저장 크기가 8바이트라서 6바이트 피연산자를 넘어 버퍼 끝의 할당자 메타데이터를 덮어쓰는 버그가 있었고, 그래서 `[6]u8` 에 `writeInt` 로 쓴다고 적혀 있다.

명령어 길이는 `getInstLenAt`(`:898`)이 표로 갖고 있다. VM 은 각 `CASE` 에 `pc += N` 으로 같은 숫자를 하드코딩하므로 두 곳이 어긋나면 안 된다. Trace 빌드는 푸시할 때마다 `args.len == 길이 - 1` 을 검사한다(`chunk.zig:726-731`).

#### 점프 오프셋과 패치

점프 오프셋은 점프 명령어 자신의 pc 로부터의 상대값(u16 유닛)이다. `jump` 는 부호 있는 i16(`vm.c:867`), `jump_t` 와 `jump_f` 는 부호 없는 u16 이라 앞으로만 간다(`vm.c:850`, `:856`: `pc += pc[2]`). `release` · `release_opt` 의 건너뛰기 오프셋도 i16 이다.

생성기는 목적지를 모를 때 오프셋 0 인 점프를 먼저 내고 pc 를 기억했다가, 목적지가 정해지면 `ops[pc+1].val = 현재pc - pc` 로 고친다.

```zig
// src/chunk.zig:459-481 (발췌)
pub fn pushEmptyJump(self: *Chunk, node: *ast.Node) !u32 {
    const start: u32 = @intCast(self.buf.ops.items.len);
    try self.pushFCode(.jump, &.{0}, node);
    return start;
}
pub fn patchJumpToCurPc(self: *Chunk, jumpPc: u32) void {
    self.buf.ops.items[jumpPc + 1].val = @intCast(self.buf.ops.items.len - jumpPc);
}
```

`break` 와 `continue` 는 어느 블록을 벗어나는지 정해야 하므로 한 단계 더 있다. IR 의 `break_` / `continue_` 는 `block_offset`(함수 시작부터 센 블록 깊이)을 갖고, 생성기는 빈 `jump` 를 내고 `Chunk.blockJumpStack` 에 `{jumpT: brk|cont, pc, block_offset}` 을 쌓는다(`gen_break` `:1034`, `chunk.zig:905`). 블록이 끝날 때 `patchBreaks`(`chunk.zig:499`) 또는 `patchForBlockJumps`(`:524`)가 스택에서 `block_offset` 이 자기 깊이와 같은 항목만 패치하고, 나머지는 앞으로 당겨 바깥 블록이 이어받게 한다. 패치할 때 목적지가 점프보다 앞이면 `-(jump.pc - target)` 을 i16 으로 비트캐스트해 음수 오프셋을 만든다.

sema 가 `if` / `while` 을 어떻게 IR 로 만드는지 알아야 이 패치가 이해된다.

```
if A: X                      block {                            loop_block {         // while c: body
else B: Y             =>       if_block(A) { X; break outer }     if_block(c) { body; continue }
else: Z                        if_block(B) { Y; break outer }   }                     // 조건이 거짓이면 if_block 을 빠져나와 루프도 끝
                               Z
                             }
```

(`src/sema.zig:1022-1040` `semaIfBlock`, `:1325-1365` `semaIfStmt`, `:615-637` `whileCondStmt`.) 마지막 갈래가 아닌 `if_block` 끝에는 `break outer` 가 붙고, `while` 본문 끝에는 `continue` 가 붙는다. 따라서 루프 맨 끝의 뒤로 가는 `jump` 는 사실 `continue` 다. 5.3절 `sum_to` 의 `jump: jmp @65674` 가 그것이고, 5.2절의 `sign` 에서 `ret` 바로 뒤에 나오는 `jump` 는 `return` 때문에 도달할 수 없는 `break outer` 다.

뒤로 가는 `jump`(오프셋 < 0)는 `CHECKPOINT()` 를 실행한다(`vm.c:867-873`). 인터럽트 플래그와 연료를 확인하는 자리라서 모든 반복문이 이곳을 지난다. 그래서 `pushJumpBackTo` / `pushEmptyJump` 는 실패 가능한 명령어로 취급되어 디버그 심볼이 붙는다(`chunk.zig:452-463` 주석). 05 장에서 이어진다.

오프셋 필드가 16비트이므로 본문 크기에 한계가 있다. `jump`(`break` · `continue` · 루프 끝 · if 갈래 끝)는 i16 이라 32767 유닛, 앞으로 가는 `jump_f` · `jump_t` 는 65535 유닛까지다. 2026-11-08 전에는 넘으면 `@intCast` 가 실패해 컴파일러가 죽었고, 32768~65535 유닛의 앞 `jump` 는 컴파일은 되지만 VM 이 음수로 읽어 세그폴트였다(7.2절). 지금은 패치 함수들이 `Chunk.checkJump` 로 거리를 재서 `Function body too large. A jump can span at most N bytecode slots.` 컴파일 오류를 낸다(`8560b025`, F-09). 오류 위치는 그 점프를 가진 문(루프 · `if` · `switch`)이다.

#### 재배치

`call` 대상의 주소는 호출을 만드는 시점에 모른다. 아직 생성되지 않은 함수일 수 있고(상호 재귀), 다른 청크의 버퍼일 수도 있다. 그래서 `pushCall` 이 `Relocation{ kind: .func, pc: start + 2, data: func }`(`:3415`)를 `Chunk.relocations` 에 올려 두고 u48 자리는 0 으로 둔다. 모든 청크의 생성이 끝나면 `genAll` 의 6단계가 `genSymMap` 의 `static_pc` 를 u48 로 덮어쓴다(`:139-155`). `fn_vm`, `closure` 의 함수 주소와 전역 변수 주소(`const_64`)도 같은 방식이다. 그래서 `static_pc` 확정 이후에는 어느 청크의 `ops` 배열도 재할당되면 안 된다. 같은 단계에서 trait vtable 에 함수 주소를 채우는데, 호스트 함수는 최상위 비트를 1로 세운다(`:167-171`). `call_ptr` 의 `host_func` 판별과 같은 약속이다.

런타임에 채우는 `rt_relocations` 는 extern(FFI) 함수용이다(08 장).

#### 상수와 문자열

- 정수와 실수 상수는 명령어 안의 즉치다(`const_16s`, `const_16`, `const_32`, `const_64`). 별도의 상수 풀 `ByteCodeBuffer.consts` 와 중복 제거 맵 `constMap`, `getOrPushConst`(`bytecode.zig:182`)가 정의되어 있지만 호출하는 곳이 없다(`genConstInt` 안의 호출은 주석 처리, `bc_gen.zig:3080`). 풀 방식에서 즉치 방식으로 옮겨 간 흔적으로 보인다(추정). 상수 풀과 `VM.consts_ptr`/`consts_len` 은 2026-11-06 에 삭제했다(F-61).
- 문자열 리터럴은 `getOrPushConstString`(`bytecode.zig:170`)이 `const_string_map`(내용 → ASCII 여부)으로 중복을 제거한다. 처음 보는 내용이면 0으로 끝나는 복사본을 할당해 맵의 키로 두고, ASCII 여부는 `cy.string.isAstring` 으로 계산한다. 같은 리터럴은 같은 포인터를 가리킨다.
- `pushConstString`(`bc_gen.zig:1270`)이 그 포인터(하위 48비트)와 길이(상위 16비트)를 u64 하나로 합쳐 `const_str` 의 피연산자에 쓰고, 마지막 유닛에 ASCII 비트를 둔다. VM 의 `CONST_STR`(`vm.c:624`)은 이것으로 `buf = NULL` 인 정적 `String` 을 만든다(`static_str`, `vm.c:265`). `buf` 가 없으므로 해제할 소유 버퍼가 없고, 길이의 최상위 비트가 ASCII 힌트다. 길이를 16비트에 담기 때문에 65536 바이트 이상의 리터럴은 잘렸는데, 2026-11-08 `10f8290b` 부터 `pushConstString` 이 `String literal too long.` 컴파일 오류를 낸다(7.2절, F-24). C 문자열 포인터 타입의 리터럴은 `const_64` 에 복사본의 주소를 담는다(`pushConstStrZPtr`, `:1265`).
- 디버그 라벨 `nops` 도 같은 맵을 쓴다(`genNopLabel2`, `:604`).

### 2.9 부가 테이블: 실행 중 pc 와 소스를 이어 주는 장치들

바이트코드만으로는 패닉 위치를 말할 수 없고, 스택이 움직이면 포인터가 깨진다. 이를 위해 `ByteCodeBuffer`(`src/bytecode.zig:32`)가 별도 테이블을 갖는다.

| 테이블 | 내용 | 채우는 곳 | 쓰는 곳 |
|---|---|---|---|
| `debugTable` | `DebugSym{pc, loc, frameLoc, file}` 16바이트 | `pushFailableDebugSym` (`chunk.zig:687`) | 패닉 시 pc → 소스 줄. `debug.zig:76-117` (선형 탐색) |
| `funcs_debug` | `FuncDebugInfo{func, name, src_chunk}` | `pushProc`, 인라인 | `frameLoc` 가 이 목록의 인덱스. 함수 이름과 소스 청크 |
| `func_table` | 각 함수 `chk_stk` 의 pc 목록 | `genFuncBlock` | pc 로 함수를 찾아 `ret_size` / `stack_size` 복원 (`debug.zig:46`, `thread.zig:1104`) |
| `Compiler.debug_tables` | `{chunk, ptr}` 를 ops 주소 순으로 정렬 | `genChunkInner` (`:470-480`) | pc 포인터가 어느 청크 소속인지 이분 탐색 (`debug.zig:96`) |
| `ptr_table`, `ptr_layouts` | 호출 지점 pc → 스택 포인터가 든 슬롯의 비트집합 | `push_site_ptr_layout`(`pushCall` · `call_ptr` · `call_union` · `call_trait` · `gen_next` · `gen_end`), `reserve_reg` | 스택이 커져 이동할 때 포인터 패치 (`thread.zig` `growStackPrecise` · `patch_frame_ptrs`) |
| `inline_sites` | 인라인 본문의 pc 구간 `[start, end)` 와 호출 지점 | `gen_inline_call` | 스택 트레이스에서 인라인 프레임 펼치기 (`debug.zig:592-636`) |
| `markers` | pc → `*Func` | `genFuncBlock` | 덤프의 `--N` 줄만 |
| `labels`, `consts` | | | 사실상 미사용 (7절) |

`debugTable` 에는 "실패할 수 있는" 명령어(`pushFCode*`: 호출, 나눗셈 같은 이항/단항 연산, 캐스트, unwrap, 뒤로 가는 점프 등)만 들어간다. `Trace` 빌드나 `gen_all_debug_syms` 설정이면 모든 명령어가 들어간다(`chunk.zig:681-685`). 패닉이 나면 `unwindStack`(`thread.zig:970`)이 프레임을 거슬러 올라가며 각 프레임의 pc 를 모으고, `allocStackTrace`(`debug.zig:592`)가 소스 줄로 바꾼다. 이 과정이 05 장의 패닉 절이다.

`ptr_table` 의 목적은 이름만 보면 "패닉 정리"로 오해하기 쉽지만 코드는 다르다. 스택 `Value[]` 는 하나의 연속 배열이고 `growStackAuto`(`thread.zig:857`)가 재할당(`realloc`)으로 키운다. 이때 슬롯 안에 든 "스택 안을 가리키는 주소"(`addr` 의 결과, `&x` 빌림)는 옛 배열을 가리키게 되므로, 호출 지점마다 "이 슬롯들이 스택 포인터다"라는 비트집합을 기록해 두었다가 이동 후 새 주소로 고친다. `reserve_reg` 가 `Type.is_stack_ptr()`(`types.zig:304`: 소유하지 않는 `pointer`, `borrow`)인 슬롯을 `ptr_layout_builder` 에 표시하고, `pushCall` 이 호출마다 현재 표시를 중복 제거(`ptr_layout_map`)해 `ptr_table` 에 올린다. 이 장치에는 빈 곳이 있는데 7절에서 재현과 함께 다룬다.

### 2.10 최적화: 상수 접기, 즉치 명령, 인라인

이 fork 의 사용자가 최근에 넣은 부분이다. 결정 기록은 `docs/decisions/project_array_index_calls.md`, `project_bc_inline.md`, `project_string_interpolation.md` 에 있고, 아래는 코드로 다시 확인한 내용이다.

1. 상수 접기(`src/sema.zig:8145` `fold_const_int`): 타입이 `int` / `r64` 이고 두 피연산자가 모두 `const64` 인 `+ - * && || ~ << >>` 와 단항 `~` 를 `const64` 하나로 바꾼다. 시프트 양이 64 이상이면 접지 않는다. 나눗셈과 나머지는 0 나누기를 런타임에 남기려고 접지 않는다. bc_gen 이 아니라 sema 가 접는다는 점에 주의. `2 + 3 * 4` 는 `const_16s %2 = 14` 한 줄이 된다(5.1절).
2. 즉치 명령: `genConstInt`(`:3074`)는 0..32767 을 `const_16s`(3유닛)로, 그 밖은 `const_64`(6유닛)로 낸다. 음수는 항상 `const_64` 라서 `-1` 이 6유닛짜리 `const_64` 가 된다(5.2절). `gen_add`(`:1964`)는 오른쪽이 i16 범위 상수이면 `add_i16`, 오른쪽이 `x * k`(0 < k <= 65535)이면 `add_mul_i16 dst, left, idx, k` 를 낸다. 뺄셈에는 즉치 형태가 없어서 `x - 1` 은 `const_16s` + `sub` 두 줄이다(5.4절 `fact`).
3. 배열 인덱스의 호출 줄이기: 결정 문서에 따르면 `arr[i]` 가 `Array.@index_addr` → `Int.uge` → `Ptr.+` 의 호출 3번이었다. `core.cy` 에서 `idx.uge(n)` 을 `(as[r64] idx) >= (as[r64] n)`(sema 가 `uge` 명령어로 내림)으로, `p + idx` 를 `*p[idx]`(`add_mul_i16`)로 바꿔 호출을 없앴다. 5.7절의 `at` 이 그 결과다.
4. 문자열 보간: `str.interpolate` 를 호스트 함수(`call_host`)로 만들어 조각 길이를 먼저 합산하고 한 번만 할당한다(5.10절의 `interpolate(...)` 호출).
5. 문자열 intrinsic 세 개: `dtor_str`, `cmp_str`, `copy_str`. 호출 대신 명령어 하나다. `copy_str` 은 이 fork 가 추가했다(`72f4ecef`).

#### 작은 함수 인라인

`gen_call` 은 `c.inline_ctx == null` 이고 `can_inline(callee)` 이고 `reg_end < 160` 이면 `call` 대신 callee 의 IR 본문을 호출자 proc 안에서 그대로 생성한다(`:1404-1409`, `gen_inline_call` `:1625`). 허용 조건은 `check_inline*`(`:1479-1597`)에 있다.

- 사용자 함수(`userFunc`), generator / jit / extern 아님, 매개변수 8개 이하, IR 노드 40개 이하(`:1461-1464`). 결과는 `FuncInfo.bc_inline`(`src/sym.zig:936`)에 캐시한다.
- 허용 문장: `declare_local`, `set_local`, `set_ret`, `set_global`, `set_field`, `set_deref`, `discard`, `ret`, `ret_expr`, `if_block`, `block`, `trap`, `nop_label`, `pop_locals`, `release`. 루프, `switch`, `try`, `yield`, `await` 는 거부한다. `break_` 도 목록에 없어서, `else` 가 있는 if 사슬(sema 가 `break outer` 를 심는다)은 인라인되지 않는다(5.2절의 `sign` 은 `call` 로 남고 `clamp` 는 인라인된다).
- 허용 식: 지역 변수, 상수, 이항 · 단항 연산(`div` 와 `mod` 포함), 비교, 필드, 캐스트, `init`, `string`, 전역 등과 함수 호출. `unwrap_nz` / `unwrap_addr` 는 목록에 없어 거부된다(5.9절의 `pick`).
- 1단계(d8ddbe44)는 "panic 할 수 없는 leaf 함수"만 허용했고, 2단계(b40531a1)가 panic 가능한 식과 일반 호출 허용으로 넓혔다. 대신 스택 트레이스를 디버그 정보로 지킨다.

`gen_inline_call` 의 절차는 이렇다.

1. 반환 레지스터: cstr 가 `localReg` / `tempReg` 이면 그 레지스터에 바로 쓰고(`ret_reg`), 아니면 임시를 예약한다.
2. 인자를 새 임시 레지스터에 평가한다. 호출과 같은 평가 순서이고, `x = f(x)` 가 옛 `x` 를 읽는 이유이기도 하다.
3. `inline_local_base = bc_local_map.len` 으로 잡고 callee 의 매개변수 local id 0..n-1 을 인자 임시에 묶는다. 이후 `toLocalReg`, `reserve_local`, `gen_pop_locals` 가 이 base 를 더해서 callee 의 지역 변수 번호가 호출자의 맵 뒤쪽에 이어 붙는다.
4. `funcs_debug` 에 callee 항목을 추가하고 `start_pc` 를 기록한다.
5. `inline_ctx` 를 켜고 본문을 생성한다. `ret_expr` 는 `ret_reg` 에 쓰고 `inline_ret_jump`(`:1599`)가 본문 끝으로 가는 `jump` 를 낸다(본문 최상위의 마지막 문장이면 생략). `trap` 과 `nop_label` 은 내지 않는다. 본문 안의 `call` 은 다시 인라인하지 않는다(`gen_call` 의 `inline_ctx == null` 검사). 그래서 인라인은 한 단계다.
6. 끝 점프를 패치하고, `bc_local_map` 길이를 되돌리고, `InlineSite{start, end, call_loc, caller_frame}` 를 `buf.inline_sites` 에 남긴다.

인라인된 본문의 디버그 심볼은 `ctx.frame_id`(callee)로, 위치는 callee 소스 위치로 기록된다(`chunk.zig:687-701`). `allocStackTrace` 는 프레임의 pc 가 어떤 `InlineSite` 안이면 callee 프레임 뒤에 호출 지점의 caller 프레임을 하나 더 붙인다(`debug.zig:600-609`). 그래서 5.11절처럼 `idiv` 가 main 안에 들어 있어도 트레이스에는 `div` 와 `main` 이 나온다.

## 3. 핵심 개념 정리

### 3.1 용어와 TS/Node 쪽 대응

비교는 모두 일반 지식이며, 같은 개념이라는 뜻이 아니라 이해를 돕는 비유다.

| Cyber 용어 | 뜻 | TS/Node 쪽 비유 |
|---|---|---|
| 슬롯(slot), `%N` | fp 기준 8바이트 칸. 변수, 인자, 임시, 반환 모두 | V8 Ignition 의 레지스터 `r0`, `a0` (`node --print-bytecode` 로 볼 수 있다) |
| 프레임(frame) | 함수 한 번 호출이 쓰는 슬롯 구간 | 호출 스택의 한 프레임 |
| `ByteCodeBuffer.ops` | 청크의 `u16` 명령어 배열 | 함수의 BytecodeArray (Cyber 는 청크 단위) |
| `Cstr` | "결과를 어디에 놓아라"는 제약 | 레지스터 할당기의 destination hint |
| `reg_end` | 다음 빈 슬롯 | 스택 포인터 (컴파일 시점 모델) |
| `debugTable` | 실행 pc → 소스 위치 | source position table / source map |
| 재배치(relocation) | 나중에 알게 되는 주소 채우기 | 링커의 relocation |
| `inline_sites` | 인라인된 구간 표시 | 최적화 컴파일러가 인라인 프레임 정보를 남기는 방식과 비슷한 발상 |

### 3.2 OpCode 132개, 기능별 분류

피연산자 표기: `d` 목적지 슬롯, `a` `b` `s` 원본 슬롯, `i16` 부호 있는 즉치, `uNN` 해당 폭 즉치. 길이는 첫 유닛(opcode) 포함 `u16` 유닛 수다(`getInstLenAt`, `bytecode.zig:898`, 의미는 `vm.c` 의 `CASE` 로 확인). 의미 열의 "패닉"은 실행이 `RES_PANIC` 으로 끝난다는 뜻이다.

상수와 이동 (12개)

| 명령어 | 길이 | 피연산자 | 의미 |
|---|---|---|---|
| `const_64` | 6 | d, u64 | 64비트 상수 |
| `const_str` | 7 | d, u64(ptr 48 / len 16), ascii | 정적 문자열. d..d+2 에 `String{buf=null, ptr, len}` |
| `const_16s` / `const_16` | 3 | d, i16 / u16 | 부호 확장 / 영 확장 상수 |
| `const_32` | 4 | d, u32 | d 의 하위 4바이트만 쓴다 |
| `true` `false` | 2 | d | |
| `mov` `mov_2` `mov_3` `mov_4` | 3 | d, s | 슬롯 1~4개 복사 |
| `mov_n` | 4 | d, s, n | 슬롯 n개 복사 |

정수 산술과 비트 (20개). 모두 64비트 슬롯 위에서 동작하고 `add` `sub` `mul` 은 wrap-around 다(오버플로 검사 없음).

| 명령어 | 길이 | 피연산자 | 의미 |
|---|---|---|---|
| `add` `sub` `mul` `imul` | 4 | d, a, b | 덧셈, 뺄셈, 곱셈(무부호), 곱셈(부호) |
| `idiv` `div` `imod` `mod` | 4 | d, a, b | 부호 있는 / 무부호 나눗셈과 나머지. 0 이면 패닉("Division by zero.") |
| `pow` | 4 | d, a, b | 정수 거듭제곱 |
| `and_` `or_` `xor` | 4 | d, a, b | 비트 연산 |
| `lsl` `lsr` | 4 | d, a, b | 시프트. 양은 `b & 0xff` (`vm.c:1573`) |
| `neg` `not` | 3 | d, a | 부호 반전, 비트 반전 |
| `add_i16` | 4 | d, a, i16 | `d = a + 즉치` |
| `add_mul_i16` | 5 | d, a, idx, u16 | `d = a + idx * 즉치` |
| `zext` `sext` | 4 | d, s, bits | 하위 bits 비트를 영 / 부호 확장 |

실수 (18개)

| 명령어 | 길이 | 피연산자 | 의미 |
|---|---|---|---|
| `fadd` `fsub` `fmul` `fdiv` `fmod` | 4 | d, a, b | f64 |
| `fadd32` `fsub32` `fmul32` `fdiv32` `fmod32` | 4 | d, a, b | f32 (슬롯 하위 4바이트) |
| `fneg` `fneg32` `fabs` `f32abs` | 3 | d, a | 부호 반전, 절댓값 |
| `f2i` `f32_2i` `i2f` `i2f32` | 3 | d, a | 실수 ↔ 정수 변환 |

비교와 논리 (23개)

| 명령어 | 길이 | 피연산자 | 의미 |
|---|---|---|---|
| `lt` `gt` `le` `ge` | 4 | d, a, b | 부호 있는 정수 비교 |
| `ult` `ugt` `ule` `uge` | 4 | d, a, b | 무부호 비교 (배열 경계 검사가 `uge`) |
| `cmp` `cmp_8` | 4 | d, a, b | 64비트 / 8비트 동등 비교 |
| `cmp_str` | 4 | d, a, b | 문자열 동등 비교(intrinsic) |
| `feq` `flt` `fgt` `fle` `fge` | 4 | d, a, b | f64 비교 |
| `feq32` `flt32` `fgt32` `fle32` `fge32` | 4 | d, a, b | f32 비교 |
| `lnot` `is_zero` | 3 | d, a | 논리 부정, `a == 0` |

점프(3개)와 호출, 반환(10개). 점프 오프셋은 점프 명령어 자신의 pc 기준 상대값이다.

| 명령어 | 길이 | 피연산자 | 의미 |
|---|---|---|---|
| `jump` | 2 | i16 | 무조건. 음수면 `CHECKPOINT()` |
| `jump_t` | 3 | cond, i16 | cond 가 참이면 |
| `jump_f` | 3 | cond, u16 | cond 가 거짓이면 (앞으로만) |
| `chk_stk` | 3 | ret_size, frame_size | fp 를 반환 슬롯 앞으로 당기고 스택 용량 검사 |
| `call` | 5 | base, u48 | 사용자 함수 호출 |
| `call_host` | 5 | base, u48 | 호스트 함수 호출 |
| `call_ptr` `call_union` | 2 | base | 함수 포인터 / `Func` 객체 호출 |
| `call_trait` | 3 | base, vtable_idx | trait 메서드 호출 |
| `ret_0` `ret` | 1 | | 반환 슬롯이 0개 / 1개인 함수에서 복귀 |
| `ret_n` | 2 | ret_size | 반환 슬롯이 2개 이상인 함수에서 복귀 |
| `enter_jit` | 4 | | JIT 진입. 죽은 코드 |

로드, 스토어, 주소 (20개). 메모리 쪽 오프셋은 바이트 단위 u16 이다.

| 명령어 | 길이 | 피연산자 | 의미 |
|---|---|---|---|
| `load_8` `load_16` `load_32` `load_64` | 4 | d, p, off | `d = *(p + off)` |
| `load_2w` `load_3w` `load_4w` | 4 | d, p, off | 워드 2, 3, 4개를 d.. 에 로드 |
| `load_n` | 5 | d, p, off, size | size 바이트 로드 |
| `store_8` `store_16` `store_32` `store_64` | 4 | p, off, s | `*(p + off) = s` (목적지가 앞에 온다) |
| `store_2w` `store_3w` `store_4w` | 4 | p, off, s | 워드 2, 3, 4개 저장 |
| `store_n` | 5 | p, off, s, size | size 바이트 저장 |
| `memsetz` | 4 | p, off, size | 0 으로 채움 |
| `addr` | 3 | d, s | `d = &stack[s]` (스택 안 주소) |
| `unwrap_addr` | 5 | d, p, tag, off | `*p == tag` 이면 `d = p + off`, 아니면 패닉 |
| `unwrap_nz` | 3 | d, s | `s != 0` 이면 `d = s`, 아니면 패닉 |

힙과 소유권 (7개). 의미 상세는 [06장](06-memory-ownership.md).

| 명령어 | 길이 | 피연산자 | 의미 |
|---|---|---|---|
| `new` | 4 | d, type_id, size | 힙 객체 할당 |
| `retain` `retain_nz` | 2 | reg | rc += 1 (`_nz` 는 0 이 아닐 때만) |
| `release` `release_opt` | 3 | reg, i16 | rc -= 1. 0 이 아니면(`_opt` 는 포인터가 0 이어도) 오프셋만큼 건너뛰어 뒤따르는 소멸자 호출을 생략 |
| `dtor_str` | 2 | reg | reg 가 가리키는 `String` 의 버퍼를 release |
| `copy_str` | 3 | d, s | s 가 가리키는 `String` 3워드를 d.. 에 복사하고 버퍼 retain (이 fork 가 추가) |

함수 값, 클로저, 타입 (9개). 앞의 힙 표와 같은 형식이다.

| 명령어 | 길이 | 피연산자 | 의미 |
|---|---|---|---|
| `fn_vm` `fn_host` | 5 | d, u48 | 함수 주소를 값으로 (`fn_host` 는 최상위 비트 표시) |
| `fn_union` | 4 | d, s, union_t | 함수 값을 힙 `Func` 객체로 포장 |
| `extern_func` | 3 | d, func_id | extern 함수 포인터 |
| `closure` | 7+n | d, union_t, u48, info, 캡처 슬롯 n개 | 클로저 객체 할당, info = 개수 15비트 + pinned 1비트 |
| `captured` | 4 | d, closure, idx | 클로저의 캡처 값 읽기 (closure 는 callee 슬롯) |
| `trait` | 5 | d, impl, type_id, vtable | d = vtable id, d+1 = 구현체 값 |
| `cast` | 5 | d, s, type, ref | 런타임 다운캐스트. 실패하면 패닉 |
| `castAbstract` | 4 | d, s, type | 추상 타입(`Object`)으로만 통과 |

제너레이터와 비동기 (5개, 의미는 [07장](07-coroutines-concurrency.md))와 기타 (5개)

| 명령어 | 길이 | 피연산자 | 의미 |
|---|---|---|---|
| `ret_gen` | 5 | type_id, ret_size, reg_end, resume_off | 제너레이터 객체 생성 후 복귀 |
| `ret_y` | 4 | ret_size, resume_off, done | yield |
| `gen_next` `gen_end` | 4 | ret, base, gen | 다음 값 / 종료 |
| `await_op` | 2 | slot | await |
| `nop32` | 3 | u32 | 함수 앞의 헤더. 함수 id |
| `nops` | 5 | u64 | 디버그 라벨 문자열(포인터 + 길이). 실행 때 아무 일도 안 한다 |
| `trap` | 1 | | "Reached trap." 패닉. Trace 빌드에서만 함수 맨 끝에 붙는다(`sema.zig:9150`) |
| `trap_debug` | 1 | | `breakpoint` 문. Trace 빌드에서만 디버거 트랩 |
| `end` | 1 | | main 종료 |

합계는 12 + 20 + 18 + 23 + 3 + 10 + 20 + 7 + 9 + 5 + 5 = 132 이고 `bytecode.zig:1238` 의 단위 테스트가 같은 숫자를 검사한다. 확장 폭 요약: 레지스터와 즉치는 u16, 주소는 u48, 상수와 문자열 포인터는 u64 다. 명령어는 가장 짧은 것이 1유닛(2바이트), 가장 긴 것이 `closure` 의 7+n 유닛이다.

### 3.3 `cyber compile` 덤프를 신뢰해도 되는 정도

`bytecode.write_inst`(`src/bytecode.zig:290`)는 명령어 크기를 1바이트에서 2바이트로 바꾼 커밋 `53e37ed6`(2025-12-13) 이전에 쓰인 부분이 남아 있다. 그 시절에는 `Inst` 가 바이트라서 `@ptrCast(pc + 3)` 이 "3바이트 뒤"였지만 지금은 "3유닛 뒤"다. 아래는 직접 덤프해서 확인한 어긋남이다.

| 증상 | 해당 명령어 | 실제 피연산자 (`vm.c` 기준) |
|---|---|---|
| 뒤로 가는 `jump` 가 `jmp @65674` 처럼 큰 앞쪽 주소로 찍힌다. 65536 을 빼서 읽는다 | `jump` | i16 상대 오프셋. 덤프가 값을 u16 으로 읽어서 `jump < 0` 분기가 실행되지 않는다 |
| 마지막 피연산자 자리에 다음 명령어의 opcode 번호가 찍힌다 | `is_zero`, `lnot`, `unwrap_nz` | d, s |
| 같은 증상 | `sext`, `zext` | d, s, bits |
| 같은 증상 | `fn_union`, `trait`, `new` | 각각 d,s,type / d,impl,type,vtable / d,type,size |
| `jmp 9` 처럼 의미 없는 숫자 | `release`, `release_opt` | reg, i16 |
| `vtable[123]` 처럼 엉뚱한 번호 | `call_trait` | base, vtable_idx |
| 피연산자가 아예 안 찍힌다 | `and_` `xor` `lsr` `mod` `imod` `pow` `not` `fmod` `ult` `ugt` `ule` `uge` `f2i` `i2f` `fabs` `const_32` `fn_vm` `fn_host` `extern_func` `retain_nz` `gen_end` | 위 표의 피연산자 순서 |

마지막 행의 목록은 `write_inst` 의 case 목록을 읽어 만들었고(`uge` 와 `fn_vm` 이 빈 줄로 나오는 것은 덤프로도 확인했다), `memsetz` 와 `gen_next` 도 같은 방식으로 읽는 코드지만 덤프에서는 확인하지 못했다(코드 읽기로만 판단). 우연히 맞아 보이는 경우를 조심하라. 5.9절의 `is_zero %10 = (%7 == 0)` 의 `%7` 은 우연히 맞는데, 다음 명령어 `lnot` 의 opcode 번호가 7 이기 때문이다. 이 장의 실습은 `vm.c` 로 교차 확인한 값만 해설에 쓴다.

2026-11-06 기준 위 표는 모두 고쳐졌다. 뒤로 가는 `jump` 는 `7563e3b4`, `is_zero` 와 빈 덤프 행은 `15a85a9e`, 나머지(`lnot` · `unwrap_nz` · `sext` · `zext` · `fn_union` · `trait` · `new` · `release` · `release_opt` · `call_trait` · `gen_next` · `memsetz`)는 F-62 의 마지막 수정에서 `vm.c` 레이아웃대로 `pc[k].val` 로 읽는다. 이 장의 실습 출력 중 오표기라고 적은 줄은 그 시점의 덤프이고, 지금 덤프하면 바른 피연산자가 나온다.

## 4. 소스 읽기 지도

권장 순서와 볼 것이다. 전체를 훑는 데 3시간 정도 잡는다.

1. `src/bytecode.zig:1068` `OpCode` 와 이 장 3.2절 표를 나란히 놓고 이름만 훑는다(15분).
2. `src/vm.c:416` `execBytecode` 의 `CASE` 몇 개: `CONST_64`(618), `MOV`(675), `JUMP_F`(851), `JUMP`(867), `CHK_STK`(913), `CALL`(928), `RET`(1010), `LOAD_64`(1073), `UnwrapAddr`(1298). 명령어 의미의 정답이다. 상수는 `vm.h:141-146`(`CALL_INST_LEN` 등)과 `:151-306`(opcode 번호 enum).
3. `src/bc_gen.zig:36` `genAll` → `:362` `genChunk` → `:438` `genChunkInner` → `:612` `mainBlock` → `:634` `genFuncBlock`. 함수와 main 이 놓이는 모양(2.3절).
4. `:379` `genStmt` 와 `:483` `genExpr` 의 `switch`. IR 코드마다 어떤 `gen_*` 인지(2.4절 표).
5. 레지스터: `:2173` `reserveFuncSlots`, `:2200` `reserve_local`, `:2214` `reserve_reg`, `:3251` `selectReg`, `:3315` `Cstr`, `:3378` `pop_temp_value`, `:3384` `pop_regs`. `:1993` `genBinOp2` 가 전형이다.
6. 호출: `:1397` `gen_call`, `:2392` `beginCall`, `:2479` `endCall`, `:3103` `pushCall`, `:2350` `gen_ret_expr`. 그리고 `vm.c` 의 `CALL`/`CHK_STK`/`RET`.
7. 제어 흐름: `:2604` `gen_if_block`, `:2489` `gen_loop_block`, `:2501` `gen_for_range_stmt`, `src/chunk.zig:446-557` 점프 패치. sema 쪽은 `src/sema.zig:615-637`(while), `:1022-1040`(if).
8. 최적화: `:1964` `gen_add`, `:1447-1719` 인라인 전체, `src/sema.zig:8145` 상수 접기.
9. 부가 테이블의 소비자: `src/debug.zig:46`, `:592-636`, `src/thread.zig:68-100`, `:857-914`.
10. 도구: `src/debug.zig:692` `dumpBytecode`, `src/bytecode.zig:290` `write_inst`.

### 새 명령어를 추가하려면 (설계만, 구현하지 않음)

이 fork 가 실제로 추가한 `add_mul_i16`(`5171b7fa`)과 `copy_str`(`72f4ecef`) 두 커밋이 건드린 파일이 곧 체크리스트다. 파일 순서대로 적는다.

1. `src/vm.h`: `OpCode` enum 에 `CodeXxx` 를 추가한다. 새 번호는 삽입 위치에 따라 이후 번호를 밀어낸다. 두 커밋 모두 비슷한 명령어 바로 뒤에 넣었다(`CodeAddI16` 뒤, `CodeDTOR_STR` 뒤).
2. `src/vm.c`: (a) `jumpTable` 에 `JENTRY(Xxx)` 를 enum 과 같은 순서의 같은 위치에 추가한다. 끝의 `STATIC_ASSERT`(`vm.c:588`)는 개수만 검사하므로 순서를 틀리면 조용히 엉뚱한 명령어가 실행된다. (b) `CASE(Xxx)` 본문을 구현한다. 마지막에 `pc += 길이; NEXT();`. 패닉하려면 `panicStaticMsg(t, "...")` 후 `RETURN(RES_PANIC)`.
3. `src/bytecode.zig`: (a) `OpCode` 에 `xxx = vmc.CodeXxx`(Zig 쪽 순서는 상관없다. 값이 C enum 에서 오기 때문이다), (b) `getInstLenAt` 의 길이 분기, (c) `write_inst` 의 덤프(선택이지만 이 장 3.3절처럼 어긋나기 쉬우니 `pc[k].val` 로 쓴다), (d) 맨 아래 단위 테스트의 개수(`:1238`).
4. `src/bc_gen.zig`: 내보내는 곳. `c.pushCode(.xxx, &.{...}, node)`, 패닉할 수 있으면 `pushFCode` 로 디버그 심볼을 붙인다. 이 장의 `gen_add`(`add_mul_i16`)처럼 IR 패턴을 `gen_*` 안에서 감지해 새 명령어로 낮추는 방식이 두 번 다 쓰였다.
5. 영향 확인: 스택을 건드리는 명령어라면 `thread.zig` 의 스택 성장 코드(`:876` 이 `chk_stk` 를 가정한다)를, 패닉하는 명령어라면 인라인 심볼 규칙을 본다.
6. 테스트: `src/test/` 아래 `.cy` 파일에 새 명령어가 생성되는 최소 프로그램 하나를 두고, `cyber compile` 로 덤프를 확인한다.
7. 하지 않는 것: `src/jit/gen.zig` 대응. `docs/decisions/project_direction.md` 에 "bytecode에 새 opcode를 넣을 때 JIT 지원은 맞추지 않는다"고 적혀 있다. C 백엔드(`cgen.zig`)는 IR 에서 만들어서 opcode 를 참조하지 않는다(`rg OpCode src/cgen.zig` 결과 없음).
8. 문서: 이 fork 의 규칙대로 `docs/decisions/` 에 결정을 먼저 적는다(`project_direction.md` 의 "바꿀 때는 docs/decisions에 결정을 먼저 적는다").

## 5. 실습

### 5.0 준비

```sh
cd /Users/kez/Repository/cyber-script
zig-out/bin/cyber compile x.cy | sed '/^--chunk1/,$d'     # 사용자 파일(chunk0)만 본다
```

`cyber compile` 은 `core.cy`(chunk1)까지 덤프해서 6000줄이 넘는다. 위처럼 chunk1 앞에서 자르면 사용자 파일만 남는다. 아래 출력은 여기서 (1) 늘 똑같은 보조 함수 블록(`@program_init`, `@program_deinit`, `print[int]`, `prints[int]`, `to_print_string[int]`), (2) `nop32` 줄, (3) 첫 줄의 긴 경로를 지웠다. `...` 는 생략한 줄, `#` 주석은 내가 덧붙인 것이고 명령어 텍스트는 그대로다. 실행 결과는 `zig-out/bin/cyber x.cy` 의 실제 출력이다. 소스를 그대로 저장하면 pc 번호까지 같다(`const_64` 의 포인터 값만 실행마다 다를 수 있다).

### 5.1 산술, 상수 접기, 레지스터 할당

```
fn calc(a int, b int, c int) -> int:
    return a * b + c - 3

fn bump(x int) -> int:
    y := x + 1
    return y * 2

n := calc(4, 5, 6)
m := 2 + 3 * 4
print(n + m)
```

실행 결과 `37`.

```
--start
0:72 .const_16s: %2 = 4          # calc 의 인자가 임시 %2 %3 %4 에 (calc 는 인라인되어 call 이 없다)
0:75 .const_16s: %3 = 5
0:78 .const_16s: %4 = 6
0:81 .imul: %6 = %2 * %3         # a * b
0:85 .add: %5 = %6 + %4          # + c
0:89 .const_16s: %6 = 3          # 뺄셈은 즉치형이 없다. 방금 반납한 %6 을 다시 쓴다
0:92 .sub: %1 = %5 - %6          # 결과가 곧바로 n 의 슬롯 %1 에
0:96 .const_16s: %2 = 14         # m := 2 + 3 * 4 는 sema 가 14 로 접었다
0:99 .add: %3 = %1 + %2          # n + m
--0 `fn calc`
0:137 .chk_stk: ret=1, frame=10  # 10 = 반환 1 + 호출 정보 4 + 매개변수 3 + 임시 2
0:140 .imul: %9 = %5 * %6        # 매개변수 a b c 는 %5 %6 %7
0:144 .add: %8 = %9 + %7
0:148 .const_16s: %9 = 3
0:151 .sub: %0 = %8 - %9         # 반환 슬롯 %0
--1 `fn bump`
0:162 .add_i16: %6 = %5 + 1      # y := x + 1 은 즉치 덧셈
0:166 .const_16s: %7 = 2         # 곱셈은 즉치형이 없다
0:169 .imul: %0 = %6 * %7
```

- main 의 `0:72`~`0:92` 가 2.5절의 표 그대로다. `%6` 이 두 번 다른 용도로 쓰인다.
- 독립 함수 `calc` 도 따로 생성된다(함수 포인터 호출 등 인라인 밖의 호출용). 같은 식이 슬롯 번호만 달라진다.
- `frame=10` 은 `max_regs`, 즉 가장 높이 올라간 `reg_end` 다.

### 5.2 if / else 사슬과 인라인된 return

```
fn sign(x int) -> int:
    if x < 0:
        return -1
    else x == 0:
        return 0
    else:
        return 1

fn clamp(x int) -> int:
    if x > 100:
        return 100
    return x

a := sign(-5)
b := clamp(7)
print(a + b)
```

실행 결과 `6`.

```
--start
0:78 .call: %1 = e2_if.sign(%6..%7) 0        # sign 은 인라인되지 않았다 (이유는 아래)
0:83 .const_16s: %3 = 7                      # clamp(7) 인라인. 인자 x 는 임시 %3
0:86 .const_16s: %5 = 100
0:89 .gt: %4 = %3 > %5
0:93 .jump_f: if (!%4) jmp @101              # x > 100 이 아니면 101 로
0:96 .const_16s: %2 = 100                    # return 100 → b 의 슬롯 %2 에 직접
0:99 .jump: jmp @104                         # 인라인된 return: 본문 끝으로
0:101 .mov: %2 = %3                          # return x
--0 `fn sign`
0:148 .lt: %6 = %5 < %7                      # x < 0
0:152 .jump_f: if (!%6) jmp @164
0:155 .const_64: %0 = 18446744073709551615   # return -1: 음수 상수는 const_64
0:161 .ret:
0:162 .jump: jmp @184                        # 도달 불가: 갈래 끝의 break outer
0:164 .const_16s: %7 = 0
0:167 .cmp: %6 = (%5 == %7)                  # x == 0
```

- `sign` 은 `else` 갈래가 있어 sema 가 갈래마다 `break outer` 를 심었고(2.8절) `break_` 는 인라인 허용 문장이 아니라서 거부된다. `clamp` 는 `else` 가 없어 인라인된다. 비슷한 함수라도 모양에 따라 갈린다.
- `ret` 바로 뒤의 `jump` 는 `return` 때문에 실행되지 않는 죽은 코드다.
- `-1` 이 6유닛 `const_64` 인 것은 `genConstInt`(`bc_gen.zig:3074`)가 0 이상에서만 `const_16s` 를 쓰기 때문이다. `CONST_16S` 는 부호 확장을 하므로(`vm.c:635`) 개선 여지가 있다(변형 과제 6).

### 5.3 while 과 for range: 뒤로 가는 점프

```
fn sum_to(n int) -> int:
    s := 0
    i := 0
    while i < n:
        s += i
        i += 1
    return s

fn sum_range(n int) -> int:
    s := 0
    for 0..n |i|:
        if i == 3: continue
        s += i
    return s

r := sum_to(10) + sum_range(5)
print(r)
```

실행 결과 `52`. 두 함수 모두 루프가 있어 인라인되지 않고 main 에 `call` 로 남는다.

```
--0 `fn sum_to`
0:132 .const_16s: %6 = 0         # s := 0   (n 은 %5)
0:135 .const_16s: %7 = 0         # i := 0
0:138 .lt: %8 = %7 < %5          # 루프 맨 위(top_pc): i < n 을 임시 %8 에
0:142 .jump_f: if (!%8) jmp @155 # 거짓이면 루프 밖
0:145 .add: %6 = %6 + %7         # s += i. 목적지가 s 자신이라 제자리 갱신
0:149 .add_i16: %7 = %7 + 1      # i += 1
0:153 .jump: jmp @65674          # continue = 위로. 덤프 오류: 65674 - 65536 = 138
0:155 .mov: %0 = %6              # return s
--1 `fn sum_range`
0:168 .const_16s: %10 = 0        # 범위 시작값 (임시)
0:171 .mov: %9 = %5              # rangeEnd = n   (숨은 슬롯: counter %7, cond %8, rangeEnd %9)
0:174 .mov: %7 = %10             # counter = 시작값
0:177 .lt: %8 = %7 < %9          # iter_pc
0:181 .jump_f: if (!%8) jmp @209 # 루프 탈출
0:184 .mov: %11 = %7             # 사용자 변수 i 는 counter 를 복사한 별개 슬롯 %11
0:197 .jump: jmp @203            # `continue` → 카운터 증가(203)
0:203 .add_i16: %7 = %7 + 1      # cont_pc: counter += 1
0:207 .jump: jmp @65713          # 65713 - 65536 = 177
```

- `sum_to` 는 `loop_block { if_block(i < n) { 본문; continue } }`(2.8절)가 그대로 풀린 모양이다. 루프 끝의 `jump` 가 `continue` 이고 목적지는 `gen_loop_block` 이 기억한 `top_pc` 다.
- 덤프의 `jmp @65674` 는 실제로 `138`(`lt` 의 pc)이다. VM 은 `(int16_t)pc[1]` 로 읽어 `-15` 칸 뒤로 간다(`vm.c:868`): `153 - 15 = 138`.
- `for 0..n |i|` 는 `gen_for_range_stmt`(`bc_gen.zig:2501`)가 직접 푼다. 숨은 슬롯을 먼저 예약하고, 증가는 `add_i16 +1` 하나다. `patchForBlockJumps` 가 `continue` 를 203 으로, 탈출을 209 로 한 번에 패치했다.

### 5.4 호출과 재귀: call 이 남는 곳

```
fn fib(n int) -> int:
    if n < 2: return n
    return fib(n - 1) + fib(n - 2)

fn fact(n int) -> int:
    r := 1
    while n > 1:
        r = r * n
        n -= 1
    return r

x := fib(10)
y := fact(5)
print(x + y)
```

실행 결과 `175`.

```
--start
0:72 .const_16s: %2 = 10         # x := fib(10) 은 인라인. 인자 n 은 임시 %2, 반환 슬롯은 x 의 자리 %1
0:78 .lt: %3 = %2 < %4           # n < 2
0:85 .mov: %1 = %2               # return n
0:88 .jump: jmp @118             # 인라인된 return → 본문 끝
0:97 .call: %3 = e4_rec.fib(%8..%9) 0   # 인라인 본문 안의 재귀는 진짜 call: base 4, 반환 %3, 인자 %8
0:109 .call: %4 = e4_rec.fib(%9..%10) 0
0:114 .add: %1 = %3 + %4
0:121 .call: %2 = e4_rec.fact(%7..%8) 1  # y := fact(5): base 3, 반환 슬롯이 y 의 자리 %2. mov 없음
--0 `fn fib`
0:164 .chk_stk: ret=1, frame=17
0:210 .call: %8 = e4_rec.fib(%13..%14) 0  # fib 본문 안 사본에서의 호출: base 9, 반환 %8, 인자 %13
--1 `fn fact`
0:292 .const_16s: %6 = 1         # r := 1   (n 은 %5)
0:298 .gt: %7 = %5 > %8          # while n > 1
0:305 .imul: %6 = %6 * %5        # r = r * n
0:309 .const_16s: %8 = 1
0:312 .sub: %5 = %5 - %8         # n -= 1: 뺄셈 즉치형이 없어 두 줄. 매개변수 슬롯을 제자리 갱신
0:316 .jump: jmp @65831          # 65831 - 65536 = 295
```

- `fib` 는 호출 구조를 보기엔 좋지 않다. 2단계 인라인이 재귀 한 단계를 호출 지점에 펼치기 때문이다(`project_bc_inline.md` 2단계). 독립 `fib` 본문 안에도 인라인 사본이 둘 들어 있고 그 안에 진짜 `call` 이 있다.
- `call: %8 = fib(%13..%14)` 에서 `base = 13 - 4 = 9`, 반환 슬롯 `9 - 1 = 8`. 2.7절 그림에 대입하면 피호출자의 fp' 는 이 프레임보다 8칸 위다.
- `fact(5)` 의 반환 슬롯이 변수 `y` 의 슬롯(`%2`)이라 호출 뒤에 `mov` 가 없다. `beginCall` 의 목적지 재사용이다.

### 5.5 프레임을 직접 보기: `meta.dump_frame`

`meta.dump_frame()` 은 자신을 호출한 함수의 프레임 슬롯 값을 출력하는 호스트 함수다(`src/builtins/meta.zig:291`). 호출 규약을 실제 메모리로 확인할 수 있다.

```
use meta

fn probe(a int, b int) -> int:
    x := a * 100
    y := b + 7
    n := 0
    while n < 1:
        n += 1
    meta.dump_frame()
    return x + y + n

r := probe(3, 4)
print(r)
```

실행 결과(주소는 실행마다 다르다).

```
frame: %0=10, info=10, ret_pc=bytecode.Inst@583744450a6, ret_fp=value.Value@58375800100
  locals: %5=3, %6=4, %7=300, %8=11, %9=1, %10=66560, %11=6062149488946, %12=6062170177800, %13=12297829382473034410, 
312
```

```
--start
0:78 .call: %1 = f1_frame.probe(%6..%8) 0      # base = 2: callinfo %2, 반환 pc %3, 이전 fp %4, callee %5, 인자 a=%6 b=%7
--0 `fn probe`
0:120 .chk_stk: ret=1, frame=14
0:126 .imul: %7 = %5 * %8        # x := a * 100
0:130 .add_i16: %8 = %6 + 7      # y := b + 7
0:134 .const_16s: %9 = 0         # n := 0
0:153 .call_host: %10 = dump_frame(%14..%14) 0   # base 10. 반환이 void 라 %10 은 base 자신
```

```
main 프레임 (fp = M)               probe 프레임 (fp' = M + 1)   dump_frame 출력
M[1]  r  (반환값이 곧바로 여기에)  ═▶ P[0]  반환 슬롯             %0=10 (아직 안 쓴 슬롯의 잔재)
M[2]  callinfo                    ═▶ P[1]                       info=10  (= 5 << 1)
M[3]  반환 pc                     ═▶ P[2]                       ret_pc
M[4]  이전 fp                     ═▶ P[3]                       ret_fp
M[5]  callee 자리(미사용)         ═▶ P[4]
M[6]  인자 a = 3                  ═▶ P[5]  a                    %5=3
M[7]  인자 b = 4                  ═▶ P[6]  b                    %6=4
                                     P[7]  x = 300              %7=300
                                     P[8]  y = 11               %8=11
                                     P[9]  n = 1                %9=1
```

- `info=10` 은 callinfo 가 `call_inst_off(5) << 1` 임을 보여 준다. `%5=3, %6=4` 는 호출자가 계산한 인자 슬롯이 복사 없이 매개변수가 된다는 증거다. 마지막 줄 `312` 는 `x + y + n = 300 + 11 + 1` 이다.
- locals 는 `%13` 에서 끝난다. `probe` 의 프레임이 14슬롯이기 때문이다. 2026-11-04 시점에는 `%257` 까지 찍혔는데, `get_pc_func_metadata`(`src/debug.zig:46-63`)가 `stack_size` 를 `metadata_pc + 3`(`:59`)에서 읽었기 때문이다. `chk_stk` 의 프레임 크기는 `+2` 에 있고 `+3` 은 다음 명령어의 첫 유닛(`const_16s` 에 `temp_dst` 힌트 `0x100` 이 붙은 `0x102 = 258`)이었다. 1바이트 시절 위치가 남은 또 하나의 사례였고(7절, F-31) 2026-11-06 에 `+2` 로 고쳤다. 맨 위(main)에서 부르면 main 에 `chk_stk` 가 없어 다른 함수의 메타데이터를 읽는 한계는 남아 있다.

### 5.6 struct 필드 읽기와 쓰기

```
type Pt(x, y int)

type Rect:
    x int
    y int
    name str

fn dist2(p Pt) -> int:
    return p.x * p.x + p.y * p.y

fn shift(p Pt) -> Pt:
    q := p
    q.x += 3
    q.y = 10
    return q

fn area(r &Rect) -> int:
    n := 0
    while n < 2:
        n += 1
    return r.x * r.y + n

p := Pt{3, 4}
q := shift(p)
r := Rect{x=2, y=5, name='box'}
a := area(&r)
print(dist2(q) + a)
```

실행 결과 `148`. `dist2` 와 `shift` 는 인라인되고 `area` 는 루프가 있어 `call` 로 남는다.

```
--start
0:72 .addr: %3 = *%1             # p := Pt{3, 4}. p 는 %1..%2 (2슬롯). 필드에 쓰려면 먼저 시작 주소를
0:81 .store_64: [%3 + 0] = %4    # p.x = 3 (오프셋은 바이트)
0:85 .store_64: [%3 + 8] = %5    # p.y = 4
0:89 .mov_2: %5 = %1             # shift(p) 인라인: 인자 p 를 임시 %5..%6 로 2슬롯 복사
0:92 .mov_2: %7 = %5             # q := p  (shift 안의 지역 변수 q)
0:95 .addr: %9 = *%7
0:98 .addr: %12 = *%7
0:101 .load_64: %11 = [%12 + 0]  # q.x 읽기 = addr + load
0:105 .add_i16: %10 = %11 + 3    # += 3
0:109 .store_64: [%9 + 0] = %10  # q.x 쓰기 = addr + store
0:123 .mov_2: %3 = %7            # return q → main 의 q 의 자리 %3..%4
0:126 .addr: %10 = *%5           # r := Rect{...}. r 는 %5..%9 (5슬롯 = 40바이트)
0:135 .const_str: %13..%16 = 'box' ascii=true
0:142 .store_64: [%10 + 0] = %11
0:146 .store_64: [%10 + 8] = %12
0:150 .store_3w: [%10 + 16] = %13   # name 은 3슬롯을 한 명령어로
0:154 .addr: %15 = *%5           # &r: 인자는 r 의 스택 주소
0:246 .dtor_str: destruct [%12]  # main 끝에서 r.name 소멸 (앞의 addr + add_i16 16 으로 name 의 주소를 만든다)
--0 `fn dist2`
0:255 .addr: %9 = *%5
0:258 .load_64: %8 = [%9 + 0]    # p.x
0:262 .addr: %10 = *%5           # 같은 구조체라도 읽을 때마다 addr 를 다시 낸다
--2 `fn area`
0:363 .load_64: %8 = [%5 + 0]    # r.x. r 는 이미 포인터(%5)라 addr 가 필요 없다
0:367 .load_64: %9 = [%5 + 8]    # r.y
```

- 레지스터 안의 구조체 필드 접근은 전부 `addr` + `load` / `store` 다. 참조(`&Rect`)로 받으면 슬롯이 이미 포인터라 `load_64 [%5 + 0]` 한 줄이다. 접근마다 `addr` 를 다시 내는 것이 `dist2` 에 보인다. 레지스터 캐시가 없는 단순함의 대가다(6절).
- `addr` 의 결과(`%3`, `%9`, `%12`, `%15`)는 스택 안을 가리키는 포인터이고 이 슬롯들이 `ptr_layout` 에 표시된다(2.9절).
- `Rect` 의 40바이트가 `store_64`, `store_64`, `store_3w` 로 나뉜다. 크기가 32, 24, 16, 8, 4, 2, 1 이 아니면 `store_n` / `load_n` 이다.

### 5.7 Slice 인덱스: 호출 없이 한 번에

```
fn at(xs &[]int, i int) -> int:
    return xs[i]

fn put(xs &[]int, i int, v int):
    xs[i] = v

xs := []int{10, 20, 30}
put(&xs, 1, 99)
print(at(&xs, 1))
```

실행 결과 `99`.

```
--0 `fn at`
0:222 .mov: %8 = %5              # Slice.@index_addr(self, idx) 가 인라인되어 인자를 임시로 복사 (self %8, idx %9)
0:225 .mov: %9 = %6
0:228 .load_64: %11 = [%8 + 16]  # Slice._len (오프셋 16)
0:232 .uge:                      # 덤프는 피연산자를 찍지 않는다. 흐름상 %10 = (%9 >=u %11)
0:236 .jump_f: if (!%10) jmp @247   # 경계 안이면 247 로
0:242 .call: core.panic_oob(%15..%16) 34   # 경계 밖일 때만 진짜 call
0:247 .load_64: %10 = [%8 + 8]   # Slice.ptr (오프셋 8)
0:251 .add_mul_i16: %7 = %10 + %9 * 8     # 요소 주소 = ptr + idx * 8
0:256 .load_64: %0 = [%7 + 0]    # 요소 읽기
--1 `fn put`
0:295 .load_64: %11 = [%7 + 8]
0:299 .add_mul_i16: %10 = %11 + %8 * 8
0:304 .store_64: [%10 + 0] = %9  # 같은 모양, 마지막만 store
```

- 결정 문서(`project_array_index_calls.md`)가 말한 "호출 3번"(`@index_addr` → `Int.uge` → `Ptr.+`)이 사라진 모습이다. `uge` 한 명령어, `add_mul_i16` 한 명령어, 경계 밖일 때만 `panic_oob` 호출이다.
- `Slice` 레이아웃(`buf, ptr, _len, header`)이 오프셋 `8`(ptr), `16`(len)로 드러난다. `core.cy` 의 필드 순서를 바꾸면 이 오프셋이 곧 바뀐다.
- `uge` 줄이 비어 있는 것은 3.3절의 덤프 결함이다. 피연산자는 레지스터 흐름(`jump_f` 가 `%10` 을 읽는다)으로 복원했다(추정).

### 5.8 클로저, 그리고 동적 호출

```
type Fn1 = fn(int) -> int

fn make_adder(n ^int) -> Func[Fn1]:
    return |b| n.* + b

add5 := make_adder(^5)
r := add5(10)
print(r)
```

실행 결과 `15`.

```
--start
0:75 .new: %2 = byte{size=2}     # ^5: 힙 박스 할당 (덤프의 타입/크기는 부정확)
0:79 .store_64: [%2 + 0] = %3    # 박스에 5 저장
0:86 .call: %3 = e7_closure.make_adder(%8..%9) 0
0:94 .release: %2.rc -= 1; jmp 9 # 박스 임시 해제. 덤프의 jmp 9 는 오류, 실제 오프셋은 11 (release 3 + mov 3 + call 5)
0:100 .call: core.@deinitObject(%7..%8) 3   # rc 가 0 일 때만 실행되는 소멸자 호출 (release 가 건너뛴다)
0:105 .mov: %6 = %1              # 클로저 값을 callee 슬롯(base 3 + 3 = %6)에 복사
0:108 .const_16s: %7 = 10        # 인자
0:111 .call_union: ?..%3 = call_union(%7..)   # base = 3, 반환 슬롯 %2 (= r)
--0 `fn make_adder`
0:164 .closure: %0 = closure(id=0, union_t=116, ncap=1, stack=false, vals={ 5, 0 })   # 슬롯 %5 (n)를 캡처. id=0 은 덤프의 고정 문자열
--6 `fn lambda`
0:179 .captured: %7 = [%4 + 0]   # callee 슬롯 %4 의 클로저에서 캡처 0번 (박스 포인터)
0:183 .load_64: %6 = [%7 + 0]    # n.*
0:187 .add: %0 = %6 + %5         # + b
```

- `closure` 는 8유닛(`0:164`~`0:171`, 7 + 캡처 1)이다. 캡처하는 것은 값 5 가 아니라 박스(`^int`) 포인터다. 이 언어에서 클로저는 `^T` 박스만 캡처할 수 있다(`src/test/functions/capture_non_ref_error.cy`).
- 람다 본문은 callee 슬롯(`%4`)을 클로저 값으로 읽는다(`closure_local`, `bc_gen.zig:2183`). 호출자가 `call_union` 전에 클로저 값을 그 슬롯에 복사해 둔다.

trait 객체 호출(`call_trait`)도 같은 틀이다.

```
type Shape trait:
    fn area() -> int

type Sq:
    with Shape
    w int

fn (&Sq) area() -> int:
    n := 0
    while n < 1:
        n += 1
    return self.w * self.w + n

var s ^Dyn[Shape] = ^Sq{w=3}
r := s.area()
print(r)
```

실행 결과 `10`. main 의 호출 부분은 이렇다.

```
0:83 .trait: %7 = trait(type=3, vtable=0, %1)   # 덤프 피연산자는 부정확. trait 값(2슬롯) 구성
0:88 .mov_2: %7 = %1                            # 수신자 포함 2슬롯을 callee 자리 %7 부터: %7 = vtable id, %8 = 수신자
0:91 .call_trait: ?..%4 = %7.vtable[9](%8..)    # base 4. 덤프의 vtable[9] 는 오류 (다음 명령어 mov 의 opcode 번호)
```

- 두 명령어 모두 `base+3` 의 callee 슬롯이 열쇠다. `call_union` 은 그 슬롯의 `Func` 객체를, `call_trait` 은 vtable id 를 읽고 명령어의 `vtable_idx` 로 메서드를 고른다(2단 조회).
- 이 둘은 호출 대상이 바이트코드에 없어 재배치 대상이 아니다. 2026-11-08 `c94f1569` 전에는 `ptr_table` 에도 올라가지 않아 7절의 문제를 낳았다.

### 5.9 Option 언랩

```
fn find(xs &[]int, want int) -> ?int:
    n := 0
    while n < xs.len():
        if xs[n] == want: return n
        n += 1
    return none

fn pick(o ?int) -> int:
    return o.? + 1

fn safe(o ?int) -> int:
    if o |v|:
        return v * 2
    return -1

xs := []int{4, 5, 6}
i := find(&xs, 5)
print(pick(i))
print(safe(i))
print(safe(none))
```

실행 결과 `2`, `2`, `-1`.

```
--0 `fn find`
0:257 .chk_stk: ret=2, frame=21     # 반환이 2슬롯 (?int = 태그 + 페이로드)
0:322 .addr: %11 = *%0              # return n: 반환 슬롯 %0..%1 에 ?int 를 직접 구성
0:325 .const_16s: %12 = 1
0:328 .store_64: [%11 + 0] = %12    # 태그 1 (some)
0:332 .store_64: [%11 + 8] = %8     # 페이로드 n
0:336 .ret_n: ret %0..%2
--1 `fn pick`
0:362 .addr: %9 = *%5               # o 의 주소
0:365 .unwrap_addr: %8 = %9.!1 + 8  # 태그가 1 인지 확인(아니면 패닉), 페이로드 주소 = 주소 + 8
0:370 .load_64: %7 = [%8 + 0]
--2 `fn safe`
0:391 .load_64: %11 = [%12 + 0]     # 태그 읽기
0:395 .is_zero: %10 = (%7 == 0)     # 덤프의 %7 은 우연히 맞아 보일 뿐 부정확하다 (3.3절). 흐름상 %10 = (%11 == 0)
0:398 .lnot: %9 = !%14              # 흐름상 %9 = !%10
0:401 .jump_f: if (!%9) jmp @419
0:407 .load_64: %10 = [%11 + 8]     # v := 페이로드
```

`pick(none)` 으로 패닉을 내면 이렇다(경로는 줄였다).

```
panic: Expected active choice tag `1`, found `0`.

e8b_unwrap_none.cy:2:12 pick:
    return o.? + 1
           ^
e8b_unwrap_none.cy:4:7 main:
print(pick(none))
      ^
```

- `?int` 는 16바이트다. `.?` 는 `unwrap_addr` 로 태그를 검사해 패닉하고, `?^int`(0 이 none 인 단일 슬롯 Option)는 `unwrap_nz` 로 같은 메시지를 낸다(둘 다 실행해 확인). `unwrap_*` 은 인라인 허용 식이 아니라서 `pick` 은 인라인되지 않는다.
- 브리프가 관찰한 "`.?` 가 none 일 때 쓰레기 값을 읽는" 경우는 이 두 경로가 아니다. 제너레이터 `next()` 결과 쪽 일이며 [07장](07-coroutines-concurrency.md)이 다룬다.

### 5.10 문자열 보간

```
fn label(name str, n int) -> str:
    return 'item %{n} of %{name}!'

s := label('box', 7)
print(s)
```

실행 결과 `item 7 of box!`.

```
--0 `fn label`
0:147 .chk_stk: ret=3, frame=40
0:150 .addr: %20 = *%11          # 리터럴 조각 배열(%11..)의 주소
0:153 .const_str: %21..%24 = 'item ' ascii=true
0:160 .const_str: %24..%27 = ' of ' ascii=true
0:167 .const_str: %27..%30 = '!' ascii=true
0:174 .store_3w: [%20 + 0] = %21     # 조각 3개를 스택 배열에 저장
0:201 .call_host: %31 = int_fmt(%38..%40)   # n 을 문자열로. to_print_string[int] 는 인라인되어 호스트 호출만 남았다
0:212 .copy_str: %33..%36 = copy [%36]       # name 복사: 3워드 복사 + retain 이 한 명령어
0:267 .call_host: %26 = interpolate(%33..%35)   # 조각 배열과 인자 배열을 한 번에 이어 붙이는 네이티브 함수
0:272 .mov_3: %0 = %26           # 결과 str 3슬롯을 반환 슬롯에
0:278 .call: core.@destruct(%30..%31) 8         # 임시 배열 소멸
0:296 .ret_n: ret %0..%3
```

- 결정 문서(`project_string_interpolation.md`)의 구조가 그대로 보인다. 조각 배열 `[N+1]str` 과 인자 배열 `[N]str` 을 스택에 만들어 `str.interpolate` 에 넘기고, `interpolate` 는 `call` 이 아니라 `call_host`(`#[bind='str.interpolate']` `core.cy:3312`, 구현은 `src/builtins/string.zig:37`)다.
- `copy_str` 은 이 fork 가 넣은 명령어(`72f4ecef`)다. 그 전에는 `@copy[str]` 함수 호출이었다.
- `label` 이 인라인되지 않은 이유는 확인하지 못했다(미확인). 호출 지점은 `0:82 .call: %1..%4 = e9_interp.label(%8..%12) 0` 이다.

### 5.11 인라인된 본문의 패닉: 스택 트레이스 복원

```
fn div(a int, b int) -> int:
    return a / b

print(div(5, 0))
```

```
--start
0:72 .const_16s: %2 = 5
0:75 .const_16s: %3 = 0
0:78 .idiv: %1 = %2 / %3         # div 가 인라인되어 main 안에 idiv 가 있다. call 은 없다
```

실행하면 다음과 같다(경로는 줄였다).

```
panic: Division by zero.

p2_trace.cy:2:12 div:
    return a / b
           ^
p2_trace.cy:4:7 main:
print(div(5, 0))
      ^
```

패닉이 난 `idiv` 는 main 의 바이트코드 안에 있는데 트레이스에는 `div`(2행)와 `main`(4행) 두 프레임이 나온다. 인라인된 본문의 디버그 심볼이 callee 프레임과 callee 소스 위치(`2:12`)를 가리키고, `inline_sites` 가 이 pc 구간을 알려 주어 `allocStackTrace`(`debug.zig:600-609`)가 호출 지점(`4:7`)의 caller 프레임을 덧붙이기 때문이다. 인라인된 함수 안의 진짜 `call` 이 패닉하는 경우도 같다. `return div(x, 0) + 1` 인 `outer` 가 main 에 인라인되고 그 안의 `call div` 가 패닉하면 `div`, `outer`, `main` 세 프레임이 나온다(실행해 확인).

### 5.12 변형 과제

1. 5.1 의 `calc` 를 `3 + c + a * b` 로 바꿔 `reg_end` 변화와 임시 재사용을 2.5절 표 형식으로 직접 추적해 보라. `3 + c` 는 `add_i16` 로 낮아질까? (`gen_add` 는 오른쪽 피연산자만 본다.)
2. 인라인 한도를 찾아라. `fn f(x int) -> int: return x + 1 + 1 + ... + 1` 에서 `+ 1` 의 개수를 늘리며 `y := f(7)` 의 덤프에 `call` 이 나타나는 시점을 본다. 이 환경에서는 18개까지 인라인되었고 19개에서 `call` 이 나타났다(IR 노드 40개 한도, `bc_gen.zig:1461`).
3. 5.5 의 `probe` 에서 `while` 루프를 지우고 다시 실행하라. `probe` 가 main 에 인라인되어 `dump_frame` 이 main 의 프레임을 찍는다. 반환 슬롯이 없어 locals 가 `%4` 부터 나오고 `x` `y` 가 `%4` `%5` 에 있다(실제로 실행해 확인한 변형이다).
4. 5.3 의 `sum_to` 루프 본문에 `s += 1` 을 반복해 넣으며 컴파일러가 죽는 지점을 찾아라. 6000번 반복은 통과하고 9000번에서 죽는다(7절).
5. (읽기) `-Dtrace=true` 로 빌드한 CLI 에서 `cyber -v x.cy > out.txt 2>&1` 후 `rg 'bc_gen:' out.txt` 를 보라. `reserve reg: N 타입`, `trunc regs to: N, cur=M`, `pushCode: 명령어 pc` 줄이 2.5절의 `reg_end` 움직임을 그대로 기록한다. 7만 줄이 넘으니 반드시 파일로 받는다.
6. (설계) 5.2 의 "작은 음수는 `const_64`" 를 `const_16s` 로 내리려면 `genConstInt` 의 조건 한 곳을 `val >= std.math.minInt(i16)` 로 바꾸면 충분한지, `vm.c` 의 `CONST_16S` 가 이미 부호 확장을 하므로 안전한지 생각해 보라(구현은 하지 않는다).

## 6. 0.3 -> 0.4 변경 관점 / 설계 철학 메모

`git show 0.3:src/bytecode.zig`, `0.3:src/vm.c`, `0.3:src/vm.h` 와 현재를 비교한 결과다.

| 항목 | 0.3 | 0.4 (HEAD) |
|---|---|---|
| 명령어 단위 | `Inst = packed struct { val: u8 }` (`bytecode.zig:749`) | `u16`. `53e37ed6`(2025-12-13) "Increase inst size to 2 bytes. Fixes perf regression." 그 직전에도 레지스터는 16비트였으나 바이트 조립 읽기(`READ_U16`)였다 |
| opcode 수 | 112 | 132 |
| 레지스터 | `u8`(`u8 ret = pc[1]`). 프레임당 256개 | `u16` 슬롯 번호. 즉치는 i16/u32/u48/u64 |
| 피연산자 순서 | 목적지가 마지막(`stack[pc[3]] = ...`) | 목적지가 처음(`stack[pc[1]]`). 단 `store_*` 는 포인터가 처음 |
| 값 표현 | NaN-boxing 64비트 값(`TAGGED_VALUE_MASK`), 정수 48비트(`_BitInt(48)`) | 태그 없는 8바이트 슬롯, 64비트 정수(wrap) |
| 명령어 의미 | 동적 타입: `addInt` `addFloat`, `callSym` `callObjSym`, 인라인 캐시 `callFuncIC` `fieldIC` | 정적 타입: `add` `fadd` `fadd32`, `call`(주소 직접), `load_*` `store_*`(바이트 오프셋) |
| 컬렉션 | 전용 opcode `list` `map` `indexList` `indexMap` `sliceList` | 전용 opcode 없음. `Array` `Map` 은 `core.cy` 코드와 일반 load/store (옛 흔적이 `bytecode.zig:1085-1097` 주석으로 남음) |
| 호출 | `call ret numArgs`, callee 를 레지스터에서 읽음. `CALL_INST_LEN 4`, `CALL_ARG_START 5`, `CALLEE_START 4`. `Ret1` 이 retFlag 검사 | `call base, u48`. `CALL_INST_LEN 5`, `CALL_ARG_START 4`, `CALLEE_START 3`. 반환 슬롯 N개를 `chk_stk` 가 프레임 앞으로 |
| 힙/소유권 | `box`, `boxValue`, 값마다 `retain`/`release` | `new`, `retain`, `release` + 컴파일러가 심은 소멸자 호출, `dtor_str`, `copy_str` |
| 예외, 코루틴 | `pushTry` `popTry` `throw`, `coinit` `coyield` `coresume` `coreturn` | 없음(패닉만). `ret_gen` `ret_y` `gen_next` `gen_end` `await_op` |

설계 철학을 정리하면 이렇다.

1. 정적 타입이 명령어를 단순하게 만든다. 값에 태그가 없으니 검사도 박싱도 없다. 대가는 명령어 종류의 증가(f32 변종, 폭별 load/store, 부호별 비교)와 좁은 정수의 폭 정리를 소비 지점에 미룬 규약이다(2.6절).
2. 호출 규약이 레지스터 윈도우 방식이라 인자와 반환값을 복사하지 않는다(2.7절). 대가는 스택이 하나의 연속 배열이라 커질 때 재배치와 포인터 패치가 필요하다는 점이고, 이 패치 장치(`ptr_table`)가 가장 허술한 곳이었다(7절, 2026-11-08 `c94f1569` 로 수정).
3. 코드 생성은 한 번의 재귀 패스에서 레지스터를 즉석 배정하는 단순한 구조다. 최적화는 `gen_*` 안의 국소 패턴 매칭(`add_i16`, `add_mul_i16`)과 인라인뿐이고 공통 부분식 제거나 `addr` 재사용이 없다(5.6절의 `dist2`).
4. opcode 추가는 가볍다. 이 fork 의 두 사례가 보여 주듯 vm.h, vm.c, bytecode.zig, bc_gen.zig 네 파일이면 된다. JIT 는 맞추지 않기로 결정되어 있다.

이 코드를 인수해서 건드릴 사람에게 다음 후보를 적어 둔다. 모두 이 장에서 관찰한 사실에서 나왔고 구현은 하지 않았다.
- 7절의 버그들, 특히 스택 이동 때 포인터 패치(main 프레임과 `call_ptr` 계열)와 `mainStackSize` 읽는 순서.
- 덤프(`write_inst`)를 `pc[k].val` 방식으로 일괄 정리. 디버깅 비용이 가장 싸게 줄어드는 작업이다.
- 상수 개선: 음수 즉치(`const_16s`), 뺄셈 즉치(`x - k` 를 `add_i16 -k` 로), 반복되는 `addr` 의 재사용.
- 인라인 3단계: 결정 문서가 적은 대로 루프 허용(`break`/`continue` 의 `block_offset` 처리 필요)과 중첩 인라인(`InlineSite` 에 부모 구간 추가).
- 한계의 정리: 지역 변수 256개, 점프 16비트, 문자열 리터럴 16비트 길이가 Zig 패닉이나 조용한 오동작으로 나온다. 사용자 오류(`CompileError`)로 바꾸는 것이 에이전트가 생성한 큰 스크립트를 다루는 데 중요하다.

에이전트 루프 관점에서 보면, 스크립트는 짧고 호출이 많으므로 호출 비용(`call` + `chk_stk` + `ret`)과 이를 줄이는 인라인이 효과가 크다. `call` 과 뒤로 가는 `jump` 에 `CHECKPOINT()` 가 있어 연료와 인터럽트가 걸리고(05장), 패닉 트레이스가 인라인에도 보존되므로 에이전트에 오류 위치를 정확히 돌려줄 수 있다. 다만 에이전트가 생성한 코드가 큰 재귀나 깊은 호출을 만들면 7절의 스택 이동 문제를 정면으로 밟는다.

## 7. 알려진 이슈, 문서와 코드의 차이, 미완 지점

모든 재현은 이 저장소의 ReleaseSafe CLI(macOS arm64)에서 실행한 것이다.

### 7.1 스택이 커질 때 스택 포인터가 고쳐지지 않는 경우 (확인된 버그, 2026-11-08 수정)

2026-11-08 `c94f1569` 로 두 구멍 모두 막았다(F-10, `docs/decisions/project_stack_ptr_patch.md`). `growStackPrecise` 의 걷기가 main 프레임까지 패치하고, `gen_call_ptr` · `gen_call_union` · `gen_call_trait` 가 `push_site_ptr_layout` 으로 `ptr_table` 항목을 남긴다. 아래 재현 1 · 2 는 이제 `42` · `20043` 을 낸다(behavior 테스트 `functions/stack_grow_ptr_patch.cy`). 이하는 수정 전 기록이다.

2.9절의 `ptr_table` 은 `growStackAuto`(`thread.zig:857`)가 스택을 재할당할 때 호출 지점별 "스택 포인터 슬롯"을 새 주소로 고치는 데 쓰인다. 두 군데에 구멍이 있었다.

- main 프레임: 거슬러 올라가는 루프가 `while (frame.frame_type() != .init)`(`thread.zig:890`)이라 main 프레임에 도달하면 패치 없이 끝난다. main 의 `&x` 같은 포인터는 이동 후 옛 스택을 가리킨다.
- `call_ptr` / `call_union` / `call_trait` / `gen_next`: `ptr_table` 항목은 `pushCall`(`bc_gen.zig:3127-3133`)만 올린다. 이 호출들이 스택을 키우면 호출한 쪽 프레임의 포인터가 패치되지 않는다.

재현 1 (main 프레임):

```
fn rec(n int) -> int:
    if n == 0: return 0
    k := 0
    while k < 1:
        k += 1
    return rec(n - 1) + k

x := 42
p := &x
print(rec(20000))
print(p.*)
```

```
20000
-6148914691236517206
```

`rec(10)` 으로 줄이면 `10`, `42` 가 나온다(스택이 커지지 않아서). `-6148914691236517206` 은 `0xAAAAAAAAAAAAAAAA` 이고, Zig 안전 빌드가 해제된 메모리에 쓰는 채움 값과 같아서 옛 스택을 읽은 것으로 판단한다(추정).

재현 2 (`call_union`): `rec` 은 위와 같고 아래를 붙인다.

```
type Fn1 = fn(int) -> int

fn via_union(f Func[Fn1], p &int) -> int:
    z := 0
    while z < 1:
        z += 1
    r := f(20000)
    return r + p.* + z

x := 42
print(via_union(rec, &x))
```

기대값은 `20043` 인데 `-6148914691236497205` 가 나온다. `f` 매개변수를 없애고 `r := rec(20000)`(일반 `call`)으로 바꾸면 `20043` 이 맞게 나온다. 일반 `call` 은 `ptr_table` 에 올라 패치되기 때문이다. `call_ptr` / `call_trait` / `gen_next` 는 코드 읽기로 같은 결론을 얻었고 재현은 `call_union` 만 했다. 스택 재할당이 제자리 확장(`alloc.resize`)에 성공하면 포인터가 그대로 유효하므로 이동이 일어나는 크기에서만 재현된다. 05 장의 스택 성장 설명과 함께 읽어야 한다.

### 7.2 컴파일러 한계가 Zig 패닉이나 조용한 오동작으로 나온다 (확인)

| 조건 | 증상 | 원인 |
|---|---|---|
| 한 함수의 지역 변수가 257개 이상 (256개는 통과) | `panic: integer does not fit in destination type` | IR `Local.id` 가 u8 (`ir.zig:452`) |
| 루프 본문이 32767 유닛을 넘음 (`s += 1` 6000번은 통과, 9000번에서 죽음) | 같은 패닉 | 뒤로 가는 `jump` 오프셋 i16 (`chunk.zig:545`). 2026-11-08 `8560b025` 컴파일 오류 `Function body too large.`로 수정(F-09) |
| `if` 본문이 65535 유닛을 넘음 (9000번 통과, 17000번에서 죽음) | 같은 패닉 | `jump_f` 오프셋 u16 (`chunk.zig:480`). 같은 커밋으로 수정 |
| `else` 본문이 32767 유닛을 넘고 `if` 갈래가 실행됨 (`s += 1` 9000번) | 컴파일은 되고 실행에서 `Segmentation fault at address 0xaaaaaaaaaaaaaaaa` | `if` 갈래 끝의 앞 `jump` 를 VM 이 `int16_t` 로 읽어 뒤로 감. 같은 커밋으로 수정 |
| 문자열 리터럴이 65536 바이트 이상 | 패닉 없이 길이가 잘림: 65535 바이트는 `65535`, 65536 바이트는 `0`, 70000 바이트는 `4464` | `const_str` 이 길이를 u64 의 상위 16비트에 담음 (`bc_gen.zig:1272`, `vm.c:628`). 2026-11-08 `10f8290b` 컴파일 오류 `String literal too long.`으로 수정(F-24) |

앞의 세 개는 `Cannot print stack trace` 와 함께 컴파일러가 죽었다. 스크립트를 생성하는 에이전트가 만들 수 있는 입력이다. 2026-11-08 현재 네 줄 모두 컴파일 오류다(F-08 · F-09 · F-24).

### 7.3 `mainStackSize` 가 쓰레기 값을 읽는다 (원인은 추정)

`mainBlock` 은 `popProc` 뒤에 `c.getMaxUsedRegisters()` 를 읽는다(`bc_gen.zig:627-630`). main 이 최상위 proc 이라 pop 후에도 `c.cur_proc` 은 바뀌지 않고 방금 pop 한 슬롯을 가리키는데, Zig 0.17 `ArrayList.pop` 은 비운 슬롯에 `undefined` 를 쓴다(`std/array_list.zig:577`). 안전 빌드에서 `undefined` 는 `0xAA` 로 채워지므로 `max_regs` 는 `0xAAAA = 43690` 이 된다. Trace 빌드의 `cyber -v` 로그가 실제로 `vm: main stack size: 43690` 을 찍는 것을 관찰했다. 원인 연결은 코드를 읽은 추정이다. 영향은 main 스택이 의도(`max_regs`)보다 훨씬 크게 시작하는 것이고 해롭지는 않다. 값을 `popProc` 전에 읽으면 고쳐진다.

### 7.4 덤프 도구와 낡은 코드

- `write_inst` 의 어긋남은 3.3절. `get_pc_func_metadata` 의 `stack_size` 도 같은 원인이다(`debug.zig:59`, 5.5절).
- `ByteCodeBuffer.clear()`(`bytecode.zig:135`)는 존재하지 않는 필드(`unwind_table` 등)를 참조한다. 호출처가 없어 컴파일되지 않을 뿐이다.
- 쓰이지 않는 것(2026-11-06 기준 `consts` / `getOrPushConst` · `labels` / `push_label` · `elseBlocks` · `selectForDstInst` · `DstInst` · `NoErrInst` · `Cstr.none` · `GenValue.constant` 는 삭제됨, F-61): `markers`(덤프 전용), `Cstr.captured` 경로. JIT 쪽 `enter_jit` 는 VM 이 `pc[5]` 를 읽는데 생성기는 3개 피연산자(길이 4)만 낸다(죽은 코드).
- `bc_gen.zig:1463` 의 "Registers are u8 indexed by the VM" 주석은 코드와 맞지 않는다(2.6절).

### 7.5 문서와 코드의 차이

| 문서의 말 | 코드의 사실 |
|---|---|
| 브리프: `ptr_layouts` 는 패닉 시 정리용 | 스택 재할당 때 포인터 패치용이다(2.9절). 패닉 때는 프레임 기록만 하고 지역 변수를 해제하지 않는다(`project_bc_inline.md`) |
| 브리프: `cyber fmt file.cy` 는 포매터 | `src/main.zig` 에서 `std.debug.panic("TODO: Embed src/tools/fmt.cy")`. 실행하면 그 패닉이 난다 |
| 브리프: `-Dvm=zig` 옵션 | `thread.zig:472` 에서 `error.Unsupported` 를 돌려준다. C VM 만 동작한다 |
| `project_array_index_calls.md`: opcode 수 검사 131 | 이후 `copy_str` 로 132 (`bytecode.zig:1238`) |
| `cyber help` 의 "`cyber compile` options:" | 항목이 비어 있다 |

## 8. 이해도 확인 Q&A

### Q1. `beginCall` 은 목적지가 `reg_end - ret_size` 일 때만 반환 슬롯을 재사용한다. 왜 그 조건인가?

A: 피호출자의 반환 슬롯은 `chk_stk` 가 fp 를 `ret_size` 만큼 당긴 결과이므로 항상 `base` 바로 앞에 붙어 있어야 한다. 목적지가 레지스터 스택의 맨 위에 있을 때만 "목적지 바로 뒤에 호출 정보 4칸을 쌓는다"가 성립한다. 지역 변수를 막 선언한 직후(`r := f(x)`)가 그 경우라 `mov` 가 사라진다. 맨 위가 아니면 새 임시를 예약하고 `endCall` 이 `push_mov` 로 옮긴다. 목적지가 0번 슬롯인 경우(자기 반환 슬롯)는 이 최적화에서 제외된다.

### Q2. 인자를 복사하지 않는 호출 규약의 대가는 무엇인가?

A: 세 가지다. (1) 프레임 크기를 호출 전에 알아야 하는 것이 아니라 호출 후 `chk_stk` 가 검사하므로 모든 함수가 `chk_stk` 를 갖는다. (2) 스택이 하나의 연속 배열이라 커질 때 재배치가 일어나고, 슬롯 안의 스택 포인터를 호출 지점마다 기록해 두었다가 고쳐야 한다(`ptr_table`). 기록이 누락되면 7.1절처럼 해제된 메모리를 읽는다. (3) 정적 호출(`call`)에서는 callee 슬롯 1칸이 쓰이지 않고 낭비된다(클로저와 trait 호출만 쓴다).

### Q3. 작은 함수를 인라인하면 패닉 스택 트레이스가 달라지지 않는가?

A: 달라지지 않게 만들었다. 1단계는 "인라인 본문은 패닉할 수 없다"는 조건으로 지켰고(나눗셈, 캐스트 거부), 2단계는 조건 대신 디버그 정보로 지킨다. 인라인된 본문의 디버그 심볼이 callee 프레임(`frameLoc`)과 callee 소스 위치를 가리키고, `InlineSite` 가 pc 구간과 호출 지점을 기록해 `allocStackTrace` 가 callee 프레임 뒤에 caller 프레임을 하나 더 붙인다(5.11절 실험이 `div` 와 `main` 을 보인다). 한계는 인라인 안의 인라인이 없어 구간이 겹치지 않는다는 전제에 있다. 중첩 인라인을 허용하려면 `InlineSite` 에 부모 정보를 넣어야 한다.

### Q4. `x - 1` 은 두 명령어인데 `x + 1` 은 한 명령어다. 왜이고 어떻게 고치겠는가?

A: `gen_add` 에만 즉치 패턴이 있고 IR 의 `sub` 는 `genBinOp2` 로 곧장 가기 때문이다. 고치려면 `sub` 용 생성 함수에서 오른쪽이 `const64` 이고 `-k` 가 i16 범위일 때 `add_i16 d, a, -k` 를 내면 된다. 경계에 주의해야 한다. `k = -32768` 이면 `-k = 32768` 이 i16 에 들어가지 않으므로 그 경우만 제외한다. 새 opcode 는 필요 없다.

### Q5. 새 명령어를 `vm.h` enum 중간에 끼워 넣고 `jumpTable` 의 끝에 `JENTRY` 를 추가하면 어떻게 되는가?

A: `STATIC_ASSERT` 는 테이블 크기만 검사하므로 통과한다. 그러나 opcode 번호는 enum 위치에서 오고(Zig 쪽 `OpCode` 도 `vmc.CodeXxx` 값을 쓴다) 점프 테이블은 위치로 인덱싱되므로, 끼워 넣은 지점 이후의 모든 opcode 가 한 칸씩 어긋난 `CASE` 로 간다. 증상은 엉뚱한 명령어 실행이다. enum 과 `JENTRY` 를 같은 위치에 넣는 것이 규칙이다.

### Q6. 5.3절 `jump: jmp @65674` 의 실제 목적지는 어디이고, VM 은 어떻게 그곳으로 가는가?

A: pc 138(루프 맨 위의 `lt`)이다. 덤프가 오프셋을 u16 으로 읽어 `jump < 0` 분기가 실행되지 않아 `153 + 65521 = 65674` 로 찍힌 것이고, 실제 명령어의 피연산자는 `-15` 를 비트캐스트한 `0xFFF1` 다. VM 의 `JUMP` 는 `(int16_t)pc[1]` 로 읽어 `pc += -15` 한다(음수일 때는 `CHECKPOINT()` 를 먼저 실행한다). 따라서 `65674 - 65536 = 138`.

### Q7. 재귀 함수 `fib` 를 덤프하면 호출 구조가 잘 안 보인다. 호출 구조를 보여 주는 예제를 만들려면?

A: 인라인 조건을 깨는 구성을 넣는다. 루프(`while`)를 한 번 넣거나, `else` 가 있는 if 사슬(`break` 가 생김)을 쓰거나, `unwrap` 계열 식을 쓴다. IR 노드가 40개를 넘기는 방법(5.12절 변형 2)도 있다. 인라인은 `inline_ctx == null` 일 때만 일어나므로 인라인된 본문 안의 `call` 은 진짜 `call` 로 남는다는 점도 이용할 수 있다.

## 9. 더 알아보기

- 키워드: register-based VM, destination-driven code generation, register window, relocation, inline site, `CHK_STK`, computed goto 디스패치.
- 이어서 읽을 장: [05. VM 실행 루프](05-vm-runtime.md)에서 이 장의 `call`, `chk_stk`, `ret`, `jump` 를 `vm.c` 로 실행해 본다. 호스트 호출, 패닉과 언와인드, 스택 성장은 05, 소멸자와 `release` 삽입 정책은 [06. 메모리와 소유권](06-memory-ownership.md), `ret_gen` 계열은 [07. 코루틴](07-coroutines-concurrency.md).
- 앞 장으로 돌아가기: [03. 의미 분석과 IR](03-sema-and-ir.md)의 IR 코드(`ir.zig`)가 이 장의 입력이다.
- 결정 기록: `docs/decisions/project_bc_inline.md`(인라인 1, 2단계), `project_array_index_calls.md`(상수 접기, `add_mul_i16`), `project_string_interpolation.md`, `project_direction.md`(JIT 비대응).
- 다음 날 연결: Day 5 는 이 장이 만든 바이트코드의 실행이다. 특히 7.1절의 스택 이동 문제는 `Thread.growStackAuto` 를 읽으며 다시 만난다.
