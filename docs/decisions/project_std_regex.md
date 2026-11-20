# 표준 모듈 `regex` (2026-11-15)

## 배경

로그와 명령 출력에서 값을 뽑는 스크립트가 `str` 메서드(`index` · `split` · `trim`)만으로는 길어진다. 표준 라이브러리에
정규식이 없다(`project_tars_agent_runtime_review.md` "없는 순수 라이브러리"). 요구는 셋이다.

- 역추적 없는 엔진. 입력 길이에 선형인 시간을 보장한다(에이전트가 쓴 패턴과 외부 입력을 그대로 돌린다).
- 외부 라이브러리 없이 직접 쓴다.
- 문법은 ripgrep 기본 문법(= Rust `regex` 크레이트 문법)의 부분집합.

구현 전에 Rust · Zig · Nim · Python의 방식과 스펙을 1차 자료로 비교했다(아래). 버전은 2026-11-15 기준이다.

## 비교 검토

### Rust `regex` 1.13 (ripgrep의 기본 엔진)

- 구조: 패턴 → AST → HIR → Thompson NFA. `Regex`는 `regex-automata`의 meta 엔진을 감싼다. 리터럴만이면 부분 문자열 검색,
  일치 범위는 lazy DFA, 캡처는 one-pass DFA → bounded backtracker(짧은 입력) → PikeVM 순으로 고른다. 리터럴 prefilter가 있다.
- 보장: "all regex searches in this crate have worst case O(m * n) time complexity". `m`은 횟수 반복을 펼친 뒤의 크기
  (`\w{5}` → `\w\w\w\w\w`), 보장은 검색 한 번에 대한 것이고 `find_iter`는 O(m * n^2)까지 간다. 컴파일은 O(m).
- 한도: `size_limit` 10 MiB(넘으면 `CompiledTooBig`), `nest_limit` 250. 오류는 `Syntax(String)` · `CompiledTooBig` 둘.
- 문법: `.`, 클래스(`[a-z]` · `[^x]` · 중첩 · `&&` · `--` · `~~` · `[[:alpha:]]`), `\d \s \w`(기본 Unicode), `\pL` · `\p{Greek}`,
  반복 `* + ? {n} {n,} {n,m}`과 lazy 꼴, 단언 `^ $ \A \z \b \B \b{start} \b{end} \b{start-half} \b{end-half}`(`\<` · `\>`),
  그룹 `(..)` · `(?:..)` · `(?P<n>..)` · `(?<n>..)`, 플래그 `i m s R U u x`(`u`만 기본 켜짐), 이스케이프 `\x7F \x{..} \u{..}`.
  look-around와 backreference는 없다(선형 시간 보장 때문). `\Z`도 없다. 8진 이스케이프는 기본 꺼짐.
- 의미: leftmost-first(`sam|samwise`는 `sam`). 오프셋은 바이트. `&str` 정규식의 빈 일치는 코드포인트를 쪼개지 않는다.
  반복 검색에서 직전 일치의 끝과 겹치는 빈 일치는 버린다(`a|(?:)`를 `a`에 돌리면 `[0,1)` 하나).
  `$`는 `(?m)`이 아니면 입력의 끝에서만 맞는다. 대소문자 무시는 Unicode simple case folding.
- API: `Regex::new`, `is_match`, `find` · `find_at` → `Option<Match>`, `find_iter`, `captures` → `Option<Captures>`, `captures_iter`,
  `replace` · `replace_all` · `replacen`, `split` · `splitn`(캡처를 결과에 넣지 않음), `captures_len`, `capture_names`, `escape`.
  `Match`는 `start` · `end` · `as_str`, `Captures`는 `get(i)` · `name(s)` · `caps[i]` · `caps["n"]` · `expand`.
  치환 문자열은 `$1` · `${name}` · `$$`(`$1a`는 그룹 `1a`. 없는 그룹은 빈 문자열), `NoExpand`와 클로저도 받는다.
  옵션은 `RegexBuilder`(플래그와 한도). `RegexSet`, 바이트용 `regex::bytes`.
