# 표준 모듈 `peg` (2026-11-15)

## 배경

`regex`는 정규 언어까지다. 괄호가 겹치는 입력, 재귀 구조(식 · 설정 파일 · 로그 안의 중첩 레코드), 앞에서 잡은 것과 같은 것이 다시
나오는 형식(여는 따옴표와 같은 닫는 따옴표)은 PEG가 맡는다. 목적이 다르므로 `regex`를 바꾸지 않고 옆에 둔다
(`project_std_regex.md` "결정" 9가 PEG를 정규식의 대안으로는 받지 않았다. 이번은 별도 모듈이다).
사용자가 쓰던 Janet은 PEG를 코어에 내장한다. 요구는 셋이다.

- 문법을 문자열로 받아 실행 중에 컴파일한다(스크립트와 에이전트가 쓴 문법을 그대로 돌린다).
- 외부 라이브러리 없이 직접 쓴다.
- 정적 타입 언어에서 쓸 수 있는 하나의 결과 타입.

구현 전에 Janet · LPeg(기준 설계)와 Rust · Zig · Nim · Python 생태계를 1차 자료(저장소 소스와 공식 문서)로 비교했다.
버전은 2026-11-15 기준이다.

## 비교 검토

### Janet 1.43.0 `peg` (코어 내장)

- 표기: 텍스트 문법이 없다. Janet 데이터가 곧 문법이다. struct가 grammar(`:main` 필수), keyword가 규칙 참조,
  tuple이 `(special 인자...)`. special은 57개다(`peg.c` `peg_specials`).
- 원소: 문자열 리터럴, 정수 `n`(n바이트), `-n`(n바이트가 남지 않음), `(range "az")`, `(set "abc")`.
  조합: `choice`/`+`, `sequence`/`*`, `any` · `some` · `between` · `at-least` · `at-most` · `repeat` · `opt`/`?`, `if` · `if-not`,
  `not`/`!`, `look`/`>`(오프셋 있는 lookahead · lookbehind), `to` · `thru`(패턴 앞까지 · 패턴까지 건너뛰기), `sub` · `split` · `til`
  (구간을 좁혀 다른 패턴 적용), `lenprefix`, `backmatch`.
- 캡처: `capture`/`<-`/`quote`, `group`, `replace`//`/`(함수 · 표 · 상수), `constant`, `argument`, `position`/`$`, `line` · `column`,
  `accumulate`/`%`, `cmt`(함수가 falsy면 실패), `backref`/`->`, `drop`, `nth`, `error`, `int` · `uint`(이진 정수), `number`.
  대부분 마지막 인자로 태그를 받는다(PEG 하나에 255개까지).
- 기본 별칭: `:d :a :w :s :h`와 대문자(여집합), 각각 `+` · `*` 꼴. 모두 ASCII. `:w`에 `_`가 없다.
- 엔진: `peg/compile`이 규칙 그래프를 `uint32` 배열로 직렬화하고 `peg_rule()`이 C 재귀로 걷는 역추적 해석기다.
  memoization 없음. 재귀 깊이 1024를 넘으면 `peg/match recursed too deeply`로 error. left recursion을 컴파일 때 보지 않아
  같은 error로 끝난다. 빈 루프는 실행 중 진전이 없으면 빠져나온다. 바이트 단위(UTF-8을 모른다).
- 캡처는 전부 즉시 평가: 스택에 쌓고 역추적 때 길이를 되돌린다. `cmt` · `replace`의 함수는 버려질 분기에서도 불린다.
- API: `peg/match`(위치 고정, 앞부분만 맞아도 성공, 결과는 캡처 배열 또는 nil), `peg/find` · `peg/find-all`(시작 위치),
  `peg/replace` · `peg/replace-all`. find 계열은 위치마다 다시 맞춰 본다. 오류 위치 보고는 없다(`(error patt)`로 직접 던진다).
- 시험: `test/suite-peg.janet`(999줄), MIT. Janet 값과 함수에 기대므로 그대로는 못 쓰고 건별 번역이 필요하다.

