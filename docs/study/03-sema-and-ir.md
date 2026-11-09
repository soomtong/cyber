---
aliases: [Sema와 IR, 의미 분석, 컴파일타임 평가]
tags:
  - study
  - cyber
  - compiler
  - sema
  - ir
  - cte
---

# Day 3. 의미 분석(sema), 컴파일타임 평가(cte), 그리고 IR

> 대상 소스: `src/sema.zig`(10,594줄), `src/sema_func.zig`(1,429줄), `src/cte.zig`(2,803줄), `src/ct_inline.zig`(380줄), `src/ir.zig`(1,140줄), `src/compiler.zig`(지휘 부분), `src/chunk.zig`(컨텍스트 필드). 줄 번호는 모두 HEAD b40531a1 기준이다.
> 예상 학습 시간: 4시간 (개념 읽기 1시간 / 소스 탐독 2시간 / 실습 1시간)
> 선행: [01 파이프라인과 프런트엔드](01-pipeline-front-end.md), [02 심볼과 타입](02-symbols-and-types.md)
> 이어지는 날: [04 바이트코드 생성](04-bytecode-gen.md)

## 한줄 요약

sema 는 AST 를 한 번 훑으면서 심볼 해석, 타입 검사, 암시적 변환, 소유권 연산(복사, 이동, 소멸자 삽입)을 동시에 처리하고, 그 결과를 이미 의미가 확정된 저수준 트리형 IR 로 내놓는다. 컴파일타임 평가기(cte)는 컴파일러 안에 들어 있는 별도의 AST 인터프리터이고, 그 값은 `ct_inline` 을 거쳐 IR 상수로 바뀐다.

## 오늘의 학습 목표

- [ ] `sema_program`, `performChunkSema`, `semaChunkFuncs` 가 어떤 순서로 호출되어 main 블록과 모든 함수 본문의 IR 이 만들어지는지 설명할 수 있다.
- [ ] `semaStmt` 와 `semaExprNoCheck` 의 디스패치 구조를 알고, `ExprResult` 와 `Cstr`(기대 타입)가 어떻게 아래로 내려가고 위로 올라오는지 설명할 수 있다.
- [ ] `if`, `for`, `switch`, `!`, `.?`, 연산자, 호출이 각각 어떤 IR 노드 조합으로 바뀌는지 `-v` 트레이스에서 직접 확인할 수 있다.
- [ ] 오버로드 해석(`matchFuncSym`)과 템플릿 함수 확장 호출이 어떻게 동작하는지, 그리고 그 한계(첫 번째로 맞는 오버로드 선택, IR 롤백 미완)를 말할 수 있다.
- [ ] cte 가 무엇을 실행할 수 있고(`const`, `#if`, `#for`, `type X const:`) 무엇을 못 하는지(예: `while`), 그리고 cte 의 복합 대입 버그를 재현할 수 있다.
- [ ] `ir.zig` 의 `Stmt`/`Expr` 메모리 모양과 노드 종류를 읽을 수 있고, 소유권 연산이 이미 IR 에 박혀 있다는 설계 의도를 코드로 확인할 수 있다.
- [ ] 컴파일 에러 메시지에서 출발해 어느 sema 함수가 보고했는지 `rg` 와 트레이스 로그로 거슬러 올라갈 수 있다.

## 1. 왜 이것이 필요한가?

AST 는 소스의 문법 구조일 뿐이다. 예를 들어 `a + b` 라는 `binExpr` 노드만 봐서는 이것이 정수 덧셈 한 명령인지, `P` 타입의 `+` 메서드 호출인지, 문자열 이어붙이기인지 알 수 없다. `x` 라는 `ident` 가 지역 변수인지 전역인지 함수인지 타입인지도 모른다. 어디에서 문자열을 해제해야 하는지, 어느 값을 복사하고 어느 값을 옮길지는 더더욱 모른다. sema 는 이 모든 것을 확정한다.

Cyber 0.4 에서는 이 일이 특히 무겁다. 정적 타입, 템플릿, 소유권(own/borrow), 컴파일타임 실행이 모두 sema 안에서 만난다. 그래서 sema 는 다음 세 가지를 한꺼번에 한다.

1. 이름 해석과 타입 검사: `lookupIdent`, `semaExpr`, `matchFuncSym`
2. 의미가 확정된 중간 표현(IR) 생성: `c.ir.newExpr(...)`, `c.ir.pushStmt(...)`
3. 수명 연산 삽입: `semaOwn`, `sema_copy`, `semaDestructLocal`, `popLocals`

`ir.zig` 상단 주석(`src/ir.zig:8-18`)이 IR 을 둔 이유를 직접 밝힌다. 번역하면 다음과 같다.

- IR 은 sema 의 결과를 담기에 AST 가 적합하지 않아서 필요하다.
- IR 이 타입 검사, 수명(lifetime), ARC, 소멸자 같은 무거운 일을 대부분 맡고, 코드젠은 단순 번역만 하게 한다.
- 정적 타입과 심볼이 있으면 일부 문장과 식은 의미가 없어진다(예: `const` 선언은 IR 이 필요 없다).
- 파라미터 복사와 변수 캡처는 나중에 알게 되므로 되돌아가 채워 넣는(backpatching) 자리가 필요하다.
- 관리되는 임시값을 지역 변수로 빼내기, 값 복사, retain/release, 정적 변수 초기화, 0 값 같은 IR 을 추가할 수 있다.
- 바이트코드 백엔드와 C 백엔드를 더 단순하게 만들고, 새 백엔드를 추가하기도 쉽게 한다.

대안과 비교하면 다음과 같다. 일반 지식으로, TypeScript 컴파일러의 binder + checker 는 AST 에 심볼과 타입을 덧붙이는 방식이라 AST 는 그대로 남고 이후 emit 단계가 AST 를 다시 읽는다. Cyber 는 sema 가 아예 새 트리(IR)를 만들어 내고 AST 는 에러 위치(각 IR 노드가 들고 있는 `node` 포인터)에만 쓴다. 장점은 코드젠이 얇아진다는 것이고, 단점은 sema 가 "검사 + 변환 + 수명 삽입"을 한 패스에서 다 하느라 `sema.zig` 가 10.6K 줄로 커졌다는 것이다. 이 단점은 7절에서 구체적인 증상으로 다시 만난다(예: 오버로드를 시도하다 실패하면 이미 만든 IR 을 되돌려야 하는데 그 일이 미완이다).

## 2. 근본적인 동작 원리

### 2.1 sema 는 언제 불리는가

컴파일러 지휘자 `Compiler.compileInner`(`src/compiler.zig:315-531`)에서 sema 와 직접 관련된 부분만 발췌한 흐름이다.

```
compileInner
  ... 청크 로드 + resolveChunkSyms (심볼 선언 해석. 02 챕터)
  reserve_hidden_func("@program_init"), ("@program_deinit")        compiler.zig:425-426
  emit_program_init_func / emit_program_deinit_func                compiler.zig:429, 431
  program_ir = sema.sema_program(mainChunk, main_func)             compiler.zig:435
      "Generate main first to expand any templates."  (433행 주석)
  for chunk in newChunks(): performChunkSema(chunk)                compiler.zig:439
      ├─ (has_static_init) emit_chunk_init_func / emit_chunk_deinit_func   :653-659
      └─ semaChunkFuncs(c): c.funcs 를 '인덱스로' 순회                      :664-699
            userFunc  → 메서드면 semaMethodBody, 아니면 semaFuncBody
            건너뜀: const_eval_only 함수, 이미 emitted 인 함수(@init 등)
  trait 구현 검사 (struct.impls 마다 모든 trait 메서드 구현이 있는지)   :453-489
  bcgen.genAll(self)                                               :520
```

읽을 때 알아둘 점이 세 가지 있다.

- main 을 먼저 sema 하는 이유는 코드 주석에 있다. main 이 템플릿을 확장하면서 새 함수(`print[int]` 같은 것)가 `c.funcs` 에 추가되고, 그 함수들의 본문은 뒤의 `semaChunkFuncs` 루프가 처리한다. 그래서 루프가 `for` 가 아니라 `while (i < c.funcs.items.len)` 이다(`compiler.zig:665-667`, "lambdas could be appended" 주석).
- 도달 가능성 분석이 없다. 사용하지 않는 함수도 전부 sema 와 코드젠을 거친다. `src/dce.zig` 에 IR 을 방문하는 DCE 가 있지만 `compiler.zig:507` 의 `const enable_dce = false;` 로 꺼져 있다.
- 에러는 "보고하고 중단"이다. `c.reportError(...)` 는 `compiler.reports` 에 리포트를 쌓고 `error.CompileError` 를 반환한다(`src/chunk.zig:637-641`). 이 에러가 Zig 의 `try` 로 호출 스택을 타고 올라가므로 첫 번째 에러에서 컴파일이 멈춘다. 에러 위치는 인자로 넘긴 AST 노드(`node`)가 정한다.

main 블록은 `sema_program`(`src/sema.zig:4555`)이 만든다.

```
sema_program
  program_block = ir.newStmt(.mainBlock)          IR 스텁을 먼저 만들고 func_blocks 에 등록
  pushProc(c, null)                               func == null 이 곧 main 이라는 표시
  call @program_init → discard                    청크별 @init 들을 부르는 숨은 함수
  main() 함수가 있으면: 최상위에는 선언문만 허용, main 호출 한 줄 생성
  없으면: semaStmts(root.stmts)                   스크립트 본문 전체
  endReachable 이면 sema_program_deinit           call @program_deinit
  popProc → stmtBlock                             program_block.bodyHead = stmtBlock.first (스텁 채우기)
```

`main` 이 선언되어 있으면 최상위에 선언 외 문장이 있을 때 "Body statement is not allowed when main function is declared." 에러가 난다(`sema.zig:4607`). main 블록에서는 `return` 이 금지된다(`sema.zig:754`, `:762`). 프로그램 끝(또는 `main()` 호출 직후)에는 `@program_deinit` 호출이 삽입된다(`sema.zig:872-878`).

함수 본문은 `semaFuncBody2`(`sema.zig:3065`)와 메서드용 `semaMethodBody2`(`sema.zig:3044`)가 같은 틀로 처리한다.

```
pushFuncProc(c, func)         funcBlock 스텁 생성 + func_blocks 등록 + Proc/Block push   sema.zig:4547
appendFuncParamVars(...)      파라미터를 varStack 에 지역으로 등록 (declareParam)
(generator 면) 참조 파라미터 retain, ret_gen 문장 push                                   :3069-3110
semaStmts(본문)
procPrologue(c)               끝에 닿을 수 있으면 암묵 return 삽입, void 가 아니면 "Missing return statement."   :9115
popFuncBlock(c)               스텁에 bodyHead, params 를 '덮어써서' 채움 (backpatch)       :9147
```

### 2.2 sema 가 들고 다니는 컨텍스트

sema 의 상태는 전역 하나가 아니라 청크(`Chunk`, 파일/모듈 단위)에 붙어 있다. 타입 레지스트리 같은 전역 모델은 `Sema` 구조체(`sema.zig:9272`)에 있고, 이는 02 챕터의 주제다. 여기서는 문장과 식을 처리할 때 쓰는 청크 필드만 본다(`src/chunk.zig:28-215`).

| 필드 | 역할 |
|---|---|
| `ir: ir.Buffer` | IR 노드를 담는 arena, 문장 리스트 스택 `stmtBlockStack`, 함수/메인 블록 목록 `func_blocks` |
| `semaProcs: ArrayList(Proc)` | 지금 sema 중인 함수/람다/main 의 중첩 스택. `c.proc()` 이 맨 위 |
| `semaBlocks: ArrayList(Block)` | 렉시컬 블록 스택. `c.block()` 이 맨 위, `c.procBlock()` 은 현재 함수의 첫 블록 |
| `varStack: ArrayList(Local)` | 지금 살아 있는 모든 지역 변수. 숨은 임시값(`_opt`, `_temp`)도 여기에 들어간다 |
| `varShadowStack` | 안쪽 블록에서 같은 이름을 선언했을 때 바깥 변수를 복원하기 위한 기록 |
| `resolve_stack: ArrayList(ResolveContext)` | "누가 무엇을 해석 중인가"와 컴파일타임 변수(`ct_params`). 템플릿 확장, cte 가 사용 |
| `funcs` | 이 청크가 소유한 모든 `*Func`(람다 포함). `semaChunkFuncs` 가 순회 |
| `cur_sema_proc`, `curNode` | 현재 Proc 캐시, 에러 보고용 "지금 보고 있는 AST 노드" |
| `temp_access_path` | 구조체 필드 이동(move)의 접근 경로 추적 |

`Proc`(`sema.zig:219`), `Block`(`:178`), `Local`(`:102`)의 핵심 필드만 추리면 다음과 같다.

```
Proc   { func: ?*Func (null 이면 main), numParams, captures, var_cache_entries(이름→변수),
         block_start, block_depth, varStart, isMethodBlock, ir: *ir.Stmt (funcBlock 스텁) }
Block  { varStart, node, endReachable, loop, pre_continue_block, loop_has_break }
Local  { type(.local|.dead), decl_t, lifetime, active_borrows, parent_local,
         inner.local = { id(IR 로컬 번호), isParam, hasInit, hidden, declIrStart } }
```

여기서 `Local.type == .dead` 가 중요하다. 이동(move)되었거나 아직 초기화 전인 변수를 `.dead` 로 표시해 두면 `semaLocal`(`sema.zig:4003`)이 접근 시 "`x` is no longer alive in this scope." 에러를 낸다. 소멸자 삽입도 `.local` 인 것만 대상이 된다(`semaDestructLocal`, `:4703`). 즉 소유권 규칙의 핵심인 이동 추적이 이 표시 하나로 구현된다.

IR 을 쌓는 방식은 스택이다. 블록을 열면 문장 리스트 하나가 새로 시작되고, 닫으면 그 리스트의 머리를 돌려받는다.

```
pushBlock(c, node)                                  sema.zig:4862
   ├─ c.ir.pushStmtBlock()        새 문장 리스트 {first=null,last=null} 를 stmtBlockStack 에 push
   ├─ proc.block_depth += 1
   └─ semaBlocks.append(Block)
         ... semaStmts(...) : c.ir.pushStmt(.set_local, ...) 는 '맨 위 리스트의 끝'에 붙는다 ...
popBlock2(c, destruct_locals)                       sema.zig:4810
   ├─ (필요하면) semaDestructBlock : 이 블록의 지역을 역순으로 돌며 release/소멸자 호출 문장 push
   ├─ varStack 을 b.varStart 로 되돌리고, 가려졌던 변수 복원
   └─ return c.ir.popStmtBlock()  → {first,last}   호출자가 body_head = block.first 로 사용
```

예를 들어 `while` 은 `pushBlock` → 조건 → `pushBlock` → 본문 → `popBlock2` → `pushStmt(.if_block, body_head=block.first)` → `popBlock` → `pushStmt(.loop_block, ...)` 순서로 만든다. 즉 문장 리스트가 곧 중첩 구조이고, 각 IR 문장은 `next` 포인터로 같은 리스트의 다음 문장을 가리킨다.

한 가지 주의할 점은 로컬 번호다. IR 의 `local.id`(u8)는 "현재 함수의 `varStack` 구간 안에서의 위치"(`local_id = varStack.len - proc.varStart`, `sema.zig:3409`)이고, 블록이 끝나 `varStack` 이 줄어들면 같은 번호가 재사용된다. 이 번호는 이후 바이트코드 단계에서 레지스터로 매핑된다(04 챕터).

### 2.3 ExprResult 와 Cstr: 위로 올라오는 것과 아래로 내려가는 것

sema 의 모든 식 함수는 같은 모양이다. 입력은 AST 노드와 `Cstr`(constraint, 기대 조건), 출력은 `ExprResult` 이다.

```zig
// src/sema.zig:3735-3755 (발췌)
pub const Cstr = struct {
    reqTypeCstr: bool = false,   // 타입이 안 맞으면 에러로 할 것인가
    fit_target: bool = false,    // target_t 로 암시적 변환을 시도할 것인가
    use_as_borrow: bool = false,
    assign_to_local: bool = false,
    return_infer_error: bool = false,  // 오버로드 시도 중이면 에러 대신 infer_error 를 반환
    allow_ct_sym: bool = false,
    target_t: ?*cy.Type = null,  // 기대 타입(없을 수 있음)
```

