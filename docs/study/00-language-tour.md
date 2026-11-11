---
aliases: [Cyber 언어 투어, language-tour]
tags:
  - study
  - cyber
  - syntax
  - typescript
---

# Day 1 (사전). Cyber 0.4 언어 투어

> 대상 소스: `docs/docs.md`(언어 레퍼런스, 설계 의도), `src/test` 하위의 모든 `.cy` 파일(실행되는 명세), `src/builtins/core.cy`(표준 타입 구현), `src/std/*.cy`, `src/main.zig`
> 줄 번호는 HEAD b40531a1 기준이다. 이 문서의 모든 코드 블록은 `zig-out/bin/cyber`(ReleaseSafe, 0.4.2-DEV)로 실제 실행해 출력을 확인했다.
> 예상 학습 시간: 3~4시간 (읽기 1.5h / 예제 직접 쳐보기 1h / 미니 과제 1h)
> 선행: 없음. 다음 챕터: [01-pipeline-front-end.md](01-pipeline-front-end.md)

## 한줄 요약

Cyber 0.4는 파이썬처럼 들여쓰기로 블록을 만들지만 정적 타입(타입 추론 포함)을 쓰고, 값/참조/빌림을 구분하며, 예외 대신 `Option(?T)`과 `Result(!T)`로 실패를 표현하는 언어다. 옛 문서(0.3)에 나오는 `my`, `dyn`, `throw/catch`, `coinit`, `print x` 같은 문법은 0.4에서 모두 사라졌다.

## 오늘의 학습 목표

- [ ] `cyber file.cy`, `cyber compile file.cy`, REPL로 코드를 실행하고 바이트코드를 볼 수 있다.
- [ ] 변수(`:=`, `var`, `global`, `const`), 기본 타입, 연산자, 정수/실수 암시적 변환 규칙을 설명할 수 있다.
- [ ] `if`/`switch`/`while`/`for`와 `|x|` 캡처 문법, 함수/람다/클로저(캡처 규칙)를 쓸 수 있다.
- [ ] struct, enum, choice, trait, 템플릿(제네릭)으로 타입을 정의하고 메서드를 붙일 수 있다.
- [ ] `?T`와 `!T`를 `.?`, `if x |v|`, `!`, `!else`로 풀 수 있다.
- [ ] `^T`(참조), `&T`(빌림), `move`의 차이를 작은 프로그램으로 보일 수 있다.
- [ ] 컴파일 에러 메시지를 보고 "자주 막히는 지점" 목록에서 원인을 찾을 수 있다.

## 1. 왜 이것이 필요한가?

Cyber는 upstream(fubark/cyber)이 2023년 0.3 이후 문법과 의미를 크게 바꿨다([cyber_0_3_to_0_4_overview.md](../history/cyber_0_3_to_0_4_overview.md)). 인터넷의 예제, 옛 README, LLM이 기억하는 Cyber 코드는 대부분 0.3 이전 문법이다. 이 fork를 인수해 유지보수하려면 "지금 이 바이너리가 받아들이는 문법"을 먼저 정확히 알아야 컴파일러 소스를 읽을 때 입력과 출력을 머릿속에서 대응시킬 수 있다.

기준 문서인 `docs/docs.md`에도 한계가 있다. 설계 의도를 적은 레퍼런스라서 구현이 따라가지 못한 곳이 있다. 이 투어는 문서를 그대로 옮기지 않고, 모든 예제를 실제로 돌려서 확인했다. 문서와 달랐던 곳은 7절에 모았다. 예를 들어 문서는 `arr := {1, 2, 3}`과 `int(fruit)`, `print(add[float](1, 2)) --> 3.0`이 된다고 쓰지만 실제 바이너리는 각각 컴파일 에러, 컴파일 에러, `3`을 낸다.

TS/Node 개발자에게 익숙하지 않은 개념이 세 가지 있다.

- 값 의미(value semantics): struct 대입은 복사다. JS 객체처럼 참조가 공유되지 않는다.
- 소유권/빌림: 힙 값은 `^T`로 명시적으로 올리고, 스택 값은 `&T`로 빌린다. 트레이싱 GC가 없다.
- 예외가 없다: 실패는 값(`!T`)이고, 패닉은 잡을 수 없다.

## 2. 근본적인 동작 원리

### 2.1 파일 하나가 실행되기까지

```
cyber hello.cy
  │  src/main.zig:56-109: 인자 해석 -> 명령(eval/compile/fmt/help/version/repl)
  ▼
컴파일러 (src/compiler.zig)         <- 01 챕터에서 해부
  소스 -> 토큰 -> AST -> 심볼/타입 -> IR -> 바이트코드
  │  표준 타입(Slice, Map, str, Option...)은 src/builtins/core.cy 를
  │  "매번 같이 컴파일"해서 얻는다 (Cyber로 쓴 표준 라이브러리)
  ▼
VM (src/vm.c execBytecode)          <- 05 챕터
  최상위 문장이 곧 프로그램 본문(main block). fn main() 이 있으면 그것이 진입점.
```

스크립트 언어처럼 보이지만 컴파일 단계에서 타입 검사가 모두 끝난다. 그래서 타입 오류는 프로그램이 한 줄도 실행되기 전에 `CompileError`로 나온다. 아래 프로그램의 첫 줄 `print('before')`는 실행되지 않는다.

```cy
print('before')
var n int = 'abc'
print(n)
```

```text
CompileError: Expected type `int`, got `str`.
```

### 2.2 설계 축 다섯 가지

| 축 | Cyber 0.4의 선택 | TS/Node에서의 비교 (일반 지식) |
|---|---|---|
| 타입 | 정적. 지역변수는 `:=`로 추론, 함수 매개변수/필드는 명시 | TS는 정적이지만 런타임에는 타입이 지워지고 JS가 돈다 |
| 메모리 | 트레이싱 GC 없음. 값은 스코프 끝에서 소멸, 힙 값은 ARC(참조 카운트) | V8은 트레이싱 GC |
| 실패 | `?T`, `!T`, `panic`. 예외 없음 | `throw`/`try`/`catch`, `undefined`/`null` |
| 제네릭 | 템플릿 `[T]`. 사용 시점에 타입별로 코드를 따로 만든다(memoized) | TS 제네릭은 타입 소거 |
| 동시성 | stackless 제너레이터, `spawn` 스레드, `Future` | `function*`, Promise/`async`, worker_threads |

### 2.3 값, 참조, 빌림의 메모리 그림

```
a := Vec2{x=1, y=2}          스택 슬롯에 값이 통째로 있다 (복사 가능)
b := a                       b 에 복사본이 생긴다. b.x = 9 해도 a.x 는 1

p := ^Vec2{x=1, y=2}         힙에 값이 생기고 p 는 8바이트 참조
q := p                       q 와 p 는 같은 힙 값을 가리킨다 (참조 카운트 증가)

r := &a                      a 를 가리키는 빌림. 스택 밖으로 못 나간다
```

이 세 줄이 JS와 가장 다른 점이다. JS에서는 `{x:1,y:2}` 객체의 변수가 모두 참조라서 대입이 공유다. Cyber에서 공유를 원하면 `^`로 올려야 한다.

## 3. 핵심 개념 정리

### 3.1 실행 도구

```bash
cyber file.cy            # 컴파일 + 실행. 뒤의 인자는 os.args() 로 받는다
cyber compile file.cy    # 컴파일만 하고 바이트코드를 덤프 (stderr 로 나간다)
cyber                    # REPL
cyber help               # 사용법
cyber version            # 버전
```

`src/main.zig:56-109`가 인자를 해석한다. 첫 번째로 `-`로 시작하지 않는 인자가 `compile`/`fmt`/`version`/`help`면 그 명령이고, 그 외에는 파일 경로로 보고 실행한다. 알 수 없는 `-옵션`은 에러 없이 무시된다(`main.zig:82`, 스크립트가 자기 옵션을 쓰도록). 그래서 `cyber --version`은 버전을 내지 않고 REPL로 들어간다. 버전은 `cyber version`이다.

```bash
$ cyber version
Cyber 0.4.2-DEV build-0-local
```

종료 코드는 정상 0, 컴파일 에러와 패닉은 1이다(`main.zig:299`). 에러 메시지는 stderr로 나간다.

`cyber fmt`는 도움말에 있지만 이 빌드에서는 동작하지 않는다. `src/main.zig:120-121`이 `std.debug.panic("TODO: Embed src/tools/fmt.cy")`를 호출하고, 그 파일은 저장소에 없다. 포매터가 필요하면 직접 만들어야 한다(01 챕터 참고). (2026-11-11 갱신: `cyber fmt`는 `src/format.zig`로 구현됐다. `docs/decisions/project_fmt.md`)

REPL은 줄 단위로 평가하며 지역 변수와 함수 선언이 다음 줄로 이어진다. 표준 입력으로도 돌릴 수 있다.

