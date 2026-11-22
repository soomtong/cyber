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

## 0.4.0..0.4.17 코드 리뷰에서 나온 수정 (2026-11-22)

`/code-review high` 3815c4c0..23df09eb의 10건을 쉬운 것부터 고쳤다. 빌림 검사 셋은 아래 별도 항목이다.

- toon: `EncodeOptions.indent` · `DecodeOptions.indent`가 1보다 작으면 `encode` · `decode`가 `error.Range`를 돌려준다. 전에는
  `toon.decode('a:\n  b: 1', DecodeOptions{indent=0}, &&d)`가 'Division by zero'로 panic했고, `indent=-2`는 `b`를 버린
  `{"a":{}}`를, `encode`의 `indent=0`은 중첩을 잃은 `a:\nb: 1`을 냈다. `decode`는 `diag.msg`에 'The indent must be at least 1,
  found 0.'을 남긴다. 옵션 값은 입력 텍스트의 형식 오류가 아니므로 `error.Syntax`가 아니다. 확인: `modules/toon.cy`.
- `str.index_rune`:
  - 비 ASCII 문자열에서 2 · 3바이트 rune을 찾지 못했다(`'héllo'.index_rune(233)`이 none). `utf8Encode`의 길이를 버리고
    4바이트 버퍼 전체로 찾았다. 이제 인코딩한 길이만큼 찾는다.
  - surrogate(`0xD800`)가 가드를 통과해 'thread panic: error'로 호스트를 끝냈다. 코드 포인트가 아닌 값(surrogate, 음수,
    `0x10FFFF` 초과)은 이제 none이다. `index_rune(0)`도 찾는다.
  - `index_any_rune(AsSpan[int])` 오버로드가 바이트 검색 `index_any`를 불러 'Expected type `AsSpan[byte]`. Found `[&]int`.'로
    컴파일되지 않았다. 확인: `core/strings_utf8.cy`.
- 세션(`persist_main`)에서 본문이 실패한 함수를 값으로 다시 쓰면 호스트가 `bc_gen.zig:142`에서 panic했다
  (`fn bad[T Any](x T) -> int: return x + 1` 뒤 `f := bad[bool]`, 다시 `g := bad[bool]`. 메서드 본문만 실패한
  `Box[Array[int]].dup`도 같다). `FuncInfo.body_failed`를 호출 경로(`checkCallee`)에서만 봤다. 함수 값을 만드는 `sema_func_sym`과
  함수 템플릿 인스턴스 경로도 `checkCallee`를 불러, 원래 오류를 같은 위치에 다시 낸다. 확인: lib 테스트 'A function value of a
  body that failed does not break the next compile.'
- 언어 서버: 오류가 있는 모듈을 열면 그 진단이 사라지고 다음 편집 때까지 돌아오지 않았다. 그 모듈을 쓰는 문서의 지난 검사 목록
  (`related`)에 남아 있어, 다시 검사 · 닫기가 열린 모듈의 진단을 빈 목록으로 덮었다. 이제 열린 모듈의 진단은 지우지 않는다. 모듈을
  닫으면 그 진단은 지워지고, 쓰는 문서의 다음 검사가 디스크의 모듈로 다시 낸다. 확인: LSP 테스트 'Opening or closing a module with
  an error keeps its diagnostics.'
- struct 필드 기본값이 global 같은 place를 읽으면 복사 없이 공유됐다. `s str = G`의 `A{}`를 여러 번 만들면 문자열이 깨지거나
  'double free', 'panic: index out of bounds'가 났고, `Array[int]` 기본값은 이중 해제였다. `semaFieldDefault`의 결과가 명시한
  필드 값과 달리 `semaOwn`을 거치지 않았다. 이제 같은 소유 처리를 받는다: 복사할 수 있는 값은 복사하고, `NoCopy` 값을 place에서
  읽는 기본값은 필드 선언의 기본값 식에서 'Cannot copy `Array[int]`, type implements `NoCopy`.'다(깨지는 변경). `meta.field_default`와
  `json.to`도 같다. 확인: `types/struct_default_initializer.cy`, `types/struct_default_nocopy_global_error.cy`, `modules/json.cy`.
