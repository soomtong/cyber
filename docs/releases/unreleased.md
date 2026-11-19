# 0.4.15 이후 변경 (미릴리스)

0.4.15(2026-11-18) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 고치는 법을 말하지 않던 컴파일 오류 셋 (tars-agent 요청, 0.4.15 비교 회차)

요청 원문: tars-agent `docs/requests/cyber-0.4.15-messages-from-codeact-round.md`. 동작은 그대로이고 문구만 바뀐다.

- `!T` · `error`를 돌려주지 않는 함수 안의 `!`: 'Expected `Result` or `error` return type for enclosing function.'이
  'Expected a `!T` or `error` return type for `!`. The function `size` returns `int`, so `!` can not pass the error on.
  Declare it `-> !int`, or handle the error here with `!else` or `try`.'가 됐다. 람다는 'The lambda returns ...'.
- 케이스 이름 없는 `.!`(`idx.!`): 'Expected ident.'가 'Expected a choice case name after `.!` (`c.!line`). Unwrap an option
  with `.?`, and an error with `!` after the call (`f()!`).'가 됐다(ParseError).
- `^[]T`에 제자리 메서드(`rows.append('a')`): 원래 문구 뒤에 'To change the value that `rows` points to, write
  `rows.*.append(...)`.'를 붙인다. `insert` · `remove` 등 다른 제자리 메서드도 같다. `^T`를 `&&T`로 저절로 바꾸지는 않는다
  (다른 참조가 같은 목록을 나눠 가질 수 있다).

## 0.4.14..0.4.15 코드 리뷰에서 나온 수정 (2026-11-18)

리뷰 범위는 `git diff 0.4.14..HEAD`. 재현한 결함 여섯, 읽어서 찾은 것 하나, 정리 셋.

### 전역의 제자리 메서드(take-and-restore)

- 인자가 호출을 빠져나가면 전역이 빈 목록으로 남았다(값 유실). `global g []str`에서 `g += f()!`의 `f`가 error를 돌려주거나
  `try: g.append(int.parse('zz')!)`가 `else`로 가면 `g`가 `{}`였다. 이제 전역은 그대로다.
- 같은 이름의 함수가 여럿인 메서드가 전역에서 컴파일되지 않았다(0.4.14 대비 회귀). `g.append(h)`, `g.append(h.span())`,
  `g += h`, `g += h.span()`(`h`는 `[]T`), `Array` 전역의 `a.append(h)`가 'Cannot acquire exclusive borrow.'였다.
- 인자가 함수를 거쳐 같은 전역을 읽으면 빈 목록을 봤다. `fn next() -> int: return g.len()`일 때 `g.append(next())`가 0을
  붙였다. `(g).append(g.len())`도 그랬다. 반대로 다른 필드를 읽는 `st.xs.append(st.n)`은 컴파일 오류였다.
- 고친 방법: 값은 인자를 평가한 뒤에 꺼낸다. 수신자를 맞출 때는 숨은 지역에 빈 값만 두고, 인자를 다 맞춘 뒤 전역의 값과
  바꾼다(`sema.finishGlobalTake`). 이때 대기 중인 인자가 먼저 지역으로 평가된다(`seqFlush`). overload 후보가 맞지 않으면
  꺼낸 상태를 되돌린다(`sema_func.matchRtOverload`).
- 그래서 규칙이 바뀐다: `g.append(g.len())`는 이제 컴파일되고 `g`의 길이를 붙인다. 오류로 남는 것은 지역에 담을 수 없는
  인자(같은 전역의 빌림 `g.append(g.span())`)뿐이고, 문구는 'The method takes `g` out while it runs, so this argument can
  not read `g`. Read it into a local first.'다('an argument'가 'this argument'로). 검사는 수신자의 경로로 한다: `st.xs`를
  꺼낼 때 `st.ys.span()`은 되고 `st.xs.span()` · `st.view()`는 오류다.

### 제자리 메서드의 결과를 쓰는 꼴의 오류

- `Slice`가 아닌 타입에도 이름만 보고 오류를 냈다. `_ = arr.append(2)`(`Array`), `_ = m.remove('a')`(`Map`), 사용자 타입의
  `x := b.clear()`가 '`clear` changes `b` in place and returns nothing...'였다. 선언의 오른쪽에서는 `Slice` 메서드만 오류다.
- 전역 수신자의 선언(`ys := g.append(2)`)이 초기화되지 않은 IR을 읽었다. 이제 지역과 같은 문구(`g.appended(2)` 안내)가 나온다.
- 대입의 오른쪽에서도 수신자가 `Slice`면 새 목록 메서드를 알려 준다: `ys = xs.append(2)`는 '... Write `xs.append(2)` as a
  statement, or `xs.appended(2)` for a new list that leaves `xs` as it was.' `xs = xs.append(2)`의 문구는 그대로다.

### cyber-lsp