```bash
$ printf 'a := 1\nb := a + 2\nprint(b)\nfn sq(x int) -> int:\n    return x * x\n\nprint(sq(7))\n.exit\n' | cyber
Cyber 0.4.2-DEV build-0-local REPL
Commands: .exit
3
49
```

`cyber compile`은 함수별 명령어 목록을 낸다. 덤프는 stdout이 아니라 stderr로 나가므로(관찰: `2>/dev/null`이면 0줄) 파이프로 거르려면 `2>&1`이 필요하다. 3줄짜리 프로그램도 표준 타입 청크(`core.cy`)가 같이 컴파일되어 6천 줄 넘게 나온다. 아래는 `fn sq`와 `print(sq(7))`만 거른 것이다. 작은 leaf 함수는 인라인되어 호출 자리에 `imul`이 직접 나온다(04 챕터).

```bash
$ cyber compile sq.cy 2>&1 | rg -n '^--start|imul|`fn sq`' | head -4
22:--start
25:0:75 .imul: %1 = %2 * %2
35:--0 `fn sq`
37:0:116 .imul: %0 = %5 * %5
```

### 3.2 문장, 주석, 블록

- 문장은 줄바꿈으로 끝난다. `;`는 문법이 아니다(`ParseError: Expected end of line or file. Got semicolon.`).
- 괄호 `() [] {}` 안이거나, 줄 끝 토큰이 연산자/키워드면 다음 줄로 이어진다.
- 주석은 `--`이다. `//`는 주석이 아니다. 문장 맨 앞에 쓰면 `ParseError: Unknown token: slash`, 식 안에서 `10 // 3`처럼 쓰면 `ParseError: Expected right operand.`가 난다. `--|`는 문서 주석(`cy.parse`가 선언에 붙은 문서를 추출)이다.
- 블록은 `:` 뒤 줄바꿈과 들여쓰기다. 한 문장이면 같은 줄에 쓸 수 있다. 빈 블록은 `pass`.
- 들여쓰기는 공백 또는 탭이며 한 파일에서 섞을 수 없다.

```cy
-- 한 줄 주석
sum := 1 +
    2 +
    3
print(sum)

xs := []int{1, 2,
    3, 4}
print(xs.len())

ok := sum > 5 and
    xs.len() == 4
print(ok)

if ok: print('one-line block')

fn todo():
    pass
todo()

a := 1   -- 줄 끝 주석
print(a)
```

```text
6
4
true
one-line block
1
```

### 3.3 변수: `:=`, `var`, `global`, `const`

```cy
a := 123          -- 선언 + 타입 추론 (int)
a = 234           -- 대입
print(a)

var b float = 123 -- 타입 명시. 정수 리터럴이 float 으로 맞춰진다
print(b)

global g int = 7  -- 프로그램 수명 전역. 타입 명시 필수 (`global g = 7`은 `ParseError: Expected global type.`)
fn show_g():
    print(g)
show_g()
g = 8
show_g()

const pi = 3.14   -- 컴파일 타임 상수. 재대입 불가
print(pi)
```

```text
234
123
7
8
3.14
```

- 같은 블록에서 같은 이름을 다시 `:=` 하면 에러다(`Variable `x` is already declared in the block.`). 안쪽 블록에서는 섀도잉이 된다.
- `begin:` 블록은 변수 스코프만 새로 만드는 블록이다.
- 함수는 바깥 지역 변수를 읽지 못한다(`Undeclared variable `a`.`). 전역은 `global`로 선언한다.
- `const`에 재대입하면 `Cannot assign to a constant.`다.

섀도잉 확인: `x := 1` 뒤 `if true:` 블록 안에서 `x := 2`를 하고 출력하면 `2`, 블록을 나온 뒤에는 다시 `1`이다. `begin:` 블록 안의 `x := 99`도 같다.

### 3.4 기본 타입과 연산자

| 타입 | 설명 | 근거 |
|---|---|---|
| `int` | 64비트 정수. `i64`/`Int[64]`의 별칭 | `core.cy:399` |
| `i8 i16 i32 i64` | 부호 있는 정수 `Int[W]` | `core.cy:395-398` |
| `byte`, `r8 r16 r32 r64` | 부호 없는 raw 정수 `Raw[W]`. `print`는 16진으로 출력 | `core.cy:292-296` |
| `float` | 64비트 실수. `f64`/`Float[64]`의 별칭 (`f32`도 있음) | `core.cy:596-598` |
| `bool` | `true`/`false` | |
| `str` | 불변 UTF-8 문자열 | `core.cy:3237` |
| `symbol` | `@usd` 형태의 전역 유일 심볼 | |
| `error` | `error.Name` 값. 생성자는 심볼에서 만든다 | `core.cy:257` |
| `void`, `never` | 반환값 없음, 반환하지 않음(`panic`) | `core.cy:232-234` |

`int`는 이름뿐 아니라 실제로 `Int[64]` 템플릿 인스턴스다. `int`, `float`, `str`의 `fmt`, `parse` 같은 메서드가 모두 `core.cy`에 Cyber 코드로 있다는 점이 이 언어의 특징이다(08 챕터).

타입 이름을 확인하고 싶으면 템플릿 함수 `fn tn(x %T) -> str: return type.name(T)`를 만들어 `tn(7)`(`int`), `tn(2.5)`(`float`), `tn('a'[0])`(`byte`)처럼 쓴다. `print(@usd)`는 `@usd`, `print(error.Oops)`는 `error.Oops`다.

연산자 동작은 다음과 같다.

```cy
print(7 / 2)       -- 정수 나눗셈은 0 쪽으로 버림
print(-7 / 2)
print(-7 % 3)      -- 나머지 부호는 피제수를 따름
print(7.0 / 2)
print(1 << 4)
print(0xF0 && 0x3C)   -- 비트 AND 는 && (논리 AND 는 and)
print(0xF0 || 0x0F)   -- 비트 OR 은 ||  (논리 OR 는 or)
print(0xFF ~ 0x0F)    -- 비트 XOR 은 ~
print(~0)
print(not true)
print(!false)
print(true and false)
```

```text
3
-3
-1
3.5
16
48
255
240
-1
false
true
false
```

정리하면 다음과 같다.

- 논리는 `and` `or` `not`(또는 `!`), 비트는 `&&` `||` `~`(이항 XOR/단항 NOT) `<<` `>>`. 거듭제곱은 별표 두 개 연산자이고 정수와 실수 모두에서 쓸 수 있다. `//`(정수 나눗셈), `++`, 별표 두 개 복합 대입은 없다(모두 `ParseError: Expected right operand.`). 복합 대입은 `+= -= *= /=`를 확인했다.
- 정수는 오버플로가 나면 랩어라운드한다(`9223372036854775807 + 1`이 `-9223372036854775808`). 0으로 나누면 `panic: Division by zero.`다.
- `print`는 인자를 정확히 하나 받는다(`print(1, 2)`는 컴파일 에러). `%T` 템플릿 함수다(`core.cy:158`).
- 실수는 정수 값이면 소수점 없이 출력된다(`print(5.0)`은 `5`, `print(0.1 + 0.2)`는 `0.30000000000000004`). 출력 포매터가 `f64_fmt`라서다(`core.cy:629`, `core.cy:655`).

- 우선순위는 C/JS와 다른 곳이 있다. 비트 시프트가 덧셈보다 강하고, 비트 OR(`||`)과 XOR(`~`)이 같은 우선순위이며, `not`은 뒤의 식 전체를 받지만 `!`는 바로 뒤 항만 받는다. 거듭제곱도 왼쪽 결합이다. 근거 코드는 [01-pipeline-front-end.md](01-pipeline-front-end.md)의 3.3절이다.

```cy
print(1 << 2 + 1)
print(1 || 2 ~ 3)
print(not false and false)
print(!false and false)
```

```text
5
0
true
false
```

정수와 실수의 암시적 변환 규칙은 다음과 같다. 구현은 `sema.semaBinExpr`(`sema.zig:8401`)이고, 이항 연산에서 왼쪽 피연산자의 타입이 오른쪽의 목표 타입이 된다(`semaExprCstr(right_n, left.type)`, `semaExprTarget(right_n, left.type)`). 왼쪽이 숫자 리터럴이면 반대로 오른쪽에서 타입을 가져온다(`sema.zig:8437-8447`).

```cy
x := 2.5
n := 3
print(x * n)      -- 왼쪽이 float: 오른쪽 int 가 float 로 맞춰진다
print(x * 2)      -- 리터럴은 목표 타입에 맞춰진다
print(10 / 4.0)   -- 왼쪽 리터럴은 오른쪽 float 에서 타입을 얻는다
var f float = n   -- int -> float 대입은 암시적
print(f)
```

```text
7.5
5
2.5
3
```

```cy
i := 7
f := 2.5
print(i + f)
```

