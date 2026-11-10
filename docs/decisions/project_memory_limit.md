# VM 메모리 한도와 `OutOfMemory` panic (2026-11-10)

상태: 구현됨. 발견 이슈 F-41의 메모리 한도 부분. C 친화 할당자 훅은 `project_c_mem_funcs.md`.

## 배경

VM의 메모리 사용에는 상한이 없었다. `Array`에 계속 `append`하는 스크립트 하나가 호스트의 메모리를 소진할 수 있고,
호스트가 할 수 있는 것은 `cl_vm_initx`에 실패하는 할당자를 넘기는 것뿐이었다. 그런데 할당 실패는 정의된 동작이 아니었다.
퍼즈(lib 테스트에 임시로 넣은 `ProbeAlloc`: Array · Map · 문자열 · `^Node` 리스트를 600번 키우는 스크립트 하나의 eval에서
N번째 할당 한 번만 실패시킴, N = 1..8600)의 결과는 다음과 같다.

- 5419회는 컴파일 오류(`CompileError: OutOfMemory`), 36회는 `panic: OutOfMemory`, 1506회는 성공(실패를 삼키는 지점)으로
  돌아왔다. 돌아온 것 가운데 1156회는 누수가 있었다(`errdefer` 없는 중간 할당).
- 1638회는 프로세스가 죽었다. 런타임 구간(N 7323 이상)의 `Unfreed raw buffers: 4`(638회)와 `freeHeapPages`의
  `incorrect alignment`(600회)가 대부분이고, 나머지는 컴파일 구간이다: `Unfreed raw buffers: 1`(81회),
  `deinit_func_ct_values`의 union 필드 오접근(68회), `types.createType`의 오류 경로(약 100회) 등.

즉 "할당자가 거부하면 VM이 오류를 돌려준다"는 모델은 컴파일러와 런타임의 할당 지점 수백 곳을 모두 고쳐야 성립한다.
스택 상한(F-40, `project_stack_limit.md`)이 재귀를 막은 뒤에도 힙이 남은 경로였다.

## 결정

1. 한도는 할당자가 아니라 지점에서 검사한다. VM은 호스트 할당자 위에 계수 래퍼 `MemAccount`(`src/mem_account.zig`)를 두고
   모든 할당을 세지만, 래퍼는 요청을 거부하지 않는다. 한도 검사는 깨끗한 panic으로 끝낼 수 있는 곳, 곧 스크립트가 힙이나
   스택을 키우는 곳에만 둔다.
   - 스레드 힙: `Heap.growHeapPages`(풀 객체), `allocBigObject`(큰 객체), `new_byte_buffer`(Array · Map · 문자열 버퍼).
   - 스택: `Thread.growStackAuto` · `growStackPrecise`.
2. 한도에 걸린 성장은 `panic: OutOfMemory`다. eval은 `CL_ERROR_PANIC`을 돌려주고 VM은 계속 쓸 수 있다. 호스트 함수가
   `error.OutOfMemory`를 돌려줄 때 이미 나오던 panic과 같은 메시지다. 인터프리터가 직접 부르는 할당 콜백
   (`zAllocPoolObject` · `zAllocBigObject` · `zAllocClosure` · `zAllocFuncUnion` · `z_ret_generator`)은 `RES_UNKNOWN` 대신
   `allocFailed`로 같은 panic을 낸다.
3. 한도는 VM 전체 바이트 기준이다. 컴파일러 · 로드된 모듈(첫 eval 뒤 약 1.8~1.9 MB, eval마다 15~70 KB 누적) · 힙 · 스택을
   모두 포함한다. 스크립트에 N 바이트를 주려는 호스트는 `cl_vm_memory_used(vm) + N`으로 정한다. 힙만 따로 세지 않은 이유:
   호스트가 지키려는 것은 프로세스 메모리이고, 스폰 스레드마다 힙이 따로 있어 "힙 하나의 크기"는 그 답이 아니다.
