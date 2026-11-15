# 메모리 누수는 테스트 실패다 (2026-11-15)

## 배경

`zig build test`의 출력 끝에 `error(SafeAllocator): leaked [... len: 1 ...]`이 한 건 나오는데도 종료 코드는 0이었다.
누가 보고를 지우고 있었던 것은 아니고, 두 가지가 겹쳤다.

- 커스텀 러너 `src/test_runner.zig`(behavior-test · trace-test가 씀)가 모든 테스트가 끝난 뒤
  `_ = std.testing.allocator_instance.deinit()`로 결과를 버렸다. 보고는 찍히지만 실패로 세지 않았다.
- behavior 케이스 518개가 테스트 함수 `Tests.` 하나 안에서 같은 allocator를 썼다. 보고에 케이스 이름이 없어서, 할당 위치 스택만
  보고는 어느 `.cy` 파일인지 알 수 없었다.

원인 파일은 테스트 526개를 Debug CLI로 하나씩 실행해서 찾았다(`meta/type_size_str_arg_error.cy`, F-153). 이 수정이 다시 깨져도
테스트가 잡지 못하는 상태였다.

## 결정

두 단계로 검사한다.

1. 케이스 단위(`src/test/setup.zig`). `VMrunner`가 케이스마다 자기 `std.heap.SafeAllocator`를 만든다(page allocator 기반,
   테스트 allocator와 같은 종류). `vm_initx`와 `cli.init_cli`가 이것을 쓴다. `VMrunner.deinit()`은 VM을 정리한 뒤 남은 블록
   수를 돌려준다. `eval` · `compile`은 0보다 크면 `leaked N blocks in <경로>`를 찍고 `error.Leaked`로 실패한다. 케이스가 다른
   이유로 이미 실패했으면 그 오류를 그대로 돌려준다. 남은 블록마다 할당 위치는 allocator가 출력한다.
2. 테스트 함수 단위(`src/test_runner.zig`). 테스트 함수마다 `std.testing.allocator_instance`와 `io_instance`를 새로 만들고, 끝나면
   `deinit()`의 누수 수를 본다. 0보다 크면 `<테스트 이름> fail: leaked N blocks`로 실패한다. VM 밖의 하네스 코드
   (`expand_tmpl_macros` 등 `t.alloc`을 쓰는 곳)에서 생긴 누수는 이 단계가 잡는다.

Zig 기본 러너를 쓰는 lib-test · lsp-test · cli-test는 원래 테스트마다 누수를 실패로 처리하므로 바꾸지 않았다.

## 버린 대안

- 끝에 한 번만 검사하고 실패만 시키기: 실패는 되지만 어느 케이스인지 모른다. 케이스 단위 검사가 바로 이 문제를 풀려는 것이다.
- `MemAccount`(`src/mem_account.zig`)로 VM이 쥔 바이트 수만 세기: 더 가볍지만 할당 위치 스택이 없다. 누수를 찾는 데 필요한 건
  위치다.

## 검증

- 현재 코드: `zig build test` 통과(behavior 518/518), 누수 보고 0건. 같은 allocator를 쓰던 때와 비교해 오탐은 없었다.
  wasm32-wasi `behavior_test.wasm`도 `wasmtime --dir .::/`로 480/480 통과(2026-11-15).
- F-153 수정(`f0300aa8`)을 잠시 되돌리면: 함수 단위만 있을 때 `behavior_test.test.Tests. fail: leaked 1 blocks`,
  케이스 단위를 넣은 뒤 `leaked 1 blocks in src/test/meta/type_size_str_arg_error.cy`로 실패, 종료 코드 1.

## 한계와 메모

- behavior 하네스는 첫 실패에서 멈춘다(`failFast`). 누수 하나가 뒤 케이스들을 가린다.
- 케이스 하나만 볼 때는 Debug CLI(`zig build cli` 후 `zig-out/bin/cyber <파일>`)를 쓴다. CLI도 Debug 빌드면 끝에 누수를
  보고한다(`src/cli.zig` `gpa`). behavior 러너에는 파일 필터가 없다.
- wasm 테스트를 wasmtime으로 돌릴 때는 저장소 루트를 `/`로 매핑해야 오류 보고의 경로(`/src/test/...`)가 맞는다.
  `--dir .`로는 `./src/test/...`가 되어 오류 메시지 비교가 전부 실패한다. `docs/build.md`는 wasm3를 예로 든다.
- 실행 시간은 재지 않았다. 할당기 종류가 같아 차이가 작을 것으로 본다.