### LPeg 1.1.0 · `re` · LPegLabel

- 본체는 Lua 연산자 조합(`P` · `R` · `S` · `*` · `+` · `^`)이고 `re` 모듈이 텍스트 문법을 준다.
- 엔진: parsing machine. 패턴을 선형 명령열로 컴파일한다(`Char` · `Any` · `Set` · `Span` · `Choice` · `Commit` · `PartialCommit` ·
  `BackCommit` · `Fail` · `FailTwice` · `Call` · `Ret` · `Jmp` · `Open/CloseCapture` 등 26개). 호스트 재귀 없이 명시적 스택 하나에
  역추적 항목 `(대안 주소, 입력 위치, 캡처 높이)`와 복귀 주소를 쌓는다. 한도는 기본 400(`setmaxstack`), 넘으면 error.
- 컴파일 때 검사: `rule 'A' may be left recursive`(nullable 분석), `empty loop in rule`, `loop body may accept empty string`,
  정의 없는 규칙.
- 최적화: head-fail(`Test*`), tail call(`Call; Ret` → `Jmp`), 문자 집합 반복은 `Span`, 반복의 `PartialCommit`.
- 캡처: 매치 중에는 기록만 쌓고 전체가 성공한 뒤 값을 만든다("captures should avoid side effects"). 예외는 `Cmt`뿐.
  종류는 simple · position · constant · argument · back · group(이름 있음) · table · substitution · string(`%1`) · numbered · query ·
  function · fold · accumulator.
- `re` 문법: `name <- p`, `p1 / p2`, 병치, `p* p+ p?`, `p^n` · `p^+n` · `p^-n`, `&p` · `!p`, `'..'` · `".."`, `[a-z]` · `[^..]`, `.`,
  `%a %d %s %w ..`(대문자는 여집합, `%nl`), `{ p }` · `{}` · `{: p :}` · `{:name: p :}` · `{~ p ~}` · `{| p |}`, `=name`,
  `p -> 'string'` · `p -> name` · `p => name`. 주석 `--`. 첫 규칙이 시작 규칙이고 규칙 없는 식 하나도 문법이다.
- 복잡도(Ierusalimschy 2008): 최악은 입력 길이에 지수. 규칙 없는 패턴은 O(n^k)(k는 star height). packrat은 메모리가
  입력에 선형이라 "평평한 큰 데이터"에 맞지 않아 쓰지 않았다.
- LPegLabel 1.6: `%{label}`이 선택으로 잡히지 않는 실패를 던지고, 같은 이름의 규칙이 복구 규칙이 된다. 일반 실패는 가장
  멀리 간 위치를 돌려준다.

### Rust 1.100 (std에 없음)

- `pest` 2.9.6(사실상 표준, 누적 3.9억 다운로드): 외부 `.pest` 문법(`a ~ b`, `a | b`, `e{n,m}`, `_{}` silent · `@{}` atomic,
  `PUSH/POP/PEEK` 스택, 암묵적 `WHITESPACE`/`COMMENT`, Unicode 속성 내장 규칙)을 derive 매크로가 recursive descent 코드로
  바꾼다. 실행 중 문법은 `pest_vm`(최적화한 AST 해석). memoization 없음(SECURITY.md가 역추적 시간을 경고).
  left recursion · 진전 없는 반복 · 닿지 않는 대안은 컴파일 오류. 결과는 규칙마다 생기는 `Pair`(규칙 · span)의 트리이고 실제로는
  평평한 Start/End 토큰 큐다. 오류는 가장 멀리 간 실패 위치 + 그 자리에서 기대한 규칙(`positives`)과 `!e`가 막은 규칙
  (`negatives`), 줄 · 칸. 한도는 `set_call_limit`(누적 호출 예산, 선택이 삼키지 못함)과 스택 가드. `ANY`와 범위는 코드포인트.