- regex: 캡처 그룹이 많은 패턴이 짧은 입력에 GB 단위 메모리를 썼다(`regex.compile('()'.repeat(4000)).captures('x')`가 RSS
  1 GB, `'()'.repeat(16000)`은 약 16 GB를 잡으려다 OOM). 검색 작업 버퍼가 명령 수 × 슬롯 수라 그룹 수의 제곱으로 커지는데
  `MaxInsts`가 막지 못했다. 이제 명령 수 × 캡처 슬롯 수(그룹 0을 포함해 그룹마다 2)가 새 한도 `regex.MaxSlotTable`(1048576)을
  넘으면 `compile`이 `error.TooBig`이다: 'The pattern is too big: its N groups and M instructions need more than 1048576 capture
  slots. ...' 캡처 검색 한 번의 작업 메모리는 16 MiB 이하다. 그룹이 수십 개인 패턴은 영향이 없다. 확인: `modules/regex.cy`.
- 평가 순서: 뒤 피연산자가 문장을 끌어올리면(`!` 언랩, 임시 지역) 그 문장이 앞 피연산자보다 먼저 실행됐다. 0.4.8의 왼쪽에서
  오른쪽 순서가 깨진 곳은 맵 리터럴의 키와 값(`Map[int,int]{(say(1))=sayr(2)!}`가 `r2 1`), `..=` 슬라이스의 수신자와 시작,
  범위의 시작(`say(1) .. sayr(2)!`), 포인터 인덱스의 포인터, 함수 포인터 호출의 callee다. 앞 피연산자를 `seqPushRes`로 등록한 뒤
  뒤 피연산자를 분석한다. 확인: `functions/eval_order.cy`.

## 갈래가 주는 빌림의 남은 구멍 (0.4.0..0.4.17 코드 리뷰, 2026-11-22, 깨지는 변경)

F-170(위 "갈래가 주는 빌림의 주인")이 남긴 구멍 셋이다.

- `switch` case 캡처: `c := Ref.one(&y)`에서 `s := switch c: case .one |p| => p, else => &x`가 컴파일러를 'index out of bounds:
  index 8, len 8'로 끝냈다. 슬롯이 다시 쓰이면 엉뚱한 지역이 주인이 됐다. case 캡처가 주인 없이 선언돼, case가 끝나며 사라진
  캡처 id가 결과의 주인으로 남았다. 이제 값 캡처 `|p|`는 control 값이 빌린 대상을, 빌림 캡처 `|&v|`는 control을 담은 지역을
  빌린다. 그래서 `switch` 문 안의 `r = p`도 컴파일된다(전에는 '`r` can not outlive `p`.'). case 지역의 빌림을 결과로 내면
  'The result of `switch` can not outlive `n`.'이다. 확인: `memory/borrow_switch_capture.cy`, `borrow_switch_capture_local_error.cy`,
  `borrow_switch_capture_owner_error.cy`.
- `scope` 함수의 반환: `fn g(scope p &[]int) -> scope &int`의 `return if (k == 1) &p[0] else &y`가 컴파일돼 끝난 프레임을
  가리키는 빌림을 돌려줬다. 갈래 순서를 바꾸면 오류였다. `switch`와 `o ?else &y`도 같았다. 매개변수와 본문 지역은 블록 깊이가
  같은데 `shorterOwner`가 동점이면 첫 갈래를 골랐고, 반환 검사는 주인 하나만 봤다. 이제 동점이면 나중에 선언된 지역을 고르고,
  반환 검사(`checkReturnOwners`)가 갈래의 모든 주인과 반환하는 지역의 loan을 본다. `?&T`, `!&T`, 빌림 컨테이너의 반환은 전에
  검사가 없어 `return &y`가 컴파일됐다. 이제 `&T`처럼 검사한다. 오류는 'Expected to return a borrow from the same scope as `p`.'.
  확인: `memory/scope_return_branch.cy`와 `scope_return_*_error.cy` 여섯.
