# 0.4.17 이후 변경 (미릴리스)

0.4.17(2026-11-22) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 세션에서 템플릿 인스턴스의 본문이 실패한 뒤의 세그폴트 (tars-agent 요청, 2026-11-22)

`persist_main` 세션(REPL, `cl_vm_eval` · `cl_vm_validate`를 한 VM에 이어 부르는 호스트)에서만 보이는 결함이다. 0.4.16에도 있었다.

- 증상: `xs := []Array[int]{}`의 컴파일 오류 뒤에, 다음 `cl_vm_validate` · `cl_vm_eval`이 소스와 상관없이(`print(1)`) 세그폴트로
  호스트 프로세스를 끝냈다. 함수 본문에서 `a[0]`을 읽는 꼴은 죽지 않고 다음 소스에 앞 오류가 다시 나왔다.
- 원인: 실패한 것은 `PtrSpan[Array[int]]`의 본문 하나인데 그것을 부르는 `Slice[Array[int]]`의 본문들은 다음 컴파일로 넘어가
  (`Compiler.carry_funcs`) 코드가 생성됐다. 부르는 쪽은 이미 가진 타입으로 함수를 찾아 인스턴스를 다시 요청하지 않으므로
  실패 표시를 보지 못했고, 검사된 적 없는 본문의 IR을 읽었다(`bc_gen.check_inline`).
- 실패는 이제 인스턴스가 아니라 본문 단위로 표시한다(`FuncInfo.body_failed`). 전에는 본문 하나가 실패하면 타입 인스턴스 전체를
  버려서, 세션의 남은 동안 `Array[Array[int]]`(같은 `PtrSpan[Array[int]]`를 쓴다)도 'The template could not be expanded with these
  arguments because of an earlier error.'로 막혔다.
- 실패한 본문을 부르는 자리(`sema_call.checkCallee`):
  - 넘어온 본문에서 부르면 그 본문도 실패로 표시하고 버린다. 지금 소스의 오류가 아니므로 보고하지 않는다.
  - 지금 소스에서 부르면 그 본문을 이 컴파일에서 다시 검사한다(`Compiler.recheck_funcs`). 같은 잘못을 다시 적은 소스는 원래 오류를
    위치와 특수화 경로까지 그대로 다시 받는다. 전에는 'because of an earlier error'만 나왔다.
- 해석에 실패한 타입 인스턴스도 같다. 앞 컴파일에서 실패한 인스턴스는 캐시에서 빼고 다시 전개해(`template.failedEarlier`) 오류를
  다시 낸다. 실패한 컴파일이 해석하지 못하고 남긴 다른 인스턴스(오류로 컴파일이 끝나 순서가 오지 않은 것)는 다음 컴파일이 먼저
  해석한다(`compiler.resolveCarriedTypes`). 전에는 필드 없는 타입이 캐시에 남아 다음 소스의 sema가 죽을 수 있었다.
- 넘어온 본문이 새로 전개한 함수도 그 검사 안에서 본다(전에는 소스와 함께 검사했다). 버린 본문이 trait 구현이면 그 타입
  인스턴스는 vtable을 채울 수 없으므로 타입째 버리고, 다음에 요청하는 소스가 다시 전개한다.
- 넘어온 본문의 검사는 8번까지 다시 돈다(전과 같다). 그 뒤에는 인스턴스의 남은 본문을 모두 버리고, 부르는 자리에서 다시 검사한다.
  전에는 8번을 넘으면 지금 소스와 상관없는 오류를 냈다.
- 확인: lib 테스트 `A body of a template instance that failed does not break the next compile.`,
  `A slice of a NoCopy element type is refused and does not break the next compile.`

## `[]T`의 원소 타입은 복사할 수 있어야 한다 (tars-agent 요청, 2026-11-22, 깨지는 변경)

- `Slice`는 버퍼를 공유하다가 크기가 바뀔 때 복제한다. 그래서 원소를 복사한다. `NoCopy` 원소(`Array[T]`, 소멸자 타입, 그런 멤버를
  가진 타입)의 `[]T`는 전에도 쓸 수 없었지만 오류는 core 안의 본문에서 났고('Cannot copy `Array[int]`, type implements `NoCopy`.',
  첫 위치 `core:4797`), 필드 타입으로만 적으면(`xs []Array[int]`) 오류 없이 넘어갔다.
