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

## cyber-lsp: 범위 포맷과 call hierarchy (2026-11-19)

- 범위 포맷(`textDocument/rangeFormatting`): 선택한 줄만 포맷한다. 결과는 문서 전체를 포맷했을 때의 그 줄들과 같다. 구문 오류가
  있으면 전체 포맷처럼 아무것도 바꾸지 않는다.
- call hierarchy: 함수 · 메서드를 부르는 함수(워크스페이스의 모든 소스)와 그 함수가 부르는 함수를 보인다. 소스의 최상위 코드는
  파일 이름의 항목이다. 표준 모듈의 함수는 항목이 되지 않고, outgoing에서도 빠진다. 부르지 않고 이름만 쓴 것(`map(twice)`)도
  호출로 친다.

## cyber-lsp: 한 함수의 오류를 모두 진단 (2026-11-19)

- 함수 · 메서드 · main 블록마다 첫 오류만 진단하던 것을, 실패한 문장을 건너뛰고 다시 검사해 그 본문의 다른 문장의 오류도 진단한다.
  본문마다 10번까지 검사한다.
- 실패한 `x := ...`는 그 블록의 나머지를 건너뛴다. 뒤의 `x`가 'Undeclared variable'로 줄줄이 나오지 않는다. 그 블록의 오류는
  선언을 고친 뒤에 보인다.
- 같은 자리 · 같은 문구의 오류는 하나로 줄인다. 함수 템플릿 본문의 오류가 인스턴스 수만큼, 서명이 해석되지 않는 템플릿 메서드의
  오류가 그것을 부르는 본문 수만큼 나던 것이다.
- libcyber: `cl_vm_set_error_recovery`가 위처럼 동작한다. CLI(복구 꺼짐)는 그대로다.

## cyber-lsp: 선언의 오류를 모두 진단 (2026-11-20)

- 선언(함수 · 메서드의 서명, 타입의 필드, `global` · `const`의 타입, 타입 별칭)의 오류가 첫 하나에서 컴파일을 끝내던 것을, 실패한
  선언을 건너뛰고 다음 선언을 해석해 모두 진단한다.
- 실패한 선언을 쓰는 선언(`type B:` 안의 `a A`, `fn f(a A)`)은 따로 진단하지 않는다. 'Structs can not contain a circular
  dependency.'가 거짓으로 나지 않는다.
- 선언에 오류가 있으면 본문은 검사하지 않는다. 본문의 오류는 선언을 고친 뒤에 보인다.
- 최상위 컴파일 타임 문장(`#if` 등), `use`, 템플릿 머리의 오류는 그대로 컴파일을 끝낸다.
- libcyber: `cl_vm_set_error_recovery`가 위처럼 동작한다. CLI(복구 꺼짐)는 그대로다.

## `use os.read_file`의 오류 문구 (2026-11-20)

- 점이 있는 이름을 `use`하면 'TODO'라는 문구만 냈다. 이제 별칭으로 쓰는 법을 알려 준다: 'Expected a module name. A symbol of a
  module is used through an alias: `use read_file = os.read_file`.'

## 실패한 컴파일 뒤의 다음 컴파일이 소스를 다시 컴파일하지 않음 (2026-11-20)

- 실패한 컴파일이 남긴 템플릿 인스턴스의 본문이 컴파일되지 않으면(`Map[[]int, int]`를 만든 뒤 오류) 다음 컴파일은 그 인스턴스를
  버리려고 소스 전체를 처음부터 다시 컴파일했다(최대 8번). 그때마다 모듈 로더 · resolver · 컴파일 타임 호스트 함수가 다시
  불렸다(`use` 하나에 로더가 5번 불린 경우를 확인).
- 이제 그 본문들은 소스를 해석하기 전에 먼저 검사한다. 실패한 본문의 IR은 `StackMark`로 되돌리고 인스턴스를 버린 뒤 남은 본문을
  다시 검사한다(최대 8번). 소스는 한 번만 컴파일한다.