`Cstr` 는 위에서 아래로 "이 자리에는 이런 타입이 오면 좋겠다"를 전달한다. 만드는 헬퍼가 네 가지 있다(`sema.zig:6271-6293`).

| 헬퍼 | target_t | fit_target | reqTypeCstr | 용도 |
|---|---|---|---|---|
| `semaExprHint` | 있음 | false | false | 이항식의 왼쪽처럼 힌트만 |
| `semaExprTarget` | 있음 | true | false | 변환은 시도하되 실패해도 에러는 아님 |
| `semaExprCstr` | 있음 | true | true | 조건식(`bool`), 대입 오른쪽 등 반드시 맞아야 함 |
| `semaExpr(c, node, .{})` | 없음 | false | false | 타입 추론 |

`ExprResult`(`sema.zig:3587`)는 아래에서 위로 올라오는 값이다.

```zig
// src/sema.zig:3587-3600 (발췌)
pub const ExprResult = struct {
    resType: ExprResultType,   // value, value_local, value_field, sym, varSym, const_, func,
                               // capturedLocal, ct_value, infer_error, pinned_borrow
    type: *cy.Type,
    data: ExprResultData,
    addressable: bool = false, // 지역/필드 등 주소를 가질 수 있는가
    owned: bool = false,       // 소유권이 있는 값인가 (임시값, 새로 만든 값)
    ir: *cy.ir.Expr,           // 이 식이 만든 IR 노드
```

식 하나를 처리한 결과는 "타입 + IR 노드 + 부가 정보(소유 여부, 주소 가능 여부, 출처 지역)"이다. `resType` 이 `value_local` 이면 "이 식은 지역 변수 그 자체"이므로 이동(move)이나 빌림 판단에 쓰인다. `ct_value` 는 컴파일타임에 이미 값이 확정된 결과(IR 이 없음, `ir = undefined`)이며 `ct_inline.value` 를 거쳐 비로소 IR 상수가 된다. `sym` 은 아직 값이 아닌 심볼(타입, 모듈 등)이다.

`semaExpr`(`sema.zig:6304`)는 얇은 래퍼다. 실제 일은 `semaExprNoCheck` 가 하고, 래퍼는 결과 타입을 기대 타입과 맞춘다.

```zig
// src/sema.zig:6304-6331 (발췌)
pub fn semaExpr(c: *cy.Chunk, node: *ast.Node, cstr: Cstr) !ExprResult {
    c.curNode = node;
    const res = try c.semaExprNoCheck(node, cstr);
    if (cstr.target_t) |target_t| {
        if (target_t == res.type) return res;
        if (cstr.fit_target) {
            if (try semaFitTarget(c, res, target_t, node)) |new| return new;
        }
        if (res.type.id() == bt.Never) return res;
        if (cstr.reqTypeCstr) return reportExpectedType(c, target_t, res.type, node);
    }
    return res;
}
```

해석하면 이렇다. 타입이 같으면 통과, 다르고 `fit_target` 이면 `semaFitTarget`(암시적 변환, 2.5절)을 시도하고, 그래도 안 되는데 `reqTypeCstr` 이면 "Expected type `X`, got `Y`." 에러(`reportExpectedType`, `sema.zig:10438`)를 낸다. `Never` 타입(`panic` 같은 반환 안 함)은 어떤 기대 타입에도 통과한다. 이 한 함수가 sema 의 "타입 검사기" 역할을 한다.

### 2.4 문(statement) 디스패치와 대표 경로

`semaStmt`(`src/sema.zig:368-775`)는 `switch (node.type())` 하나다. 분기는 세 부류다.

1. 계속 sema 를 하는 문장: 표현식 문장, `var_decl`, 대입류, 제어 흐름, `return`, `yield`, `ct_stmt`.
2. 아무것도 하지 않는 선언류(`sema.zig:438-454`): `funcDecl`, `struct_decl`, `enumDecl`, `const_decl`, `global_decl`, `use_alias`, `import_stmt`, `template` 등. 선언은 sema 이전의 심볼 해석 단계에서 이미 처리되었기 때문에 본문 순회 중에는 건너뛴다.
3. 나머지는 `else => "Unsupported statement: {}"`(`sema.zig:767`).

Trace 빌드에서는 문장 하나가 끝날 때마다 `check_locals`(`sema.zig:777`)로 `varStack` 길이가 문장 시작 때와 같은지 검사한다(`:770-774`). 각 문장이 자기가 만든 임시 지역을 반드시 정리해야 한다는 불변식을 테스트용으로 강제하는 장치다.

| AST 노드 | 처리 함수 | 만들어지는 IR |
|---|---|---|
| `exprStmt` | `semaExprStmt` (342) | `discard(expr)` + `pop_locals`. void/Never 가 아닌 값은 에러 |
| `var_decl` (`:=`, `var`) | `localDecl` (3450) | `declare_local(init)` |
| `assign_stmt`, `op_assign_stmt` | `semaAssignStmt` (1589) | `set_local`, `set_field`, `set_deref`, `set_global`, `setCaptured` |
| `if_stmt` | `semaIfStmt` (1325) | `block { if_block ... }` |
| `if_unwrap_stmt` | `semaIfUnwrapStmt` (1271) | `block { declare_local _opt, if_block ... }` |
| `whileInfStmt`, `whileCondStmt`, `while_unwrap_stmt` | 인라인 (598-660) | `loop_block` |
| `for_range_stmt` | 인라인 (557-597) | `forRangeStmt` 전용 노드 |
| `for_iter_stmt` | 인라인 (455-556) | `block { 숨은 지역 3개, loop_block { if_block ... } }` |
| `switch_stmt` | `semaSwitchStmt` (5240) | `switch_stmt` + `switch_case` 식들 |
| `returnStmt`, `returnExprStmt` | `semaReturn` (880), `semaReturnExprStmt` (904) | `set_ret`, 소멸자 문장들, `ret` |
| `breakStmt`, `continueStmt` | `semaBreak` (791), `semaContinue` (811) | 소멸자 문장들 + `break_`/`continue_` |
| `yield_stmt` | 인라인 (709-750) | `set_ret` + `yield` (07 챕터) |
| `ct_stmt` (`#if` 등) | `ct_inline.evalStmt` | 고른 분기만 다시 `semaStmt` |
| `tryStmt` | `sema_try_stmt` | `block` 둘 + 본문 `!` 의 `set_local` · `break_` (2026-11-09 F-32 구현. 이전에는 항상 "Unsupported statement: tryStmt") |

`await` 는 문장 노드가 아니다. core.cy 의 `@await_`(`src/builtins/core.cy:4097`)가 `host_builtin` 함수로 연결되어 있고, 그 Zig 구현 `await_`(`src/builtins/core.zig:1508`)가 sema 도중에 `.await_` IR 문장을 직접 push 한다. 같은 메커니즘으로 `gen_next`/`gen_end` IR 식도 `core.zig:1999-2026` 의 호스트 빌트인이 만든다(`sema.zig` 안에는 `newExpr(.gen_next` 가 없다). 이 "Zig 로 IR 을 직접 만드는 함수" 종류가 `host_builtin` 이다(`src/module.zig:344`, 호출 쪽은 `sema_func.zig:362-383`). 코루틴의 의미는 [07 코루틴](07-coroutines-concurrency.md)에서 다룬다.

IR 스케치 표기: `이름 { ... }` 는 문장 리스트를 가진 문장 노드, `이름(a, b)` 는 식 노드와 자식이다. 아래는 코드를 읽고 5절의 `-v` 트레이스(IR 노드가 만들어지는 순서)와 맞춰 본 재구성이며, 함수와 줄 번호는 근거 위치다.

#### (가) 변수 선언: `r := find(5)` — `localDecl`

```
1. reserveLocalName        이름 중복 검사("Variable `a` is already declared in the block."), varStack 에 push
2. declare_local 를 init=null 로 '먼저' push, 변수는 .dead 로 표시 (자기 자신을 초기화식에서 못 쓰게)
3. semaExpr(오른쪽, target = 선언 타입 또는 없음, assign_to_local=true)
4. semaOwn(오른쪽)         소유권 없는 값이면 sema_copy (복사 또는 retain 삽입)
5. 타입을 추론한 경우 declare_local.decl_t 와 Local.decl_t 를 '나중에' 채움       <- backpatch
6. 변수를 .local 로 되살림. 초기화식이 숨은 지역을 만들지 않았으면 declare_local.init = right.ir,
   만들었으면 별도 set_local 문장을 push
7. popLocals(var_start)    초기화식이 만든 임시 지역 정리
```

`declare_local` 을 초기화식보다 먼저 push 하는 이유는 초기화식이 만든 숨은 임시 지역과 문장들이 선언 뒤에 와야 하기 때문으로 보인다(추정). `sema.zig:3450-3536` 에서 위 순서를 그대로 읽을 수 있다. `ir.zig:513` 의 "If null, only reserve the local." 주석이 이 패턴을 뜻한다.

#### (나) 대입: `semaAssignStmt` 의 왼쪽 종류별 분기

`semaAssignStmt`(`sema.zig:1589`)는 왼쪽 AST 의 종류로 갈린다.

| 왼쪽 | 처리 | IR |
|---|---|---|
| `ident` (지역) | 오른쪽을 `Cstr.initRequire(변수 타입)` 로 평가 → `semaOwn` → managed 타입이면 `_temp` 숨은 지역에 담고 기존 값에 소멸자 호출을 먼저 push | `set_local` |
| `ident` (필드/전역/캡처) | 위와 비슷하게 평가 | `set_field`, `set_global`(`semaAssignToGlobal`, 1560), `setCaptured` |
| `a.b` (`accessExpr`) | `semaAssignToAccessStmt` (1464). 필드가 없으면 `@set` 훅을 찾음 | `set_field` (managed 필드는 `_res`, `_temp` 로 기존 값 소멸 후 이동) |
| `a[i]` (`index_expr`) | `semaAssignToIndexStmt` (1395). `@set_index` 가 있으면 그 호출, 없으면 `@index_addr` 로 포인터를 얻어 | 호출 또는 `set_deref` |
| `p.*` (`deref`) | 포인터 또는 빌림의 자식 타입으로 평가 | `set_deref` |

참조형 파라미터에 쓰는 경우 `"TODO: Write to a reference parameter."` 에러가 난다(`sema.zig:1714`). 복합 대입 `x += e` 는 `op_assign_stmt` 노드를 그대로 `right` 로 넘기고(`430`), 오른쪽 평가 때 `semaExprOrOpAssignBinExpr`(`7623`)가 `semaBinExpr(left, op, right)` 로 바꿔 평가한다. 즉 `x += e` 는 `x = x + e` 와 같은 경로를 탄다. 인덱스 대입에서는 `binExpr` AST 노드를 합성한다(`1604`).

managed 타입(문자열, 슬라이스 등) 대입이 "새 값을 `_res` 에 담기 → 기존 값을 `_temp` 로 꺼내 소멸 → 이동" 순서인 점은 06 챕터의 소유권 규칙과 연결된다. 새 값을 먼저 다 계산해 두고 나서 기존 값을 해제하려는 순서로 보인다(`s = s + 'x'` 처럼 새 값이 기존 값을 읽는 경우를 위한 것이라는 점은 추정).

#### (다) 조건문과 루프

`if` 는 IR 에 `else` 가 없다. 바깥 `block` 하나에 `if_block` 을 나열하고, 마지막이 아닌 본문 끝에 `break_`(바깥 블록 탈출)를 넣는다(`semaIfBlock`, `sema.zig:1022-1040`, `semaIfStmt`, `:1325-1365`). 실제 트레이스(`if x > 0: ... else x < 0: ... else: ...`)의 IR 생성 순서도 `cmp`, `const64`, `set_ret`, `ret`, `break_`, `if_block` 이 두 번 반복된 뒤 else 본문 `const64`, `set_ret`, `ret`, 마지막에 `block` 이었다.

```
if c1: A                                block
else c2: B             ====>              if_block cond=c1 { A; break_(바깥) }
else: E                                   if_block cond=c2 { B; break_(바깥) }
                                          E
```

`while` 은 `loop_block` 안의 `if_block` 이고, 본문 끝에 `continue_` 가 붙는다(`sema.zig:615-637`). 조건이 거짓이면 `if_block` 을 지나쳐 `loop_block` 끝에 닿는 것이 곧 탈출이다. `while:` (조건 없음)은 `if_block` 없이 본문 뒤에 `continue_` 만 있다. `break_`/`continue_` 는 `block_offset`(현재 함수의 첫 블록에서 목적지 블록까지의 거리, `ir.zig:78-90`)를 갖고, 나가기 전에 지나가는 블록들의 지역에 소멸자 호출을 먼저 push 한다(`semaBreak`, `sema.zig:791-801`).

`for 0..n |i|` 는 전용 노드 `forRangeStmt` 다(`sema.zig:557-597`). 시작은 `semaExprTarget(start, i64)`, 끝은 시작과 같은 정수 타입으로 `semaExprCstr` 하고, 정수가 아니면 "Expected integer type." 에러를 낸다.

`for list |it|` 같은 이터레이터 루프(`sema.zig:455-556`)는 AST 안에서 풀려서 여러 문장이 된다.

```
block
  declare_local _iterable = address_of(list)        참조형이 아니면 &빌림으로 보관
  declare_local iterator  = call(iterable.iterator())
  declare_local _counter  = const64 0
  loop_block
    declare_local _opt = call(next(&iterable, &iterator))     semaIfUnwrapBlock2 가 만든다
    if_block cond = lnot(is_zero(field(local _opt, 0)))
      declare_local it = field(local _opt, 1)                 Option 의 payload
      block { 사용자 본문 }
      (count 변수가 있으면 _counter += 1)
      continue_
```

즉 이터레이터 프로토콜(`iterator()` 와 `next()`)은 sema 에서 일반 메서드 호출로 푼다. 5.3 에서 `for list |it|` 트레이스로 같은 모양을 확인한다. Option 의 태그가 `field idx=0`, payload 가 `field idx=1` 이라는 점(`semaIsNone`, `sema.zig:7736`)이 2.5절 `.?` 이야기와 이어진다. `while next() |v|` (`while_unwrap_stmt`)와 `if opt |v|` 도 같은 `semaIfUnwrapBlock2` 의 조각이다.

#### (라) switch

`semaSwitchStmt`(`sema.zig:5240`)는 먼저 제어식을 평가해 `&제어식` 을 `control` 숨은 지역에 담는다. choice 타입이면 태그를 `_choice_tag` 지역에 뽑는다(`:5303-5313`). 각 `case` 는 `switch_case` 식(`ir.SwitchCase`: `conds`, `body_head`, `fallthrough`)이 되고, 마지막에 `switch_stmt{cases}` 하나가 push 된다.

- case 조건은 컴파일 타임에 평가된다. `semaCaseCond`(`:5630`)가 `cte.evalTarget` 으로 조건을 값으로 만든 뒤 `ct_inline.value` 로 IR 상수화한다. 그래서 `case k:` 에 런타임 지역 변수 `k` 를 쓰면 "Could not find the symbol `k`." 에러가 난다(5.4 에서 재현, `cte.zig:1950`).
- 범위 `case 3..9:` 는 `>=` 와 `<=` 비교를 `semaLogicAnd2` 로 묶은 식이 된다(`:5653-5678`).
- choice 의 `case .line |l|:` 은 `_choice_tag == 상수` 비교(`case_cond`)와, 본문 맨 앞에서 `field(control, 1)` 로 payload 를 복사하는 `declare_local l` 이 된다(`:5507-5538`). 5절 트레이스 참고.
- enum/choice 는 모든 case 를 다뤘는지 검사한다. 빠지면 "Unhandled cases in `switch`." (`:5417`), 그 외 타입은 `else` 가 없으면 "Expected `else` case since switch does not handle all cases." (`:5424`).
- `switch` 안의 `#for` 는 컴파일 타임에 case 들을 펼친다(`:5322-5386`).

#### (마) return, yield, try

`return expr` 는 `semaReturnExprStmt`(`sema.zig:904`)가 처리한다. 순서는 (1) 반환 타입을 기대 타입으로 식 평가 (2) `semaOwn` (3) `set_ret` push (4) 함수 최상위 블록의 모든 지역에 대한 소멸자 호출을 `semaDestructBlock2` 로 push (5) `ret` push 다(`semaReturnExpr`, `:829-869`). 소멸자가 `ret` 앞에 이미 박혀 있으므로 코드젠은 "ret 에서 정리"를 생각할 필요가 없다. `ret_expr`(소멸자가 없을 때 한 문장으로 합치는 최적화) 노드는 존재하지만 sema 가 만들지 않는다(`:857` 의 TODO).

