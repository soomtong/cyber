# C API의 할당 실패: VM 생성과 값 생성 (2026-11-26)

상태: 구현됨. 사용자 위임("결정은 위임합니다") 아래 정했다. `project_compile_alloc_failure.md` 결정 10과
`project_c_mem_funcs.md` 결정 7이 남긴 것이다.

## 배경

eval 안의 할당 실패는 그 eval의 오류가 됐지만(`project_compile_alloc_failure.md`), 두 구간은 여전히 `fatal`로 프로세스를 끝냈다.

- VM을 만드는 함수(`cl_vm_init` · `cl_vm_initx` · `cl_vm_init_mem`). 시그니처가 `CLVM*`를 돌려주는데 실패를 알릴 길이 없었다.
  `VM.init`에는 실패 경로도 없어서, 오류를 돌려주게만 고쳐도 지은 것이 샜다(lib 테스트로 재면 491건).
- 호스트 함수가 값을 만드는 함수(`cl_str_init` · `cl_astr_init` · `cl_ustr_init` · `cl_slice_init` · `cl_new_func_union` ·
  `cl_lift` · `cl_array_empty` · `cl_map_empty`)와 VM 수준의 몇 함수(`cl_vm_alloc` · `cl_vm_allocb` ·
  `cl_vm_ensure_func_sig` · `cl_symbol` · `cl_error` · `cl_object_string` · `cl_value_desc` · `cl_vm_resolve`). 몇은
  `@panic("error")`였다. `cl_vm_resolve`는 할당이 아니라 해석 실패(없는 모듈)에도 `fatal`이었다.

다른 임베딩 런타임의 방식:

- Lua: `lua_newstate`는 `NULL`. 값을 만드는 `lua_pushstring` 등은 `LUA_ERRMEM` 오류를 `longjmp`로 던진다(호스트는 확인하지 않는다).
- Python C API: 값을 만드는 함수가 `NULL`을 돌려주고 스레드의 오류 표시에 `MemoryError`를 둔다. 호스트가 매번 확인해 `NULL`을 위로 돌려준다.
- QuickJS: `JS_NewRuntime`은 `NULL`, 값은 `JS_EXCEPTION` 표지 값. 호스트가 확인한다.
- wasmtime C API: 생성 함수가 `NULL`.

## 결정

1. VM을 만드는 세 함수는 할당이 실패하면 `NULL`을 돌려준다. 그때까지 받은 블록은 모두 돌려준다(`cl_vm_init_mem`은 호스트 함수로
   받은 `HostMem`까지). 호스트가 `NULL`을 확인한다. Lua · QuickJS · wasmtime과 같다.
2. 호스트 함수 안에서 값을 만드는 함수는 실패하면 빈 문자열 · 빈 slice · 값 0을 돌려주고 스레드에 표시(`ThreadC.host_alloc_failed`)를
   남긴다. 호스트 함수가 돌아오면 VM이 표시를 보고 그 호출을 `panic: OutOfMemory`로 끝낸다. 호스트가 무엇을 돌려줬든 같다. 호스트가
   `cl_thread_ret_panic`으로 직접 낸 panic은 그대로 둔다.
   - C 호스트에는 `longjmp`로 풀 길이 없어 Lua 방식은 안 된다. Python 방식(호스트가 매번 확인)은 확인을 빠뜨린 호스트가 빈 값을
     스크립트에 넘긴다. 표시를 VM이 보면 확인하지 않는 호스트도 안전하게 끝난다.
   - 호스트가 지킬 것: 실패한 값은 쓰지 않고 다른 값에 담지 않는다(값 0을 배열에 넣으면 나중에 해제에서 죽는다). 가능한 한 빨리 돌아온다.
     확인하고 싶은 호스트는 빈 값 대신 직접 panic을 낼 수 있지만 지금은 확인 함수를 따로 두지 않았다(빈 문자열은 정상 결과와 구분되지 않는다).
   - 표시는 호스트 호출을 부르는 여섯 자리(`vm.c`의 `CALL_HOST`, `Thread`의 함수 값 · 함수 포인터 · trait · union 호출)가 본다.
     `vm.c`는 표시가 켜졌을 때만 `zHostCallResult`를 부른다(평소 비용은 읽기 하나와 분기 하나).
3. VM 수준 함수: `cl_vm_alloc`은 `NULL`, `cl_vm_allocb` · `cl_object_string` · `cl_value_desc` · `cl_vm_resolve`는 null
   문자열, `cl_vm_ensure_func_sig`는 `NULL`, `cl_symbol` · `cl_error`는 -1(헤더가 이미 `int64_t`였다).