```text
CompileError: Expected `int`, found `float`.
```

반대 방향은 막혀 있다. `int + float`는 에러이고, `float -> int`는 `int(f)` 또는 `as[int] f`로 명시해야 한다(실수를 버림 방식으로 잘라 정수로 만든다. `int(-2.5)`는 `-2`).

```cy
var big int = 127
var small i8 = as[i8] big      -- 넓은 정수 -> 좁은 정수: 값이 맞으면 성공, 아니면 `panic: Lossy conversion from `1000` to `i8``
print(small)
f := 3.9
print(as[int] f)
print(int(f))
print(int(-2.5))
print(int('123') + 1)
print(float('1.5') * 2)
```

```text
127
3
3
-2
124
3
```

단일 문자 문자열 리터럴은 정수 자리에서 코드포인트로 취급된다. `fn f(a int)`에 `f('s')`를 넘기면 115가 들어간다(`docs.md:483-493`의 규칙). 두 글자 이상이면 "Expected argument `int`, found `str`".

### 3.5 문자열

`str`은 불변 UTF-8 바이트열이다(`core.cy:3237`: `buf`, `ptr`, `header` 필드). 큰따옴표와 작은따옴표는 같고, 보간은 `%{식}`이다(JS의 `${}`에 해당). 백틱은 이스케이프와 보간이 없는 raw 문자열, 따옴표 세 개는 여러 줄이다.

```cy
name := 'Rex'
points := 123
print('Scoreboard: %{name} %{points}')
print('calc %{points * 2 + 1} ok')
print("double 'quote' %{name}")
print(`raw %{name} \n`)
multi := """line1
line2 %{name}"""
print(multi)
```

```text
Scoreboard: Rex 123
calc 247 ok
double 'quote' Rex
raw %{name} \n
line1
line2 Rex
```

인덱스와 길이는 바이트 기준이다. 메서드는 `core.cy:3248-3880`에 있다.

```cy
s := 'hello, world'
print(s.len())
print(s.upper())
print(s.contains('world'))
print(s.replace('world', 'cyber'))
print(s.split(', ').len())
print(s[0..5])            -- 슬라이스 (끝 제외)
print(s[7..])
print(s[1])               -- 인덱스는 byte 를 돌려준다
print(s[1] == 'e')
print(s.index('o'))       -- ?int
print('ab' + 'cd')
print('x'.repeat(3))
print('🐶abc'.len())      -- 바이트 수
print('🐶abc'.count())    -- 룬(문자) 수
print('🐶abc'.rune_at(0))
print('a\\b')
```

```text
12
HELLO, WORLD
true
hello, cyber
2
hello
world
0x65
true
4
abcd
xxx
7
4
0x1f436
a\b
```

- `s[0] = 'x'` 같은 인덱스 대입은 `Unsupported type `str` for index assignment.`다. 불변이다.
- `str`끼리의 `<`, `>`는 없다("Can not find the symbol `<` in `str`"). 비교는 `a.less(b)` 또는 `a.compare(b)`다(`core.cy:3543,3739`). 동등 비교 `==`는 된다.
- 문자열 반복은 `'ab'`에 별표 두 개 연산자와 정수를 쓰는 형태도 있지만(`core.cy:3361`), 읽기 좋은 `repeat(n)`을 권한다.
- 숫자 변환은 `int('123')`, `float('1.5')`. `int('abc')`는 에러가 아니라 `0`이다(7절).

### 3.6 제어 흐름

- `if`/`else`: 추가 조건은 `else 조건:`이다. `else if`가 아니다.
- `if (조건) 값 else 값`은 식이다. 조건 괄호가 필수다.
- `while`: 무한(`while:`), 조건(`while cond:`), 언랩(`while it.next() |v|:`).
- `for`: 범위 `a..b`(끝 제외), `a..=b`(끝 포함), 내림 `a..>b`, `a..>=b`. `|i|`로 카운터를 캡처한다. 컬렉션은 `for xs |x|:` 또는 `for xs |i, x|:`.
- `switch`: `case a, b:`, 범위 `case 1..9:`(끝 포함), `=>`로 식 형태. 정수/문자열에는 `else`가 필요하고, enum/choice는 모든 case를 다루면 `else`가 필요 없다.
- 조건은 반드시 `bool`이다. `if x:`에 int를 쓰면 "Expected type `bool`, got `int`".

```cy
a := 10
if a == 10:
    print('a is 10')
else a == 20:
    print('a is 20')
else:
    print('neither')

x := 5
print(if (x > 3) 'big' else 'small')

for 0..3 |i|:
    print('i=%{i}')
for 3..>=0 |i|:
    print('down %{i}')

arr := []int{10, 20, 30}
for arr |i, n|:
    print('%{i}:%{n}')

k := 0
while:
    k += 1
    if k == 2: continue
    if k > 4: break
    print('k=%{k}')

val := 150
switch val:
    case 100:
        print('100')
    case 200, 300:
        print('200 or 300')
    case 101..200:
        print('range')
    else:
        print('else')

shu := switch 'jalapeno':
    case 'bell' => 0
    case 'jalapeno' => 2000
    else => -1
print(shu)
```

```text
a is 10
big
i=0
i=1
i=2
down 3
down 2
down 1
down 0
0:10
1:20
2:30
k=1
k=3
k=4
range
2000
```

`Map`을 `for`로 돌리면 `MapEntry`(`.key`, `.value`)가 나오고, 순서는 삽입 순서가 아니라 해시 순서다. 같은 입력이면 실행마다 같았지만 보장은 없다.

`one`, `two`, `three`, `four` 순서로 넣은 `Map[str, int]`를 `for`로 돌리면 `one`, `three`, `two`, `four` 순서로 나왔다(3회 실행 모두 같음).

### 3.7 함수, 람다, 클로저

- `fn 이름(매개변수 타입) -> 반환타입:`. 같은 타입의 매개변수는 `a, b int`처럼 묶는다. 반환 타입을 생략하면 `void`다.
- 매개변수 이름 뒤에 타입이 온다(Go/Zig 식, TS와 순서는 같고 `:`만 없다).
- 오버로딩이 된다(인자 타입 시그니처로 구분).
- 값을 반환하는 함수의 결과를 그냥 버리는 호출문은 에러다. "Expected assignment to a variable or placeholder for `int`." 버리려면 `_ = f()`.
- 함수는 값이다: `f := add`. 람다는 `fn(a, b int) -> int:` 블록 또는 목표 타입이 있는 곳의 `|a, b| 식`이다. 함수 포인터 타입은 `type BinFn = fn(int, int) -> int`처럼 별칭으로 선언한다.
- 클로저가 캡처할 수 있는 것은 참조 타입(`^T`, `&T`) 변수뿐이다. 나머지는 컴파일 에러다. 클로저를 값으로 반환하거나 저장하려면 타입을 `Func[FnType]`으로 쓴다(`src/test/functions/call_closure.cy`).

```cy
fn add(a, b int) -> int:
    return a + b

fn foo() -> int:
    return 4
fn foo(n int) -> int:
    return 10 + n

print(add(1, 2))
print(foo())
print(foo(2))

f := add
print(f(3, 4))

mul := fn(a, b int) -> int:
    return a * b
print(mul(3, 4))

type BinFn = fn(int, int) -> int
fn apply(op BinFn, a, b int) -> int:
    return op(a, b)
print(apply(|a, b| a - b, 10, 3))

fn fib(n int) -> int:
    if n < 2: return n
    return fib(n - 1) + fib(n - 2)
print(fib(20))
```

```text
3
4
12
7
12
7
6765
```

클로저는 캡처한 `^T`를 공유한다. 호출마다 새 카운터를 만드는 클로저 예제다.

```cy
type Next = fn() -> int

fn counter(start int) -> Func[Next]:
    n := ^start
    return fn() -> int:
        n.* += 1
        return n.*

a := counter(0)
b := counter(100)
print(a())
print(a())
print(b())
print(a())
```

```text
1
2
101
3
```

지역 변수를 그대로(`n := 0`) 캡처하면 문서(`docs.md:2032`의 pinned closure)와 달리 "CompileError: Can only capture variables declared with the reference types `^T` or `&T`."로 거부된다.

### 3.8 컬렉션: `[]T`, `Array[T]`, `Map`, `[N]T`, 튜플

| 타입 | 표기/생성 | 성질 |
|---|---|---|
| Slice | `[]int{1, 2}` | 가변 길이. 복사하면 버퍼를 공유한다(`core.cy:1026`). 크기를 바꾸는 메서드는 새 Slice를 돌려준다(`xs = xs.append(1)`, `xs += 1`) |
| Array | `Array[int]{1, 2}` | 가변 길이. 복사 금지(`NoCopy`), `<<`로 추가(`core.cy:1662`) |
| Map | `Map[str, int]{}` | 해시 맵. `m[k]`는 없는 키에 `panic: MissingKey`, `m.get(k)`는 `?V` |
| Vector | `[3]int{1, 2, 3}` | 고정 길이 값 타입. `[_]int{...}`로 길이 추론 |
| Tuple | `type Pt(x, y float)` | 필드 이름이 있는 값 타입. `Pt{3, 4}` 또는 `Pt{x=3, y=4}` |

