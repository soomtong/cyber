# Slice.append의 버퍼 공유와 누수

2026-11-01, `src/tools/bench.cy`를 고치다 발견했다. 기록만 하고 고치지 않았다(설계 결정이 필요).

## 재현

Debug CLI(Trace)에서 다음은 "unreleased refcount: 1"로 끝난다.

```
a := []str{'x'}
c := a.append('a' + 'b')
```

`a = a.append(...)`처럼 받는 쪽을 덮어쓰면 깨끗하다. 원소가 관리 대상이 아닌 `[]int`도 문제가 드러나지 않는다.

## 원인

- `Slice.clone_on_resize`(`src/builtins/core.cy`)는 버퍼가 유일 참조이고 용량이 남으면 새 버퍼 없이 `self.*`를 돌려준다.
  복사본이 버퍼를 하나 더 참조하므로 `a`(길이 1)와 `c`(길이 2)가 같은 버퍼를 공유한다.
- `Slice.@deinit`은 버퍼가 유일 참조가 된 쪽에서만 원소를 해제하고, 그 쪽의 `_len`까지만 해제한다.
  짧은 `a`가 나중에 해제되면 `c`가 붙인 원소가 남는다. 해제 순서에 따라 누수 여부가 갈린다.
- `c := a.append(s1)` 뒤 `d := a.append(s2)`는 덮어쓰지 않는다. 첫 append로 버퍼 참조가 2가 되어 두 번째는 복사한다
  (`c[1]`은 `ab`, `d[1]`은 `cd`로 확인). 다만 첫 append의 누수는 그대로 남는다.

## 경위

- `clone_on_resize`의 유일 참조 빠른 경로, `Slice.@deinit`, 값을 돌려주는 `Slice.append`는 모두 upstream `b751ca6c`
  (2025-11-21, "[all] some updates")에서 한꺼번에 들어왔다. 코루틴 삭제와 같은 대형 커밋이라 설계 이유는 남아 있지 않다.
- 그 전(`c992b94e`, 2024-09)에는 `List.append(self, val) void`처럼 제자리에서 바꾸는 참조형 리스트였다. 별칭 문제가 없었다.
- 이후 upstream 변경은 기계적이다. `ecb7df2c`(2025-12-12)가 append 연산자를 `<<`에서 `+`로 바꿨고(`res <<= x` →
  `res += x`), `e4804c08`(2025-12-12)이 `$`를 `self`로 바꿨다. upstream 마지막 커밋 `c853fcc2`(2025-12-21)까지 로직은 같다.
- `<<` → `+` 변경은 위험을 키운다. `c := a + b`는 새 값을 만드는 덧셈으로 읽혀 받는 쪽을 남기는 코드를 부추긴다.
- 문서(`docs/docs.md` "Slice operations")와 테스트(`src/test/core/Slice.cy`)는 모두 `arr = arr.append(x)` · `a = a + 1`처럼
  덮어쓰는 형태만 쓴다. 받는 쪽을 남기는 경우의 규칙은 어디에도 없다.
- 제자리 변경이 필요하면 `Array[T]`를 쓰라는 구도로 보인다. `Array`의 `append`는 `fn (&&Array[]) append(val T)`로
  배타적 빌림을 받아 제자리에서 바꾸고 값을 돌려주지 않는다. `Slice`는 값 의미(COW)를 맡는다.

## 해석

`append` · `+` · `insert` 등 `clone_on_resize`를 거치는 연산은 "받는 쪽을 결과로 덮어쓴다"를 전제한 설계로 보인다.
언어 차원에서 이 전제를 강제하지 않으므로 사용자 코드가 쉽게 어긴다. 후보는 다음과 같다.

1. 버퍼에 초기화된 원소 수(최고 수위)를 두고 `@deinit`이 그 수까지 해제한다. `size_down` · `clear`가 이 수를 함께
   갱신해야 한다.
2. 유일 참조여도 `self`가 지역 변수로 계속 살아 있으면 복사한다. 컴파일러가 "마지막 사용"을 알아야 한다.
3. 빠른 경로를 없애 항상 새 버퍼를 만든다. 반복 append가 O(n^2)가 되어 받아들이기 어렵다.

## 지금의 우회

받는 쪽을 덮어쓴다(`args = args + cmd`). `src/tools/bench.cy`의 `peak_memory`가 이렇게 쓴다.