fork 가 추가한 최적화가 하나 있다. 반환하는 식이 소유권 없는 managed 지역 변수 이름 하나(`return s`)면 복사 대신 이동한다(`implicitReturnMoveLocal`, `sema.zig:994-1019`, 커밋 eb060d5e). 지역을 `.dead` 로 표시한 채 소멸자를 생성하므로 그 지역은 소멸자 대상에서 빠진다.

`try ... else err:` 문은 파서가 AST 를 만들지만(`parser.zig:1862`) sema 가 거부했다(`sema.zig:673-678`). 5절에서 재현한다. 2026-11-09 F-32 로 `try: … else |err|: …` 가 구현됐다(`sema_try_stmt`, `docs/decisions/project_try_block.md`). 오류는 값이므로 런타임 catch 가 아니라 본문 안 `!` 의 오류 분기를 `else` 블록으로의 `break_` 로 바꾸는 변환이다. 그 밖의 에러 처리 경로는 변함없이 `!`/`!else`/`Result` 식이다.

### 2.5 식(expression) 디스패치와 대표 경로

`semaExprNoCheck`(`sema.zig:6334-7465`)가 식 AST 종류별로 갈리는 거대한 `switch` 이고, 입구에서 `lambda_cont_expr` 만 따로 푼다. 부류를 지도처럼 나누면 다음과 같다.

| 부류 | AST 노드 | 대표 위치 |
|---|---|---|
| 리터럴 | `decLit`, `floatLit`, `hexLit`, `string_lit`, `noneLit`, `trueLit`, `dot_lit`, `undef_lit` | 6349-6504 |
| 이름 | `ident` → `semaIdent` → `lookupIdent` | 6451, 4031, 5032 |
| 조건식 | `if_expr`, `switchExpr`, `as_expr` (캐스트) | 6505, 7416, 6558 |
| 호출 | `callExpr` → `semaCallExpr` | 6831, 7488 |
| 접근 | `accessExpr`, `index_expr`, `unwrap_choice`(`.!tag`) | 6874, 7396, 6877 |
| Option 과 Result | `unwrap`(`.?`), `unwrap_or`(`?else`), `unwrap_res`(`!`), `unwrap_res_or`(`!else`) | 6924, 7110, 6961, 7013 |
| 연산 | `binExpr`, `unary_expr`, `range`, `borrow`, `ex_borrow`, `ref`, `ptr`, `deref` | 7183-7237 |
| 구성 | `init_lit`(`{...}`), `init_expr`(`T{...}`), `stringt`(보간), `lambda_expr` | 7238, 7393, 7327, 7339 |
| 소유권 | `move_expr` | 7422 |
| 컴파일타임 | `expand_lit`(`#{...}`) → `cte.eval` + `ct_inline.value` | 7177 |

그 밖의 노드는 "Unsupported node: {}"(`:7462`)가 된다.

#### 리터럴 타입 추론

정수 리터럴은 기대 타입을 보고 자기 타입을 정한다. `decLit` 는 `target_t` 가 있으면 `semaInferSignedLit`(`sema.zig:10446`)을 먼저 시도한다. 대상이 `f32`/`f64` 면 실수 상수, `i8`/`i16`/`i32`/`r8`... 이면 해당 폭의 `const8/16/32` 로 범위 검사 후 만들고, Option/Result 이면 자식 타입으로 재귀한다. 대상이 없거나 맞는 폭이 없으면 `i64` 의 `const64` 다(`sema.zig:6411-6420`). 실행해서 확인한 결과는 다음과 같다(5.7).

```
a := 5               -> ir: .const64 Int
var b float = 5      -> ir: .const64 Float
var c i8 = 5         -> ir: .const8 Int
var d ?i32 = 7       -> ir: .const32 Int, .const64 Int, .init Option      (Some 태그 1 + 값)
var d i8 = 300       -> CompileError: Parsing decimal literal overflows integer type.
```

`none` 은 기대 타입 없이는 못 쓴다("Could not determine optional type for `none`.", `:6351`). `.rectangle` 같은 `dot_lit` 도 기대 타입이 enum 이어야 케이스를 찾는다(`:6360-6374`).

#### 암시적 변환: `semaFitTarget`

`semaExpr` 가 타입 불일치를 만나면 부르는 `semaFitTarget`(`sema.zig:10101-10366`)이 암시적 변환 규칙의 전부다. 지원 목록을 코드에서 정리하면 다음과 같다.

| 목표 타입 | 원본 | 변환 | 만드는 IR |
|---|---|---|---|
| `?T` (option) | `T` | Some 으로 감싸기 (`semaWrapSome`, 8976) | `init(tag=1, v)` 또는 zero_union 이면 `bitcast` |
| `!T` (result) | `T` 또는 `error` | 성공/실패 choice 로 감싸기 | `init` + `init_case` |
| `&T` | `^T` (ref) | 빌림으로 보기 | `bitcast` |
| trait | 구현 타입의 ref/빌림 | trait 객체 | `trait` |
| `Func[...]` | 같은 시그니처의 함수 포인터 | 함수 값으로 감싸기 | `func` |
| 포인터 | 다른 포인터, `&T`, `Ptr[void]` 등 | 주소 재해석 | `bitcast` |
| `f64` | `f32` | `f64.@init` 호출 | `call` |
| float | int, raw | 정수를 실수로 | `i2f` |
| int | 더 좁은 int | 부호 확장 | `sext` |
| int/raw | 더 좁은 raw/int | 0 확장 또는 비트 재해석 | `zext`, `bitcast` |

정수에서 실수로는 암시적 변환이 된다는 점(`i2f`)이 눈에 띈다. 실행으로 확인하면 `n := 5; var f float = n` 은 통과하고, `var c i8 = n` 은 "Expected type `i8`, got `int`.", `f := 1.5; var i int = f` 는 "Expected type `int`, got `float`." 에러다. 즉 반대 방향(`float` → `int`)과 넓은 정수에서 좁은 정수는 암시적이지 않아 `as[...]` 캐스트가 필요하고, 정수 폭 변환 캐스트는 `Int[].@init` 호출이라 범위를 넘으면 런타임에 패닉한다. 실제로 `n := 300` 다음 `a := as[i8] n` 은 "panic: Lossy conversion from `300` to `i8`"(`core.cy:433`)로 실행 중에 죽었다(5.7). 같은 코드에서 `as[float] n` 은 호출 없이 `i2f` 노드 하나였다.

#### 이항, 단항 연산: 내장 fast path 와 연산자 메서드

`semaBinExpr`(`sema.zig:8401`)는 연산자 종류로 갈린다.

- `and`/`or` 는 단락 평가를 `semaLogicAnd`/`semaLogicOr`(`:1155`, `:1119`)로 푼다. `_temp` bool 지역 + 바깥 `block` + `if_block { set_local; break_ }` 로, 연산자 노드가 따로 없다.
- `<`, `>`, `<=`, `>=`: 왼쪽이 int/raw/float 이면 오른쪽을 왼쪽 타입으로 `semaExprCstr` 한 뒤 `cmp`(`ir.Compare`, `Condition` 은 `gt/lt/ugt/...`) 노드(`sema_bin_expr3`, `:8086`). raw 는 부호 없는 조건(`ult` 등), int 는 부호 있는 조건이다. 그 밖의 타입은 타입 모듈에서 `<` 라는 이름의 메서드를 찾아 호출한다.
- `+ - * / % && || ~ << >>`: 정수/raw/실수면 `sema_bin_expr2`(`:8179`)가 `add`, `sub`, `imul`, `idiv`, `fadd` 같은 전용 노드를 바로 만든다. 폭이 다르면 넓은 쪽으로 `semaFitTarget` 으로 확장한다(`:8452-8483`). 두 피연산자가 모두 `const64` 노드이면 `fold_const_int`(`:8145`)가 상수 하나로 접는다(fork 커밋 5171b7fa).
- `==`, `!=`: `semaCompare`(`:8660`). 정수, bool, f64, 포인터, enum 은 `binary_op(op=equal_equal)` 노드이고, Option/choice/Result/struct 는 합성된 `@eq` 함수 호출(`getEqFunc`)이다. 실제로 `find(1) == none` 이 `call bool` 로 컴파일되는 것을 트레이스에서 봤다.
- 그 밖(예: 사용자 struct 의 `+`)은 타입 모듈에서 이름이 연산자 문자열인 메서드(예: 바로 "+")를 찾아 일반 메서드 호출로 푼다(`:8490-8493`). core.cy 에는 ``fn (EvalStr) `+`(o Self)`` 처럼 백틱으로 연산자 이름을 쓴 메서드가 선언되어 있다(`core.cy:277`). 사용자 정의 ``fn (&P) `+`(o P) -> P`` 로 `a + b` 를 실행한 결과 IR 은 `address_of(local a)`, `local b`, `call P` 였고 `add` 노드는 없었다(5절).

단항은 `semaUnExpr`(`:7951`)가 같은 방식으로 처리한다. `-x` 는 정수에 `neg`, 실수에 `fneg`, `!b` 는 bool 에 `unary_op(lnot)`, `~x` 는 정수/raw 에 `not` 이며 상수 접기 대상이다. 음수 리터럴 `-5` 는 `decLit` 를 직접 읽어 음수 상수 하나로 만든다(`:7956-8005`).

#### 호출 해석: `semaCallExpr` 에서 `call` 노드까지

호출은 sema 에서 가장 복잡한 경로다. `foo(123)` 한 줄이 지나는 함수들을 순서대로 적으면 다음과 같다.

```
semaExprNoCheck(.callExpr)                      sema.zig:6831
  semaCallExpr(node, target)                    :7488   callee 모양으로 분기
     callee 가 ident  → lookupIdent
         .local/.capture → semaCallValue (함수 값 호출)     :7579-7587
         .static(sym)    → callSym → semaCallFuncSym        :7588  (3792)
     callee 가 a.b   → 수신자(a)를 sema 하고 b 를 타입 모듈에서 찾음
         func   → semaCallFuncSymRec(func_sym, a, recv, args)      :7524, :7555
         field  → 필드 값(함수 포인터)을 호출 semaCallValue
  sema_func.matchFuncSym2(func_sym, pre_args, end_args, req_value)  sema_func.zig:560
     matchFuncSym                                   :587
        함수가 1개 → matchFunc → matchFuncRt        :407, :335
        오버로드 N개 → 선언 순서대로 하나씩 시도    :610-666
     matchFuncSig(sig, args)                        :504   인자마다:
        matchArg                                    :1259
           resolveRtArg   : semaExpr(인자, target=매개변수 타입, fit_target=true)   :835
           ownOrManageArg : 객체형이면 호출자가 관리, 아니면 semaOwn                  :817
           isTypeCompat   : 타입이 호환되는지
  ir.newExpr(.call, ret_t, {func, args})        sema_func.zig:575
```

이 경로에서 눈여겨볼 설계 결정이 다섯 가지다.

첫째, 메서드 호출 `x.m(a)` 는 수신자 `x` 가 첫 번째 인자(`Argument.initReceiver`)가 되는 같은 `matchFuncSym2` 이다. 수신자가 `T` 인데 메서드가 `&T` 를 받으면 `resolveRtArg` 의 `.receiver` 분기(`sema_func.zig:872-977`)가 암시적으로 `semaAddressOf` 를 넣어 준다. 위 사용자 연산자 호출에서 `address_of(local a)` 가 생긴 이유다. 반면 일반 인자(`b`)는 `P` 에서 `&P` 로 자동 변환되지 않아서, ``fn (&P) `+`(o &P)`` 로 선언하고 `a + b` 를 쓰면 "Expected argument `&P`, found `P`, when calling `fn +(&P, &P) -> P`." 에러가 났다(직접 확인).

둘째, 오버로드 해석은 2026-11-08 `cf4aa84a`(F-21)부터 두 단계다. 1단계는 암시적 변환 없이(`fit_target=false`) 매개변수 타입이 그대로 맞는 후보를 선언 순서와 무관하게 고르고(정수 리터럴은 `int` · `raw` 매개변수에만 맞음, 제네릭 후보 제외), 없으면 2단계가 이전처럼 "선언 순서대로 처음 성공하는 것"이다(`matchRtOverload`, 성공하면 즉시 반환). 모두 실패하면 인자 번호가 가장 큰 곳까지 맞았던 함수 하나를 골라 불일치 에러를 낸다(`:660-668`, `reportCallFuncMismatch` `:1278`). `call_overload_incompat_arg_error.cy` 의 기대 메시지가 첫 번째 오버로드 `fn foo(int)` 를 지목하는 이유다.

셋째, 시도에 실패한 오버로드가 남긴 IR 을 되돌리는 코드가 "미완" 표시와 함께 있다. 실패하면 `varStack` 을 시도 전 길이로 줄이고 현재 문장 리스트의 꼬리를 잘라내지만(`:647-658`), 바로 옆에 `TODO: Also remove the statements and expressions generated.` 가 남아 있다. 이미 만든 식 노드는 arena 에 남는다(arena 는 개별 해제가 없다). 이 불완전한 롤백이 실제 오동작을 일으키는 사례는 찾지 못했다(미확인). 다만 후보 인자 평가가 숨은 지역이나 문장을 만드는 코드를 고칠 때는 이 경로를 의심해야 한다.

넷째, 인자 소유권은 타입으로 갈린다(`ownOrManageArg`, `sema_func.zig:817-833`). 객체형(`isObjectLike`: `^T` 참조, 클로저 `Func[...]` 등. `types.zig:285`)은 호출하는 쪽이 관리하고(지역이면 그대로 넘기고 아니면 `semaOwn` + `semaManage` 로 숨은 임시 지역에 담는다), 그 밖의 타입은 `semaOwn` 으로 복사본을 만들어 피호출 쪽이 관리한다. `sink` 파라미터는 지역 변수를 `.dead` 로 표시해 이동시킨다(`resolveRtArg`, `:853-860`).

다섯째, 호출 노드는 종류가 여럿이다.

| IR 노드 | 언제 | 만드는 곳 |
|---|---|---|
| `call` | 정적으로 정해진 함수/메서드 | `sema_func.zig:575`, `sema.zig:6063` (`sema_call_ir`) |
| `call_ptr` | 함수 포인터 타입 값 | `semaCallPtr` (6085) |
| `call_union` | 클로저/함수 값(`Func[...]`) | `semaCallUnion` (6102) |
| `call_trait` | trait 메서드(vtable 인덱스) | `semaCallFuncSymRec` (6048) |

`req_value` 이거나 `const_eval_only` 함수이면 `matchFuncCt` 로 갈라져 호출이 컴파일 타임에 평가되고 결과는 IR 이 아니라 `ct_value` 가 된다(`sema_func.zig:407-418`, 2.7절). `host_builtin` 함수는 위 흐름에서 `func.data.host_builtin.ptr` 를 호출해 Zig 가 `ExprResult` 를 직접 만든다(`sema_func.zig:362-383`).

#### 템플릿 함수 호출

`fn add(a %T, b T) -> T` 처럼 `%T` 로 추론하는 함수는 `matchFuncRt` 의 `.generic` 분기에서 `matchGenericFuncRt`(`sema_func.zig:192`)로 간다. 인자를 하나씩 `matchTemplateArg`(`:1086`)에 넘기면, 컴파일 타임 파라미터는 `cte.evalCheck` 로 값을 구해 `template_ctx` 에 저장하고, `%T` 같은 추론 파라미터는 인자를 타입 힌트 없이 평가해 그 타입으로 `T` 를 정한다(`inferCtArgs`). 모든 파라미터가 정해지면 `genFunc`(`:272`)가 `cy.template.expandResolvedFuncTemplate` 로 특수화된 `*Func`(`print[int]` 같은)를 얻고, 호출은 그 함수를 가리키는 평범한 `call` 이 된다. 특수화 함수의 본문은 앞서 본 `semaChunkFuncs` 루프가 나중에 sema 한다. 트레이스에서 `push func: print[int]` 가 main 이 끝난 뒤에 나타나는 것이 그 증거다.

#### 필드, 인덱스, 구조체 초기화