`{1, 2, 3}`처럼 타입 없는 초기화 리터럴은 목표 타입이 있을 때만 쓸 수 있다(`var a []int = {1, 2, 3}`). `arr := {1, 2, 3}`은 `TODO: infer tuple type`이라는 컴파일 에러다.

```cy
xs := []int{3, 1, 2}
xs += 4
xs = xs.insert(1, 99)
xs.sort(|a, b| a < b)
print(xs.len())
print(xs[0])
print(xs.contains(99))
xs = xs.remove(0)
print(xs.join(','))
ys := xs              -- Slice 대입은 같은 버퍼를 가리킨다
ys[0] = 1000
print(xs[0])
print(xs)             -- 내용이 아니라 타입 이름이 출력된다

arr := Array[int]{1, 2, 3}
arr << 4
print(arr[3])

m := Map[str, int]{}
m['one'] = 1
print(m['one'])
print(m.get('zzz'))
print(m.size())

v := [3]int{1, 2, 3}
v[1] = 20
print(v[1])

type Pt(x, y float)
p := Pt{3, 4}
print(p.x + p.y)
```

```text
5
1
true
2,3,4,99
1000
[]int
4
1
none
1
20
7
```

`print`가 Slice 내용을 보여주지 않는 이유는 `to_print_string`(`core.cy:168-218`)이 모르는 타입이면 `type.name(T)`을 돌려주기 때문이다. 내용을 보려면 `join`이나 `for`를 쓴다.

### 3.9 struct와 메서드

`type 이름:` 아래에 `필드 타입`을 쓰면 struct다. 기본값은 컴파일 타임 상수만 허용된다. 초기화는 `이름{필드=값}`이며, 기본값이 없는 필드를 빠뜨리면 "Initialization requires the field `b`"다. 메서드는 `fn (&Type) 이름():`로 선언하고 본문에서 `self`를 쓴다. 수신자가 `&`면 읽기 빌림, `&&`면 배타적(수정) 빌림이다. 호출할 때는 `v.scale(2)`처럼 JS와 똑같이 쓴다. 정적 함수는 `fn Vec2 :: origin()`, 연산자 오버로딩은 백틱 이름 `` `+` ``이다.

```cy
type Vec2:
    x float = 0
    y float = 0

fn (&Vec2) len2() -> float:
    return self.x * self.x + self.y * self.y

fn (&&Vec2) scale(k float):
    self.x *= k
    self.y *= k

fn (&Vec2) `+`(o Vec2) -> Vec2:
    return {x = self.x + o.x, y = self.y + o.y}

fn Vec2 :: origin() -> Vec2:
    return Vec2{}

v := Vec2{x=3, y=4}
print(v.len2())
v.scale(2)
print(v.x)
w := v           -- 값 복사
w.x = 100
print('%{v.x} %{w.x}')
print((v + w).x)
print(Vec2.origin().y)
```

```text
25
6
6 100
106
0
```

필드 앞의 `-`(`-b int`)는 모듈 비공개 표시인데, 현재 구현은 다른 모듈에서의 접근을 막지 않는다(7절).

### 3.10 enum, choice, trait

- `type T enum:`과 `case 이름`은 enum이다. `print`는 `Color.green`처럼 찍는다. 정수로 바꾸려면 `as[int] c`다(`int(c)`는 에러).
- case에 타입을 붙이면(`case circle float`) choice(태그된 유니온)가 된다. `switch s:`에서 `case .circle |r|:`로 페이로드를 꺼내고, 모든 case를 다루면 `else`가 필요 없다. `s.!circle`은 "그 case가 아니면 패닉"인 언랩이다.
- trait은 `type Speaker trait:`로 인터페이스를 선언하고, 구현 타입은 `with Speaker`를 쓴다. 동적 디스패치는 `^Dyn[Speaker]`(참조) 또는 `&Dyn[Speaker]`(빌림)로 한다. 전체 예제는 5절의 과제 6이다.

```cy
type Color enum:
    case red
    case green
    case blue

c := Color.green
print(c)
print(as[int] c)
c = .blue
switch c:
    case .red: print('r')
    case .green: print('g')
    case .blue: print('b')

type Shape enum:
    case circle float
    case rect Vec2
    case point

type Vec2:
    x float
    y float

fn area(s Shape) -> float:
    switch s:
        case .circle |r|: return 3 * r * r
        case .rect |v|: return v.x * v.y
        case .point: return 0

print(area(Shape.circle(2)))
print(area(Shape.rect({x=2, y=5})))
print(area(.point))
print(Shape.circle(7).!circle)
```

```text
Color.green
1
b
12
10
0
7
```

주의: `^Dyn[Trait]` 값을 `[]`나 `Array`에 넣으면(`xs += ^Circle{...}`) 런타임에 `panic: integer overflow`로 죽었다(ARC 이중 해제, 7절). 2026-11-06에 고쳐 지금은 정상이다(F-74).

### 3.11 Option: `?T`

`?T`는 `Option[T]`(`core.cy:4091`)이다. 값을 `T`로 쓰면 자동으로 `some`으로 감싸진다. 쓰려면 반드시 풀어야 한다.

- `if opt |v|:` / `while it.next() |v|:`: 값이 있을 때만 블록 실행
- `opt ?else 기본값`: 기본값 대체
- `opt.?`: 없으면 패닉 ("panic: Expected active choice tag `1`, found `0`.". 문서의 "Option is empty."와 메시지가 다르다)
- `none`은 목표 타입이 있어야 한다. `tn(none)` 같은 곳에서는 "Could not determine optional type for `none`."이다.

```cy
fn find(xs []int, t int) -> ?int:
    for xs |i, x|:
        if x == t: return i
    return none

xs := []int{5, 6, 7}
print(find(xs, 6))
print(find(xs, 9))
if find(xs, 7) |idx|:
    print('idx=%{idx}')
print(find(xs, 9) ?else -1)

var a ?str = 'abc'
print(a.?)
var b ?str = none
if b |v|:
    print(v)
else:
    print('b is none')
```

```text
1
none
idx=2
-1
abc
b is none
```

### 3.12 Result: `!T`와 패닉

`!T`는 "에러 또는 T"인 값이다. 에러는 `error.Name` 리터럴(심볼 기반)이다. 풀이는 세 가지다.

- `expr!`: 에러면 호출한 함수의 호출자에게 그대로 반환한다(rethrow). 그 함수의 반환 타입이 `!T`여야 한다. main block에서는 패닉이 된다.
- `expr !else 기본값`
- `expr !else |err|:` 블록: 블록은 반드시 끝에서 빠져나가야 한다(`return`/`panic`). 블록이 값을 내는 형태는 아직 없다(`Expected unreachable block end.`, `docs.md`의 `break value`는 Planned).

`try:` 블록은 2026-11-09(F-32)부터 동작한다. 본문 안의 `!`가 실패하면 함수 반환 · panic 대신 `else |err|:` 블록으로 뛰고, `else` 블록은 끝에 도달해도 된다(`docs.md` Unwrap block). `panic(msg)`는 잡을 수 없고 스레드를 멈추며 스택 트레이스를 stderr로 낸다. 종료 코드는 1.

```cy
fn parse(s str) -> !int:
    if s.len() == 0:
        return error.Empty
    n := int.parse(s)!
    if n > 100:
        return error.TooBig
    return n

fn describe(s str) -> str:
    n := parse(s) !else |err|:
        return 'failed: %{err}'
    return 'ok: %{n}'

print(parse('42') !else 0)
print(parse('') !else -1)
print(describe('10'))
print(describe(''))
print(describe('500'))
print(describe('xyz'))
```

```text
42
-1
ok: 10
failed: error.Empty
failed: error.TooBig
failed: error.InvalidCharacter
```

패닉의 모양은 이렇다. 라이브러리 안쪽 프레임(`core.cy`)이 같이 찍힌다.

```cy
fn deep(n int) -> int:
    if n == 0:
        panic('boom at the bottom')
    return deep(n - 1) + 1
print(deep(2))
```

```text
panic: boom at the bottom
```

### 3.13 참조 `^T`, 빌림 `&T`, `move`, 소멸자

- `^값`은 값을 힙으로 올리고 참조 `^T`를 돌려준다. 참조는 대입하면 공유되고(ARC), `.*`로 역참조한다. 구조체 필드는 `pos.x`처럼 바로 접근된다.
- `&값`은 빌림이다. 스택 밖으로 나갈 수 없고, 메서드 수신자(`&Type`)와 `&int` 같은 매개변수에 쓴다.
- `move a`는 소유권을 옮긴다. 이후 `a`를 쓰면 컴파일 에러다. `Array`처럼 복사가 금지된 값을 함수에 넘길 때도 `move`가 필요하다.
- `fn (&Type) @deinit():`은 값이 소멸할 때(스코프 끝, 재대입) 호출된다.

