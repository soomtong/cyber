# 0.4.18 이후 변경 (미릴리스)

0.4.18(2026-11-22) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 추론 람다와 오버로드, 기본 메서드의 버그 수정 (2026-11-23)

0.4.18 이후 변경을 리뷰하면서 찾은 문제를 고쳤다. 아래 '함수 인자에서 템플릿 파라미터를 추론한다'와 'trait의 기본 메서드' 항목의 일부 서술은 이 항목으로 대체된다.

### 반환 타입을 추론하는 람다 본문의 `!`가 컴파일러를 segfault로 죽였다

- 무엇이 틀렸나: `fn(x str) => int.parse(x)!`와 `map(items, |x| int.parse(x)!)`(`f fn(T) -> %U`)처럼 반환 타입을 본문에서 추론하는 람다는 본문 분석이 끝난 뒤에야 시그니처가 정해지는데,
  `!`와 `!else:` 블록의 `return`이 아직 없는 시그니처에서 반환 타입을 읽었다. 반환 타입을 선언한 식 람다(`fn(x str) -> !int => int.parse(x)!`)도 시그니처를 본문 뒤에 정해서 같은 값을 읽었다.
- 이제 어떻게 되나: 추론 중인 람다의 `!`는 '`!` can not leave a lambda whose return type is inferred from its body: the return type is not known yet. Declare the return type of the lambda (`fn(x T) -> !U => expr`), or handle the error here with `!else` or `try`.'를,
  `return`은 '`return` can not leave a lambda whose return type is inferred from its body: the return type is not known yet. Declare the return type of the lambda (`fn(x T) -> U => expr`).'를 위치와 함께 보고한다.
  반환 타입을 선언한 식 람다의 `!`는 정상 동작하고, `fn(T) -> %U` 인자로 넘기면 `U`가 `!int`로 추론된다. 본문에서 `!U`를 추론하는 것은 지원하지 않는다.
- 구현: `sema_stmt.checkReturnTypeKnown`이 `func.isResolved()`를 확인한다(`!`, `return`, `scope` 블록). `sema_expr`의 `lambda_expr`는 반환 타입이 선언된 경우 본문 전에 `resolveUserLambda`를 부른다.
  `Proc.getReturnType`에 assert를 추가했다.
- 테스트: `src/test/control_flow/bang_in_infer_ret_lambda.cy`, `bang_in_infer_ret_lambda_error.cy`, `return_in_infer_ret_lambda_error.cy`, `src/test/meta/infer_param_lambda_bang_error.cy`.

### 추론 람다의 함수 타입에서 `%T` 자리표시 평가

- 무엇이 틀렸나: `f fn(T) -> Map[%K, int]`, `fn(T) -> Wrap[%U]`(제약 있는 템플릿), `fn(T) -> [%N]T`처럼 반환 타입 안의 템플릿이 infer 파라미터를 선언하면,
  추론 람다(`|x| expr`)를 넘긴 유효한 호출이 선언 위치에서 '`type.info` does not support the type `Infer`', 'Expected type `Num`. Found `type`.', 'Expected type `int`. Found `type`.'로 실패했다.
  `fn(T) -> Pair[%U, U]`처럼 `%U`로 선언한 이름을 같은 함수 타입 안에서 다시 쓰면 'Could not find the symbol `U`.'였다. 두 경우 모두 이름 있는 함수를 넘기면 통과했다.
  `fn twice(f fn(%T) -> T, x T)`에 `twice(|x| x * 2, 3)`도 선언 위치에 'Could not find the symbol `T`.'가 나왔다.
- 이제 어떻게 되나: 위 람다 호출들이 이름 있는 함수를 넘긴 경우와 똑같이 통과한다. 타입 별칭 템플릿과 `Func[fn(T) -> Pair[%U, U]]`도 같다.
  `twice(|x| x * 2, 3)`는 호출 인자 위치에 'Can not infer the template parameter `T` from the lambda for `f`. The type of the lambda parameter `x` must be known from the arguments before the lambda. ...'를 보고한다.
- 남은 한계: 값 파라미터가 있는 별칭(`type VecFn[const N int, T Any] = fn(T) -> [N]T`, `f VecFn[%N, T]`)에 추론 람다를 넘기면
  'Can not infer function type. Consider using an explicit `fn` declaration.'이 호출 위치에 나온다. 이름 있는 함수나 타입을 적은 람다를 쓴다.
- 구현: `InferParamMode.placeholder`를 없앴다. `sema_func.evalParamTypeHint`가 정해지지 않은 infer 이름을 `Sema.infer_t`로 임시로 묶고 `.bound` 모드로 평가한 뒤 푼다.
  `template.resolveTemplateArgs`는 자리표시로 만든 인자를 받으면 템플릿을 확장하지 않고 자리표시 자체를 결과로 삼는다. 타입 별칭, `Func`, `OpaqueFunc`, `&T`는 예외로 확장한다.
  이 경로의 인자 검사는 `ExprCstr.pass_infer_placeholder`로 건너뛴다.
- 테스트: `src/test/meta/infer_param_lambda_template_ret.cy`, `infer_param_lambda_reuse_error.cy`.

### 함수 본문의 `%T`는 항상 오류다

- 무엇이 틀렸나: 템플릿 함수 본문의 `%T`가 이름이 묶여 있으면 오류 없이 `T`로 통과했고(`fn g(x []%T) -> T:` 안의 `var y %T = x[0]`), 없으면 'Could not find the symbol `Q`.'가 나왔다.
- 이제 어떻게 되나: 템플릿 함수 여부, 이름이 묶였는지와 관계없이 '`%T` can only be declared in the signature of a function.'을 보고한다.
  본문 안 람다의 시그니처에 쓴 `%T`(`f := fn(a %T) -> T:`)도 같다. 전에는 조용히 `T`로 통과했으므로, 그런 코드는 `%`를 뗀다.
