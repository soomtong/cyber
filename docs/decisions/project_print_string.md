# `print` · `%{}`의 복합 값 표시

작성일 2026-11-04.

## 배경

`print` · `eprint` · `log` · 문자열 보간 `%{}` · `str.fmt`는 모두 core.cy의 `to_print_string(x %T)`를 거친다. 이 함수는
기본 타입 · enum · option · 포인터만 다루고 나머지는 `type.name(T)`를 돌려줘서 `print(Point{x=1, y=2})`가 `Point`만 찍었고,
choice는 `Shape@circle{}`처럼 payload 없는 형식이었다. REPL 결과 포매터(`project_repl_result.md`)가 타입 레이아웃을 걸어
값을 펼치게 된 뒤 `print`만 뒤처져 있었다.

core.cy에는 깊은 덤프용 `dump_str`가 있지만 여러 줄 형식이고 필드 값 대신 타입 이름을 찍는 등(`x: int`) 손질이 필요해
`print`의 기준으로 삼지 않았다.

## 결정

- struct(튜플 struct 포함)는 타입 이름을 붙인 레코드 리터럴 모양 `Point{x=1, y=2}`. 제네릭 인스턴스는 `Pair[str, int]{k='a', v=1}`.
  Python의 dataclass · Rust의 `Debug`처럼 타입 이름을 함께 보여 어떤 값인지 알 수 있게 했다.
- choice는 `Shape.circle(5)` · `Shape.rect(Point{x=1, y=2})`, payload가 `void`면 `Shape.empty`. REPL 포매터 · `dump_str`와
  같은 모양이고 `Shape@circle{}` 형식은 버렸다(문서 · 테스트에 참조 없음).
- Slice · Vector는 `{1, 2, 3}`. 시퀀스는 다른 언어처럼 타입 이름을 생략한다. REPL 포매터와 같다.
- 중첩된 문자열은 `{'a', 'b'}` · `Named{name='rex'}`처럼 따옴표를 유지한다. 최상위 `print('abc')`는 여전히 `abc`.
  이를 위해 `to_elem_string(x %T)`(비공개)을 두어 `str`과 `?str`만 따옴표를 붙이고 나머지는 `to_print_string`에 넘긴다.
- `^T`는 `^Point`처럼 타입 이름 그대로(순환 참조 · 중복 캐시 문제, 기존 테스트 `objects.cy`가 이 형식을 기대). `Ptr[T]`는 주소.
- 깊이 제한은 없다. 값 타입은 순환할 수 없고 ref는 펼치지 않으므로 끝난다.

`Map` · `Array`는 `NoCopy`라 `print(m)`이 값 매개변수 복사 단계에서 컴파일 오류가 난다("Cannot copy `Map[str, int]`").
`print`가 빌림(`&%T`)을 받게 하는 것은 호출 규약을 바꾸는 별개 과제라 여기서는 다루지 않았다.

## 구현

`src/builtins/core.cy` `to_print_string`: `type.is_instance_of(T, Slice)` 분기가 `for x |elem|`로 원소를 모으고,
`#switch type.info(T)`에 `.choice`(`switch meta.choice_tag(x)` 안에서 `#for meta.enum_values(T.Tag)`로 case를 펼치고
`#if meta.CasePayload[T, Tag] != void`일 때만 `meta.access_choice_case`로 payload를 꺼냄) · `.struct |info|`
(`info.fields`를 `#for`로 돌며 `meta.access(x, #{field.name})`) · `.vector |info|`(`for 0..#{info.len}`)를 더했다.
원소 문자열은 `[]str`에 모아 `join(', ')`한다.

테스트는 `src/test/modules/core.cy`의 `to_print_string()` 절(struct · 튜플 struct · 보간 · choice 세 형태 · Slice · Vector ·
option 원소 · 중첩 struct). 문서는 `docs/docs.md` "String interpolation." 절.
