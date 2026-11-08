---
aliases: [Day2 심볼과 타입]
tags:
  - study
  - cyber
  - compiler
  - type-system
---

# Day 2. 심볼, 청크, 모듈, 그리고 타입 시스템

> 대상 소스: src/chunk.zig, src/module.zig, src/sym.zig, src/compiler.zig(1052~1375줄), src/types.zig, src/sema_type.zig, src/template.zig, src/builtins/core.zig(타입 생성 함수), src/builtins/core.cy(타입 선언), src/builtins/meta.cy (줄 번호는 HEAD b40531a1 기준)
> 예상 학습 시간: 4시간 (읽기 1시간 / 소스 탐독 1.5시간 / 실습 1.5시간)
> 선행: [Day 1 파이프라인과 프런트엔드](01-pipeline-front-end.md), [언어 투어](00-language-tour.md)
> 후행: [Day 3 의미 분석과 IR](03-sema-and-ir.md)
> 실험 환경: 이 문서의 모든 출력은 저장소 루트에서 ReleaseSafe 빌드 CLI(zig-out/bin/cyber)와 `-Dtrace=true` 빌드 CLI(이하 trace cyber)로 직접 실행한 결과다. 실험 파일은 임의의 폴더(예: lab02/)에 만들어 쓰면 된다. 출력 속 절대 경로는 `...`로 줄였다.

## 한줄 요약

컴파일러는 소스 파일 하나를 청크(Chunk)로 읽어 모듈(Module)이라는 이름 공간에 심볼(Sym)을 먼저 모두 예약하고(reserve), 그다음에 타입 레이아웃과 함수 시그니처를 확정한다(resolve). 0.4의 타입 시스템은 이 과정에서 모든 값의 크기, 정렬, 복사/소멸 규칙을 컴파일 시점에 정해 버리기 때문에, VM 은 런타임에 타입 정보를 거의 갖지 않는다.

## 오늘의 학습 목표

- [ ] Chunk, Module, Sym, Func, FuncSig 의 관계를 그림으로 설명할 수 있다.
- [ ] `reserveChunkSyms` 와 `resolveChunkSyms` 를 둘로 나눈 이유와, 무엇이 즉시(eager) 해석되고 무엇이 지연(lazy)되는지 구분할 수 있다.
- [ ] `Type` 의 kind 31종과 `TypeInfo` 플래그를 읽고, 임의의 타입이 스택 몇 칸(reg_size)을 차지하는지 예측할 수 있다.
- [ ] Option, Result, choice, str, Slice, Array 의 메모리 배치를 말할 수 있고, `.?` 가 어디서 검사되는지 안다.
- [ ] 템플릿(제네릭)이 어떻게 인스턴스로 확장되고 캐시되는지, 트레이스 로그의 이름(`Box[int]`, `pick[float]`)으로 확인할 수 있다.
- [ ] 0.3 의 동적 타입(`dynamic`, `any`)이 0.4 에서 사라진 이유를 메모리 모델과 연결해 설명할 수 있다.
- [ ] 이 코드베이스의 타입 시스템 구멍 몇 가지(trait 시그니처 검사, `-` 가시성, `const` 타입 이름 덮어쓰기 등)를 재현할 수 있다.

## 1. 왜 이것이 필요한가?

### 1.1 해결하려는 문제

Day 1 에서 본 파서는 "문자열 `Point` 가 어디선가 선언된 타입 이름이다" 같은 사실을 알지 못한다. AST 에는 이름만 있고, 그 이름이 무엇을 가리키는지(타입? 함수? 다른 파일의 모듈?), 그 타입이 몇 바이트이고 복사할 때 메모리를 어떻게 다뤄야 하는지는 비어 있다. 이 빈칸을 채우는 것이 두 가지 자료구조다.

- 심볼(Sym)과 모듈(Module): 이름 -> 선언된 대상. 스코프, 선언 순서, 파일 간 참조, 오버로드를 다룬다.
- 타입(Type): 대상이 값일 때 그 값의 모양. 크기, 정렬, 필드 오프셋, 복사/소멸 방법, 다른 타입으로의 변환 가능성을 다룬다.

이것이 없으면 Day 3 의 의미 분석(sema)은 `a.x + 1` 의 `a` 가 무엇인지조차 알 수 없고, Day 4 의 바이트코드 생성기는 구조체 한 개를 레지스터 몇 칸에 담아야 하는지 모른다.

### 1.2 0.3 은 타입 정보를 런타임까지 들고 갔다

0.3 의 `src/types.zig` 는 384줄이었고, 타입 하나는 이런 모양이었다(`git show 0.3:src/types.zig`).

```
pub const Type = struct {
    sym: *cy.Sym,
    symType: cy.sym.SymType,
    data: union {
        uninit: void,
        numFields: u16,
        hostObject: struct { getChildrenFn, finalizerFn },
    },
};
pub const CompactType = packed struct { id: u31, dynamic: bool };
```

`CompactType` 의 `dynamic` 비트가 핵심이다. 0.3 의 컴파일러는 변수마다 "정적 타입 id + 이 변수는 동적인가" 를 따로 기록했고, 값은 NaN 태깅된 64비트 Value 라서(`git show 0.3:src/value.zig`) 런타임에 값 자체가 자기 타입을 알렸다. `int` 는 48비트였다(0.3 문서: "It has 48-bits"; vm.h 의 `_BitInt(48)`).

현재(0.4)의 `Type` 은 1507줄짜리 파일의 `extern struct` 이고, 값은 태그 없는 64비트 워드다(src/vm.h:351 `typedef uint64_t Value;`). 값이 무엇인지는 컴파일러가 안다. VM 은 모른다. 이 차이가 오늘 문서 전체의 축이다. 6절에서 0.3 코드와 직접 비교한다.

### 1.3 TypeScript 개발자 관점에서 본 대안 비교

일반 지식: TypeScript 의 타입은 컴파일 후 완전히 지워지고(type erasure), 런타임은 V8 이 동적 타입으로 처리한다. Cyber 0.4 는 지우기는 같지만 지우고 남는 것이 다르다. TS 는 지운 뒤에도 값이 힙의 태그된 객체라서 동작에 문제가 없지만, Cyber 는 타입을 지운 뒤의 값이 그냥 8바이트 워드들이라서 컴파일러가 정한 레이아웃이 곧 프로그램의 의미다. 타입 검사가 틀리면 TS 는 "경고가 틀렸다" 로 끝나지만, Cyber 는 메모리를 잘못 읽는다. 이 차이는 5절 실습의 trait 시그니처 버그에서 눈으로 볼 수 있다.

## 2. 근본적인 동작 원리

### 2.1 큰 그림

```
 소스 파일들 ──(Day 1)──▶ 파일마다 AST 한 벌

 Compiler.compileInner (src/compiler.zig:315)
 │
 ├─ reserveCoreTypes            builtin 타입 id 1..33 을 번호만 먼저 확보          (:1252)
 ├─ ensureModule(main)          Chunk 객체와 chunk Sym 생성 (아직 읽지 않음)       (:1114)
 ├─ loadBuiltinChunk(core)      core.cy 파싱 -> reserve -> 핵심 타입 resolve         (:879)
 ├─ for 모든 chunk:
 │     loadChunk                파일 읽기 + 파싱 + reserveChunkSyms                  (:1052)
 │     resolveChunkSyms         타입 레이아웃, 함수 시그니처 확정                     (:1342)
 ├─ sema_program(main)          main 본문 먼저 -> 템플릿이 여기서 대부분 확장됨      (:435)
 ├─ performChunkSema            나머지 모든 함수 본문 검사 -> IR                     (:439)
 ├─ Pass through type syms      `with Trait` 구현 검사                               (:452)
 └─ bcgen.genAll                바이트코드                                           (:520)
```

이 문서가 다루는 범위는 `loadChunk`/`resolveChunkSyms` 와 그 안에서 만들어지는 타입이다. 함수 본문(`sema_program`, `performChunkSema`)은 [Day 3](03-sema-and-ir.md)가 다룬다.

### 2.2 심볼: 모든 이름 있는 것의 공통 머리

`Sym` 은 24바이트(64비트 기준) 공통 머리이고, 종류별 구조체가 이 머리를 첫 필드로 포함한다(src/sym.zig:47~62).

```zig
pub const Sym = extern struct {
    parent: ?*Sym align(8),
    type: SymType,
    metadata: u16,
    nameLen: u16,
    namePtr: [*]const u8,
```

`extern struct` 인 이유는 C 쪽(vm.h 의 `SemaSym`)과 같은 레이아웃을 쓰기 위해서이고, 이를 검증하는 테스트가 파일 끝에 있다(src/sym.zig:1734~1751: `@sizeOf(Sym) == 24`, `@offsetOf` 비교). 종류는 `SymType` 21가지다(src/sym.zig:16~43).

| SymType | 구조체 | 의미 | TS/Node 대응 |
|---|---|---|---|
| chunk | Chunk | 파일 하나 = 모듈 하나. parent 가 null, private | ES 모듈 |
| type | TypeSym | 구체 타입. 멤버 이름공간(`mod`)과 `impls_`, 템플릿 출신이면 `instance` | class/interface 선언 |
| func | FuncSym | 함수 이름 하나. 오버로드된 `Func` 들의 연결 리스트(`first`, `last`, `numFuncs`) | 함수 선언(+오버로드 시그니처) |
| userVar / hostVar / extern_var | UserVar / HostVar / ExternVar | `global` 변수 / 임베딩 API 가 바인딩한 전역 / FFI 외부 변수 | 모듈 최상위 `let` |
| const_ | Const | `const` 상수 (컴파일타임 값) | `const` + 리터럴 타입 |
| field | Field | 구조체 필드. 구조체의 `mod` 안에 등록됨(idx, type) | 프로퍼티 심볼 |
| enum_case / choice_case / union_case | EnumCase 등 | 케이스. 모두 타입의 `mod` 안에 등록 | enum 멤버 |
| use_alias | UseAlias | `use` 가 만든 별칭. `sym` 이 진짜 대상, `resolved` 플래그 | import 바인딩 |
| type_alias / type_const | TypeAlias / TypeConst | `type A = B` / `type X const:` | type 별칭 |
| template / func_template | Template / FuncTemplate | `type C[T Any]` / `fn f[T Any]` 의 틀 | 제네릭 선언 |
| variant_func / variant_member | VariantFunc 등 | 템플릿 이름공간 안에 선언된 메서드/상수(인스턴스마다 나중에 실체화) | 제네릭 클래스의 메서드 |
| ct_value, module_alias | CtValue, ModuleAlias | 생성 지점 없음 (rg 로 확인: `createCtValue`, `createModuleAlias` 호출 없음) | - |

`metadata` 의 비트는 `resolving`(해석 중 순환 감지), `private`, 14비트 패딩이다(src/sym.zig:435~442). `private` 는 현재 chunk 심볼, `use_alias`, 그리고 `type_alias`/`type_const` 의 `-` 접두사에만 설정된다. 이 사실이 7절의 "가시성이 강제되지 않는다" 항목으로 이어진다.

### 2.3 Func, FuncSig, 오버로드

함수는 두 겹이다. 이름은 `FuncSym` 하나이고, 같은 이름의 선언마다 `Func` 가 하나씩 생겨 `next` 로 연결된다(src/sym.zig:549~575, 946~992).

```
 Module.symMap["f"] ─▶ FuncSym "f"
                         first ─▶ Func(a int)        ─next▶ Func(a str)  ─next▶ Func(a int, b int)
                                   sig: *FuncSig            sig                   sig
                                   type: userFunc ...
```

`Func.type` 은 `FuncKind` 로, 처음엔 `unresolved` 이고 시그니처를 해석하면서 `userFunc`, `hostFunc`(`#[bind]`), `extern_`(FFI), `generic`(`%T` 가 있는 함수), `trait`(trait 메서드), `reserved` 중 하나로 바뀐다(src/sym.zig:881~903, src/sema.zig:2807 `ensure_resolved_func`). `FuncInfo` 비트 필드(src/sym.zig:905~939)에는 `generator`, `is_method`, `emitted`, `bc_inline`(최근 인라인 캐시) 같은 플래그가 있다.

`FuncSig` 는 `Sema.ensureFuncSig2` 로 해시-컨싱(hash-consing)된다(src/sema.zig:9496~9529). 키는 (파라미터 타입 열과 sink 비트, 반환 타입, `extern_`, `scope_param_idx`)이고, 같은 키면 항상 같은 포인터를 돌려준다(`FuncSig` 정의는 src/sema.zig:9213~9234). 그래서 함수 시그니처의 동일성 비교는 포인터 비교이고, 같은 시그니처를 가진 함수 타입(`funcptr_t[SIG]`)은 어디서 만들어도 같은 타입이 된다. 구조체가 선언된 이름으로만 같은 타입(nominal)인 것과 대조된다.

오버로드 유일성 검사는 `Module.isFuncUnique` 가 한다(src/module.zig:67~77). 첫 Func 의 시그니처는 `FuncSym.firstFuncSig` 에 복사해 두고 포인터 비교로 끝낸다. 두 번째부터는 (FuncSym, FuncSig) 쌍을 키로 하는 `overloadedFuncMap` 에 넣고 조회한다. 여기서 시그니처에 반환 타입이 포함된다는 점이 실수를 만든다. 5.7 실험에서 `fn f(a int) -> int` 와 `fn f(a int) -> float` 가 동시에 선언되는 것을 확인한다.

### 2.4 모듈과 이름 조회

`Module` 은 놀랄 만큼 작다(src/module.zig:23~41).

```zig
pub const Module = struct {
    /// Name to sym.
    symMap: std.StringHashMapUnmanaged(*cy.Sym),
    overloadedFuncMap: std.HashMapUnmanaged(ModFuncKey, *cy.Func, cy.hash.KeyU128Context, 80),
```

파일 하나가 `Chunk`(컴파일 단위, src/chunk.zig:34)이고, 그 `Chunk.sym`(chunk Sym)의 `mod` 가 모듈이다. 타입, 템플릿, FuncTemplate 도 각자 `mod` 를 갖는다(`Sym.getMod`, src/sym.zig:253~279). 그래서 `Point.x` 의 `x` 필드, `Shape.circle` 의 `circle` 케이스, `Node.DefaultValue` 같은 "타입 이름공간 상수" 가 전부 같은 방식 `symMap` 조회로 해결된다. 이름 공간이 트리 하나다.

심볼 등록은 `addUniqueSym` 한 곳을 지난다(src/module.zig:104~113). 이미 같은 이름이 있으면 `reportDupSym` 이 "`A` has already been declared as a `type`" 과 "First declared at:" 두 위치를 낸다(5.6 실험).

식별자 하나를 찾는 순서는 `getResolvedName`(src/sema.zig:4160~4238)에 있다.

```
 1. 현재 ResolveContext 의 컴파일타임 매개변수 (템플릿 T, N ...)
 2. 함수/심볼 컨텍스트의 템플릿 인스턴스 매개변수 (instance.getParam)
 3. "Self"                                    (타입 안에서)
 4. 현재 청크의 모듈 (c.sym.mod)               <- use 별칭도 여기에 들어 있음
 5. fallback_modules 를 뒤에서 앞으로          <- core 가 항상 들어 있음
 6. resolve_name_fn (libcyber 의 clFindType 용)
```

`fallback_modules` 는 `Chunk` 의 필드다(src/chunk.zig:107~108 "Builtins is always a fallback module for symbol lookups"). `loadChunk` 끝에서 모든 청크에 core 청크가 추가된다(src/compiler.zig:1092~1096). 이것이 `print`, `Array`, `Map`, `str` 을 import 없이 쓰는 이유의 전부다. 별도의 "prelude 파서" 같은 것은 없다. 5.6 실험에서 사용자 파일이 `print` 를 직접 선언하면 core 의 `print` 가 통째로 가려지는 것(오버로드가 모듈 경계를 넘어 합쳐지지 않음)을 볼 수 있다.

`use` 문은 `reserve` 단계에서 `declareUseImport` 가 처리한다(src/sema.zig:2447~2502). 아직 파일을 읽지 않고 `ensureModule` 로 빈 청크만 만들며, `use_alias`(`resolve_with_sym = true`)를 모듈에 등록한다. 실제 로딩은 이 alias 가 `resolveUseAlias` 로 해석될 때 `loadChunk` 로 일어난다(src/sema.zig:2416~2422). `use * 'x'` 만 예외로, 그 자리에서 즉시 `loadChunk` 한 뒤 `private` 가 아닌 모든 심볼을 alias 로 복사한다(:2483~2495).

