# Zig 0.17 업그레이드에서 정한 것

설계 · 실측 · 릴리즈 노트 체크리스트: `docs/specs/2026-10-25-zig-0.17-upgrade-design.md`.

## 검증 환경

- 호스트(macOS 27)에서 Zig 0.15.2는 build runner가 링크되지 않는다. 0.15.2 기준선은 Linux 컨테이너
  (`debian:stable-slim`, aarch64)에서만 잰다.
- Linux 컨테이너 기준선은 원래 빨갛다. `modules/os.cy:25`(`os.open_dir` InvalidArgument)와 `FFI.`
  (FileNotFound). 비교는 "같은 실패가 같은 자리에서 나는가"로 한다.
- `-Dffi=false`의 `modules/os.cy` 세그폴트는 0.15.2에서도 나던 문제였고 고쳤다(2026-10-31). std의 libc 바인딩은
  `#[extern]`이라 TCC 없이는 실행할 수 없다. FFI가 없으면 extern 호출은 panic으로 끝나고, FFI가 필요한
  테스트는 `test_config.ffi`(build.zig `TestConfig.ffi`)로 거른다.

## 코드 규칙

- C 헤더 번역은 `build.zig`의 `translateC`(translate-c 패키지의 `Translator`)로 한다. `b.addTranslateC`는
  0.17에서 deprecated다. 패키지는 codeberg 주소와 커밋으로 고정한다(ghostty 미러와 해시가 같다).
  `default_init = true`가 없으면 extern struct 필드의 0 기본값이 사라져 `CLBindFunc` 초기화가 깨진다.
  받은 패키지는 `zig-pkg/`(gitignore, CI 캐시 경로)에 풀린다.
- `Io`는 `stdx.io()`에서 얻는다. 환경 변수는 `stdx.getEnvVarOwned`(libc). 인자는 `std/os.zig`의
  `process_args`를 CLI `main`과 테스트 러너의 `test_init`이 채운다.
- extern struct에 std 컨테이너를 흉내 내 넣지 않는다. std 타입은 배치가 정의되지 않고(0.17
  `ArrayList`의 `pointer_stability`), 바뀌면 조용히 깨진다. 필요하면 크기 · 정렬만 맞춘 저장소를 둔다.
- `vm.h`의 `ZVM`/`ZHeap` padding은 Zig `VM`/`Heap`의 `c` offset을 모드별로 잰 값이다. safety를 켜면
  `ArrayList`와 `HashMapUnmanaged`마다 `usize` lock이 붙고 Zig가 필드 순서를 바꾸므로 공식으로 세지 않는다.
  64-bit은 safe 120/536, unsafe 96/432, wasm32 `ZVM`은 220/172. 어긋나면 `vm.zig` · `heap.zig` ·
  `thread.zig`의 comptime 검사가 두 offset을 찍으며 빌드를 멈춘다(모든 모드 · 타깃).
- 읽힐 수 있는 필드와 out 파라미터는 `undefined`로 두지 않는다. 최적화 빌드에서 undefined 값을 읽는 비교나
  `std.debug.assert`는 UB라 결과가 임의로 정해지거나 주변 코드가 사라진다. 실제로 난 두 곳:
  `resolveFuncSig`의 `out_generic`(템플릿 함수 `sig`가 null), `FuncSym.firstFuncSig`(wasm32에서 첫 resolve가
  "same function signature" 중복으로 판정됨, 이제 `?*FuncSig` + `null`).
- CI는 x86_64-linux · aarch64-macos cli job에서 `zig build test -Doptimize=ReleaseFast`를, wasi job에서
  ReleaseFast `build-test`를 돌린다. 크기 단언 테스트는 bare union의 safety tag만큼 모드별 값을 둔다
  (64-bit 8, wasm32 `Local` · `Func` 4).
- extern 타입의 재해석은 `@bitCast` 대신 `.val` 또는 `stdx.reinterpret`(0.17은 extern `@bitCast` 금지).
- Zig 쪽 범용 allocator는 `std.heap.SafeAllocator.init(std.heap.page_allocator, ...)`다(`cli.zig` `gpa`,
  `stdx/heap.zig`). `DebugAllocator`는 deprecated고, 바꿔도 피크 메모리는 Debug +7% · ReleaseFast
  `-Dmalloc=zig` -12%, 시간은 같았다(2026-10-31, `src/test/bench/alloc/alloc.cy`). backing은 메모리를
  재사용하지 않는 page_allocator여야 write-after-free 검출이 된다. 기본 릴리스 CLI는 mimalloc을 쓴다.