- `regex-lite`: 같은 API와 O(m * n) 보장을 PikeVM 하나로 준다. 버린 것은 `\p{..}`, Unicode `\d \s \w \b`(ASCII만),
  Unicode case folding, 클래스 집합 연산. 코드포인트 단위 매칭과 나머지 문법은 그대로다. 작은 구현의 기준선이다.
- ripgrep이 더하는 것(크레이트가 아니라 CLI의 동작): 줄 단위 검색이라 패턴이 `\n`에 맞지 못하게 막고(`\s`에서 `\n` 제거,
  리터럴 `\n`은 오류), `multi_line`을 항상 켠다. `-U`로 풀고, `-S` smart case와 `-P`(PCRE2)는 선택이다.

### Zig 0.17

- std에 정규식이 없다. 방침을 밝힌 이슈나 제안도 찾지 못했다(std는 작게 두고 패키지로 푸는 쪽이 통념).
- 생태계는 작은 구현 여럿이고 표준 격은 없다.
  - `tiehuis/zig-regex`: PikeVM과 backtracking VM을 입력 크기로 골라 쓴다. 바이트 단위(UTF-8 미지원), `(?:..)` · 이름 그룹 ·
    플래그 · POSIX 클래스 없음. 반복 한도 1000. `compile(alloc, re)`, `match`(전체) · `partialMatch` · `captures`.
  - `mnemnion/mvzr`: 할당 없는 backtracking 바이트코드 VM, comptime 컴파일 가능, 캡처 · 플래그 · Unicode 없음.
    기본 64 op · 8 charset. "공격자가 정하는 패턴에는 부적합"이라고 적었다. `match` · `isMatch` · `iterator`.
  - `alexnask/ctregex.zig`: comptime에 패턴을 매처 코드로 펼친다. 유지 멈춤(2023).
  - `quangd42/regex.zig`(2026): PikeVM만, O(m * n), leftmost-first, 플래그 `i m s U`, 이름 그룹, ASCII 전용.
- 시사점: Zig 쪽에서 가져다 쓸 엔진이 없으니 직접 쓴다. 선형 시간을 말하는 구현은 모두 PikeVM이다. Unicode 속성 표도
  std에 없어 UCD에서 직접 만든다.

### Nim 2.4 · Nimony

- `std/re` · `std/nre`: PCRE1 8.36 래퍼(동적 로딩). backtracking이고 2.4 문서에서 둘 다 deprecated(PCRE1 수명 종료).
  `re`는 `find(s, pat, matches)` · `=~` 템플릿 · `replacef` · `MaxSubpatterns = 20`, `nre`는 `find` → `Option[RegexMatch]`,
  `m.captures[i]` · `m.captures["name"]` · `captureBounds`.
- `nitely/nim-regex`(2.4의 `std/nre2`가 이 위에 있다): 순수 Nim NFA, "match time is linear in the length of the text and the
  regular expression". Unicode `\d \w \s` · `\p{Greek}`, 플래그 `i m s U u x`, 이름 그룹. backreference는 보장 때문에 없다.
  look-around는 받지만 반복이 들면 다항 시간. `re2"..."`(컴파일 타임 가능), `match`(전체) · `find` · `findAll` · `replace`(`$N`,
  `limit`) · `split` · `splitIncl`, `group(m, i)`는 범위(`Slice[int]`). 잘못된 UTF-8은 release 빌드에서 undefined behavior.
- `std/pegs`(PEG, 순서 있는 선택) · `std/strscans`(`scanf` 꼴 추출 매크로)가 정규식 아닌 대안으로 std에 있다.
- Nimony `lib/std/rex.nim`: PCRE를 버리고 DFA. longest match(`a|ab`가 `ab`), "결정적" 패턴만 받고(`.*x`는 오류) lazy ·
  플래그 · 이름 그룹 · `\p{L}`이 없다. 선형이지만 Perl 계열 의미(leftmost-first)와 다르다.