- 구현: `cte`의 `%T` 평가는 시그니처를 해석할 때(`infer_param == .param`)만 instance를 조회한다.
- 테스트: `src/test/meta/infer_param_template_body_error.cy`, `infer_param_template_body_new_error.cy`.

### 결과 타입 `!%T` 안의 infer 파라미터

- 무엇이 틀렸나: `!%U`는 `unary_expr`로 파싱되는데 infer 파라미터를 찾는 순회가 이 노드를 방문하지 않았다. `fn conv(x %T, f fn(T) -> !%U) -> !U`는 선언에서 'Could not find the symbol `U`.'를 냈고,
  `fn un(x !%T) -> int`에 `un(int.parse('1'))`은 'Expected argument `Infer`, found `!int`, when calling `fn un(Infer) -> int`.'를 냈다.
- 이제 어떻게 되나: `!%T`는 `?%T`, `[]%T`와 같은 방식으로 템플릿 파라미터를 선언한다. 파라미터 타입(`x !%T`, `x ![]%T`, `x ?!%T`), 함수 타입의 반환 타입(`f fn(T) -> !%U`),
  타입 별칭 템플릿의 대상, `Func[...]` · `&OpaqueFunc[...]` 인자에서 모두 추론되고, 이름 있는 함수와 추론 람다(`|s| int.parse(s)`) 양쪽을 받는다.
  실패하지 않는 함수를 넘기면 'Expected template `Result`. Found `Int`.'이다.
- 구현: `sema_type.findInferParams`, `sema_func.firstInferParam`, `sema_func.inferCtArgs`에 `unary_expr`(`.lnot`) 분기를 추가했다. `inferCtArgs`는 인자 타입이 `Result` 템플릿의 인스턴스인지 보고 child와 맞춘다.
- 테스트: `src/test/meta/infer_param_result_type.cy`, `infer_param_result_type_error.cy`.

### 오버로드에 넘긴 추론 람다의 본문 타입이 안 맞으면 다음 오버로드로 넘어간다

- 무엇이 틀렸나: `fn conv(x int, f fn(int) -> str)`와 `fn conv(x %T, f fn(T) -> %U)`가 있을 때 `conv(1, |x| x + 1)`이 추론 오버로드로 넘어가지 않고 'Expected type `str`, got `int`.'로 실패했다.
  이름 있는 함수(`conv(1, toi)`)는 넘어갔다.
- 이제 어떻게 되나: 식 람다(`|x| expr`)의 본문 타입이 함수 파라미터의 결과 타입과 다르면 그 오버로드의 불일치로 보고 다음 오버로드를 시도한다.
  어떤 오버로드도 받지 못하면 가장 가까웠던 오버로드 기준으로 본문 위치에 전과 같은 오류를 낸다. 본문 안의 다른 오류(선언되지 않은 이름 등)는 바로 오류다.
- 남은 한계: `if` 식 분기의 타입 불일치, 블록 람다의 `return`, 템플릿 파라미터를 추론하는 오버로드 안에서의 불일치는 여전히 바로 오류다.
- 구현: 오버로드 인자인 추론 람다는 본문의 최상위 타입 검사만 보고하지 않고 플래그로 돌린다(`semaExprCstrSoft`, `semaReturnExprStmt2`). 불일치면 람다를 코드 생성 없이 버리고(`sema_local.dropLambdaProc`)
  `FuncMatchError.lambda_result`를 돌려준다. `matchFuncSym`은 모든 후보가 실패하고 가장 멀리 간 후보가 람다 본문에서 실패했으면 그 후보만 다시 맞춰 본문의 오류를 낸다.
- 테스트: `src/test/meta/infer_param_overload_lambda.cy`, `infer_param_overload_lambda_error.cy`, `infer_param_overload_lambda_body_error.cy`.

### trait의 기본 메서드가 같은 이름의 오버로드와 함께 동작하지 않았다

- 무엇이 틀렸나: 타입이 기본 메서드를 받을지를 이름만 보고 정했다. trait에 `fn show() -> str:`(기본)와 `fn show(indent int) -> str`가 같이 있을 때 타입이 `show(indent int)`만 구현하면
  기본 `show()`를 받지 못했고('`A` does not implement `fn show(Fmt) -> str` from `Fmt`.'), 두 오버로드가 모두 기본이면 자기 자신과 충돌했다('`A` gets the default method `show` from both `Fmt` and `Fmt`. ...').
  서로 다른 두 trait이 같은 이름 · 다른 파라미터의 기본 메서드를 줄 때도 충돌로 보고했다.
- 이제 어떻게 되나: 기본 메서드는 오버로드 단위로 정해진다. 타입에 같은 이름 · 같은 파라미터 타입의 메서드가 있을 때만 그 기본 메서드가 빠지고, 파라미터가 다른 메서드는 별개의 오버로드로 남는다.
  기본 메서드 본문에서 `self.show(0)`처럼 다른 오버로드를 부를 수 있다. 두 trait의 충돌 오류는 이름과 파라미터 타입이 모두 같을 때만 난다.
  파라미터는 같고 반환 타입만 다른 메서드는 전처럼 'does not implement' 오류다. 같은 이름의 필드나 수신자 없는 함수가 있으면 그 이름의 기본 메서드는 전처럼 받지 않는다.