- 필드 · 원소 저장과 인자: `h.r = if (k == 2) &y else &a[0]` 뒤 `a << i`를 100번 하고 `h.r`을 읽으면 쓰레기 값이 나왔다.
  `f(if ... else &a[0], &&a)`도 컴파일됐다. 갈래의 다른 주인(`borrow_pending`)을 지역 선언과 다시 대입만 반영했다. 이제 필드 ·
  원소 저장은 모든 주인에 loan을 걸고, 인자 충돌 검사는 인자마다 모든 주인을 본다. 오류는 'Expected exclusive access. There is
  another active borrow to `a`.'와 'Cannot pass an exclusive borrow of `a` with another argument that borrows `a`.'. 확인:
  `memory/borrow_branch_store.cy`와 `borrow_branch_{field,elem,arg,arg_ex}_error.cy`.

이 셋을 고치며 찾은 것(템플릿 함수 인자, 언랩 캡처, 복합 대입)은 아래 절에서 고쳤다.

## 리뷰가 미룬 후보와 수정 중 찾은 결함 (2026-11-22)

위 두 절의 리뷰가 10건 제한으로 미룬 후보와, 그 10건을 고치며 찾은 결함이다.

빌림 검사(깨지는 변경):

- 템플릿 함수의 인자 충돌: `fn f(%T type, r &T, b &&Array[T])`에 `f(int, &a[0], &&a)`가 컴파일돼, `f`가 `b`를 늘리면 `r`이
  해제된 메모리를 읽었다. 인자 owner 충돌 검사가 `matchFuncSig`에만 있었다. 검사를 `ArgBorrows`로 떼어 `matchGenericFuncRt`도
  쓴다. 추론 매개변수(`%R`), 갈래 빌림, 배타 수신자의 제네릭 메서드(`b.add_from(&b.items[0])`)도 같다. 오류는 'Cannot pass an
  exclusive borrow of `a` with another argument that borrows `a`.'. 확인: `memory/borrow_generic_arg.cy`와
  `borrow_generic_{arg_ex,arg_branch,method_arg}_error.cy`.
- 언랩 캡처: `if o |q|: r = q`(`o`는 `?&int`)가 '`r` can not outlive `q`.'로 막혔다. 이제 `if` · `while` 언랩 캡처는 `switch`
  캡처처럼 옵션이 빌린 대상을 빌린다. 값 캡처의 빌림 `r = &q`는 그대로 오류다.
