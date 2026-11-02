# Map[str] 키 해시를 네이티브로

작성일 2026-11-02.

## 배경

벤치 `src/test/bench/alloc/alloc.cy`(200라운드 × 배열 5000개 append + Map 5000개 삽입)가 약 5.5초 걸렸다. 나눠
재면(ReleaseSafe, 스크립트 내부 시간) 배열 부분 0.84초, 문자열 생성만 0.38초, `Map[str, int]` 삽입 4.4초,
`Map[int, int]` 삽입 0.42초였다. 미리 만든 키로 `Map[str, int]`에 넣어도 4.0초라 문자열 생성이 아니라 해시가 원인이다.

`AutoHash[str]`는 `Wyhash.hash(0, key.span())`를 부르고, `Wyhash`는 core.cy에 Cyber 스크립트로 포팅돼 있다.
`Wyhash(seed)` 생성(48바이트 버퍼 0 채우기 포함), `smallKey`, `final2`, 그 안의 `mix` · `mum` · `rot` · `umul` · `readI32`가
모두 실제 호출이라 짧은 키 한 번에 약 1.5 µs가 든다. `HashMap`은 resize 때 해시를 다시 계산하므로 5000개 삽입에
해시 호출이 약 1.1만 번이다.

## 결정

`Wyhash.hash`에 `#[bind='Wyhash.hash']`를 달고 `src/builtins/core.zig`에 같은 알고리즘을 Zig로 옮긴다.

- core.cy 포팅은 32비트 mum 변형(`WYHASH_32BIT_MUM`, `src/test/core/wyhash.cy` 테스트 벡터)이라 Zig `std.hash.Wyhash`
  (128비트 mum)와 값이 다르다. std를 쓰면 Map 순회 순서가 바뀌므로 스크립트와 같은 32비트 변형을 그대로 옮긴다.
- 스크립트 본문은 지우지 않는다(`str.index`처럼 bind와 본문을 함께 둠). 증분 해시(`update` · `final`)는 그대로 스크립트다.
- 검증: 바꾸기 전 스크립트 구현으로 길이 0~299(48바이트 경계 포함) × 시드 3종 해시 900개를 덤프하고, 바꾼 뒤 값과 비교한다.

## 결과 (Apple M1 Max, ReleaseSafe, 스크립트 내부 시간)

| | 이전 | 이후 |
|---|---|---|
| `Wyhash.hash` 짧은 키 100만 회 | 1522 ms | 27 ms |
| 미리 만든 키로 `Map[str, int]` 100만 삽입 | 4022 ms | 750 ms |
| alloc 벤치 전체 | 약 5500 ms | 1911 ms |

900개 해시 값은 바꾸기 전과 같다. alloc의 나머지는 배열 append + 문자열 보간 약 0.84초, Map 약 1.1초다.
`Map[str]`이 `Map[int]`(0.42초)보다 느린 것은 키 문자열 비교와 참조 카운트 때문으로 보인다(미조사).

## 함께 고친 버그: `HashMap.set` 덮어쓰기

`set`이 기존 키의 값을 바꿀 때도 `len += 1` · `nvac -= 1`을 했다. `m['a'] = 1; m['a'] = 2` 뒤 `size()`가 2였고,
덮어쓰기를 반복하면 `nvac`이 0이 되어 쓸데없이 grow했다(grow가 `len`을 다시 세므로 값이 들쭉날쭉). 이제 새 키일 때만
`len`을 늘리고, `nvac`은 빈 슬롯(meta 0)을 쓸 때만 줄인다. tombstone을 재사용할 때는 줄이지 않는다(`try_remove`가
tombstone을 만들 때 `nvac`을 늘리지 않으므로). 테스트는 `src/test/core/Map.cy` 끝에 추가.

## 남는 것

- `HashMap.resize`가 해시를 다시 계산한다. 해시를 저장하면 재해시 비용이 사라지지만 메모리가 늘어 보류.

## 2단계: `copy_str` opcode

`Map[str]`이 `Map[int]`보다 느린 원인을 바이트코드(`cyber compile`)로 보면, `key K`를 값으로 넘길 때마다
`core.@copy[str]` 호출(안에서 `@copy[?^StrBuffer]`를 또 호출해 retain)과 함수 끝의 `dtor_str`이 붙는다. 새 키 하나 삽입에
`Map.@set_index` → `HashMap.@set_index` → `set`(2회) → `findSetSlot` → `AutoHash`로 str 복사가 약 5번, VM 호출이 약 10번 늘어난다.
해제 쪽은 이미 `dtor_str` 명령이 있으므로 복사 쪽에 짝이 되는 `copy_str dst, src_ptr`를 둔다.

- `bc_gen.zig` `Intrinsic`에 `copy_str` 추가(`gen_intrinsic`이 `u2`라 0~3이 꽉 참). `genAll`에서 `str_t.copy_ctor`가 있으면 표시.
- VM: `src_ptr`의 String 3워드를 읽고 `buf`가 있으면 retain한 뒤 `dst..dst+3`에 쓴다. 결과를 버리는 경우(discard)는 명령을 내지 않는다.
- 기준(ReleaseSafe, hyperfine wall): 미리 만든 키 `Map[str, int]` 100만 삽입 775 ms, `Map[int, int]` 422 ms, alloc 1971 ms.