- `peg` 0.8.6: `peg::parser!{}` 매크로. 규칙이 Rust 타입을 돌려주고 action 블록이 값을 만든다. `#[cache]`(선택적 packrat),
  `#[cache_left_rec]`(seed growing), `precedence!{}`. 오류는 `ParseError{location, expected}`. 성공 경로에서는 가장 먼 위치만
  세고 실패했을 때 다시 돌려 기대 집합을 모은다.
- `nom` · `winnow` · `chumsky` · `pom`: parser combinator. 문법 문자열이 없고 호스트 언어의 타입과 클로저에 기댄다.

### Zig 0.17.1 (std에 없음)

- std에 PEG도 combinator도 없다(`std.zig.Parse`는 손으로 쓴 예측 파서). Zig 문법의 정본은 `doc/langref/grammar.peg`이고
  `tools/gen_parser_oracle.zig`가 거기서 퍼징용 recognizer를 만들지만 내부 도구다.
- `Hejsil/mecha` 0.12(별 614, 0.17 추종): comptime combinator. 실패 위치만 준다. 재귀는 `recursiveRef`가 memo로 푼다.
- 실행 중 문법을 받는 것: `q-uint/zpars`(LPeg식 바이트코드 VM + JIT, 선택적 packrat, labeled failure), `zig-parslet`,
  `zig-pegparse`(parsimonious 이식). 모두 별 10개 안팎의 실험이다. 생성기 쪽은 `zapp`(packrat, cut) · `zpeg`.
- 시사점: 가져다 쓸 엔진이 없다. 실행 중 문법 + VM 꼴의 선례는 zpars와 `pest_vm`뿐이다.

### Nim 2.4.2

- `std/pegs`(조사 대상 중 유일한 표준 라이브러리 PEG, 2026년에도 수정 커밋): "a more powerful replacement for regular
  expressions". Ford 표기에 확장: `{E}` 캡처, `$i` 역참조, `@E` 검색 · `{@}E`, `i'..'` 대소문자 무시, `\d \s \w \a \n \ident \letter`,
  `^` · `$`, `\skip pat`. `peg"..."`는 실행 중에 AST를 만들고 `rawMatch`가 재귀로 해석한다. memoization 없음, 캡처는 위치
  기반 20개 고정(넘으면 조용히 버림), 이름 캡처 없음, left recursion은 검사 없이 충돌, 실패 위치를 주지 않는다.
  빈 입력에 맞는 것의 `*`는 2026-09부터 문법 오류. `.`과 클래스는 바이트, `_`와 `\letter`는 rune.
  API는 정규식 꼴: `match` · `matchLen` · `find` · `findAll` · `replacef`(`$1`) · `split` · `=~`.
- `zevv/npeg` 1.3.0: 매크로가 컴파일 타임에 parsing machine 명령을 Nim `case` 루프로 낸다. Nim 식이어야 해서 표기가 다르다
  (`*` 순차, `|` 선택, 전위 `*P +P ?P`, `>P` 캡처). 스택 둘 각각 1024 → `NPegStackOverflowError`. `matchMax`(가장 먼 위치),
  `E"msg"` 오류 표지, `^` · `^^` 우선순위. JSON · AST 캡처는 0.22에서 뺐다(문자열 캡처와 코드 블록만).
- Nimony의 `lib/std`에는 pegs가 없고 DFA 정규식 `rex`만 있다.

### Python 3.15

- std에 사용자용 PEG가 없다. CPython 파서는 `pegen`(PEP 617)이 만든 packrat 파서지만 `Tools/`에만 있다. 표기는
  `rule: a | b`, cut `~`, `s.e+`, `&&e`, action. left recursion은 memo 기반 seed growing. 오류는 가장 먼 토큰 + `invalid_` 규칙.
- `parsimonious` 0.11(텍스트 PEG의 사실상 표준): `rule = expr`, `/`, `~"regex"`, `{m,n}`. 항상 packrat(메모리 O(문법 × 입력)).
  결과는 모든 식의 `Node` 트리 + `NodeVisitor`. `parse`(전체) · `match`(앞부분). `ParseError`는 가장 먼 위치 · 줄 · 칸 · 식 하나.
  left recursion은 실행 중 `LeftRecursionError`.