- 구현: `sema_type.reserveDefaultMethods`가 타입의 같은 이름 메서드 시그니처를 먼저 푼 뒤(`ensure_resolved_func`) 수신자 뒤 파라미터 타입으로 비교한다(`sameMethodParams`).
- 테스트: `src/test/types/trait_default_overload.cy`, `trait_default_overload_clash_error.cy`. `trait_default_sig_error.cy`는 파라미터가 같고 반환 타입이 다른 경우로 바꿨다(예전 입력은 이제 올바른 프로그램이다).

### 정리

- `Taskfile.yml` 머리말에 남은 `tcc` · `cc` 주석과 `src/vm.h`의 쓰이지 않는 `EvalConfig` 구조체를 지웠다. 동작 변화는 없다.

## trait 메서드의 수신자는 공유 빌림이다 (2026-11-23, 깨지는 변경)

타입의 메서드가 trait 메서드를 구현하는지 볼 때 수신자를 비교하지 않았다(`Type.get_trait_method_impl`이 첫 파라미터를 건너뛴다).
그래서 배타 수신자 `fn (&&Box) push(x int)`가 trait의 `fn push(x int)` 구현으로 받아들여졌고, `^Dyn[Grow]` · `&Dyn[Grow]` · 기본 메서드의 `self`로
다른 빌림이 살아 있는 동안 검사 없이 호출됐다. `first := &b.xs[0]` 뒤 `d.push(4)`가 버퍼를 다시 잡아도 `first`를 그대로 읽었다.
값 수신자 `fn (Box) get()`은 `Dyn` 호출이 넘기는 주소를 값으로 읽어 쓰레기 값을 돌려줬다.

- 규칙: trait 메서드는 공유 빌림 `&T`로 호출된다. `&&T` 수신자 메서드는 trait 메서드를 구현하지 않는다. `with Trait` 줄에 다음을 보고한다.
  '`Box` does not implement `fn push(Grow, int) -> void` from `Grow`. The method `push` takes an exclusive borrow `&&Box`, but a trait method takes a shared borrow `&Box`.
  Keep what `push` changes behind a reference `^T`, or call `push` on `Box` without the trait.'
- 근거: 구체 타입에서도 `&&T` 메서드는 `&T`나 `^T`로 부를 수 없다('Expected argument `&>Box`, found `&Box`, ...'). `^T`는 `b.*.push(4)`로 풀어 써야 하고 그 호출은 정적으로 검사된다.
  trait 경로만 이보다 약했다. 런타임 유일성 검사는 어디에도 없으므로 `Dyn`에 새 장치를 넣지 않고 거부한다.
- 고치는 법: `&&T` 메서드를 trait 밖에 두고 타입에서 직접 부르거나, 메서드가 바꾸는 값을 참조 뒤에 둔다(`items ^Items`, `fn (&Box) push(x int): self.items.xs += x`).
  `^T` 뒤는 배타 빌림 규칙이 적용되지 않는다(기존 규칙).
- 같은 시그니처의 `&T` 메서드와 `&&T` 메서드가 둘 다 있으면 `&T` 메서드가 trait을 구현한다. 전에는 오버로드 목록에서 먼저 찾은 쪽이었다.
- 값 · `^T` · `sink T` 수신자: 템플릿 제약으로는 계속 trait을 구현한다(core의 `Span[T].span()`이 값 수신자로 `AsSpan[T]`를 구현한다).
  `Dyn`으로 바꾸는 자리와 기본 메서드를 받는 자리에서 거부한다. '`Unit` can not be used as `Dyn[Sized]`. The method `size` takes the receiver as `Unit`,
  but a call through `Dyn` passes a shared borrow `&Unit`. Declare the method as `fn (&Unit) size(...)`.'
  `^T` 수신자를 `^Dyn`으로만 쓰던 프로그램은 전에 동작했고 이제 오류다. 수신자를 `&T`로 바꾼다.
- 영향 범위: 저장소의 `src/builtins`, `src/std`, `src/test`, `examples`, `docs`에 `&&T` 수신자로 trait을 구현한 곳은 없다. `&T`가 아닌 수신자는 `Span[T].span()` 하나다.
- 남은 한계: trait 제약 템플릿(`fn add[T Grow](r &&T)`)에서 `&&T` 메서드를 trait 메서드로 부르던 코드도 타입이 trait을 구현하지 않게 되므로 막힌다.
  trait 메서드 선언에 배타 수신자를 표시하는 문법은 넣지 않았다. 쓰는 코드가 없고, `Dyn` 뒤의 값에는 배타성을 검사할 장치가 없다.
- 문서: `docs/docs.md`의 'Methods -> Choosing a receiver'(수신자 고르는 법과 오류 문구), 'Traits -> Receivers of trait methods'.
- 구현: `Compiler.resolveImplFuncs`(`src/compiler.zig`)가 `&&T` 수신자를 거부하고, `sema_type.checkDynReceivers`가 `Dyn` 변환 두 곳(`src/sema_lit.zig`)과
  기본 메서드의 `self`(`src/sema_local.zig`)에서 나머지 수신자를 거부한다. `get_trait_method_impl`(`src/types.zig`)은 `&T` 수신자 오버로드를 먼저 고른다.
- 테스트: `src/test/types/trait_receiver.cy`, `trait_ex_receiver_error.cy`, `trait_default_ex_receiver_error.cy`, `trait_value_receiver_dyn_error.cy`,
  `trait_ref_receiver_dyn_error.cy`, `trait_value_receiver_default_error.cy`.

## C 백엔드(`-tcc`, `-cc`)를 삭제했다 (2026-11-23, 깨지는 변경)

