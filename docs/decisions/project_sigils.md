# `#` · `@` 표기의 경계

2026-11-11 결정 · 구현.

## 배경

`#`과 `@` 두 접두 기호에 여러 뜻이 겹쳐 있었고, 일반 스크립트용과 builtin 모듈 작성용이 같은 표기에 섞여 있는데 컴파일러가
경계를 검사하지 않았다. 사용자가 "cy 파일을 쓸 때 쓰는 것인지 컴파일러를 설계할 때 쓰는 것인지 구분이 안 간다"고 했다.

`#`의 세 갈래(`src/parser.zig`의 `.pound` 처리).

- `#[name]` · `#[name=value]`: attribute. 이름은 파서의 고정 목록이다.
- `#{expr}`: 컴파일 타임 표현식.
- `#<문>`: 컴파일 타임 문(`#if` · `#for` · `#switch` · `#x :=` · `#expr`).

`@`는 문법이 아니라 식별자 접두사다(토큰 `at_ident` 하나). 네 가지로 쓰였다.

1. hook: 스크립트가 선언하고 컴파일러가 이름으로 부른다(`@init` · `@deinit` 등).
2. intrinsic: builtin 모듈이 선언하고 주로 builtin 모듈이 부른다(`@memcpy` · `@bitCast` 등 약 65개).
3. 컴파일러 내부 심볼(`@program_init` · `@mainResult` 등).
4. symbol 리터럴(`@usd`). 선언 없이 쓰는 값이라 나머지와 성격이 반대였다.

변경 전에는 스크립트에서 `fn (&Foo) @whatever()` 선언과 호출, `@bitCast(float, 1)`, `#[consteval]` · `#[unsafe]`가 모두 통과했다.

## 결정

1. `@`는 "컴파일러가 아는 이름"만 가리킨다. symbol 리터럴은 `symbol.name`으로 옮긴다. `error.Name`과 같은 꼴이고 새 기호가
   필요 없다. 후보 `$usd`는 기호가 하나 느는 것, `@usd` 유지는 "호출이 아니면 symbol"이라는 규칙이 남는 것 때문에 택하지 않았다.
2. 스크립트가 선언할 수 있는 `@` 함수는 hook 13개로 닫는다. 그 밖의 이름은 컴파일 오류다. `@size`는 `@freeObject`에 넘기는
   할당 크기라 hook에서 뺐다.
3. `#[unsafe]` · `#[consteval]` · `#[reserve]`는 builtin 모듈 전용이다. `#[bind]` · `#[extern]` · `#[inline]` · `#[cond]`는 그대로 연다.
4. `#[consteval]`은 `comptime` 키워드로 바꾸지 않는다. Zig의 `comptime`은 매개변수 · 표현식 · 블록에 붙는 것이라 대응이 아니고,
   컴파일 타임 어휘는 이미 `#`과 `const` 둘이다. 쓰는 곳도 builtin 3곳뿐이다.
5. 스크립트는 intrinsic을 쓸 수 없다(호출도, 값으로 참조도). 사용자가 "사용자 환경에서 호출하는 장점이 있나, Zig 계층을
   노출하는 것 아닌가"를 물었고, 답은 "거의 없다, 맞다"였다. 대부분 참조 카운트 · 객체 레이아웃 · VM 명령에 직접 닿아 스크립트가
   부르면 메모리 안전성이 깨지고 내부를 바꿀 때마다 호환성 문제가 된다. 공개 목록(`@bitCast` · `@unsafeCast` · `@memcpy` ·
   `@consume`)을 두는 안은 택하지 않았다. 필요한 기능은 표준 모듈의 일반 이름으로 제공한다(사용자 결정).
   변경 전 스크립트 쪽 사용은 테스트의 `@bitCast` 2곳 · `@unsafeCast` 2곳, `tokenizer.cy`의 `@enumToInt` · `@intToEnum` 3곳,
   문서 예제의 `@memcpy` · `@consume`이었다.

## 구현