- `c.x`: `semaAccessExpr` → 왼쪽이 심볼이면 모듈/타입 멤버 조회, 값이면 `semaAccessFieldName`(`sema.zig:2018`). 타입 모듈에서 `x` 가 `.field` 심볼이면 `semaField`(`:2197`)가 `field{rec, idx}` 를 만든다. 없으면 임베딩 필드, `@get` 훅(이름을 `EvalStr` 컴파일타임 값으로 넘김), 포인터/빌림의 자식 타입 순으로 찾는다. 모두 실패하면 "Field `x` does not exist in `T`." 에러다. 결과는 `value_field` 종류의 `ExprResult` 이고 `parent_local` 을 기억한다(빌림 검사용).
- `a[i]`: `semaIndexExpr`(`:1881`). 범위(`a[1..3]`)면 `@slice`, 포인터면 `sema_ptr_index`(주소 + 인덱스 * 원소 크기 산술을 직접 IR 로), 그 외에는 `@index_addr` 를 먼저 찾고 없으면 `@index` 를 호출한다. 즉 `list[i]` 는 문법이 아니라 타입 모듈의 메서드 규약이다.
- `P{x=1, y=2}`: `semaInitExpr`(`:5991`) → `semaInitStruct`(`:5924`). 필드 이름을 필드 번호로 매핑한 뒤 필드 순서대로 `semaExprCstr(값, 필드 타입)` + `semaOwn` 하고, 빠진 필드는 기본값 노드(`init_n`)를 쓰거나 "Initialization requires the field `x`." 에러를 낸다. 결과는 `init{args[]}` 하나다. Option, Result, choice, Vector 도 같은 `init` 노드로 만든다(`InitBuilder`, `:9787`).

#### 람다와 클로저

`fn(a int) => a + 1` 은 `lambda_expr`(`sema.zig:7339`)다. `pushLambdaProc` 로 새 `Proc` 을 열어 본문을 그 자리에서 sema 하고, `popLambdaProc`(`:9053`)이 닫으면서 `lambda{func, captures[], pinned_closure}` 식을 돌려준다. 호출 쪽 기대 타입이 함수 타입이면 `inferLambdaFuncSig` 로 파라미터 타입을 거기서 가져오고(`|a| a + 1`), 없으면 선언된 타입을 쓴다. 람다의 `funcBlock` IR 은 main 블록 문장 리스트 안이 아니라 `ir.func_blocks` 에 따로 등록된다. 5절 트레이스에서 `push func: lambda`, `captured Ref`, `lambda Func`, `call_union` 순서로 확인했다.

캡처는 `lookupIdent`(`:5032`)에서 일어난다. 현재 `Proc` 에 없는 이름이면 `lookupParentLocal`(`:5113`)로 바로 위 `Proc` 하나만 찾고(주석 "Only check one block above"), 찾으면 `pushCapturedVar` 로 캡처 슬롯을 만든다. 제한이 두 가지 있다. 캡처할 변수의 타입은 참조형(`^T`) 또는 빌림(`&T`)이어야 하고("Can only capture variables declared with the reference types `^T` or `&T`.", `:5066`), 정적 함수(`fn` 선언)는 지역을 캡처할 수 없다(`:5057-5061`, 람다만 가능). 그래서 `n := 1` 을 `fn() -> int:` 본문에서 읽으면 컴파일 에러이고, `n := ^1` 처럼 박싱해야 한다(5.4).

#### 문자열 보간

`'hi %{name} %{c.y}'` 는 `semaStringTemplate`(`sema.zig:4065`)가 푼다. 리터럴 조각들을 `[N+1]str` 벡터 지역 `_strs_vec` 로, 각 `%{expr}` 를 `to_print_string[T]` 호출 결과로 만들어 `[N]str` 벡터 지역 `_exprs_vec` 로 담고, 둘의 `[&]str` 뷰로 `str.interpolate` 를 호출한다. `str.interpolate` 는 `#[bind='str.interpolate']` 로 Zig 네이티브에 연결되어 있다(`core.cy:3312`, 근거 `docs/decisions/project_string_interpolation.md`). 보간 전용 IR 노드는 없다. 벡터 `init`, `address_of`, `call` 의 조합일 뿐이다.

#### Option 과 Result: `.?`, `?else`, `if x |v|`, `!`, `!else`

Option 은 `{tag, payload}` 두 칸짜리 choice 이고(`field idx=0` 이 태그, `idx=1` 이 payload), 포인터처럼 0 이 곧 none 이 될 수 있는 타입은 `zero_union` 이라 값 한 칸이다(`semaIsNone`, `sema.zig:7736-7771`). Result 도 `idx=0` 이 태그(0 이면 에러), `idx=1` 이 payload 다(`semaIsError`, `:7727`, `semaUnwrapResultNoCheck`, `:1937`).

| 문법 | AST | 처리 | 만드는 IR (요지) |
|---|---|---|---|
| `x.?` | `unwrap` (6924) | Option 인지 `sema_expr_cstr_template` 로 검사, 주소 가능하게 만든 뒤 | zero_union: `unwrap_nz(opt)`. 그 외: `address_of` → `unwrap_addr(tag=1)` → `deref` |
| `x ?else d` | `unwrap_or` (7110) | `semaUnwrapOrStmt` (10077) | `block { if_block(!none){ set_local _temp = payload; break_ }; set_local _temp = d }` |
| `if x \|v\|:` | `if_unwrap_stmt` (1271) | `semaIfUnwrapBlock` (1235), `semaCaptureUnwrap` (1085) | `declare_local _opt` + `if_block(lnot(is_zero(tag)))` + `declare_local v = copy(field(_opt, 1))` |
| `r!` | `unwrap_res` (6961) | 아래 | `if_block(is_zero(tag)){ 에러 반환 }` + `field(r,1)` + `case` |
| `r !else d` | `unwrap_res_or` (7013) | `?else` 와 같은 모양 | `block { if_block(is_error){ set_local _temp = d; break_ }; set_local _temp = copy(payload) }` |
| `r !else \|e\|: ...` | `unwrap_res_or_block` (7058) | 에러 블록이 끝에 도달하면 안 됨 | 위와 같되 기본값 자리에 블록, 끝에 "Expected unreachable block end." 검사 |

`x.?` 의 IR 은 태그를 검사하는 노드를 따로 두지 않는다. 검사는 VM 명령 `UnwrapAddr`/`UnwrapNZ` 안에 있다(`src/vm.c:1298-1319`). 태그가 기대와 다르면 `z_panic_unexpected_choice` 로 패닉하고 메시지는 "Expected active choice tag `1`, found `0`." 이다. `?int`, `?str`, `?^Foo` 에서 `none.?` 을 직접 실행해 세 번 모두 이 패닉을 확인했다(5.7). 제너레이터에서 `g.next().?` 가 쓰레기 값을 내는 현상이 따로 보고되어 있지만, 위 실험으로 볼 때 `.?` 자체의 문제는 아니다. 제너레이터가 돌려주는 값이 이미 잘못된 것으로 추정한다(5.7, 원인은 07 챕터 담당).

`r!` 는 에러 경로의 모양이 문맥으로 갈린다(`sema.zig:6975-6995`).

- 감싼 함수의 반환 타입이 `error` 면 에러 값을 그대로 `semaReturnExpr` 한다.
- 반환 타입이 `Result` 면 `init Result(tag 0, err)` 를 만들어 `semaReturnExpr` 한다. 소멸자가 함께 push 되므로 조기 반환도 정리된다.
- 둘 다 아니면 "Expected `Result` or `error` return type for enclosing function." 에러다.
- main 블록(함수 밖)이면 `panic_unwrap_error_fn` 호출로 패닉한다("Unwrapped error `error.Invalid`." 는 `try_panic.cy` 의 기대 메시지).

`fn use_bang(x int) -> !int:` 안의 `v := may_fail(x)!` 를 트레이스한 실제 IR 생성 순서(숨은 지역 `_temp`, `_res_addr`)는 `local Result`, `address_of Borrow`, `field Int`, `is_zero`, `field error`, `case error`, `init Result`, `const64`, `init_case`, `set_ret`, `ret`, `if_block`, `field Int`, `case Int`, `set_local`, `pop_locals` 였다. 에러 분기 안의 `set_ret`, `ret` 를 `if_block` 이 감싸고, 정상 경로는 `field`+`case` 로 payload 를 읽는 모양이다.

캐스트 `as[T] x`(`as_expr`, `sema.zig:6558-6830`)는 대부분 컴파일 타임 판정이다. 타입이 이미 호환이면 식을 그대로 돌려주고(리터럴 타입 고정 용도), 같은 기본 표현이면 `bitcast`, 포인터끼리면 `bitcast`, 정수끼리, 실수끼리, 실수에서 정수로의 변환은 대상 타입의 `@init` 호출이다(정수에서 실수는 위 암시적 변환 `i2f` 로 처리된다). 런타임 다운캐스트용 `cast{isRtCast}` 노드는 마지막 폴백에만 남아 있다(`:6825`).

### 2.6 소유권 관련 sema 작업의 위치 (상세는 06 챕터)

소유권은 별도 패스가 아니라 위의 모든 경로에 흩어져 있다. 어디를 보면 되는지 위치만 정리한다.

| 작업 | 함수 (줄) | 하는 일 |
|---|---|---|
| 복사 삽입 | `sema_copy` (5750), `semaOwn` (5829) | `NoCopy` 면 에러, 복사 생성자가 없으면 그대로, ref 포인터나 클로저는 `retain`, 그 외는 `@copy` 호출 |
| 임시값 지역화 | `semaManage` (5816), `semaEnsureAddressable` (5807) | 소유한 managed 값을 숨은 `_temp` 지역에 담아 수명을 블록에 묶음 |
| 이동 | `move_expr` (7422), `implicitReturnMoveLocal` (994), `sink` 인자 (`sema_func.zig:853`) | 원본 지역을 `.dead` 로 표시 |
| 지역 수명 끝 | `popBlock2` (4810), `popLocals2` (310), `semaDestructBlock2` (4794) | 블록을 나갈 때 `varStack` 을 역순으로 돌며 소멸자 문장 push |
| 소멸자 선택 | `semaDestructLocal` (4702) | 타입 종류로 분기: `release`(ref, 클로저, zero_union Option), `@destruct` 호출(str, choice, Result, struct, vector 등) |
| 빌림 추적 | `Local.active_borrows`, `parent_local`, `popLocals2` (322) | 빌림이 살아 있는 동안 소유자의 배타성 검사 |
| 인자 소유 | `ownOrManageArg` (`sema_func.zig:817`) | 2.5절 호출 해석의 "넷째" |

`semaDestructLocal` 은 문장을 직접 만드는 곳이므로 5.3 의 `a := ^123` 함수 트레이스에서 `declare_local`, `set_ret`, `release`, `ret` 순서와 함께 `@deinitObject[int]` 라는 타입별 소멸자 함수가 자동 생성되는 것(`semaReleaseLocal` → `getDeinitObjFunc`, `sema.zig:4690`, `:9999`)을 볼 수 있다. 여기서 정리한 소멸자가 IR 의 `release` 로 이미 박혀 있다는 것이 2.8절의 "코드젠은 번역만"이라는 주장의 근거다.

### 2.7 컴파일타임 평가: cte 와 ct_inline

컴파일타임 평가는 두 파일로 나뉜다.

| 파일 | 역할 |
|---|---|
| `cte.zig` (2,803줄) | 컴파일 타임 인터프리터. AST 를 직접 걸으며 `Value` 를 계산한다. `evalExprNoCheck`(`cte.zig:1297`)가 식, `evalStmt`(`:480`)가 문장 |
| `ct_inline.zig` (380줄) | 그 값을 IR 로 되돌리거나(`value`, `:13`) `#if`/`#for` 같은 컴파일타임 문장을 sema 와 엮는다(`evalStmt`, `ifStmt`) |

핵심 사실은 "cte 는 VM 이 아니다"라는 점이다. 컴파일된 바이트코드를 돌리는 것이 아니라, AST 노드를 재귀적으로 걸으며 값을 계산하는 별도 구현이다. 결과 타입 `cte.Expr`(`:1160`)는 `ct_var`, `value`, `sym`, `func` 중 하나이고, 값은 `TypeValue{type, value}` 로 다룬다. 값이 힙을 쓰면(문자열, 타입 객체 등) `Compiler.heap`("Compile-time heap", `compiler.zig:53-54`, 생성 `:122`)에 산다. 이는 VM 런타임 힙과 같은 `cy.Heap` 타입의 별도 인스턴스다.

컴파일타임 변수와 템플릿 인자는 `ResolveContext.ct_params`(`sema.zig:2564`)에 이름으로 저장된다. 컨텍스트는 `resolve_stack` 에 쌓여서 중첩 확장(템플릿 안의 템플릿)을 지원하고, 에러가 나면 `caller` 노드들이 에러 리포트의 스택 트레이스가 된다(`chunk.zig:616-635`). 5절의 `while` 에러 출력에서 호출한 줄이 함께 나온 이유다.

컴파일 타임 전용 값 타입이 둘 있다. `EvalInt` 는 64비트 정수이고 `EvalStr` 는 `heap.EvalStr{ptr, header}`(`src/heap.zig:792`) 문자열이다. 이 타입은 런타임에 존재하지 않고, `ct_inline.value` 가 대상 타입에 맞는 IR 상수로 바꾼다. `EvalInt` 는 `const64`(대상이 `r8/r16/r32` 면 좁은 상수), `EvalStr` 는 문자열 상수 노드가 된다(`ct_inline.zig:51-93`).

#### 진입점

| 진입점 | 위치 | 동작 |
|---|---|---|
| `const X = expr` | `resolveConst` (`sema.zig:3158`) | `cte.eval` 로 값을 구하고 `ct_inline.value` 로 만든 IR 을 `sym.ir` 에 캐시. 처음 참조될 때 해석된다. `str` 타입 const 는 에러("Consider using `EvalStr`") |
| `#{expr}` | `expand_lit` (`sema.zig:7177`) | 식 하나를 즉석 평가해 IR 상수로 끼워 넣음 |
| `#if`, `#else`, `#for`, `#switch` | `ct_inline.ifStmt` (314), `evalStmt` (289), `cte.forRangeStmt` (321) | 조건/범위를 cte 로 평가하고, 선택된 본문만 일반 `semaStmts` 로 sema |
| `#x := expr` | `cte.localDecl` (83) | `ct_params` 에 컴파일타임 변수로 저장 |
| `#[consteval] fn`, 컴파일타임 전용 타입 파라미터를 가진 함수 | `sema.zig:2850`, `module.zig:460` → `cte.evalCall` (771) → `evalFunc` (23) | 호출이 컴파일 타임에 실행됨. `semaChunkFuncs` 가 이 함수의 IR 은 만들지 않음 |
| `type X[...] const:` | `resolve_type_const` (`sema_type.zig:14`) → `cte.evalFuncBody` (53) | 본문을 실행해 `type` 값을 반환받고, 그 타입의 이름과 부모를 `X` 의 것으로 덮어씀 |
| 타입 표현식, 템플릿 인자, switch case 조건 | `cte.eval_type2`, `evalCheck` 등 | 타입 식(`?^StrBuffer`, `[N]int`)도 전부 cte 가 평가 |

마지막 줄은 규모가 의외다. 5.1 의 `-v` 로그 72,964줄 중 `cte:` 로 시작하는 줄이 7,271줄이고 `sema:` 줄은 6,632줄이다. core.cy 의 타입 선언을 푸는 일이 대부분 cte 호출이기 때문이다(줄 수는 실측, 이유는 로그 내용으로 본 추정).

`type X[const N int] const:` 의 실제 사용례가 `src/test/meta/ct_eval_loop.cy` 에 있다. `for 0..N |i|:` 로 필드 배열을 채우고 `meta.new_struct(fields, {tuple=true})` 를 반환하면 `Ints[2]` 가 필드 `p0`, `p1` 을 가진 새 struct 타입이 된다. 이 파일은 CLI 로 실행해 통과했다(출력 없음, exit 0). 이 본문은 `fn` 본문과 달리 런타임이 아니라 컴파일러 안에서 실행된다는 점이 핵심이다. `docs/decisions/project_ct_eval_loop_result.md` 는 이 본문이 0회 반복 루프일 때 결과가 초기화되지 않아 쓰레기 값이 "반환"으로 읽히던 버그의 기록이다. 수정 후 `evalStmt` 가 결과를 `.{ .ret = false, .ret_value = undefined }` 로 시작한다.

#### 무엇까지 실행할 수 있는가

cte 가 지원하는 문장은 `cte.zig:480-557` 의 `switch` 에 있는 것이 전부다.

