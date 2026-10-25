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
- `vm.h`의 `ZVM`/`ZHeap` padding은 Zig `VM`/`Heap`의 `c` offset을 손으로 맞춘 값이다. Zig 쪽 필드나
  std 타입 크기가 바뀌면 `vm internals.` · `heap internals.` 테스트가 알려 준다.
- extern 타입의 재해석은 `@bitCast` 대신 `.val` 또는 `stdx.reinterpret`(0.17은 extern `@bitCast` 금지).