- 시사점: 외부 C 라이브러리 의존은 수명 문제를 남겼고, 대체물은 순수 구현 + 선형 시간 + Rust 계열 문법으로 갔다.

### Python `re` 3.15

- 엔진 `sre`는 backtracking. 시간 한도 · 단계 한도가 없다. 3.11에 possessive 수량자와 atomic 그룹을 더해 폭발을 사용자가
  막게 했다. look-around, backreference(`\1`, `(?P=name)`), 조건부 그룹이 있다.
- Rust와 갈리는 곳: 이름 그룹은 `(?P<n>..)`만, `$`가 마지막 줄바꿈 앞에서도 맞음, `\Z`(3.14부터 `\z`도), 플래그 `re.A` ·
  `re.L`, 전역 인라인 플래그는 패턴 맨 앞에서만, `\p{..}` 없음(3.16 예정), `(?<n>..)` 오류.
- 빈 일치: "Adjacent empty matches are not possible, but an empty match can occur immediately after a non-empty match."
  `sub('x*', '-', 'abxd')`는 `-a-b--d-`(Rust 규칙으로는 `-a-b-d-`).
- API: 모듈 함수 `search` · `match`(앞 고정) · `fullmatch` · `findall` · `finditer` · `split`(캡처도 결과에 넣음) · `sub` · `subn` ·
  `escape`와 컴파일 캐시(512개). `findall`은 그룹 수에 따라 반환 꼴이 바뀐다. `Match`는 `group` · `groups` · `groupdict` · `span` ·
  `m[1]`. 치환은 `\1` · `\g<name>` 또는 함수. 오류는 `re.PatternError(msg, pattern, pos)`.
- 시사점: LLM이 쓰는 패턴은 Python 꼴이 많다(`(?=..)`, `\1`, `\Z`, `(?P=n)`). 받지 않는 문법의 오류 문구가 대안을 말해야 한다.

### 요약

| | Rust `regex` | Zig | Nim | Python `re` |
|---|---|---|---|---|
| std 포함 | 아님(사실상 표준 크레이트) | 없음 | PCRE1 래퍼(deprecated) → `nre2` | 있음 |
| 엔진 | NFA 계열 여럿(meta) | 패키지마다 다름 | PCRE → 순수 NFA | backtracking |
| 시간 보장 | O(m * n) | PikeVM 구현만 | `regex`는 선형 | 없음 |
| look-around · backref | 없음 | 없음 | look-around만 | 있음 |
| 기본 Unicode | 예(`\w` · `\b` · `(?i)` · `\p`) | 대부분 바이트 | 예 | 예(`\p` 없음) |
| 일치 선택 | leftmost-first | leftmost-first | leftmost-first(Nimony는 longest) | leftmost-first |
| 캡처 접근 | `caps[1]` · `caps["n"]` · `get` | `sliceAt(n)` | `captures[i]` · `group(m, i)` | `m[1]` · `m.group('n')` |
| 치환 문법 | `$1` · `${n}` · `$$` | 없음 | `$N` | `\1` · `\g<n>` |
| `split`의 캡처 | 넣지 않음 | 없음 | 넣지 않음(`splitIncl` 별도) | 넣음 |
| 오류 | `Syntax(msg)` · `CompiledTooBig` | 오류 집합 | `RegexError` | `PatternError(msg, pos)` |

## 결정

1. 기준은 Rust `regex`. 받는 패턴은 ripgrep과 같은 뜻으로 맞고, 받지 않는 문법은 컴파일 오류다(조용히 다르게 맞지 않는다).
   줄 단위 동작은 ripgrep CLI의 것이라 따르지 않는다: `\n`도 맞고, `^` · `$`는 `(?m)`이 있어야 줄 경계다.