```
op_assign_stmt, assign_stmt  (대입 대상: 컴파일타임 변수, p.*, 벡터 원소)
var_decl, for_range_stmt, switch_stmt, if_stmt, returnExprStmt, exprStmt, ct_stmt
그 외 → "Inline eval: Unsupported {}." (cte.zig:550)
```

`while`/`for 이터레이터`/`try` 는 없다. `const s = sum_to(10)` 에서 `sum_to` 가 `while` 을 쓰면 "Inline eval: Unsupported whileCondStmt." 에러가 난다(5.6). 식은 리터럴, 이름, 이항/단항, 호출, 접근, 인덱스, `if` 식, `switch` 식, `?else`, `as`, 타입 식 정도다(`cte.zig:1297-1948`의 case 목록). 람다, 문자열 보간(`%{}`), `!` 같은 식은 목록에 없고 "Unsupported compile-time expression: `stringt`"(람다는 `lambda_expr`) 에러가 난다(`cte.zig:1945`, 5.7). core.cy 가 컴파일타임 이름을 만들 때 보간 대신 `'p' + EvalStr(i)` 를 쓰는 것(`core.cy:2012`)도 이 제약 때문으로 보인다(추정).

호출은 `evalCall`(`cte.zig:771`)이 함수 종류로 갈라 처리한다.

- `host_const_eval`: Zig 로 구현된 컴파일타임 함수(`EvalStr.+` 등 `core.zig` 의 `zErrConstEvalFunc` 표).
- `hostFunc` 이면서 `eval` 포인터가 있는 함수.
- `userFunc`: `evalFunc`(`:23`)가 파라미터를 `ct_params` 에 묶고 함수 본문 AST 를 `evalStmts` 로 해석한다. 재귀도 된다. `docs/docs.md:3017-3024` 예제와 같은 모양의 `const fib20 = fib(20)` 이 컴파일됐고, `fib20` 과 런타임 `fib(20)` 이 모두 6765 였으며 `#{fib(10)}` 은 55 였다(5.6).
- 그 밖에는 "Inline eval: Unsupported function".

결과 타입은 "eval 적격(eval eligible)"이어야 한다. managed 타입(힙 소유)은 `ensure_eval_eligible_type`(`sema_type.zig:1333`)이 거부하고, `const` 선언 타입은 `isConstEligible` 이어야 한다.

`#if` 는 단순 분기가 아니라 진짜 조건부 컴파일이다. 함수 안에서 `#if false: this_function_does_not_exist()` 를 써도 에러가 나지 않았고, `#for 0..3 |i|: print(#{i * 10})` 는 `print(0)`, `print(10)`, `print(20)` 세 문장으로 펼쳐졌다(5.3, IR 로그에서 `exprStmt` 가 세 번, 각각 `const64` 와 `call`). 선택되지 않은 분기는 sema 를 아예 거치지 않는다. 함수 밖 최상위의 `#if` 본문은 "컴파일타임 문장만" 허용되는 문맥이라 `print` 같은 런타임 문장을 넣으면 "Only compile-time statements are allowed in this context." 에러가 난다(`ct_inline.zig:274`, 5.7).

#### 해석기가 컴파일러 안에 있다는 것의 의미

장점은 분명하다. 별도 실행 환경 없이 템플릿 인자, 타입 생성, 시그니처 해석, 조건부 컴파일이 모두 sema 안에서 일어나고, 컴파일 도중의 임의 지점(예: 함수 시그니처 해석 중)에서도 불릴 수 있다. 값이 곧 타입 객체이기도 해서 `type X const:` 가 새 타입을 만들어 타입 레지스트리에 등록한다.

대가는 "언어의 구현이 둘"이라는 점이다. 같은 소스가 런타임(바이트코드)과 컴파일 타임(AST 해석)에서 다르게 동작할 수 있다. 실제 사례를 7절에 적었다. 복합 대입 `t += 5` 가 컴파일 타임에서는 `t = 5` 로 평가됐다(F-20, 2026-11-08 수정). `docs/docs.md:3015` 가 "This can not emulate the entire language" 라고 한계를 밝히고 있고, 새 문법이 sema 에 추가될 때 cte 는 따로 따라가야 한다.

### 2.8 IR: sema 의 산출물

#### 메모리 모양

`ir.zig` 상단 주석(`:20-25`)은 "트리 구조지만 모든 노드가 선형 배열에 들어가 위치(인덱스)로 가리킨다"고 설명한다. 현재 코드는 그렇지 않다. 같은 주석 안에서도 "위치로 색인"(21행)과 "AST 노드 포인터"(22행)가 섞여 있는데, 0.3 의 같은 주석은 AST `nodeId` 라고 적혀 있었다(`git show 0.3:src/ir.zig`). 현재 구현은 노드마다 arena 에서 할당한 포인터를 쓰고, 선형 배열과 인덱스 설명은 남은 흔적이다(7절). 실제 모양은 이렇다.

```zig
// src/ir.zig:96-109, 189-206 (발췌)
pub const Stmt = extern struct { code: StmtCode, node: *ast.Node, next: ?*Stmt, ... };
pub const Expr = extern struct { code: ExprCode, node: *ast.Node, type: *cy.Type, ... };

pub const IfBlock = extern struct { base: Stmt = undefined, cond_expr: *Expr, body_head: ?*Stmt };
pub const Call    = extern struct { base: Expr = undefined, func: *cy.Func, numArgs: u8, args: [*]const *Expr };
```

- 모든 노드는 `extern struct` 이고(`ExprImpl` 가 comptime 으로 강제, `ir.zig:796-798`) 맨 앞 필드 `base` 가 공통 헤더다. 노드를 받은 코드는 `stmt.cast(.if_block)` 처럼 `code` 로 구체 타입을 골라 `@ptrCast` 한다(`:101-108`). Trace 빌드에서는 `code` 가 일치하는지 검사한다("Expected {}, found {}.").
- 헤더는 C 레이아웃 계산상 64비트에서 24바이트(`code` 1바이트 + 패딩, 포인터 둘)다(계산값, 실측 아님).
- `node` 포인터는 모든 노드가 갖는다. 코드젠이 에러나 디버그 심볼 위치를 알려면 AST 가 필요하기 때문이다. IR 은 AST 를 대체하지 않고 AST 위에 얹혀 있다.
- 문장은 `next` 로 이은 단방향 리스트이고, 중첩 구조는 `body_head`, `bodyHead` 같은 자식 리스트 머리 포인터로 표현한다. 식은 `left`/`right`/`args[]` 같은 자식 포인터를 직접 갖는 트리다. 그래서 "식 트리 + 문장 리스트의 트리"다.
- 노드 생성은 `Buffer.newExpr`/`newStmt`/`pushStmt`(`ir.zig:860-888`)로만 한다. 각 노드를 청크의 `ArenaAllocator` 에서 하나씩 `create` 하고, `pushStmt` 는 `stmtBlockStack` 맨 위 리스트 끝에 붙인다.

```
funcBlock(find)
  bodyHead ──▶ block ──next──▶ set_ret ──next──▶ ret ──next──▶ trap
               bodyHead                          (trap 은 Trace 빌드에서만, sema.zig:9152)
                  │
                  ▼
               if_block ── cond_expr ──▶ cmp(gt) ─ left ─▶ local x
                  body_head                      └ right ▶ const64 2
                  │
                  ▼
               set_ret ─next─▶ ret
                  └ right ▶ init(Option) ── args[0] ▶ const64 1
                                         └ args[1] ▶ imul(local x, const64 2)
```

최상위의 `set_ret` 도 `right` 로 `init(Option, const64 0, voidv)` 를 가리킨다(`return none`). 위 그림은 그 가지를 생략했다.

#### 노드 종류 (StmtCode 31개, ExprCode 73개)

`rg` 로 `newExpr(.이름,` 와 `pushStmt(.이름,` 호출처를 모두 찾아 "sema 쪽에서 만드는 곳이 없는 코드"를 가려냈다. 아래 표에서 "(미사용)"이 그것이다. 호출 코드 값을 변수로 넘기는 곳이 있으면 이 정적 검색은 놓칠 수 있다(`sema_bin_expr2` 의 `ir_code` 변수는 모든 분기가 먼저 반환해 영향 없음을 읽어서 확인했다).

| 부류 | StmtCode |
|---|---|
| 블록 구조 | `mainBlock`, `funcBlock`, `block`, `pop_locals`, `nop_label` |
| 지역과 수명 | `declare_local`, `discard`, `release` |
| 제어 흐름 | `if_block`, `loop_block`, `forRangeStmt`, `switch_stmt`, `break_`, `continue_`, `trap` (`tryStmt` IR 은 2026-11-09 삭제, `try` 블록은 `block` · `break_` 로 낮춘다) |
| 반환과 코루틴 | `ret`, `set_ret`, `ret_gen`, `yield`, `await_`, `ret_expr`(미사용) |
| 쓰기 | `set_local`, `set_field`, `set_global`, `set_deref`, `setCaptured`, `set`(미사용) |
| 디버그 | `breakpoint`, `dumpBytecode`(미사용), `verbose`(미사용) |

| 부류 | ExprCode |
|---|---|
| 상수 | `const8`, `const16`, `const32`, `const64`, `truev`, `falsev`, `voidv`, `undef`, `string`, `init_zero` |
| 변수와 메모리 | `local`, `global`, `captured`, `field`, `case`, `deref`, `address_of`, `lift` |
| 정수 산술 | `add`, `sub`, `imul`, `mul`, `idiv`, `div`, `imod`, `mod`, `neg`, `not`, `and_op`, `or_op`, `xor`, `lsl`, `lsr`, `asr` |
| 실수 산술 | `fadd`, `fsub`, `fmul`, `fdiv`, `fmod`, `fneg`, `fabs` |
| 비교와 논리 | `cmp`, `is_zero`, `binary_op`(`==` 등), `unary_op`(`lnot`) |
| 변환 | `bitcast`, `cast`, `i2f`, `f2i`, `zext`, `sext`, `trunc` |
| 값 생성 | `init`(struct, Option, Result, choice, vector 공통), `init_case`, `trait`, `func`, `func_ptr`, `lambda`, `vector`(미사용), `partial_vector`(미사용), `closure`(미사용) |
| 호출 | `call`, `call_ptr`, `call_union`, `call_trait` |
| 수명 | `retain` |
| Option, choice | `unwrap_addr`, `unwrap_nz`, `case_cond`, `switch_case` |
| 코루틴 | `gen_next`, `gen_end` |
| 기타 | `mainEnd`(미사용) |

0.3 과 비교하면 노드의 성격이 바뀌었다. 0.3 의 `ExprCode` 는 49개였고 `fieldDynamic`, `coinitCall`, `coyield`, `coresume`, `list`, `map`, `stringTemplate` 같이 동적 타이핑과 컬렉션 리터럴을 직접 표현하는 이름이 있었다(`git show 0.3:src/ir.zig`). 지금은 `field`, `address_of`, `deref`, `add`, `imul` 처럼 정적 타입이 확정된 저수준 연산만 남았고, 리스트/맵/문자열 보간 같은 고수준 구성은 `init` 과 `call` 로 풀려 있다. IR 이 "타입이 이미 결정된 낮은 수준"으로 이동한 것이다.

#### 수명과 소비자

`ir.zig:11` 은 "IR 은 sema 중에 만들어지고 코드젠이 소비한 뒤 버려진다"고 하는데, 실제 수명은 이렇다.

- IR arena 는 `Chunk.init` 에서 만들어진다(`chunk.zig:266`). 해제는 `Chunk.deinit`(`:313`)이고, 이는 `Compiler.deinit`(`compiler.zig:187`) 곧 VM 정리 때다. `bcgen.genAll` 직후에 해제하지 않는다. 즉 "버려진다"는 의미상의 서술이고 메모리는 컴파일러가 살아 있는 동안 유지된다.
- 루트는 청크마다 `ir.func_blocks`(`mainBlock`/`funcBlock` 스텁의 목록)이고, bc_gen 이 `genChunkInner`(`bc_gen.zig:438-446`)에서 이 목록을 순회한다. main 블록은 `Compiler.program_ir` 에도 저장된다(`compiler.zig:96`, `:435`).
- 스텁을 먼저 만들고 나중에 덮어쓰는 패턴이 곳곳에 있다. `funcBlock`(`pushFuncProc`, `sema.zig:4548`에서 `undefined` 로 생성 → `popFuncBlock`, `:9173`에서 `bodyHead`/`params` 채움), `declare_local.init`(2.4절 가), `mainBlock`. 주석의 "backpatching" 이 이것이다.
- 소비자는 여럿이다. `bc_gen.zig`(`genStmt` `:379`, `genExpr` `:480`이 `code` 별 1:1 switch), `cgen.zig`(C 백엔드, 3,187줄), `jit/gen.zig`, 그리고 꺼져 있는 `dce.zig`. 다만 C 백엔드는 현재 쓸 수 없다. `cyber -cc x.cy` 를 실행하면 sema 단계에서 core.cy 의 `#[bind]` 함수에 본문이 없다는 이유로 "Expected function implementation." 에러가 난다(`sema.zig:2870`, 5.7). IR 이 여러 백엔드를 위한 중립 표현이라는 의도는 코드 구조(백엔드가 모두 같은 IR 을 읽는다)에서 확인되지만, 바이트코드 VM 외에는 실행해 보지 못했다.

#### "코드젠은 번역만 한다"를 코드로 확인하기

설계 의도는 소유권, ARC, 소멸자가 IR 에 이미 박혀 있어 bc_gen 이 단순 번역을 하는 것이다. 근거는 다음과 같다.

- 소멸자 호출과 해제는 sema 가 `release`, `retain`, `call(@destruct)`, `pop_locals` 문장으로 직접 넣었다(2.6절). bc_gen 의 `gen_release`(`bc_gen.zig:581-584`)는 레지스터를 찾아 `pushRelease` 를 부르는 두 줄이다.
- 정수 산술은 `add`/`imul` 같은 전용 노드라 bc_gen 은 타입별 연산자 해석을 하지 않는다.
- 호출은 이미 어떤 함수인지 확정된 `*Func` 를 들고 있다.

반면 bc_gen 에 남은 일도 있다. IR 지역 번호를 레지스터에 매핑하는 일(`bc_local_map`, `gen_pop_locals` `:2821`), 명령어 선택, fork 가 추가한 작은 leaf 함수 인라이닝(`gen_inline_call`, `check_inline_expr`)이다. 04 챕터가 다룬다. "번역만"은 "의미 결정을 하지 않는다"는 뜻이지 "일이 없다"는 뜻이 아니다.

## 3. 핵심 개념 정리

| 개념 | 한 줄 정의 | TS/Node 와의 대응 (일반 지식) |
|---|---|---|
| sema | AST 를 훑으며 이름 해석, 타입 검사, 소유권 연산 삽입, IR 생성을 한 번에 하는 패스 | TypeScript 의 binder + checker 에 해당. 다만 결과가 AST 주석이 아니라 새 트리 |
| `Chunk` | 파일/모듈 단위의 컴파일 상태 묶음(IR arena, 변수 스택, 심볼 목록) | 하나의 `SourceFile` 과 그 Program 상태 |
| `Proc` | 함수/람다/main 하나를 sema 하는 동안의 컨텍스트 | 함수 스코프(Scope) |
| `Block` | 렉시컬 블록 하나. 지역 변수 범위, 도달 가능성(`endReachable`) | 블록 스코프 |
| `Local` / `varStack` | 살아 있는 지역 변수 스택. `.dead` 는 이동됐거나 초기화 전 | 없음(TS 는 GC) |
| `ExprResult` | 식 하나의 결과: 타입 + IR + 소유/주소 가능 여부 | 타입이 붙은 식 노드 |
| `Cstr` | 식에 내려보내는 기대 타입과 정책 | contextual typing |
| IR | sema 가 만든 저수준 트리. 소유권, 소멸자, 변환이 이미 반영됨 | 해당 없음(TS 컴파일러는 AST 를 그대로 emit) |
| 스텁과 backpatch | IR 노드를 먼저 만들어 두고 나중에 채우는 패턴 | 해당 없음 |
| `semaOwn` / `semaManage` | 값을 소유 값으로 만들기(복사) / 소유 값을 숨은 지역에 묶기 | 해당 없음 |
| cte | 컴파일러에 내장된 AST 인터프리터(컴파일 타임 평가) | C++ constexpr, Zig comptime 에 대응하는 기능 |
| `ct_value` | 컴파일 타임에 값이 확정된 `ExprResult`. IR 이 아직 없음 | 해당 없음 |
| `ct_inline` | cte 값을 IR 상수로 바꾸고 `#if`/`#for` 를 sema 와 엮는 접착제 | 해당 없음 |
| `host_builtin` | Zig 로 쓴 "sema 중에 IR 을 직접 만드는" 함수 | 컴파일러 intrinsic |

