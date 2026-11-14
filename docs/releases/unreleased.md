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
- `^[]T`나 `&[]T` 지역에 `+=` 같은 복합 대입을 하면 메모리가 깨졌다. `out := ^[]str{}` 뒤 `out += 'x'`를 두 번 하면
  Segmentation fault, 한 번이면 붙지 않거나 길이가 쓰레기 값이었다(0.4.9부터). `x op= y`는 `x = x op y`인데, 이 경로만
  결과 타입을 대입 대상과 비교하지 않아 `+`가 돌려준 `[]T`를 `^[]T` 자리에 넣었다. 이제 일반 대입처럼 검사하고,
  결과가 가리키는 값의 타입이면 ``Expected type `^[]str`, got `[]str`. To change the value that `out` points to, write
  `out.* += ...`.``를 낸다. 가리키는 값을 바꾸려면 `out.* += 'x'`(F-128, tars-agent M0 스파이크 03).
- 문자열의 잘못된 이스케이프(`"TODO\|Todo"`, `'a\xZZ'`)가 세션을 지웠다. 오류가 위치 없는 `Error: InvalidEscapeSeq` ·
  `Error: InvalidCharacter`로 나왔고, 컴파일러가 이것을 할당 실패로 보아 다음 eval 앞에서 VM을 reset했다. `persist_main`
  세션의 변수, 함수, `use`가 모두 사라졌다. 이제 위치가 있는 컴파일 오류다: ``Invalid escape sequence `\|`. A backslash in a
  string is followed by one of: n t r 0 a b e \ ' " ` xHH. Write `\\|` for a backslash.`` 세션은 그대로다. reset은 실제 할당
  실패(`OutOfMemory`, `WriteFailed`, 할당자가 거절한 요청)에만 한다(F-131, tars-agent M0 요청서 1절).
- `'\0'`이 큰따옴표(0x22)였다. 이제 문서대로 NUL(0x00)이다(F-132, tars-agent M0 요청서 2절).
- 호스트 함수가 `cl_thread_ret`보다 먼저 매개변수를 읽으면(`cl_thread_str` 등) null 포인터를 읽어 죽었다. 이제 반환 슬롯은
  매개변수 앞이나 뒤 어디서 받아도 된다. 매개변수 사이에서 받으면 매개변수 읽기가 처음으로 돌아간다(`cyber.h`에 적음,
  F-133, tars-agent M0 요청서 5절).

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
- `deny_raw_ptrs`를 켠 VM에서 오버로드된 함수에 타입 없는 목록 리터럴을 넘기면(`s.trim({'a', 'z'})`) Debug 빌드가
  "Null type does not have a symbol." panic으로 죽었다. 오버로드를 고르는 동안의 타입 없는 인자를 원시 포인터 검사가 건너뛴다.
- `str`에 인자 없는 `trim()`이 생겼다. 양 끝의 공백, 탭, 줄바꿈을 자른다(Python `strip()`). 전에는 자를 문자가 필요했다.
- 원인만 말하던 오류 문구가 고치는 법을 덧붙인다(F-129, tars-agent M0 스파이크 03):
  - 처음 쓰는 이름에 `=`로 대입하면 ``Undeclared variable `report`. To declare a new variable, write `report := ...`.``
  - `else if c:`는 "Write `else cond:`, not `else if cond:`.", 괄호 없는 if 식(`if c a else b`)은
    "An `if` expression is written `if (cond) a else b`."
  - 처리하지 않은 `!void` 호출문은 "Add `!` after the call to unwrap it, or handle the error with `!else` or `try`."
  - `!T` · `?T`에서 `T`의 메서드를 부르면(`r().len()`) `!`나 `.?`로 먼저 풀라고 한다.
  - `!`를 `str`이나 `?int`에 붙이면 `!` · `!else` · `try`가 `!T`에 쓰인다는 것과 그 값에 맞는 연산자를 말한다(`?int`면 `.?` · `?else`). `.?`를 `!T`에 붙인 경우도 같다.
  - `opt ?else '' == 'x'`처럼 `?else` · `!else`의 기본값이 비교식이면 우선순위를 말하고 괄호를 권한다. 연산자 표에
    `?else` · `!else` 줄을 더했다(오른쪽이 식의 나머지 전부를 받는다).
  - `^int` · `&float` 같은 참조에 산술 · 비교 연산자를 쓰면(`n += 2`, `r < 2.0`) ``Cannot invoke the reserved function `int.+`.`` 대신
    ``Can not use `+` on `^int`. ... write `n.* += ...`.``처럼 역참조를 말한다. `Ptr[T]`의 포인터 산술은 그대로다.
  - 없는 필드(`s.length`)에도 메서드 제안을 한다: "Did you mean the method `len()`?" `rfind` · `rindex`는 `lastIndexOf`를 제안한다.
