# `Array`는 복사할 수 없는 원소를 담는다: 옮겨 넣고, 빌려 읽고, 빌려 순회한다 (2026-11-11)

상태: 구현됨. 발견 이슈 F-26의 남은 것. 사용자 결정(2026-11-11): "암묵적 복사는 없고, 이동과 빌림은 이미 있는 문법 그대로 쓴다."

## 배경

`Array[R]`(`R`은 `with NoCopy`, 또는 `NoCopy` 멤버를 가진 struct, 또는 `Array` 자신)은 `Array[R]{}`부터 컴파일되지 않았다.
템플릿 인스턴스의 메서드는 이름으로 처음 찾을 때 그 이름의 오버로드가 모두 컴파일되는데, 그 가운데 원소를 복사하는 것이 있으면
`Cannot copy \`R\`, type implements \`NoCopy\`.`가 core.cy 안을 가리켰다. 배열의 배열(`Array[Array[int]]`)도 같은 이유로 못 썼다.

## 결정

언어의 기존 규칙 셋을 그대로 연장한다.

- `NoCopy` 값은 `g := f`가 컴파일 오류이고 옮기려면 `move`를 적는다.
- 임시 값은 주인이 없어 그냥 옮겨진다(`Box[R]{x=R{id=7}}`, `a.append(R{id=1})`).
- 빌림은 `&`로 드러낸다(`case .a |&a|:`, `&a[i]`).

그래서:

1. 리터럴은 원소를 옮겨 받는다. `Array[R]{R{id=1}, R{id=2}}`. 변수는 `Array[R]{move x}`. `Array[R]{x}`는 복사 오류.
2. `a[i]`를 값으로 쓰면(`x := a[0]`) 복사 오류 그대로다. `&a[i]`로 빌리거나 `a[i].id`처럼 멤버를 읽는다. 자동 빌림은 넣지 않는다
   (같은 식이 타입에 따라 복사도 되고 빌림도 되면 `g := f`를 막는 이유와 어긋난다).
3. `for a |r|`는 복사 오류 그대로다. `for a |&r|`(`for a |i, &r|`)가 빌림으로 순회한다. `case .a |&a|:`와 같은 모양이다.
   복사할 수 있는 원소에서도 쓸 수 있고 순회마다 복사 · 파괴가 없다.

## 구현

- 조건부 메서드: 원소를 복사하는 `Array` 메서드에 `#[cond=type.is_copyable(T)]`(F-91이 만든 수단). `append(span)` ·
  `append(arr)` · `<<`의 같은 둘 · `@init(n, val)` · `clone` · `contains` · `index` · `last` · `size_up` · `setLast`.
  `NoCopy` 원소에서 부르면 ``Can not find the symbol `last` in `Array[R]`.``가 사용자 줄을 가리킨다.
  `@index`(값 반환)와 `next`에는 붙이지 않았다. 그래야 `x := a[0]` · `for a |r|`의 오류가 `Cannot copy`로 남는다.
- `<<`(val T)는 `move val`로 넘긴다. `NoCopy`에서는 `append` 오버로드가 하나라 `Self.append[0]`을 쓸 수 없어 `#if`로 가른다.
- `@set_index`: `NoCopy`면 `self.buf[idx] = move val`(옛 원소 파괴 뒤 새 값 이동).
- 리터럴: 컴파일러는 원소를 숨은 지역 `_vec`(`Vector[N, T]`)에 만들고 `@init_sequence(init [&]T)`에 span으로 넘긴다.
  원소 타입이 복사 불가면 `sema_call_init_span`이 호출 뒤 `_vec`를 `.dead`로 표시해 원소를 파괴하지 않고,
  `Array.@init_sequence`는 `@memcpy`로 바이트를 가져온다(`ensure_cap`의 이동과 같은 방식).
  약속: 복사할 수 없는 원소의 `@init_sequence` · `@init_record`는 넘겨받은 원소를 가져간다. 복사하는 구현은 어차피 컴파일되지 않는다.
- 빌림 순회: `for` 문의 each가 `&이름`이면 `next` 대신 `next_borrow(idx &int) -> scope ?&T`를 부르고 캡처는 `&T`다.
  `Array` · `Slice`에 구현. 없는 타입은 `` `Map[str, int]` can not be iterated by borrow. It has no `next_borrow` method. ``
  순회 중 배열은 빌린 상태라 `a << x`는 기존 검사(`Expected exclusive access.`)가 막는다.

## 확인

- 테스트 `memory/array_nocopy_elem.cy`: 빈 리터럴 · `append` · `<<`, 리터럴 이동과 `move x`, 루프 안 리터럴, 반환 · 이동,
  인덱스 대입, `insert` · `remove` · `size_down` · `clear`, 성장, 빌림 순회(`continue` · `break`), span, `NoCopy` 멤버 struct,
  배열의 배열, 복사 가능 원소의 빌림 순회, `Slice` 빌림 순회. 모두 원소당 `@deinit` 한 번.
- 오류 테스트 `memory/array_nocopy_index_copy_error.cy` · `array_nocopy_for_copy_error.cy` · `array_nocopy_last_error.cy` ·
  `array_nocopy_literal_var_error.cy`, `control_flow/for_iter_borrow_unsupported_error.cy` · `for_iter_borrow_mutate_error.cy`.

## 남은 것

- `Slice` · `ArrayStore` · `Map`의 `NoCopy` 원소는 그대로 안 된다(`Slice.append`는 버퍼 공유라 따로 본다).
- `sort` · `join`은 조건을 붙이지 않았다(원소 타입에 따라 core 안의 오류가 난다).
- 복사할 수 있고 `@deinit`이 있는 원소의 리터럴(`Array[C]{C{n=1}}`)은 여전히 복사 뒤 임시를 파괴한다(`@deinit`이 리터럴에서 한 번 더).
  모든 원소를 옮기려면 `Span.@init_sequence`처럼 span을 그대로 돌려주는 구현과 구분해야 한다.
- 원소를 배열 밖으로 옮기는 수단(`pop` · `take`)이 없다. `remove`는 파괴한다.
- `Map` · `str` 등의 빌림 순회(`next_borrow`)는 없다.