4. 컴파일 단계는 세기만 하고 막지 않는다. 컴파일러의 comptime 힙(`Heap.c.thread == null`)과 sema · 코드 생성의 할당은
   한도를 넘을 수 있고, 넘은 만큼은 다음 힙 성장에서 보인다. 한도가 현재 사용량보다 낮아도 스크립트는 컴파일되고 첫
   할당까지 실행된다. 컴파일 단계 메모리는 소스 크기에 비례하므로 호스트가 소스 길이로 제한할 수 있다.
5. panic 뒤에 메모리를 돌려준다. 그렇지 않으면 한도까지 자란 힙 · 스택이 다음 eval의 여유를 모두 차지한다.
   - `thread.panic`: `freeHeapPages` 뒤 `Heap.releaseFreePages`가 첫 페이지만 남기고 반환, `compact_trace.clearAndFree`
     (언와인드한 프레임당 한 항목, 깊은 재귀에서 약 1 MB).
   - `vm.eval`: `error.Panic` · `error.Interrupted`로 끝난 main 스레드의 스택을 `Thread.resetStack`이 처음 크기(511슬롯)로
     줄인다. `thread.panic`이 아니라 eval에 둔 이유: `callFunc2`의 안쪽 실행이 panic하면 `thread.panic`이 바깥 프레임이
     살아 있는 채로 한 번 돈다.
6. 호스트 API: `cl_vm_set_memory_limit(vm, bytes)`(0 이하는 무제한, 기본값), `cl_vm_memory_used(vm)`.
   `cl_vm_allocator`가 돌려주는 것은 이제 계수 래퍼다. 거기서 받은 메모리는 호스트 할당자가 아니라 같은 할당자로 돌려줘야 한다.

## 구현 메모

- `VM`(Zig) 구조체 크기는 `vm.h` `ZVM` 패딩에 묶여 있어 필드를 늘리지 않았다. `MemAccount`는 `VM.init`이 호스트 할당자로
  따로 할당하고 `VM.deinit`이 해제한다. 래퍼인지 여부는 `alloc.vtable == &MemAccount.vtable`로 본다(`MemAccount.of`).
  스폰 스레드는 `vm.alloc`을 받으므로 같은 계정을 쓴다. `used` · `limit`은 atomic이다.
- `growHeapPages`는 요청한 페이지 수를 남은 여유에 맞춰 줄인다. 한 페이지도 안 들어가면 `error.OutOfMemory`. 페이지 수를
  두 배씩 늘리는 성장이 한도 근처에서 여유의 절반을 버리지 않게 하기 위해서다.
- `allocBigObject`는 포인터 객체를 잡기 전에 `reserve`하고, 본체 할당이 실패하면 포인터 객체를 풀에 돌려준다(그대로 두면
  panic 뒤 스윕이 가리키는 곳 없는 포인터를 따라간다). `new_byte_buffer` · `init_eval_str_undef`에는 `errdefer`.
- non-trace 빌드는 failable 명령에만 디버그 심볼을 만든다. `.new` · `.closure` · `.fn_union`이 optional이라 그 pc에서 난
  panic이 `error.NoDebugSym` → `CL_ERROR_UNKNOWN`이 되고 `unwinding`이 true로 남아 다음 panic에서 abort했다. 세 명령을
  `pushFCode` · `pushFCodeExt`(신규)로 바꿨다.
- 스택은 resize가 안 되면 새 블록으로 복사하므로 옛 스택과 새 스택을 같이 쥔다. `growStackPrecise`가 복사 전에 새 크기 전체가
  들어가는지 본다. 그래서 스택은 여유의 약 40%까지만 자란다.
- 스폰 스레드의 panic은 `worker.zig`가 메시지를 await 쪽에 넘긴다: `panic: Spawned thread panicked: OutOfMemory`.

## 한계

- Trace(Debug) 빌드는 `objectTraceMap`이 객체마다 기록을 남겨 panic 뒤에도 `used`가 돌아오지 않는다. 개발 진단용이라 두었다.
  한도를 계속 쓰려면 panic 뒤 `cl_vm_memory_used` 기준으로 다시 정한다.