조회는 호출한 곳이 아니라 "선언된 곳의 청크"(`ctx.chunk`)를 기준으로 한다(src/sema.zig:4162~4163 `const search_c = ctx.chunk`). 그래서 사용자가 `Array` 를 새로 선언해도 core 내부 코드의 `Array` 는 영향을 받지 않는다(5.6 실험에서 확인).

### 2.5 두 단계: reserve 와 resolve

`loadChunk` 가 청크 하나에 대해 하는 일은 세 줄로 요약된다(src/compiler.zig:1052~1098).

```
loadChunk(c)
 1. 모듈 로더를 불러 소스를 얻는다 (c.pending_load_src 일 때)
 2. performChunkParse            Day 1: 토큰화 + 파싱, c.ast 확보
 3. reserveChunkSyms(c)          선언마다 "껍데기 심볼" 등록
 4. fallback_modules 에 core 추가
```

이어서 `resolveChunkSyms(c)` 가 껍데기를 채운다. 두 함수의 뼈대를 나란히 보자.

```zig
// src/compiler.zig:1148~1160, 1179~1182 (발췌)
fn reserveChunkSyms(c: *cy.Chunk) anyerror!void {
    if (c.reserved_syms) { return; }
    try sema.pushChunkResolveContext(c, null);
    defer sema.popResolveContext(c);

    // Process static declarations.
    for (c.ast.root.?.stmts.slice()) |stmt| {
        switch (stmt.type()) {
            .import_stmt => { try sema.declareUseImport(c, stmt.cast(.import_stmt)); },
            ...
            .struct_decl => {
                const decl = stmt.cast(.struct_decl);
                _ = try sema_type.reserveStruct(c, decl, false);
            },
```

`reserve` 는 AST 최상위 문장을 한 번 훑으면서 이름을 모듈에 등록하는 일만 한다. 구조체 하나에 대해서는 `Type`(kind=struct_t, 크기와 필드는 아직 비어 있음)과 `TypeSym` 을 만들고 타입 id 를 배정해 `symMap` 에 넣는 것이 전부다(src/sema_type.zig:649~659 `reserveStruct`). 필드 타입이 무엇인지는 아직 아무도 평가하지 않는다. 최상위에 함수 선언이 아닌 문장이 있으면 main 청크가 아닌 경우 여기서 오류가 난다(:1239~1243, "Top level statement is not allowed from imported module.").

```zig
// src/compiler.zig:1342~1370 (지역 변수를 정리해 발췌)
fn resolveChunkSyms(c: *cy.Chunk) !void {
    // Evaluate any top level ct stmts.
    try sema.semaChunkTopCtStmts(c, null);

    var cur_sym: usize = 0;
    var cur_func: usize = 0;
    while (true) {
        // Iterate with explicit index since unnamed types could be appended.
        while (cur_sym < c.syms.items.len) : (cur_sym += 1) {
            try resolveSym(c, c.syms.items[cur_sym]);
        }
        while (cur_func < c.funcs.items.len) : (cur_func += 1) {
            try sema.ensure_resolved_func(c, c.funcs.items[cur_func], false, null);
        }
        if (cur_sym == c.syms.items.len) { break; }
    }
```

이 루프는 고정점(fixed point) 반복이다. 심볼 목록 `c.syms` 를 끝까지 해석하고, 함수 목록 `c.funcs` 를 끝까지 해석한 뒤, 그 사이에 새 심볼이 생겼으면(필드 심볼, 템플릿이 만든 타입, 람다 등) 다시 돈다. 해석이 새 심볼을 만들어 목록이 커지기 때문에 for-each 대신 인덱스 루프를 쓴다는 주석이 그 이유다. `resolveSym`(:1299~1336)은 종류별 분기일 뿐이다.

| SymType | resolveSym 이 하는 일 |
|---|---|
| type | `ensure_resolved_type` -> 필드 평가, 크기/정렬/오프셋, managed/copy 플래그 |
| userVar, const_, hostVar, extern_var | 선언된 타입 평가, 초기화 식 평가(const) |
| use_alias, type_alias, type_const | 별칭 대상 평가. `use` 는 여기서 청크 로딩이 일어난다 |
| template, func_template | 매개변수 이름만 정리(`resolveTemplate`, src/sema.zig:2389). 인스턴스는 만들지 않는다 |
| func | 아무것도 안 한다 (`.func => {}`). 함수는 두 번째 루프에서 시그니처를 해석 |

왜 둘로 나누는가. 이 구조에서 얻는 것은 세 가지다.

1. 선언 순서 독립. 5.5 실험처럼 `main` 이 파일 맨 위에 있고 타입과 `const K` 가 아래에 있어도 된다. 모든 이름이 먼저 `symMap` 에 있으니 해석 도중 이름을 찾을 때 "아직 선언 안 됨" 이라는 상황이 없다.
2. 순환 참조. `type A: b ?^B` 와 `type B: a ?^A` 에서 A 를 해석하다가 B 가 필요하면, B 는 이미 타입 id 와 심볼이 있다. 해석 중임을 표시하는 `Struct.resolving_struct` 플래그가 있어서 값 자체의 순환(`a S`)은 "Structs can not contain a circular dependency." 로 거부하고(src/sema_type.zig:217~219), 포인터를 거치는 순환(`?^B`, 8바이트)은 크기가 확정이라 통과한다.
3. 중복 선언 검출이 해석과 무관하게 한 군데(`addUniqueSym`)에서 일어난다.

이 설계는 TypeScript 의 binder(선언마다 symbol 을 먼저 만들고) -> checker(필요할 때 타입을 계산) 와 같은 모양이다(일반 지식). 차이는 checker 가 지연 계산을 하는 TS 와 달리 Cyber 는 비템플릿 선언을 전부 즉시 해석한다는 점이다.

### 2.6 즉시(eager)와 지연(lazy)은 어디서 갈리나

"쓰이지 않은 심볼은 해석되지 않는다" 는 문장은 코드에서 한 군데 주석에만 나온다. `persist_main`(REPL 에서 이전 main 의 심볼을 새 main 으로 이월) 처리 중 이런 주석이다(src/compiler.zig:354~356).

```zig
// Use all *resolved* top level syms from previous main.
// If a symbol wasn't resolved, it either failed during compilation or didn't end up getting used.
```

이 주석은 일반 파일 컴파일에는 해당하지 않는다. 일반 컴파일에서는 청크의 비템플릿 타입과 함수 시그니처가 전부 해석된다. 실제로 어디서 무엇이 지연되는지를 로그와 실험으로 정리하면 이렇다.

| 대상 | 해석 시점 | 근거 |
|---|---|---|
| 다른 파일 | `use` alias 가 해석될 때 로드 | trace: `resolve: math .use_alias` 바로 뒤에 `Invoke module loader: .../math.cy` (5.2) |
| 비템플릿 타입(필드, 크기) | `resolveChunkSyms`, 선언 순서대로, 사용 여부와 무관 | 호출도 사용도 안 한 `Unused` 타입도 해석됨 (5.1) |
| 함수 시그니처 | `resolveChunkSyms` 두 번째 루프, 무조건 | 같은 로그의 `resolve: never_called` |
| 함수 본문 | `performChunkSema`, 호출 여부와 무관 | 호출하지 않은 함수의 타입 오류도 보고됨 (5.3) |
| 템플릿 틀 | 매개변수 이름만 | `resolve: Box .template` |
| 템플릿 인스턴스 `Box[int]` | 처음 쓰인 식에서 | `main` 본문 sema 중 `resolve type: Box[int] 127` (5.4) |
| 템플릿 메서드와 그 본문 | 인스턴스에서 처음 접근할 때 | 미사용 템플릿의 타입 오류는 보고되지 않음 (5.3) |
| `%T` 제네릭 함수 | 호출 시 인스턴스마다 | `push func: pick[int]`, `pick[float]` 가 따로 sema 됨 |

템플릿 메서드가 지연되는 메커니즘은 `getResolvedSym` 의 마지막 부분이다(src/module.zig:561~598). 심볼 조회가 모듈에서 실패하면, 대상이 템플릿 인스턴스일 때 템플릿의 `mod` 에서 `variant_func` 를 찾아 그 자리에서 `reserveFunc` + `ensure_resolved_func` 를 한다(주석: "Lazily load instance sym."). 즉 `Box[int].get` 은 `b.get()` 을 컴파일하는 순간 처음 존재하게 된다.

정리하면, 비템플릿 코드는 즉시 모두 검사하고, 제네릭에 속한 것만 사용 시점에 검사한다. C++ 템플릿과 같은 규칙이다(일반 지식). 그래서 제네릭 코드의 타입 오류는 인스턴스를 만든 호출 지점의 사용 방식에 따라 나타나고 안 나타날 수 있다.

### 2.7 타입의 몸: Type 머리와 kind 31종

`Type` 도 Sym 처럼 `extern struct` 머리이고 kind 별 구조체가 `base: Type` 을 첫 필드로 포함한다(src/types.zig:81~93, 718~752 의 `TypeImpl`).

```zig
pub const Type = extern struct {
    kind_: TypeKind,
    sym_: *cy.sym.TypeSym,
    id_: TypeId,
    info: TypeInfo,
    dtor: ?*cy.Func = null,        // null 이면 소멸자 없음
    deinit_obj: ?*cy.Func = null,
    copy_ctor: ?*cy.Func = null,   // null 이면 memcpy
```

모든 타입은 `Sema.types`(`ArrayList(*Type)`)에 id 순서로 들어 있고, 타입 id 는 이 배열의 인덱스다(`createType`, src/types.zig:1320~1337). 타입 이름은 곧 `sym_` 의 이름이다. 타입은 늘 심볼과 한 쌍이어서, 템플릿 인스턴스의 이름(`Box[int]`)도 심볼 이름 출력(`writeSymName`, src/sym.zig:1514~1650)이 만든다. `Option`, `Result`, `Ref`, `Borrow` 같은 템플릿 인스턴스는 거기서 `?int`, `!int`, `^P`, `&P` 로 그려진다.

`cast(.struct_t)` 는 `@ptrCast` 일 뿐이고 kind 일치 검사는 `cy.Trace` 빌드에서만 한다(src/types.zig:458~465). ReleaseSafe CLI 에서는 잘못된 cast 가 조용히 지나갈 수 있다는 뜻이다.

`TypeKind` 31종을 정리한다. 번호는 vm.h 의 `TYPE_KIND_*`(src/vm.h:548~578)이고 Zig 의 열거형이 `= vmc.TYPE_KIND_X` 로 같은 값을 쓴다(src/types.zig:17~51). 크기는 `Type.size()`(:414~443)가 돌려주는 값이다.

| kind (vm.h 번호) | 대응하는 문법/타입 | size() | 비고 |
|---|---|---|---|
| null (0) | 자리표시자 `NullType` | - | id 0. 예약된 빈 슬롯 |
| bool (1) | `bool` | 1 | |
| int (2) | `int`=`Int[64]`, `i32`, `i16`, `i8` | bits/8 | `Int[const Bits EvalInt]` 인스턴스 |
| raw (3) | `byte`=`Raw[8]`, `r16`, `r32`, `r64`, `error`, `symbol`, `type` | bits/8 | 부호 없는 비트열. `error`/`symbol` 은 `distinct=true` |
| float (4) | `float`=`Float[64]`, `f32` | bits/8 | |
| enum_t (5) | `type X enum:` (페이로드 없음) | 8 | 태그 i64 하나 |
| choice (6) | `type X enum:` + 페이로드 case | 8+최대 페이로드, 8 정렬 | 태그 있는 합집합 |
| struct_t (7) | `type X:`, `cstruct`, 튜플 `type V(x float)`, `str`, `Array[T]` ... | 필드 합(정렬 포함) | 사용자 타입의 기본형 |
| option (8) | `?T` = `Option[T]` | zero_union 이면 8 또는 4, 아니면 8+size | 2.11절 |
| generic_trait (9) | `type X trait:` | (size() 불가) | trait 선언 자체. 제약으로만 쓰임 |
| bare (10) | - | - | 생성 지점 없음(rg). bc_gen 에서 만나면 오류 처리 |
| generic (11) | `Any`, `Infer`, `dependent` | 0 | 제네릭 자리표시. 값 타입이 아님 |
| vector (12) | `[N]T` | n*elem | 값 타입 고정 배열 |
| func_ptr (13) | `fn(int) -> int` = `funcptr_t[SIG]` | 8 | 함수 포인터 |
| func (14) | `Func[funcptr]`, `OpaqueFunc` | 8 | 함수 또는 클로저를 담는 유니온 |
| func_sym (15) | `fnsym(...)`, `funcsym_t[SIG]` | (불가) | 컴파일타임 함수 심볼 |
| pointer (16) | `Ptr[T]`(ref=false), `^T`(ref=true), `Thread`, `FuncSig` | 8 | `Ref[T]` 와 `Ptr[T]` 가 같은 kind. `ref` 비트로 구분 |
| borrow (17) | `&T` | 8 | 스택 위 빌림 포인터 |
| void (18) | `void` | 0 | |
| result (19) | `!T` | 8+max(8, size) | 2.11절 |
| ref_trait (20) | `^Dyn[Trait]` | 16 | 팻 포인터 |
| borrow_trait (21) | `&Dyn[Trait]` | 16 | |
| generic_vector (22) | `[_]T` | (불가) | 길이 추론용 자리표시 |
| never (23) | `never` | 0 | |
| c_variadic (24) | FFI 가변 인자 | - | |
| eval_int (25) | `EvalInt` | - | 컴파일타임 정수. `info.ct` |
| c_union (26) | `cunion` | 최대 페이로드 | |
| partial_vector (27) | `[..N]T` | 8+n*elem | 길이 + 원소 |
| ex_borrow (28) | `&&T` | 8 | 배타적 빌림 |
| dyn_trait (29) | `Dyn[Trait]` | (불가) | 컨테이너 타입 자체. `^`/`&` 로 감싸서만 쓰임 |
| eval_ref (30) | `EvalStr`, `EvalBuffer[T]` | 8 | 컴파일타임에만 있는 rc 타입 |

`(불가)` 는 `size()` 의 switch 에 항목이 없어 `std.debug.panic("TODO: {} size")` 로 떨어진다는 뜻이다. 런타임 값으로 존재할 수 없는 타입이라는 것을 이 panic 이 간접적으로 말해 준다.

TS 와의 대응: 합집합은 `choice`(태그 있는 합집합)와 `option`/`result` 로 나뉘어 있고, TS 의 `A | B` 같은 태그 없는 합집합은 없다. `interface` 는 `trait`, 제네릭 제약 `T extends X` 는 `T X` 다.

### 2.8 TypeInfo: 타입이 들고 다니는 16비트

복사, 소멸, 컴파일타임 전용 여부 같은 규칙은 `Type.info` 의 비트 필드에 모인다(src/types.zig:53~79).

| 비트 | 뜻 | 누가 채우나 |
|---|---|---|
| resolved | 레이아웃과 복사 규칙이 확정됨 | 각 `resolve*Type` 끝 |
| managed | 값 안에 참조 카운트되는 것이 있음 (소멸 필요) | 자식이 managed 이거나 `@deinit` 이 있으면 |
| copy_base | 기본 `@copy`(필드별 복사/retain)가 필요 | 자식 중 copy ctor 가 있는 것이 있을 때 |
| copy_user | 사용자 정의 `@copy` 가 있음 | 타입 모듈에 `@copy` 가 선언됨 |
| no_copy | `NoCopy` 를 구현하거나 그런 필드를 가짐 | `resolve_type_impls`, `resolve_type_info` |
| borrow_only | 빌림이거나 빌림을 포함 (함수 반환 제한에 쓰임) | |
| ct | 컴파일타임에만 존재 | `EvalInt`, `EvalStr`, 이를 포함한 필드 |
| generic | 제네릭 제약 자리표시 (`Any`, trait) | |