- `Arpeggio` 2.0(자동 공백 건너뛰기, `NoMatch`가 그 자리에서 기대한 규칙 목록을 준다), `TatSu` 5.24(EBNF 꼴, packrat과 left
  recursion 기본), `pyparsing` 3.3(combinator), `pe` 0.6(Ford 표기 + `~e` 캡처 · `name:e`, parsing machine 엔진 선택 가능,
  캡처 의미를 명세로 적은 유일한 구현).

### 요약

| | Janet | LPeg `re` | Rust `pest` | Zig | Nim `std/pegs` | Python `parsimonious` |
|---|---|---|---|---|---|---|
| std 포함 | 코어 내장 | 외부 | 외부(사실상 표준) | 없음 | 있음 | 외부(CPython 내부만 PEG) |
| 표기 | 호스트 데이터(S-expr) | 텍스트(`<-`, `/`) | 텍스트(`=`, `~`, `\|`) | combinator(mecha) | 텍스트(Ford + 확장) | 텍스트(`=`, `/`, regex 단말) |
| 컴파일 | 실행 중 | 실행 중 | 빌드(매크로), `pest_vm`은 실행 중 | comptime | 실행 중 | 실행 중 |
| 엔진 | 재귀 해석기 | parsing machine | recursive descent | 함수 포인터 | 재귀 AST 해석기 | 재귀 + packrat |
| memoization | 없음 | 없음 | 없음 | `recursiveRef`만 | 없음 | 항상 |
| left recursion | 실행 중 깊이 초과 | 컴파일 오류 | 컴파일 오류 | memo로 지원 | 충돌 | 실행 중 오류 |
| 빈 루프 | 실행 중 탈출 | 컴파일 오류 | 컴파일 오류 | - | 문법 오류 | - |
| 결과 | 캡처 배열(동적 값) | 캡처 값들(동적) | 규칙별 `Pair` 트리 | 타입 값 | 위치 캡처 20개 | 모든 식의 `Node` 트리 |
| 실패 보고 | 없음 | 없음(Label이 가장 먼 위치) | 가장 먼 위치 + 기대 집합 | 위치 | 없음 | 가장 먼 위치 + 식 하나 |
| 매칭 단위 | 바이트 | 바이트(`utfR`만 예외) | 코드포인트 | 바이트 | 바이트 + rune 원소 | 코드포인트 |
| 자원 한도 | 깊이 1024 | 스택 400(조정) | 호출 예산 · 스택 가드 | 없음 | 없음 | Python 재귀 한도 |
| 공백 | 직접 | 직접 | 암묵 규칙 | 직접 | `\skip` | 직접 |

공통점: 표준 PEG를 스스로 말하는 텍스트 문법은 npeg를 빼고 모두 Ford의 핵심(`/`, 병치, 후위 `? * +`, 전위 `& !`, `'..'`,
`[..]`, `.`)을 쓴다. 갈리는 것은 정의 기호(`<-` 또는 `=`)와 캡처 표기다. 실행 중 문법을 받는 구현은 memoization 없는 역추적이
다수다(Janet · LPeg · `pest_vm` · `std/pegs`). 실패 보고가 있는 구현의 공통 분모는 "가장 멀리 간 실패 위치"다.

## 결정

1. 표기는 텍스트다. 기준은 LPeg `re`(Ford 표기 + 캡처 표기). Janet의 데이터 표기는 따르지 않는다: Cyber에는 keyword와
   이종 tuple 리터럴이 없어 생성자 호출을 겹쳐 써야 하고(`peg.seq(peg.lit('a'), ...)`), 모델이 쓴 문법은 텍스트 PEG 꼴이 많다.
   `regex`의 원칙을 그대로 쓴다: 받는 문법은 `re`에서와 같은 뜻이고, 받지 않는 표기는 컴파일 오류로 대신 쓸 것을 말한다.
   Janet에서 가져오는 것은 표기가 아니라 쓰임새다: 코어에 내장, 캡처 중심, 함수 없이 되는 특수 형식(`backmatch` → `=name`).