C 백엔드는 어떤 스크립트도 컴파일하지 못했다. `cyber -tcc x.cy`는 `print(1.5)` 한 줄에도 `core:17`에서 'CompileError: Expected function implementation.'으로 끝났다.
upstream에서 물려받은 상태이고 CI는 이 백엔드를 돌린 적이 없다. 그런데 `cyber help`는 두 옵션을 'Experimental.'로, 매뉴얼은 네이티브 성능이 필요할 때 쓰라고 적고 있었다.
점검해 보니 막힌 곳이 다섯 겹이고 IR의 문장 9종 · 식 17종과 런타임 대부분이 없어, 고치는 일이 백엔드를 새로 만드는 크기였다. 그래서 코드를 지웠다.
바이트코드 VM이 유일한 백엔드다. 네이티브 백엔드는 필요해지면 LLVM으로 새로 만든다(결정 `docs/decisions/project_direction.md`).

- CLI: `-tcc`, `-cc`를 주면 'error: The C backend (-tcc) was removed. Run without the option.'을 stderr에 찍고 종료 코드 1로 끝난다.
  CLI는 모르는 옵션을 무시하므로, 이 안내가 없으면 스크립트가 조용히 VM에서 돈다. `cyber help`에서 두 옵션이 빠졌다.
- 임베딩 API(깨지는 변경):
  - `CLBackend`에서 `CL_TCC` · `CL_CC`가 빠졌다. `CL_LLVM`의 값이 4에서 2가 됐다(`CL_VM` 0, `CL_JIT` 1은 그대로).
  - `CLEvalConfig`에서 `spawn_exe` 필드가 빠졌다(AOT 실행 파일을 띄우는 방식이었다). 구조체 배치가 바뀌니 헤더와 라이브러리를 함께 올린다.
  - `cy` 모듈의 `Backend` enum에서 `tcc` · `cc`가, `EvalConfig`에서 `spawn_exe`가 빠졌다.
  - JIT 거절 문구는 C 백엔드를 권하던 부분을 빼서 'The JIT backend is not supported. Use the bytecode VM (default).'이다.
- 지운 것: `src/aot.c` · `src/aot.h`, `src/cgen.zig`의 프로그램 생성 쪽(`gen` · `genStmt` · `genExpr`과 그 아래, 3,162줄 → 약 1,030줄),
  `Compiler`의 `AotCompileResult`, `VM.eval`의 실행 파일 경로와 `VM.last_exe_error`, 빌드 옵션 `-Dtest-backend`와 `Taskfile.yml`의 `BACKEND=`.
- 남긴 것: `src/cgen.zig`의 나머지는 FFI(`src/builtins/c.zig`)가 `extern` 바인딩의 C 코드를 만들 때 쓴다. `libtcc`도 FFI가 쓴다. 동작은 그대로다.
  `meta.is_vm_target()`은 남아 있고 항상 `true`다.
- 문서: `docs/docs.md`에서 'C backend.' · 'Static binding.' 절과 AOT를 언급한 문장을 지웠다. `docs/build.md`의 'C backend (not working)' 절도 지웠다.
- 테스트: CLI 테스트 'CLI: -tcc and -cc are reported as removed.'. 발견 표 F-195.


## 함수 인자에서 템플릿 파라미터를 추론한다 (2026-11-23)

함수 타입 안에서 선언한 infer 파라미터(`f fn(T) -> %U`)와, 앞선 템플릿 파라미터를 쓰면서 새 파라미터를 선언하는 파라미터 타입(`p Pair[T, %U]`, `f MapFn[T, %U]`)은
호출 인자 위치에 'Can not infer the template parameter `U` from the argument for `f`...'을 보고했고, `%U type`을 따로 선언해 `map(str, items, name)`으로 타입을 넘겨야 했다.
이제 인자의 타입에서 추론한다. 아래 두 항목(함수 포인터 타입, infer 파라미터 오류)의 '추론은 아직 지원하지 않는다'는 이 항목으로 대체된다.

- 규칙: 호출 인자는 왼쪽에서 오른쪽으로 맞춘다. 파라미터 타입은 앞선 인자가 정한 템플릿 파라미터를 쓰면서 새 파라미터를 선언할 수 있다.
  이미 정해진 부분은 인자와 맞아야 하고, 맞지 않으면 보통의 불일치 오류다. `fn second(x %T, p Pair[T, %U]) -> U`에 `second(1, Pair[str, str]{...})`는
  'Expected type `Pair[int, str]`. Found `Pair[str, str]`.'이다.
- 함수 인자: `fn map(items []%T, f fn(T) -> %U) -> []U`를 `map([]float{1, 2}, name)`으로 부르면 `name`의 타입 `fn(float) -> str`에서 `U`가 `str`이 된다.
  함수 타입의 파라미터 타입과 반환 타입을 함수의 것과 하나씩 맞춘다. `fn(%A, %B) -> %C`, `fn(T) -> []%U`, `fn(T) -> ?%U`처럼 어느 자리에나 선언할 수 있다.
  타입을 적은 람다(`fn(x int) => x * 2`, `fn(x int) -> str: ...`)도 같은 함수다. `map([]int{1, 2}, name)`은 'Expected type `fn(int) -> str`. Found `fn(float) -> str`.'이다.
- 쓰는 형식: 인라인 함수 타입, 타입 별칭 템플릿(`f MapFn[T, %U]`, 별칭의 별칭과 파라미터를 두 번 쓰는 별칭 포함), 함수 유니온의 인자(`f Func[fn(T) -> %U]`, `f &OpaqueFunc[fn(T) -> %U]`).
  함수 유니온 파라미터는 함수와 클로저를 모두 받는다. 메서드(`fn (&Box[]) map(f fn(T) -> %U) -> Box[U]`)에서도 같다.
