# 0.4.10 이후 변경 (미릴리스)

0.4.10(2026-11-13) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

- `!T`의 `T`가 관리되는 타입(`str`, `[]T`, 객체)이면 값을 복사하지 못했다: `y := x`, `print(f())`, `Future[!str]`의
  `await`가 ``Expected type instance of `Result`, found `Ptr[!str]`.``(위치 `core:2918`)로 컴파일되지 않았다.
  `@copy`의 result 분기가 오류 값을 읽을 때 포인터를 역참조하지 않았다. 호스트가 `Future[!str]` · `Future[![]int]`를
  돌려주고 값이나 오류로 완료할 수 있다(F-119, tars-agent M0 스파이크).
- 세션(`persist_main`이나 `cl_vm_validate`로 이어지는 VM)에서 컴파일이 실패하면 다음 컴파일이 프로세스를 죽일 수 있었다
  (Segmentation fault). 실패한 컴파일이 코어 템플릿을 펼친 인스턴스(`[]str`의 `sort`, `Map[str, int]`의 메서드)는
  캐시에 남는데 본문 검사와 코드 생성은 버려진 chunk와 함께 사라졌고, 실패한 컴파일이 처음 불러온 모듈은 코드 없이
  모듈 캐시에 남았다. 이제 다음 컴파일이 그런 인스턴스의 본문을 다시 검사해 코드를 만들고, 그런 모듈은 다음 `use`에서
  다시 불러온다. 다시 검사한 본문이 컴파일되지 않으면(`Map[[]int, int]`처럼 앞의 오류 때문에 검사되지 않았던 것)
  그 인스턴스를 버리고 같은 소스를 다시 컴파일하므로, 그 오류가 관계없는 다음 eval에 보고되지 않는다. 같은 인스턴스를
  다시 쓰면 "because of an earlier error" 오류다. 첫 컴파일이 실패하면 VM을 리셋하는 것은 그대로다(F-120,
  tars-agent M0 스파이크).
- 범위식이 포함 끝과 방향을 잃었다. `a[1..=2]`가 `{2}`를 돌려줬고(이제 `{2, 3}`), `a[3..>1]`은 `InvalidArgument` panic이었다
  (이제 컴파일 오류 "A decreasing range can not be a slice index."). 값으로 쓴 `0..=3`은 `Range{start=0, end=3}`이었다
  (이제 `end=4`, `Range`는 끝을 포함하지 않는다). `3..>0` 같은 감소 범위는 `for` 밖에서 컴파일 오류다(F-121).

## 언어와 표준 라이브러리

- 타입 없는 목록 리터럴은 첫 원소 타입의 `[]T`다: `names := {'a.py', 'b.py'}`, `for {1, 2, 3} |n|:`. 전에는
  `TODO: infer tuple type` 오류였다. 빈 `{}`와 키-값 리터럴(`{a=1}`)은 여전히 목표 타입이 필요하고 그렇게 말하는 오류를 낸다.
- Map 리터럴의 키를 괄호로 감싸면 식으로 계산한다: `Map[str, int]{(k)=1, (k + '2')=2}`. 괄호 없는 이름은 전처럼 문자열 키다.
- `Map[str, int]{'app': 7}`은 "Expected `=` between a key and a value. An initializer uses `key=value`, not `key: value`."로,
  `for ['a', 'b'] |f|:`는 "A list literal uses braces: `{a, b}` or `[]T{a, b}`."로 원인을 알려 준다
  (전에는 `Expected closing brace.`, ``Expected `]`.``, F-122, tars-agent M0 스파이크).
- 스크립트 코드에서 `!T`를 풀지 않고 출력하면 컴파일 오류다: `print(f())`, `log(x)`, `'%{f()}'`는
  "Can not print `!str`. Unwrap it with `!` first, or handle the error with `!else` or `try`."를 낸다. 전에는 값 대신
  타입 이름(`!str`, `!int`)을 찍었다. 제네릭 코드(`%T`가 결과인 `test.eq` 등)는 성공 값이나 `error.Name`을 찍는다
  (F-124, tars-agent M0 스파이크 02).
- `for x in xs:`는 "A `for` loop is written `for xs |x|:` or `for 0..n |i|:`, not `for x in xs:`."를,
  `for 'a', 'b' |p|:`는 "To loop over values, put them in a list literal: `for {a, b} |x|:`."를 덧붙인다(전에는 `Expected :.`만).
  타입 오류 문구는 문법에 없는 이름 대신 쓰는 표기를 말한다: ``Expected `Vector` element type.``은
  ``Expected the element type of `[n]T`.``, `Slice` · `Span` · `PartialVector`도 `[]T` · `[&]T` · `[..n]T`로(F-125,
  tars-agent M0 스파이크 02).
- 없는 메서드 오류가 대신 쓸 이름을 말한다: ``Can not find the symbol `startsWith` in `str`. Did you mean `starts_with`?``.
  Python · JS 이름(`startswith`, `find`, `strip`, `push`, `toUpperCase`, `length` 등)은 Cyber 이름으로, camelCase는
  snake_case로, 나머지는 철자가 가까운 멤버로 찾는다. 대상이 그 타입에 있을 때만 말한다. `str.join`은 "`join` is a method
  of a list: `xs.join(sep)`.", `pop`은 "Use `last()` and `remove(i)`.", Map의 `items`는 `for m |e|:`를 알려 준다(F-126,
  tars-agent M0 스파이크 02).
- `str`에 `<` · `<=` · `>` · `>=`가 생겼다(바이트 순, `compare`와 같음). 전에는 `a.less(b)`만 됐다.
- 원소 타입에 `<`가 있으면 `xs.sort()`가 오름차순으로 정렬한다(`Slice` · `Span` · `Array`).
- `^T`나 `&T`를 캡처한 클로저와 `Func` 변수를 `sort`처럼 `&OpaqueFunc`를 받는 자리에 넘길 수 있다:
  `c := &counts` 뒤 `names.sort(|a, b| c[a] > c[b])`. 전에는 ``Expected argument `&OpaqueFunc[...]`, found `Func[...]` ``였다.
  일반 지역을 캡처하는 오류는 `^T`로 선언하거나 람다 앞에서 빌리라고(`b := &counts`) 안내한다. 일반 지역 캡처 자체는
  설계 검토 중이다(`docs/decisions/project_sort_closures.md`, F-127, tars-agent M0 스파이크 02).

## 임베딩 API

## 변경

- `not`의 우선순위를 Python과 같게 바꿨다: 비교보다 약하고 `and` · `or`보다 강하다. 전에는 뒤의 식 전체를 받아
  `not a and b`가 `not (a and b)`였고, 문서의 연산자 표에는 `not`이 없었다. 이제 `(not a) and b`다.
  `not a == b`는 여전히 `not (a == b)`다. 오류 없이 값이 바뀌므로 `not`을 `and` · `or`와 섞어 쓴 코드는 확인이
  필요하다(F-123, tars-agent M0 스파이크 02).

## 문서