5.9 실험으로 몇 가지 타입의 managed/copyable 을 `type.managed(T)`, `type.is_copyable(T)` 로 찍어 보면 규칙이 잘 보인다. `int`, `P{x,y}` 는 managed 가 아니고, `str`, `^P`, `Array[int]` 는 managed 이며, `Array[int]` 는 `with NoCopy` 라서 copyable 이 false 다. 구조체는 managed 인 필드가 하나라도 있거나 `@deinit` 이 있으면 managed 가 된다(src/sema_type.zig:918~922).

### 2.9 builtin 타입 id 와 vm.h

타입 id 0~33 은 컴파일러와 C 코드가 같은 번호를 쓰도록 고정되어 있다. vm.h 의 enum(src/vm.h:311~346)에는 주석 "These types are reserved so that the IDs are consistent across builds." 이 있고, Zig 쪽 `BuiltinTypes`(src/types.zig:1205~1243)는 이 상수를 `vmc` 모듈(vm.h 를 translate-c 한 것)에서 가져다 쓴다. 번호를 한 곳에서만 정의하는 구조여서 둘이 어긋날 수 없다.

```
 0 NULL   1 VOID   2 BOOL   3 I8   4 I16   5 I32   6 I64   7 EVAL_INT
 8 R8     9 R16   10 R32   11 R64  12 F32  13 F64  14 ERROR  15 SYMBOL
16 OBJECT 17 ANY  18 TYPE  19 THREAD 20 CODE 21 FUNC_SIG 22 PARTIAL_STRUCT_LAYOUT
23 STR   24 STR_BUFFER 25 EVAL_STR 26 NEVER 27 INFER 28 DEPENDENT 29 TCC_STATE
30 RANGE 31 TABLE 32 NO_COPY 33 MUT_STR              (BuiltinEnd = 34)
```

`reserveCoreTypes`(src/compiler.zig:1252~1297)가 `bt.Void` 부터 `bt.MutStr` 까지 같은 순서로 `reserveType()` 을 부르고 `id == type_id` 를 assert 한다. 그 뒤 core.cy 의 선언이 이 번호표를 채운다. 예를 들어 `createIntType`(src/builtins/core.zig:653~673)은 `Int[64]` 가 확장될 때 `bits` 에 따라 `bt.I64/I32/I16/I8` 을 골라 `createTypeWithId` 로 만든다. `int`, `i64`, `Int[64]` 가 모두 같은 타입 id 6 인 이유다. `type byte = Raw[8]`, `type float = Float[64]` 도 같다(src/builtins/core.cy:292~297, 395~400, 596~598). 기본형이 틀(template)의 인스턴스라는 점이 이 언어의 특징이다. 호스트가 만드는 타입은 core.zig 의 `types` 표(:32~77)에 `TYPE_CREATE`(생성 함수), `TYPE_RESERVE_DECL`(id 만 고정하고 레이아웃은 core.cy 가 선언) 두 방식으로 등록된다.

### 2.10 크기, 정렬, reg_size, 그리고 값 타입과 힙 박스

VM 의 스택은 8바이트 슬롯(Value)의 배열이고(src/vm.h:351), 한 값이 차지하는 슬롯 수가 `reg_size` 다.

```zig
// src/types.zig:217~219
pub fn reg_size(self: *Type) usize {
    return (self.size() + 7) >> 3;
}
```

바이트코드 생성기의 `type_reg_size`(src/bc_gen.zig:2270)도 같은 식이다. 로컬 변수 하나를 만들 때 `reserve_reg` 가 이만큼의 연속 레지스터를 잡고(src/bc_gen.zig:2214~2243), 함수 호출 인자와 반환 슬롯도 이 단위로 자리를 잡는다(`exp_arg_reg += arg.type.reg_size()`, :1382). `size()` 를 직접 재 보면 아래와 같다(5.8 실험, `type.size(T)` 출력).

| 타입 | size | reg_size | 비고 |
|---|---|---|---|
| `int`, `float`, `error`, `symbol`, 열거형 | 8 | 1 | 열거형도 8바이트 태그 |
| `byte`, `bool` | 1 | 1 | 값이 1바이트여도 레지스터는 1칸 |
| `i32`, `f32` | 4 | 1 | |
| `[3]byte` | 3 | 1 | 값 타입 고정 배열 |
| 구조체 `P{x int, y int}` | 16 | 2 | |
| `str` | 24 | 3 | buf, ptr, header |
| `Array[int]` | 24 | 3 | buf, length, header |
| `[]int` (Slice) | 32 | 4 | buf, ptr, _len, header |
| `Map[int, int]` | 48 | 6 | HashMap 필드 6개 |
| `Range` | 16 | 2 | start, end |
| `Generator[fn() -> int]` | 48 | 6 | frame_ptr 등 7필드 |
| `Object` | 8 | 1 | `Ptr[void]` 하나 |
| `^P`, `&P`, `Ptr[P]` | 8 | 1 | 포인터류 |
| `^Dyn[Trait]`, `&Dyn[Trait]` | 16 | 2 | 팻 포인터 (2.16절) |
| `fn() -> int`, `Func[...]` | 8 | 1 | |
| `[4]int` | 32 | 4 | 값 타입, 인라인 |
| `[..4]int` | 40 | 5 | 길이 8바이트 + 4칸 |

필드 배치 알고리즘은 `resolveStructFields` 한 곳에 있다. 필드는 선언 순서대로 놓이고(재배치 없음), 각 필드는 자기 정렬에 맞춰 오프셋이 올림되고, 구조체 전체 크기는 최대 정렬로 올림된다(src/sema_type.zig:889~908, 코드 주석: "Alignment follows C-ABI rules."). `cstruct` 도 같은 함수를 지난다. 다른 점은 FFI 용으로 0 초기화가 허용된다는 것뿐이다. 필드 순서가 크기를 바꾸는 것을 5.8 실험에서 본다.

```
type A: lo byte, mid int, hi byte     type B: mid int, lo byte, hi byte
 A size=24: lo@0 mid@8 hi@16           B size=16: mid@0 lo@8 hi@9
```

값 타입과 힙 박스의 구분이 0.4 의 핵심이다. 구조체, Option, Result, choice, 벡터, str, Slice, Array 는 전부 값 타입이다. 변수에 담기면 스택(레지스터) 슬롯에 그대로 인라인되고, 대입과 인자 전달은 슬롯 복사다. 힙에 올리려면 `^T` 로 명시한다. 바이트코드(`cyber compile`)로 확인하자. 5.1 의 r1.cy 에서 `Point{x=3, y=4}` 를 만들어 `dist(p)` 에 넘기는 부분이다.

```
0:72 .addr: %3 = *%1            -- p 는 %1,%2 두 칸. %3 에 %1 의 주소
0:75 .const_16s: %4 = 3
0:78 .const_16s: %5 = 4
0:81 .store_64: [%3 + 0] = %4   -- x 를 오프셋 0 에
0:85 .store_64: [%3 + 8] = %5   -- y 를 오프셋 8 에
0:89 .mov_2: %12 = %1           -- 인자 전달 = 두 칸 복사
0:92 .call: %7 = r1.dist(%12..%14) 0
```

`dist` 안에서는 `p.y` 가 `.addr: %10 = *%5` + `.load_64: %9 = [%10 + 8]` 로 읽힌다(레지스터 두 칸을 메모리처럼 취급하고 오프셋으로 접근). 이 때문에 VM 에는 `LOAD_8/16/32/64`, `LOAD_2W/3W/4W/N`, `STORE_*`, `MOV_2/3/4/N` 같은 폭별 명령이 있다(src/vm.h:150~300 의 OpCode). 이 명령들은 [Day 4](04-bytecode-gen.md)에서 다룬다.

힙 박스 `^T` 는 8바이트 포인터이고, 가리키는 객체 바로 앞 8바이트에 헤더가 있다(src/vm.h:484~487 `ObjectHeader { u32 meta; u32 rc; }`, `OBJ_TYPEID(o)` 는 `o - 8` 을 읽는다). `meta` 의 하위 28비트가 타입 id 이고(`TYPE_MASK 0x0fffffff`, src/vm.h:83) 나머지가 플래그다. `NEW` 명령이 객체를 할당한다(src/vm.c:1269 `allocObjectInit(t, val_t, size)`). 소멸자를 고르는 법은 [Day 6](06-memory-ownership.md)에서 다룬다.

스택에 있는 값은 자기 타입을 모르는 반면 힙 객체는 헤더에 타입 id 를 갖는다. 그러나 런타임 타입 테이블(`vm.c.types_ptr`)은 `cy.Trace` 빌드에서만 채워지고 이름 문자열뿐이다(src/bc_gen.zig:199~214, `meta.cy` 의 `type.name_rt` 주석 "This is only available in trace mode."). 릴리스 VM 은 타입 이름도 모른다.

### 2.11 특수 타입의 메모리 배치

모두 5.10 실험(`as[Ptr[int]] &x` 로 슬롯을 읽는 덤프)으로 확인한 값이다.

Option `?T`. 틀 `Option[T]` 는 core.zig 의 `createOptionType`(src/builtins/core.zig:808~825)이 만든다. 핵심은 한 줄이다.

```zig
const zero_union = child_t.kind() == .pointer or child_t.kind() == .func_ptr or child_t.kind() == .eval_ref;
```

자식이 포인터류(`^T`, `Ptr[T]`), 함수 포인터, 컴파일타임 rc 타입이면 `zero_union` 이다. 이 경우 별도 태그가 없고 값 0 이 none 이다(크기 = 자식 크기 8 또는 4, src/sema_type.zig:1111~1116). 그 밖의 모든 자식은 태그 + 페이로드다(:1117~1137).

```
 ?int(42)              ?int(none)            ?^P(none)      ?^P(some)
 ┌────┬────┐           ┌────┬────┐           ┌────────┐     ┌────────┐
 │ 1  │ 42 │           │ 0  │ ·· │           │   0    │     │ 포인터 │
 └────┴────┘           └────┴────┘           └────────┘     └────────┘
  tag  payload          tag  (쓰이지 않음)     zero_union      zero_union
  size 16               size 16               size 8          size 8
```

실측: `?int(42)` 는 `[1, 42]`, `?int(none)` 의 첫 슬롯은 0, `?^P(none)` 은 `[0]`. 태그는 8바이트이고 some=1, none=0 이다(`semaWrapSome` 이 zero_union 이면 비트캐스트, 아니면 `semaConst(1, i64)` 를 태그로 붙인다: src/sema.zig:8977~8987). 그래서 `?byte` 도 16바이트, `?bool` 도 16바이트다. 같은 방식으로 재면 `?&int`(빌림)가 16이고 `?Func[...]`(함수 유니온)도 16인데, 둘 다 kind 가 pointer/func_ptr 가 아니기 때문이다. 중첩 `??int` 는 24바이트다.

Result `!T`. `resolveResultType`(src/sema_type.zig:1057~1104)이 크기를 8(태그) + max(8, 페이로드 크기)로 올림해 정한다. 케이스는 `error`=0, `result`=1 이다(:1096~1097). 에러 값은 `error` 타입(심볼 id)이고 페이로드 자리에 들어간다. 실측: 성공 `!int(5)` 는 `[1, 5]`, 실패 `error.Neg` 는 `[0, 50]`(50 은 그 프로그램의 심볼 테이블에서 `Neg` 의 id).

choice (태그 있는 합집합). `declare_choice_cases`(src/sema_type.zig:421~500)가 정한다. 태그는 맨 앞 8바이트 i64(케이스 선언 순서의 인덱스), 페이로드는 오프셋 8부터, 크기는 8 + 최대 페이로드를 8 정렬로 올린 값이다(`var size = 8 + max_payload_size`, :480~484). 페이로드 정렬이 8 보다 크면 `std.debug.panic("Unsupported alignment.")` 이다(:464~466). 실측으로 `case circle float / rect P / point` 인 `Shape` 는 24바이트이고,

```
 Shape.rect(P{x=7, y=8})   [1][7][8]        Shape.point           [2]
 Shape.circle(1.0)         [0][0x3FF0000000000000]   (1.0 의 IEEE754 비트)
```

enum 은 케이스에 페이로드가 없을 때이며 태그만 가진 8바이트 값이다(`Color` size 8). 같은 `enum` 선언이 페이로드 있는 case 를 하나라도 가지면 choice 로 해석된다(src/compiler.zig:1187~1193 의 `decl.isChoiceType`).

str. `str` 은 core.cy 가 필드를 선언하고(`#[bind] type str: buf ?^StrBuffer / ptr Ptr[byte] / header int`, src/builtins/core.cy:3236~3247) 타입 id 만 호스트가 고정한다(`TYPE_RESERVE_DECL(bt.Str)`). 24바이트 3슬롯이고 `buf` 가 none 이면 정적 문자열 조각이다. 부분 문자열이 버퍼를 공유하는 구조이고, `header` 가 바이트 길이와 ASCII 여부를 담는다.

Slice, Array. `Slice[T]` 는 `buf ?^RawBuffer[byte]`, `ptr`, `_len`, `header`(최상위 비트가 부분 슬라이스 표시, 나머지는 용량) 4슬롯이다(src/builtins/core.cy:1026~1050). `Array[T]` 는 `with NoCopy` 이고 `buf Ptr[T]`, `length`, `header`(용량, 상위 2비트는 Ex 빌림용) 3슬롯이다(:1662~1675). 둘 다 사용자 코드와 같은 `type` 선언이고 호스트 타입이 아니다. 즉 컬렉션의 레이아웃은 Cyber 소스에 있다.

벡터. `[N]T` 는 `elem_size * N` 바이트의 인라인 배열이고 `[..N]T`(PartialVector)는 앞 8바이트가 길이, 그 뒤가 원소다(`array_t.size = 8 + elem_size * array_t.n`, src/sema_type.zig:1023~1038). 그래서 `[..4]int` 는 40바이트다. 길이 검사 코드는 core.cy 의 `@index_addr` 안에 Cyber 코드로 있다(`idx.uge(N)` 후 `panic_oob`, src/builtins/core.cy:3926~3929).

튜플. 별도 kind 가 없고 `Struct.tuple = true` 인 구조체다(src/types.zig:967~996). `type Vec2(x float, y float)` 는 필드 이름이 `x`, `y` 인 16바이트 구조체이고 `Vec2{3.0, 4.0}` 로 초기화한다. `FnTuple[Sig]` 처럼 함수 시그니처에서 `meta.new_struct(fields, {tuple=true})` 로 만들어 내는 튜플도 같은 kind 다(src/builtins/core.cy:2008~2018).

### 2.12 `.?` 는 어디서 검사하고 어디서 검사하지 않나

처음 관찰에서는 `print(g.next().?)` 가 none 일 때 패닉하지 않고 쓰레기 값(`-9223372036854775806`)을 읽는 것처럼 보였다. 코드와 실험으로 가려 보았다. 결론부터: `.?` 문법 자체는 항상 검사한다. 쓰레기 값은 다른 경로에서 나온다.

`.?` 는 AST 노드 `unwrap` 이고 `semaExprNoCheck` 에서 이렇게 갈린다(src/sema.zig:6924~6960).

```zig
if (opt.type.cast(.option).zero_union) {
    const expr = try c.ir.newExpr(.unwrap_nz, payload_t, node, .{ .option = opt.ir });
    ...
} else {
    ...
    const loc = try c.ir.newExpr(.unwrap_addr, ptr_t, node, .{
        .choice = addr.ir,
        .tag = 1,
    });
```

두 IR 은 VM 에서 이렇게 실행된다(src/vm.c:1298~1319, 두 명령을 나란히 놓고 줄여서 옮겼다).

```c
CASE(UnwrapAddr): {                       CASE(UnwrapNZ): {
    Value* ptr = (Value*)stack[pc[2]];        Value val = stack[pc[2]];
    if (VALUE_AS_INTEGER(ptr[0]) == pc[3]) {  if (val != 0) {
        stack[dst] = ((u64)ptr) + pc[4];          stack[dst] = val; ...
    } else {                                  } else {
        z_panic_unexpected_choice(t, pc[3], ..);  z_panic_unexpected_choice(t, 1, 0);
        RETURN(RES_PANIC);                        RETURN(RES_PANIC);
```

