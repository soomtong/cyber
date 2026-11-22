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
