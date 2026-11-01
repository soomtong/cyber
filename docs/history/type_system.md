# 타입 시스템: 동적 · 정적 혼합에서 정적 전용으로

2026-11-01 작성. 개요는 `cyber_0_3_to_0_4_overview.md`.

## 0.3 상태 (2023-12)

- 동적 타입과 정적 타입을 같이 지원했다. `my a = 123`은 `dynamic` 타입, `var a = 123`은 추론된 정적 타입,
  `var a any = 123`은 정적 `any`다. `dynamic`은 타입 검사를 런타임으로 미루고 `any`는 컴파일 시점에 캐스트를 요구했다.
- "Recent type inference": `dynamic` 변수의 가장 최근 대입 타입을 컴파일러가 추적해 확실히 실패할 호출은 컴파일 에러로 냈다.
- 반환 타입을 안 쓰면 `dynamic`이었다. 함수 선언은 `func`.
- 사용자 타입은 `type Student object:` 하나였다. 필드는 `var name string`. 값 타입(struct)은 없었다. 인스턴스화는 `[Student:]`.
- 내장 타입: `bool` `float` `int` `string` `List` `Map` `error` `fiber` `any`. `none` 값이 있었고 Option(`Node?`)은 계획만 있었다.
- Traits · Union types · 함수 타입 캐스트가 모두 "Planned". 정적 변수는 `var Root.global Map = [:]`.
- CYON(Cyber 객체 표기) 직렬화 포맷이 언어의 일부였다.

## 구간 A에서 바뀐 것 (2024-01 ~ 2024-09)

| 날짜 | 커밋 | 변화 |
|---|---|---|
| 2024-01-12 | `843471f5` `ea23b5b0` | `type X object`의 `object`가 선택이 되고 곧 사라짐 |
| 2024-01-29 | `9d4eb7e2` | choice 타입(tagged union) |
| 2024-02-11 | `0c1132cd` `e2c38738` `516156af` `233f7c48` `3ea9f7ff` | 값 타입 struct, Option 타입, object · enum 템플릿(제네릭) |
| 2024-03-08 | `427755b0` `90838c9c` `9bb0f893` `211f6f1c` | `none` 값 제거 · `void` 타입, unwrap은 `Option(T)` 필수, `=`로 타입 별칭, 원시 타입을 struct로 바인딩 |
| 2024-03-10 | `f3bda254` | `func`는 항상 정적, 동적 함수는 `my` |
| 2024-03-24 | `4c4c1ac5` `9092ba68` `f02d6c50` | `my` → `let`, distinct type, 동적 객체는 `$set` · `$get`으로 |
| 2024-04-07 | `af2b1fc6` | 필드 · 심볼 가시성 `-` 접두사 |
| 2024-05-13 | `519f7039` `fccd1732` `b2e6aedb` `70b6a642` `489f16ee` | 함수 템플릿, `[]`로 템플릿 확장, `List` 템플릿, 동적 추론, 템플릿 특수화 |
| 2024-07-10 | `946ed790` `94bade94` | 포인터 타입, `int` 64비트 unboxed |
| 2024-08-25 | `d40d97fd` `6c29fa5a` `cb742d41` | 반환 기본 `void`, 함수 포인터 · 함수 union 타입, `metatype` → `type` |
| 2024-08-27 | `2a224217` | `let` → `dyn` |
| 2024-09-04 | `2e3ff392` | "recent type" 동적 추론 실험 제거 |
| 2024-09-20 | `35e84dd9` | 참조 타입을 값 타입에서 유도, object 타입 제거 |
| 2024-09-21 | `9a06dfc2` `0c5ddea5` `8305af03` | CYON 제거, unboxed enum, `TypeSym`으로 축소 |
| 2024-09-22 ~ 23 | `9bb9a495` `84df10db` `e80054e9` `c992b94e` | `string` 정리, `fn` · `Fn`, 동적 메서드 디스패치 제거, 동적 오버로드 호출 제거 |