즉 태그 있는 Option 은 "태그 슬롯 == 1 인가", zero_union 은 "값이 0 이 아닌가"를 검사하고, 실패하면 둘 다 같은 메시지 "Expected active choice tag `1`, found `0`." 로 스레드를 패닉시킨다. Option 이 choice 의 특수형이라는 구현 사실이 메시지에서 드러난다. 5.11 실험에서 `find(..).?`, 제너레이터 `g.next().?` 모두 이 패닉으로 멈추는 것을 확인했다.

검사가 없는 경로는 이름에 `unsafe` 가 붙은 것들이다.

| 접근 방법 | 검사 | 근거 |
|---|---|---|
| `x.?` | 있음 (패닉) | UnwrapAddr/UnwrapNZ, src/vm.c:1298~1319 |
| `x.!case` (choice) | 있음 | 같은 `UnwrapAddr`, 메시지 "Expected active choice tag `1`, found `0`." (src/test/types/choice_unwrap_panic.cy) |
| `if x \|v\|:`, `while x \|v\|:`, `x ?else y` | 있음 (none 분기가 먼저) | 검사 뒤 `semaUnwrapOptionNoCheck` (src/sema.zig:1979~1996, 1096) |
| `r.unwrap()` (Result) | 있음 | `@result_unwrap`. 5.11 에서 같은 패닉 확인 |
| `meta.access_option_payload(x)` | 없음 | `#[bind, unsafe]` (src/builtins/meta.cy:112~114, meta.zig:262~271) |
| `meta.access_result_payload(r)` | 없음 | 같은 파일. 실패한 Result 의 에러 심볼 id 를 int 로 읽어 냄 |
| `meta.access_choice_case(c, Tag)` | 없음 | src/builtins/meta.zig:273~ |

`access_option_payload` 는 의미가 단순하다. zero_union 이면 값을 비트캐스트하고, 아니면 슬롯 1 의 필드를 읽는다. 태그는 보지 않는다. 5.11 에서 `?int(none)` 에 대고 호출하면 `-8161530843051276573` 같은 스택 쓰레기가 나온다. 이 함수는 core.cy 내부(`Future.await`, `dump_str`, `@destruct` 등)에서 태그를 이미 확인한 뒤 쓰도록 만든 도구인데, `use meta` 만 하면 사용자 코드도 호출할 수 있다. 처음 관찰한 -9223372036854775806 은 제너레이터 프레임 복원 문제([Day 7](07-coroutines-concurrency.md))로 payload 슬롯이 오염된 결과일 가능성이 높지만, 그 값을 만든 정확한 경로는 이 장에서 재현하지 못했다(미확인). 다만 `.?` 문법이 검사를 건너뛴다는 증거는 어디에도 없다.

### 2.13 타입 선언은 어떻게 해석되나 (sema_type.zig)

`ensure_resolved_type`(src/sema_type.zig:112~226)이 kind 로 분기하고, 대부분은 `info` 플래그만 채우고 끝난다. 의미 있는 분기는 이렇다.

| kind | 하는 일 |
|---|---|
| struct_t | `resolveStructType`(:760): (1) `resolve_type_impls` 로 `with Trait` 목록 수집 (2) `resolveStructFields` 로 필드 평가와 레이아웃 |
| enum_t | `declare_enum_cases`(:309): 케이스마다 `EnumCase` 심볼, 값은 선언 인덱스 |
| choice | `declare_choice_cases`(:421): 페이로드 타입 평가, 크기 계산. 짝이 되는 `Tag` 열거형도 함께 해석 |
| pointer | `^T` 이면 managed + copy_base. `Ptr[T]` 는 타입 모듈에 `@deinit` 이 있을 때만 managed |
| func, ref_trait, dyn_trait | managed + copy_base (힙 객체를 가리킴) |
| borrow, ex_borrow | `borrow_only = true`, managed 아님 |
| option, result, vector, partial_vector | 2.11절의 크기 계산 + 자식의 managed/copy 플래그 상속 |
| generic_trait | `resolve_trait_type`(:82): 트레이트 메서드를 `Func(.trait)` 로 예약하고 `vtable_idx` 를 선언 순서로 부여 |

세부 규칙 몇 가지.

- 필드 그룹. `type Vec3(x, y, z float)` 처럼 타입이 없는 필드는 뒤따르는 첫 타입 있는 필드의 타입을 쓴다(`indexOfTypedField`, :781~788, :819~829).
- 타입 임베딩. 필드를 `b use Base` 로 선언하면 `embedded=true` 이고 필드 타입이 구조체가 아니면 "Embedded field must be a struct type" 오류다(:856~871). 임베딩은 런타임 변화 없이 sema 가 `c.a` 를 `c.b.a` 로 풀어 주는 컴파일 시점 치환이다(src/sema.zig:2058~2063, 7473~7481). docs.md 는 "Planned Feature" 라고 쓰지만 실제로는 동작한다(5.13).
- 복사 규칙. `resolve_type_info`(:942~959)가 `NoCopy` 를 구현한 타입에 사용자 `@copy` 가 있으면 "Cannot override `@copy` if type implements `NoCopy`." 로 막는다. `copy_base` 는 "자식 중 복사 생성자가 필요한 것이 있는가" 이고 `copy_user` 는 사용자 정의 `@copy` 유무다.
- 타입 별칭. `type Pos2 = Vec2` 는 새 타입이 아니고 `alias.sym = type_.sym()` 로 같은 TypeSym 을 가리킨다(`resolve_type_alias`, :239~253). `type int = Int[64]` 도 같은 방식이다. 이름이 여러 개인 하나의 타입이다.
- `type X const:`. 본문을 컴파일타임에 실행해(`cte.evalFuncBody`) 타입 값을 돌려받는다(`resolve_type_const`, :14~32). 결과 타입의 심볼 이름을 별칭 이름으로 덮어쓰는 부분이 있어 5.14 에서 부작용을 본다.
- 호스트 타입. `#[bind] type X _` 는 core.zig 의 `types` 표에서 생성 함수를 찾는다(`resolve_custom_type`, :35~68). 오류 메시지가 아직 옛 이름 `@host` 를 말한다("Custom type requires a `@host` attribute.").

### 2.14 타입 호환 판정과 암시적 캐스트

핵심은 단순하다. 타입 동일성은 `Type` 포인터 비교다. `semaExpr` 의 끝부분(src/sema.zig:6312~6330)이 전부다.

```zig
if (cstr.target_t) |target_t| {
    if (target_t == res.type) { return res; }
    if (cstr.fit_target) {
        if (try semaFitTarget(c, res, target_t, node)) |new| { return new; }
    }
    if (res.type.id() == bt.Never) { return res; }
    if (cstr.reqTypeCstr) { return reportExpectedType(c, target_t, res.type, node); }
}
```

타입이 정확히 같으면 통과, 아니면 `semaFitTarget` 이 "암시적 변환을 삽입할 수 있는가" 를 시도하고, 안 되면 오류다. 구조체는 이름이 같은 선언끼리만 같은 타입이고 템플릿 인스턴스는 캐시되어 항상 같은 포인터이므로, 필드가 똑같은 두 구조체는 호환되지 않는다(5.12 e1). TypeScript 의 구조적 타이핑(structural typing)과 정반대다. 함수 시그니처는 위에서 본 해시-컨싱 때문에 구조적으로 같다.

`semaFitTarget`(src/sema.zig:10101~10367)이 바로 docs.md 의 "Implicit casts." 표(docs/docs.md:980~1024)의 구현이다. target 의 kind 로 switch 하고 source 가 맞는지 본다. 코드에서 확인한 분기를 요약하면:

| target kind | 허용되는 source | 동작 |
|---|---|---|
| option | `T` (자식 id 가 정확히 같을 때) | `semaWrapSome` |
| result | `error`, `T`, 그리고 재귀적으로 `T -> !?T` | `semaInitChoice(tag 0/1)` |
| ref_trait / borrow_trait | `^S` / `&S` (S 가 그 trait 를 `with` 로 선언) | trait 팻 포인터 생성 |
| borrow | `^T` (같은 T), 함수 포인터 -> `&Func` | 비트캐스트 / 감싸기 |
| func | 같은 시그니처의 func_ptr | `Func` 로 감싸기 |
| pointer | `Ptr[T] <-> Ptr[void]`, `Ptr[Int[W]] <-> Ptr[Raw[W]]`, `&T -> Ptr[T]`, `&[N]T -> Ptr[T]`, `&[..N]T -> Ptr[T]`(+8 오프셋) | 비트캐스트 |
| float | `f32 -> f64`, `Int[]`, `Raw[]` -> `Float[]` | 변환 |
| int | 더 작은 `Int` (부호 확장), 같거나 작은 `Raw` | sext / zext / 비트캐스트 |
| raw | 더 작은 `Raw`, 같거나 작은 `Int` (`distinct` 인 `error`/`symbol` 제외) | zext / 비트캐스트 |

문서와 다른 점 하나. docs.md 표에는 `^T -> Object` 가 있지만 코드에서 이 분기는 주석 처리되어 있다(src/sema.zig:10103~10120). 실제로 `var o Object = ^5` 는 "Expected type `Object`, got `^int`." 이고 `Object(^5)` 처럼 명시적으로 만들어야 한다(5.12).

함수 호출에서는 `isTypeCompat`(src/types.zig:1443~1457)이 인자 매칭에 쓰이는데, 포인터 같음, `Ptr[void]` 가 모든 `Ptr` 를 받음, `c_variadic` 가 무엇이든 받음, 이 셋이 전부다(호출 해석은 Day 3). 오류 메시지는 경로에 따라 세 가지 말투가 섞여 있다: "Expected type `int`, got `str`."(`reportExpectedType`), "Expected type `Showable`. Found `type`."(`reportIncompatType`), "Expected argument `A`, found `B`, when calling `fn take(A) -> void`."(src/sema_func.zig:1301).

Any 에 대해서도 주의: `Any` 는 "값의 타입" 이 아니라 템플릿 매개변수의 제약이다. `var x Any = 1` 은 "Expected type `Any`, got `int`." 이고 `fn show(x Any)` 도 호출 시 같은 오류다. 임의 타입을 받으려면 `fn show(x %T)` 를 쓴다(5.12). TS 의 `any`/`unknown` 에 해당하는 최상위 값 타입이 없다.

### 2.15 템플릿(제네릭): 확장과 캐시

`type Box[T Any]` 는 `Template` 심볼이고(src/sym.zig:638~677) 틀 자체에는 매개변수 이름만 있다. 인스턴스는 `Instance`(src/template.zig:15~44)이고 `param_types`, `params`(값, 소유), 그리고 이름으로 값을 찾는 `map`(2개 이하는 이름 두 개, 3개 이상은 해시맵)을 가진다. 확장은 `expand_template2`(src/template.zig:272~327) 한 함수다.

```
 expand_template2(template, arg_types, args)
   key = VariantKey{ param_types, params }
   ┌─ template.instance_cache 에 있나? ──yes──▶ 저장된 Instance 의 sym 반환
   no
   ├─ args 복사, Instance 생성, initParams
   ├─ reserve_template_instance            템플릿 선언에서 "껍데기 Type + TypeSym" 생성  (sema_type.zig:536)
   │     kind 별로 struct_t / enum_t / trait_t / custom_t / type_alias / type_const
   ├─ 캐시와 template.instances 에 먼저 등록     <- 주석: 순환 참조를 허용하려고 해석 전에 등록
   └─ resolve_new_types 이면 resolve_type_sym 으로 즉시 레이아웃 계산
```

세 가지 점이 중요하다.

1. 키는 (타입 매개변수 -> 타입 id, 정수/enum 매개변수 -> 값, 문자열 -> 내용, 함수 시그니처 -> id)로 해싱된다(`VariantKeyContext.hash`, :133~178). 그래서 `Box[int]` 는 어디서든 같은 타입이다. 처음 쓰이는 식에서만 `resolve type: Box[int] 127` 이 찍힌다(5.4).
2. 본문 안의 `T` 는 `getResolvedName` 의 두 번째 단계(인스턴스 매개변수 조회)에서 해결된다. 인스턴스마다 다른 값이 있으니 같은 틀의 메서드 본문이 인스턴스마다 따로 sema 된다. 트레이스에 `push func: Box[int].get`, `Box[str].get` 이 따로 나오는 이유다.
3. 선언 위치(함수 시그니처 등)에서는 `resolve_new_types=false` 로 확장하여 타입 껍데기만 만들고, 본문 안에서는 `true` 로 레이아웃까지 해석한다(주석: "Declaration sites only need the type handle and therefore don't need to be fully resolved.").

builtin 포인터류 `?T`, `!T`, `^T`, `&T`, `[]T`, `[N]T` 는 전부 이 경로를 쓴다. sema 가 `option_type` 노드를 만나면 `expand_template_ast(c, c.sema.option_tmpl, ...)` 를 부르고(src/sema.zig:6259~6262), `getOptionType`, `getPtrType`, `getRefType` 등도 `expand_template` 래퍼다(src/sema.zig:9857~9965). 다시 말해 `?int` 와 `Option[int]` 는 같은 인스턴스이고(src/test/core/Option.cy 의 "Equivalent to ?int."), 타입 이름을 그릴 때만 `?` 접두로 보인다(src/sym.zig:1575~1620).

함수 템플릿 `fn f[T Any]` 와 `%T` 제네릭 함수는 `FuncTemplate`(src/sym.zig:1068~1125)과 같은 `VariantKeyContext` 캐시를 쓴다(`expandResolvedFuncTemplate`, :481~540). 호출 쪽 매칭은 Day 3 이다.

`type X[T Any] const:` 는 `TemplateType.type_const` 템플릿이다. 인스턴스를 만들면 본문이 컴파일타임 실행되어 "다른 타입" 을 돌려주는 특수화 장치다. core.cy 의 `ExInner[T]`(조건에 따라 `T` 또는 `ExDefaultInner[T]`)와 `FnTuple[Sig]`(시그니처에서 튜플 구조체를 합성)가 실제 사용례다.

### 2.16 trait 와 Dyn: 타입 쪽 이야기

trait 는 두 얼굴을 가진다. 하나는 제네릭 제약(`T Showable`, `fn f(s Shape)`), 다른 하나는 `Dyn` 에 담아 쓰는 동적 디스패치 인터페이스다. 호출 명령(`CALL_TRAIT`)과 vtable 은 [Day 4](04-bytecode-gen.md)가 다루고, 여기서는 타입만 본다.

선언과 구현. `type Shape trait:` 는 `generic_trait` 타입이고 메서드는 `Func(.trait)` 로 예약된다. `type Circle: with Shape` 는 `Struct.impls` 에 `Impl{trait, funcs}` 를 남긴다(`resolve_type_impls` 는 struct_t 만 처리하고 나머지는 `error.TODO`, src/sema_type.zig:991~999. enum/choice 선언은 파서가 `with` 를 "Expected case keyword." 로 거부하므로 trait 는 구조체만 구현한다). 실제 구현 검사는 해석 단계가 아니라 모든 함수 본문이 sema 된 뒤, `compileInner` 의 "Pass through type syms" 루프에서 한다(src/compiler.zig:452~489). 메서드 해석이 끝나야 비교할 수 있어서다.

```zig
// src/compiler.zig:470~480 (발췌)
for (trait_members, 0..) |member, i| {
    const func = type_.get_trait_method_impl(member) orelse {
        ...
        return chunk.reportErrorFmt("`{}` does not implement `fn {}{}` from `{}`.", ...);
    };
    funcs[i] = func;
}
impl.funcs = funcs;
```

`impl.funcs` 가 곧 이 (타입, trait) 쌍의 vtable 원본이다(bc_gen 의 `VtableKey{type, trait}`, src/bc_gen.zig:24~27). 그런데 이 검사 함수에 버그가 있다. 5.13 에서 재현한다.

```zig
// src/types.zig:625~640 (발췌)
const trait_params = trait_sig.params()[1..];
const func_params = func.sig.params()[1..];
for (trait_params, 0..) |trait_param, i| {
    if (trait_param != func_params[i]) {
        next = func.next;
        continue;            // <- 안쪽 for 의 continue. 바깥 while 로 가지 않는다
    }
}
if (trait_sig.ret != func.sig.ret) { ... continue; }
return func;
```

