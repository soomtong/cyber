# `Array.append`는 값을 옮긴다, 성장은 복사 대신 이동한다 (2026-11-08)

상태: 구현됨(`3979bb13`). 발견 이슈 F-26(06장 §7.1의 6 · 7 · 8번).

## 배경

`fn (&&Array[]) append(val T)`는 `@ptr_init(*self.buf[self.length], val)`로 원소를 넣는다. `@ptr_init`은 둘째 인자에
`semaOwn`을 적용하므로 매개변수 `val`을 한 번 더 복사하고, 함수가 끝날 때 `val` 자신을 파괴한다. 호출자가 `a.append(Res{..})`처럼
rvalue를 넘겨도 `@deinit`이 삽입마다 한 번(임시), 성장 때 옛 원소마다 한 번(`ensure_cap`이 새 버퍼에 복사한 뒤 옛 것을 파괴),
끝에 한 번 더 돌아 원소당 세 번이다(06장 실습 6). `NoCopy` 원소는 그 복사 때문에 `append`가 컴파일되지 않는다
(`Cannot copy \`R\`, type implements \`NoCopy\`.`가 core.cy 안을 가리킨다). `@deinit`이 자원을 닫는 타입이면 세 번 닫힌다.

같은 절의 나머지 둘: `Array.clone()`이 없는 필드 `cap`을 써서 컴파일되지 않고(`header`가 용량), `ArrayStore.append(slice [&]T)`는
같은 세 줄이 두 번 붙어 있어 원소가 두 번 들어간다(`len=6`).

## 결정

1. 원소를 넣는 자리에서 매개변수를 옮긴다. `Array.append(val T)` · `Array.insert`의 끝 삽입 · `ArrayStore.append(val T)`가
   `@ptr_init(…, move val)`을 쓴다. `move`는 소유를 넘기고(`owned`라 `semaOwn`이 복사하지 않음) 매개변수를 죽은 지역으로
   표시해 함수 끝 파괴도 없다. 호출자 쪽 복사는 그대로다. 지역을 넘기면 복사본이 들어가고(`a.append(x)` 뒤 `x`는 살아 있음),
   rvalue나 `move x`를 넘기면 복사 없이 들어간다. 그래서 `NoCopy` 원소는 `a.append(R{..})` · `a.append(move r)`로 넣는다.
2. 참조 계열 원소(`^T`, 함수 값)는 예외다. 참조 매개변수는 호출자가 관리하며 +0으로 넘어오고(`ownOrManageArg`), `move`가
   `Cannot move a reference parameter.`로 거부된다. 그 자리에서는 기존처럼 `@ptr_init(…, val)`(retain 한 번)을 유지한다.
   `#switch type.info(T)`의 `.ref` · `.func` 분기로 가른다.
3. 성장(`ensure_cap`)은 옛 버퍼의 바이트를 `@memcpy`로 새 버퍼에 옮기고 옛 버퍼만 해제한다. 복사 생성자와 파괴자를 부르지 않는다.
   원소가 자기 주소에 의존하지 않는 한 비트 이동이 소유 이동이다(core의 `TODO: Move old elements to new buffer.`).
   `Array`와 `ArrayStore` 둘 다.
4. `Array.clone()`은 `header = self.length`(용량 = 길이, Ex 비트 0)로 만들고 길이 0이면 `buf = none`이다(`@init_sequence`와 같은 모양).
5. `ArrayStore.append(slice)`의 중복 블록을 지운다.

## 구현 메모

- `src/builtins/core.cy`: `Array.append(val)` · `ArrayStore.append(val)`의 `@ptr_init(…, move val)`(`#switch type.info(T)`의 `.ref` · `.func`은
  복사 유지), `Array.insert`는 `@memmove`로 꼬리를 한 칸 밀고 같은 방식으로 넣는다(이전에는 끝 삽입과 중간 삽입이 다른 경로였고
  중간 삽입은 원소를 하나씩 대입 복사했다). `Array.ensure_cap` · `ArrayStore.ensure_cap`의 `@memcpy` 이동, `Array.clone`의 `header`,
  `ArrayStore.append(slice)` 중복 삭제.
- `move val`은 함수 본문 최상위에서만 된다(`Can only move variable declared in the same block.`). 처음에 `insert`의 끝 삽입 분기
  (`if idx == self.length:`) 안에 두어 실패했고, 그래서 삽입 위치와 무관하게 한 곳에서 넣는 모양으로 바꿨다.
- 테스트: behavior `memory/array_append_move.cy`(전역 카운터로 `@deinit` 횟수: 9개 append + 2개 insert 동안 0, 블록 끝 11. 지역 전달은
  복사라 그대로 쓸 수 있음, `move` 전달, 삽입 순서, `^int` 원소 retain, `clone`의 독립성과 빈 배열, `ArrayStore.append(span)` 길이).
  06장 실습 6 스크립트는 삽입 중 `deinit` 없이 끝에 9번.

## 기대 동작

- 06장 실습 6 스크립트(`Res` 9개 append, 8에서 성장): 삽입 중 `deinit` 없음, 끝에 9번.
- `Array[R]`(`with NoCopy`)은 `append` 자리에서는 더 이상 막히지 않지만 다른 복사 메서드 때문에 아직 타입 자체가 컴파일되지 않는다(아래 "남은 것").
- `b := a.clone(); b.append(4)`에서 `a`는 그대로.
- `s := ArrayStore[int]{1, 2}; s.append(other[..])`가 `len=4`.

## 남은 것

- `NoCopy` 원소는 여전히 `Array[R]{}` 자체가 컴파일되지 않는다. 템플릿 인스턴스의 다른 메서드(`PtrSpan.init(val T)` 채우기,
  `set(val T)`, `@init(n, val)`, `size_up`, 값을 돌려주는 `@index`)가 원소를 복사하기 때문이다. `append`만 고쳐서는 오류 위치가
  옮겨갈 뿐이다. 허용하려면 복사하는 메서드를 `type.is_copyable(T)`로 조건부 선언하는 수단이 필요하다(core에 `#[cond]`는 쓰이지 않음).
- `for a |r|`은 원소를 복사해 `r`에 넣는다(순회마다 `@deinit` 2회). 빌림 순회(`for a |&r|`)는 별개 과제.
- `Slice.append(val)` · `insert`도 같은 `@ptr_init(…, val)` 복사다. `Slice`는 버퍼 공유(`project_slice_append_aliasing.md`)라 따로 본다.
