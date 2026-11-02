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

## 남는 것

- `HashMap.resize`가 해시를 다시 계산한다. 해시를 저장하면 재해시 비용이 사라지지만 메모리가 늘어 보류.
- `HashMap.set`이 기존 키를 덮어쓸 때도 `len += 1` · `nvac -= 1`을 한다(별도 수정).