2. 엔진은 LPeg의 parsing machine. 호스트 재귀가 없어 깊은 입력이 VM 스택을 건드리지 않고(Janet · `std/pegs` · `pest`의 재귀는
   깊이 한도나 충돌로 끝난다), 역추적 항목 하나가 세 칸이라 한도를 크게 줄 수 있다. memoization은 두지 않는다(LPeg의 이유:
   메모리가 입력에 선형, 로그 같은 평평한 입력이 주 용도).
3. 나눔은 `regex`와 같다: 문법 파서 · 검사 · 코드 생성은 Cyber(`src/std/peg.cy`), 매칭 루프는 Zig(`src/std/peg.zig`).
   프로그램은 `[]int` 하나, `Peg`의 필드는 private.
4. 결과는 타입 하나 `peg.Capture{name, start, end, text, kids}`의 트리다. 매치 전체가 뿌리(이름 `''`)이고, 캡처는 문법에서
   감싼 모양대로 겹친다. 동적 값 배열(Janet · LPeg)은 정적 타입에 맞지 않고, 규칙마다 노드가 생기는 꼴(`pest` · `parsimonious`)은
   추출 용도에 군더더기가 많다. 명시한 캡처만 노드가 된다. `{| p |}`(table)는 겹침이 이미 트리라 필요 없다.
5. 캡처는 기록만 쌓고 매치가 끝난 뒤 트리를 만든다(LPeg의 지연 평가). 역추적은 기록 길이만 되돌린다. 함수를 부르는 캡처
   (`-> name` · `=> name`, Janet `cmt` · `replace`의 함수)는 두지 않는다: 버려질 분기에서의 호출 문제가 생기고 매칭 루프가 Zig다.
   변환은 문자열 캡처 `p -> 'text %1'`과 치환 캡처 `{~ p ~}`로 한다.
6. 컴파일 때 거부한다(LPeg · `pest`): left recursion, 빈 문자열에 맞을 수 있는 것의 반복, 정의 없는 규칙, 중복 규칙.
   Janet · `std/pegs`처럼 실행 중에 드러나게 두지 않는다.
7. 실패 보고: `parse`가 실패하면 `peg.Diag`에 가장 멀리 간 실패 위치(바이트 · 줄 · 칸)와 그 자리에서 기대한 것들(`pest`의
   positives, Arpeggio `NoMatch`)을 준다. 기대한 것은 규칙 이름이 아니라 문법의 원문 조각(`'='`, `[0-9]`)이다. `&` · `!` 안의 실패는
   세지 않고, `!e`가 막았으면 `not e`로 적는다. 오류 표지 · 복구(LPegLabel) · cut(`pegen`)은 두지 않는다.
8. 매칭 단위는 `regex`와 같이 코드포인트, 오프셋은 바이트. `.`과 `[가-힣]`이 글자 단위다(Janet · LPeg의 바이트 단위는 한글
   입력에서 글자를 쪼갠다). UTF-8이 아닌 바이트는 한 단위로 `.`과 부정 클래스에 맞는다(`!.`이 입력의 끝이라는 뜻을 지킨다.
   `regex`는 이 바이트가 `.`에 맞지 않는다). `%a %d %w ..`는 LPeg(C locale) · Janet과 같이 ASCII.
9. 시간 보장은 없다. PEG는 역추적이라 문법에 따라 입력 길이에 지수 시간이 든다(`regex`와 다른 점. 문서에 적는다).
   보호는 둘이다: 스택과 캡처 기록의 한도, 그리고 일정 단계마다 보는 VM interrupt 표시(호스트의 시간 제한).
   `pest`식 호출 예산은 필요가 생기면 더한다.
10. API는 `regex`의 이름을 맞춘다(`find` · `find_all` · `replace` · `replace_all` · `split`). PEG 고유의 것은 둘: `match`(위치 고정,
    앞부분만 맞아도 성공. Janet `peg/match` · LPeg `match`)와 `parse`(입력 전체, 실패하면 오류와 `Diag`. `parsimonious`의 나눔).
    치환 문자열은 `regex`와 같은 `$1` · `${name}` · `$$`.