```cy
i := 123
ref := ^i
ref.* = 456
print('%{ref.*} %{i}')

type P:
    x int
    y int
pos := ^P{x=4, y=5}
pos2 := pos             -- 같은 힙 값을 공유
pos2.y = 50
print(pos.y)

a := 123
fn inc(p &int):
    p.* += 1
inc(&a)
print(a)

type Res:
    name str
fn (&Res) @deinit():
    print('release %{self.name}')
begin:
    r1 := Res{name='A'}
    print('in scope')
print('after scope')
r2 := Res{name='B'}
r2 = Res{name='C'}
print('end of main')
```

```text
456 123
50
124
in scope
release A
after scope
release B
end of main
release C
```

`b := move a` 뒤에 `print(a)`를 쓰면 "CompileError: `a` is no longer alive in this scope."다.

### 3.14 템플릿(제네릭)과 컴파일 타임 분기

- `fn add[T Any](a T, b T) -> T`: 명시적 템플릿. `add[int](1, 2)`처럼 대괄호로 확장한다. 인자만으로는 추론되지 않아 `add(1, 2)`는 "Unsupported call from symbol: `func_template`".
- `fn largest(a %T, b T) -> T`: `%T`가 인자 타입에서 추론되는 템플릿 매개변수다. `[]%T`처럼 안쪽 타입도 추론된다.
- `fn zero(%T type) -> T`: 타입을 값처럼 받는 제네릭 함수.
- `type Box[T Any]:`: 타입 템플릿. 같은 인자로 확장하면 같은 타입이 나온다(memoized).
- `#if T == int:` / `#else:`는 확장 시점에 평가되는 컴파일 타임 분기다. 표준 `print`/`to_print_string`도 이 방식으로 타입별 분기를 한다(`core.cy:168`).

```cy
fn add[T Any](a T, b T) -> T:
    return a + b
print(add[int](1, 2))
print(add[float](1, 2))

fn largest(a %T, b T) -> T:
    return if (a > b) a else b
print(largest(3, 9))

fn last_of(xs []%T) -> T:
    return xs[xs.len() - 1]
print(last_of([]str{'x', 'y', 'z'}))

fn zero(%T type) -> T:
    return T(0)
print(zero(int))

type Box[T Any]:
    id    int
    value T
fn (&Box[]) get() -> T:
    return self.value
print(Box[str]{id=1, value='abc'}.get())

fn describe(x %T) -> str:
    #if T == int:
        return 'int'
    #else T == str:
        return 'str'
    #else:
        return 'other: ' + type.name(T)
print(describe(1))
print(describe(1.5))
```

```text
3
3
9
z
0
abc
int
other: float
```

### 3.15 모듈: `use`

- `use math`: 내장/표준 모듈(`math`, `os`, `io`, `test`, `meta`, `cy`...). 이름이 그대로 로컬 이름이 된다.
- `use g 'geometry.cy'`: 상대 경로 파일. 로컬 이름을 앞에 쓰고 경로는 문자열이다. URL도 가능하다(`docs.md:3279`).
- `use * 'x.cy'`: 모든 심볼을 현재 네임스페이스에 가져온다(실험적).
- 가져온 모듈에는 최상위 문장이 있을 수 없다(선언만). 진입 파일은 최상위 문장을 쓰거나 `fn main()`을 선언한다. 둘을 섞으면 "Body statement is not allowed when main function is declared."다(`src/test/functions/main_func_top_stmt_error.cy`).
- `os.args()`는 `[]str`이며 0번이 스크립트 경로다. `cyber main5.cy a b`이면 `{main5.cy, a, b}`다.

```bash
$ cat geometry.cy
type Point:
    x int
    y int

fn dist2(p Point) -> int:
    return p.x * p.x + p.y * p.y

global calls int = 0

fn bump() -> int:
    calls += 1
    return calls

$ cat main.cy
use math
use g 'geometry.cy'
use test

p := g.Point{x=3, y=4}
print(g.dist2(p))
print(g.bump())
print(g.bump())
print(math.sqrt(16))
test.eq(25, g.dist2(p))

$ cyber main.cy
25
1
2
4
```

### 3.16 속성 `#[...]`

선언 앞에 붙는 속성은 `parser.zig:19-29`의 고정 표에 9개뿐이다: `bind`, `extern`, `reserve`, `call`, `generator`, `cond`, `unsafe`, `consteval`, `jit`. 사용자 정의 속성은 없다.

| 속성 | 의미 | 확인한 곳 |
|---|---|---|
| `#[bind]` | 본문 대신 호스트(Zig) 구현에 연결 | `sema.zig:2794,2841`, `core.cy` 곳곳 |
| `generator fn` | 함수를 제너레이터로 만든다. 속성이 아니라 `fn` 앞의 수식어다(2026-11-11 전에는 `#[generator]`) | `sema.zig:2847`, `src/test/concurrency/generator.cy` |
| `#[consteval]` | 컴파일 타임에만 호출 가능 | `sema.zig:2850` |
| `#[reserve]` | 빌트인 연산자 슬롯 예약(본문 없음) | `sema.zig:2853`, `core.cy:247,359` |
| `#[extern]` | C ABI 함수(FFI) | `sema.zig:2844` |
| `#[cond=식]` | 조건이 참일 때만 선언 | `src/std/os.cy:5` |
| `#[jit]` | JIT 힌트 (JIT는 죽은 코드) | `sema.zig:2859` |
| `#[unsafe]`, `#[call]` | 파서에 있음. 쓰임은 이 챕터에서 미확인 | `core.cy:2678` |

### 3.17 테스트: `use test`

`test.eq(기대, 실제)`는 같지 않으면 패닉으로 종료 코드 1을 낸다. 저장소의 `src/test` 하위 `.cy` 파일이 모두 이 방식이고, 통과하면 출력 없이 종료한다. 파일 끝의 `--cytest: pass` / `--cytest: error` 주석은 Zig 쪽 러너(`src/behavior_test.zig`)가 읽는 기대 결과다(08 챕터).

```cy
use test
test.eq(4, 2 + 2)
test.eq('ab', 'a' + 'b')
test.assert(1 < 2)
print('pass')
test.eq(5, 2 + 2)
```

```text
pass
panic: Expected `5`, found `4`.
...
```

### 3.18 제너레이터, `spawn`, `Future` 맛보기

- `generator fn`은 호출하면 본문을 실행하지 않고 `Generator[...]`를 돌려준다. `yield 값`으로 내보내고 `while g.next() |v|:`로 소비한다. `next()`는 `?T`다(`core.cy:4319-4351`).
- `spawn(함수, {인자...})`는 새 스레드에서 실행하고 `Future[T]`를 돌려준다. `.await()`로 결과를 기다린다(`core.cy:4381`). 인자는 튜플 리터럴이다. `Future.complete(값)`은 이미 끝난 Future다.
- 주의: 이 투어는 제너레이터의 상태를 힙 객체(`^State`)에 둔 예제만 쓴다. 제너레이터 본문의 지역 변수는 `yield` 사이에 값이 보존되지 않는 문제가 있어(`i := 10; yield i; i += 1; yield i`가 `10, 11, 11`) [07-coroutines-concurrency.md](07-coroutines-concurrency.md)에서 따로 다룬다.

```cy
type State:
    cur int
    limit int

generator fn squares(s ^State) -> int:
    while s.cur < s.limit:
        yield s.cur * s.cur
        s.cur += 1

st := ^State{cur=1, limit=5}
g := squares(st)
while g.next() |v|:
    print(v)

fn fib(n int) -> int:
    if n < 2: return n
    return fib(n - 1) + fib(n - 2)

f := spawn(fib, {25})
print(f.await())
print(Future.complete(100).await())
```

```text
1
4
9
16
75025
100
```

### 3.19 TypeScript 대조표

