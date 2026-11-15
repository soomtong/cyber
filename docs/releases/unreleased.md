# 0.4.11 이후 변경 (미릴리스)

0.4.11(2026-11-14) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 언어와 표준 라이브러리

- 모델이 쓴 코드에서 나온 문구(tars-agent `docs/requests/cyber-0.4.11-codeact-messages.md`, 0.4.11 CodeAct 회차):
  - `for p |s| in {'a', 'b'}:`처럼 `|x|` 뒤에 `in`이 오면 ``Expected :.`` 대신 "A `for` loop has no `in`. The values come first
    and the name goes in `|x|`: `for {'a', 'b'} |s|:`."(범위 `for 0..n |i| in ...`도 같다).
  - `q: byte = 0`은 ``Unsupported block statement.`` 대신 "To declare a typed variable, write `var q byte = 0` or `q := byte(0)`."
    (값이 숫자 리터럴이 아니면 `var` 꼴만).
  - `in_s str = ''`처럼 `var` 없는 타입 선언은 ``Expected end of line or file. Got ident.`` 대신 "To declare a typed variable,
    write `var in_s str = ''`."
  - `out == none` · `out != none`의 왼쪽이 `none`을 담을 수 없는 타입이면 ``Expected `?T` to infer `none` value, found `str`.``
    대신 "`out` is `str`, which is never `none`. Compare with a value of the same type"(`str`이면 `out.len() == 0` 예시).
  - 옵션이 아닌 값의 `?else`는 ``Expected type instance of `Option`, found `bool`.``에 "This value is `bool`, not an option.
    Remove `?else false`."를 덧붙인다(`?else:` 블록이면 "Remove the `?else` block.").
  - `<` · `<=` · `>` · `>=`와 산술 · 비트 연산자의 오른쪽 타입이 맞지 않으면 ``Expected argument `str`, found `int`, when calling
    `fn >(str, str) -> bool`.`` 대신 연산자로 말한다: "Can not compare `str` with `int`. Convert one side: `int(i)` or `'%{0}'`.",
    "Can not apply `+` to `str` and `int`. To join them, write `'%{s}%{1}'`."(그 밖의 타입 쌍은 "Convert one side so that both
    have the same type.").
- 새 표준 모듈 `json` · `toon`(`docs/decisions/project_std_json_toon.md`):
  - `json`: RFC 8259 파서와 직렬화. 값은 choice `json.Value`(`null` · `bool` · `int` · `float` · `str` · `array` · `object`).
    `int`에 맞는 정수(소수부 · 지수 없음)는 `int`, 나머지 수는 `float`. 객체는 키 삽입 순서를 지키고 중복 키는 첫 위치에 마지막 값. `v['k']` ·
    `v[i]`는 없으면 `Value.null`, `get` · `at` · `as_*`는 옵션. `json.parse(src, &diag)`는 `json.Diag`에 줄 · 칸 · 이유를 남긴다
    (`error.Syntax`, UTF-8이 아니면 `error.Unicode`, 중첩 256단계). `json.stringify(v[, indent])`, 수는 최단 왕복 자릿수
    (`1e-6 <= |x| < 1e21`은 소수, 밖은 `1e+21`), NaN · 무한은 `null`. `json.encode(x)` · `json.from(x)`는 struct · 옵션 ·
    enum · choice · 슬라이스 · `Map`(키 정렬, `&map`으로 넘김)을 리플렉션으로 바꾼다. `Value.eq`는 JSON 모델 동등성.
  - `toon`: TOON 사양 v4.4(2026-10-08) 인코더 · 디코더. 표(`users[2]{id,name}:`) · 키 표(`env[2:]{region}:`) · 중첩
    필드 그룹 · 목록 형식, `EncodeOptions{indent, delim}`(`.comma` · `.tab` · `.pipe`), `DecodeOptions{indent, strict}`(비엄격
    복구 다섯 가지), 오류는 `error.Syntax`와 `json.Diag`. `toon.from_json` · `toon.to_json`. 공식 적합성 fixture 564개
    (`src/test/assets/toon-spec`, spec 커밋 `009074d`)를 모두 통과한다.
  - `json.to(T, v)` · `json.decode(T, src)`(각각 `&diag`를 받는 꼴도 있음): `Value`를 Cyber 타입으로 바꾼다(`from`의 반대). struct ·
    옵션 · enum · choice · 슬라이스 · `Map[str, V]` · 수 · `bool` · `str` · `Value` · `Object`. 옵션이 아닌 struct 필드가 없으면
    `error.MissingField`, 다른 종류의 값이나 모르는 case 이름은 `error.Type`, 범위 밖 수는 `error.Overflow`. 정수 타입은 정수인
    float(`3e2`)도 받는다. 필드가 아닌 멤버는 무시한다. `json.Diag`에 `path` 필드가 생겨 `$.users[1].id`처럼 실패한 자리를 적는다.
  - 큰 수 · 고정밀 수: `json.Value`에 `number`(JSON 원문 텍스트) case가 있다. `int`에 맞지 않는 정수와 `float` 범위 밖 수(`1e999`)는
    `number`로 읽어 손실 없이 다시 쓴다. `json.parse(src, json.ParseOptions{exact=true})`(`toon.DecodeOptions{exact=true}`)이면 소수 ·
    지수가 있는 수도 원문으로 둔다. `number_text()` · `json.fmt_number(text)`는 수를 한 꼴(`1.50` → `1.5`, `1e2` → `100`)로 쓰고,
    `eq`는 이 꼴로 비교한다. `as_float`는 가장 가까운 값(범위 밖은 `none`), `json.to`의 `str` 필드는 모든 수를 텍스트로 받는다.
    TOON 인코더는 `number`를 정규형으로 쓴다. TOON 참조 구현은 `float` 범위 밖 수를 문자열로 읽는데 여기서는 수다.
  - `?json.Value == none`처럼 `==`로 `Value`를 비교할 수는 없다(코어 `@eq`가 choice를 지원하지 않음). `?else` · `if ... |x|` ·
    `Value.eq`를 쓴다.
- 새 표준 모듈 `regex`(`docs/decisions/project_std_regex.md`, 매뉴얼 "Regular expressions."):
  - 역추적 없는 엔진(Pike VM)이라 검색 한 번이 입력 길이에 선형이다(`(a*)*b` 같은 패턴도). 문법은 ripgrep 기본 문법(Rust `regex`
    크레이트)의 부분집합이고, 컴파일되는 패턴은 거기서와 같은 것에 맞는다. Rust `regex`의 테스트 데이터 820개
    (`src/test/assets/regex-spec`)를 통과하고 ripgrep 15.2와의 차분 퍼징 23,000건에서 차이가 없었다.
  - `regex.compile(pat)` → `!Regex`. `is_match(s)`, `find(s[, start])` → `?Match{start, end, text}`, `find_all(s)`,
    `captures(s[, start])` → `?Captures`(`c[1]` · `c['name']`은 텍스트, `c.get(1)`은 `?Match`), `captures_all(s)`,
    `replace(s, repl)` · `replace_all(s, repl)`(`$1` · `${name}` · `$$`), `split(s[, limit])`, `regex.escape(s)`.
  - 받는 문법: 클래스(`[a-z]` · 중첩 · `&&` · `--` · `~~` · `[[:alpha:]]`), `\d \s \w`, `\p{L}` · `\p{Hangul}`(일반 범주 · 스크립트 ·
    `Alphabetic` 등), 반복과 lazy 꼴, `^ $ \A \z \b \B \b{start}` 등, 그룹과 이름 그룹, 플래그 `i m s U x`.
    `\w` · `\b` · `(?i)`는 Unicode 18.0 기준이라 `\w+`가 한글에 맞는다. 오프셋은 바이트, 매칭 단위는 코드포인트.
  - 받지 않는 것은 컴파일 오류(`error.Syntax`)이고 `regex.Diag{msg, pos}`가 대신 쓸 것을 말한다: look-around, backreference,
    `\Z`, `(?-u)` · `(?R)`, 그 밖의 `\p{..}` 속성. 프로그램이 32768 명령을 넘으면 `error.TooBig`, 중첩은 250단계까지.
  - ripgrep CLI와 다른 점: 줄 단위가 아니라 문자열 전체를 본다. `$`는 `(?m)`이 있어야 줄 끝이고 `\s` · `[^a]`가 줄바꿈에도 맞는다.

## 버그 수정

- `.?` · `!`로 임시 옵션 · 결과에서 꺼낸 관리 값(`str`, `[]T` 등)을 `==` · `!=`의 피연산자나 `for`의 대상으로 쓰면 해제되지
  않았다(`g().? == 'x'`, `for f()! |x|:`, `for v['items'].as_array().? |x|:`). 언랩이 값을 옮겨 오면서 결과를 주소 있는
  자리로 표시해, 빌림이 임시 지역을 만들지 않았다. 이제 옮겨 온 값은 임시 지역에 담겨 문장 끝에 해제된다(F-141).
- wasm32에서 `str.from_utf8` · `str.is_utf8` · `str(PtrSpan)`이 `panic: integer does not fit in destination type`으로 멈출 수
  있었다. 8바이트 칸의 위 32비트(쓰레기)까지 포인터로 바꿨다. 이제 아래 절반만 쓴다(F-143).

- `int.parse` · `Int[N].parse`가 넘침을 검사하지 않았다: `int.parse('99999999999999999999')`가 오류 없이 `7766279631452241919`였다.
  이제 `error.Overflow`를 돌려준다(`i8.parse('128')`도). 숫자가 아닌 글자는 넘침보다 먼저 `error.InvalidCharacter`. 문자열을 받는
  `int('...')`는 실패하면 0이므로 넘침도 0이다(F-142).
- `?T` · `!T`를 돌려주는 함수에서 `return -x`가 ``Can not find the symbol `-` in `!int`.``로 컴파일되지 않았고, `?i8`에서 `return -5`도
  `i8`로 맞춰지지 않았다. 이제 옵션 · 결과의 자식 타입으로 부정하고 감싼다(F-144).
- `x := f() !else ...`와 `!else |e|:` 블록이 호출이 돌려준 결과를 언랩할 때 페이로드를 복사해 `!Map[str, int]` 같은 복사할 수 없는
  타입에 `Cannot copy`였다(`!`는 됐다). 이제 옮긴다. 변수에 담긴 결과는 그대로 복사한다(F-145).
- `meta.access(T, name)`에 `%T type` 템플릿 인자를 넘기면 `Unsupported expansion of compile-time value of type: type`이었다. 이제 `T`의
  멤버를 찾는다(F-146).
- 원소가 256개 이상인 리터럴(`[]int{...}`, `[_]int{...}`, `Array[T]{...}`, `Map[K, V]{...}`)의 256번째부터의 원소가 틀린 값이었다
  (Release 빌드에서는 오류 없이, Debug · ReleaseSafe에서는 `panic: integer does not fit in destination type`). 이제 개수 제한 없이 맞다(F-147).
- private choice(`-type Shape enum`)를 복사하거나 해제하면 ``Can not access the private symbol `Tag` in `Shape`.``로 컴파일되지
  않았다. 이제 된다(F-148).

## 임베딩 API

- `cl_mod_bind_json` · `cl_mod_bind_toon` · `cl_mod_bind_regex`(`cyber.h`). 기본 로더는 `use json` · `use toon` · `use regex`를 바로 푼다. 직접 로더를 쓰는 호스트는
  다른 표준 모듈처럼 이 함수로 묶는다.

## 알려진 한계

- 기본 파싱(`exact` 없음)에서 17자리를 넘는 소수는 `float`으로 근사한다. 잃지 않으려면 `ParseOptions{exact=true}`.
- `json.to`는 struct 필드의 기본값(`x int = 3`)을 쓰지 않는다. 없는 필드는 옵션 필드만 허용한다.
