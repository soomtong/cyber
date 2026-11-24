# 세션의 뒤 입력이 앞 입력의 타입에 메서드를 선언한다 (2026-11-24, F-199 · F-202)

## 배경

`persist_main` 세션(CLI의 REPL, `cy.VM`, 여러 소스를 한 세션에 eval하는 임베딩 호스트)에서 앞 입력이 선언한 타입에 뒤 입력이
메서드나 타입 함수를 선언하면 호스트 프로세스가 죽었다(F-199).

~~~text
> type V:
    |     x float
    |
> fn (&V) twice() -> float:
    |     return self.x * 2
    |
thread 599 panic: attempt to use null value
src/module.zig:379:32: in reserveFunc
    const mod = parent.getMod().?;
~~~

REPL은 빈 줄이 입력을 끝내므로 타입과 메서드를 빈 줄로 나누면 한 입력에 넣을 수 없다. 그래서 흔한 쓰임에서 REPL에 메서드를 선언할
길이 없었다.

원인은 둘이다.

1. 세션의 새 main 청크는 앞 eval의 최상위 심볼을 선언 없는 `use` 별칭으로 본다(`Compiler.compileInner`). 선언의 부모를 찾는
   `sema_resolve.ensureDeclNamePath`는 청크의 모듈에서 찾은 심볼을 그대로 돌려주었고, 별칭에는 모듈이 없다.
2. 같은 자리가 한 소스에서도 죽었다. 부모가 함수 · 전역 · 상수(`fn foo :: bar()`, `fn (&g) bar()`)이거나 다른 모듈 타입의 `use`
   별칭(`use V = m.V` 뒤 `fn (&V) twice()`)이면 같은 panic이었다. 세션만의 결함이 아니라 "모듈이 없는 부모"의 검사가 없었다.

## 결정 (사용자, 2026-11-24)

사용자의 목표: "a method or type function declared in a later input of the same session works like one declared in the same
source, for struct types at least. If some case can not be supported, it must be a compile error with a clear message, never a
panic of the host."

목표는 사용자의 것이다. 아래 규칙의 세부는 그 목표 안에서 구현하며 정했고 사용자의 확인 전이다. 갈림길이 있던 곳은 둘이다:
규칙 3의 같은 시그니처(오류로 할지 교체할지)와 규칙 5의 `@` 메서드 넷(거절). 규칙 1은 매뉴얼이 이미 적은 것을 구현이 따르게 한
것이다.

### 규칙 1. 세션의 main 청크들은 한 모듈이다

매뉴얼은 전부터 '`persist_main` 세션은 한 모듈로 친다'고 적었다. 구현은 "같은 `srcUri`의 청크"로 판정했는데(F-30),
`cl_vm_validate`는 `main`으로, `.which`는 `which`로 컴파일하므로 세션의 uri가 다르면 한 모듈이 아니었다. 그래서 eval이 받는
소스를 validate가 거절했다: 앞 입력 타입의 `-` 필드를 읽으면 'Can not access the private field'(F-202).

판정을 `module.sameModule`로 모았다. 같은 청크, 같은 uri, 또는 둘 다 `persist_main` 컴파일의 main 청크(`Chunk.session_main`)면
한 모듈이다. `-` 심볼의 가시성과 아래 규칙 2가 같은 판정을 쓴다.

### 규칙 2. 뒤 입력은 세션이 선언한 타입에 멤버를 선언한다

앞 입력이 선언한 타입과 타입 템플릿은 뒤 입력의 선언을 받는다. 같은 소스에서 선언한 것과 같게 동작한다.

| 선언 | 예 |
| --- | --- |
| 메서드 | `fn (&V) twice() -> float:` |
| 타입 함수 | `fn V :: make() -> V:` |
| 타입의 상수 · 함수 템플릿 | `const V :: K = 7`, `fn V :: gen[T Any](x T) -> T:` |
| 템플릿 타입의 멤버 | `fn (&Box[]) get() -> T:`, `fn Box[] :: make(v T) -> Box[T]:` |

struct만이 아니라 enum · choice 타입도 같은 길이다. 선언은 타입의 모듈에 들어가므로 그 타입의 값을 쓰는 모든 자리에서 보인다.
본문의 이름은 선언한 입력의 눈으로 푼다(그 입력과 그 뒤에 선언한 함수를 부를 수 있다).

### 규칙 3. 오버로드는 더하고, 같은 시그니처는 오류다

- 매개변수 타입이 다른 같은 이름은 오버로드로 더한다. 앞 입력의 `twice()`와 뒤 입력의 `twice(n int)`가 함께 있다.
- 같은 시그니처는 한 소스에서와 같은 오류다: '`twice` has already been declared with the same function signature.' 반환 타입만
  다른 것도 한 소스에서와 같다. 그 입력은 실패하고 아무것도 남기지 않는다.
- trait이 준 기본 메서드와 같은 시그니처도 같은 오류다. 한 소스에서는 타입의 메서드가 기본 메서드를 대신하지만, 뒤 입력에서는
  vtable이 이미 기본 메서드로 채워져 있다.