파라미터가 다르면 `continue` 를 하지만 이것은 안쪽 `for` 를 이어 가는 것이라 불일치가 무시되고, 반환 타입만 같으면 그 함수를 구현으로 채택한다. 게다가 `func_params[i]` 는 길이 검사 없이 인덱싱한다(반대로 구현 쪽 파라미터가 trait 보다 많은 경우는 `for` 가 trait 쪽 길이까지만 돌아 통과할 것으로 읽히지만 실험하지 않았다). 결과적으로 파라미터 타입이 다른 메서드가 통과하고(호출하면 타입이 섞인다), 파라미터 개수가 적은 메서드는 컴파일러 자체가 `index out of bounds` 로 죽는다(5.13).

`Dyn` 변환. `Dyn[T]` 는 `create_dyn_type` 이 만드는 `dyn_trait` kind 컨테이너이고 T 는 trait 여야 한다(src/builtins/core.zig:533~548). `Ref[Dyn[T]]` 는 `ref_trait`(`^Dyn[T]`), `Borrow[Dyn[T]]` 는 `borrow_trait`(`&Dyn[T]`)로 바뀐다(:550~565, 583~598). 둘 다 16바이트다. `^Circle` -> `^Dyn[Shape]` 은 `semaFitTarget` 의 `ref_trait` 분기(src/sema.zig:10146~10162)에서 `Struct.implements` 를 확인하고 IR `.trait` 노드를 만든다. VM 의 `Trait` 명령은 두 슬롯을 쓴다(src/vm.c:1281~1291).

```c
stack[dst]   = vtable;     // pc[4]. vtable 번호
stack[dst+1] = impl;       // 구현 객체 포인터
```

암시적 trait. 멤버가 없고 `@predicate(T type) -> bool` 이 있는 trait 는 컴파일타임 조건 검사다. `Copyable`, `Const` 가 그 예이고(src/builtins/core.cy:761~765, 1432~1436), `implements`(src/sema_type.zig:1298~1331)가 `cte.evalCall` 로 술어를 실행해 결과를 `GenericTrait.impls` 집합에 캐시한다. 템플릿 제약 `type OnlyCopy[T Copyable]` 은 이 경로로 `NoCopy` 타입을 막는다(5.12). 단, 제약 위반 메시지는 "Expected type `Copyable`. Found `type`." 처럼 읽기 어렵다.

## 3. 핵심 개념 정리

TS/Node 대응은 "일반 지식" 이다. 같아 보여도 의미가 다른 곳을 오른쪽 칸에 적었다.

| Cyber 개념 | TS/Node 에서 가장 가까운 것 | 다른 점 |
|---|---|---|
| Chunk / Module / `use` | ES 모듈 / `import` | `use` 는 해석될 때 파일을 읽는다. `use *` 만 즉시 로드. 모듈 이름공간은 `symMap` 하나 |
| Sym, `reserve`, `resolve` | ts 의 Symbol, binder, checker | checker 와 달리 비템플릿 선언은 전부 즉시 해석 |
| core 의 fallback_modules | 전역 `lib.d.ts` | 별도 장치가 아니라 모든 청크의 조회 마지막 단계일 뿐 |
| `struct` (기본 `type X:`) | interface / class | 명목 타이핑, 값 타입(대입하면 복사), 필드 순서가 곧 메모리 순서 |
| `^T` | (없음. JS 객체는 항상 참조) | 명시적 힙 박스. 참조 카운트. 스택 값을 힙으로 올리는 연산이 문법에 보인다 |
| `&T`, `&&T` | (없음) | 빌림. 스택 값을 복사 없이 넘기는 방법 (Rust 의 `&`, `&mut` 와 비슷, 일반 지식) |
| `?T` | `T \| undefined` | 태그 값(16바이트) 또는 널 포인터 최적화(8바이트). `.?` 는 TS 의 `!` 와 달리 런타임에서 검사 |
| `!T` | (Promise reject, throw) | 값으로 전달되는 에러 (Rust `Result`, Go `(T, error)` 와 비슷, 일반 지식) |
| choice | 판별 유니온 (discriminated union) | 태그가 언어에 내장. 케이스 이름이 곧 판별자 |
| enum | enum | 8바이트 태그. 페이로드가 있으면 choice |
| trait + `with` | interface + `implements` | 구현을 선언해야만 만족 (구조적이지 않음). `Dyn[T]` 에 담아야 동적 디스패치 |
| template `type C[T Any]` | 제네릭 클래스 | 타입 소거가 아니라 인스턴스마다 별개 타입과 코드가 생김 (C++ 템플릿에 가까움) |
| `type X const:` | 조건부 타입 `T extends U ? A : B` | 타입 수준 DSL 이 아니라 컴파일타임에 실행되는 Cyber 코드 (Zig comptime 에 가까움) |
| `Any` | `T extends unknown` | 제약일 뿐 값의 타입이 아님. 최상위 값 타입이 없음 |
| `Object` | `unknown` + 런타임 타입 검사 | `Object(^x)` 와 `downcast(^T)` 로 힙 값을 지운 타입. 동적 타입의 유일한 잔재 |
| `int` | (없음. JS number 는 double) | 64비트 정수. `float` 가 double |
| `reg_size` | (없음) | 값이 스택 8바이트 슬롯을 몇 칸 쓰는지. 호출 규약과 명령어 선택의 기준 |
| 해시-컨싱된 FuncSig | 구조적 함수 타입 | 같은 (파라미터, 반환)이면 같은 포인터 = 같은 타입 |

## 4. 소스 읽기 지도

한 번에 다 읽으려 하지 말고 이 순서로 따라가면 앞 절의 내용이 파일 위치와 맞물린다.

1. src/sym.zig:16~62 `SymType`, `Sym` -> :549~575 `FuncSym` -> :881~992 `FuncKind`, `FuncInfo`, `Func` -> :1068~1125 `FuncTemplate`. 파일 끝의 테스트(:1734~1751)에서 C 레이아웃 일치 검사를 본다. `createXxx` 함수(:1164~1444)는 모두 `c.syms` 에 심볼을 `append` 한다는 점만 확인한다.
2. src/module.zig:23~113 `Module`, `addUniqueSym`. -> :408~441 `reserveFunc`, :471~487 `resolveFunc` (오버로드 유일성). -> :532~602 `getResolvedSym` (끝부분의 "Lazily load instance sym"). 파일 중간의 `reserveTemplateFunc`(:378), `reserveHostObjectType`(:152)는 호출처가 없는 옛 코드다(7절).
3. src/chunk.zig:34~196. 필드 이름만 훑는다. `fallback_modules`(:107), `syms`(:111), `funcs`(:115), `reserved_syms`(:182)가 오늘의 주인공이고, 나머지 대부분은 sema/codegen 작업용 스택이다. :780~884 의 `pub const reserveXxx = cy.module.reserveXxx` 별칭 목록은 "Chunk 메서드처럼 부르지만 구현은 module.zig/sema.zig" 라는 안내판이다.
4. src/compiler.zig: :315~531 지휘 순서, :1052~1098 `loadChunk`, :1148~1248 `reserveChunkSyms`, :1299~1375 `resolveSym`, `resolveChunkSyms`. 그리고 :879~970 `loadBuiltinChunk` 에서 `c.sema.option_tmpl` 같은 빌트인 템플릿이 이름으로 꽂히는 곳을 본다(`core.getSym("Option")`).
5. src/sema.zig:4160~4238 `getResolvedName` (이름 조회 6단계), :2447~2502 `declareUseImport`, :2411~2445 `resolveUseAlias`.
6. src/types.zig: :17~93 `TypeKind`, `TypeInfo`, `Type` -> :217, :384~443 `reg_size`, `alignment`, `size` -> :820~1043 `Result`, `Option`, `Choice`, `Struct` -> :1205~1243 `BuiltinTypes`. 같은 파일 후반(:1405~1508 `isAnyOrDynamic`, `isRtTypeCompat`, `unionOf` 등)은 0.3 시절 잔재라 읽지 않아도 된다.
7. src/sema_type.zig: :112~226 `ensure_resolved_type` -> :409~500 choice -> :760~927 `resolveStructType`, `resolveStructFields` -> :1057~1148 Result/Option 크기 -> :1298~1331 `implements`.
8. src/builtins/core.zig:32~77 (`types` 표), :550~565, :808~825 (Ref, Option 생성). 짝으로 src/builtins/core.cy:232~300 (void, bool, error, byte), :395~409 (Int), :1026 (Slice), :1662 (Array), :3237 (str), :4071~4091 (Result, Option), :4319 (Generator), :4375 (Dyn).
9. src/template.zig:15~44 `Instance`, :133~228 해시와 `eql`, :272~327 `expand_template2`. 이어서 src/sema_type.zig:536~600 `reserve_template_instance`.
10. 호환 판정: src/sema.zig:6304~6332 `semaExpr` 끝부분 -> :10101~10367 `semaFitTarget` -> src/sema_func.zig:1146~1160, 1260~1272 호출 인자 매칭.
11. trait: src/compiler.zig:452~489 -> src/types.zig:613~643 `get_trait_method_impl` (F-22, 2026-11-08 수정).
12. meta API: src/builtins/meta.cy:112~338 의 `TypeInfo` 선언. 구현은 meta.zig.
13. 역사: docs/history/type_system.md 와 이 문서 6절의 `git show` 명령.

## 5. 실습

모든 실험은 `zig-out/bin/cyber 파일.cy` 로 실행한다. 컴파일 로그가 필요한 실험(5.1, 5.2, 5.4)은 `zig build -Dtrace=true --prefix <폴더>` 로 만든 trace cyber 를 `cyber -v 파일.cy > out.trace 2>&1` 로 돌려 파일로 받은 뒤 `rg` 로 거른다(출력이 7만 줄 이상이다). 아래의 "출력" 은 실제 실행 결과이고, 경로는 `...` 로 줄였다. 소스에서 `'x'` 한 글자 문자열은 룬 리터럴로 취급되어 `int` 로 받아지는 점에 주의하자(`return 'x'` 는 `-> int` 에서 오류가 나지 않는다). 아래 실험의 오류 재현에는 두 글자 이상의 문자열을 쓴다.

### 5.1 reserve -> resolve 순서를 로그로 보기

```
type Point:
    x int
    y int

type Unused:
    a int

fn dist(p Point) -> int:
    return p.x * p.x + p.y * p.y

fn never_called() -> int:
    return 99

fn main():
    p := Point{x=3, y=4}
    print(dist(p))
```

실행하면 `25`. trace cyber 로 `rg -n 'compiler: |sema_type: resolve type' r1.trace` 를 하면 사용자 청크 구간이 이렇게 보인다.

```
compiler: chunk parse: 0
compiler: resolve chunk syms: .../r1.cy
compiler: resolve: r1 .chunk
compiler: resolve: Point .type
sema_type: resolve type: Point 114
compiler: resolve: Unused .type
sema_type: resolve type: Unused 115
compiler: resolve: dist .func
compiler: resolve: never_called .func
compiler: resolve: main .func
compiler: resolve: x .field
compiler: resolve: y .field
compiler: resolve: a .field
compiler: resolve: dist
compiler: resolve: never_called
compiler: resolve: main
```

관찰 포인트. (1) 사용하지 않은 `Unused` 도 해석된다. (2) 심볼 루프가 먼저 돌고(`.func` 항목은 no-op), 그 사이에 타입 해석이 만든 `.field` 심볼이 목록 끝에 붙어 같은 루프에서 처리된다. (3) 함수 시그니처(`resolve: dist` 등 종류 표시 없는 줄)는 그 뒤 두 번째 루프다. (4) 타입 id 114, 115 는 core 의 타입들이 먼저 번호를 쓴 뒤의 값이다. 이어서 로그 앞부분(`resolve: NoCopy .type` ... `resolve: rsize .type_alias`)은 core 청크가 먼저 해석되는 장면이다.
변형: `type Unused` 의 필드 타입을 존재하지 않는 `Nope` 로 바꾸면 사용하지 않아도 컴파일 오류가 난다.

### 5.2 `use` 와 청크 로딩

```
use math

fn later() -> float:
    return math.sqrt(2.0)

fn main():
    print(later())
```

출력 `1.4142135623730951`. trace 로그에서 `rg -n 'compiler: (Invoke|chunk parse|resolve chunk syms)'` 를 하면 청크 id 와 순서가 보인다: 청크 id 는 만들어진 순서라서 사용자 파일이 0, core 가 1, meta 가 2 이지만 파싱은 core(1), meta(2), 사용자(0) 순이다. 사용자 청크의 `resolve: math .use_alias` 직후에 `Invoke module loader: .../std/math.cy`, `chunk parse: 3` 이 나온다. math 의 심볼 해석(`resolve chunk syms: .../math.cy`)은 사용자 청크 해석이 끝난 뒤 `compileInner` 의 청크 루프가 처리한다. math 가 쓰는 `c.cy` 는 청크 4 로 그 뒤에 로드된다.

### 5.3 지연되는 것과 지연되지 않는 것

```
fn never() -> int:          -- lazy1.cy: 한 번도 호출되지 않는 일반 함수
    return 'xyz'
fn main():
    print('ok')
```

출력은 "CompileError: Expected type `int`, got `str`." 이고 위치는 `lazy1.cy:2:12` 다. 호출이 없어도 일반 함수 본문은 검사된다. 반면 템플릿 메서드는 쓰기 전까지 검사되지 않는다.

```
type Bad[T Any]:            -- lazy2~4 가 공유하는 선언
    v T
fn (&Bad[]) m() -> int:
    return 'xyz'
```

| 파일 | main 본문 | 결과 |
|---|---|---|
| lazy2.cy | `print('ok-unused-template')` (템플릿을 안 씀) | 정상 실행 |
| lazy3.cy | `b := Bad[int]{v=1}` 후 `b.v` 만 출력 (`m` 호출 없음) | `ok-instantiated-no-call 1` |
| lazy4.cy | `b := Bad[int]{v=1}` 후 `print(b.m())` | "CompileError: Expected type `int`, got `str`." |

템플릿 인스턴스의 메서드 본문은 접근하는 순간 비로소 해석된다는 2.6절의 주장이 이 세 줄로 확인된다. 참고로 `return 'x'` 처럼 한 글자 문자열은 룬 리터럴이라 `int` 로 받아져 오류가 나지 않았다(lazy4 에서 `120` 이 출력됨). 오류 재현에는 두 글자 이상을 써야 한다.

### 5.4 템플릿 확장 이름 관찰

```
type Box[T Any]:
    inner T

fn (&Box[]) get() -> T:
    return self.inner

type Grid[T Any, const N int]:
    cells [N]T

fn pick(%T type, a T, b T) -> T:
    return a

#[generator]
fn count() -> int:
    yield 1
    yield 2

fn main():
    a := Box[int]{inner=7}
    b := Box[str]{inner='hi'}
    c := Box[int]{inner=9}
    print(a.get())
    print(b.get())
    print(c.get())
    g := Grid[int, 3]{cells={1, 2, 3}}
    print(g.cells[1])
    print(pick(int, 1, 2))
    print(pick(float, 1.5, 2.5))
    gen := count()
    while gen.next() |v|:
        print(v)
```

출력은 한 줄씩 `7`, `hi`, `9`, `2`, `1`, `1.5`, `1`, `2` 다. trace cyber 로 받은 로그를 `rg -n 'Box|Grid|Generator\[|pick' tpl2.trace` 로 거르고 `cte:`/`ir:` 줄을 빼면 다음이 나온다(발췌).

```
3633 compiler: resolve: Box .template
3635 compiler: resolve: Grid .template
3636 compiler: resolve: pick .func              <- %T 가 있어 FuncKind.generic 이 됨
3655 sema_type: resolve type: Generator[fn() -> int] 115   <- count() 의 반환 타입을 시그니처 해석 중에
3696 sema_type: resolve type: ^Generator[fn() -> int] 116
4581 sema_type: resolve type: Box[int] 127         <- main 본문의 첫 사용에서 인스턴스 생성
4600 sema_type: resolve type: Box[str] 128
4634 sema_type: resolve type: &Box[int] 129        <- 메서드 수신자용 빌림 타입도 별개 타입
4703 sema_type: resolve type: Grid[int, 3] 131
4946 sema: push func: Box[int].get
4983 sema: push func: Box[str].get
5133 sema: push func: pick[int]
5143 sema: push func: pick[float]
5179 sema: push func: Generator[fn() -> int].next
```