- 세션에 맞는 오류 문구(F-134, tars-agent M0 요청서 6절):
  - `persist_main` 세션의 최상위에서 일반 지역을 캡처하면 빌림을 최상위에 두라고 하지 않는다(최상위 `b := &x`는 eval 사이에
    유지되지 않는다): "Declare it with `^T`. Inside a function, you can also borrow it before the lambda ...".
  - `xs.len`처럼 메서드를 필드로 쓰면 ``Did you mean the method `len()`?``를 낸다(`[]T`는 내부 필드 `_len`을 제안했고 `str`은
    제안이 없었다). 밑줄로 시작하는 내부 멤버는 밑줄로 시작하는 이름에만 제안한다.
  - `not`을 `bool`이 아닌 값에 쓰면 ``Can not find the symbol `!` in `?int`.`` 대신 "`not` takes a `bool`. Found `?int`."와
    `x == none` · `if x |v|:` · `?else`(옵션), `!` · `!else` · `try`(결과) 안내를 낸다.
  - `to_upper` · `to_lower` · `uppercase` · `lowercase` · `toUpper` · `toLower`가 `upper` · `lower`를 제안한다. `to_` 접두사를 뗀
    이름이 그 타입에 있으면 그것을 제안한다.

## 임베딩 API

- `CLEvalConfig` · `CLCompileConfig`에 `deny_spawn`이 생겼다. 켜면 표준 모듈이 아닌 chunk의 `spawn` 호출이 컴파일 오류다:
  "`spawn` is not allowed. The host disabled threads for this script (`deny_spawn`). Use `fiber` or a `scope` block for
  concurrent work." 호스트 함수가 eval 스레드에서만 불린다. fiber와 `scope` 블록은 그대로 쓴다. 두 구조체에 필드가 하나
  늘었으므로 호스트는 다시 컴파일해야 한다(tars-agent M0 요청서 4절).
- `bool cl_vm_reset_pending(CLVM* vm)`: 다음 `cl_vm_eval` · `cl_vm_validate`가 reset된 VM에서 시작하는지 알려 준다(VM의 첫
  컴파일 실패, 컴파일러나 main 지역 이월 중의 할당 실패 뒤). `CL_SUCCESS`가 아닌 eval 뒤에 물어 세션을 다시 차린다
  (tars-agent M0 요청서 1절).
- `build.zig`가 라이브러리를 install 스텝으로 내보낸다. `build.zig.zon` 의존으로 받은 쪽이
  `b.dependency("cyber", .{ .target = target, .optimize = optimize, .static = true, .commit = @as([]const u8, "63e35e8") }).artifact("cyber")`로
  정적 라이브러리를 링크하고, `cyber.h`는 그 아티팩트의 include 경로로 따라온다. `ffi`는 `lib` 스텝처럼 기본 false다.
  `commit` · `build` 인자가 버전 문자열에 들어간다(`Cyber 0.4.10-DEV build-0-63e35e8`). 이 때문에 인자 없는 `zig build`가
  라이브러리를 빌드한다(tars-agent M0 요청서 3절).

## 변경

- `not`의 우선순위를 Python과 같게 바꿨다: 비교보다 약하고 `and` · `or`보다 강하다. 전에는 뒤의 식 전체를 받아
  `not a and b`가 `not (a and b)`였고, 문서의 연산자 표에는 `not`이 없었다. 이제 `(not a) and b`다.
  `not a == b`는 여전히 `not (a == b)`다. 오류 없이 값이 바뀌므로 `not`을 `and` · `or`와 섞어 쓴 코드는 확인이
  필요하다(F-123, tars-agent M0 스파이크 02).
- 타입 없는 목록 리터럴은 뒤 원소의 리터럴을 첫 원소의 타입으로 바꾸지 않는다. `{1, 'a'}`는 `{1, 97}`이 됐고(한 글자
  문자열이 정수 자리에서 코드 포인트가 됨) `{1.5, 2}`는 `[]float`이 됐다. 이제 둘 다 컴파일 오류다: ``Expected type `int`,
  got `str`. A list literal without a type takes the type of its first element and does not convert the others. Write the
  element type: `[]T{...}`.`` 타입을 쓴 `[]int{1, 'a'}` · `[]float{1.5, 2}`와 `var b byte = 'a'`는 그대로다(사용자 결정
  2026-11-14, F-135, tars-agent M0 요청서 7절).

## 문서