- 추론 람다: `|x| expr`은 자기 타입이 없다. 람다의 파라미터는 함수 타입에서 타입을 받고, 반환 타입의 템플릿 파라미터는 본문 식의 타입에서 추론한다.
  `map([]int{1, 2}, |x| 'n%{x}')`는 `[]str`이다. 그래서 함수 타입의 파라미터 타입에 있는 템플릿 파라미터는 람다보다 앞선 인자가 정해야 한다.
  `fn rmap(f fn(%T) -> %U, items []T)`에 `rmap(|x| x + 1, items)`는 'Can not infer the template parameter `T` from the lambda for `f`. The type of the lambda parameter `x` must be known
  from the arguments before the lambda. ...'이다. 이름 있는 함수와 타입을 적은 람다는 스스로 `T`를 정하므로 앞에 와도 된다(`rmap(name, items)`).
- 남은 한계: 블록 본문의 추론 람다(`f(items, |x|)):` 뒤에 본문)는 결과 타입을 추론하지 않는다. 템플릿 파라미터를 정해야 하는 자리에서는
  'Can not infer the template parameter `U` from the lambda for `f`. The result type of a lambda with a block is not inferred. ...'을 보고한다. 식 람다, 타입을 적은 람다, `%U type` 중 하나를 쓴다.
  어느 인자도 정하지 못하는 파라미터(별칭이 쓰지 않는 파라미터 등)는 전과 같은 'Can not infer the template parameter `U` from the argument for `f`. Declare it as its own parameter (`%U type`) ...'이다.
  컴파일 타임 호출(`const r = f(...)`)은 함수를 함수 포인터 인자로 받지 못하는 기존 제약이 그대로여서 함수 타입 추론이 닿지 않는다. 값 타입의 추론(`fn size(x %T, v [%N]T)`)은 컴파일 타임 호출에서도 된다.
- 그 밖의 오류: 함수가 아닌 인자는 'Expected a function for `fn(T) -> %U`. Found `int`.', 파라미터 수가 다르면 'Expected a function with `1` parameter(s) for `fn(T) -> %U`. Found `fn(int, int) -> int`.',
  함수 포인터 자리에 클로저를 넘기면 'Expected a function for `fn(T) -> %U`. Found the closure `Func[fn(int) -> int]`. A closure is passed to a `Func[fn(...)]` or a `&OpaqueFunc[fn(...)]` parameter.',
  람다의 파라미터 수가 다르면 'Expected a lambda with `1` parameter(s) for `f`. Found `2`.'이다.
- 같은 파라미터를 두 번 선언한 `fn two(a %T, b %T) -> T`는 위치 없는 'CompileError: Error: DuplicateParam'으로 끝났다. 이제 두 번째 `%T` 위치에
  'The template parameter `T` is already declared. Write `T` without `%` to use it.'를 보고한다.
- `?%T`도 infer 파라미터를 선언하는 형식으로 받는다(`fn opt(x %T, f fn(T) -> ?%U) -> ?U`, `fn first(o ?%T) -> T`).
- 이미 정해진 부분의 불일치는 선언 쪽 노드가 아니라 호출 인자 위치에, 파라미터 타입 전체로 보고한다. `fn f(m Map[str, %V])`에 `Map[int, int]`를 넘기면
  전에는 시그니처의 `str` 위치에 'Expected type `int`. Found `str`.'이 났다. 이제 인자 위치에 'Expected type `Map[str, int]`. Found `Map[int, int]`.'이다.
- 오버로드: 템플릿 파라미터를 추론하는 후보는 인자와 정확히 맞는 후보가 없을 때만 시도한다(선언 순서와 무관). 추론 람다의 본문 타입이 안 맞는 후보는 건너뛴다(맨 위 항목).
- 구현: `src/sema_func.zig`의 `matchTemplateArg` · `matchTemplateArgCt`가 Dependent 파라미터 타입을 지금까지 정해진 파라미터로 평가해 보고(`evalParamType`, `InferParamMode.bound`),
  아직 정해지지 않은 infer 파라미터가 있으면 인자를 먼저 해석한 뒤 `inferCtArgs`로 묶는다. `inferCtArgs`는 `fn_type`, `option_type`, 별칭 템플릿(`AliasArgs`), 함수 유니온을 따라간다.
  묶은 뒤 파라미터 타입 전체를 다시 평가해 인자와 비교하고, 함수를 `Func`로 감싸는 변환은 `sema_lit.semaFitTarget`이 한다.
  추론 람다는 `resolveInferLambdaArg`가 정해지지 않은 파라미터를 자리표시 타입으로 둔 채(`evalParamTypeHint`, 맨 위 항목) 함수 타입을 평가해 람다 파라미터 타입을 얻고, `sema_expr.semaLambdaInferRet`가 본문에서 결과 타입을 얻는다.
- 예제: `examples/calculator.cy`의 `map`이 `%U type` 없이 `map(calc.history, |r| r.result)`로 불린다.
- 테스트: `src/test/meta/infer_param_func_type*.cy`, `infer_param_lambda*.cy`, `infer_param_dependent*.cy`, `infer_param_method.cy`, `infer_param_overload.cy`, `infer_param_dup_error.cy`,
  `src/test/functions/func_type_inline_infer_param*_error.cy`.

## trait의 기본 메서드 (2026-11-23)

trait 메서드에 본문을 쓸 수 없어서('Trait methods should not have a body.') 구현 타입마다 같은 동작을 다시 적어야 했다.
이제 본문이 있는 trait 메서드는 기본 메서드다. `with Trait`으로 선언한 타입이 그 메서드를 선언하지 않으면 기본 메서드를 받는다.