관찰 포인트: (1) 타입 이름이 인스턴스 인자까지 포함해 `Box[int]` 로 찍힌다. (2) `Box[int]` 는 두 번 썼지만 한 번만 해석된다. (3) 메서드 `get` 은 인스턴스마다 따로 `push func` 된다. (4) 제너레이터의 `next` 도 `Generator[fn() -> int].next` 라는 템플릿 인스턴스의 메서드다 (제너레이터 자체는 [Day 7](07-coroutines-concurrency.md)).

### 5.5 선언 순서 독립과 순환 참조

```
fn main():
    a := ^A{v=1, b=none}
    b := ^B{v=2, a=a}
    a.b = b
    print(a.b.?.v)
    print(later(3))

type A:
    v int
    b ?^B

type B:
    v int
    a ?^A

fn later(n int) -> int:
    return n * K

const K = 10
```

출력 `2`, `30`. 사용이 선언보다 앞서고 `A`, `B` 가 서로를 참조하지만 문제가 없다. 이제 값으로 순환시켜 본다(`type A: b B` / `type B: a A`)

```
CompileError: Structs can not contain a circular dependency.
.../fwd2.cy:5:7:    a A
.../fwd2.cy:2:7:    b B
.../fwd2.cy:1:1: type A:
```

해석 경로를 따라 세 위치가 오류 스택으로 나온다(`resolving_struct` 플래그가 켜진 상태에서 재진입했기 때문, 2.5절).

### 5.6 이름 충돌, 가림, 중복

같은 파일에 `type A:` 를 두 번 선언하면 두 위치를 모두 보여 준다.

```
CompileError: `A` has already been declared as a `type`
.../dup1.cy:3:1: type A:
First declared at:
.../dup1.cy:1:1: type A:
```

사용자 파일에서 `fn print(x int)` 를 선언하고 `print(5)` 와 `print('str')` 을 부르면 두 번째 호출이 "Expected argument `int`, found `str`, when calling `fn print(int) -> void`." 로 실패한다. core 의 `print` 와 오버로드가 합쳐지지 않고 사용자 `print` 가 가린다(2.4절의 조회 4단계가 5단계보다 먼저). `type Array: x int` 를 사용자 파일에 선언해도 `Map[int, int]{}` 는 그대로 동작한다(core 의 `Array` 는 core 청크 기준으로 조회되므로).

### 5.7 오버로드

```
fn f(a int) -> int:
    return a
fn f(a str) -> int:
    return a.len()
fn f(a int, b int) -> int:
    return a + b
```

`f(1)`, `f('abc')`, `f(1, 2)` 의 출력은 `1`, `3`, `3` 이다. 인자 타입과 개수로 오버로드가 고른다. 이제 같은 파라미터에 반환 타입만 다르게 선언해 본다.

```
fn f(a int) -> int:
    return a
fn f(a int) -> float:
    return 1.0
fn main():
    print(f(1))
```

수정 전 출력은 `1` 이고 오류가 없었다. 2.3절에서 말한 구멍이다. 파라미터가 같고 반환만 다른 선언은 거부되지 않았고 호출은 먼저 선언된 쪽으로 갔다. 2026-11-08 `cf4aa84a`(F-21)부터는 "`f` has already been declared with the same parameters. Overloads must differ in their parameter types, not only in the return type." 컴파일 오류다. 파라미터와 반환이 모두 같을 때만 "`f` has already been declared with the same function signature." 가 나온다. 오버로드된 이름을 값으로 쓰면(`g := f`) 오류 메시지가 `AmbiguousSymbol` 이라는 Zig 에러 이름 그대로 나온다. 함수와 타입이 같은 이름이면 5.6 의 "has already been declared as a `type`" 이 나온다.

### 5.8 meta 로 타입 정보 조회하기

`type.size(T)`, `type.name(T)`, `type.info(T)` 는 컴파일타임에 평가되는 메타 함수다(src/builtins/meta.cy:242~326). 2.10절의 크기 표는 `print('str %{type.size(str)}')` 같은 줄을 타입마다 나열한 프로그램의 출력이다. 함수 타입은 식 위치에 쓸 수 없어서(`type.size(fn() -> int)` 는 ParseError: Expected colon.) `type Cb = fn() -> int` 별칭을 거쳤다. `type.info` 의 결과는 choice `TypeInfo`(`.struct`, `.option`, `.choice`, `.int`, `.ref`, `.result`, ...)라서 `#switch` 로 분기할 수 있다. 컴파일타임 값을 문자열에 넣으려면 `#{...}` 로 감싼다(그냥 `%{info.fields.len()}` 는 "Unsupported expansion of compile-time value of type: `?EvalStr`" 오류).

```
type P:
    x int
    y float
type Shape enum:
    case circle float
    case rect P
    case point

fn describe(%T type) -> str:
    #switch type.info(T):
        #case .struct |info|:
            return 'struct %{type.name(T)}, %{#{info.fields.len()}} fields, size=%{type.size(T)}'
        #case .option |info|:
            return 'option %{type.name(T)}, size=%{type.size(T)}'
        #case .choice |info|:
            return 'choice %{type.name(T)}, %{#{info.cases.len()}} cases, size=%{type.size(T)}'
        #case .int |info|:
            return 'int %{type.name(T)}, bits=%{#{info.bits}}'
        #case .ref |info|:
            return 'ref %{type.name(T)}'
        #case .result |info|:
            return 'result %{type.name(T)}, size=%{type.size(T)}'
        #else:
            return 'other %{type.name(T)}'
```

`describe(P)`, `describe(?int)`, `describe(?^P)`, `describe(Shape)`, `describe(int)`, `describe(i8)`, `describe(^P)`, `describe(!int)`, `describe(Array[int])`, `describe(Map[str, int])`, `describe([]int)`, `describe([4]int)` 를 차례로 부른 출력이다(지면 때문에 두 열로 재배치했다).

```
struct P, 2 fields, size=16            choice Shape, 3 cases, size=24
option ?int, size=16                   int int, bits=64      int i8, bits=8
option ?^P, size=8                     ref ^P                result !int, size=16
struct Array[int], 3 fields, size=24   struct Map[str, int], 1 fields, size=48
struct []int, 4 fields, size=32        other [4]int
```

`Array`, `Map`, `[]int` 가 일반 struct 로 분류되는 것, `[4]int` 는 `.vector` 인데 위 switch 에 케이스가 없어 `other` 인 것을 눈여겨보자. 필드 오프셋은 `#for 0..info.fields.len() |i|: #field := info.fields[i]` 로 읽는다. 2.10절의 `A size=24: lo@0 mid@8 hi@16` / `B size=16: mid@0 lo@8 hi@9` 가 이 코드의 출력이다. 참고로 core.cy 의 `dump(x)` 는 구조체 필드 중 기본형은 값이 아니라 타입 이름(`x: int`)을 찍는다. 값 덤프가 필요하면 직접 만들어야 한다.

### 5.9 TypeInfo 플래그 찍어 보기

```
fn row(%T type):
    print('%{type.name(T)}: managed=%{type.managed(T)} copyable=%{type.is_copyable(T)} const=%{type.is_const(T)}')
```

타입별 출력(P{int,int}, WithStr{str,int}, WithRef{^P}, Own{with NoCopy}, HasDeinit{@deinit 정의}).

```
int: managed=false copyable=true const=true          P: managed=false copyable=true const=true
WithStr: managed=true copyable=true const=false      WithRef: managed=true copyable=true const=false
Own: managed=false copyable=false const=true         HasDeinit: managed=true copyable=true const=false
str: managed=true copyable=true const=false          Array[int]: managed=true copyable=false const=false
[]int: managed=true copyable=true const=false        ^P: managed=true copyable=true const=false
&P: managed=false copyable=true const=false          ?int: managed=false copyable=true const=false
?^P: managed=true copyable=true const=false          Ptr[P]: managed=false copyable=true const=true
!int: managed=false copyable=true const=false        Map[str, int]: managed=true copyable=false const=false
```

managed 는 "자식이 managed 이거나 `@deinit` 이 있으면" 전염되고, copyable 은 `NoCopy` 구현(Array, Map)이 전염된다는 것이 보인다. `?int` 는 const 가 아닌데 `int` 는 const 다. Option 은 const-eligible 판정에서 빠진다(src/types.zig:146~189 에 option 분기가 없음).

### 5.10 메모리 배치 직접 덤프

`&x` 로 주소를 얻어 `Ptr[int]` 로 캐스트하고 슬롯을 읽는다. `&T -> Ptr[T]` 는 암시적이고 `Ptr[S] -> Ptr[T]` 는 `as` 가 필요하다.

```
fn dump_words(name str, p Ptr[int], n int):
    out := name + ':'
    for 0..n |i|:
        out += ' ' + str(p[i])
    print(out)

fn mk(v int) -> !int:
    if v < 0:
        return error.Neg
    return v

type Mixed:
    a byte
    b int
    c byte

fn main():
    o1 := ?int(42)
    dump_words('?int(42)', as[Ptr[int]] &o1, 2)
    s1 := Shape.rect(P{x=7, y=8})
    dump_words('rect(7,8)', as[Ptr[int]] &s1, 3)
    m := Mixed{a=1, b=2, c=3}
    dump_words('Mixed', as[Ptr[int]] &m, 3)
    -- 나머지 줄은 ?int(none), Shape.point, Shape.circle(1.0), mk(5), mk(-1), ?^P(none) 에 대해 같은 방식
```

출력(이름 열 정리).

```
?int(42)    : 1 42                  ?int(none)  : 0
rect(7,8)   : 1 7 8                 point       : 2
circle(1.0) : 0 4607182418800017408 !int ok     : 1 5
!int err    : 0 50                  ?^P none    : 0
Mixed{byte,int,byte} : 1 2 4587943624963
```

`4607182418800017408` 은 `0x3FF0000000000000`, 즉 `1.0` 의 비트다. 마지막 줄의 세 번째 값 `0x42c36c00103` 은 하위 바이트 `0x03` 이 필드 `c` 이고 나머지 바이트(패딩)에는 스택에 남아 있던 쓰레기가 그대로 들어 있다. 구조체 패딩은 초기화되지 않는다.

### 5.11 `.?` 검사와 검사 없는 접근

```
fn find(xs &Array[int], v int) -> ?int:
    for 0..xs.len() |i|:
        if xs[i] == v:
            return xs[i]
    return none

fn main():
    xs := Array[int]{1, 2, 3}
    print(find(&xs, 2).?)
    n := find(&xs, 9)
    print('before unwrap')
    print(n.?)
```

```
2
before unwrap
panic: Expected active choice tag `1`, found `0`.
.../opt1.cy:12:11 main:
    print(n.?)
          ^
```

제너레이터가 끝난 뒤 `g.next().?` 도 같은 패닉이다(`#[generator] fn g1() -> int: yield 1` 에서 두 번째 `.?`). 이제 검사 없는 접근을 쓴다.

```
use meta
fn main():
    n := ?int(none)
    print(meta.access_option_payload(n))     -- 출력: -8161530843051276573 (실행마다 다를 수 있음, 스택 쓰레기)
```

Result 도 마찬가지다. 실패한 `mk(-1)` 에 `meta.access_result_payload(r)` 는 `50`(에러 심볼 id)을 돌려주고, `r.unwrap()` 은 같은 "Expected active choice tag" 패닉이다. 제너레이터 지역 변수가 `10, 11, 12` 가 아니라 `10, 11, 11` 로 나오는 문제([Day 7](07-coroutines-concurrency.md))에서도 `.?` 는 검사대로 동작하고 payload 값이 잘못 저장된 쪽이 문제다. 이 장에서는 쓰레기 값을 `.?` 가 만든 것은 아니라는 데까지만 확인했다. 제너레이터 `i := 10; yield i; ...` 를 `.?` 로 세 번 읽으면 이 장의 환경에서 `10`, `2599806046265`, `2599806046265` 가 나왔다.

### 5.12 타입 오류 메시지 모음

각각 `fn main()` 안에 한 줄씩 넣어 실행한 결과다.

| 실수 | 메시지 |
|---|---|
| 필드가 같은 `B` 를 `A` 인자에 전달 | `` Expected argument `A`, found `B`, when calling `fn take(A) -> void`. `` |
| `n := 10` 후 `n = 'abc'` | `` Expected type `int`, got `str`. `` |
| `x := find()`(`?int`) 후 `x + 1` | `` Can not find the symbol `+` for `?int`. `` |
| `var b Box[float] = a`(`a` 는 `Box[int]`) | `` Expected type `Box[float]`, got `Box[int]`. `` |
| `f(1, 'two')` | `` Expected argument `int`, found `str`, when calling `fn f(int, int) -> int`. `` |
| choice 의 `switch` 에서 `case .circle` 만 처리 | `` Unhandled cases in `switch`. `else` can be used to handle the remaining cases. `` |
| `x := 3.5` 후 `var n int = x` | `` Expected type `int`, got `float`. `` |
| `var big int = 300` 후 `var small i8 = big` | `` Expected type `i8`, got `int`. `` |
| `Grid[int, 3]` 를 `Grid[int, 4]` 에 대입 | `` Expected type `Grid[int, 4]`, got `Grid[int, 3]`. `` |
| `var o Object = ^5` | `` Expected type `Object`, got `^int`. `` (docs 표에는 허용으로 적힘) |
| `var x Any = 1`, `fn show(x Any)` 호출 | `` Expected type `Any`, got `int`. `` / `` Expected type `Any`. Found `int`. `` |
| `Wrap[int]` (`type Wrap[T Showable]`) | `` Expected type `Showable`. Found `type`. `` |
| `OnlyCopy[NC]` (`NC` 는 `with NoCopy`) | `` Expected type `Copyable`. Found `type`. `` |

관찰: (1) 암시적 변환은 확장(`i8 -> int`, `int -> float`)만 있다. `float -> int` 와 `int -> i8` 는 `as` 가 필요하다. (2) `?int` 에 대한 `+` 는 "Option 은 연산자가 없다" 는 심볼 조회 실패로 보고되어 "?를 풀어라" 같은 힌트가 없다. (3) 템플릿 제약 위반 메시지의 "Found `type`" 은 인자 `int` 가 타입 값이라서 그 값의 타입인 `type` 이 찍힌 것이다.

### 5.13 trait 구현 검사와 타입 임베딩

먼저 정상 동작. `Circle`, `Rect` 가 `with Shape` 로 `area()` 를 구현하고 `var s1 ^Dyn[Shape] = ^Circle{r=2.0}` 로 담은 뒤 `s1.area()`, `s2.area()` 를 부르면 `12`, `6` 이 나온다(`Circle.area` 는 `3.0 * r * r`). `type.size(^Dyn[Shape])` 는 `16`.

이제 2.16절의 버그를 재현한다.

```
type Shape trait:
    fn scale(k float) -> float
type Circle:
    with Shape
    r float

fn (&Circle) scale(k int) -> float:      -- trait 는 k float, 구현은 k int
    return k

fn main():
    c := ^Circle{r=2.0}
    var s ^Dyn[Shape] = c
    print(s.scale(2.0))
```

기대: 컴파일 오류. 실제 출력은 `4611686018427388000`. 오류 없이 컴파일되고, `2.0` 의 비트 패턴(`0x4000000000000000`)이 `int` 로 읽혀 다시 float 로 변환된 값이다. 같은 trait 에서 메서드 파라미터를 하나 빼면(`fn scale(k float, j float)` 인 trait 에 `fn (&Circle) scale(k float)` 구현) 컴파일러가 죽는다.

2026-11-08 수정 `40bfa711`: 세 경우(타입 불일치 · 적은 파라미터 · 많은 파라미터) 모두 "`Circle` does not implement `fn scale(Shape, float) -> float` from `Shape`." 컴파일 오류다. `get_trait_method_impl` 이 파라미터 개수와 모든 파라미터 타입, 반환 타입이 정확히 같은 메서드만 채택한다. 테스트 `src/test/types/trait_param_*_error.cy`. 아래 수정 전 관찰은 기록으로 남긴다.

```
thread 55137877 panic: index out of bounds: index 1, len 1
Cannot print stack trace: stack tracing is disabled
```