- libcyber: `CLModuleLoaderFn` 주석과 매뉴얼의 세션 절에서 "다시 시작한다"는 설명을 뺐다. 실패한 컴파일이 처음 불러온 모듈을
  다음 `use`가 다시 불러오는 것은 그대로다.

## `spawn f(args)`: 스레드 생성도 키워드 + 호출식 (2026-11-20, 깨지는 변경)

- `spawn`이 `fiber`와 같은 키워드가 됐다. `spawn(fib, {40})`은 `spawn fib(40)`으로 쓴다. 인자는 그 자리에서 평가해 새 스레드로
  보내고, 함수는 새 스레드에서 부른다. 돌려주는 것은 전과 같이 `Future[T]`다.
- 옛 꼴은 ParseError다: 'Expected a function call after `spawn`: `spawn f(a, b)`. The form `spawn(f, {a, b})` was replaced.'
  `spawn`을 이름(지역 · 함수 · 필드)으로 쓸 수 없다.
- `spawn`은 첫 호출까지만 받는다: `spawn fib(40).await()`는 `(spawn fib(40)).await()`다. `fiber`도 같게 바꿨다(`fiber f(x).resume()`은
  새 fiber를 resume한다. 전에는 `f(x).resume()`의 결과를 진입점으로 보려다 오류였다).
- 람다를 바로 넘기는 꼴(`spawn(fn(n int) -> int => n + 1, {3})`)은 없다. 지역에 담아 `inc := fn(...) ...` 뒤 `spawn inc(3)`.
- 메서드는 타입으로 부른다(`spawn Job.run(job)`). `spawn job.run()`은 'A thread entry cannot be a method call on a value. ...'
  컴파일 오류다. 빌림(`&T`) 매개변수를 받는 진입 함수는 'Cannot borrow a value across threads. ...' 컴파일 오류다(전에는
  `@send` 쪽의 타입 오류였다).
- 고친 곳: core의 `spawn` 함수는 `@spawn`(builtin 모듈만)으로 이름을 바꾸고, `spawn` 식이 `@spawn(f, {args})`로 풀린다
  (`fiber`의 `@new_fiber`와 같은 경로, `sema.semaEntryCall`). `deny_spawn`은 그대로 동작한다. tree-sitter `spawn_expression`,
  VS Code · 플레이그라운드 키워드 목록, `tokenizer.cy`(빠져 있던 `fiber` · `suspend`도 더함).

## choice의 `==` (2026-11-20)

- choice 값을 `==` · `!=`로 비교할 수 있다. 전에는 core `@eq`가 choice를 몰라 'Unsupported: ...' 컴파일 오류였다.
  활성 case가 다르면 다르고, 같으면 payload를 `==`로 비교한다(payload 없는 case는 같다). payload 비교는 그 타입의 규칙을 따른다:
  슬라이스는 참조 비교다.
- 그래서 `?json.Value == none`이 된다(`v.get('a') == none`). `json.Value`의 `==`는 case와 payload 비교라 `Value.int(1) ==
  Value.float(1.0)`은 false이고 `array` · `object`는 참조 비교다. JSON 모델의 비교는 전처럼 `Value.eq`.

## 빌림을 담은 값이 빌린 지역보다 오래 살던 결함 (2026-11-20)

- `&T`를 캡처한 클로저(`OpaqueFunc`)를 반환 · 구조체 필드 · `^` · 전역으로 내보낼 수 있었고, 부르면 해제된 스택을 읽었다(쓰레기
  값). `OpaqueFunc`는 문서상 복사 · 이동이 막힌 값이지만 sema가 강제하지 않았다. 이제 빌림 컨테이너다: 반환은 `scope` 반환
  타입으로만('Returning a borrow container requires a `scope` modifier.'), `^`는 'Cannot lift the borrow container type ...'.