- 빌림 벡터: `[N]&T`가 빌림 컨테이너가 아니어서 검사에서 빠졌다. 블록 안 `r = [1]&int{&y}`가 블록 밖에서 쓰레기 값을 읽었고,
  `xs := [1]&int{&a[0]}; a << 4`도 컴파일됐다. 이제 빌림 벡터는 빌림 컨테이너이고 리터럴은 원소마다 주인을 빌린다. core
  `Vector.next` · `Span.next`가 `scope`가 돼 `for xs |p|`, `for xs[1..] |p|`로 돌 수 있다(전에는 'Returning a borrow container
  requires a `scope` modifier.'). 캡처는 벡터가 빌린 대상을 빌린다.
- 빌림 컨테이너의 복사(`r = h`)가 원본의 첫 주인만 이어받아 `a << 4`가 통과했다. 이제 모든 주인을 이어받는다(`copyBorrowLoans`).
- 확인: `memory/borrow_unwrap_capture.cy`, `borrow_for_vector.cy`와 `borrow_{unwrap_capture,while_capture,for_vector,for_span,
  vector_lit,copy_loans}_*_error.cy`. `r = xs[0]`, `r = h.b`는 아직 컨테이너 자신을 주인으로 본다(보수적).

평가:

- 복합 대입이 좌변의 수신자와 인덱스를 두 번 계산했다(`arr[say(1)] += 2`가 `say(1)`을 두 번, `getr(log, p).a += 1`이 `g g`).
  `x op= y`를 `x = x op y`로 분석하며 좌변을 다시 분석했다. 이제 부작용이 있을 수 있는 수신자와 인덱스를 우변보다 먼저 숨은 지역에
  한 번 담는다(`stabilizeOpAssignLeft`). 모든 복합 연산자, Map 키(`@index` · `@set_index`), 중첩 인덱스, 포인터 역참조에 적용된다.
  변수 · 필드 경로만의 좌변은 바이트코드가 그대로다. 순수로 보는 연산식 인덱스(`a[i + 1]`)는 두 번 분석하므로 부작용이 있는
  사용자 연산자 오버로드는 두 번 돈다. 확인: `functions/eval_order.cy`.

호스트를 끝내던 입력(이제 스크립트 panic):

- `str.init_rune(0x200000)`: 0x200000..0x3FFFFF가 검사를 지나 `u21` 캐스트에서 죽었다. 음수, 0x10FFFF 초과, surrogate는
  'Invalid rune: N'이다(전에는 'InvalidRune').
- `'héllo'.seek_pos(-1)`: 음수나 범위를 넘는 n은 'Out of bounds rune index: N'이다. `seek_pos(룬 개수)`는 ASCII 문자열에서도
  길이를 돌려준다(전에는 UTF-8 문자열만). `str.rune_str_at`이 끝에서 잘린 UTF-8 시퀀스에서 문자열 밖을 읽던 것도 고쳐 첫 바이트
  하나를 돌려준다.
- `Raw.fmt`의 64자리를 넘는 `width`: 고정 버퍼에 패딩해 죽었다. 이제 어떤 폭이든 채운다. 음수 폭은 'Invalid width: N', 128
  이상의 `pad`는 'Invalid pad: N, expected an ASCII rune'.
- 확인: `core/str_init_rune_{invalid,surrogate}_panic.cy`, `core/str_seek_pos_neg_panic.cy`, `core/raw_fmt_neg_width_panic.cy`,
  `core/strings.cy`, `core/strings_utf8.cy`, `core/byte.cy`.

표준 라이브러리:

- `time.Duration`의 `*`: 음수 Duration에 큰 `n`을 곱하면 결과가 범위 안이어도 'The duration is out of range.'였다
  (`time.nanos(-1) * 1000000000000000000`). 음수 Duration은 초를 하나 내려 저장하는데, 검사가 그 초의 절댓값을 봤다. 크기끼리
  곱하고 부호를 붙인다. 확인: `modules/time.cy`.
- `json.to(f32, v)` · `json.decode(f32, src)`: `f32` 범위를 넘는 유한한 수(`1e39`)가 오류 없이 `inf`였다. 이제 `error.Overflow`와
  'The number `1e+39` does not fit `f32`.'. 너무 작은 수는 Go처럼 0으로 반올림한다. 확인: `modules/json.cy`.

호스트 · 도구:

- `cyber-lsp`가 stdout 쓰기에 실패하면(클라이언트가 스트림을 닫음) 응답 버퍼를 두 번 해제했다. 이제 남은 응답을 한 번씩 해제하고
  'cyber-lsp: can not write a message: ...'를 stderr에 낸 뒤 종료 코드 1로 끝난다(`transport.sendAll`, 단위 테스트).
- `cl_vm_set_stack_limit`에 큰 값을 넘기면 32비트 대상(wasm32)에서 `@intCast` overflow panic이었다. `usize`를 넘는 값은 `usize`
  최댓값(제한 없음과 같다)으로 맞춘다. `cl_vm_set_memory_limit`도 같은 helper를 쓴다.
- 기존 문제(고치지 않음): `zig build lib -Doptimize=ReleaseSafe -Dtarget=wasm32-freestanding`는 Zig 0.17.1 std 안의 오류 71개로
  실패한다(23df09eb에서도 같다). wasm32-wasi의 `build-test`는 빌드된다.