```cy
type Shape trait:
    fn area() -> float
    fn name() -> str
    fn describe() -> str:
        return '%{self.name()} with area %{self.area()}'
```

- 호출: 구현 타입에서 바로(`Circle{radius=2}.describe()`), `^Dyn[Shape]` · `&Dyn[Shape]`를 거쳐서, 템플릿 파라미터를 거쳐서 모두 된다.
- 재정의: 타입이 같은 이름 · 같은 파라미터 타입의 메서드를 선언하면 그것이 쓰인다. 파라미터가 다른 메서드는 별개의 오버로드다(맨 위 항목).
  파라미터는 같고 반환 타입만 다르면 기존 오류 그대로다('`Circle` does not implement `fn describe(Shape) -> str` from `Shape`.').
- `self`: 기본 메서드 안의 `self`는 trait으로 본 수신자, 타입은 공유 빌림 `&Dyn[Shape]`이다. trait의 다른 메서드(필수 · 기본)를 부를 수 있고
  `&Dyn[Shape]`를 받는 함수에 넘길 수 있다. `self`의 호출은 동적 디스패치라서 구현 타입이 재정의한 메서드에 닿는다.
- 필드 접근은 오류다: 'Field `radius` does not exist in `&Dyn[Shape]`. A default method of a trait can not access the fields of the implementing type, only the methods of the trait.'
  값이 필요하면 그 값을 돌려주는 필수 메서드를 선언해서 부른다.
- 수신자: trait 메서드는 수신자 없이 선언하고 기본 메서드는 항상 공유 빌림으로 받는다. 배타 수신자 `&&T`의 기본 메서드는 없다.
- 제네릭 trait(`type Source[T Any] trait`)의 기본 메서드는 trait의 템플릿 파라미터를 쓸 수 있다. 템플릿 타입(`Box[T]`)도 기본 메서드를 받는다.
- 두 trait의 기본 메서드가 이름과 파라미터 타입이 같으면 타입이 직접 선언해야 한다: '`Both` gets the default method `side` from both `Left` and `Right`. Declare `side` for `Both` to say what it does.'
  한 trait의 기본 메서드는 다른 trait의 필수 메서드를 구현하지 않는다: '`Both` has the method `side` only as a default method of `Left`. Declare `side` for `Both` to implement `Right`.'
- 제한: 기본 메서드는 제너레이터일 수 없고('A default method of a trait can not be a generator.') 템플릿 파라미터를 가질 수 없다
  ('A default method of a trait can not have a template parameter.'). 본문은 기본 메서드를 받는 타입마다 컴파일되므로, 모든 구현 타입이 재정의한 기본 메서드의 본문은 검사되지 않는다.
- 구현: 타입의 `with`를 풀 때(`sema_type.reserveDefaultMethods`) 타입에 없는 기본 메서드마다 수신자 `&T`인 메서드를 타입에 예약한다(`Func.default_trait`).
  직접 호출과 vtable 구성(`Compiler.resolveImplFuncs`)은 이것을 타입이 선언한 메서드처럼 찾는다. 본문을 검사할 때(`sema_local.semaMethodBody2`) 수신자는 숨은 파라미터이고
  `self`는 그것을 `&Dyn[Trait]`로 감싼 지역 변수다. VM · 바이트코드 변경은 없다.
- 테스트: `src/test/types/trait_default.cy`, `trait_default_field_error.cy`, `trait_default_clash_error.cy`, `trait_default_other_trait_error.cy`,
  `trait_default_sig_error.cy`, `trait_default_generator_error.cy`. 예제 `examples/calculator.cy`의 `Operation.describe`.

## 함수 포인터 타입을 타입 자리에 바로 쓴다 (2026-11-23)

함수 포인터 타입은 타입 별칭의 오른쪽에만 쓸 수 있었다. `fn apply(x int, f fn(int) -> int) -> int:`는 `fn`에서 'Expected type specifier.'가 났고,
고차 함수는 시그니처마다 별칭(`type MapFn[T Any, U Any] = fn(T) -> U`)을 따로 선언해야 했다. 이제 타입을 쓰는 자리 어디에나 `fn(P1, P2) -> R`을 쓴다.

- 쓸 수 있는 자리: 함수 · 메서드 · 람다의 파라미터와 반환 타입, 구조체 필드, choice 케이스의 payload, `var` · `global` 선언, `as[...]`의 대상,
  타입 인자(`[]fn(int) -> int`, `Map[str, fn(float, float) -> float]`, `?fn() -> int`, `Func[fn(int, int) -> int]`, `&OpaqueFunc[fn(T, T) -> bool]`), 트레이트 메서드 시그니처.
  `-> R`이 없으면 `void`를 반환한다. 별칭 형식처럼 파라미터 이름을 붙일 수 있다(`fn(a int, b int) -> int`).
- 같은 타입: 인라인 형식과 별칭 형식은 같은 타입이다. 서로 대입되고, 타입 이름도 같고(`fn(int) -> int`), 오버로드 판정에서도 같다.
  `fn over(f IntFn)`과 `fn over(f fn(int) -> int)`를 함께 선언하면 '`over` has already been declared with the same function signature.'이다.
- 반환 타입의 결합: 함수 타입의 반환 타입은 오른쪽 끝까지 차지한다(오른쪽 결합). `fn(int) -> fn(int) -> int`는 함수를 반환하는 함수이고,
  `fn make() -> fn(int) -> int:`는 `fn(int) -> int`를 반환한다. 본문을 여는 `:`는 타입에 들어가지 않는다.
  파라미터 괄호 안의 `-> R`은 그 파라미터의 것이고, `)` 뒤의 `-> R`은 바깥 함수의 것이다(`fn g(f fn(int) -> int) -> int:`).