반환 타입이 다른 경우(`fn area() -> int` 구현)는 올바르게 "`Circle` does not implement `fn area(Shape) -> float` from `Shape`." 로 막힌다. 즉 반환 타입만 검사하고 파라미터는 사실상 검사하지 않는다. 오류 메시지에서 trait 메서드의 자기 자신 파라미터가 `Shape` 로 찍히는 것(`fn area(Shape)`)은 trait 메서드의 `self` 타입이 trait 자신이라는 2.16절 설명과 맞는다.

임베딩은 정상이다. `type Container: b use Base / c int`, `Base` 에 필드 `a` 와 메서드 `double()` 이 있을 때 `Container{b=Base{a=21}, c=1}` 에 대해 `c.a` 는 `21`, `c.double()` 은 `42` 가 된다. docs.md 의 "Planned Feature" 표시는 낡았다.

### 5.14 템플릿 캐시와 const 타입의 함정

세 가지 버그/함정을 재현한다. 모두 소스 읽기만으로 짚은 것이 아니라 실행으로 확인했다.

(a) 템플릿 캐시 충돌. 2.15절에서 본 `VariantKeyContext.eql` 은 `Type` 이 아닌 매개변수(`int`, `EvalInt`, `EvalStr`, 함수 시그니처, 함수 심볼, enum)를 비교하면 그 자리에서 `return` 하고 이후 매개변수를 보지 않는다(src/template.zig:189~224). 첫 const 정수가 같고 다음 매개변수만 다른 두 키가 해시 맵 슬롯의 지문(fingerprint) 비트까지 우연히 같으면 서로 같은 키로 취급된다(Zig std 해시 맵은 충돌 후보를 지문으로 거른 뒤에만 `eql` 을 부른다. 지문이 7비트라는 것은 일반 지식이다). 아래 생성기로 재현한다.

```
python3 - <<'EOF'
lines = ["type Buf[const A int, const N int]:", "    data [N]byte", "", "fn main():"]
for k in range(1, 60):
    lines.append(f"    print(type.size(Buf[1, {k}]))")
open("eql2.cy", "w").write("\n".join(lines) + "\n")
EOF
cyber eql2.cy | sed -n 45,48p
```

기대 출력은 `45 46 47 48` 인데 수정 전 실제 출력은 `45 46 45 48` 이었다(2026-11-08 수정 `1ec8d581`: 비-Type 매개변수가 다르면 false, 같으면 다음 매개변수를 본다. 테스트 `src/test/types/template_const_params.cy`). `Buf[1, 47]` 이 `Buf[1, 45]` 의 인스턴스(`data` 가 45바이트)로 조용히 대체되었다. 같은 방식으로 `N[1, k]` 600개를 만들면 13개가 앞선 인스턴스 이름으로 출력된다(예: `N[1, 47]` 대신 `N[1, 45]`). `Type` 매개변수는 같을 때 `return` 하지 않으므로, `[T Any, const N int]` 처럼 `Type` 이 앞이고 비-Type 이 마지막인 core 의 `Vector`, `PartialVector` 는 영향을 받지 않는다. 비-Type 매개변수 뒤에 매개변수가 더 오는 템플릿이 위험하다(사용자의 `const W int, const H int`, core 의 `HashMap[K, V, const HASH, const EQ]` 구조도 해당하지만 후자는 HASH/EQ 가 K 로 정해져 충돌 조합이 나오지 않는다. 이 마지막 문장은 코드 읽기에 기반한 추정이다).

(b) 지원되지 않는 const 매개변수가 컴파일러를 죽인다. `type Flag[const B bool]`(`Flag[true]`)는 "thread panic: Unsupported value hash: .bool 2", `type Tag[const S EvalStr]`(`Tag['a']`)는 "Unsupported: EvalStr", enum 값(`ByLvl[.high]`)은 "Unsupported: Lvl" 로 컴파일러가 패닉한다. 해시(`VariantKeyContext.hash`)와 이름 출력(`writeVariantParam`, src/sym.zig:1652~1678)이 지원하는 종류가 서로 달라서 생긴다. `const A int, const B int` 는 `N[1, 2]` 로 정상 출력된다. 2026-11-08 수정 `bb5d1a05`(F-28): 지원 종류를 `template.is_const_param_type` 하나로 정하고(정수 · `bool` · enum · `EvalStr` · 함수 심볼), 해시 · 비교에 `bool` 과 모든 폭의 정수를 넣고, 타입 · 함수 템플릿의 이름 출력을 `writeTemplateParam` 하나로 합쳤다(`Flag[true]` · `Tag['a']` · `ByLvl[Lvl.high]`). trace 없는 빌드에서 `EvalStr` 인자가 값 스택과 템플릿 컨텍스트에서 두 번 해제되던 것도 같이 고쳤다. 지원 밖 타입(`float`)은 매개변수 위치에 컴파일 오류. 테스트 `src/test/types/template_const_param_kinds.cy` · `template_const_param_type_error.cy`, 결정 문서 `docs/decisions/project_template_const_params.md`.

(c) `type X const:` 가 원래 타입의 이름을 바꾼다.

```
type IntBox:
    v int
type Pick[T Any] const:
    if T == int:
        return IntBox
    else:
        return str
fn main():
    var p Pick[int] = {v=1}
    print(type.name(type.of(p)))
    plain := IntBox{v=1}
    print(type.name(type.of(plain)))
```

출력은 `Pick[int]` 와 `Pick[int]` 다. 두 번째가 `IntBox` 여야 하지만 `resolve_type_const`(src/sema_type.zig:27~30)가 결과 타입의 심볼 이름과 부모, 인스턴스 정보를 별칭 쪽 값으로 덮어쓰기 때문에 `IntBox` 자체가 개명된다. `Pick[int]` 를 해석하기 전에 `IntBox` 를 출력하면 `IntBox` 이다(해석 순서에 따라 오류 메시지의 타입 이름이 달라진다). 또 `Pick[int]{v=5}` 처럼 init 식에서 쓰면 "CompileError: Unsupported: type_const" 이고, `var p Pick[int] = {v=5}` 형태로 써야 한다.

### 5.15 `-` 가시성은 어디까지 강제되는가

`mods/priv.cy` 에 `type Info: a int / -b int`, `-fn secret() -> int`, `type Visible = Info`, `-type Alias = Info` 를 선언하고 다른 파일에서 `use p 'mods/priv.cy'` 로 쓴다. 결과: `p.Info{a=1, b=2}.b` 는 `2`, `p.secret()` 은 `7` 이 접근된다. docs.md 의 "필드는 같은 모듈 안에서만 접근" 과 다르다. 유일하게 강제되는 곳은 `use * 'mods/priv.cy'` 로 가져올 때 `-type Alias` 가 빠지는 것이다("Undeclared variable `Alias`"). 이것도 `p.Alias{...}` 로 한정 접근하면 통과한다. `private` 메타데이터가 type_alias/type_const/use_alias/chunk 에만 설정되고(src/sym.zig:1330, 1369, 1382, 1394), 함수/필드/변수의 `hidden` 은 파서 값으로만 남기 때문이다(rg 로 `.hidden` 사용처 확인).

### 5.16 변형 과제

1. 5.14(a)의 생성기에서 `Buf[const A int, const N int]` 를 `Buf[T Any, const N int]` 로 바꿔(`Buf[int, k]`) 충돌이 사라지는지 확인한다. 왜 그런지 `VariantKeyContext.eql` 의 분기 순서로 설명해 본다.
2. 5.13 의 trait 버그를 고치는 한 줄 패치를 설계한다(`continue` 를 바깥 루프용 라벨로, 그리고 `trait_params.len != func_params.len` 검사 추가). 직접 `src/` 를 고치지 말고 fork 에 `docs/decisions` 문서부터 쓴다는 원칙(project_direction.md)에 따라 문서 초안만 작성한다.
3. `type Cell: a byte, b i32, c byte, d i64` 의 크기를 예측하고 `layout(Cell)` (5.8)로 확인한 뒤, 필드를 재배열해 최소 크기를 찾는다.
4. 사용자 파일에 `type Option[T Any]: v T` 를 선언해 `?int` 가 영향을 받는지 본다(core 의 `Option` 은 `loadBuiltinChunk` 가 이름으로 잡아 두었다: src/compiler.zig:889).
5. `Object(^1)` 의 `toString()` 후 프로그램이 "integer overflow" 로 끝나는 것(7절)의 최소 재현을 만들고 `Object.toString`(core.cy:691~716)의 `(as[^int] self.inner).*` 에서 참조 카운트가 어떻게 어긋나는지 가설을 세운다.
6. `ct` 플래그가 켜진 타입(`EvalStr`)을 필드로 가진 구조체를 만들어 `info.ct` 가 전파되고 런타임 사용이 막히는 모습을 본다(src/sema_type.zig:844~846, 924~926).

## 6. 0.3 -> 0.4 변경 관점 / 설계 철학 메모

출발점은 [docs/history/type_system.md](../history/type_system.md)이고, 아래 수치와 인용은 `git show` 로 다시 확인한 것이다.

### 6.1 같은 이름, 다른 물건

| 항목 | 0.3 (태그 `0.3`) | 0.4 (HEAD) | 확인 방법 |
|---|---|---|---|
| 변수 선언 | `my a = 123`(dynamic), `var a = 123`(static) | `a := 123` 정적 추론만 | `git show 0.3:docs/hugo/content/docs/toc/type-system.md` |
| Value | NaN 태깅 64비트, `int` 는 48비트 | 태그 없는 64비트 워드, `int` 는 64비트 | `0.3:src/vm.h` 의 `_BitInt(48)` / vm.h:119 `BITCAST(i64, v)` |
| 타입 표 항목 | `Type{sym, symType, data}` + 변수별 `CompactType{id u31, dynamic bool}` | `extern struct Type` + kind 31종 + `TypeInfo` 16비트 | `0.3:src/types.zig` 384줄 / 현재 1507줄 |
| 동적 호출 명령 | `CallObjSym`, `CallObjNativeFuncIC`, `CallObjFuncIC`, `FieldIC`, `SetFieldIC` 등 | 없음. `CALL`, `CALL_TRAIT`, 폭별 `LOAD_n`/`STORE_n` | `0.3:src/vm.h` 와 vm.h:150~300 |
| 사용자 타입 | `type X object` 하나(힙 객체) | struct(값), `^T`(힙), cstruct, enum, choice, trait | history 문서 구간 A |
| 없음 표현 | `none` 값 | `?T` | `427755b0` "Remove `none` value." |
| 오류 | throw/catch | `!T` | docs/history/error_handling.md |
| `src/sema.zig` | 4383줄 | 10594줄 | `git show 0.3:src/sema.zig \| wc -l` |

`dynamic` 은 TS 의 `any`(검사 건너뜀)에, 0.3 의 정적 `any` 는 TS 의 `unknown`(캐스트해야 사용)에 대응한다(일반 지식의 비유). 0.3 의 "Recent type inference" 는 `dynamic` 변수의 가장 최근 대입 타입을 추적해 확실한 실패만 컴파일 오류로 올리는 장치였고, TS 의 대입에 따른 좁히기(narrowing)와 닮았다.

### 6.2 전환 순서 (커밋으로 확인)

| 날짜 | 커밋 | 메시지 | 의미 |
|---|---|---|---|
| 2024-01-12 | 843471f5 | Remove `object` from `type` declaration. | `type X object` 의 `object` 가 사라짐 |
| 2024-01-29 | 9d4eb7e2 | Implement choice types aka tagged unions. | 합 타입 |
| 2024-02-11 | 516156af, 233f7c48 | optional types / Generics for object types using cte template expansion | Option 과 템플릿 |
| 2024-03-08 | 427755b0 | Remove `none` value. Rename to `void` type. | 값으로서의 none 제거 |
| 2024-07-10 | 94bade94 | `int` now 64 bits. Box/unbox `int`. | `int` 가 64비트가 되지만 아직 힙 박스(`struct Int {typeId, rc, val}`, 지금도 vm.h:471 에 남아 있음)이고 `VALUE_AS_INTEGER` 는 `_BitInt(48)` 그대로 |
| 2024-09-21 | cfe806d9 | ARC is the default memory model. ... | `VALUE_AS_INTEGER` 가 `BITCAST(i64, v)` 로 바뀜. 이 시점에 비로소 태그 없는 64비트 int (history 문서는 94bade94 쪽에 "unboxed" 로 적었지만 vm.h 기준으로는 이 커밋이다) |
| 2024-09-04 | 2e3ff392 | Remove recent type experiment for dynamic types. | 32개 파일, +400/-717 |
| 2024-09-20 | 35e84dd9 | Reference types are derived from value types. Remove object type. | `^T` 가 struct 에서 유도됨 |
| 2024-09-23 | e80054e9, c992b94e | Remove dynamic method dispatch / dynamic calls to overloaded functions | e80054e9 의 규모는 아래 문단 |
| 2025-11-21 | b751ca6c | [all] some updates | "Dynamic Typing" 장과 `dyn`, `any` 등 키워드 소멸, `Table` 타입은 소스에 남음 (444개 파일) |

e80054e9 가 순삭제 약 880줄(+411/-1289, 42개 파일)이라는 점이 중요하다. 동적 디스패치와 동적 오버로드 호출을 걷어내자 코드가 크게 줄었다. 반대로 `sema.zig` 는 4383줄에서 10594줄로 2.4배가 되었다. 무엇이 늘었는지 줄 단위로 분류하지는 않았다. 값 의미(소유권, 빌림, 복사), 템플릿, 컴파일타임 평가가 주된 증가분이라는 것은 파일 안의 함수들을 훑은 추정이다.

### 6.3 동적 타입 제거의 동기

c992b94e 시점의 docs.md 에는 아직 "Dynamic Typing" 장이 있었고 핵심 문장이 이것이다(`git show c992b94e:docs/docs.md`, 3322줄). `dyn` 에는 동적 메서드 디스패치와 동적 필드 접근을 허용하지 않는다. 그런 동작은 불필요한 런타임 비용을 더하고, 트리 쉐이킹(tree shaking)을 제한하며, 정적 타입과 서로 다른 메모리 의미론이 이끄는 언어에 복잡성을 더하기 때문이다(번역·요약). 메모리 모델과의 연결은 코드에서 이렇게 보인다.

- 해제 시점은 타입으로 정해진다. IR 의 `release` 는 `deinit_obj` 함수를 가진다(src/ir.zig:280, src/sema.zig:4691~4697). `getDeinitObjFunc` 가 타입마다 `@deinitObject[T]` 템플릿 인스턴스를 만든다(src/sema.zig:10000~10003). 값의 타입을 모르는 `dyn` 은 이 선택을 컴파일 시점에 할 수 없다.
- 지금도 타입 소거가 필요한 곳은 `Object` 와 `^Dyn[Trait]` 두 곳뿐이고, 거기서만 힙 객체 헤더의 타입 id 로 런타임에 소멸자를 찾는다(`@destructBox` -> `@getDeinitObject`, src/builtins/core.cy:2831~2833). 즉 동적 타입은 "필요한 만큼만" 명시적 비용을 내는 도구로 격하되었다.
- 값 소유권과 빌림(`^T`, `&T`)은 값의 크기와 수명을 컴파일러가 알아야 성립한다. history 문서의 해석("구간 A 끝의 동적 디스패치 제거는 구간 B 의 소유권 도입을 준비한 것")은 커밋 순서와 일치하지만, 작성자의 의도를 적은 문서는 없다. 추정이다.

### 6.4 표현과 성능에 준 영향

- 값이 자기 타입을 설명할 필요가 없어지자 NaN 태깅이 사라졌다. `VALUE_AS_INTEGER(v)` 는 `BITCAST(i64, v)` 일 뿐이다(src/vm.h:119). 이 형태는 2024-09-21 의 cfe806d9 에서 들어왔다. vm.h 에는 0.3 의 태그 매크로(`TAGGED_VALUE_MASK` 등)가 아직 남아 있다(죽은 정의, src/vm.h:32~75).
- 명령어가 타입별로 특화되었다: `ADD`/`FADD`/`FADD32`, `LT`/`ULT`/`FLT`, `LOAD_8..64`, `LOAD_2W..4W`. 인라인 캐시류(`FieldIC`, `CallObjFuncIC`)는 없다.
- 레이아웃과 복사/소멸 규칙의 계산이 런타임에서 컴파일러로 이동했다. 그 대가가 `sema_type.zig`/`types.zig` 의 코드량과 2절의 규칙들이다.
- 성능이 얼마나 좋아졌는지는 이 장에서 측정하지 않았다(미확인). upstream 벤치마크(src/test/bench)로 확인해야 한다.

