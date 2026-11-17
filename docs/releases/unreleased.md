# 0.4.14 이후 변경 (미릴리스)

0.4.14(2026-11-17) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## `Slice`의 크기 변경은 제자리, 새 목록은 `-ed` 메서드 (깨지는 변경)

- `append`, `insert`, `remove`, `clear`, `size_down`, `size_up`이 받는 변수를 그 자리에서 바꾸고 아무것도 돌려주지 않는다
  (`fn (&&Slice[]) append(val T)`). `Array`와 같은 꼴이다. `xs = xs.append(1)`은 이제 `xs.append(1)`이다.
- 새 목록을 돌려주는 메서드 `appended`, `inserted`, `removed`가 생겼다. 받는 변수는 그대로다. `+`는 `appended`와 같고,
  `xs += v`는 `append`처럼 제자리에서 붙인다(`+=`가 타입의 `` `+=` `` 메서드를 부른다. 없으면 전처럼 `xs = xs + v`).
- `[]T`에 `pop() -> ?T`가 생겼다(`Array.pop`과 같다).
- 옛 꼴은 고칠 방법을 말하는 컴파일 오류다. `xs = xs.append(1)` → '`append` changes `xs` in place and returns nothing.
  Write `xs.append(1)` as a statement.', `ys := xs.append(1)`은 `xs.appended(1)`도 알려 준다. 새 목록 메서드의 결과를 버리면
  (`xs.appended(1)`만 쓴 문장, `_ = xs.removed(0)`) 제자리 메서드를 알려 주는 오류다.
- 버퍼를 다른 값과 나눠 가진 `Slice`(`ys := xs`, 부분 슬라이스)를 제자리에서 키우거나 가운데를 바꾸면 먼저 복사한다.
  다른 값은 원소와 길이를 그대로 본다. 원소 쓰기(`xs[i] = v`, `sort`, `reverse`)는 복사하지 않아 버퍼를 나눈 값 모두에
  보인다(전과 같다). `size_down` · `clear`는 복사하지 않는다(잘린 원소는 다른 값을 위해 살아 있다).
- 끝이 아닌 `remove` · `insert`가 버퍼를 혼자 가진 `Slice`에서 할당 없이 제자리로 돈다(0.4.13부터 항상 복사했다).
- REPL · 세션(`persist_main`)의 마지막 줄 `xs.append(4)`는 결과가 없는 문장이다(0.4.13~0.4.14에서는 오류). 마지막 줄의
  `xs.removed(0)`은 새 목록을 결과로 보여 준다.
- 0.4.13에서 넣은 "버린 크기 변경 결과" 오류(`checkDroppedSliceResult`)는 새 목록 메서드에만 남는다.
- 전역 변수는 배타적으로 빌릴 수 없어 전역 `[]T`에는 제자리 메서드를 쓸 수 없다(`g.append(v)`는 고칠 방법을 말하는 컴파일
  오류). 전역의 `g += v`는 `g = g + v`(복사)로 남는다. 전에는 `g = g.append(v)`가 버퍼를 다시 써서 빨랐으니, 전역 목록을 키우는
  반복문은 느려진다. 지역이나 `&&`로 받는 값의 필드에 둔다.

## 포인터 · 빌림으로 지역 변수를 대입하면 해제된 메모리를 읽던 결함 (F-161)

- `p.* = r`(`p`가 `Ptr[T]`, `&T`, `&&T`이고 `r`이 관리 대상 값을 든 지역 변수)이 `r`을 복사하지 않고 넣어, 함수가 끝나며 `r`과
  대상이 같은 값을 두 번 놓았다. 뒤에 대상을 읽으면 해제된 메모리였다(ReleaseSafe에서 `-6148914691236517206`). 이제 복사한다.
- `&&T`로 받은 값에 `p.* = v`로 대입할 수 있다(전에는 'Expected pointer type.').
