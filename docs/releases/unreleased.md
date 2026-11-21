# 0.4.16 이후 변경 (미릴리스)

0.4.16(2026-11-21) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 빌림은 마지막으로 이름이 나오는 문장까지 산다

지역에 담은 빌림이 블록 끝이 아니라 같은 블록에서 그 이름이 마지막으로 나오는 문장이 끝날 때 끝난다. 그 뒤에는 주인을 다시
배타로 쓸 수 있다. 거절하던 코드를 받아들이는 쪽이라 깨지는 코드는 없다.

```cy
a := Array[int]{1, 2, 3}
elem := &a[2]
print(elem.*)
a << 4        -- 전에는 'Expected exclusive access. There is another active borrow to `a`.'
```

- 마지막으로 이름이 나오는 문장이 반복문 · `if`면 그 문장 전체가 끝날 때 끝난다. 안쪽 블록 · 람다 · 보간 · 주석 · 문자열 속의
  이름도 센다. `.` 뒤의 이름(`h.r`)은 멤버라 세지 않는다(`..r`는 센다).
- 소멸자가 있는 지역(빌림과 관리형 필드를 함께 담은 구조체, 빌림을 잡은 람다)은 그대로 블록 끝까지 빌린다.
- 빌림의 복사본(`r2 := r`)과 컨테이너에 담은 빌림은 따로 센다. 원래 지역이 끝나도 그것들이 살아 있으면 주인은 빌려진 채다.
- REPL의 최상위 지역은 그대로 블록 끝까지다(뒤 입력이 읽는다).
- 결정 `docs/decisions/project_borrow_model.md` "비어휘적 수명", 매뉴얼 Borrows 절.

## `NoCopy` 값은 `move` 없이 이동한다

`NoCopy` 값을 변수나 그 멤버에서 읽어 복사가 일어날 자리(인자, 초기값, 대입, 리터럴의 필드 · 원소)에 두면 `move`를 적은 것처럼
이동한다. 전에는 'Cannot copy `Foo`, type implements `NoCopy`.' 오류였다. 이동한 뒤 그 변수를 쓰면 이동한 자리를 짚는 오류다.

```cy
xs := Array[int]{1, 2, 3}
print(total(xs))     -- `total(move xs)`와 같다
print(xs.len())      -- 'xs' was moved at 2:13. Borrow it with `&xs` or clone it to use it here.
```

- 복사 가능한 타입은 그대로 복사한다. 원소 읽기(`a[0]`)처럼 변수가 아닌 자리는 전처럼 복사 오류다.
- 이동한 변수를 쓸 때의 문구가 바뀌었다: 명시적 `move` 뒤에도 '`a` is no longer alive in this scope.' 대신 위 문구다.

## `if` 갈래 안에서 바깥 변수를 옮길 수 있다

`if` 문의 갈래가 바깥 블록의 변수를 옮길 수 있다(명시적 `move`, 위의 암시적 이동 둘 다). 옮기지 않은 갈래와, `else`가 없을 때의
암시적 `else`는 갈래 끝에서 그 변수를 소멸시킨다. `if` 문 뒤에서 그 변수는 죽어 있다. 전에는 'Can only move variable declared in
the same block.' 오류였다.

- `@deinit`이 블록 끝이 아니라 갈래 끝에서 돈다.
- 반복 본문은 아래 "갈래 · 반복 본문에서 바깥 변수를 옮기는 자리가 늘었다"의 조건에서만 반복문 밖의 변수를 옮긴다. 갈래
  안에서도 바깥 변수의 멤버는 옮기지 못한다.
- 결정 `docs/decisions/project_last_use.md`, 매뉴얼 Moving 절.

## 새 목록 메서드는 마지막 사용에서 버퍼를 재사용한다