- 접두사: `?`, `!`, `[]`, `^`, `&`는 뒤따르는 함수 타입 전체에 붙는다. `?fn() -> int`는 옵션 함수, `fn() -> ?int`는 옵션을 반환하는 함수다.
  다르게 묶으려면 괄호를 쓴다(`?(fn() -> int)`, `fn(int) -> (fn(int) -> int)`).
- 식 자리의 `fn(...)`: 람다다. 시그니처 뒤에 `:`나 `=>`가 와야 하고, 없으면 전과 같이 'Expected colon.'이다.
  시그니처 뒤에 `)`, `]`, `,`, `}`가 올 때만 타입으로 읽는다. 타입 인자(`Func[fn(int) -> int]`, `Map[str, fn(int) -> int]{}`, `type.name(fn(int) -> int)`)가 이 경우다.
  타입 자리와 타입 접두사 뒤에서는 항상 타입이다. `^fn(a int) -> int:`처럼 식에서 람다 앞에 붙는 `^` · `&`는 전과 같이 람다를 받는다.
- 템플릿 파라미터: 인라인 함수 타입은 앞선 인자로 정해진 템플릿 파라미터를 쓸 수 있다. `fn filter(items []%T, f fn(T) -> bool) -> []T`를 `filter(xs, |x| x > 3.0)`으로 부른다.
  함수 타입 안에서 새 infer 파라미터를 선언할 수는 없다. `f fn(T) -> %U`, `f fn(%T) -> int`, `f Func[fn(T) -> %U]`는 호출 인자 위치에
  'Can not infer the template parameter `U` from the argument for `f`. Declare it as its own parameter (`%U type`) and pass the type in the call.'을 보고한다.
  추론은 아직 지원하지 않는다. `fn map(%U type, items []%T, f fn(T) -> U) -> []U`처럼 따로 선언한다.
- 구현: `src/parser.zig`의 `parseOptTypeSpecWith`가 `fn`을 받아 별칭과 같은 `fn_type` 노드를 만든다(`parseFuncType`). 식 자리는 `parseLambdaOrFuncType`이 시그니처 뒤 토큰으로 가른다.
  `ParseTermConfig.type_spec`이 타입 자리임을 접두사 아래로 전달한다. `src/sema_type.zig`의 `findInferParams`와 `src/sema_func.zig`의 `firstInferParam`이 `fn_type`을 방문한다.
- 도구: `cyber fmt`와 `examples/fmt.cy`는 새 문법을 그대로 둔다. tree-sitter 문법(`exts/tree-sitter/grammar.js`)은 이미 `function_type`을 타입으로 받아서 바꾸지 않았고, 코퍼스 테스트만 더했다.
- 예제: `examples/calculator.cy`의 `map` · `filter` · `fold`가 별칭 대신 인라인 타입을 쓴다.
- 테스트: `src/test/functions/func_type_inline*.cy`, `src/test/syntax/func_type_inline_*_error.cy`, `exts/tree-sitter/test/corpus/declarations.txt`의 'Inline function types'.

## `Object.to_string()`이 상자를 해제하던 버그 수정 (2026-11-23)

`Object(^1).to_string()`처럼 `bool`, 정수, `float`, `error`, `symbol`, `str`을 담은 `Object`에 `to_string()`을 부르면 결과는 맞게 나오지만
호출이 끝날 때 상자가 해제됐다. 그 뒤 `Object`가 범위를 벗어나거나 다시 쓰이면 이미 해제된 메모리를 건드렸다.
디버그 빌드는 'double free' 또는 'retaining dangling pointer'로 멈춘다. 이 검사가 없는 빌드에서는 해제된 메모리를 다시 쓰게 된다.

- 원인: `Object.to_string`(`src/builtins/core.cy`)이 `self.inner`를 `as[^T]`로 캐스팅했다. `Ptr[void]`에서 `^T`로 가는 캐스팅은 retain 없이 소유권을 넘겨받는 참조를 만들기 때문에
  임시 참조가 해제되면서 `Object`가 가진 참조 카운트를 하나 깎았다. 이제 `as[Ptr[T]]`로 빌려서 읽는다. 0.4.18 이전부터 있던 버그다.
- 같이 고친 것: `i8` · `i16` · `i32`를 담은 `Object`가 부호 없이 찍혔다(`Object(^(as[i8] -5)).to_string()`이 `251`). 상자를 `int`로 읽었기 때문이다.
  이제 타입마다 제 너비로 읽어 `-5`가 나온다. `r8` · `r16` · `r32`도 제 너비로 읽는다(출력은 그대로 `0xc8` 같은 16진수).
- 바뀌지 않는 것: `print(obj)`와 문자열 보간 `'%{obj}'`은 `to_string()`을 부르지 않으며 전과 같이 `Object{inner=@0x...}`를 찍는다.
- 테스트: `src/test/core/object_to_string.cy`.



## float은 항상 소수점을 붙여 문자열로 바뀐다 (2026-11-23, 깨지는 변경)

값이 정수인 float은 소수점 없이 문자열이 됐다. `print(3.0)`이 `3`을 찍어서 출력만으로는 `int`와 `float`을 구별할 수 없었고,
`docs/docs.md`의 예제(`print(add[float](1, 2)) --> 3.0`)와도 달랐다. 이제 float은 다시 읽으면 float이 되는 문자열로 바뀐다.