`c992b94e` 시점의 문서는 "Dynamic Typing" 장을 아직 가지고 있었다. `dyn`은 남았지만 동적 메서드 디스패치와 동적
필드 접근은 금지됐고, 동적 객체는 내장 `Table`로, 동적 디스패치는 trait로 보내는 설명이었다. 그 장의 문장 하나가 방향을
요약한다. "그런 동작을 허용하면 불필요한 런타임 비용이 들고 tree shaking을 막고, 정적 타입과 다른 메모리 의미론이 이끄는
언어에 복잡성을 더한다."

## 구간 B에서 바뀐 것 (2025-11 ~ 2025-12)

`b751ca6c`에서 "Dynamic Typing" 장과 `dyn` · `any` · `def` · `mod` · `symbol` · `context` 키워드가 사라졌다.
`Table`은 타입으로 남아 있지만(`src/builtins/core.cy`의 `type Table`) 문서의 "Dynamic tables" 절은 없다.

## 0.4.2 현재 상태

- 선언: `a := 123`(추론), `var a int = 123`, `global`, `const`. 함수는 `fn`, 반환 기본 `void`.
- 기본 타입: `bool` `int` `byte` `float` `str` `symbol` `error`, Option `?T`, Result `!T`, 참조 `^T`, 빌림 `&T` · `&&T`,
  포인터 `Ptr[T]`, 벡터 `[N]T`, 부분 벡터 `[..N]T`, 슬라이스 `[]T`, `Array[T]`, `Map[K, V]`, 튜플.
- 사용자 타입: struct(기본), `cstruct` · `cunion`, enum, choice, trait, 타입 별칭, 타입 임베딩, `@init` · `@init_sequence` · `@init_record`,
  타입 네임스페이스(`Foo :: fn`), 연산자 메서드.
- 제네릭: `type C[T Any]` 템플릿, `const N int` 템플릿 매개변수, `type X const:` 타입 평가로 특수화.
- 동적 디스패치는 trait를 `Dyn[T]` 컨테이너에 넣어 `^Dyn[Shape]`로만 한다. 암시적 캐스트 규칙(`Implicit casts.`)이 문서화됐다.
- 테스트: `src/test/types`(choice · cstructs · enums · structs · template_* · trait · tuple · type_alias · type_embedding ·
  pointers · PtrSpan · bitcast · cast), `src/test/vars`(const · global · local).

## 미완 지점

- `docs/docs.md`의 TBD: Generic types 2곳, Type embedding, Optional chaining, Named parameters, Shorthand calls, No parameter calls,
  Mutable strings, Line-join literal.
- "Attributes." 절이 비어 있다. 속성은 `extern` `bind` `reserve` `cond` `generator` `unsafe` `consteval` `jit` 여덟 개이고
  `src/parser.zig`의 고정 목록으로 검사한다(`project_coroutines.md`).
- `Table`이 소스에 남아 있는데 문서에 없다. 유지할지 지울지 정해지지 않았다.

## fork의 결정 · 미결

- 결정: upstream 문법을 그대로 따른다. 바꿀 때는 호환을 깨지 않는 범위에서, `docs/decisions`에 먼저 적는다(`project_direction.md`).
- 미결: Attributes 문서, `Table`의 운명, Named parameters. 스크립트 CLI 용도에서는 Named parameters와 Optional chaining이
  먼저 쓰일 가능성이 크다.

## 해석

- 전환의 동기는 메모리 모델이다. 값 소유권과 빌림은 수명을 컴파일 시점에 알아야 하고, `dyn`은 그 전제를 깨뜨린다.
  A 구간 끝에서 동적 디스패치와 동적 오버로드 호출을 먼저 걷어낸 것은 B 구간의 소유권 도입을 준비한 것으로 읽힌다.
- 0.3이 내세운 "점진적 타입 추가"는 포기됐다. 대신 trait + `Dyn[T]`가 다형성을, choice가 합 타입을, 템플릿이 제네릭을 맡는다.
- 이름 변경이 많았던 것(`my` → `let` → `dyn`, `import` → `use`, `func` → `fn`, `object` → struct)은 설계가 흔들렸다는 뜻이기도 하다.
  fork가 문법을 추가할 때는 같은 흔들림을 반복하지 않도록 결정 문서를 먼저 쓴다.