2. 엔진은 PikeVM 하나(Thompson NFA 시뮬레이션, 스레드 우선순위로 leftmost-first, 캡처 슬롯). `regex-lite` · `quangd42/regex.zig` ·
   `nim-regex`와 같은 선택이다. 검색 한 번은 O(m * n), `m`은 횟수 반복을 펼친 프로그램 크기. DFA · backtracker는 두지 않는다.
   빨리 가는 길은 둘만 둔다: 패턴이 요구하는 리터럴 접두사를 부분 문자열 검색(SIMD)으로 건너뛰기, `\A` · `^`로 시작하는
   패턴의 조기 종료.
3. 나눔: 파서와 컴파일러는 Cyber(`src/std/regex.cy`), 매칭 루프와 Unicode 표는 Zig(`src/std/regex.zig`) 바인딩.
   `json` · `toon`은 순수 Cyber였지만 PikeVM 단계는 VM에서 1 MB · 스레드 4개에 약 160 ms(캡처 복사 전)로 측정돼 로그 크기
   입력에 느리다. `project_std_json_toon.md` "성능"이 적은 순서(바이트 스캔을 Zig로)와 같다. 프로그램은 `[]int` 하나로 넘긴다.
   Zig 쪽은 호출마다 작업 메모리를 잡고 놓으며 상태를 들지 않는다. 일정 바이트마다 VM의 interrupt 표시를 본다.
4. Unicode는 Rust 기본과 같게 둔다(`regex-lite`처럼 ASCII로 줄이지 않는다). 한글 로그에서 `\w+` · `\b`가 ripgrep과 다르게
   맞으면 "같은 뜻" 원칙이 깨진다. 매칭 단위는 코드포인트, 오프셋은 바이트. `\d \s \w \b`와 `(?i)`(simple case folding)는
   Unicode, `\p{..}`는 General_Category · Script와 몇 가지 이진 속성. 표는 UCD에서 생성해 Zig 소스로 둔다.
   UTF-8이 아닌 바이트는 어떤 클래스에도(`.` · 부정 클래스 포함) 맞지 않는 한 단위로 지나간다(ripgrep의 Unicode 모드와 같다).
   `u` 플래그는 끌 수 없다(`(?-u)`는 오류. ASCII만 원하면 `[0-9]` · `[[:alpha:]]`).
5. 받지 않는 것: look-around, backreference, possessive · atomic, `\Z`, 조건부, 8진, `(?R)`(CRLF) · `(?-u)`, `\p{..}`의 그 밖의 속성
   (Script_Extensions · Age · Emoji 등). 오류 문구는 무엇이 안 되고 대신 무엇을 쓰는지 말한다(Python 꼴 패턴 대비).
6. 오류: `regex.compile(pat) -> !Regex`. 오류 값은 `error.Syntax`와 `error.TooBig`(Rust의 두 variant). 위치와 문구는 `json`처럼
   호출자가 넘기는 `regex.Diag{msg, pos}`(Zig `Diagnostics`, Python `PatternError.pos`).
7. 한도: 프로그램 명령 수(Rust `size_limit`에 해당)와 중첩 깊이(Rust 250). 값은 아래 "한도".
8. API는 Rust의 이름과 나눔(`find`는 범위만, `captures`는 그룹까지)을 따르고, 반복자 대신 슬라이스를 돌려준다
   (`find_all` · `captures_all`. Python `findall`처럼 그룹 수에 따라 꼴이 바뀌지 않는다). 치환은 ripgrep `-r`과 같은 `$1` · `${name}` · `$$`.
   `split`은 Rust처럼 캡처를 넣지 않는다. 반복 검색의 빈 일치는 Rust 규칙.
   모듈 수준 지름길(`regex.find(pat, s)`)과 패턴 캐시(Python)는 두지 않는다: 컴파일 오류가 숨고 캐시는 전역 상태다.
   옵션 구조체(`RegexBuilder`)도 두지 않는다: 플래그는 패턴 안에 `(?i)`로 쓴다(`nre`와 같다).