| TypeScript/Node | Cyber 0.4 |
|---|---|
| `let x = 1` / `const x = 1` | `x := 1`(재대입 가능). `const x = 1`은 컴파일 타임 상수 |
| `x: number` | `int`와 `float`가 분리되어 있다. 암시적 변환은 `int -> float` 방향만 |
| `` `a ${b}` `` | `'a %{b}'` |
| `// 주석` | `-- 주석` |
| `{ ... }` | `:` 와 들여쓰기 |
| `function f(a: number): number {}` | `fn f(a int) -> int:` |
| `(a, b) => a + b` | 타입이 정해진 자리에서 `\|a, b\| a + b`, 일반적으로는 `fn(a, b int) -> int:` 블록 |
| `interface` / `type X = {...}` | struct는 `type X:`, 인터페이스는 `trait` |
| `class` / `this` / 메서드 | `type` + `fn (&X) m():` + `self`. 상속은 없다 |
| 판별 유니온 (`kind` 필드) | choice(`enum` + 페이로드) + `switch` (모든 case 검사) |
| `T \| undefined`, `?.`, `??` | `?T`, `if x \|v\|`, `.?`, `?else` |
| `throw` / `try-catch` | `!T`, `error.X`, `expr!`, `expr !else ...`, `panic` |
| `T[]` / `Array<T>` | `[]T`(Slice), `Array[T]` |
| `Map<K, V>` | `Map[K, V]` (순회 순서는 해시 순서) |
| `for (const x of xs)` | `for xs \|x\|:` |
| `for (let i=0; i<n; i++)` | `for 0..n \|i\|:` |
| `import m from './m'` | `use m 'm.cy'`, 표준은 `use math` |
| `function f<T>(x: T)` | `fn f[T Any](x T)` 또는 `fn f(x %T)` |
| `function*` / `yield` | `generator fn` + `yield`. 소비는 `while g.next() \|v\|:` |
| `async`/`await`, Promise | `spawn(f, {인자})` -> `Future[T]`, `.await()` |
| `console.log(a, b)` | `print(x)` (인자 하나, 문자열 보간으로 합친다) |
| `process.argv` | `os.args()` |
| `null`, `undefined` | `none` (`?T` 안에서만) |
| 객체 대입은 참조 공유 | struct 대입은 복사. 공유는 `^T` |
| 타입 소거 제네릭 | 사용 시점 확장(memoized) 템플릿 |
| GC | 소유권 + ARC, 소멸자 `@deinit` |

## 4. 소스 읽기 지도

이 챕터는 컴파일러가 아니라 언어 사용법이 대상이므로 "언어가 실제로 하는 일"을 확인하는 곳을 가리킨다.

| 알고 싶은 것 | 어디를 보나 |
|---|---|
| 문법의 의도와 설계 설명 | `docs/docs.md`. 목차 줄: 문법 48, 기본 타입 402, 커스텀 타입 1071, 제어 흐름 1646, 함수 1890, 메모리 2143, 에러 2553, 동시성 2712, 메타 2978, 모듈 3205. 단, 구현과 어긋난 곳이 있다(7절) |
| 문법이 실제로 허용되는지 | `src/test` 하위 `.cy`. 디렉터리별: `control_flow/`, `core/`, `functions/`, `types/`, `vars/`, `memory/`, `syntax/`, `modules/`, `concurrency/`, `meta/` |
| 기대되는 에러 메시지 | 파일명이 `_error.cy`로 끝나는 테스트의 마지막 `--cytest: error` 주석 아래 `--CompileError: ...` 줄 |
| 표준 타입의 메서드 | `src/builtins/core.cy`: `Int` 395, `Float` 596, `Slice` 1026, `Array` 1662, `Map` 2181, `str` 3237, `Result` 4071, `Option` 4091, `Future` 4102, `Generator` 4319, `spawn` 4381 |
| 표준 모듈 | `src/std/math.cy`, `os.cy`, `io.cy`, `test.cy`, `cli.cy` |
| 속성 목록 | `src/parser.zig:19-29`, 적용 위치 `src/sema.zig:2833-2865` |
| 명령줄 처리 | `src/main.zig:56-133` |

추천 순서: (1) `src/test/core/` 의 `Option.cy`, `Result.cy`, `ints.cy`를 읽는다. 각 파일이 한 기능의 명세다. (2) `src/test/types/`에서 struct, enum, trait. (3) `core.cy`에서 `Slice`와 `str`의 메서드 몇 개. 파일이 `fn (&Slice[]) append(...)`처럼 Cyber 문법으로 쓰여 있어 이 투어의 문법을 그대로 복습할 수 있다.

## 5. 실습: 미니 과제 8개와 풀이

각 과제는 풀이를 가리고 먼저 직접 써 본다. 풀이는 모두 `cyber 파일.cy`로 실행해 출력을 확인한 것이다. 힌트는 해당 3.x 절에 있다.

과제 1. 1부터 15까지 FizzBuzz를 한 줄로 출력하라. (3.5, 3.6)

```cy
out := ''
for 1..=15 |i|:
    if i % 15 == 0:
        out += 'FizzBuzz '
    else i % 3 == 0:
        out += 'Fizz '
    else i % 5 == 0:
        out += 'Buzz '
    else:
        out += str(i) + ' '
print(out)
```

```text
1 2 Fizz 4 Buzz Fizz 7 8 Fizz Buzz 11 Fizz 13 14 FizzBuzz
```

과제 2. 문장 `the cat and the hat and the bat`의 단어 빈도를 알파벳 순으로 출력하라. `Map`의 순회 순서에 의존하면 안 된다. (3.8)

```cy
text := 'the cat and the hat and the bat'
counts := Map[str, int]{}
for text.split(' ') |word|:
    counts[word] = (counts.get(word) ?else 0) + 1

keys := []str{}
for counts |e|:
    keys += e.key
keys.sort(|a, b| a.less(b))
for keys |k|:
    print('%{k}: %{counts[k]}')
```

```text
and: 2
bat: 1
cat: 1
hat: 1
the: 3
```

`m.keys()`가 있지만 현재 쓸 수 없어서(7절) 키는 직접 모았다.

과제 3. 2차원 벡터 `Vec2`에 `+`와 `*`(스칼라) 연산자를 정의하고 `(a + b) * 2`를 계산하라. (3.9)

```cy
type Vec2:
    x float
    y float

fn (&Vec2) `+`(o Vec2) -> Vec2:
    return {x = self.x + o.x, y = self.y + o.y}

fn (&Vec2) `*`(k float) -> Vec2:
    return {x = self.x * k, y = self.y * k}

fn (&Vec2) len2() -> float:
    return self.x * self.x + self.y * self.y

a := Vec2{x=1, y=2}
b := Vec2{x=3, y=4}
c := (a + b) * 2
print(c.x)
print(c.y)
print(c.len2())
```

```text
8
12
208
```

과제 4. 정수 슬라이스에서 첫 짝수를 `?int`로 돌려주는 함수를 만들고 `if ... |v|`와 `?else`로 사용하라. (3.11)

```cy
fn first_even(xs []int) -> ?int:
    for xs |x|:
        if x % 2 == 0:
            return x
    return none

print(first_even([]int{1, 3, 4, 6}))
print(first_even([]int{1, 3, 5}))
if first_even([]int{7, 8}) |v|:
    print('found %{v}')
print(first_even([]int{1, 3}) ?else -1)
```

```text
4
none
found 8
-1
```

과제 5. 0으로 나누면 `error.DivByZero`를 돌려주는 `safe_div`를 만들고, `!`로 전파하는 `calc`와 `!else |err|`로 처리하는 `report`를 작성하라. 최상위 문장 대신 `fn main()`을 쓴다. (3.12)

```cy
fn safe_div(a, b float) -> !float:
    if b == 0:
        return error.DivByZero
    return a / b

fn calc(a, b float) -> !float:
    q := safe_div(a, b)!
    return q + 1

fn report(a, b float):
    msg := calc(a, b) !else |err|:
        print('error: %{err}')
        return
    print('result: %{msg}')

fn main():
    print(calc(10, 4) !else -1)
    print(calc(1, 0) !else -1)
    report(10, 4)
    report(1, 0)
```

```text
3.5
-1
result: 3.5
error: error.DivByZero
```

과제 6. `area()`를 가진 `Shape` trait을 만들고 `Circle`, `Rect`를 구현한 뒤 `^Dyn[Shape]`를 받는 함수로 호출하라. (3.10)

```cy
type Shape trait:
    fn area() -> float
    fn name() -> str

type Circle:
    with Shape
    r float

type Rect:
    with Shape
    w float
    h float

fn (&Circle) area() -> float:
    return 3 * self.r * self.r
fn (&Circle) name() -> str:
    return 'circle'

fn (&Rect) area() -> float:
    return self.w * self.h
fn (&Rect) name() -> str:
    return 'rect'

fn describe(s ^Dyn[Shape]):
    print('%{s.name()} area=%{s.area()}')

describe(^Circle{r=2})
describe(^Rect{w=3, h=4})

var cur ^Dyn[Shape] = ^Circle{r=1}
print(cur.area())
cur = ^Rect{w=2, h=5}
print(cur.area())
```

```text
circle area=12
rect area=12
3
10
```

과제 7. 제네릭 `Stack[T]`를 만들고 `push`, `pop`(비면 `none`), `size`를 구현하라. 수신자를 `^Stack[]`로 쓰는 이유는 7절의 `&&` 수신자 버그 때문이다. (3.8, 3.11, 3.14)

