# Slice.append의 버퍼 공유와 누수

2026-11-01, `src/tools/bench.cy`를 고치다 발견했다. 같은 날 후보 1(버퍼에 초기화된 원소 수)로 고쳤다. 아래 "결정" 참고.

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

## 다른 언어 (2026-11-01 조사)

- Swift `Array`: 길이(count)가 값이 아니라 공유 버퍼 헤더(`_ArrayBody`)에 있고, 저장소 deinit은
  `deinitialize(count: countAndCapacity.count)`로 버퍼의 count만큼 해제한다. 그래서 한 버퍼를 길이가 다른 두 값이 나눠
  가질 수 없다(부분 보기는 범위를 따로 가진 `ArraySlice`). 변경은 `mutating`이라 변경되는 변수 자신의 유일성을 검사하고
  (`isUniquelyReferenced() && capacity >= minimumCapacity`일 때만 제자리), `+`처럼 값을 돌려주는 연산은 새 배열을 만든다.
- Lean 4 · Koka(Perceus): `Array.push : Array α → α → Array α`는 함수형 시그니처지만 참조 카운트가 1이면 제자리에서 바꾼다.
  인자는 소유(owned)로 넘어가고, 호출 뒤에도 쓰이는 값이면 컴파일러가 호출 전에 카운트를 올려 복사가 일어난다.
  저자들은 빌린 참조는 RC = 1이어도 제자리 갱신이 안전하지 않다고 명시한다. Cyber의 `clone_on_resize`가 바로 빌린
  `&Slice` 수신자에서 `@isUniqueRef`를 보고 `self.*`를 돌려주는 경우다.
- Go: `append`가 용량이 남으면 원래 배열을 공유하고 길이만 다른 헤더를 돌려준다(Cyber와 같은 구조). GC라 누수 대신
  의미상 별칭(덮어쓰기)과 길이 밖 원소의 수명 연장이 문제가 됐고, Go 1.22는 `slices.Delete` 등이 길이 밖으로 밀려난
  원소를 0으로 지우게 바꿨다. 반환값을 버리고 원래 슬라이스를 쓰는 것은 여전히 잘못된 사용으로 본다.
- Rust `Vec::push(&mut self)`: 배타적 빌림으로 제자리 변경만 한다. 별칭이 타입 수준에서 막힌다. Cyber의 `Array[T]`
  (`&&` 수신자)와 같은 자리다. 공유 + COW가 필요하면 소유한 `Rc`에 `Rc::make_mut`를 쓴다.
- Python `list`: `append`는 제자리, `a + b`는 항상 새 리스트. 빠른 경로와 값 연산이 분리돼 있다.

정리하면 해제 정확성을 지키는 방법은 두 가지다. 길이를 버퍼 쪽에 두거나(Swift, 후보 1과 같은 방향), 제자리 갱신을 소유한
값이나 변경되는 변수 자신에게만 허용한다(Lean · Koka · Swift `mutating`, 후보 2와 같은 방향). Go만 Cyber와 같은 구조인데
GC라서 누수로 드러나지 않는다.

출처: Swift `stdlib/public/core/ArrayBody.swift` · `ContiguousArrayBuffer.swift`, Ullrich · de Moura "Counting Immutable
Beans"(IFL 2019) 및 Lean 발표 자료, Reinking 외 "Perceus"(PLDI 2021), Go Blog "Robust generic functions on slices"(2024-02).

## 해석

`append` · `+` · `insert` 등 `clone_on_resize`를 거치는 연산은 "받는 쪽을 결과로 덮어쓴다"를 전제한 설계로 보인다.
언어 차원에서 이 전제를 강제하지 않으므로 사용자 코드가 쉽게 어긴다. 후보는 다음과 같다.

1. 버퍼에 초기화된 원소 수(최고 수위)를 두고 `@deinit`이 그 수까지 해제한다. `size_down` · `clear`가 이 수를 함께
   갱신해야 한다.
2. 유일 참조여도 `self`가 지역 변수로 계속 살아 있으면 복사한다. 컴파일러가 "마지막 사용"을 알아야 한다.
3. 빠른 경로를 없애 항상 새 버퍼를 만든다. 반복 append가 O(n^2)가 되어 받아들이기 어렵다.

## 고치기 전의 우회

받는 쪽을 덮어쓴다(`args = args + cmd`). 수정 뒤에는 필요 없다.

## 결정 (2026-11-01)

후보 1을 택했다. Swift처럼 해제 정확성을 버퍼에 맡기고, 의미(별칭) 문제는 남긴다. 후보 2는 컴파일러의 마지막 사용 분석이
필요해 따로 검토한다.