9. 받지 않기로 한 대안: C 라이브러리 래퍼(PCRE2 · POSIX. Nim이 겪은 수명 문제, wasm · 정적 빌드, backtracking),
   Nimony식 longest-match DFA(Perl 계열 의미와 달라 ripgrep 패턴이 다르게 맞는다), PEG · scanf 꼴(다른 문법이라 요구와 다름).

## 문법

| 종류 | 받는 것 |
|---|---|
| 문자 | 리터럴, `.`(`\n` 제외, `(?s)`면 전부), `\a \f \t \n \r \v`, `\x7F` · `\x{10FFFF}` · `\u007F` · `\u{..}` · `\U0000007F` · `\U{..}`, 구두점 이스케이프(`\.` · `\*` ...) |
| 클래스 | `[abc]` · `[^abc]` · `[a-z]`, 중첩 `[a[^b]]`, 집합 연산 `&&` · `--` · `~~`, `[[:alpha:]]` · `[[:^alpha:]]`(14종), `\d \s \w \D \S \W`, `\pL` · `\p{Lu}` · `\p{Hangul}` · `\p{sc=Greek}` · `\P{..}` |
| 반복 | `* + ?`, `{n}` · `{n,}` · `{n,m}`, 각각의 lazy 꼴(`*?` ...), 겹친 반복(`a?+`는 `(?:a?)+`) |
| 단언 | `^ $`(`(?m)`이면 줄), `\A \z`, `\b \B`, `\b{start}` · `\b{end}` · `\b{start-half}` · `\b{end-half}`, `\<` · `\>` |
| 그룹 | `(..)`, `(?:..)`, `(?P<name>..)` · `(?<name>..)`, `(?flags)` · `(?flags:..)` |
| 플래그 | `i`(대소문자 무시) · `m`(줄 단위 `^ $`) · `s`(`.`이 `\n`도) · `U`(greedy 뒤집기) · `x`(공백 · `#` 주석 무시) |

## API

```text
use regex

re := regex.compile(`(?P<key>\w+)=(\d+)`)!
re.is_match(s)                  --> bool
re.find(s)                      --> ?Match          Match{start, end, text}
re.find(s, start)               --> ?Match          start 바이트 위치부터(단언은 전체 입력을 본다)
re.find_all(s)                  --> []Match
re.captures(s)                  --> ?Captures
re.captures(s, start)           --> ?Captures
re.captures_all(s)              --> []Captures
caps[0]  caps[2]  caps['key']   --> str             참여하지 않은 그룹은 '', 없는 그룹은 panic
caps.get(2)  caps.get('key')    --> ?Match          참여하지 않았으면 none
caps.len()                      --> int             그룹 수(0번 포함)
re.replace(s, repl)             --> str             첫 일치만
re.replace_all(s, repl)         --> str
re.split(s)                     --> []str
re.split(s, limit)              --> []str           조각이 limit개를 넘지 않게
re.captures_len()               --> int             그룹 수(0번 포함)
re.capture_names()              --> []str           번호 순, 이름 없는 그룹은 ''
re.pattern()                    --> str
c.expand(repl)                  --> str
regex.escape(s)                 --> str

var diag regex.Diag = {}
re2 := regex.compile(pat, &diag) !else |err|: ...   -- diag.msg, diag.pos
```

## 한도

- `MaxInsts` 32768: 프로그램 명령 수. 넘으면 `error.TooBig`(Rust `CompiledTooBig`). 반복 횟수 하나도 이 값을 넘지 못한다.
  Unicode 클래스가 명령 하나라(Rust는 UTF-8 오토마톤으로 펼친다) `\w{30000}`도 들어간다. 아무것도 내지 않는 반복
  (`(?:(?:){30000}){30000}`)은 코드 생성의 방문 횟수(`MaxInsts * 8`)로 막는다.