- 클로저와 빌림 필드를 가진 구조체 · 튜플 리터럴을 바깥 블록의 지역에 대입하면 빌린 지역보다 오래 살 수 있었다. 이제
  '`r` can not outlive `y`.' 컴파일 오류다(빌림 하나를 대입할 때와 같은 검사). 클로저는 캡처한 지역 중, 리터럴은 빌림 필드가 빌린
  지역 중 먼저 끝나는 것을 주인으로 본다. 그 주인이 빌림 중으로 기록되므로 클로저가 사는 동안 주인의 배타 빌림(`&&x`)은 막힌다.
  빌림을 담은 지역을 다시 빌리는 것(`h := Holder{r=&&f}` 뒤 `&&self` 메서드 `h.push(1)`)은 그 지역 자신의 기록을 빼고
  검사한다(`sema.otherBorrows`).
- 전역에 빌림 타입(`&T`, `?&T`, 빌림 컨테이너)을 쓸 수 없다: 'A global cannot hold the borrow type `?&int`. Use an owned type
  such as `^T`.' 전에는 선언이 통과했다.
- 캡처가 둘 이상인 pinned closure가 해제되지 않고 샜다. core `@deinitObject`가 `.closure`만 알아 pinned closure를 24바이트 pool
  객체로 놓았고, `Heap.pinned_closures`에서 빼지도 않았다(스택이 옮겨지면 해제된 객체에 쓸 수 있는 낡은 항목). 이제
  `@freePinnedClosure`가 표에서 빼고 할당한 크기로 놓는다.

## 템플릿 특수화 중 오류에 특수화 경로 (2026-11-20)

- 템플릿 인스턴스의 본문 · 선언에서 난 컴파일 오류에, 그 인스턴스를 처음 요청한 자리를 'While specializing `inner[int]` here:'
  주석으로 붙인다. 그 자리가 다른 인스턴스 안이면 바깥으로 이어 사용자 코드까지 보인다(`Map[[]int, int]{}`의 오류는
  `AutoHash[[]int]` → `Map[[]int, int]`의 자리까지). 전에는 본문의 위치만 짚어 어느 호출이 원인인지 알 수 없었다.
- 주석은 그 컴파일에서 만든 인스턴스만 단다(세션의 앞 컴파일이 남긴 인스턴스는 자리가 없다). 해석 문맥이 이미 같은 자리를
  가리키면 다시 달지 않는다. libcyber에서는 `cl_vm_compile_report_note`의 메시지 있는 note다.
- 고친 곳: `Instance.site` · `site_parent`(`template.createInstance`), `Compiler.compile_seq`, `Chunk.appendInstanceTrace`,
  `sema.bodyInstance`. 설계 원칙 검토 1.4 C의 1단계다.

## OS 오류의 표준 이름 (2026-11-20, 깨지는 변경)

- `os`의 실패한 OS 호출이 플랫폼과 함수에 관계없이 같은 이름을 돌려준다. 결정은 `docs/decisions/project_os_error_names.md`.
  전에는 errno 여섯 개만 이름이 있었고(`EEXIST` · `ENOTDIR` · `ENOSPC` 등은 모두 `error.Unknown`), 거부가 `AccessDenied` ·
  `OperationDenied` 둘이었고, Windows는 다른 표를 썼다. `Unknown`일 때 stderr에 'errno: N'을 찍던 것도 뺐다.
- 옛 이름 → 새 이름(호환성): `FileNotFound` → `NotFound`, `AccessDenied` · `OperationDenied` → `PermissionDenied`,
  `FileExists` → `AlreadyExists`, `BadFile` · `BadAddress` → `InvalidArgument`. 언어 별칭은 없다. `== error.FileNotFound`로
  비교하는 스크립트는 조용히 false가 되니 고쳐야 한다.
- 새 이름: `IsADirectory` · `DirectoryNotEmpty` · `NoSpace` · `ReadOnly` · `NameTooLong` · `TooManyOpenFiles` · `Busy` ·
  `CrossesDevices` · `Interrupted` · `WouldBlock` · `TimedOut` · `BrokenPipe` · `ConnectionRefused` · `Unsupported`.
  `NotADirectory` · `OutOfMemory` · `InvalidArgument` · `Unknown`은 그대로다.
- 새 함수: `os.last_os_error()`(원래 코드), `os.from_errno(code)`, `os.from_win32_error(code)`, `os.last_error()`.
- Windows 매핑은 실행으로 확인하지 못했다(빌드 · 테스트 환경 없음).