## 4. 소스 읽기 지도

### 4.1 권장 순서 (약 2시간)

1. `src/sema.zig:4555` `sema_program` → `:4638` `pushProc` → `:4862` `pushBlock` → `:4810` `popBlock2`. 컨텍스트가 어떻게 쌓이고 닫히는지 보고 2.2절 그림과 맞춰 본다.
2. `src/sema.zig:368` `semaStmt` 를 위에서 아래로 훑는다(400줄). 모르는 분기는 건너뛴다.
3. `src/sema.zig:3450` `localDecl` 과 `:4003` `semaLocal`. 변수 선언과 읽기.
4. `src/sema.zig:6287-6332` `semaExprCstr`, `semaExpr`, 그다음 `:6334` `semaExprNoCheck` 의 상단 200줄(리터럴).
5. `src/sema.zig:7488` `semaCallExpr` → `src/sema_func.zig:560-669` → `:817-983`. 호출 해석 전체.
6. `src/sema.zig:8401` `semaBinExpr`, `:8179` `sema_bin_expr2`, `:8660` `semaCompare`.
7. `src/sema.zig:1022-1100` if/unwrap, `:6924-7176` Option/Result 언랩.
8. `src/sema.zig:4702` `semaDestructLocal`, `:5750-5834` `sema_copy`, `semaOwn`, `semaManage`.
9. `src/cte.zig:480-557` `evalStmt`, `:771-824` `evalCall`, `src/ct_inline.zig:13-190` `value`.
10. `src/ir.zig:1-26, 27-206`, 그다음 `src/bc_gen.zig:379-421` 의 `genStmt` 로 IR 소비 쪽을 본다.

### 4.2 sema.zig 구간 지도 (10,594줄)

| 줄 범위 | 내용 | 비고 |
|---|---|---|
| 1-300 | 데이터 구조: `Lifetime`, `Local`, `Block`, `Proc` | 먼저 읽기 |
| 300-367 | `semaStmts`, `popLocals`, `semaExprStmt` | |
| 368-776 | `semaStmt` 디스패치 (for, while, switch 진입, try, yield) | 핵심 |
| 777-1020 | `break`/`continue`, `semaReturn*`, `implicitReturnMoveLocal` | |
| 1021-1394 | `if`, `if` unwrap, `and`/`or` 단락 평가 | |
| 1395-1816 | 대입: 인덱스, 필드, 전역, `semaAssignStmt` | |
| 1817-2253 | 인덱스/슬라이스, Result/Option 언랩 헬퍼, 필드 접근 | |
| 2254-2534 | 템플릿, `use` 별칭 선언 해석 | 02 챕터와 공유 |
| 2535-2755 | `CtParam`, `ResolveContext` (cte 의 변수 저장소) | 2.7절 |
| 2756-3115 | 함수 선언 해석(`ensure_resolved_func`, 호스트 바인딩), `semaMethodBody`, `semaFuncBody` | |
| 3116-3317 | `const`/`global`/`var` 해석(`resolveConst`, `semaUserVarInit`) | |
| 3318-3550 | 지역 선언: `declareParam`, `reserveLocalName`, `localDecl` | |
| 3552-3770 | `ExprResult`, `Cstr` | 핵심 타입 |
| 3771-4109 | `callSym`, `symbol`/`symbol2`, `semaLocal`, `semaIdent`, `semaStringTemplate` | |
| 4110-4529 | 이름 해석(`getResolvedName`), 최상위 컴파일타임 문장, `resolveFuncSig`, 람다 시그니처 | 02 챕터와 공유 |
| 4530-4667 | `Proc` push/pop, `sema_program` | 진입점 |
| 4668-4956 | 소멸자(`semaDestructLocal`), `pushBlock`, `popBlock2`, 변수 push | 소유권 |
| 4957-5169 | `lookupSelf`, `lookupIdent`, `lookupParentLocal` | 이름 조회, 캡처 |
| 5170-5701 | `switch` 전체 | |
| 5702-5923 | 주소/빌림/복사/소유/`Manage`/`Lift`, tuple/vector 초기화 | 소유권 |
| 5924-6160 | struct 초기화, 호출 헬퍼(`semaCallFuncSymRec` 외) | |
| 6161-6333 | `semaExprSkipSym`, `semaExpr` 계열 | 핵심 |
| 6334-7465 | `semaExprNoCheck` 거대 switch | 핵심, 1,100줄 |
| 7467-7626 | `semaCallExpr` | 핵심 |
| 7627-7950 | 상수, 문자열, `none`/`is_none`, ref/borrow 식 | |
| 7951-8513 | 단항/이항 연산 | |
| 8514-8956 | 벡터, 초기화 리터럴 `semaInitLitTarget`, 비교, 람다, `ex_borrow`, init 시퀀스/레코드 | |
| 8957-9047 | `nop`, `semaWrapSome`, choice/cunion 초기화 | |
| 9048-9212 | `popLambdaProc`, `procPrologue`, `popFuncBlock` | 함수 끝처리 |
| 9213-9678 | `FuncSig`, `Sema` 구조체(전역 모델) | 02 챕터 |
| 9679-9825 | 문자열 이스케이프, `InitBuilder` | |
| 9826-10013 | 타입 생성 헬퍼(`getPtrType`, `getOptionType` 등) | 02 챕터 |
| 10014-10594 | 문자열 리터럴 코드포인트, `semaUnwrapOrStmt`, `semaFitTarget`, 리터럴 파싱 | |

### 4.3 나머지 파일 지도

| 파일 | 줄 | 내용 |
|---|---|---|
| `sema_func.zig` | 1-110 | `FuncResult`, `Argument`(standard, receiver, pre_resolved) |
| | 114-297 | 템플릿 함수 매칭(`matchGenericFuncCt/Rt`, `genFunc`) |
| | 335-418 | `matchFuncRt`, `matchFunc` (컴파일타임/런타임 분기) |
| | 504-669 | `matchFuncSig`, `matchFuncSym2`, `matchFuncSym` (오버로드 루프) |
| | 671-815 | 컴파일타임 매칭 `matchFuncCt`, 오버로드 |
| | 817-983 | `ownOrManageArg`, `resolveRtArg` |
| | 985-1272 | 템플릿 인자 매칭, `matchArg` |
| | 1274-1302 | 불일치 에러 메시지 `reportCallFuncMismatch` |
| | 1304-1429 | 템플릿 인자 추론 `inferCtArgs` |
| `cte.zig` | 18-96 | `evalFunc`, `evalFuncBody`, `evalStmts`, `localDecl` |
| | 98-388 | `switchStmt`, `forRangeStmt`(컴파일타임) |
| | 389-557 | 대입(`eval_assign`), `evalStmt` |
| | 559-630 | `eval`, `evalTarget`, `evalCheck` 진입점 |
| | 632-880 | 호출(`evalCallExpr`, `evalCall`), `ExprCstr` |
| | 883-1296 | 값 변환, 타입 평가, 구조체/벡터 초기화 |
| | 1297-1947 | `evalExprNoCheck` 거대 switch |
| | 1948-2460 | 이름, 단항, 이항 평가 |
| | 2461-2803 | 문자열, 접근, `evalCZero`, 리터럴 |
| `ct_inline.zig` | 13-188 | `value`(컴파일타임 값에서 IR 상수) |
| | 190-346 | `evalTopStmts`, `evalStmts`, `evalStmt`, `ifStmt` |
| `ir.zig` | 1-26 | 설계 주석 |
| | 27-206 | `StmtCode`, `Stmt`, `ExprCode`, `Expr` |
| | 208-690 | 노드 구조체들 |
| | 693-800 | `StmtImpl`/`ExprImpl` (코드에서 구조체 매핑) |
| | 803-911 | `Buffer` (arena, 문장 리스트 스택) |
| | 913-1139 | 방문자 `visitStmts` (낡음, 7절) |

## 5. 실습

아래 출력은 모두 이 저장소 HEAD 에서 실제로 실행한 결과다. 실험 파일은 작업 폴더에 `t2.cy` 처럼 만든다. 릴리스 CLI 는 `zig-out/bin/cyber`, 트레이스 CLI 는 `-Dtrace=true`(`build.zig:50`)로 따로 빌드한 바이너리다. 트레이스 빌드는 `-v` 로 컴파일 단계 로그를 낸다.

### 5.1 트레이스 로그 읽는 법

`-v` 출력은 크므로 반드시 파일로 받아서 `rg` 로 본다. 단계 접두사별 분량(5.2 의 `t2.cy`, 총 72,964줄)은 다음과 같았다.

```
$ cyber -v t2.cy > t2.trace 2>&1
$ cut -d' ' -f1 t2.trace | sort | uniq -c | sort -rn | head -5
35358 bc_gen:
 7271 cte:
 6632 sema:
 6297 chunk:
 6271 ir:
```

sema 와 IR 로그는 두 종류다. `sema: stmt.X` / `sema: expr.X` 는 `semaStmt`/`semaExprNoCheck` 진입 시(`sema.zig:376`, `:6337`), `ir: ir expr: .code Type` / `ir: ir stmt: .code` 는 노드가 만들어지는 순간(`ir.zig:861`, `:874`)에 찍힌다. 따라서 IR 로그는 후위 순회(자식이 먼저) 순서다. 단계 경계는 `compiler: emit program.`(main sema 시작), `sema: pop main block`(main 끝), `compiler: Perform sema.`(각 함수), `compiler: sema func: 이름`, `compiler: Perform codegen.` 이다. `nop_label` 문장은 `semaTraceNopFmt` 가 Trace 빌드에서만 만드는 것이라 릴리스 IR 에는 없다.

### 5.2 if + 함수 호출 + Option 언랩이 IR 이 되는 과정

```
fn find(x int) -> ?int:
    if x > 2:
        return x * 2
    return none

r := find(5)
if r |v|:
    print(v)
```

main 블록(`emit program.` ~ `pop main block`)의 `sema:`/`ir:` 로그에서 `nop_label`, 식 종료 줄, 주소 접미사를 걸러낸 결과다.

```
sema: stmt.var_decl: "r := find(5)"
ir: stmt: .declare_local              <- init 은 비어 있음(스텁). 아래 call 이 나중에 init 이 된다
ir: expr: .const64 Int                <- 인자 5 (기대 타입 int)
ir: expr: .call Option                <- find(5)
sema: stmt.if_unwrap_stmt: "if r |v|:
ir: expr: .local Option               <- r
ir: stmt: .declare_local              <- _opt (숨은 지역, 초기값 = local r)
ir: expr: .local Option               <- semaLocal(_opt)
ir: expr: .field Int                  <- _opt 의 태그 (idx 0)
ir: expr: .is_zero bool               <- 태그 == 0 (none?)
ir: expr: .unary_op bool              <- lnot
ir: expr: .field Int                  <- _opt 의 payload (idx 1)
ir: stmt: .declare_local              <- v = payload
sema: stmt.exprStmt: "print(v)"
ir: expr: .local Int
ir: expr: .call void                  <- print[int](v)
ir: stmt: .discard
ir: stmt: .if_block                   <- cond = lnot(is_zero(...)), body = [declare v, discard]
ir: stmt: .block                      <- semaIfUnwrapStmt 의 바깥 블록
ir: expr: .call void                  <- @program_deinit 호출
sema: pop main block
```

`find` 함수 본문(`sema func: find` 구간)은 다음과 같다.

```
ir: stmt: .funcBlock                  <- pushFuncProc 가 만든 스텁
sema: stmt.if_stmt: "if x > 2:
ir: expr: .local Int / .const64 Int / .cmp bool            <- x > 2
sema: stmt.returnExprStmt: "return x * 2"
ir: expr: .local Int / .const64 Int / .imul Int            <- x * 2 (정수 전용 노드)
ir: expr: .const64 Int / .init Option                      <- Some(...): 태그 1 + payload
ir: stmt: .set_ret / .ret                                  <- 반환 슬롯에 쓰고 반환
ir: stmt: .if_block / .block
sema: stmt.returnExprStmt: "return none"
ir: expr: .init Option / .const64 Int / .voidv void        <- none: 태그 0 + 빈 payload
ir: stmt: .set_ret / .ret / .trap                          <- trap 은 Trace 빌드만
```

로그의 생성 순서와 코드(`semaIfUnwrapStmt`, `semaReturnExprStmt`)를 맞춰 재구성한 IR 트리는 다음과 같다.

```
mainBlock
  discard call @program_init
  declare_local r(0) init=call(find, const64 5)
  block
    declare_local _opt(1) init=local r(0)
    if_block cond=unary_op(lnot, is_zero(field(local _opt, idx0)))
      declare_local v(2) init=field(local _opt, idx1)
      discard call(print[int], local v)
  discard call @program_deinit

funcBlock find(x)
  block
    if_block cond=cmp(gt, local x, const64 2)
      set_ret init(Option, const64 1, imul(local x, const64 2))
      ret
  set_ret init(Option, const64 0, voidv)
  ret
```

`cyber compile t2.cy` 의 `find` 함수 바이트코드는 이 IR 과 구조가 거의 1:1 이다.

```
--0 `fn find`
0:181 .chk_stk: ret=2, frame=12
0:184 .const_16s: %8 = 2
0:187 .gt: %7 = %6 > %8                 <- cmp(gt)
0:191 .jump_f: if (!%7) jmp @217        <- if_block
0:194 .addr: %8 = &%0                   <- init(Option) 의 저장 위치 (반환 슬롯)
0:197 .const_16s: %9 = 1
0:200 .const_16s: %11 = 2
0:203 .imul: %10 = %6 * %11             <- imul
0:207 .store_64: [%8 + 0] = %9          <- 태그 1
0:211 .store_64: [%8 + 8] = %10         <- payload
0:215 .ret_n: ret %0..%2                <- set_ret + ret
0:217 .addr: %7 = &%0
0:220 .const_16s: %8 = 0
0:223 .store_64: [%7 + 0] = %8          <- none: 태그 0
0:227 .ret_n: ret %0..%2
```

같은 덤프의 main 에는 `find` 호출 자체가 없다. fork 의 leaf 함수 인라이닝이 `find(5)` 를 펼쳤기 때문이다(`docs/decisions/project_bc_inline.md`, 04 챕터).

### 5.3 다른 구성이 만드는 IR 순서 (같은 방법으로 관찰)

| 소스 | 관찰한 IR 생성 순서 (요지) |
|---|---|
| `c := a + b` (``fn (&P) `+`(o P) -> P`` 정의) | `local P`, `address_of Borrow`, `local P`, `call P`. `add` 노드 없음 |
| `for list \|it\|: sum += it` | `_iterable`, `iterator`, `_counter`, `_opt` 선언 4개 → `field`, `is_zero`, `unary_op`, `field` → `declare it` → `add`, `set_local`, `block`, `continue_`, `if_block`, `loop_block`, `block` |
| `v := may_fail(x)!` | `call Result`, `_temp`, `address_of`, `_res_addr`, `field`, `is_zero`, `field error`, `case error`, `init Result`, `init_case`, `set_ret`, `ret`, `if_block`, `field Int`, `case Int`, `set_local`, `pop_locals` |
| `switch s: case .line \|l\|:` (choice) | `address_of`, `control` 선언, `deref`, `field`(태그), `_choice_tag`, `_cond` 선언, `binary_op`, `case_cond`, `field Float`, `declare l`, 본문, `switch_case`, 다음 case, `switch_stmt`, `pop_locals` |
| `a := ^123` 함수에서 `return a.*` | `declare_local`(`lift Ref`), `deref`, `set_ret`, `release`, `ret` |
| `foo := fn() => a.*` | `funcBlock`(lambda), `captured Ref`, `deref`, `set_ret`, `ret`, `lambda Func`, 호출 때 `local Func`, `call_union`. 끝에 `release` 두 번 |
| `#for 0..3 \|i\|: print(#{i * 10})` | `exprStmt` 가 세 번, 각 `const64 Int` + `call void` + `discard` |
| `opt ?else 123` | `declare _temp`, `_opt`, `field/is_zero/unary_op/field`, `set_local`, `break_`, `if_block`, `const64`, `set_local`, `block` |

### 5.4 컴파일 에러에서 sema 함수까지 거슬러 올라가기