- `MaxDepth` 250(Rust `nest_limit`과 같은 값): 그룹 · 클래스 · 반복의 중첩. 파서와 코드 생성이 재귀라 VM 스택을 지킨다.
- 검색 한 번의 작업 메모리는 명령 수 × 슬롯 수에 비례한다(스레드마다 캡처 슬롯 한 줄). `is_match`는 슬롯 0, `find`는 2.

## 구현

- `src/std/regex.cy`: 파서(재귀 하강, 플래그는 그룹 범위) → 노드(`[]Node`, 자식은 번호) → 명령. 프로그램은 `[]int` 하나:
  머리 8칸 · 리터럴 접두사 · 집합 · 명령(`op, a, b` 세 칸). `Regex`의 필드는 private이라 사용자가 프로그램을 지어낼 수 없다.
- `src/std/regex.zig`: `exec(prog, hay, start, skip, slots)` 하나가 검색이다. 스레드 목록 둘(sparse set + 슬롯 표), 엡실론 닫힘은
  명시적 스택(`regex-lite` `pikevm.rs`의 구조). 일치하면 그보다 우선순위가 낮은 스레드를 버리고, 살아 있는 스레드가 끝나면 멈춘다.
- 클래스는 명령 하나다. 집합은 후위 식(`range` · `table` 잎과 `or` · `and` · `diff` · `xor` · `not`)이고 ASCII 128자는 컴파일 때
  비트맵 두 칸으로 미리 계산한다(`set_ascii`). 그래서 중첩 클래스와 집합 연산이 식 그대로 들어가고 Cyber 쪽에 범위 대수가 없다.
  `(?i)`는 잎에서 접는다: 잎이 코드포인트의 simple case folding 궤도 중 하나에라도 맞으면 참. Rust가 잎(과 연산자의 양쪽)을 먼저
  접고 연산하는 순서와 같다. `(?i)`의 리터럴 글자는 범위 하나짜리 집합이다.
- Unicode 표: `src/tools/gen_regex_unicode.cy`가 UCD(18.0.0)에서 `src/std/regex_unicode.zig`를 만든다. 표 220개(일반 범주 30 +
  묶음 8, 스크립트 177, `Alphabetic` · `Lowercase` · `Uppercase` · `White_Space`, `\w`), 범위 10692개, 이름 436개(별칭 포함,
  느슨한 비교), 접기 궤도 3035칸. 표 데이터는 약 110 kB다(한 칸 8바이트). `\w`는 Rust와 같이 Alphabetic + M + Nd + Pc + Join_Control.
- `e*`에서 `e`가 빈 문자열에 맞을 수 있으면 `(e+)?`로 낸다(Rust NFA 컴파일러와 같다. 대안의 우선순위가 지켜진다).
- 반복 검색의 빈 일치 건너뛰기는 Zig 쪽 `skip` 인자가 코드포인트 하나를 넘긴다. 코드포인트 안에서 시작하는 `start`는 그 끝으로 민다.
- 리터럴 접두사: 첫 명령부터 `save` · 단언 · `char`만 이어지는 동안의 글자(64바이트까지). 살아 있는 스레드가 없으면 `str.index`와
  같은 SIMD 탐색으로 건너뛴다. `(?i)`의 글자는 집합이라 접두사가 되지 않는다.
- interrupt: 16384 단계마다 스레드의 interrupt 표시를 보고, 서 있으면 결과 없이 돌아간다(`exec_`가 -1, 일치 1, 없음 0).
  `regex.cy`의 `exec`는 -1이면 다시 돌고, 루프의 checkpoint가 VM을 멈춘다. 처음에는 "일치 없음"으로 돌아가 다음 검사점에 맡겼다.
  지금은 그 뒤의 호출이 어차피 checkpoint라 드러나지 않지만, 중단이 실패한 검색으로 보일 수 있어 따로 둔다(`peg`와 같다,
  2026-11-15).