```cy
type Stack[T Any]:
    items Array[T]

fn (^Stack[]) push(x T):
    self.items << x

fn (^Stack[]) pop() -> ?T:
    n := self.items.len()
    if n == 0:
        return none
    top := self.items.last()
    self.items.size_down(n - 1)
    return top

fn (^Stack[]) size() -> int:
    return self.items.len()

s := ^Stack[int]{items={}}
s.push(1)
s.push(2)
print(s.size())
print(s.pop())
print(s.pop())
print(s.pop())
```

```text
2
2
1
none
```

과제 8. `fib(20)`부터 `fib(24)`를 `spawn`으로 병렬 계산하고 `Future`를 모아 합계를 출력하라. (3.18)

```cy
fn fib(n int) -> int:
    if n < 2: return n
    return fib(n - 1) + fib(n - 2)

fs := []Future[int]{}
for 20..25 |n|:
    fs += spawn(fib, {n})
total := 0
for fs |f|:
    total += f.await()
print(total)
```

```text
110447
```

## 6. 0.3 -> 0.4 변경 관점 / 설계 철학 메모

옛 자료를 만났을 때 바로 번역할 수 있도록 0.3 문법과 0.4 문법을 대응시킨다(0.3 쪽은 `git show 0.3:docs/hugo/content/docs/toc/*.md`로 확인했다).

| 0.3 | 0.4 |
|---|---|
| `print x` | `print(x)` (함수 호출, 인자 하나) |
| `my a = 1`(동적), `var a = 1` | `a := 1`, `var a T = ...` |
| `func f(a, b)` | `fn f(a, b int) -> int:` |
| `import math` | `use math`, `use m 'x.cy'` |
| `type Node object:` | `type Node:` (struct, 값 타입) |
| `'$(name)'` 보간 | `'%{name}'` |
| `throw` / `try` / `catch` | `!T`, `error.X`, `!`, `!else`, `panic` |
| `coinit` / `coresume` / `coyield` | `generator fn` + `yield`, `spawn`/`Future` |
| 동적 타입 `dyn`, `any` | 정적 타입. 동적 디스패치는 `^Dyn[Trait]` |

설계 철학은 "실패와 소유권을 타입에 드러낸다"로 요약된다. `Option`/`Result`/`move`/`^T`/`&T`가 모두 타입 시스템 안의 값이라서, 코딩 에이전트처럼 생성된 코드를 자동 실행하는 환경에서는 컴파일 타임에 거를 수 있는 오류 범위가 넓다는 이점이 있다(추정. 05 챕터의 패닉/인터럽트와 함께 평가해야 한다).

이 fork를 이어받는 관점에서 이번 투어가 찾아낸 우선 수정 후보는 다음과 같다(7절의 재현 방법 참고). 표준 라이브러리 안의 Cyber 코드 결함이 많아서 Zig를 건드리지 않고 `core.cy`만 고쳐서 풀리는 항목이 대부분이다: `Slice.index` 무한 재귀, `Int.parse`의 음수, `HashMap.keys`. 반대로 `&&` 수신자의 필드 빌림은 `bc_gen.zig`에서 풀어야 할 가능성이 높다(03, 04 챕터에서 원인 분석). `cyber fmt`는 구현 자체가 없어 01 챕터의 `cy.parse`와 AST를 이용한 새 구현 후보다.

## 7. 알려진 이슈, 문서와 코드의 차이, 미완 지점

### 7.1 자주 막히는 지점 (실제 메시지)

