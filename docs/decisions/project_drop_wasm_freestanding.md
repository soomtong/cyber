# wasm32-freestanding 빌드를 지원하지 않는다

2026-11-22 결정. 0.4.18 릴리스 직후.

## 결정

- 지원하는 wasm 타깃은 `wasm32-wasi` 하나다. 브라우저도 WASI 호스트(`examples/web-playground/wasi.js`)로 돌린다.
- `wasm32-freestanding` 전용 코드(호스트 import, `std.Io.failing` 분기, `HostFileWriter`, 호스트 시계, freestanding용 `pow` export)는 지웠다.
- `meta.system()`의 `SystemKind.freestanding`도 지웠다. freestanding으로 빌드하면 `system()`의 `@field` 매핑에서 컴파일 오류가 난다. 지원하지 않는다는 표시로 둔다.
- `export_table`(`build.zig`의 wasm lib 설정)은 남긴다. `wasm32-wasi` lib을 JS에서 임베딩하는 경로에 그대로 쓰이고 비용이 없다.
- wasm64(memory64)는 지원하지 않는다. 4GB 넘는 선형 메모리가 필요한 경우가 없고, 포인터가 커지고 런타임 지원이 고르지 않다.

## 이유

- 쓰는 곳이 없었다. 플레이그라운드와 LSP는 WASI 빌드이고, 릴리스 행렬에는 freestanding 작업이 없었다(`cyber-web.wasm` 이름 매핑만 남아 있었다).
- 유지 비용이 났다. Zig 0.16 `std.Io` 이전 뒤 0.4.5부터 0.4.17까지 빌드가 깨진 채로 있었고(F-189, `project_zig_017_upgrade.md`), 소스 곳곳에 `isWasmFreestanding` 분기가 흩어져 있었다.
- freestanding의 장점(WASI shim 없이 작은 호스트 API로 JS에 붙인다)은 WASI 호스트를 직접 두는 것으로 대신할 수 있다. 플레이그라운드의 `wasi.js`가 그 예다.

## 남긴 것

- WASI에도 쓰이는 `isWasm` 분기(allocator, http client, FFI · CLI 끄기, `is32Bit`).
- Zig std os tag를 나열하는 `switch`의 `.freestanding` arm(`stdx.zig`, `std/time.zig`, `lsp/transport.zig`, `app_debug.zig`). 동작에 영향이 없다.
- `src/vm.c`의 libc 의존 제약은 wasi-libc 기준으로 바꿨다.

## 검증

- 네이티브 `zig build test` 통과.
- `zig build build-test -Dtarget=wasm32-wasi`: lib_test, cli_test, trace_test 통과. behavior_test는 wasmtime에서 6/9이고 변경 전 코드도 같다. 실패한 3개는 진단 경로가 `./src` 대신 `/src`로 찍히는 wasmtime preopen 차이다. CI는 wasm3로 돌린다.
- 플레이그라운드용 `cyber.wasm`, `cyber-lsp.wasm`(wasm32-wasi) 빌드와 실행 확인.