11. 받지 않기로 한 대안: packrat(메모리, 위), left recursion 지원(seed growing은 memo가 전제), 암묵적 공백(`pest` · Arpeggio.
    추출용 패턴에서 공백이 뜻을 가진다), 우선순위 연산자(`npeg` `^`, `peg` `precedence!`), 생성자 API.

## 문법

`re`의 것 그대로다. 우선순위는 위가 높다.

| 표기 | 뜻 |
|---|---|
| `'text'` `"text"` | 리터럴. 이스케이프 `\n \r \t \\ \' \" \[ \] \- \^ \xHH \u{H..}` |
| `[a-z_]` `[^"]` | 코드포인트 클래스와 여집합. 안에 `%d` 같은 클래스를 쓸 수 있다 |
| `.` | 아무 글자 하나(코드포인트, 또는 UTF-8이 아닌 바이트 하나) |
| `%a %c %d %g %l %p %s %u %w %x` | ASCII 클래스(alpha · cntrl · digit · graph · lower · punct · space · upper · alnum · xdigit). 대문자는 여집합 |
| `%nl` | `'\n'` |
| `name` | 규칙 호출 |
| `( p )` | 묶음 |
| `{ p }` | 캡처 |
| `{}` | 위치 캡처(길이 0) |
| `{:name: p :}` | 이름 있는 캡처 |
| `{~ p ~}` | 치환 캡처: 텍스트가 매치에서 직계 자식 캡처의 구간을 그 텍스트로 바꾼 것 |
| `=name` | 가장 최근에 닫힌 `name` 캡처가 맞은 텍스트와 같은 것 |
| `p?` `p*` `p+` | 0~1번 · 0번 이상 · 1번 이상. 되돌아가지 않는다(possessive) |
| `p^n` `p^+n` `p^-n` | 정확히 n번 · n번 이상 · n번 이하 |
| `p -> 'text'` | 문자열 캡처: 텍스트가 `text`. `%0`은 매치, `%1`~`%9`는 `p` 안의 캡처, `%%`는 `%` |
| `&p` `!p` | 맞으면 · 맞지 않으면 성공. 입력을 쓰지 않고 캡처를 남기지 않는다 |
| `p1 p2` | 순서대로 |
| `p1 / p2` | 순서 있는 선택: `p1`이 맞으면 `p2`를 보지 않는다 |
| `name <- p` | 규칙. 첫 규칙에서 시작한다. 규칙 없이 식 하나만 써도 된다 |
| `-- ..` `# ..` | 줄 끝까지 주석(`re`와 Ford) |

`re`와 다른 곳(LPeg 1.1.0에서 확인):
- 리터럴과 클래스에 이스케이프가 있다(`re`는 Lua 문자열에 기대어 없다. Ford 표기에는 있다).
- `{:name: p :}`는 겹친 캡처를 자식으로 갖는 노드다(`re`에서는 `{| |}` 밖에서 값을 내지 않는다). `{: p :}`(이름 없는 묶음)는
  `{ p }`로 쓴다.
- `=name`은 그 캡처가 맞은 텍스트 전체와 비교한다. `re`는 묶음의 첫 값이라 안에 캡처가 있으면 그 캡처의 값과 비교한다.
  그 이름의 캡처가 아직 없으면 `re`는 실행 중 error, 여기서는 매치 실패다.
- `p -> '%2'`에서 없는 캡처는 빈 문자열이다(`re`는 실행 중 error). `{}`는 텍스트가 `''`이고 위치는 `start`다(`re`는 수).
- 검사가 더 엄격하다: 첫 규칙에서 닿지 않는 규칙과, 실패할 수 없는 대안 뒤의 대안도 left recursion · 빈 루프를 본다
  (LPeg는 그런 대안을 만들 때 버리고, 닿지 않는 규칙을 검사하지 않는다).