| 메시지(첫 줄) | 원인 | 해결 |
|---|---|---|
| `ParseError: Expected end of line or file. Got string.` | `print "hi"` (0.3 문법) | `print('hi')` |
| `ParseError: Expected end of line or file. Got ident.` | `let x`, `function f()`, `class Foo` | `x := 1`, `fn f():`, `type Foo:` |
| `ParseError: Expected `(`.` | `else if a == 1:` | `else a == 1:` |
| `ParseError: Expected :.` | `for i in 0..3:` | `for 0..3 \|i\|:` |
| `ParseError: Expected end of line or file. Got semicolon.` | 문장 끝 `;` | 지운다 |
| `ParseError: Unknown token: slash` | `//` 주석 | `--` |
| `ParseError: Expected spaces for indentation.` | 탭과 공백 혼용 | 한 파일은 한 가지만 |
| `ParseError: Expected right operand.` | `a++`, 별표 두 개 복합 대입, `10 // 3` | `a += 1` 등 |
| `Variable `x` is already declared in the block.` | 같은 블록에서 `x :=` 반복 | 대입 `x = ...` |
| `Undeclared variable `x`.` | 선언 없이 `x = 5`, 또는 함수에서 바깥 지역 변수 읽기 | `x := 5`, `global`, 매개변수 |
| `Expected `int`, found `float`.` | `int + float` (왼쪽 타입에 맞춰짐) | `float(i) + f` 또는 변수를 float 로 |
| `Expected type `int`, got `float`.` | `var x int = 2.5`, `x = 2.5` | `int(2.5)` |
| `TODO: infer tuple type` | `arr := {1, 2, 3}` | `[]int{1, 2, 3}` |
| `Expected assignment to a variable or placeholder for `int`.` | 값을 돌려주는 호출을 문장으로 사용 | `_ = f()` 또는 변수에 대입 |
| `Can only capture variables declared with the reference types `^T` or `&T`.` | 클로저가 `n := 0` 캡처 | `n := ^0` |
| `Cannot copy `Array[int]`, type implements `NoCopy`.` | `b := a` | `move a` |
| `` `a` is no longer alive in this scope.`` | `move` 후 사용 | 이동 후 원본을 쓰지 않는다 |
| `Expected `else` case since switch does not handle all cases.` | int/str `switch`에 `else` 없음 | `else:` 추가 |
| `Can not find the symbol `&&` for `bool`.` | JS의 `&&` | `and` (`&&`는 비트 AND) |
| `Expected type `bool`, got `int`.` | `if x:` (truthy) | `if x != 0:` |
| `Return statement is not allowed in the main block.` | 최상위에서 `return` | `fn main():` 로 감싼다 |
| "Unsupported call from symbol: `func_template`". | `fn f[T Any]`를 `f(x)`로 호출 | `f[int](x)` 또는 `fn f(x %T)` |
| `Could not determine optional type for `none`.` | 목표 타입 없는 `none` | `var a ?int = none` |
| `Field `len` does not exist in `[]int`.` | `xs.len` (속성 아님) | `xs.len()` |
| `Can not find the symbol `+` for `?int`.` | Option 을 풀지 않고 산술 | `x.?`, `if x \|v\|`, `?else` |
| `Expected unreachable block end.` | `!else \|err\|:` 블록이 끝에서 빠져나가지 않음 | 블록 끝에 `return`/`panic` |
| `Unsupported: Color` (위치가 `core.cy:438`) | `int(enum값)` | `as[int] c` |

마지막 항목처럼 템플릿 안에서 난 에러는 사용자 코드가 아니라 `core.cy`의 줄을 가리킨다. 사용자 줄은 그 아래 스택에 있다고 가정하지 말고 호출한 식을 직접 확인한다.

### 7.2 문서와 코드의 차이 (모두 실행으로 확인)

| 문서(`docs/docs.md`) | 실제 |
|---|---|
| `arr := {1, 2, 3}`, `map := {a=123}` (1777, 1785) | 목표 타입이 없으면 `TODO: infer tuple type` |
| `print(int(fruit))  --> 3` (1478) | `Unsupported: Fruit` 컴파일 에러. `as[int] fruit` |
| `print(add[float](1, 2)) --> 3.0` (2108) | `3`. 정수 값 실수는 소수점 없이 출력 |
| `.?`의 패닉 `Option is empty.` (777) | `panic: Expected active choice tag `1`, found `0`.` |
| 비참조 지역 변수 캡처는 pinned closure (2032) | `Can only capture variables declared with the reference types ...` |
| `Func(FN)` (2064) | `Func[FN]`가 실제 표기(`src/test/functions/call_closure.cy:17`) |
| `case 100` / `case 200` 본문 없는 fallthrough 예제 (1850) | 그대로 쓰면 `ParseError: Unexpected indentation.` |
| `try:` ... `catch err:` (2656 부근) | 구현 없음(TBD). `!else`만 사용. 2026-11-09 구현(F-32): `try:` ... `else |err|:`, 매뉴얼의 `catch err:` 문단은 삭제 |
| `-` 접두 비공개 (1159, 3290대) | 다른 모듈에서 `x.b`, `u.hidden()` 접근이 막히지 않는다. 가시성 검사 자리는 `module.zig:502,510`에 `TODO: check visibility.` 2026-11-09 수정 `2646638d`(F-30): 이제 컴파일 오류 |

### 7.3 구현 버그와 놀라운 점 (HEAD b40531a1, 재현 방법 포함)

1. `[]T.index(needle)`이 끝나지 않는다. `xs := []int{3, 1, 2}; print(xs.index(1))`가 무한 대기(10초 타임아웃에서 종료 코드 142). `core.cy:1293-1294`가 `return self[..].index(needle)`인데 Slice의 `self[..]`는 다시 Slice를 돌려줘 자기 자신을 호출한다(`cyber compile`에서 `fn []int.index`가 `Slice.index`를 call). `contains`는 정상이다.
2. `int.parse('-5')`가 `error.InvalidCharacter`다. `core.cy:476-482`에서 `-`를 만나 `res = -res`를 한 뒤 `else` 없이 숫자 검사로 떨어진다. `int.parse('')`은 `0`이고 `int('abc')`는 오류 없이 `0`(`core.cy:417`).
3. `Map.keys()`는 호출하면 컴파일 에러다("Undeclared variable `@iterator`"). `core.cy:2362-2367`이 옛 문법 `@iterator()`/`@next(&iter)`를 쓴다.
4. 구조체의 `Array` 필드를 `&&` 수신자 메서드에서 변경하면 결과가 틀리거나 죽는다. 재현:

```cy
type D:
    items Array[int]

fn (&&D) push(x int):
    self.items << x

d := D{items=Array[int]{}}
d.push(1)
d.push(2)
d.push(3)
print(d.items.len())
```

   `3`이어야 하지만 `1`이 나온다(필드 앞에 다른 필드를 두면 segfault). `cyber compile`을 보면 `fn D.push`가 `addr %7 = *%4`로 `self`(빌림 포인터가 든 슬롯 %4)의 주소를 필드 시작 주소로 쓴다. 정수 필드 접근(`load_64 [%4 + 0]`)은 포인터 값을 제대로 쓴다. `^D` 수신자나 메인 블록의 `d.items << 1`은 정상이다. 원인 후보는 bc_gen의 "빌림 매개변수를 거친 필드의 주소 취하기" 경로이며 03/04 챕터에서 확인한다(추정). 2026-11-09 수정 `b8e9f759`(F-73): 추정이 맞았다. `addr %7 = *%4`는 VM에서 레지스터 `%4`의 주소라 `self`(`&&D`)가 든 슬롯이 `Array`로 읽혔다. `genAddressOfField`가 `&&T`(`ex_borrow`)를 `&T`처럼 주소로 보지 않은 것이 원인이고, `38272a0c` 이후 인라인된 호출에서만 증상이 사라졌었다(인라인되지 않는 긴 본문은 HEAD에서도 세그폴트). `docs/decisions/project_ex_borrow_field_addr.md`.
5. `^Dyn[Trait]` 값을 `[]`/`Array`/`ArrayStore`에 넣으면 죽는다(`xs += d`). ReleaseSafe에서는 `panic: integer overflow`, 트레이스 빌드에서는 `Double free`다(Circle의 힙 객체를 `@copy`한 뒤 이중 해제). 컨테이너 없이 `^Dyn`/`&Dyn`를 인자로 넘기고 변수에 재대입하는 것은 정상이다. 2026-11-06 수정: `@copy`의 `.ref_trait` 분기가 impl을 retain하지 않던 것이 원인이었다(F-74).
6. `cyber fmt`는 `std.debug.panic("TODO: Embed src/tools/fmt.cy")`다(`main.zig:120-121`). (2026-11-11 갱신: `cyber fmt`는 `src/format.zig`로 구현됐다. `docs/decisions/project_fmt.md`)
7. `print(slice)`는 내용 대신 `[]int`를, `dump(x)`는 값 대신 타입 구조를 출력한다. (2026-11-04 둘 다 값을 찍도록 수정, `docs/decisions/project_print_string.md`)
8. `-fn`/`-필드` 비공개 표시는 대부분 강제되지 않는다(7.2).
9. 정수 오버플로는 랩어라운드하고(`9223372036854775807 + 1`), 단일 문자 문자열이 정수 자리에서 코드포인트로 바뀐다(`f("s")`가 115).
10. 제너레이터 지역 변수 상태 보존 문제는 07 챕터에서 다룬다.

## 8. 이해도 확인 Q&A

### Q1. `x float`, `y int`일 때 `x + y`는 되는데 `y + x`는 왜 안 되는가?

A: 이항 연산에서 왼쪽 피연산자의 타입이 오른쪽의 목표 타입이 되기 때문이다(`sema.zig:8401` 이하, `semaExprCstr(right_n, left.type)`). `x + y`는 오른쪽 `int`를 `float`로 암시적 변환하지만, `y + x`는 `float`를 `int`로 줄여야 해서 문서의 "손실 변환은 암시적이지 않다" 규칙에 걸린다. 왼쪽이 숫자 리터럴이면 오른쪽에서 타입을 가져온다.

### Q2. 왜 `Slice`와 `Array`가 둘 다 있는가?

A: 복사 의미가 다르다. `Slice`(`[]T`)는 복사 가능하고 대입하면 버퍼를 공유하며(3.8의 `ys := xs`), 크기를 바꾸는 메서드가 새 값을 돌려준다(`xs = xs.append(1)`). `Array`는 `NoCopy`이고 `core.cy:1660`의 설명대로 크기를 바꾸는 연산에 배타적 빌림(`&&`)이 필요하다. 요소에 대한 안정된 주소(`&a[2]`)를 허용하려는 설계로 읽힌다(`docs.md:2389`의 설명. 설계 의도는 추정).

### Q3. 클로저가 `n := 0` 같은 지역 값을 직접 캡처하지 못하는 이유는?

A: 확인된 사실은 컴파일러가 `^T`/`&T`만 허용한다는 것이다. 이유는 추정이다. 클로저는 함수가 끝난 뒤에도 살 수 있는데 스택 값은 스코프 끝에서 소멸하므로, 수명을 힙의 참조 카운트(`^T`)에 맡기게 한 것으로 보인다. 문서가 말하는 pinned closure(복사/이동 불가)는 구현되어 있지 않다.

### Q4. `!else |err|:` 블록이 값을 만들 수 없을 때 값이 필요한 경우 어떻게 쓰는가?

A: 블록은 반드시 `return`/`panic`으로 빠져나가야 한다. 그래서 (1) 기본값이면 `expr !else 기본값`, (2) 에러 종류에 따라 다른 값이면 별도 함수로 감싸 그 함수 안에서 `return`한다(`describe`), (3) 이상 상황이면 `!else |err|: panic(...)` 형태가 된다. `docs.md`의 `break value` 형태는 Planned다.

### Q5. struct를 기본으로 두고 언제 `^T`로 올려야 하는가?

A: 이 투어의 실험에서 `^`가 필요했던 경우는 (1) 여러 곳이 같은 값을 공유하고 수정해야 할 때(`pos2 := pos`), (2) 클로저가 값을 캡처할 때, (3) `Dyn` 동적 디스패치, (4) 제너레이터의 상태를 호출 사이에 보존할 때였다. 나머지는 값(복사)이 기본이고 큰 값은 `&`로 빌려 넘긴다.

### Q6. `print(xs)`가 `[]int`만 찍는다. 내용이 찍히게 하려면 어디를 고치는가?

A: `to_print_string`(`core.cy:168`)은 알려진 기본 타입과 enum/option 등만 처리하고 나머지는 `type.name(T)`을 돌려준다. `Slice`, `Array`, `Map`을 위한 분기를 `#else:` 앞에 `#if type.is_instance_of(...)`류로 추가하면 된다. 단, 에이전트 루프에서는 출력 포맷이 계약이 되므로 먼저 어떤 형식으로 고정할지 정해야 한다(설계 결정 필요).

## 9. 더 알아보기

- 키워드: 토크나이저의 키워드 표와 0.3 대비 변화는 [01-pipeline-front-end.md](01-pipeline-front-end.md).
- 심볼/타입: `Int[W]`, `Raw[W]`, 템플릿 확장과 memoize는 02 챕터(02-symbols-and-types.md).
- 암시적 변환과 `semaBinExpr`의 실제 구현은 03 챕터(03-sema-and-ir.md).
- `&&` 필드 빌림 버그의 원인 후보 `bc_gen.zig`와 인라인은 04 챕터(04-bytecode-gen.md).
- `^T`/`&T`/ARC/`@deinit`은 06 챕터(06-memory-ownership.md), 제너레이터/`spawn`/`Future`는 [07-coroutines-concurrency.md](07-coroutines-concurrency.md).
- `use test`와 `--cytest:` 러너, `#[bind]`는 08 챕터(08-embedding-builtins-tests.md).
- 설계 배경: [type_system.md](../history/type_system.md), [error_handling.md](../history/error_handling.md), [ownership_memory.md](../history/ownership_memory.md), [coroutines_concurrency.md](../history/coroutines_concurrency.md).
- 다음 날: [01-pipeline-front-end.md](01-pipeline-front-end.md)에서 이 문법이 토큰과 AST가 되는 과정을 본다.