두 가지 도구를 쓴다. (1) 메시지 문구를 `rg -n` 으로 소스에서 찾는다. (2) 트레이스 빌드의 마지막 `sema:` 로그 줄이 "에러 직전에 어느 문장/식을 처리 중이었는지"를 알려 준다.

| 소스 | 출력된 메시지 | `rg -n` 로 찾은 곳 | 호출 경로 |
|---|---|---|---|
| `fn foo(a bool): pass` / `foo(123)` | Expected argument `bool`, found `int`, when calling `fn foo(bool) -> void`. | `sema_func.zig:1301` | `matchFuncSym2` → `matchFuncSym` → `matchFunc` → `matchFuncRt` → `matchFuncSig`(불일치) → `reportCallFuncMismatch` |
| `x := 1` / `x + 2` | Expected assignment to a variable or placeholder for `int`. | `sema.zig:357` | `semaStmt` → `semaExprStmt` (값 있는 식을 버림) |
| `fn bar() -> int:` 본문이 `x := 1` 뿐 | Missing return statement. | `sema.zig:9141` | `semaFuncBody2` → `procPrologue` (끝에 닿는데 void 아님) |
| `try:` / `else err:` | Unsupported statement: tryStmt (2026-11-09 이후 `try:` / `else \|err\|:` 가 동작하고, 이 구문은 `Expected colon.`) | `sema.zig:677` | `semaStmt` 의 `.tryStmt` 분기 → 지금은 `sema_try_stmt` |
| `n := 1` / `fn() -> int: return n` | Can only capture variables declared with the reference types `^T` or `&T`. | `sema.zig:5066` | `semaIdent` → `lookupIdent` (부모 지역을 찾았는데 값 타입) |
| `case k:` (k 는 런타임 지역) | Could not find the symbol `k`. | `cte.zig:1950` | `semaSwitchBody` → `semaCaseCond` → `cte.evalTarget` → `eval_ident` |
| `1!` (`try_error.cy`) | Expected type instance of `Result`, found `int`. | `sema.zig:10592` 또는 `cte.zig:585` | 트레이스 마지막 줄이 `sema: expr.unwrap_res: "1!"` 와 `expr.decLit` → `sema_expr_cstr_template` |

마지막 행은 같은 문구가 두 곳에 있어서 `rg` 만으로는 단정할 수 없다. 트레이스를 보면 에러 직전 로그가 `sema: expr.unwrap_res: "1!"`, `sema: expr.decLit: end Int` 로 끝나고 `cte:` 줄이 뒤따르지 않아, `unwrap_res` 분기(`sema.zig:6963`)가 부른 `sema_expr_cstr_template`(`:10587`)로 좁혀진다. 세 번째 행의 트레이스 끝에는 `fn bar` 안의 `sema: stmt.var_decl: "x := 1"` 와 `expr.decLit` 가 있고 그 뒤에 바로 에러가 찍혔다. 함수 본문을 다 훑은 뒤 `procPrologue` 에서 나온 에러라는 뜻이다.

모든 에러는 `CompileError` 하나로 위로 올라오므로 호출 스택은 에러 리포트에 남지 않는다. 대신 `resolve_stack` 의 `caller` 가 리포트 뒤에 줄을 덧붙인다(`chunk.zig:616`). `const s = sum_to(10)` 안에서 난 에러가 `sum_to` 안의 위치(`4:5`)와 호출한 위치(`9:11`) 두 줄을 함께 보여 준 것이 그 예다(5.6).

### 5.5 `--cytest` 주석은 기대 결과를 어떻게 적는가

테스트 `.cy` 파일은 마지막에 `--cytest: pass | error | panic` 줄을 둔다(`src/behavior_test.zig:621-629`). `error` 이면 그 아래 `--` 로 시작하는 줄들이 기대 리포트이고(주석 기호 `--` 를 지워서 비교, `:629-650`), `@MainPath()` 는 테스트 파일 경로로 치환된다(`src/test/setup.zig:477`).

```
fn foo(a bool):
    pass
foo(123)

--cytest: error
--CompileError: Expected argument `bool`, found `int`, when calling `fn foo(bool) -> void`.
--
--@MainPath():3:5:
--foo(123)
--    ^~~
```

`src/test/functions/call_incompat_param_error.cy` 를 CLI 로 직접 실행하면 같은 메시지가 `줄:열`(`3:5`)과 함께 출력된다. 각 테스트는 `behavior_test.zig` 안에서 `run.case("functions/call_incompat_param_error.cy")` 로 등록되어야 `zig build test` 가 돌린다. 등록은 278줄이고 10줄은 주석 처리되어 있다. `src/test` 안의 `cytest:` 마커는 288개(`error` 116, `panic` 23, `pass` 149)다. 주석 처리된 예가 `control_flow/unreachable_error.cy` 다. 파일 첫 줄이 "Skip test. For now, statements are still allowed after unreachable for convenience." 이고 `behavior_test.zig:410` 에서 등록이 빠져 있다. `sema.zig:381-383` 에서 "Unreachable statement." 검사가 주석 처리된 것과 짝이다.

### 5.6 컴파일타임 평가 실험

```
$ cyber x.cy          # fib 재귀 + const fib20 = fib(20); print(fib20); print(fib(20)); print(#{fib(10)})
6765
6765
55
```

`while` 은 컴파일타임에 못 돈다. `sum_to` 가 `while i < n:` 루프를 쓰고 `const s = sum_to(10)` 로 호출하면 다음과 같이 두 위치가 함께 나온다.

```
CompileError: Inline eval: Unsupported whileCondStmt.

x.cy:4:5:
    while i < n:
    ^~~~~~~~~~~~
x.cy:9:11:
const s = sum_to(10)
          ^~~~~~~~~
```

`for 0..n |i|` 로 바꾸면 컴파일은 되는데 값이 틀린다. 아래는 실제로 발견한 버그의 최소 재현이다(7절).

```
fn f() -> int:
    t := 10
    t += 5
    return t

print(f())          # 런타임: 15
const x = f()
print(x)            # 컴파일타임 평가: 5
print(#{f()})       # 컴파일타임 평가: 5
```

실행 결과는 `15`, `5`, `5` 였다. 같은 파일에서 `t = t + 5` 로 쓰면 `15` 가 나왔다. `for 0..10 |i|: total += i` 를 `const` 로 평가하면 45 대신 마지막 `i` 인 9 가 나왔다.

### 5.7 그 밖에 직접 확인한 항목

- 리터럴 추론: `a := 5`, `var b float = 5`, `var c i8 = 5`, `var d ?i32 = 7` 은 IR 이 각각 `const64 Int`, `const64 Float`, `const8 Int`, `const32 Int` + `const64 Int` + `init Option` 이었다. `var d i8 = 300` 은 "Parsing decimal literal overflows integer type." 에러다.
- 캐스트: `n := 300` 일 때 `a := as[i8] n` 은 `Int[].@init` 호출이 되어 실행 중 "panic: Lossy conversion from `300` to `i8`" (`core.cy:433`)로 죽는다. `f := as[float] n` 은 호출 없이 `i2f` 노드다.
- 함수 밖 최상위에서 `#if meta.system() == .macos:` 아래에 `print('macos')` 를 두면 "Only compile-time statements are allowed in this context." 에러다(`ct_inline.zig:274`). 같은 `#if` 를 함수 안에 두면 실행된다.
- `none.?`: `?int`, `?str`, `?^Foo` 반환값에 `.?` 를 붙여 실행하면 세 경우 모두 `panic: Expected active choice tag `1`, found `0`.` 이다. `cyber compile` 덤프에서 `?int` 는 `unwrap_addr`, `?^Foo`(zero_union)는 `unwrap_nz` 명령이 나왔다.
- 제너레이터: `#[generator] fn count(n int) -> int:` (`i := 0; while i < n: yield i; i += 1`)에서 `g.next().?` 를 세 번 출력하면 `0`, `-9223372036854775806`, `-9223372036854775787` 이 나왔다. `.?` 의 문제가 아니라 제너레이터가 돌려주는 값 자체가 틀린 것으로 보인다(추정, 07 챕터).
- `cyber -cc x.cy` 와 `-tcc`: `CompileError: Expected function implementation.` (core.cy 의 첫 `#[bind]` 에서, `sema.zig:2870`).
- 컴파일타임 평가에서 지원하지 않는 식: `const x = f(1)` 의 `f` 안에 문자열 보간(`'a%{n}'`)을 쓰면 "Unsupported compile-time expression: `stringt`", 람다(`fn(a int) => a + n`)를 쓰면 `lambda_expr` 로 같은 에러가 난다.
- `if false: this_function_does_not_exist()` 는 `Undeclared variable` 에러. `#if false:` 는 에러가 없다. 런타임 `if` 는 죽은 분기도 sema 하지만 `#if` 는 아니다.
- `var d i8 = 300` → `Parsing decimal literal overflows integer type.`
- `try: ... else err: ...` → `Unsupported statement: tryStmt`. 문서(`docs/docs.md:2667-2670`)의 `catch err:` 형태는 파서에서 "Expected catch block." 로 거부된다. 2026-11-09 F-32 로 `else |err|:` 캡처 구문이 구현됐고, `else` 가 없으면 "Expected else block.", 캡처가 식별자가 아니면 "Expected error variable." 이다.

### 5.8 변형 과제

1. 5.2 의 `t2.cy` 에서 `if r |v|:` 를 `x := r.?` 로 바꿔 트레이스를 다시 떠 보자. `unwrap_addr`/`address_of` 가 어디에 나오는가? `r` 의 타입을 `?^Foo` 로 바꾸면 `unwrap_nz` 로 바뀌는가?
2. `find` 에 `else x < 0:` 분기를 더하고 `block` 안의 `break_` 개수를 세어 보자. 마지막 분기에 `break_` 가 없는 이유를 `semaIfBlock` 의 `is_last` 로 설명해 보자.
3. `fn foo(a int)` 와 `fn foo(a float)` 를 둘 다 선언하고 `foo(1)`, `foo(1.5)`, `n := 1; foo(n)` 을 호출하자. 선언 순서를 바꾸면 결과가 달라지는가? (직접 실행한 결과: `int` 를 먼저 선언하면 `int`, `float`. `float` 를 먼저 선언하면 `foo(1)` 도 `foo(n)` 도 `float` 가 나왔다. `semaFitTarget` 의 `int` → `float` 암시적 변환과 `matchFuncSym` 의 순서 규칙으로 설명해 보자.)
4. 5.6 의 재현 코드가 틀린 원인(`cte.zig:423`)을 읽고, `eval_assign_right` 를 쓰도록 고치는 패치를 `src/` 가 아닌 별도 브랜치에서 작성해 보자. `src/test/meta/` 에 `+=` 를 쓰는 `const` 케이스를 추가하고 `behavior_test.zig` 에 등록해야 `zig build test` 가 돌린다.
5. `#[consteval] fn` 하나를 만들어 `if`/`for`/`switch` 만으로 간단한 함수를 쓰고 `const` 에서 호출해 보자. 같은 함수에 `while` 을 넣으면 에러 위치가 어떻게 나오는가?
6. `n := ^1` 로 박싱한 변수를 람다가 캡처하는 코드의 IR(`lambda`, `captured`, `call_union`)을 트레이스로 확인하고, 박싱하지 않은 경우의 에러를 비교해 보자.

## 6. 0.3 -> 0.4 변경 관점 / 설계 철학 메모

### 6.1 git 으로 확인한 변화

`git show <rev>:src/<파일> | wc -l` 로 잰 줄 수다. 괄호 속 0 은 그 시점에 파일이 없다는 뜻이다.

| 파일 | 0.3 (2023-12-10) | `c992b94e` (구간 A 끝, 2024-09-23) | `b751ca6c` (구간 B 본체, 2025-11-21) | HEAD |
|---|---|---|---|---|
| `sema.zig` | 4,383 | 7,430 | 10,082 | 10,594 |
| `sema_func.zig` | (0) | 809 | 1,585 | 1,429 |
| `cte.zig` | (0) | 864 | 2,465 | 2,803 |
| `ct_inline.zig`, `sema_type.zig`, `template.zig` | (0) | (0) | 389, 1,323, 540 | 380, 1,339, 540 |
| `ir.zig` | 672 | 1,088 | 1,137 | 1,140 |
| 컴파일 지휘 | `vm_compiler.zig` 1,093 | `compiler.zig` 1,323 | 1,479 | 1,516 |
| `bc_gen.zig` | 3,551 | 4,617 | 3,380 | 3,432 |

- IR 은 0.4 에서 생긴 것이 아니다. `ir.zig` 는 2023-11-15 커밋 `58fcebfc`("Rewrite sema to codegen. ...")에서 처음 생겼고 0.3 태그보다 앞선다. `docs/history/embedding_cli.md:15` 가 0.3 릴리스 노트 항목으로 "Compiler rewrite" 를 적고 있다. 이 항목이 위 커밋을 가리킨다는 것은 시기와 메시지에 근거한 추정이다(릴리스 노트 원문은 저장소에서 확인하지 못했다).
- 0.3 의 IR 은 진짜 선형 배열이었다. `c992b94e` 의 `Buffer` 도 `buf: ArrayList(u8)` 와 `func_blocks: ArrayList(Loc)`(인덱스)였다. arena 와 포인터 방식으로 바뀐 것은 `b751ca6c` 한 커밋 안이다(`b751ca6c^` 의 `func_blocks` 는 `Loc`, `b751ca6c` 에서는 `*Stmt`). 그래서 7절의 낡은 주석이 생겼다.
- 구간 A 의 IR 관련 커밋 제목들은 IR 이 풀어 쓰는 쪽으로 정리된 흔적이다. "Block and block expr IR"(`10784c6c`), "Expr type IR"(`96f3c3bc`), "Reduce while variants to loop IR"(`b235d641`), "Flatten root IR"(`cc058615`). `cte.zig` 는 `233f7c48`("Generics for object types using cte template expansion", 2024-02-11)에서 처음 생겼고, 컴파일타임 함수 호출, 람다, `#if` 는 2024-08~09 에 들어왔다(`02fda3e7`, `f2306ae3`, `2c08d9a5`). `sema_func.zig` 는 `71cfacac`("Refactor function matching", 2024-07-10)에서 분리되었다.
- `b751ca6c`("[all] some updates") 한 커밋이 `sema.zig` 에서만 13,318줄을 바꿨고 `sema_type.zig`, `template.zig`, `ct_inline.zig` 를 새로 만들었다. 메시지에 이유가 없다.

sema 가 왜 커졌는지는 개념어 출현 횟수로 추정할 수 있다. `rg -c <패턴> src/sema.zig`(해당 줄 수)를 0.3 과 HEAD 에서 비교했다.

| 패턴 | 0.3 | HEAD | 패턴 | 0.3 | HEAD |
|---|---|---|---|---|---|
| `borrow` | 0 | 166 | `ResolveContext` | 0 | 72 |
| `Lifetime` | 0 | 8 | `semaDestruct` | 0 | 35 |
| `semaOwn` | 0 | 39 | `popLocals` | 0 | 23 |
| `semaManage` | 0 | 18 | `template`/`Template` | 6 | 192 |
| `sema_copy` | 0 | 7 | `dyn`/`Dyn` | 103 | 2 |

0.3 에 없던 소유권/빌림, 소멸자 삽입, 템플릿, 컴파일타임 컨텍스트가 sema 안으로 들어왔고, 동적 타이핑 관련 분기는 거의 사라졌다. 이것은 숫자에서 끌어낸 추정이며 커밋 메시지로 뒷받침되지는 않는다. fork 이후(0.4.1 태그의 `sema.zig` 10,487줄에서 HEAD 10,594줄)의 변화는 작다. 상수 접기(`5171b7fa`), 반환 지역 이동(`eb060d5e`), REPL 지역 이어받기(`e541090a`, `sema_program` 의 `persist_main` 블록 `sema.zig:4571-4585`), 컴파일타임 루프 결과 초기화(`87d4c3ed`)가 전부다.

### 6.2 설계 철학 메모

sema 의 설계를 한 문장으로 줄이면 "코드젠을 얇게 하려고 sema 에 모든 의미 결정을 모은다"이다. 그 대가로 sema 는 (1) 한 패스에서 검사와 변환과 수명 삽입을 다 하고, (2) 첫 에러에서 `CompileError` 로 중단하며(복구 없음), (3) 언어의 의미를 런타임과 컴파일타임에서 두 번 구현한다.

fork 를 유지보수하는 입장에서 시사점은 다음과 같다.