- builtin 판별: `Chunk.is_builtin`. `core.markBuiltinModule(mod)`를 `core` · `meta` · `cy` · `c` · `math` · `io` · `test`의 bind 함수가
  부른다. URI로 판별하지 않는 이유는 CLI가 builtin 소스를 실행 파일 옆의 파일 경로로 읽기 때문이다
  (`is_std_module_uri`는 라이브러리의 기본 로더에서만 맞는다). `os` · `cli` · `libc`는 표시하지 않았고 지금은 필요도 없다.
- hook · attribute 검사: `sema.zig`의 함수 선언 해석(attribute 루프 앞), `isBuiltinModuleNode` · `hook_names`.
- symbol: `semaAccessExpr2`와 `cte.zig`의 `.accessExpr`에서 왼쪽이 `symbol` 타입 심볼이면 리터럴로 만든다. 파서가 아니라
  sema에서 하므로 `symbol`이라는 지역 변수가 타입을 가려도 된다. 풀리지 않는 `@name`은 `reportOldSymbolLit`이 대체 표기를 알려 준다.
  `core.cy`의 symbol 출력(`'@' + name`) 두 곳을 `'symbol.' + name`으로, `@borrowed` 등 9곳을 새 표기로 바꿨다.
- 테스트: `functions/call_at_ct_error.cy`(스크립트의 `#[consteval]`)는 `functions/consteval_attr_error.cy`로 바꿨다. 새 오류 테스트
  `functions/unknown_hook_error.cy` · `core/symbol_at_lit_error.cy`. 런타임 인자로 consteval 함수를 부르는 경우의 오류는 이제
  스크립트에서 만들 수 없어 테스트가 없다.
- intrinsic 검사: `sema.checkIntrinsicUse`. `@name`이 정적 심볼로 풀리는 세 곳(호출 `semaCallExpr`, 값 `semaExprSkipSym` ·
  `semaExprNoCheck`, 컴파일 타임 호출 `cte.zig`)에서 노드의 청크가 builtin이 아니면 오류다. builtin 템플릿을 스크립트에서
  펼친 경우는 노드가 builtin 청크의 것이라 통과한다. 컴파일러가 스크립트 AST에 넣는 호출(`fiber f()` → `@new_fiber`)은
  `Chunk.internal_callee`로 그 노드 하나만 통과시킨다. 메서드 꼴의 hook 호출(`a.@deinit()`, `T.@init(...)`)은 검사하지 않는다.
- 공개 API: `c.memcpy`(c.cy, `@memcpy` 호출), `meta.consume`(core의 `consume` builtin을 meta.zig에서 한 번 더 바인딩),
  `meta.enum_from_int`(meta.cy, `@intToEnumResult` 호출). `math.cy`의 `@bitCast` 14곳은 builtin이라 그대로다.
- 테스트 정리: intrinsic 자체를 스크립트로 시험하던 `types/bitcast.cy` · `functions/func_sym_unsafe_cast_error.cy`(F-94의
  `@unsafeCast(f, 1)` abort 회귀 테스트)는 지웠다. 그 입력은 이제 스크립트에서 만들 수 없다. `types/pointers.cy`는
  `as[Ptr[int]] ref`로, `tokenizer.cy`는 `int(x)` · `meta.enum_from_int`로 바꿨다. 새 테스트 `functions/intrinsic_call_error.cy` ·
  `meta/script_api.cy`.
- tree-sitter는 바꾸지 않았다. `symbol.usd`는 `member_expression`으로 읽힌다.

## 교훈

- `@name`은 호출이 아니면 symbol이라는 옛 규칙 때문에 core 안에서 `@` 이름의 함수를 값으로 넘길 수 없었다
  (`fiber_block_entry`를 `-fn`으로 둔 이유). 이제는 풀리지 않을 때만 오류다.
- 검색 정규식이 소문자로 시작하는 이름만 잡아 `@Oops` · `@Tiger`를 놓쳤다. 대소문자를 모두 본다.