최상위 함수는 뒤 입력이 같은 이름을 선언하면 앞의 것을 가린다(`module.isCarriedOverSym`). 메서드는 가리지 않기로 했다.

| 안 | 내용 | 판단 |
| --- | --- | --- |
| A. 오류 (채택) | 같은 시그니처는 한 소스처럼 오류 | 목표("같은 소스처럼")와 같다. 이미 컴파일된 코드와 새 코드가 같은 메서드를 본다 |
| B. 교체 | 뒤 선언이 앞 메서드를 대신한다 | Julia · Common Lisp(`defmethod`) · Ruby의 REPL이 이렇다. 정적 바인딩인 Cyber에서는 앞서 컴파일된 호출 · 템플릿 인스턴스 · vtable이 옛 본문을 계속 부른다. Julia는 world age로 이 차이를 정의하지만 Cyber에는 그런 장치가 없다 |

B의 수요(메서드 본문을 고쳐 다시 넣기)는 타입을 다시 선언하는 길로 받는다: 새 타입이 옛 타입을 가리고, 메서드를 다시 선언한다.
옛 타입의 값은 옛 메서드를 갖고 있다. Swift의 REPL · GHCi가 같은 쪽이다(재선언은 오류이거나 새 선언이 옛 타입을 가린다).

### 규칙 4. 템플릿 타입의 인스턴스

템플릿 메서드는 인스턴스가 이름을 처음 찾을 때 전개된다(`module.getResolvedSym2`). 뒤 입력이 더한 새 이름은 그 길로 기존
인스턴스에도 생긴다. 이미 전개한 이름에 오버로드를 더하는 경우가 남는다: `Box[int]`가 `get`을 전개한 뒤 `fn (&Box[]) get(add T)`
가 오면 `Box[int]`에는 없고 새 인스턴스에만 있게 된다. 인스턴스의 함수 심볼이 템플릿 선언을 몇 개 전개했는지 세고
(`FuncSym.variant_decls`), 모자라면 조회 때 나머지를 전개한다. 그 선언을 한 입력은 심볼 해석 뒤에 이미 전개한 인스턴스들에 바로
더한다(`Compiler.expandLateVariants`). 그래서 같은 시그니처의 중복은 선언한 입력의 오류가 된다.

### 규칙 5. 받지 않는 선언은 컴파일 오류다

| 경우 | 문구 |
| --- | --- |
| `@deinit` · `@copy` · `@clone` · `@send` | 'Can not declare `@deinit` for `V` after the input that declares `V`. The code that the session compiled since then destroys, copies and sends a `V` without it. Declare the type again, together with `@deinit`.' |
| 다른 모듈의 타입(`use` 별칭, 모듈) | 'Can not declare `twice` for `V`: `V` belongs to another module. A method or a member of a type is declared in the module that declares the type.' |
| 타입이 아닌 부모(함수 · 전역 · 상수) | 'Can not declare `bar` for `foo`: `foo` is not a type. A method `fn (&T) name()` or a member `fn T :: name()` is declared for a type of this module.' |
| 타입 별칭 | 전과 같다: 'Cannot declare from type alias.' |

네 `@` 메서드는 타입 해석이 읽거나(`@deinit` · `@copy`: `managed` · `copy_user`) core의 템플릿이 인스턴스마다 한 번 묻는다
(`@clone` · `@send`: `meta.has_decl`). 앞서 컴파일된 코드는 그것 없이 값을 없애고 복사하고 보낸다. 뒤에 더하면 같은 타입의 값이
자리마다 다르게 다뤄진다. 나머지 `@` 메서드(`@init`, `@index`, `@get` 등)는 부르는 자리에서 찾으므로 받는다.

뒤의 두 줄은 한 소스에서도 같다. 전에는 둘 다 panic이었다.

네 `@` 메서드의 문구는 "타입을 다시, 그것과 함께 선언하라"고 한다. 임베딩 호스트와 `cy.VM`은 한 소스에 타입과 메서드를 함께
넣으면 된다. CLI의 REPL은 타입 블록이 한 입력이라(빈 줄로 들여쓰기를 되돌리면 입력이 끝난다) 이 넷을 선언할 길이 없다. REPL의
입력 규칙을 바꾸는 일(블록 뒤에 선언을 이어 받기)은 이번 범위가 아니다.

### 규칙 6. 실패하거나 버려진 컴파일은 아무것도 남기지 않는다

뒤 입력의 선언은 살아남는 청크의 모듈(타입의 모듈)에 들어간다. main 청크의 심볼처럼 "다음 main이 물려받지 않으면 끝"이 아니다.

- 컴파일이 실패하면 그 선언을 타입의 모듈에서 뺀다(`Compiler.dropLateDecls` → `module.dropDeclsFrom`). 템플릿이면 인스턴스가
  그 선언에서 전개한 것도 뺀다. 기준은 선언 노드의 청크다(`decl.src() >= chunk_start`).
