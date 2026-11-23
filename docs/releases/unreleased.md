# 0.4.18 이후 변경 (미릴리스)

0.4.18(2026-11-22) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

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
||||||| parent of d539623e (Allow a function pointer type inline wherever a type is expected)


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
- C 백엔드(`-tcc`, `-cc`)의 `cb_float_fmt`(`src/aot.c`)는 건드리지 않았다. 정수 값에는 이미 `.0`을 붙이지만 `%.10f`를 써서 자릿수가 VM과 다르다.

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