- Slice 버퍼(`RawBuffer[byte]`)의 데이터 앞 8바이트에 초기화된 원소 수(count)를 둔다. 원소는 그 뒤에서 시작한다.
  `length`는 이 8바이트를 포함한 바이트 수라 `@size`와 해제 크기는 그대로 맞는다.
- 버퍼를 만드는 곳(`new_slice_buffer`, Zig `init_slice_undef`)이 count를 쓴다. 크기를 바꾸는 연산(`append` · `insert` ·
  `remove` · `size_down` · `size_up`)은 끝에서 count를 결과 길이로 맞춘다.
- `Slice.@deinit`은 버퍼가 유일 참조일 때 count만큼 해제한다. 부분 슬라이스의 `header`에 든 부모 길이는 해제에 더는 쓰지 않는다.
- `clone_on_resize`의 빠른 경로는 버퍼가 유일하므로 이 보기의 길이 뒤에 남은 초기화 원소(앞서 버퍼를 공유하던 결과가
  붙이고 사라진 것)를 먼저 해제하고 count를 줄인 뒤 재사용한다.
- 남는 것: 크기를 줄이는 연산 뒤 원래 슬라이스를 계속 읽으면 이미 해제된 칸을 볼 수 있다(예: `b := a.size_down(0)` 뒤
  `a[0]`). Go와 같은 "반환값을 받은 뒤 원래 슬라이스는 쓰지 않는다" 규칙이 여전히 필요하다.
- 구현: `src/builtins/core.cy`의 `new_slice_buffer` · `slice_buffer_count` · `slice_buffer_elems`, Zig `heap.zig`의
  `new_slice_buffer` · `init_slice_undef`(`SliceBufferElemsOffset = 8`). 크기 변경 연산은 함수 호출 없이
  `(as[Ptr[int]] ((as[int] res.ptr) - 8)).* = res._len`으로 count를 쓴다(`clone_on_resize` 결과는 부분 슬라이스가 아니라 `ptr`가 원소 시작).
- 성능(ReleaseFast, `src/tools/bench.cy` 50회 평균): count 기록을 `#if type.managed(T)`로 감싸 `[]int` append 200만 회는
  361 → 358 ms로 차이가 없다. `[]str` append 100만 회는 386 → 400 ms(+3.6%). 처음 `sync_count()` 메서드 호출로 쓴 버전은
  `[]int`까지 +8.8%였다(인터프리터의 호출 비용).
- 함께 드러난 문제: 고치기 전에는 `remove` · `insert`도 같은 빠른 경로를 써서, 원래 슬라이스를 남기면 이중 해제가 났다
  (새 테스트를 옛 코드로 돌리면 `Double free`). 또 `size_down`이 관리 원소에서 없는 메서드 `PtrSpan.destruct()`를 불러
  `[]str.size_down`이 컴파일조차 되지 않았다. 원소별 `@destruct` 루프로 고쳤다.
- 회귀 테스트: `src/test/memory/slice_shared_buffer.cy`(append · `+` · remove · insert · size_down · size_up을 받는 쪽을
  남긴 채 호출, 버퍼 재사용, 부분 슬라이스).
- wasm32 사고(2026-11-01): 처음에는 count를 음수 인덱스 `(as[Ptr[int]] res.ptr)[-1]`로 썼는데, push 뒤 Latest Build의
  `wasm32-wasi` 잡이 `core/Slice.cy`에서 "remap of invalid memory ... canary"로 죽었다(run 41253320696, 다른 11개 잡은 성공,
  `latest` 릴리스는 갱신되지 않음). 로컬에서 `zig build build-test -Dtarget=wasm32-wasi -Doptimize=ReleaseSafe` 뒤
  `wasmtime run --dir=.::/ zig-out/bin/behavior_test.wasm`으로 재현했다. 슬라이스를 쓰지 않는 프로그램도 실패해 `core.cy`를
  컴파일하는 단계에서 손상이 생긴다. 음수 인덱스를 정수 주소 계산 `(as[int] ptr) - 8`로 바꾸자 통과했다. `sema_ptr_index`는
  포인터를 `i64`로 비트캐스트해 `idx * 크기`를 더하는데, 32비트에서 음수 상수 인덱스를 어디서 잘못 다루는지는 추적하지
  않았다. 64비트 macOS 테스트는 해제된 메모리를 재사용하지 않는 allocator라 드러나지 않은 것으로 본다.