- 조사 뒤 바꾼 것: `\p{^L}`는 Rust가 받지 않아 뺐다(퍼징에서 드러남). `a?+` · `a++`는 Rust에서 겹친 반복이라 그대로 받는다
  (처음에는 possessive로 보고 거부했다). 이름은 Rust를 따라 `captures_len` · `capture_names`.

## 성능

ReleaseFast, 9.8 MB 로그(10만 줄, 한글 포함), Apple Silicon:

| 패턴 | `find_all` | 처리량 |
|---|---|---|
| `status=(\d+)` (접두사 있음) | 96 ms, 10만 건 | 약 100 MB/s |
| `\d+\.\d+ms` | 502 ms | 약 20 MB/s |
| `(\w+)=(\S+)` | 761 ms, 50만 건 | 약 13 MB/s |
| `\p{Hangul}+` | 422 ms | 약 23 MB/s |
| `(?i)error\|warn` (일치 없음) | 506 ms | 약 19 MB/s |
| `ERROR` (리터럴, 일치 없음) | 1 ms 미만 | SIMD 탐색 |

`(a*)*b`를 `a` 10만 개에 돌리면 6 ms, `(x+x+)+y`를 `x` 5만 개에 3 ms다(역추적 엔진은 끝나지 않는다).
같은 단계 루프를 Cyber로 쓰면 1~2 MB/s로 추정됐다("결정" 3). 더 빨라야 하면 다음은 첫 글자 집합으로 시작 위치를 건너뛰는 것,
그다음이 캡처 없는 검색용 lazy DFA다.

## 검증

- `modules/regex.cy`: API · 의미 · 오류 문구와 위치 · 한도 · 선형 시간(모든 대상).
- `modules/regex_spec.cy`: Rust `regex` 저장소 `testdata`(커밋 `3d79fe9`)에서 이 모듈의 API로 같은 뜻을 물을 수 있는 820개
  (`src/test/assets/regex-spec`, 변환 규칙과 뺀 것은 그 폴더 README). 모두 통과. fixture에는 `LICENSE-MIT`와, fowler 데이터의
  원 라이선스(AT&T testregex) `LICENSE-FOWLER`를 같이 둔다(사용자 결정 2026-11-15). 파일을 읽으므로 `toon_spec.cy`와 같은 조건에서 돈다.
- ripgrep 15.2와 차분 퍼징(`src/tools/regex_fuzz_gen.py` · `regex_fuzz_run.cy`): 문법에서 만든 패턴과 메타 문자를 섞은 패턴
  23,000건에서 컴파일 가부와 일치 범위가 모두 같았다. ripgrep 쪽 사정으로 비교에서 뺀 것: 패턴을 `(?:..)`로 감싸서 생기는 차이
  (짝 없는 `)`, `(?x)` 주석이 닫는 괄호를 삼킴), 바이트 API라 코드포인트 안에 생기는 빈 일치, 줄 끝의 빈 일치.
- `regex.zig`의 단위 테스트(UTF-8 디코드, 접기 궤도)는 `lib-test`에서 돈다.

## 작업 중 찾은 결함

- 이번 구현에서는 컴파일러 결함이 나오지 않았다. 첫 시도(순수 Cyber, 리셋됨)에서 찾은 F-147(원소 256개 이상 리터럴) ·
  F-148(private choice 복사)은 `7a0c9015`에서 고쳤다.

## 남은 일

- 필요가 생기면: 첫 글자 집합 건너뛰기, `find_iter` 꼴의 지연 반복(지금은 슬라이스), 함수로 치환(`replace`에 클로저),
  `RegexSet`, 그 밖의 이진 속성(`\p{Emoji}` 등), `(?R)`.