4. `cy.eval`이 만드는 새 VM(`UserVM_init`)은 생성 실패가 스크립트의 `OutOfMemory` panic이다.
5. 깨지는 변경: Zig 쪽 export의 반환 타입이 `?*VM` · `?*anyopaque` · `?*FuncSig` · `i64`로 바뀌었다. C 헤더의 선언은 그대로다(포인터는
   원래 `NULL`이 될 수 있는 타입이다). 확인하지 않고 쓰던 C 호스트는 할당 실패에서 abort 대신 `NULL` 역참조가 된다. 예제
   `examples/libcyber/*.c`에 확인을 넣었다.

## 구현 메모

- `VM.init`: 메인 스레드와 `data`("builtins", "cleanups")가 생기기 전에는 단계마다 `errdefer`로 되돌리고, 그 뒤(`whole`)에는
  `deinit(false)`가 나머지(`bindCore`가 만든 심볼 등)를 정리한다. 앞의 `errdefer`는 `whole`이면 건너뛴다.
- `Compiler.init`: `Heap` · `Sema`를 먼저 지역에 받고 `errdefer`, `createModuleUnmanaged`는 uri의 소유가 chunk로 넘어가는 지점을
  플래그로 가른다. `Thread.init` · `Heap.init`(`heapPages` 목록)에도 `errdefer`.
- `Sema.ensureSymbol`: `getOrPut` 뒤 실패하면 키를 지우고(전에는 키가 호출자의 버퍼를 가리킨 채 남았다), 목록 자리를 먼저 잡는다.
- `ThreadC.host_alloc_failed`는 `panic_type` 뒤의 패딩 자리라 구조체 크기는 그대로다(`vm.h`와 `thread.zig`의 배치 테스트).

## 검증

- lib 테스트 `A VM that can not be created returns null and leaves nothing allocated.`: `cl_vm_initx`의 할당을 1번부터 하나씩
  실패시키고(한 번, 그리고 그 뒤 전부), `NULL`이면 누수 없음, 아니면 eval이 돈다. 누수 검사 할당자 위에서.
- lib 테스트 `cl_vm_init_mem returns null when the host runs out of memory, and the host gets every block back.`: 호스트 함수가 N번째부터
  `NULL`을 돌려줄 때 남은 블록 0.
- lib 테스트 `A value that a host function can not create ends the call with an OutOfMemory panic.`: `cl_str_init` · `cl_slice_init`이
  실패하는 호스트 함수(직접 호출, 함수 값 호출), 직접 panic을 내는 호스트 함수. 요약이 'panic: OutOfMemory' 또는 호스트의 문구,
  다음 eval은 성공.

## 남은 것

- (2026-11-26 해결, 아래 "`cl_vm_reset`과 `clReportApiError`") `cl_vm_reset` · `clReportApiError`의 `fatal`.
- `runtime.zig` · `string.zig` 등 런타임 안쪽의 `catch fatal()`(`project_compile_alloc_failure.md` "한계"의 목록).
- 값 생성 실패를 호스트가 바로 아는 확인 함수(필요해지면 `cl_thread_alloc_failed`).

## `cl_vm_reset`과 `clReportApiError` (2026-11-26)

남은 것의 첫 줄. 둘 다 반환값이 `void`라 시그니처를 바꾸지 않고 닫았다.

- `cl_vm_reset`: `resetVM`에서 실패할 수 있는 것은 옛 상태를 다 놓은 뒤의 `bindCore`(sema 심볼 등록)뿐이다. 실패하면
  `Compiler.alloc_failed`를 켜 둔다. 그러면 `cl_vm_reset_pending`이 참이고 다음 eval · validate가 다시 reset한다(eval 안의 할당
  실패와 같은 길). `bindCore`는 다시 불러도 된다: `Sema.ensureSymbol`은 있는 키를 돌려주고, 실패한 키는 지운다. 반환 타입을
  `bool`로 바꾸는 안은 Zig 호출자 스무 곳이 `_ =`를 써야 하고, 호스트가 할 일(다시 reset하거나 그냥 eval)은 pending 확인으로
  충분해 하지 않았다.
- `clReportApiError`: 전에는 옛 문구를 놓은 뒤 복사가 실패하면 `fatal`이었다(`catch`를 없애면 놓은 포인터가 남는 자리다). 이제
  먼저 복사하고 옛 것을 놓는다. 복사가 실패하면 빈 문구로 오류를 알린다(`hasApiError`는 켜진다). 로더 · resolver 콜백이 부르는
  함수라 오류가 났다는 사실이 문구보다 중요하다.
- lib 테스트 `A reset that runs out of memory leaves a pending reset, and the next eval starts over.`(reset의 할당을 하나씩, 그리고
  그 뒤 전부 실패시킴)와 `An API error without memory for its message is still reported.`