- 이제 타입을 해석할 때 사용자 줄에서 거절한다: 'A slice `[]Array[int]` copies its elements, so the element type `Array[int]` can not
  be `NoCopy`. Use `Array[Array[int]]`, which moves them.' 자기 자신을 원소로 갖는 `NoCopy` 타입(`type Tree: with NoCopy`,
  `kids []Tree`)은 `Tree`가 해석될 때 같은 오류다.
- 새로 오류가 되는 코드: `NoCopy` 원소의 `[]T`를 필드 · 매개변수 타입으로 적기만 하고 값을 만들지 않던 코드.
- 테스트 `memory/slice_nocopy_elem_error.cy`, `memory/slice_nocopy_elem_field_error.cy`.

## 빌린 값을 `for`로 돌기 (tars-agent 요청, 2026-11-22)

- `fn total(a &[]int)`의 `for a |x|:`는 'Expected argument `&[]int`, found `&&[]int`, when calling `fn iterator(&[]int) -> int`.'였다.
  `for`가 빌림을 다시 빌렸다. 이제 빌림(`&T`)을 받으면 그 자리에서 돈다. `for a.* |x|:`와 같다.
- `|i, x|`, `|&x|`도 같다. `Array` · `Map`의 빌림도 된다. 테스트 `control_flow/for_iter_borrowed_iterable.cy`.

## 0.4.16..0.4.17 코드 리뷰에서 나온 수정 (2026-11-22)

`/code-review high`의 6건이다. 모두 0.4.17의 마지막 사용 분석(이동 · 버퍼 재사용)에 있던 결함이다. 설계 기록은
`docs/decisions/project_last_use.md`의 마지막 절.

새로 컴파일 오류가 되는 코드(0.4.17에서는 컴파일되고 틀리게 돌았다):

- `while` 조건식이나 `while opt |v|:`의 옵션 식이 반복문 밖 변수를 옮기는 것. 본문이 늘 `break` · `return`으로 떠나면 조건이
  거짓인 길에서 변수가 두 번 소멸되거나, 반복문 뒤에서 옮긴 변수를 읽을 수 있었다(`while take(x) == 2: break`).
  'Cannot move `x` in the condition of a `while` loop: it is declared outside the loop, and the condition is evaluated before every
  iteration. Borrow it with `&x`, or write `while:` and move it in the body where the body then leaves the loop with `break` or
  `return`.' 반복문 밖의 `NoCopy` 옵션 변수를 `while o |v|:`로 푸는 것도 이 오류다.
- `else` 조건식 안의 `if` 식 갈래가 바깥 변수를 옮기는 것(`else (if (j == 0) take(x) else 0) == 7:`). 이중 소멸이 났다.
  문구는 기존의 'Cannot move `a` in the condition of an `else` branch: ...'다.
- 반복 본문이 바깥 변수를 옮긴 뒤, 같은 본문에서 인자에 `if` 식 갈래의 이동이 있는 overload 호출을 하는 것. 실패한 후보를
  되돌리며 바깥 변수의 이동 기록이 지워져 'Cannot move `y` here: it is declared outside the loop, ...' 오류가 나지 않고 변수가
  반복마다 소멸됐다. 같은 꼴이 `if` 갈래 안이면 옮기지 않은 길에서 변수가 소멸되지 않았다.

고친 동작:

- `if` 문의 첫 조건식이나 `and` · `or`의 왼쪽 안의 `if` 식이 같은 블록의 변수를 옮기면 반복 본문 끝에서 그 변수가 다시
  소멸됐고(`for` 본문), `while` 본문에서는 컴파일러가 'index out of bounds'로 죽었다.