- 공백만 있는 줄 뒤의 구문 오류가 빠졌다. 복구가 빈 줄의 들여쓰기를 다음 줄의 것으로 봤다. `x := )` 다음에 공백 줄, 그 다음
  `fn foo():`가 오면 `foo` 안의 오류가 진단되지 않고 outline에서 `foo`가 빠졌다.
- 'as a statement' quick fix가 `ys = xs.append(2)`를 `xs.append(2)`로 바꿔 `ys`의 갱신을 지웠다. 이제 왼쪽이 수신자와 같은
  `xs = xs.append(2)`에만 fix가 있다.
- quick fix가 컴파일러 오류 문구의 영어 문자열에 묶여 있었다. 이제 컴파일러가 고칠 편집을 오류에 싣는다. 서버는 진단의
  `data.fix`로 내보내고 `codeAction`에서 돌려받는다. 문구에서 fix를 읽는 코드는 지웠다.
- 힌트(쓰지 않는 이름, 추론 타입)를 요청마다 다시 계산했다. 컴파일당 한 번 만들고, 쓰지 않는 이름 검사는 참조를 한 번 훑어
  만든 색인을 쓴다.

### libcyber

- `CLReport`에 `has_fix` · `fix_pos` · `fix_end_pos` · `fix_text`가 생겼다(구조체 끝에 추가). 컴파일러가 고칠 편집을 아는
  오류에 선다: 철자가 틀린 멤버('Did you mean ...?'), 같은 모듈에서 이름이 바뀐 함수(`os.read_file_str`), `xs = xs.append(v)`.

## cyber-lsp: 긴 문서의 주석 위에 뜨던 hover (2026-11-19)

- core의 템플릿을 쓰는 식(`[]int{1, 2}`, `s.len()`)이 있으면, core 소스의 위치가 이 문서의 위치로 기록됐다. 문서가 길면 주석이나
  관계없는 자리에서 hover가 `void` · `int` · `str` 같은 타입을 보였다. 이제 다른 소스의 노드는 기록하지 않는다.
  `cl_vm_symbol_at` · `cl_vm_symbol_refs`도 같다.

## cyber-lsp: 호출 자리의 매개변수 이름 (2026-11-19)

- inlay hint가 매개변수가 둘 이상인 함수 호출의 인자 앞에 매개변수 이름을 보인다: `area(‹width:›7, ‹height:›3)`. 오버로드는 호출이
  실제로 고른 함수의 이름이다. 메서드의 수신자, 그리고 이미 이름을 말하는 인자(`height`, `self.height`, `old_height`)에는 없다.
- libcyber: `CL_HINT_PARAM_NAME`(`CLHintKind` 4)이 생겼다. `cl_vm_symbol_hints`가 오류 없는 컴파일이 아니어도 낸다.

## cyber-lsp: 함수 · 타입 · 필드의 rename (2026-11-19)

- 함수 · 메서드 · 타입 · 필드 · 상수를 워크스페이스의 모든 소스에서 고친다. 전에는 지역과 매개변수만 됐다.
- 쓰임을 다 안다고 말할 수 없으면 고치지 않고 까닭을 말한다: 이름이 들어 있는 소스에 컴파일 오류가 있을 때, 컴파일러가 보지
  않는 자리(택하지 않은 `#if` 갈래, 쓰이지 않는 템플릿 본문)에 이름이 있을 때, 표준 모듈의 것, 모듈 이름. 워크스페이스 밖의
  소스는 모른다.
- references: 첫 줄에 선언된 함수의 파일을 넘는 references에 그 모듈의 이름(`lib.twice`의 `lib`)이 섞이던 것을 고쳤다.

## cyber-lsp: rename · 매개변수 이름 inlay의 리뷰 수정 (2026-11-19)

- 오버로드된 함수를 rename하면 호출과 첫 선언만 바뀌고 두 번째 오버로드의 선언은 옛 이름으로 남아 컴파일 오류가 났다. 이제
  오버로드를 모두 함께 고친다.
- 관계없는 소스에 같은 이름의 enum case(`case twice`)가 있으면 함수 rename이 '`#if` 갈래' 까닭으로 거절됐다. enum · choice ·
  union case의 선언 이름도 해석된 자리로 본다. hover · references도 case 선언 이름에서 그 case를 찾는다.
- 새 이름이 키워드(`return`, `fn`)여도 rename이 되어 여러 파일이 구문 오류가 됐다. 이제 '`return` is a keyword.'로 거절한다.
- `fiber worker(1, 2)`에 `worker` 앞 `func:`, `(` 앞 `args:` inlay가 붙었다. sema가 만든 `@new_fiber` 호출이라 이제 빼낸다.
- 템플릿 본문의 호출이 인스턴스마다 다른 오버로드를 고르면 첫 인스턴스의 매개변수 이름만 보였다. 이제 그 호출에는 이름을
  보이지 않는다. 매개변수가 32개를 넘으면 이름이 한 칸씩 밀리던 것도 고쳤다(힌트를 내지 않는다).
