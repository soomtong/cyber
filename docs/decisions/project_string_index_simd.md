# 문자열 탐색(`str.index`) SIMD 개선

작성일 2026-11-01.

## 배경

`str.index`(`src/builtins/string.zig` `index`)는 `src/string.zig` `indexOf`를 부르고, 이 함수는 0x80.pl의 SIMD
strstr(첫 바이트와 마지막 바이트를 동시에 거르는 방식)을 쓴다. 벤치 `string/index`는 바늘 `waldo`의 첫 바이트 `w`가
haystack에서 32바이트마다 나오는 입력이라, 첫 바이트로 `memchr`를 돌리는 Lua · V8은 자주 멈추고 Cyber가 4~6배
앞섰다. 공정하게 보려고 첫 바이트가 haystack에 없는 `string/index_rare`(`Waldo`)를 추가하자 Lua · LuaJIT · Luau가
Cyber보다 20~36% 빨랐다.

## 원인

기존 루프는 16바이트(aarch64 NEON)마다 `@bitCast(vec == first)`로 비트마스크를 만들고 `firstMask > 0`으로 분기했다.
aarch64에는 x86의 `pmovmskb` 같은 movemask 명령이 없어서 비트마스크를 만드는 데 여러 명령이 들고, 분기는 첫
바이트가 자주 나오면 예측이 빗나간다.

## 결정

`indexOfSimdFixed`에 8개 벡터(aarch64에서 128바이트)씩 처리하는 두 단계 루프를 앞에 둔다.

1. 각 벡터를 `buf1 ^ first`로 바꾸면 첫 바이트가 맞는 자리만 0이다. 8개를 `@min`으로 합쳐 `@reduce(.Min)`이 0이
   아니면 블록을 건너뛴다. 벡터당 로드 1회라 `memchr`와 같은 비용이다.
2. 후보가 있으면 `(buf1 ^ first) | (buf2 ^ last)`로 마지막 바이트도 맞는 자리만 남기고 다시 한 번 축약 검사한다.
3. 그래도 남으면 그 블록에서만 비트마스크를 만들어 `std.mem.eql`로 확인한다. 벡터 순서와 `@ctz` 순서로 보므로 가장
   앞의 위치를 돌려준다.

남는 꼬리(블록 미만)는 기존 16바이트 루프와 `indexOfSimdRemain`이 처리한다. 경계 가정(`str` 뒤에 `needle.len`
바이트가 더 있음)은 기존과 같다.

## 결과 (Apple Silicon, ReleaseSafe, 스크립트 내부 시간, 50회 탐색)

| | 이전 | 4개 벡터 | 8개 벡터(채택) | Lua `memchr` |
|---|---|---|---|---|
| `index` (`w`가 잦음) | 81 ms | 60 ms | 56 ms | 약 400 ms |
| `index_rare` (`W` 없음) | 57 ms | 36 ms | 33 ms | 약 40 ms |

처음 시도한 한 단계 방식(항상 `buf2`까지 읽고 `(b1 ^ first) | (b2 ^ last)`만 검사)은 `index`를 25% 줄였지만
`index_rare`는 57 → 61 ms로 느려졌다. 벡터당 로드가 2회라 첫 바이트가 드문 입력에서 `memchr`보다 불리하다.

## 검증

- 테스트 "string.indexOf matches std.mem.find."(`src/string.zig`, lib-test에서 실행): 400바이트 버퍼의 모든 위치에 바늘을 두고(벡터 · 블록 경계 포함),
  3글자 알파벳의 무작위 문자열 3000개(후보가 많은 입력)를 `std.mem.find`와 비교한다. 결과에 +1을 넣은 버그를 잡는 것을
  확인했다. 각 입력을 `indexOfSimd`의 벡터 크기 16 · 32 · 64(NEON/SSE · AVX2 · AVX-512)로도 돌려, 이 머신에 없는
  x86 벡터 크기의 루프 논리도 확인한다.
- x86_64 빌드는 컴파일만 확인했다. 이 머신(M1 Max)에 Rosetta가 없어 실행은 못 했다.

## 남은 문제

- 첫 바이트와 마지막 바이트가 함께 자주 맞는 입력(같은 문자 반복 등)은 후보마다 `std.mem.eql`을 부르므로 느려질 수
  있다. 재지 않았다.
