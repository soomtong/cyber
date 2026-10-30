# Zig 0.17 업그레이드에서 정한 것

설계 · 실측 · 릴리즈 노트 체크리스트: `docs/specs/2026-10-25-zig-0.17-upgrade-design.md`.

## 검증 환경

- 호스트(macOS 27)에서 Zig 0.15.2는 build runner가 링크되지 않는다. 0.15.2 기준선은 Linux 컨테이너
  (`debian:stable-slim`, aarch64)에서만 잰다.
- Linux 컨테이너 기준선은 원래 빨갛다. `modules/os.cy:25`(`os.open_dir` InvalidArgument)와 `FFI.`
  (FileNotFound). 비교는 "같은 실패가 같은 자리에서 나는가"로 한다.
- `-Dffi=false`의 `modules/os.cy` 세그폴트는 0.15.2에서도 난다.

## 코드 규칙

- `Io`는 `stdx.io()`에서 얻는다. 환경 변수는 `stdx.getEnvVarOwned`(libc). 인자는 `std/os.zig`의
  `process_args`를 CLI `main`과 테스트 러너의 `test_init`이 채운다.
- extern struct에 std 컨테이너를 흉내 내 넣지 않는다. std 타입은 배치가 정의되지 않고(0.17
  `ArrayList`의 `pointer_stability`), 바뀌면 조용히 깨진다. 필요하면 크기 · 정렬만 맞춘 저장소를 둔다.
- `vm.h`의 `ZVM`/`ZHeap` padding은 Zig `VM`/`Heap`의 `c` offset을 모드별로 잰 값이다. safety를 켜면
  `ArrayList`와 `HashMapUnmanaged`마다 `usize` lock이 붙고 Zig가 필드 순서를 바꾸므로 공식으로 세지 않는다.
  64-bit은 safe 120/536, unsafe 96/432, wasm32 `ZVM`은 220/172. 어긋나면 `vm.zig` · `heap.zig` ·
  `thread.zig`의 comptime 검사가 두 offset을 찍으며 빌드를 멈춘다(모든 모드 · 타깃).
- out 파라미터는 모든 경로에서 쓴다. 최적화 빌드에서 undefined 값에 대한 `std.debug.assert`는 UB라
  주변 코드가 사라진다(`resolveFuncSig`의 `out_generic`). ReleaseFast 테스트로 잡는다.
- extern 타입의 재해석은 `@bitCast` 대신 `.val` 또는 `stdx.reinterpret`(0.17은 extern `@bitCast` 금지).