- panic 기록(스택 트레이스 · compact trace)과 호스트 함수가 직접 하는 할당은 한도를 넘을 수 있다. 측정한 초과는 여유의
  절반 이하(lib 테스트가 `peak < limit + room/2`를 검사).
- `fits`와 실제 할당은 원자적이지 않다. 스폰 스레드 여럿이 동시에 자라면 한 번의 성장 크기만큼 넘을 수 있다.
- eval은 재진입하지 않는다고 가정한다(호스트가 스크립트 함수를 부르는 공개 API가 없다).
- 한도 없이 호스트 할당자가 실제로 실패하는 경우(진짜 OOM)는 실행 중에는 같은 panic이 된다(아래 검증의 재퍼즈).
  이 문서를 쓴 시점에는 컴파일 단계가 이전과 같았고(위 퍼즈의 크래시 · 누수) Trace 빌드는 실행 중에도 `traceAlloc`이 `fatal`로
  죽을 수 있었다. 둘 다 같은 날 뒤이은 작업에서 고쳤다(`project_compile_alloc_failure.md`).

## 검증

- lib-test `cl_vm_set_memory_limit turns runaway allocation into a panic.`: 여유 4 MiB에서 `Array[int]` append, `Map[int, int]`,
  문자열 두 배 늘리기, `Array[str]`, `^Node` 리스트, 6필드 `^Big` 리스트, `f(n + 1) + 1` 재귀가 모두 `panic: OutOfMemory`.
  호스트 할당자의 peak가 `limit + room/2` 아래, panic 뒤 `used`가 처음 + 256 KiB 아래, 한도를 유지한 채 다음 eval 성공,
  한도 1에서 할당 없는 스크립트는 성공, 0과 -1은 무제한.
- lib-test `cl_vm_set_memory_limit covers spawned threads.`: 스폰 스레드의 폭주 append가 await 쪽에서 panic.
- `MemAccount counts what its allocator holds.`
- Debug · `-Dtrace=false` · ReleaseSafe · ReleaseFast에서 통과, 누수 검사 할당자 누수 없음.
- 같은 퍼즈를 수정 뒤 런타임 구간(N 8611~9937, 1327회)에 다시 돌렸다. 한도와 무관하게 호스트 할당자가 한 번 실패하는 경우다.
  1250회 `panic: OutOfMemory`, 67회 성공(resize 실패 뒤 다른 경로), 누수 0. 죽은 10회는 모두 Trace 빌드 전용
  `traceAlloc`의 `fatal`(`objectTraceMap` 기록 실패)이다. 수정 전 런타임 구간은 1238회가 죽었다(`Unfreed raw buffers: 4` · `freeHeapPages`의
  `incorrect alignment`). 어느 변경이 어느 크래시를 없앴는지는 따로 가르지 않았다: 이 경로에 닿는 변경은 할당 콜백의
  `RES_UNKNOWN` → panic, `allocBigObject`의 포인터 객체 반환, 버퍼 `errdefer`다. 컴파일 구간(N 7000~8610)의 크래시 · 누수는 그대로다.
- 13단계 검증(네이티브 test 4모드, lib-test 2모드, lib-standalone, wasm32 4개) 통과.
- 래퍼 비용(ReleaseFast CLI, hyperfine 20~30회, 수정 전 `f45be740`과 A/B): alloc 489.5 → 487.0 ms, heap 29.6 → 29.5 ms,
  for 35.2 → 35.0 ms, fib 28.2 → 27.9 ms, string index 68.3 → 68~69 ms는 잡음 안. fiber만 24.2 → 25.0 ms(+3%)로 일관되게 느리다:
  제너레이터 10만 개의 프레임 할당 · 해제마다 간접 호출과 원자 덧셈이 한 번씩 든다(호출당 약 4 ns).

## 남은 것

- C 친화 할당자 훅은 같은 날 `cl_vm_init_mem`으로 더했다(`project_c_mem_funcs.md`).
- CLI 옵션(`cyber --memory-limit`)은 없다.
- 컴파일 단계의 할당 실패 처리(퍼즈의 크래시 · 누수)는 같은 날 뒤이어 했다(`project_compile_alloc_failure.md`).