- `for xs |x|:` 본문의 `move x`(캡처 변수나 인덱스)가 컴파일러를 죽였다(0.4.16은 'Can only move variable declared in the same
  block.'). 이제 옮길 수 있다. 캡처는 반복 한 번의 변수이고, `continue`와 본문 끝에서 옮기지 않은 캡처가 소멸된다.
- `try:` 안의 `xs = xs.appended(f()!)`(`xs`는 `try` 밖 선언)와 반복문 안의 `xs = xs.appended(pick(i) ?else: break)`가 0.4.16과
  달리 'Cannot leave the assignment to `xs` here: its right side moved `xs`'로 거절됐다. 이런 문장은 버퍼를 재사용하지 않고
  0.4.16처럼 복사한다. `inserted` · `removed` · `+`도 같다.
- cyber-lsp: 버퍼를 재사용하는 호출(`xs = xs.inserted(0, v)`, 마지막 사용의 `ys := xs.inserted(0, v)`)에 매개변수 이름 inlay가
  나오지 않았다.

테스트: `memory/move_while_cond_error.cy` · `move_while_unwrap_error.cy` · `move_cond_expr.cy` · `move_else_cond_expr_error.cy` ·
`move_for_capture.cy` · `move_overload_undo.cy` · `move_overload_undo_loop_error.cy` · `slice_reuse_assign_jump.cy`, LSP 테스트
'Inlay hints name the parameters at the arguments of a call.'

## 갈래가 주는 빌림의 주인 (2026-11-22, 깨지는 변경)

여러 갈래 중 하나가 빌림을 주는 식이 주인을 잃어, 빌린 배열을 키운 뒤 해제된 메모리를 읽었다. 0.4.17에도 있었다.

- `switch` 식: `e := switch x: case 1 => &a[0] else => &a[1]` 뒤 `a << i`가 됐다. `&&a`를 주는 두 갈래는 배타 빌림 둘을 만들었고,
  안쪽 블록 지역의 빌림을 바깥 변수에 넣을 수 있었다. 이제 `if` 식처럼 'Expected exclusive access. There is another active borrow
  to `a`.', '`r` can not outlive `z`.'다.
- `?else` · `!else`: 옵션 · 결과 쪽(`o ?else &y`, `o`가 `&a[0]`을 담음)과 기본값 쪽(`o ?else &a[0]`) 모두 주인을 센다.
- 두 주인의 빌림: `e := if (c) &y else &a[0]`은 `y`만 셌다. 이제 둘 다 센다(`switch` 식 · `?else`도 같다).
- `!&T`: 결과 타입이 빌림을 담은 것으로 셈해진다(`?&T`와 같다). `r := f(&a)`를 든 채 `a`를 키울 수 없다. `-> !&T`를 돌려주는 함수는
  `scope`가 필요하다: 'Returning a borrow container requires a `scope` modifier.' `fn pick(scope p &int) -> scope !&int`로 적는다.
- `e := f(&a)!`(`f`가 `scope !&int`)를 담은 블록이 끝날 때 컴파일러가 panic으로 죽던 것도 고쳤다.
- 테스트 `memory/borrow_branch_owner.cy`와 `memory/borrow_switch_expr_*_error.cy` 등 오류 테스트 열 개. 결정
  `project_borrow_model.md` "갈래가 주는 빌림", 발견 이슈 F-170.

## `json.to`가 struct 필드 기본값을 쓴다, 기본값 식의 이름은 선언한 곳에서 찾는다 (2026-11-22)

- `json.to` · `json.decode`가 없는 멤버에 필드 기본값을 쓴다(`port int = 8080`). 전에는 기본값이 있어도 'Missing the field `port`.'
  (`error.MissingField`)였다. 기본값이 있는 옵션 필드는 없으면 기본값, `null`이면 `none`이다.
- `meta.has_field_default(T, name)`, `meta.field_default(T, name)`를 더했다.
- 필드 기본값 식의 이름을 struct를 선언한 곳(모듈, private 선언, 템플릿 인자)에서 찾는다. 전에는 리터럴을 쓴 곳에서 찾았다.
  - 다른 모듈에서 `conf.Conf{...}`를 쓰면 기본값이 그 모듈의 상수(`const LIMIT = 20`, public이어도)를 쓸 때 'Undeclared variable
    `LIMIT`.'였다.
  - 템플릿 struct의 `v T = T(3)`은 'Undeclared variable `T`.'였다.
  - 리터럴을 쓴 함수에 같은 이름의 지역이 있으면 그 지역이 기본값이 됐다(`K := 100` 뒤 `A{}`의 `x int = K`가 100). 이제 7이다.
    동작이 바뀌는 수정이다.
