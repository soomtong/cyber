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
  - `find_all` · `captures_all` · `replace_all` · `split`은 검색 버퍼를 한 번만 만들고, `replace_all`은 결과를 한 버퍼에 쌓아
    매치 수에 선형이다(`'ab1 '` 10만 번에 `[a-z]+\d` 치환 1.3초 → 0.3초).

- 새 표준 모듈 `peg`(`docs/decisions/project_std_peg.md`, 매뉴얼 "Parsing expression grammars."):
  - 규칙이 서로를 부르는 패턴(PEG)으로 겹친 괄호 같은 재귀 구조를 맞춘다. 문법은 LPeg `re` 모듈의 부분집합이고 받는 문법은
    거기서와 같은 뜻이다(LPeg 1.1.0과의 차분 퍼징 180,000건에서 차이 없음). 엔진은 LPeg식 parsing machine이라 VM 스택을
    쓰지 않는다. 선택 `a / b`는 순서가 있고 반복은 되돌아가지 않는다.
  - `peg.compile(grammar)` → `!Peg`. `parse(s)` → `!Capture`(입력 전체), `match(s[, start])` → `?Capture`(그 위치에서, 앞부분만
    맞아도 됨), `find(s[, start])`, `find_all(s)`, `replace(s, repl)` · `replace_all(s, repl)`(`$0` · `$1` · `${name}` · `$$`), `split(s)`.
  - 결과는 `peg.Capture{name, start, end, text, kids}`의 트리다. 캡처는 문법에서 감싼 모양대로 겹친다. `c[0]`은 자식의 텍스트,
    `c['name']`은 그 이름의 첫 자손의 텍스트(없으면 `''`), `c.get(name)` → `?Capture`, `c.all(name)` → `[]Capture`.
  - 받는 문법: `'text'`, `[a-z]` · `[^..]`, `.`, `%a %d %s %w ..`(ASCII)와 `%nl`, `p? p* p+`, `p^n` · `p^+n` · `p^-n`, `&p` · `!p`,
    `p1 / p2`, `name <- p`, 캡처 `{ p }` · `{:name: p :}` · `{}` · `{~ p ~}`(치환) · `p -> 'text %1'`(문자열), 역참조 `=name`,
    주석 `--` · `#`. 매칭 단위는 코드포인트, 오프셋은 바이트.
  - 컴파일 오류(`error.Syntax`, `peg.Diag{msg, pos, line, col}`): left recursion, 빈 문자열에 맞을 수 있는 것의 반복, 정의 없는 규칙,
    그리고 `re`에서 Lua 함수나 표가 필요한 것(`p -> name` · `p => name` · `{| p |}`).
  - `parse`가 실패하면 `error.NoMatch`이고 `Diag`가 가장 멀리 간 실패 위치와 그 자리에서 기대한 것을 말한다
    (``Expected `'('` or `%d` at line 1, column 8, found `)`.``, `diag.expected`). 반복은 표기와 상관없이 멈춘 자리에서 그 대상을
    기대 목록에 넣는다(`[a-z]+`와 `('a')*`가 같다).
  - `regex`와 달리 시간 보장이 없다(역추적). 한도: 매칭 스택 100000 항목(`error.TooDeep`), 캡처 100만 개 · 프로그램 65536 명령
    (`error.TooBig`), 문법 중첩 250단계. `match` · `find` 계열은 실행 중 한도를 넘으면 panic이다.
  - `re`와 다른 점: 리터럴과 클래스에 이스케이프가 있다, `{:name: p :}`가 결과의 노드다, `=name`은 그 캡처가 맞은 텍스트 전체와
    비교한다(`re`는 그 안의 첫 캡처 값), 닿지 않는 규칙과 대안의 left recursion도 거부한다. `=name`이 찾는 캡처는 `re`와 같다:
    마지막으로 닫힌 그 이름의 캡처이고, 그 안에 같은 이름의 캡처가 있어도 바깥 것이다(`{:n: 'a' {:n: 'b' :} :} =n`은 `abab`에 맞는다).
  - UTF-8이 아닌 바이트는 매칭에서도 `find_all` · `split` · `replace_all`의 빈 매치 뒤 이동에서도 한 단위다.