- 새 문법을 넣는 위치는 정해져 있다. 파서와 AST → `semaStmt`/`semaExprNoCheck` 분기 → (컴파일타임에서도 필요하면) `cte.evalStmt`/`evalExprNoCheck` 분기 → 새 IR 노드가 필요하면 `ir.zig` 정의 + `bc_gen.genStmt`/`genExpr` 분기. 테스트는 `src/test/<분류>/*.cy` 에 `--cytest:` 마커를 쓰고 `behavior_test.zig` 에 `run.case` 로 등록한다. 새 IR 노드를 추가해도 `ir.visitStmts` 는 손대지 않는 편이 낫다(7절).
- 건드릴 때 조심할 곳은 세 군데다. 오버로드 시도의 IR 롤백(`sema_func.zig:647-658`), cte 와 런타임의 의미 불일치(7절 버그 1), 그리고 `popLocals`/`semaDestructBlock2` 의 호출 위치(소멸자 누락이나 이중 해제가 여기서 생긴다. Trace 빌드의 `check_locals` 가 일부를 잡아 준다).
- 코딩 에이전트 루프(CodeAct)처럼 짧은 스크립트를 매우 자주 실행하는 용도에서는 이 구조의 시작 비용이 관건이다. 릴리스 CLI 로 `print(1)` 한 줄을 20번 돌린 총 시간이 0.108초(회당 약 5ms)였다. 이 안에 core.cy 전체의 컴파일이 포함된다(`cyber compile` 덤프에 함수 196개). `cache.zig` 는 URL import 와 자산 캐시용이고 컴파일 결과 캐시는 코드에서 확인하지 못했다(미확인). 에러가 첫 번째 하나만 나온다는 점은 에이전트에게 에러를 돌려줄 때 한 번에 하나씩 고치게 만든다는 뜻이다(구조에서 읽은 추정).

## 7. 알려진 이슈, 문서와 코드의 차이, 미완 지점

### 7.1 직접 재현한 버그와 한계

1. cte 복합 대입 무시. `cte.zig:423`(컴파일타임 변수 대입)과 `:460`(벡터 원소 대입)은 `rec_op`(복합 연산자 정보)를 버리고 오른쪽 식만 평가한다. `.deref` 분기만 `eval_assign_right` 를 쓴다(`:436`). 5.6 의 `t += 5` 가 `15` 대신 `5` 가 된다. `src/test/meta` 에 `+=` 를 쓰는 케이스가 없어서 테스트에 걸리지 않는다. 영향 범위는 `const` 초기화, `#{}`, `type ... const:` 본문, `#[consteval]` 함수 안의 `+=`, `-=` 등이다. 2026-11-08 수정 `02f39e67`: `eval_assign_right(c, right, rec_op, target_t)`가 세 분기 모두에서 `left op right` 를 평가하고 목적지 타입을 검사한다. 컴파일 타임 벡터 원소 읽기와 범위 검사도 함께 넣었다(`docs/decisions/project_cte_op_assign.md`). 테스트 `meta/ct_op_assign.cy` 는 같은 함수를 런타임과 `const` 로 실행해 비교한다.
2. 지역 변수 257개부터 컴파일러가 죽는다. IR 지역 번호가 `u8`(`LocalVarS.id`)이라 `@intCast(local_id)`(`sema.zig:3416`, 파라미터는 `:3343`)가 넘친다. 한 함수에서 지역 `a0` ~ `a255`(256개)는 통과했고 257개에서 "panic: integer does not fit in destination type" 이 났다(main 블록은 300개에서 확인). `CompileError` 가 아니라 컴파일러 프로세스 패닉이다. 숨은 임시 지역(`_opt`, `_temp` 등)도 번호를 쓰므로 실제 한계는 사용 패턴에 따라 더 낮다. 생성된 코드를 실행하는 에이전트 루프에서는 만날 수 있는 조건이다. 2026-11-08 수정 `04096230`: `reserveLocalName` · `declareParam`이 번호를 매기기 전에 `checkLocalLimit`로 256개 초과를 `CompileError`("Too many local variables. A function can have at most 256 locals, including hidden temporaries.")로 보고한다. 같은 u8 계열인 매개변수 255개 초과(`resolveFuncSig` · `pushLambdaFuncParams` · `resolveFuncType`, "Too many parameters."), 구조체 필드 255개 초과(`resolveStructFields` · `reifyStructType`, "Too many fields."), C 가변 인자 호출의 인자 255개 초과(`getVmCVariantFunc`, "Too many arguments.")도 같은 방식이다. 폭을 u16으로 넓히는 길은 IR extern 구조체 · `FuncParam.reg` · 바이트코드 레지스터 번호까지 번지므로 택하지 않았다.
3. `try ... else err:` 는 파싱되지만 sema 가 항상 "Unsupported statement: tryStmt" 로 거부한다(`sema.zig:673-678`). 같은 구문의 IR 노드(`tryStmt`), `bc_gen.gen_try_stmt` 가 남아 있다. 2026-11-09 F-32 로 구현됐고 죽은 IR · 코드젠은 지웠다(`docs/decisions/project_try_block.md`).
4. 오버로드 시도 롤백이 미완이다(`matchRtOverload` 의 TODO). 5.4 에서 다룬 대로 실제 오동작은 찾지 못했다(미확인). 선언 순서가 결과를 바꾸던 F-21 은 2026-11-08 `cf4aa84a` 로 고쳤다(`docs/decisions/project_overload_exact_match.md`).
5. 클로저는 참조형(`^T`, `&T`) 지역만 캡처하고 바로 위 `Proc` 한 단계만 본다(`sema.zig:5066`, `:5115`). 값 타입 캡처는 `TODO: Capture non-reference stack variables too.`(`:5063`).
6. `cyber -cc`/`-tcc` 는 sema 단계에서 실패한다(`sema.zig:2870`). C 백엔드(`cgen.zig`)는 이 IR 을 읽도록 작성되어 있으나 현재 core.cy 와는 맞지 않는다.

### 7.2 문서와 코드의 차이

| 문서/주석 | 코드 |
|---|---|
| `ir.zig:20-25` IR 은 선형 배열이고 위치로 색인 | arena 에서 노드마다 `create` 하고 포인터로 연결(`ir.zig:860-888`) |
| `ir.zig:802` "IR ops use an explicit index since the underlying buffer can grow." | 위와 같은 이유로 낡은 주석 |
| `ir.zig:11` IR 은 코드젠이 소비한 뒤 버려진다 | 청크 arena 이므로 `Chunk.deinit` 때까지 유지(`chunk.zig:313`) |
| `ir.zig:913-1139` `visitStmts`/`visitExpr` 방문자 | 존재하지 않는 코드(`.byte`, `.float`, `.int`)와 필드(`numArgs`, `src_ptr`)를 참조한다. Zig 는 쓰이지 않는 함수를 분석하지 않아 컴파일이 통과한다. 쓰는 곳은 `dce.zig` 뿐이고 `enable_dce = false` |
| `docs/docs.md:2667-2670` `try:` / `catch err:` | 파서는 `else`(`parser.zig:1876`)를 기대하고 sema 는 어느 쪽이든 거부. 2026-11-09 F-32 로 `else |err|:` 가 동작하고 매뉴얼의 `catch err:` 문단은 삭제 |
| `docs/docs.md:3015` 인라인 평가는 "전체 언어를 흉내 낼 수는 없다" | 맞다. 문장은 `cte.zig:480-557` 의 9종, `while` 없음 |
| `.?` 가 none 에서 패닉하지 않고 쓰레기 값을 읽는다는 보고(제너레이터에서 관찰) | 직접 `.?` 는 `?int`, `?str`, `?^Foo` 모두 패닉(5.7). 제너레이터 값 문제는 별개로 추정 |

### 7.3 미완 지점 (코드에 TODO 나 막힌 분기로 남은 것)

- sema 가 만들지 않는 IR 코드: `ret_expr`, `set`, `dumpBytecode`, `verbose`, `closure`, `mainEnd`, `vector`, `partial_vector`(2.8절). `ret_expr` 는 `sema.zig:857` 의 TODO 최적화, 나머지는 옛 설계의 잔재로 보인다(추정). `tryStmt` 는 2026-11-09 에 지웠다.
- "Unreachable statement." 검사 비활성(`sema.zig:381-383`), 연결된 테스트는 주석 처리(`behavior_test.zig:410`).
- `if opt |[a, b]|` 같은 구조 분해 캡처는 즉시 `TODO` 에러(`sema.zig:1101-1106`). `yield` 인자 없음도 `TODO`(`:748`), 타입 추론 없는 `{...}` 리터럴은 "TODO: infer tuple type"(`:7253`).
- `docs/decisions/project_ct_eval_loop_result.md` 의 "남은 문제": `type ... const:` 본문이 기존 타입(`int` 등)을 반환하면 `resolve_type_const` 가 그 타입의 이름과 부모를 덮어써 오염시킨다(`sema_type.zig:27-30`). 현재 내장 type const 는 모두 새 타입을 만들어 반환해서 드러나지 않는다.

## 8. 이해도 확인 Q&A

### Q1. `semaExpr` 가 `ExprResult` 에 `owned`, `resType`(`value_local` 등), `parent_local` 까지 들고 올라오게 한 이유는 무엇인가?

A: 소유권과 이동 판단에 필요한 정보가 식 하나 안에 없고 "이 식이 어디서 왔는지"에 있기 때문이다. `return s` 에서 `implicitReturnMoveLocal` 은 `resType == value_local` 이고 `owned == false` 인 managed 지역만 이동으로 바꾼다(`sema.zig:994`). `sink` 파라미터는 `value_local` 인 인자의 원본을 `.dead` 로 만든다(`sema_func.zig:853-860`). 빌림은 `parent_local` 로 소유자의 `active_borrows` 를 센다. 타입과 IR 만 올라오면 이런 판단을 할 때마다 AST 를 다시 읽어야 한다.

### Q2. 오버로드를 "선언 순서대로 처음 성공하는 것"으로 고르면 어떤 문제가 생기는가? 이를 완화하는 장치는 무엇인가?

A: 선언 순서가 의미를 바꾼다. `foo(int)` 와 `foo(float)` 를 `float` 먼저 선언하면 `foo(1)` 은 물론 `int` 변수를 넘긴 `foo(n)` 도 `float` 오버로드가 선택됐다(직접 실행, 2026-11-08 `cf4aa84a` 전). `int` → `float` 이 암시적 변환이라 먼저 선언된 후보가 성공하기 때문이다. 지금은 변환 없이 맞는 후보를 먼저 찾는 1단계가 앞에 있어 `foo(n)` · `foo(1)` 모두 `int` 로 간다. 시도에 실패한 오버로드가 만든 숨은 지역과 문장은 되돌려야 하는데 그 코드에 TODO 가 있다(`sema_func.zig:653`). 장치는 `Cstr.return_infer_error`(오버로드 중이면 리터럴 추론 실패를 에러 대신 `infer_error` 로 반환)와 `varStack`/문장 꼬리 복원이다. 그리고 모두 실패했을 때는 가장 멀리 간 후보를 에러에 쓴다.

### Q3. `#if false:` 안의 `this_function_does_not_exist()` 는 에러가 없는데 `if false:` 안에서는 에러가 난다. 왜 이렇게 설계했는가?

A: `#if` 는 조건을 cte 로 먼저 평가하고 선택된 분기만 `semaStmts` 에 넘긴다(`ct_inline.ifStmt`, `ct_inline.zig:314`). 선택되지 않은 분기는 sema 를 거치지 않으므로 이름 해석도 일어나지 않는다. 일반 `if` 는 조건이 상수여도 런타임 분기이므로 양쪽을 모두 sema 해서 타입을 검사한다. 이 차이가 곧 조건부 컴파일(플랫폼별 코드, 템플릿 인자별 코드)을 가능하게 한다. 일반 지식으로, C 의 `#if` 가 전처리 단계에서 선택되지 않은 분기를 버리는 것과 비슷한 효과다.

### Q4. `fn f()` 안의 `t += 5` 가 런타임에서는 15, `const x = f()` 에서는 5 가 된다. 이 불일치가 구조적으로 생기기 쉬운 이유와 재발 방지 방법은?

A: 같은 언어를 두 곳에서 구현했기 때문이다. 바이트코드 경로는 `semaAssignStmt` 가 복합 대입을 `semaBinExpr` 로 풀지만(`sema.zig:430`, `:7623`), cte 의 `eval_assign` 은 대입 대상 종류마다 따로 오른쪽 식을 평가한다. 한 분기(`.deref`)에만 `eval_assign_right` 가 들어갔다(`cte.zig:436`, 2026-11-08 `02f39e67` 로 세 분기가 모두 쓰도록 고침). 재발을 막으려면 cte 쪽 대입 종류마다 복합 대입 케이스를 포함한 테스트(`src/test/meta/`)를 두고, 같은 함수를 런타임과 `const` 로 모두 실행해 결과를 비교하는 테스트를 만드는 것이 가장 싸다.

### Q5. `a + b` 에서 정수는 `add` 노드가 되고 사용자 타입은 `call` 이 되는 분기를 sema 에 두면 코드젠에는 어떤 이점이 있는가? 연산자 오버로딩의 확장 지점은 어디인가?

A: bc_gen 은 `add` 노드를 만나면 타입 검사 없이 정수 덧셈 명령을 고르고, `call` 노드는 함수 호출로만 번역하면 된다. 연산자 해석 규칙이 sema 한 곳에 모인다. 확장 지점은 타입 모듈의 메서드 이름 규약이다. 연산자 문자열 자체가 메서드 이름이라서(`op.name()`, `ast.zig:1742`) `fn (&P) `+`(o P) -> P` 선언만 추가하면 `a + b` 가 호출로 풀린다. 단, 두 번째 피연산자는 일반 인자라 `&P` 로 자동 변환되지 않는다(5.3, 2.5절 호출 해석 첫째).

### Q6. `ret` 직전에 `release` 같은 소멸자 문장이 이미 IR 에 있다는 점은 `return` 이 여러 곳인 함수에서 어떤 일을 막아 주는가?

A: 코드젠이 "함수 종료 지점에서 무엇을 해제해야 하는가"를 추적하지 않아도 된다. `semaReturnExpr` 가 `ret` 마다 `semaDestructBlock2(c, procBlock())` 로 그 시점에 살아 있는 모든 지역의 소멸자를 push 한다(`sema.zig:858-859`). `break`/`continue` 도 지나가는 블록들에 대해 같은 일을 한다(`:791-801`). 단점은 같은 소멸자 코드가 반환 지점마다 복제된다는 점이다.

### Q7. `switch` 의 case 값이 컴파일 타임에 평가된다는 사실은 언어 사용성과 구현에 어떤 영향을 주는가?

A: case 값에 런타임 변수를 쓸 수 없다(`Could not find the symbol` 에러, 5.4). 대신 enum/choice 의 중복 case 검사와 모든 case 처리 여부 검사를 컴파일 타임에 할 수 있고(`enum_coverage`, `sema.zig:5596`), `3..9` 같은 범위를 `>=`, `<=` 비교로 바로 낮출 수 있다. 이유를 코드가 직접 설명하지는 않는다. 이 이점들이 이유였을 것이라는 것은 추정이다.

## 9. 더 알아보기

- 키워드: Pratt/recursive-descent 이후의 semantic analysis, lowering, backpatching, contextual typing(기대 타입 전달), overload resolution, constexpr / comptime, partial evaluation.
- 같이 볼 문서: `docs/history/type_system.md`, `docs/history/ownership_memory.md`(06 과 연결), `docs/history/error_handling.md`(`Result`, `!`), `docs/decisions/project_bc_inline.md`, `docs/decisions/project_ct_eval_loop_result.md`, `docs/decisions/project_string_interpolation.md`.
- 관련 챕터: [02 심볼과 타입](02-symbols-and-types.md)(`Sema` 전역 모델, 템플릿 확장), [04 바이트코드 생성](04-bytecode-gen.md)(IR 소비, 인라이닝), [06 메모리와 소유권](06-memory-ownership.md)(소멸자, ARC), [07 코루틴](07-coroutines-concurrency.md)(`yield`, `ret_gen`, `gen_next`).
- 다음 날(Day 4): 이 IR 이 레지스터 기반 바이트코드로 번역되는 과정을 본다. 오늘 만든 `find` 의 IR 트리와 5.2 의 바이트코드 덤프를 옆에 두고 `genStmt`/`genExpr` 를 읽으면 대응이 바로 보인다.