`Slice`의 `appended` · `inserted` · `removed` · `+`는 받는 쪽이 변수이고 그 사용이 마지막이면(그 문장에 이름이 한 번만 나오고 블록의
뒤 문장에 나오지 않음) 복사하지 않고 그 버퍼를 넘겨받는다. `move` 뒤 제자리 메서드와 같다. 결과는 전과 같고 복사만 줄어든다.
다른 값이 버퍼를 나눠 갖고 있으면 제자리 메서드가 전처럼 먼저 복사한다. 결정 `docs/decisions/project_last_use.md` "B 구현".

## 이동한 변수에 다시 대입할 수 있다

대입문이 이동한 지역 변수에 값을 다시 준다. 전에는 '`r` was moved at ...' 오류였다(`r = eat(move r)`도 같았다).

```cy
acc := Array[int]{}
for 0..3 |i|:
    acc = step(acc, i)     -- 오른쪽이 `acc`를 옮기고 결과를 대입한다. 소멸은 없다.
take(acc)
acc = Array[int]{}         -- 옮긴 뒤라 소멸시킬 옛 값이 없다.
```

- 오른쪽이 대입 대상을 옮기는 꼴(`x = f(x)`)은 반복 본문 · `if` 갈래 · `switch` 등 어느 블록에서든 된다. 문장이 끝나면 변수가 살아
  있기 때문이다. 옮기는 자리는 늘 평가되는 자리여야 한다(`and` · `or` · `if` 식 · `?else` · `!else` 안은 전처럼 막힌다).
- 문장 전에 이미 옮긴 변수는 그 변수를 선언한 블록이나 옮긴 그 블록에서 대입한다. 다른 반복 본문 · 갈래에서는 'Cannot assign to `a` here: it was
  moved at L:C and it is declared in an outer block. Assign to it in the block that declares it, or declare a new variable.'