결과(ReleaseSafe, hyperfine wall 5회): 미리 만든 키 `Map[str, int]` 775 → 493 ms(−36%), alloc 1948 → 1391 ms(−29%).
바이트코드에서 `core.@copy(` 호출이 33곳 → 4곳(str 이외 타입)으로 줄었다. `Map[int]`와의 차이는 약 60 ms만 남는다.
fib · for · heap은 ±2% 안(잡음)이다. `Map[int, int]`만 422 → 430 ms(+2%)로 일관되게 느린데, 이 경로에는 str이 없어
인터프리터 디스패치 루프의 코드 배치가 바뀐 영향으로 추정한다(미확인).

### wasm32에서 드러난 `heap.Span` 버그

wasm32에서는 포인터가 4바이트라 `str`이 16바이트(레지스터 2개)이고 C `String` 구조체와 레이아웃이 같다. 그래서
`COPY_STR`은 `String` 구조체를 그대로 복사한다. 처음에 "str은 항상 64비트 워드 3개"로 가정한 시도는 틀렸다.

`copy_str` 뒤 wasm32 `meta/get_set.cy`가 호스트 함수에서 "integer does not fit"으로 panic했다. 원인은 `copy_str`이
아니라 `heap.Span.items`다. Cyber `[&]T`는 wasm32에서 `{base 4바이트, 패딩 4바이트, length 8바이트}`인데 Zig `Span`은
`ptr: u64`를 `@intCast`로 `usize`로 바꿔서, 패딩에 쓰레기가 있으면 panic한다. `Wyhash.hash(0, k.span())`를 직접
불러도 재현됐다. 레지스터 내용이 바뀌면서 패딩이 우연히 0이 아니게 된 것이다. `@truncate`로 고쳤다(64비트는 동작 같음).
`[&]byte`를 받는 다른 호스트 함수(`str.index_any_byte` 등)도 같은 위험이 있었다.

wasm CLI로 재현하는 법: `zig build cli -Dtarget=wasm32-wasi -Doptimize=ReleaseSafe --prefix <dir>`, `<dir>/bin`에
`zig-out/bin/src`를 복사하고 스크립트도 넣은 뒤 `wasmtime run --dir=<dir>/bin::/ <dir>/bin/cyber.wasm /t.cy`.

## 3단계: HashMap 핫 경로의 호출 줄이기

보간 개선 뒤 alloc(903 ms)에서는 Map이 가장 크다. `Map[int, int]`도 캐시에 들어가는 5000개 Map을 200번 새로 채우면
445 ms(python dict 95 ms)인데, 같은 Map에 덮어쓰기만 하면 130 ms(python 90 ms)다. 차이는 grow(resize)와 생성 · 해제다.
resize는 이전 슬롯마다 `PtrSpan.next` → `@index_addr` 호출 2번, 살아 있는 원소마다 `set` 경로 전체(호출 약 8번, 같은 키 비교
포함)를 다시 타고, 관리 타입이 아니어도 빈 해제 루프로 슬롯을 한 번 더 돈다.

- `resize`: 인덱스 루프로 이전 슬롯을 돌고, 키가 서로 다르고 새 테이블에 tombstone이 없으므로 해시 후 빈 슬롯까지 선형 탐사만
  한다. 원소는 옮긴다(관리 타입은 `@memcpy`로 비트 이동, 아니면 `@ptr_init`). 그래서 copy 후 release하던 해제 루프가 없어진다.
- `set`: `self._keys + slot`(`Ptr.+` 호출)을 `*self._keys[slot]`으로.
- `splitmix64_hash`: `umul` 호출 대신 `r64` 곱셈(부호 없는 MUL). int `*`도 하위 64비트는 같지만 C에서 부호 있는 overflow라 쓰지 않음.
- `Map.@set_index`가 `HashMap.@set_index`를 거치지 않고 `set`을 바로 부름. `grow`의 `2 ** 3`을 `8`로.
- `HashMap.@deinit`의 슬롯 루프를 `#if type.managed(K) or type.managed(V)` 안으로. `AutoHash[int]`에 splitmix 본문을 직접 씀.

결과(ReleaseSafe, hyperfine wall 5회, 5000개 Map × 200회): `Map[int, int]` 새로 채우기 446 → 257 ms(python 95 ms),
`Map[str, int]` 503 → 347 ms, 덮어쓰기만 131 → 116 ms(python 90 ms), alloc 902 → 752 ms. 해시 값과 순회 순서는 같다.
`src/test/core/Map.cy`에 grow 중 관리 키 · 값 이동과 tombstone 제거 테스트를 추가.

## 구조체 해제에서 관리 타입이 아닌 필드 건너뛰기

`@destruct`의 struct 분기가 모든 필드에 `@destruct(field.type, ...)`를 불러, int · 포인터 필드도 nop뿐인 함수를 호출했다
(generator 해제 한 번에 빈 호출 7번). `#if type.managed(field.type)`로 감쌌다. `managed`는 `has_managed_child or
has_user_deinit`이라 `@deinit`가 있는 타입은 그대로 불린다. fiber 벤치 43.3 → 39.1 ms, 나머지 벤치 변화 없음.