- 규칙: 유한한 값의 결과에 `.`이 없으면 `.0`을 붙인다. `3.0`은 `3.0`, `-0.0`은 `-0.0`, `1e21`은 `1000000000000000000000.0`.
  자릿수 생성(같은 값으로 읽히는 가장 짧은 십진수, 지수 표기 없음)은 그대로다. `1.5`, `0.0000001`, `inf`, `-inf`, `nan`은 바뀌지 않는다.
- 적용 범위: `print`, `str(x)`, 문자열 보간 `'%{x}'`, `x.fmt()`, 슬라이스 · 구조체 · 옵션 · `Object` 안의 float, `f32`.
  `print([]float{3, 5.5})`는 `{3.0, 5.5}`, `print(Point{x=1, y=2})`는 필드가 float이면 `Point{x=1.0, y=2.0}`.
- 바뀌지 않는 것: `json.stringify` · `json.encode` · `json.fmt_float`(`3.0`은 `3`), `toon.encode`, `time`의 `format`. 정수 `print(3)`은 `3` 그대로다.
- 고치는 방법: 소수점 없는 출력이 필요하면 `int(x)`로 바꿔서 찍는다. float 출력을 문자열로 비교하던 코드는 기대값에 `.0`을 붙인다.
- 구현: 규칙은 `src/fmt.zig`의 `renderFloat` 한 곳에 있다. `f64_fmt` · `f32_fmt`(`src/builtins/core.zig`), `Heap.writeValue`(`src/heap_value.zig`),
  디버거 값 설명(`src/debug.zig`)이 이것을 부른다. `json.fmt_float`는 `float.fmt()` 결과에서 `.0`을 떼어 JSON 형식을 유지한다.
- 테스트: `src/test/core/float_to_str.cy`, `src/fmt.zig`의 'renderFloat'.

## 추론할 수 없는 템플릿 파라미터의 오류 문구 (2026-11-23)

앞선 템플릿 파라미터를 쓰면서 새 infer 파라미터를 함께 선언하는 파라미터 타입(`f MapFn[T, %U]`, `p Pair[T, %U]`)으로 제네릭 함수를 호출하면
위치 없이 내부 오류 이름만 나왔다('CompileError: Error: FoundInferParam'). 이런 타입은 앞선 파라미터에 의존하는 타입으로 분류되어 호출 때 추론 없이 평가되기 때문이다.

- 이제 해당 호출 인자 위치와 함께 'Can not infer the template parameter `U` from the argument for `f`. Declare it as its own parameter (`%U type`) and pass the type in the call.'을 보고한다.
- 추론 자체는 아직 지원하지 않는다. `fn map(%U type, items []%T, f MapFn[T, U]) -> []U`처럼 따로 선언하고 `map(str, items, name)`으로 타입을 넘긴다.
- 컴파일 타임 호출(`const r = second(1, Pair[int, str]{a=1, b='x'})`)은 같은 경우에 '`%U` can only be declared in the signature of a function.'이라고 틀리게 보고했다. 이제 런타임 호출과 같은 'Can not infer the template parameter `U` from the argument for `p`...' 문구를 호출 인자 위치에 보고한다.
- 반환 타입의 infer 파라미터(`fn f(x int) -> %U:`)는 호출이 없어도 위치 없는 'CompileError: Error: FoundInferParam'으로 끝났다. 이제 `%U` 위치에 '`%U` can not be declared in a return type. Declare it in a parameter (`%U type`) instead.'를 보고한다.
- 제네릭이 아닌 함수의 본문에 쓴 infer 파라미터(`fn main():` 안의 `a := []%T{}`)는 위치는 있었지만 문구가 'CompileError: error.FoundInferParam'이었다. 이제 최상위에서 쓴 경우와 같은 '`%T` can only be declared in the signature of a function.'을 `%T` 위치에 보고한다.
- 구현: infer 파라미터를 선언할 수 있는 자리(파라미터 타입)를 평가할 때만 내부 오류 `FoundInferParam`을 내보내고, 그 밖의 자리에서는 바로 오류를 보고한다. 받아 줄 곳이 없는 경로로 내부 오류 이름이 새지 않는다.
- 테스트: `src/test/meta/infer_param_dependent_error.cy`, `infer_param_dependent_ct_error.cy`, `infer_param_return_type_error.cy`, `infer_param_func_body_error.cy`. 매뉴얼: `docs/docs.md`의 'Infer parameter'.

## wasm32-freestanding 빌드 제거 (2026-11-22, 깨지는 변경)

웹용 라이브러리 빌드(`zig build lib -Dtarget=wasm32-freestanding`)를 지원 대상에서 뺐다. 0.4.18에서 다시 빌드되게 고쳤지만 쓰는 곳이 없었다.
웹 플레이그라운드는 WASI 빌드(`cyber-wasi.wasm`)를 `examples/web-playground/wasi.js` 위에서 돌리고, 릴리스 asset에도 `cyber-web.wasm`이 없었다.

- 브라우저에서 Cyber를 돌리거나 임베딩하려면 `wasm32-wasi` 빌드와 WASI 호스트를 쓴다. `zig build lib -Dtarget=wasm32-wasi`가 libcyber를 만든다.
- `meta.system()`의 `SystemKind`에서 `.freestanding`을 뺐다. 저장소의 `.cy` 코드는 이 값을 쓰지 않았다.
- 호스트가 채워야 했던 import(`hostLogDebug/Info/Warn/Error`, `hostMilliTimestamp`, `hostFileWrite`, `hostSleep`, `hostFetchUrl`)는 더 이상 없다.
- `task lib:wasm`, CI의 freestanding 컴파일 확인 단계를 지웠다.
