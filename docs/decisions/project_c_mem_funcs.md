# C 호스트용 메모리 함수 훅 `cl_vm_init_mem` (2026-11-10)

상태: 구현됨. 발견 이슈 F-41의 나머지 절반. 메모리 한도는 `project_memory_limit.md`.

## 배경

VM의 할당자를 바꾸는 길은 `cl_vm_initx(CLAllocator)` 하나였다. `CLAllocator`는 Zig `std.mem.Allocator`와 같은 배치
(`ptr` + `vtable`)이고 vtable의 네 함수는 Zig 호출 규약(`alloc(ctx, len, alignment, ret_addr)`, 슬라이스 값을 받는
`resize` · `remap` · `free`)이라 C 호스트가 채울 수 없다. 그래서 C 호스트는 `cl_vm_init`의 `malloc`밖에 쓸 수 없었고,
VM의 메모리를 자기 아레나 · 풀 · 계수기로 돌릴 방법이 없었다.

메모리 상한 자체는 `cl_vm_set_memory_limit`(`b7fdf554`)이 해결했다. 이 훅은 상한이 아니라 "VM의 메모리를 호스트가 쥔다"는
쪽이다: 호스트의 할당자로 보내기, 호스트 쪽 통계에 넣기, VM을 버릴 때 아레나째 비우기.

## 결정

1. 함수 둘과 문맥 포인터 하나를 담는 `CLMemFuncs`와 `cl_vm_init_mem(CLMemFuncs)`를 더한다.

   ```c
   typedef struct CLMemFuncs {
       void* ctx;
       void* (*alloc)(void* ctx, size_t size, size_t align);
       void (*free)(void* ctx, void* ptr, size_t size, size_t align);
   } CLMemFuncs;
   ```

2. `free`는 할당 때의 `size`와 `align`을 그대로 받는다. Zig 할당자 인터페이스가 이미 그 둘을 쥐고 있으므로 비용이 없고,
   호스트는 블록 머리에 크기를 따로 적지 않고도 계수 · 크기별 풀을 만들 수 있다.
3. `realloc`에 해당하는 함수는 두지 않는다. vtable의 `resize`는 `false`, `remap`은 `null`을 돌려주고 Zig 쪽이
   새 블록 할당 + 복사 + 해제로 처리한다. 함수 둘이면 호스트가 틀릴 곳이 적다. 큰 버퍼의 제자리 성장이 필요해지면
   그때 선택 필드로 더한다.
4. `align`은 2의 거듭제곱이고 계약상 `malloc`이 보장하는 정렬보다 클 수 있다. 호스트가 맞춰야 한다. 지금 VM이 실제로 요청하는
   최대 정렬은 8이다(arm64 macOS, lib 테스트에서 측정). `size`는 0이 아니다.
5. 두 함수는 스레드에 안전해야 한다. `spawn`한 스레드가 같은 할당자로 동시에 할당한다.
6. `alloc`이 `NULL`을 돌려주는 것은 `cl_vm_initx`에 실패하는 할당자를 넘긴 것과 같다. 런타임의 힙 · 스택 성장에서는
   `panic: OutOfMemory`가 되지만 컴파일 단계에서는 정의된 동작이 아니다(`project_memory_limit.md`의 퍼즈). 스크립트의
   메모리를 묶는 수단은 `cl_vm_set_memory_limit`이고, 헤더에 그렇게 적는다.
   갱신(같은 날): eval 중의 `NULL`은 이제 컴파일 단계에서도 그 eval의 오류다(`project_compile_alloc_failure.md`). 컴파일이
   메모리 부족으로 끝나면 세션이 reset되므로 상한의 수단은 여전히 `cl_vm_set_memory_limit`이다.
7. VM을 만들 때의 할당 실패는 `cl_vm_init` · `cl_vm_initx`와 같이 `fatal`이다.

## 구현 메모

- `src/lib.zig`의 `HostMem`: `CLMemFuncs`를 쥔 구조체 하나가 `std.mem.Allocator`의 `ptr`이 된다. 구조체 자신도 호스트의
  `alloc`으로 받고 `cl_vm_deinit`이 vtable 비교(`HostMem.of`)로 알아보고 호스트의 `free`로 돌려준다. 호스트 쪽에서 보면
  `cl_vm_deinit` 뒤에 남는 블록이 없다.
- 계수 래퍼(`MemAccount`)는 그대로 그 위에 올라간다. `cl_vm_memory_used` · `cl_vm_set_memory_limit`은 어느 init으로 만든
  VM에서도 같다.
- `cl_vm_allocator`가 돌려주는 `CLAllocator`는 여전히 Zig 모양이다. C 호스트는 `cl_vm_alloc` · `cl_vm_free`를 쓴다.

## 검증

- lib 테스트 `cl_vm_init_mem runs a VM on the C memory functions of a host.`: 크기 · 정렬을 검사하는 테스트 할당자 위에서
  eval, 한도 panic, deinit 뒤 남은 블록 0.
- `examples/libcyber/host_tool.c`: `malloc` 위의 정렬 · 계수 함수로 VM을 만들고, 한도 턴(`panic: OutOfMemory` 뒤 재사용)과
  `cl_vm_deinit` 뒤 호스트 계수 0을 확인한다. `zig build lib-standalone-test`가 실행한다.

## 남은 것

- 제자리 성장(`realloc`) 훅.
- `alloc`의 `NULL`을 컴파일 단계에서도 깨끗한 오류로 만드는 일은 했다(`project_compile_alloc_failure.md`). VM을 만드는 중의
  `NULL`(결정 7)과 값 생성 API의 `fatal`은 남았다.