- `cl_vm_validate`(`.which`)는 성공한 컴파일을 버린다. 선언을 빼고, 그 컴파일이 살아남는 템플릿에서 전개한 본문 중 버려지는
  선언에 닿는 것도 버린다(`Compiler.discardLateDecls`). `fn dbl(x %T): x.twice()`의 `dbl[V]`가 버려진 `twice`를 부르는 코드로
  캐시에 남기 때문이다. 코드가 이미 생성돼 실패한 컴파일의 본문처럼 다시 검사할 수 없다(`bc_gen.genFuncBlock`은 함수를 한 번만
  생성한다).
  - 닿는지는 그 컴파일이 기록한 참조로 본다(`Compiler.late_refs`: `sema_call.checkCallee`가 호출과 함수 값을 적는다. 람다는
    그것을 담은 본문에도 적는다). 버려지는 선언에서 거꾸로 따라가 닿는 본문을 표시한다(`FuncInfo.late_taint`).
  - 함수 템플릿의 인스턴스는 `failed`로 표시해 다음 사용이 다시 전개하고, 타입 인스턴스의 메서드는 이름을 지워 다음 조회가
    다시 전개한다.
  - 그 컴파일이 전개한 것을 통째로 버리지 않는 까닭: 타입이 갖고 있는 소멸 · 복사 함수(`Type.dtor` · `copy_ctor`)도 템플릿
    인스턴스다. 그것을 `failed`로 만들면 뒤의 컴파일이 그 타입을 없앨 때 '... because of an earlier error'가 된다. 이 함수들은
    뒤 입력의 선언에 닿지 않는다(규칙 5가 `@deinit` · `@copy`를 막는다).
  - 실패한 컴파일은 이 일이 필요 없다: 살아남는 본문을 다음 컴파일이 처음부터 다시 검사한다(`carry_funcs`).

## 구현

- `src/sema_resolve.zig` `ensureDeclNamePath` · `lateDeclParent`: 별칭을 세션의 타입으로 풀고 위 규칙을 검사한다. 푼 부모는
  `Compiler.late_parents`에 적는다. 함수 · 함수 템플릿 · 상수 · 템플릿 멤버의 예약이 모두 이 함수를 지난다.
- `src/module.zig`: `sameModule`, `dropDeclsFrom`(함수 심볼의 오버로드 목록 · `overloadedFuncMap` · `overloadedParamsMap`에서
  빼기), `expandVariantFuncs`(지연 전개를 함수로), `expandLateOverloads`, `clampVariantDecls`.
  `resolveFunc`는 혼자 해석된 첫 함수를 오버로드 표에 뒤늦게 넣는다(반환 타입만 다른 오버로드 검사가 첫 함수를 놓치지 않게).
- `src/compiler.zig`: `late_parents` · `late_variants` · `late_overloads` · `late_refs`, `dropLateDecls`(실패한 `compile`의 catch에서,
  carry 전에), `discardLateDecls`(`VM.validate`가 부른다), `expandLateVariants`.
- `src/chunk.zig` `session_main`, `src/sym.zig` `FuncSym.variant_decls` · `FuncInfo.late_taint`.

## 한계

- 템플릿 인스턴스는 전개할 때의 결정을 갖고 있다. `meta.has_decl(T, 'twice')`로 갈래를 고른 인스턴스는 뒤에 `twice`가 생겨도
  다시 전개되지 않는다. 이름을 직접 부르다 실패한 인스턴스는 캐시에 남지 않으므로 문제없다.
- 템플릿 메서드의 중복 선언은 한 소스에서처럼 처음 쓸 때 드러난다. 어떤 인스턴스도 그 이름을 전개하지 않았으면 선언한 입력은
  통과하고 다음 사용이 오류를 낸다. 그 이름은 타입을 다시 선언할 때까지 쓸 수 없다.
- validate가 처음 만든 타입 인스턴스의 trait 구현 메서드가 버려지는 선언에 닿으면, 그 인스턴스의 vtable은 버려진 본문을 계속
  가리킨다(직접 호출은 다시 전개된 본문으로 간다). 메모리는 안전하다. 타입 인스턴스를 버리면 그것을 시그니처에 가진 다른
  인스턴스와 타입이 갈라지므로 손대지 않았다.
- trait 타입에 뒤 입력이 선언한 함수는 한 소스에서처럼 trait의 멤버가 아니다(vtable에 들어가지 않는다).
- CLI의 REPL에서는 `@deinit` · `@copy` · `@clone` · `@send`를 가진 타입을 선언할 수 없다(규칙 5의 끝). 전에도 같았다.
- `fn (&Box[int]) only()`처럼 인스턴스 하나에만 선언하는 꼴은 전부터 'TODO' 오류다. 이번 범위가 아니다.

## 확인

- behavior: `modules/cy_session_methods.cy`(세션), `functions/decl_parent_not_type_error.cy`,
  `functions/decl_method_parent_global_error.cy`, `modules/decl_method_other_module_error.cy`.
- lib: `lib_test/session.zig` "A later eval declares a method for a type of an earlier eval."
- 14단계 검증(`src/tools/verify.sh`) rc=0. REPL은 Debug · ReleaseSafe CLI에 stdin으로 넣어 확인했다(메서드, 타입 함수, 오버로드,
  중복 오류, `@deinit` 거절, `.which`).