- 새 표준 모듈 `time`(`docs/decisions/project_std_time.md`, 매뉴얼 "Dates and times."):
  - 타입 넷: `Time`(순간) · `DateTime`(순간 + UTC 오프셋) · `Date`(달력 날짜) · `Duration`(길이). 시간대는 UTC와 고정 오프셋이고
    오프셋은 UTC 동쪽이 양수인 분 단위 `int`다(`+09:00`은 540, `-03:30`은 -210, 범위 ±23:59). 로컬 시간대와 오프셋 없는
    datetime은 없다. 달력은 proleptic Gregorian, 연도 1..9999, 윤초는 세지 않는다(글의 `:60`은 `:59`로 읽는다).
  - 시계: `time.now()` → `Time`, `time.monotonic()` → `Duration`(단조, 차이만 뜻이 있다).
  - `Time`: `time.unix(sec[, nsec])` · `unix_millis(ms)`, `t.unix()` · `unix_millis()` · `subsec_nanos()`, `t + d` · `t - d` · `t - u`(→ `Duration`),
    비교 연산자, `t.add(d)` → `!Time`, `t.utc()` · `t.to_offset(m)` → `DateTime`, `t.format([fmt])`.
  - `DateTime`: `time.datetime(y, mo, d, h, mi, s[, nsec, offset])`, 접근 메서드(`year()` ... `offset()` · `weekday()` · `day_of_year()` ·
    `date()` · `time()`), `to_offset(m)`(같은 순간) · `replace_offset(m)`(같은 시계 값), `add(d)` · `add_days(n)` · `add_months(n)` ·
    `add_years(n)`, `format([fmt])`. `==`는 오프셋까지 비교하고 순서 연산자는 없다(`a.time() < b.time()`).
  - `Date`: `time.date(y, m, d)`, `d - e`(일수), 비교, `add_days` · `add_months` · `add_years`, `weekday()` · `iso_weekday()` ·
    `iso_week()` · `day_of_year()`, `at(h, mi, s[, nsec, offset])`. 월 · 년 덧셈은 말일로 clamp한다(01-31 + 1개월 = 02-29).
  - `Duration`: `time.nanos` · `micros` · `millis` · `seconds` · `minutes` · `hours` · `days`, `+ - *` · 단항 `-` · 비교, `secs()` · `millis()` ·
    `subsec_nanos()` · `to_float()` · `abs()` · `format()`(`1h2m3.5s`).
  - 파싱: `time.parse(s)`는 RFC 3339(오프셋 필수. 공백 구분자 · `,` 소수점 · `Z` · `+09:00` · `+0900` · `+09`), `time.parse(s, offset)`은
    오프셋 없는 글을 그 오프셋으로, `time.parse_format(s, fmt[, offset])`은 strptime 형식으로, `time.parse_date(s)`는 `YYYY-MM-DD`.
    형식 지정자는 strftime의 부분집합(`%Y %y %m %d %e %j %b %B %a %A %H %I %p %M %S %f %3f %6f %9f %z %:z %F %T %R %D %s` ...).
  - 오류: `error.Syntax`(글이 다름) · `error.Range`(값이 범위 밖) · `error.Format`(형식 문자열), 문구와 위치는 `time.Diag{msg, pos}`.
    연산자 `+` · `-`는 범위를 넘으면 panic, 이름 있는 메서드는 `error.Range`.
  - `os.FileInfo`에 `mtime()` · `atime()` · `ctime()` → `!time.Time`. 정수 칸(`mtime_sec` ...)은 그대로다.
  - Python `datetime`과의 차분 시험 78,000건(달력 분해 · 요일 · ISO 주 · `strftime` · 파싱 왕복 · 월 덧셈)에서 차이가 없었다.

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
- 괄호 묶음이 식 중간에서 왼쪽 피연산자일 때 그 뒤의 연산자를 모두 가져갔다. `a - (b) / 2 + 1`이 `a - ((b) / 2 + 1)`로,
  `-(2) + 5`가 `-((2) + 5)`로 계산됐다(타입이 맞으면 오류 없이 다른 값). 이제 묶음 앞 연산자의 우선순위대로 묶인다(F-154).
  식의 맨 앞 묶음(`(a) + b`)과 괄호 없는 식은 전부터 맞았다. 이 꼴에 기대던 코드는 값이 달라진다.
- 줄바꿈 없이 끝나는 파일의 마지막 줄이 `x: int = 5` · `x int = 5` · `x: int =`이면 타입 선언 안내 대신 컴파일러가
  `panic: index out of bounds`로 멈췄다. 이제 안내를 보여 준다(F-149).
- `json.encode` · `json.from`이 2^63 이상인 `r64`를 음수로 썼다(`r64.ones` → `-1`). 이제 `18446744073709551615`처럼
  부호 없는 수(`number`)로 쓰고, `json.to(r64, v)`도 2^63 이상을 읽는다(F-150).
- `ParseOptions{exact=true}`로 읽은 `1E-99999999999999999999`를 `json.to(int, v)`하면 `error.Type`이 아니라 `error.Overflow`였다.
  대문자 `E` 지수도 소문자와 같이 다룬다(F-151).
- 컴파일 타임 인자의 타입이 맞지 않아 컴파일 오류가 날 때(`type.size('s')`) 그 인자 값이 해제되지 않았다(F-153).
- wasm32에서 `io`의 줄 읽기가 F-143과 같은 이유로 `panic: integer does not fit in destination type`으로 멈출 수 있었다(F-152).

## 임베딩 API

- `cl_mod_bind_json` · `cl_mod_bind_toon` · `cl_mod_bind_regex` · `cl_mod_bind_peg` · `cl_mod_bind_time`(`cyber.h`). 기본 로더는 `use json` · `use toon` · `use regex` · `use peg` · `use time`을 바로 푼다. 직접 로더를 쓰는 호스트는
  다른 표준 모듈처럼 이 함수로 묶는다.

## 알려진 한계

- 기본 파싱(`exact` 없음)에서 17자리를 넘는 소수는 `float`으로 근사한다. 잃지 않으려면 `ParseOptions{exact=true}`.
- `json.to`는 struct 필드의 기본값(`x int = 3`)을 쓰지 않는다. 없는 필드는 옵션 필드만 허용한다.
