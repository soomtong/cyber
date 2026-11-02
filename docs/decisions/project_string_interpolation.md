# 문자열 보간 성능

작성일 2026-11-02.

## 배경

`'k%{i}'` 같은 보간은 다음으로 컴파일된다(`cyber compile`).

1. 각 인자를 `to_print_string[T]`로 str로 바꾼다. int면 `to_print_string` → `str.@init[int]` → `Int.fmt` → `int.fmt`
   → 호스트 `int_fmt`로 VM 호출 4번과 할당 1번.
2. 리터럴 조각 `[N+1]str`과 인자 `[N]str`을 스택 배열로 만들어 `str.interpolate(strs, args)`(core.cy 스크립트)를 부른다.
   스크립트는 인자마다 `res += arg; res += strs[i+1]`이라 `concat`이 2N번, 할당도 2N번이고 복사량은 O(N²)다.
   루프 자체도 `Span.next` · `Span.@index_addr` · Option `@destruct` 호출이다.
3. 두 배열을 `@destruct[[N]str]` 호출로 해제한다.

기준(ReleaseSafe, hyperfine wall, 100만 회): 인자 1개 `'k%{i}'` 298 ms, 2개 538 ms, 5개(str 4 + int 1) 905 ms.

## 결정 1: `str.interpolate`를 네이티브로

`#[bind='str.interpolate']`, `src/builtins/string.zig`에 구현. 모든 조각의 길이 합과 ASCII 여부를 먼저 구해
`init_astr_undef` / `init_ustr_undef`로 한 번만 할당하고 차례로 복사한다. 인자가 없으면 `strs[0]`을 retain해서 돌려준다
(스크립트와 같음). 매개변수는 빌린 `[&]str`이라 해제하지 않는다.

## 결정 2: int → str 경로에서 중간 호출 제거

`to_print_string[int]` → `str(x)` → `x.fmt()` → `self.fmt(.dec)` → `int_fmt`는 단계마다 넘기기만 한다. VM에 인라인이 없으므로
(`project_array_index_calls.md`와 같은 이유) `to_print_string`의 int 분기, `str.@init`의 int 분기, `Int.fmt()`가
`int_fmt(x, .dec)`를 직접 부르게 했다.

## 결과 (ReleaseSafe, hyperfine wall, 100만 회, 출력은 바꾸기 전과 같음)

| | 이전 | 네이티브 interpolate | + int 경로 | python3 | lua |
|---|---|---|---|---|---|
| `'k%{i}'` | 298 ms | 145 ms | 123 ms | 230 ms | 152 ms (`'k' .. i`) |
| `'item %{i} of round %{n}'` | 538 ms | 231 ms | 191 ms | 308 ms | – |
| 인자 5개(str 4 + int 1) | 905 ms | 281 ms | 258 ms | – | – |

남은 비용: 반복마다 할당 2번(`int_fmt` 임시 문자열, 결과)과 `@destruct[[N]str]` 호출 2번. 리터럴 조각은 정적 문자열이라
해제할 것이 없지만 배열 destruct가 그것을 모른다. int 인자를 interpolate 안에서 바로 포맷하면 임시 할당 하나가 줄지만
`to_print_string`의 구조를 바꿔야 해서 보류.
