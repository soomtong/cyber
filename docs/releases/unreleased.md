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
- 반복 본문은 반복문 밖의 변수를 옮기지 못한다(다음 반복이 읽는다). 새 문구 'Cannot move `a` here: it is declared in an outer
  block. ...'. 갈래 안에서도 바깥 변수의 멤버는 옮기지 못한다.
- 결정 `docs/decisions/project_last_use.md`, 매뉴얼 Moving 절.
