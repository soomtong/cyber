# `const` 템플릿 매개변수의 값 종류 (2026-11-08, F-28)

## 배경

`type X[const N int]`처럼 `const` 수식자가 붙은 템플릿 매개변수는 타입이 아닌 값을 받는다. 인스턴스는 `template.zig`의
`instance_cache`(`VariantKeyContext`로 해시 · 비교)에 기억되고, 인스턴스 이름(`Buf[1, 2]`)은 `sym.zig`가 매개변수 값을 찍어 만든다.
세 곳이 지원하는 값 종류가 서로 달랐다.

- `VariantKeyContext.hash` · `eql`: `Type` · `PartialStructLayout` · `FuncSig` · `i32` · `int` · `EvalInt` · `EvalStr` · 함수 심볼 · enum.
  `bool`은 없어서 `type Flag[const B bool]`의 `Flag[true]`가 `thread panic: Unsupported value hash: .bool 2`로 컴파일러를 죽였다.
- 타입 템플릿 인스턴스 이름 `writeVariantParam`: `Type` · `int` · `EvalInt` · `str` · `FuncSig` · 함수 심볼만. `EvalStr` · enum은
  `Unsupported: EvalStr` · `Unsupported: Lvl` 패닉. 함수 템플릿 인스턴스 이름 `writeTemplateParam`은 `EvalStr` · enum을 지원했지만
  enum을 `$high`로 찍었다.
- `resolveTemplateArgs`가 `EvalStr` 인자를 값 스택과 템플릿 컨텍스트(`initCtParam`)에 같은 값으로 넣어 둘 다 해제했다. 참조 계수가
  있는 `EvalStr`는 이중 release로 ReleaseSafe에서 `integer overflow` 패닉(Debug trace 빌드에서는 이름 출력 패닉이 먼저 나와 가려졌다).

발견 이슈 F-28의 전반부(`type X const:`의 이름 덮어쓰기)는 2026-11-04 `ab8163bc`로 고쳐졌고 이 문서는 후반부다.

## 결정

- `const` 매개변수가 될 수 있는 타입을 `template.is_const_param_type` 하나로 정한다: `type`, 정수(`int` · `i8` · `i16` · `i32` ·
  `byte` · `r16` · `r32` · `r64` · `EvalInt`), `bool`, enum, `EvalStr`, 함수 심볼(`fnsym`), `FuncSig`, `PartialStructLayout`(내부).
  `resolveTemplateArgs`(타입 템플릿)와 `expandTemplateFuncForArgs`(함수 템플릿 `f[...]`)가 인자를 평가하기 전에 매개변수 타입을
  검사해 그 밖이면 매개변수 타입 위치에 컴파일 오류 ``Unsupported `const` parameter type `float`. A `const` template parameter can be
  a type, an integer, a `bool`, an enum, an `EvalStr`, or a function symbol.``. `str`은 cte 값이 `EvalStr`라 전부터 인자에서
  `Expected type str. Found EvalStr.`였는데 이제 매개변수에서 위 오류다.
- `VariantKeyContext.hash` · `eql`이 `bool`과 모든 폭의 정수를 폭에 맞는 접근자(`asByte` · `asU16` · `asU32` · `asUint`)로 다룬다.
  이전 `i32`는 hash에만 있고 eql에는 없었다.
- 인스턴스 이름은 타입 · 함수 템플릿이 `writeTemplateParam` 하나를 쓴다(`writeVariantParam` 삭제). `bool`은 `true` · `false`,
  `EvalStr`은 `'abc'`, enum은 값 표기와 같은 `Lvl.high`(이전 함수 템플릿은 `$high`), 정수는 폭에 맞게.
- `resolveTemplateArgs`는 템플릿 컨텍스트에 `copyValue2`로 복사한 값을 넣는다(함수 템플릿의 `inferCtArgs`와 같은 규칙: 컨텍스트가
  자기 복사본을 소유하고 값 스택 항목은 호출자가 해제).
- `cte.evalCompare`에 `bool`을 추가했다(`#if B == true` 같은 비교. 이전에는 `Unsupported bool.` 컴파일 오류).

## 검증

- behavior 테스트 `types/template_const_param_kinds.cy`: `bool` · `EvalStr` · enum · `byte` `const` 매개변수를 가진 타입 템플릿
  (메서드 본문에서 `#if B:` · `return S` · `#if L == .high`), `type.name`(`Flag[true]` · `Tag['abc']` · `ByLvl[Lvl.high]` · `Small[3]`),
  인스턴스 구별(`#{Flag[true] == Flag[false]}`가 false, 같은 인자는 true), 같은 종류의 함수 템플릿(`g['xy']()` · `h[true]()` · `k[.low]()`).
- `types/template_const_param_type_error.cy`: `type Scale[const F float]`의 `Scale[1.5]`가 위 컴파일 오류.
- 기존 `types/template_const_params.cy`(F-23) · `meta/type_const.cy` · `meta/ct_eval_loop.cy`는 그대로.

## 남은 것

- `[N]T`의 길이 `N`은 `int`만 받는다(`type Small[const N byte]: data [N]byte`는 `Expected type int. Found byte.`). 폭이 다른
  정수를 `int`로 넓히는 것은 별개.
- `float` `const` 매개변수는 지원하지 않는다(해시 · 비교 · 이름 출력에 넣으면 되지만 쓰임이 없어 보류).
- 인스턴스 이름의 `EvalStr`는 따옴표 · 이스케이프 없이 그대로 찍힌다(`Tag['a''b']` 같은 형태 가능).