- 같게 맞춘 곳: 클래스 안의 `%` 이름은 `re`처럼 글자 · 숫자 · `_`가 이어지는 데까지 읽는다. `[%w_]`는 `%w_`라는 이름이라 오류이고
  문구가 `[_%w]`를 권한다.
- 받지 않는 것(컴파일 오류): `{| p |}`, `p -> name` · `p -> 3` · `p => name` · `p ~> name` · `p >> name`, `%name`(위 표 밖), `<name>`.

## API

```cy
use peg

p := peg.compile(`
    pair  <- {:key: word :} '=' {:val: value :}
    value <- quote / word
    quote <- {:q: ['"] :} (!=q .)* =q
    word  <- [_%w]+
`)!
p.match(s)                --> ?Capture     위치 0에서. 앞부분만 맞아도 된다
p.match(s, start)         --> ?Capture     바이트 start에서
p.parse(s)                --> !Capture     입력 전체. error.NoMatch
p.parse(s, &diag)         --> !Capture     diag.msg · pos · line · col · expected
p.find(s)                 --> ?Capture     가장 왼쪽에서 맞는 것
p.find(s, start)          --> ?Capture
p.find_all(s)             --> []Capture    겹치지 않게 모두
p.replace(s, repl)        --> str          첫 매치만
p.replace_all(s, repl)    --> str          $0 매치, $1.. 최상위 캡처, ${name}, $$
p.split(s)                --> []str
p.source()                --> str
c.name  c.start  c.end  c.text  c.kids
c['key']                  --> str          그 이름의 첫 자손 캡처의 텍스트, 없으면 ''
c[0]                      --> str          자식 캡처의 텍스트. 범위 밖이면 panic
c.get('key')              --> ?Capture     문서 순서로 첫 자손
c.all('key')              --> []Capture    그 이름의 모든 자손
c.len()                   --> int          자식 수

var diag peg.Diag = {}
p2 := peg.compile(src, &diag) !else |err|: ...     -- error.Syntax · error.TooBig
```

## 한도

- `MaxInsts` 65536: 프로그램 명령 수. 넘으면 `error.TooBig`. `p^n`은 n번 펼친다.
- `MaxDepth` 250: 문법 식의 중첩(파서와 코드 생성이 재귀).
- `MaxStack` 100000: 매칭 스택의 항목(호출 복귀와 역추적). 입력의 중첩 깊이가 이것으로 막힌다.
- `MaxCaptures` 1000000: 매치 하나의 캡처 수.
- 실행 중 한도를 넘으면 `parse`는 `error.TooDeep`(스택) · `error.TooBig`(캡처)를 돌려주고, 옵션을 돌려주는 `match` · `find` ·
  `find_all` · `replace` · `split`은 panic이다(매치 없음으로 조용히 넘어가지 않는다).

## 구현

- `src/std/peg.cy`: 재귀 하강 파서 → 노드 → 검사(nullable 고정점, left recursion, 빈 루프) → 명령. 프로그램은 `[]int`:
  머리 8칸 · 리터럴 바이트 · 집합 · 명령(`op, a, b` 세 칸).
- 명령: `end` `any` `str` `set` `span` `choice` `commit` `partial_commit` `back_commit` `fail` `fail_twice` `call` `ret` `jmp`
  `open` `close` `backref`. `p*`는 `choice L2; L1: p; partial_commit L1; L2:`, `!p`는 `choice L; p; fail_twice; L:`,
  `&p`는 `choice L1; p; back_commit L2; L1: fail; L2:`. 집합 하나의 `*`는 `span`. 규칙의 마지막 대안 끝에 있는 호출은 `jmp`(tail call)라
  `a <- !. / . a` 같은 규칙이 스택을 쓰지 않는다(앞쪽 대안 안의 호출은 선택 항목이 남아 스택을 쓴다. LPeg와 같다).
- 집합: `ascii_lo, ascii_hi, 부정, 범위 수, (lo, hi)...`. ASCII는 비트맵(부정 적용됨), 그 밖은 범위를 훑는다.
- `src/std/peg.zig`: `exec(prog, hay, start, mode, out, caps)`. 스택 항목은 `(pc, 입력 위치 또는 호출 표시, 캡처 높이)`.
  `mode`의 검색 비트는 위치를 코드포인트씩 옮겨 가며 다시 맞춰 보고(Janet `peg/find`와 같다), 추적 비트는 가장 먼 실패
  위치와 그 자리에서 실패한 명령(16개까지)을 모은다. 술어 안인지는 스택의 술어 항목 수로 안다.
- 캡처 기록은 `(종류, 인자, 위치)` 세 칸씩 호출자의 버퍼에 쓴다. 모자라면 필요한 크기를 알리고 Cyber 쪽이 늘려 다시 돈다.
  트리는 Cyber에서 명시적 스택으로 만든다(겹친 캡처가 깊어도 VM 재귀가 없다).
- `=name`은 실행 중 기록을 뒤로 훑어 가장 최근에 닫힌 그 이름의 캡처를 찾는다. 없으면 실패다.
- 기대 문구: 실패할 수 있는 명령마다 문법 원문의 구간을 적어 둔 표(`pc → 문구`)가 `Peg`에 있다.

## 성능

ReleaseFast, Apple Silicon:

| 일 | 시간 |
|---|---|
| 8.9 MB 로그(10만 줄)에서 `'status=' {%d+}`의 `find_all`, 10만 건 | 228 ms |
| 같은 로그에서 `{:k: [_%w]+ :} '=' {:v: %S+ :}`의 `find_all`, 40만 건 | 1129 ms |
| 같은 로그 전체를 줄 문법으로 `parse`, 캡처 50만 개 | 395 ms |
| 1.2 MB JSON을 JSON 문법으로 `match`(캡처 없음) | 26 ms(약 47 MB/s) |
| 8.9 MB에서 없는 리터럴 `find` | 25 ms |

`find_all`은 매치마다 Cyber 쪽에서 실행을 다시 시작하고 트리를 만드는 값이 든다. 더 빨라야 하면 첫 글자 집합으로 시작 위치를
건너뛰는 것(LPeg의 head-fail)이 다음이다.

## 검증

- `modules/peg.cy`: 문법 요소 · 캡처 트리 · API · 오류 문구와 위치 · 한도 · 코드포인트 매칭(모든 대상).
- 기준 구현의 시험 데이터: LPeg `test.lua`와 Janet `suite-peg.janet`은 호스트 언어의 값과 함수에 기대어 fixture로 그대로 쓸 수
  없다(regex의 Rust testdata 같은 중립 형식이 아니다). 대신 LPeg 1.1.0(Lua 5.5)의 `re`와 차분 퍼징을 했다
  (`src/tools/peg_fuzz_gen.py` · `peg_fuzz_run.cy`): 공통 부분집합에서 만든 문법(규칙 1~4개, 캡처 · 역참조 · 치환 포함)과 입력
  180,000건(시드 15개)에서 컴파일 가부, 매치 끝 위치, 캡처 값이 모두 같았다. 비교에서 뺀 것: LPeg가 실행 중 error를 내는 경우
  (없는 역참조 · 없는 `%n`), 위치 캡처의 값이 `%1`에 들어가는 경우, 그리고 여기만 거부하는 닿지 않는 규칙 · 대안(위 "다른 곳").
- 퍼징이 찾아 고친 것: 클래스 안의 `%a_` 읽기(처음에는 한 글자만 읽어 `re`와 달랐다), `p^0` 안의 호출을 left recursion으로 본 것.
- `peg.zig`의 단위 테스트(UTF-8 디코드, 집합)는 `lib-test`에서 돈다.

## 남은 일

- 필요가 생기면: 호출 예산(`pest` `set_call_limit`), 첫 글자 집합 건너뛰기, 대소문자 무시 리터럴(`std/pegs` `i'..'`), Unicode 속성
  클래스(`regex`의 표 재사용), 건너뛰기 표기(Janet `to` · `thru`, `std/pegs` `@`), 오류 표지와 복구(LPegLabel), 줄 · 칸 캡처.