- 바깥 블록의 변수를 옮긴 오른쪽은 `break` · `continue` · `try` 블록 안의 실패한 `!`로 문장을 떠나지 못한다('Cannot leave the
  assignment to `a` here: its right side moved `a`, which is declared outside the block that ends here. Move it to a new
  variable in a statement before this one.'). `return`은 된다.
- REPL의 최상위 변수는 옮긴 뒤 대입하지 못한다('Cannot assign to the top level variable `g` of the REPL after it was moved.
  Declare it again with `g := ...`.'). 오른쪽이 실행 중 실패하면 옮겨진 변수가 다음 입력에 남기 때문이다.
- `xs = xs.appended(v)`(`inserted` · `removed` · `+`도)는 문장에 `xs`가 그 둘뿐이면 버퍼를 재사용한다. 반복 본문에서도 된다. 원소
  100개를 이렇게 붙이면 버퍼가 100번이 아니라 자랄 때만(시험에서 4번) 새로 잡힌다. 결과는 전과 같다.
- 결정 `docs/decisions/project_last_use.md` "이동한 지역에 다시 대입", 매뉴얼 Moving 절 · Slice 절.

## 갈래 · 반복 본문에서 바깥 변수를 옮기는 자리가 늘었다

`if` 문의 갈래에서만 되던 바깥 변수의 이동이 다음 자리에서도 된다. 모두 거절하던 코드를 받아들이는 쪽이다.

```cy
buf := Array[int]{}
for items |it|:
    if it.last:
        send(buf)       -- `buf`를 옮긴다
        break
    buf << it.value
-- 여기서 `buf`는 죽어 있다. 그 `break` 없이 반복이 끝나면 반복문 끝에서 소멸한다.
```

- `if` 언랩 문(`if opt |v|:`)의 갈래, `switch` 문의 case, `begin:` 블록. 옮기지 않은 갈래의 끝에서 변수가 소멸하고 문장 뒤에는
  죽어 있다(`if` 문과 같다). `switch` 식의 case는 아래 "남은 자리의 이동"에서 열었다.
- 반복 본문: 옮긴 뒤 `return`이나 `break`로 반복문을 떠나면 된다. `break` 뒤에는 변수가 죽어 있고, 반복문을 떠나는 다른 길(반복이
  끝남, 옮기지 않은 `break`)은 반복문 끝에서 그 변수를 소멸시킨다. 옮긴 뒤 `break`가 여럿이고 옮긴 변수가 서로 달라도 된다
  (아래 "남은 자리의 이동").
- 옮긴 뒤 다음 반복으로 넘어가면 옮긴 자리의 오류다. 문구가 바뀌었다: 'Cannot move `a` here: it is declared outside the loop, and
  the next iteration reads it. A loop body can move it where it then leaves the loop with `break` or `return`, or gives it a
  value again. Borrow it with `&a`.' 반복 조건식(`while take(a):`)의 이동도 이 문구다.
- 같은 갈래 · 같은 반복 본문에서 옮긴 뒤 대입하면 변수가 살아 있다(`if c: take(x); x = R{}`, `for ..: take(x); x = R{}`). 전에는
  'Cannot assign to `x` here: it was moved at L:C and it is declared in an outer block.'
- `if` 언랩 문의 옵션 식은 `if` 문의 첫 조건식처럼 늘 평가되므로 변수를 옮길 수 있다(`if take(r) |v|:`).
- `scope` 블록은 아래 "`and` · `or`의 왼쪽과 `scope` 블록의 이동"에서 열었다.
- 결정 `docs/decisions/project_last_use.md` "갈래 종류와 반복 본문", 매뉴얼 Moving 절.

## `if` · `while` 언랩이 `NoCopy` payload를 꺼낸다

`if opt |v|:`와 `while opt |v|:`의 캡처가 `NoCopy` payload를 옵션에서 꺼내 `v`가 갖는다. 전에는 'Cannot copy `R`, type
implements `NoCopy`.'였다.

- 옵션을 변수에서 읽으면(`if o |v|:`) 그 변수가 이동한다. 문장 뒤에 쓰면 '`o` was moved at ...'. 반복 본문에서 반복문 밖의 옵션
  변수를 풀면 위 반복문 규칙을 따른다(`break` · `return`으로 떠나야 한다).
- 멤버에 담긴 옵션(`if s.opt |v|:`)은 전처럼 'Cannot copy `?R`, type member implements `NoCopy`.'다.
- payload가 복사 가능한 타입이면 전과 같다(옵션은 그대로 남는다).
- `for a |r|:`는 전과 같다: 원소를 복사하므로 `NoCopy` 원소는 'Cannot copy `R`, type implements `NoCopy`.'이고 `for a |&r|:`로 돈다.

## `?else`가 `NoCopy` 옵션을 푼다

`b := make() ?else: ...`와 `make() ?else default`에서 옵션이 호출 결과 같은 새 값이면 payload가 `NoCopy`여도 풀린다. 0.4.16에서는
'Cannot copy `?R`, type member implements `NoCopy`.'였고, 그 뒤 master에서는 숨은 지역을 짚는 'Cannot move `_temp` inside a
`?else` expression'이었다. 변수에 담긴 옵션(`o ?else ...`)은 아래 "남은 자리의 이동"에서 열었다.

## 남은 자리의 이동: `if` · `switch` 식, `try` 문, 서로 다른 `break`, `o ?else`

바깥 변수의 이동을 거절하던 자리 넷을 받아들인다. 모두 런타임 플래그 없이, 그 변수를 옮기지 않은 길의 끝에서 소멸시켜 문장 뒤의
상태를 하나로 맞춘다.

```cy
buf := Array[int]{}
try:
    n := read_into(&&buf)!      -- 여기서 실패하면 `else` 블록 전에 `buf`가 소멸한다
    send(buf)                   -- `buf`를 옮긴다
    flush()!
else |err|:
    print(err)                  -- 여기서 `buf`는 죽어 있다
```

- `if` 식의 갈래와 `switch` 식의 case(`v := if (c) take(a) else 0`, `v := switch k: case .x => take(a) ...`). 옮기지 않은 갈래가
  값을 낸 뒤 그 변수를 소멸시키고, 식 뒤에는 죽어 있다. `if` 식의 조건은 늘 평가되므로 문장의 일부처럼 옮긴다. 전에는 'Cannot
  move `a` inside an `if` expression: ...'과 'Cannot move `a` here: it is declared outside this block. ...'였다.
- `try` 문의 본문과 `else` 블록. 본문이 실패할 수 있는 `!` 전에 옮긴 변수는 `else` 블록에서 죽어 있다('`a` was moved at L:C.
  ...'). 그 변수를 옮기기 전에 실패한 `!`는 본문을 떠나기 전에 그것을 소멸시킨다. 어느 한 길이 옮긴 변수는 문장 뒤에 죽어 있고,
  옮기지 않은 길(본문의 끝, `else` 블록의 끝)이 소멸시킨다. 반복문 안이면 반복문 규칙을 따른다(옮긴 뒤 `else` 블록이 다음 반복으로
  가면 옮긴 자리의 오류).
- 반복문의 `break`들이 서로 다른 바깥 변수를 옮긴 뒤여도 된다. 각 `break`는 다른 `break`만 옮긴 변수를 떠나기 전에 소멸시킨다.
  'Cannot leave the loop here: ... has to follow the same moves.' 오류는 없어졌다.
- 변수에 담긴 `NoCopy` 옵션의 `?else`(`a := o ?else default`, `o ?else:` 블록). 옵션 식은 늘 평가되므로 `o`가 이동한다. 뒤에 `o`를
  쓰면 '`o` was moved at L:C. ...'. 전에는 'Cannot move `o` inside a `?else` expression: ...'였다. `?else`의 기본값 식과 블록은
  조건부로 평가되므로 전처럼 바깥 변수를 옮기지 못한다.
- 그대로 막히는 자리: `and` · `or`의 오른쪽, `?else` · `!else`의 기본값과 블록. `and` · `or`의 왼쪽과 `scope` 블록은 아래 절에서
  열었다.
- 결정 `docs/decisions/project_last_use.md` "남은 다섯", 매뉴얼 Moving 절.

## `and` · `or`의 왼쪽과 `scope` 블록의 이동

바깥 변수를 옮기지 못하던 마지막 두 자리다.

- `and` · `or`의 왼쪽 피연산자는 늘 평가되므로 식을 둘러싼 블록의 문장처럼 변수를 옮긴다(`ok := take(a) and ready`,
  `if take(a) or force:`). 오른쪽은 조건부로 평가되므로 전처럼 'Cannot move `a` inside an `and` expression: ...'이다. 왼쪽이 옮긴
  변수를 오른쪽에서 쓰면 '`a` was moved at L:C. ...'. 반복문 조건 · 본문에서는 반복문 규칙을 따른다.
- `scope` 블록의 본문은 `try` 문의 본문처럼 바깥 변수를 옮긴다. 블록 뒤에는 죽어 있다. 본문의 `!`가 실패하면 그때까지 옮긴 변수는
  죽은 채로, 뒤에서 옮길 변수는 블록을 떠나기 전에 소멸된 채로 오류가 나간다(감싸는 `try` 문의 `else` 블록에서 둘 다 죽어 있다).
  fiber의 오류는 블록 끝의 join에서 나가므로 본문이 옮긴 변수는 모두 죽어 있다.
- 블록의 이름(`scope |s|:`의 `s`)은 옮기지 못한다: 'Cannot move `s`: it is the scope of a `scope` block, which joins its fibers
  at the end of the block. Borrow it with `&&s`.' 전에는 'Cannot move `s` here: it is declared outside this block. ...'였다.
- fiber가 빌린 변수는 블록이 끝날 때까지 빌려져 있으므로 관리형 값이면 옮기지 못한다('Cannot move `a`. There is an active borrow
  to it.', 전과 같다).
- 일반 문구 'Cannot move `a` here: it is declared outside this block. ...'의 블록 목록에 `scope` 블록이 들어갔다.
- 결정 `docs/decisions/project_last_use.md` "`and` · `or`의 왼쪽과 `scope` 블록", 매뉴얼 Moving 절.

## 멤버에 대입하는 새 목록 메서드도 버퍼를 재사용한다

`s.xs = s.xs.appended(v)`(`inserted` · `removed` · `+`도)가 `s.xs.append(v)`처럼 제자리에서 돈다. 결과는 전과 같고 원소 하나마다
목록을 복사하던 비용이 없어진다. 메서드 안의 `self.xs = self.xs.appended(v)`(`&&T` 수신자)도 같다.

- 조건: 경로가 지역 변수(또는 `&&T` 매개변수)에서 구조체 값의 멤버로만 이어지고, 그 변수가 빌려져 있지 않고, 오른쪽에서 그
  변수의 이름이 수신자에 한 번만 나온다. 참조(`^T`) · 공유 빌림(`&T`)을 거친 멤버와 인자가 그 변수를 읽는 문장
  (`s.xs = s.xs.appended(s.n)`)은 전처럼 복사한다.
- 다른 값이 버퍼를 나눠 갖고 있으면 제자리 메서드가 전처럼 먼저 복사한다.

## 고치는 법을 말하는 문구 넷 (tars-agent 요청, 0.4.16 CodeAct 회차)

- Python 슬라이스 `s[:3]` · `s[2:]` · `s[1:3]`: 'A slice is written `s[..3]`, `s[2..]` or `s[1..3]`, not `s[:3]`.' 전에는
  'Expected element expression.' · 'Expected closing bracket.'.
- `for 0..n |_|:`: 'A loop that does not use its value is written `for 0..n:` or `for xs:`. `|_|` is not allowed.' 위치가 `_`다.
  전에는 다음 줄을 가리키는 'Expected ident.'.
- 값을 버린 문장: 'Expected assignment to a variable or placeholder for `?str`. Write `_ = xs.pop()` to drop the value.' 문장이
  60자 이하 한 줄이면 그 문장으로 꼴을 보인다.
- 모듈에 없는 이름에 가까운 이름을 알려 준다('Can not find the symbol `bas` in `path`. Did you mean `base`?'). 다른 언어의 이름
  `basename` · `dirname` · `extname` · `isabs`는 `base` · `dir` · `ext` · `is_absolute`로 맞춘다. LSP quick fix도 붙는다.
- 에이전트 가이드: `int(z)`와 `int('Z')`가 다른 값인 예와 `int(z[0])`, `Array` 이동 줄, 오류 표의 두 줄을 고쳤다.

## 0.4.16 뒤 변경의 코드 리뷰에서 나온 수정

릴리스 전 `/code-review`(0.4.16..HEAD)가 찾은 결함이다. 모두 위 절들의 기능(암시적 이동 · 갈래 안 이동 · 버퍼 재사용)에서 나왔고
0.4.16에는 없다.

- overload 후보가 맞지 않으면 그 시도에서 이동한 지역이 되살아난다. 전에는 첫 후보를 맞춰 보다 이동한 지역이 죽은 채 남아
  `out += xs.appended(2)`, `out.append(xs.appended(2))`, `ys := out + xs.appended(2)`, `str(ys.appended('b').len())`가
  '`xs` was moved at ...'로 거절됐고, `fn f(a R, b int)` · `fn f(a R, b str)`에 `f(r, s)`는 둘째 후보에 닿지 못했다. 멤버 이동
  (`f(box.r, s)`)과 sink 매개변수도 같이 되돌린다.
- 버퍼를 재사용한 새 목록은 다른 값과 버퍼를 나눠 갖지 않는다. 전에는 제자리 메서드가 복사하지 않는 두 경우(마지막 원소의
  `removed`, 빈 목록을 더하는 `+` · `appended`)에 결과가 버퍼를 공유했다: `b := a` 뒤 `c := a.removed(2)`, `c[0] = 9`가 `b[0]`을
  바꿨고, 매개변수로 받은 목록은 호출자의 목록을, sub-slice는 원래 목록을 바꿨다. 이제 제자리 메서드 뒤에 `own_buffer()`
  (버퍼를 혼자 갖고 있지 않으면 복사)를 부른다. 혼자 갖고 있을 때는 전처럼 복사가 없다.
- `#for` 본문에서는 버퍼를 재사용하지 않는다. 본문이 같은 블록에 반복해 펼쳐지므로 첫 반복이 지역을 옮기면 둘째 반복이
  '`zs` was moved at ...'로 실패했다.
- 버퍼를 재사용한 호출의 인자 오류가 적은 메서드를 말한다: `xs.inserted(1)`은 `fn insert(&>[]int, int, int) -> void`가 아니라
  `fn inserted(&[]int, int, int) -> []int`를 보인다. 범위 밖 인덱스의 panic 문구는 같고, stack trace에는 제자리 메서드
  (`Slice.remove`)가 나온다.
- behavior 테스트 넷(`syntax/python_slice_error.cy` 등)이 `test_memory`에 등록돼 있던 것을 제 분류로 옮겼다.
- REPL의 최상위 변수는 `move`를 적어야만 이동한다. 암시적 이동이 들어온 뒤 `eat(a)` · `b := a`만으로 변수가 이동했는데, 이동
  상태가 다음 입력으로 넘어가지 않아 다음 입력이 해제된 값을 읽었다(`print(a[0])`가 segfault). 이제 'Cannot copy `Array[str]`, a
  `NoCopy` type. The top level variable `a` of the REPL does not move without `move`: later inputs read it. Write `move a` to give it
  away (later inputs can not use `a` then), or borrow it.' 오류다. 최상위 `if` 갈래 안에서 최상위 변수를 옮기는 것도 같다.
  함수 본문의 지역과 갈래 안에서 선언한 지역은 전처럼 이동한다.
  - 명시적 `move a` 뒤에는 다음 입력에서 `a`가 없다('Undeclared variable `a`.'). 0.4.16까지는 `b := move a` 뒤에도 다음 입력이 `a`를
    되살려 값의 주인이 둘이 됐다(새 builtin `@untrackMainLocal`).
  - 최상위 변수의 멤버는 REPL에서 옮기지 못한다: 'Cannot move a member of the top level variable `bx` of the REPL: later inputs read
    `bx`. Move the whole variable with `move bx`, or do it inside a function.' 암시적 이동 자리에서는 'A member of the top level
    variable `bx` of the REPL does not move ...' 문구다.
- 값을 반환하는 `op=` 메서드(`` fn (&Acc) `+=`(o int) -> int ``)를 문장으로 쓰면 'The `+=` method of `Acc` returns `int`, and an
  `x += y` statement can not use or drop the value. Declare the method without a return type.' 전에는 문법에 없는 'Write
  `_ = a += 2` to drop the value.'였고, `!void`를 반환할 때의 'Add `!` after the call' 안내도 쓸 수 없는 문법이었다.
- `if` 갈래 이동의 컴파일러 panic을 고쳤다. 한 갈래가 바깥 변수를 옮기고 `else`(또는 뒤 `else cond:`)에 관리형 지역이 있으면
  'panic: expected mapping to IR local'이었다. 갈래 끝 소멸의 cancel pad가 다른 갈래의 지역까지 잡은 탓이다. 같은 수정으로
  소멸자 안에서 취소됐을 때 이미 옮겼거나 방금 소멸시킨 변수를 다시 소멸시키지 않는다.
- `if` 문의 조건식에서 변수를 옮길 수 있다(`if take(a) > 0:`). 조건식은 늘 평가되므로 그 블록의 문장에서 옮긴 것과 같다. 전에는
  같은 블록의 변수인데 'it is declared in an outer block' 오류였다.
- 조건부로 평가되는 식 안의 이동은 계속 오류이고 문구가 원인을 말한다: 'Cannot move `a` inside an `and` expression: a part of the
  expression is evaluated conditionally. Borrow it with `&a`, or move it to a variable in a statement before this one.'(`and` ·
  `or` · `if` 식 · `?else` · `!else`), 'Cannot move `a` in the condition of an `else` branch: the condition is evaluated
  conditionally. Move it inside the branch, or borrow it with `&a`.'
  - 남은 한계: `while` 조건식과 `if` 언랩(`if opt(a) |v|:`)의 조건식은 옛 문구 그대로다.