### 6.5 TS 개발자 관점의 득실

득: 타입 오류가 실행 전에 문자열 인자 하나 단위로 걸리고(5.12), 크기와 복사 비용이 코드에 보인다. 에이전트 루프에서 모델이 생성한 코드가 틀리면 그 오류 메시지가 곧바로 다음 프롬프트의 근거가 된다(이 용도 판단은 추정). 실패가 늦게 나오는 `undefined is not a function` 류가 없다.
실: (1) JSON 처럼 구조가 열린 데이터를 담을 범용 동적 컨테이너가 없다(`Table` 은 테스트까지 꺼진 상태, 7절이고 src/std 에는 cli, io, libc, math, os, test 모듈뿐이다). (2) 구조적 타이핑이 없어 같은 모양의 타입끼리 변환 코드를 써야 한다. (3) 제네릭이 인스턴스마다 코드를 만들어 코드 크기가 커진다. (4) 템플릿 오류가 사용 시점에만 나타난다(5.3). (5) 오류 메시지가 TS 만큼 친절하지 않다(5.12). (6) 가장 현실적인 위험은 5.13~5.14 처럼 타입 검사기의 구멍이 곧 메모리 오류로 이어진다는 점이다. TS 에서는 타입 검사가 틀려도 JS 가 어떻게든 돈다.

### 6.6 이름이 자주 바뀐 이력의 교훈

history 문서의 표대로 `my -> let -> dyn`, `import -> use`, `func -> fn`, `object -> struct`, `metatype -> type`, `string -> str` 이 모두 2024년 한 해 안에 있었다. 설계가 흔들렸다는 신호이지만, 반대로 `fn`/`use`/`struct` 같은 최종 이름은 비교적 안정적이다. fork 가 문법을 바꿀 때는 `docs/decisions` 에 먼저 적는다는 원칙(docs/decisions/project_direction.md)이 이 교훈의 구체적 형태다.

### 6.7 fork 유지보수 시사점

타입 시스템에서 다음에 손댈 가치가 높은 순서는 (1) 5.13 의 trait 검사(안전성, 수정이 작음. 2026-11-08 수정), (2) 5.14(a) 의 `eql` 조기 return(안전성, 수정 한 군데. 2026-11-08 수정), (3) 5.14(b) 해시와 이름 출력의 지원 종류 일치(2026-11-08 수정), (4) 5.15 가시성을 강제하거나 문서를 고치기(임베딩 환경에서 샌드박스 경계로 쓰려 한다면 지금은 쓸 수 없다), (5) 7절의 죽은 코드 정리다. 모두 `src/test/types/*_error.cy` 형식의 `--cytest: error` 테스트로 먼저 고정하면 회귀를 막을 수 있다(src/behavior_test.zig:182~239 에 등록하는 방식). 템플릿 코드는 인스턴스를 만들어 호출하는 테스트가 있어야 오류가 드러나므로, 새 core 템플릿에는 대표 인스턴스 호출 테스트를 같이 둔다.

## 7. 알려진 이슈, 문서와 코드의 차이, 미완 지점

실행으로 재현한 것.

1. trait 구현 검사가 파라미터 타입과 개수를 검사하지 않았다 (src/types.zig:625~640, 5.13). 타입이 다른 메서드를 통과시키고 파라미터가 적으면 컴파일러가 `index out of bounds` 로 죽었다. 2026-11-08 수정 `40bfa711`(F-22).
2. 템플릿 캐시 `VariantKeyContext.eql` 이 비-Type 매개변수에서 조기 return 했다 (src/template.zig:189~224, 5.14a). `Buf[1, 47]` 이 `Buf[1, 45]` 로 바뀌었다. 함수 템플릿 캐시도 같은 문맥을 쓴다(:481). 2026-11-08 수정 `1ec8d581`(F-23).
3. `const` 매개변수로 `bool`, `EvalStr`, enum 을 쓰는 타입 템플릿이 컴파일러 패닉을 냈다 (5.14b; 해시는 bool 만, 이름 출력은 EvalStr/enum 을 지원하지 않음). 2026-11-08 수정 `bb5d1a05`(F-28).
4. `type X const:` 가 결과 타입의 이름을 덮어쓴다 (src/sema_type.zig:27~30, 5.14c). init 식 `Pick[int]{...}` 은 "Unsupported: type_const".
5. `-` 가시성은 파서만 인식하고 함수, 필드, 변수에서는 강제되지 않는다 (5.15). docs.md 의 "Field visibility." 와 다르다.
6. 파라미터가 같고 반환만 다른 오버로드가 거부되지 않고 첫 번째 선언이 호출됐다 (5.7). 2026-11-08 수정 `cf4aa84a`(F-21).
7. `Object.toString()` 을 호출하면 프로그램 종료 시 "integer overflow" 패닉이 난다. 최소 재현은 `a := Object(^'s')` / `print(a.toString())` / `print('end')` 이고 `end` 출력 뒤에 패닉한다(`Object(^5)` 도 동일, `downcast` 는 정상). 원인은 `(as[^str] self.inner).*` 가 retain 없이 만든 `^` 값이 소멸되며 참조 카운트가 어긋나는 것으로 추정한다. 확인하지 않았다.
8. `fn show(x Any)` 가 호출 시 "Expected type `Any`. Found `int`." 로 실패한다. docs.md 의 Generic types 절은 `Any` 가 "template parameters and generic function parameters" 에서 쓰인다고 한다. trait 나 `Copyable` 을 매개변수 타입으로 쓰는 함수는 정상적으로 제네릭이 된다.
9. 템플릿 제약 위반 메시지가 "Expected type `Showable`. Found `type`." 이다.
10. 구조체 패딩 바이트가 초기화되지 않는다 (5.10). 바이트 단위 비교나 해싱에 구조체 전체를 쓰는 코드가 있으면 위험하다 (그런 코드를 찾는 작업은 하지 않았다).

문서와 코드의 차이.

- docs.md Implicit casts 표의 `^T -> Object` 는 코드에서 주석 처리되어 있고 동작하지 않는다 (5.12).
- docs.md 는 Type embedding 을 "Planned Feature" 로 적지만 동작하고 테스트도 있다 (src/test/types/type_embedding.cy, 5.13).
- `src/test/core/table.cy` 는 `var o = {}` 가 파싱되지 않는 옛 문법이고, src/behavior_test.zig:357~358 에서 주석 처리되어 있다. `Table` 타입(core.cy:2042, 내장 id 31)은 소스에 남아 있다.
- 오류 메시지 일부가 옛 속성 이름 `@host` 를 말한다 (src/sema_type.zig:43, 264).
- core.cy 의 `dump(x)` 는 구조체의 기본형 필드를 값이 아니라 타입 이름으로 찍는다 (5.8).

죽은 코드. Zig 는 참조되지 않는 함수 본문을 분석하지 않으므로(일반 지식) 존재하지 않는 이름을 쓰는 코드가 빌드를 통과한다. 읽다가 헷갈리지 않도록 rg 로 확인한 항목만 적는다.

| 위치 | 내용 |
|---|---|
| src/module.zig:43~52, 152~157, 378~406 | `Module.dump`(없는 필드), `reserveHostObjectType`(없는 `HostObjectType`), `reserveTemplateFunc`(없는 `FuncKind.template`) |
| src/chunk.zig:805 | `reserveDistinctType` 별칭 (module.zig 에 없음) |
| src/types.zig:316~318, 1314, 1405~1508 | `is_min_resolved`(없는 `shallow_resolved`), `createTypeCopy` 의 `info.distinct`, `isAnyOrDynamic` 등 0.3 잔재 |
| src/sema.zig:2000, 5153 | `semaAccessChoicePayload`(호출 없음), `checkTypeCstr2`(없는 `bt.Dyn`) |
| src/compiler.zig:560~571 | `resolveCopyCtor`/`resolveFuncTemplate`(없는 `cy.generics`). 2026-11-06 삭제(F-61) |
| src/sym.zig | `SymType.ct_value`, `module_alias` 는 생성 지점이 없음 |
| src/types.zig `TypeKind.bare` | 어디서도 만들지 않고 bc_gen 에서 만나면 `error.Unexpected` |

미확인으로 남긴 것: 처음 관찰된 `-9223372036854775806` 값을 만든 정확한 경로(5.11), 7번 항목의 원인, `Func` 유니온과 클로저의 타입 쪽 세부, `ExBorrow`/`Ex[T]` 런타임 빌림 검사의 타입 규칙, 제너릭 함수(`%T`)의 인자 추론 상세(Day 3), 성능 수치.

## 8. 이해도 확인 Q&A

### Q1. `reserveChunkSyms` 를 건너뛰고 `resolveChunkSyms` 안에서 선언을 만나는 대로 심볼을 만들면 어떤 프로그램이 깨지나?

A: 5.5 의 두 프로그램이 깨진다. `main` 이 `A`, `later`, `K` 보다 먼저 나오는 파일과, `A` 가 `?^B` 를, `B` 가 `?^A` 를 참조하는 순환 타입이다. 선언을 만나는 순서대로 해석하면 아직 만나지 않은 이름을 조회하게 된다. 예약은 "이름이 있다" 는 사실만 먼저 확정해서 해석 순서와 선언 순서를 분리한다. 값 순환(`a A` / `b B`)은 예약 덕분에 "존재하지만 해석 중" 상태를 감지할 수 있어서 `resolving_struct` 플래그로 거부된다.

### Q2. `Box[int]` 를 파일 곳곳에서 100번 써도 `resolve type: Box[int]` 는 한 번만 나온다. 이 사실이 타입 호환 판정에 어떤 의미를 갖나?

A: 인스턴스가 (템플릿, 매개변수 값) 키로 캐시되어 항상 같은 `Type*` 이므로 호환 판정(`target_t == res.type`)이 포인터 비교만으로 충분하다. 반대로 구조체끼리는 선언이 하나씩이므로 필드가 같아도 다른 타입이다. 캐시 키 비교가 틀리면(5.14a) 이 전제가 깨져 조용히 다른 타입이 섞인다. 즉 `eql` 은 타입 시스템의 건전성(soundness) 일부다.

### Q3. `?^P` 는 8바이트이고 `?int` 는 16바이트다. `?int` 가 8바이트가 될 수 없는 이유를 값의 표현에서 설명하라.

A: `^P` 는 유효한 포인터가 0 이 될 수 없으므로 0 을 none 으로 써도 정보 손실이 없다. `int` 는 64비트 전체가 유효한 값이라서 none 을 나타낼 비트 패턴이 남지 않는다. 그래서 태그 슬롯이 따로 필요하고 8바이트 정렬 때문에 16바이트가 된다(`?byte` 도 16). 이 선택은 `createOptionType` 한 줄(자식 kind 가 pointer, func_ptr, eval_ref)이 정한다. 0.3 의 NaN 태깅 값은 태그 비트가 값 안에 있어서 이런 구분이 필요 없었다.

### Q4. 템플릿 메서드 본문의 타입 오류는 사용 전에는 보이지 않는다. 팀이 코어 라이브러리를 템플릿으로 작성할 때 어떻게 대응해야 하나?

A: 템플릿 메서드는 처음 접근할 때만 해석된다(5.3). 따라서 모든 템플릿에는 대표 인스턴스를 만들고 모든 메서드를 호출하는 테스트가 필요하다. 인스턴스마다 `T` 의 속성(managed, copyable)이 달라 분기하는 경우(`#if type.managed(T)`)는 managed 와 아닌 타입 둘 다로 테스트해야 한다. 템플릿 선언만 있고 호출이 없는 코드는 컴파일 오류로 나타나지 않는다는 점을 CI 가 가정해야 한다.

### Q5. 필드가 똑같은 두 구조체 `A`, `B` 가 호환되지 않는 것이 에이전트 루프의 코드 생성에서 의미하는 바는?

A: 모델이 생성한 코드에서 타입 이름을 틀리면 TS 였다면 통과했을 구조적 호환이 여기서는 컴파일 오류가 된다. 오류 메시지가 두 타입 이름과 호출된 함수 시그니처를 모두 보여 주므로(5.12) 피드백으로는 쓸 만하다. 반면 변환 함수를 직접 써야 해서 생성 코드가 길어진다. 어느 쪽이 실패율을 낮추는지는 이 장에서 측정하지 않았다(추정 불가).

### Q6. `get_trait_method_impl` 의 버그를 한 문장으로 설명하고, 그 버그가 `Dyn` 호출에서 어떤 증상으로 나타나는지 말하라.

A: 안쪽 `for` 의 `continue` 가 바깥 `while` 이 아니라 `for` 자신에 걸려서 파라미터 타입 불일치가 무시되고, 반환 타입만 같으면 구현으로 채택했다(길이 검사도 없음. 2026-11-08 `40bfa711` 로 개수 · 타입 · 반환을 모두 비교하도록 고침). `Dyn` 을 통해 호출하면 호출자는 trait 시그니처 대로 인자를 쌓고 피호출자는 자기 시그니처로 읽기 때문에, `float` 비트를 `int` 로 읽는 식의 조용한 오동작이 난다(5.13: `2.0` 이 `4611686018427388000` 이 됨).

### Q7. 구조체 `{byte, int, byte}` 는 24바이트인데 `{int, byte, byte}` 는 16바이트다. 필드 순서를 바꾸는 것을 컴파일러가 자동으로 하지 않는 이유를 이 언어의 용도에서 추정해 보라.

A: 필드 순서가 `cstruct` 와 FFI 의 C ABI 레이아웃과 같아야 하고(코드 주석 "Alignment follows C-ABI rules."), `type.field(T, name).offset` 같은 메타 API 가 오프셋을 노출하기 때문에 결정적인 선언 순서 레이아웃이 단순하고 안전하다. 같은 함수가 `struct` 와 `cstruct` 를 모두 처리한다는 점이 증거다(src/sema_type.zig:791). 다만 저자가 이유를 적은 문서는 없으므로 이 답은 추정이다.

### Q8. 0.3 의 `dynamic` 과 0.4 의 `Object` 는 어떤 점이 같고 무엇이 근본적으로 다른가?

A: 둘 다 "정적 타입을 모르는 값을 담는 그릇" 이다. 다른 점은 비용과 안전의 위치다. `dynamic` 은 모든 연산이 런타임 타입 검사를 했고 변수 선언만으로 쓰였다. `Object` 는 `Object(^x)` 로 힙 값을 명시적으로 감싸고, 쓸 때도 `downcast(^T)` 로 타입을 선언해야 하며 틀리면 "Downcast expected `^float` typeid=13, found typeid=6." 패닉이다. 메서드 호출과 필드 접근은 되지 않는다. 동적 디스패치가 필요하면 `Dyn[Trait]` 를 써야 한다. 즉 "암묵적이고 전염되는 동적성" 이 "명시적이고 국소적인 동적성" 으로 바뀌었다.

## 9. 더 알아보기

- 키워드: hash-consing, nominal vs structural typing, monomorphization, binder/checker, tagged union, null pointer optimization(zero_union), C ABI 구조체 레이아웃, fat pointer.
- 이어서: [Day 3](03-sema-and-ir.md)는 이 장에서 만든 심볼과 타입을 써서 함수 본문을 검사하고 IR 로 내린다(`semaFitTarget` 호출 경로, 제네릭 함수 인자 추론, 컴파일타임 평가). [Day 4](04-bytecode-gen.md)는 `reg_size` 와 `Trait` 명령, 호출 규약을 다룬다. [Day 6](06-memory-ownership.md)은 managed/copy 플래그가 소유권 코드로 이어지는 부분이다. 제너레이터의 타입(`Generator[fn() -> int]`)은 [Day 7](07-coroutines-concurrency.md), `#[bind]` 호스트 타입과 `types` 표는 [Day 8 임베딩과 테스트](08-embedding-builtins-tests.md)에서 다시 만난다.
- 용어는 [00-glossary.md](00-glossary.md) 참고.
- 읽을거리: docs/docs.md 의 Type templates, Traits, Type evaluation 절, docs/history/type_system.md, docs/decisions/project_direction.md.

