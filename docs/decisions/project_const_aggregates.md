# 문자열을 가진 const 구조체 · 고정 배열 (2026-11-27)

상태: 구현됨. Find Cost of Tile 예제가 `const Fields = []Field{...}`에서 'Expected eval eligible type'로 막힌 것이 계기다. 사용자에게
슬라이스 `const`의 이점과 단점을 설명하고 권고(슬라이스 `const`는 넣지 않고 `str`을 가진 고정 배열 `const [N]T`를 허용, 슬라이스
`const`에 안내 오류와 fix)를 냈다. 사용자: "전역에 고정되지 않은 버퍼를 두는 문제지? 권고 내용이 좋다. 권고를 준수하자. 해당 구문에
대한 린트 제공하나?", 이어서 "그래 진행해".

## 왜 슬라이스는 아닌가

`[]T`는 복사해도 크기가 바뀌기 전까지 버퍼를 공유한다(Go 꼴). 상수를 정적 버퍼 하나로 두면 `xs := Names` 뒤 `xs[0] = ...`가 상수를
바꾼다. 쓸 때마다 복사하면 할당이 매번 생겨 상수의 이점이 사라진다. 읽기 전용 슬라이스 타입(Rust `&'static [T]`, Zig `[]const T`)은
없다. 고정 배열은 값 의미라 이 문제가 없다.

## 비교

- Rust: `const`는 쓰는 자리마다 값을 넣는다. 공유는 `static`과 `&'static [T]`.
- Zig: comptime 배열과 `[]const T`.
- Nim: `const` seq는 쓸 때마다 복사된다.
- Python: 관례로 튜플 상수.

## 결정

1. 컴파일 타임 값으로 펼칠 수 있는 타입(`Type.isConstExpandable`): 관리형이 아닌 값, `str`, 그리고 이것들로만 된 구조체 · 고정
   배열. 사용자 `@copy`나 `NoCopy`가 있는 구조체는 뺀다(쓰는 자리마다 새로 만드는 뜻과 맞지 않는다). `ensure_eval_eligible_type`과
   타입을 적은 `const`의 `isConstEligible`이 이것을 쓴다.
2. 문자열 리터럴(`EvalStr`)이 `str` 자리에 오면 컴파일 타임 힙의 `str`이 된다(`cte.evalFitTarget`). 펼칠 때 다시 문자열
   리터럴 IR이다(`ct_inline.value`의 `bt.Str`). 구조체 · 배열의 펼침은 원래 필드 · 원소마다 되돌아 부른다.
3. 상수의 원소 · 필드에 대입은 오류다(`sema_assign.checkConstPart`). 전에는 펼친 임시 값만 바꿔 조용히 아무 일도 하지 않았다
   (`int` 배열에도 있던 결함). 왼쪽을 `[i]` · `.f`로 따라가 뿌리 이름이 상수면 오류.
4. 슬라이스 `const`는 전용 문구와 fix: 'A slice cannot be a constant: its copies share one buffer. Use a fixed array `[2]str`, or
   `global` for a value that changes.' fix는 `[]`를 `[N]`으로 바꾼다(N은 리터럴의 원소 수). 리터럴이 아니면 `[N]`으로 적고 fix는
   없다. 1.0 전이라 경고 단계 없이 오류다(전에도 오류였고 문구만 바뀐다).

## 하지 않은 것

- 읽기 전용 슬라이스 타입과 정적 데이터: 쓰는 곳이 생기면 본다.
- 상수의 `&&` 메서드 호출(`Fields[0].name.append(...)` 같은 꼴)은 대입과 같은 임시 값 문제다. `str`에는 그런 메서드가 없어 지금 경로로
  드러나지 않는다. 쓰는 곳이 생기면 같은 검사로 넓힌다.
- `const E = .a`(열거 점 리터럴)는 'Unsupported compile-time expression: `dot_lit`'로 막혀 있다. 이번 범위 밖.
