# 컴파일 단계의 할당 실패 처리 (2026-11-10)

상태: 구현됨. 발견 이슈 F-41의 남은 것. 메모리 한도는 `project_memory_limit.md`, C용 메모리 함수는 `project_c_mem_funcs.md`.

## 배경

`cl_vm_init_mem`(`eee5bcdb`)으로 C 호스트가 VM의 할당자를 쥐게 됐다. 그 `alloc`이 `NULL`을 돌려주는 것은 실행 중의 힙 · 스택
성장에서는 `panic: OutOfMemory`가 됐지만(`b7fdf554`), 컴파일 중이거나 panic을 처리하는 중이면 정의된 동작이 아니었다. 고정
크기 아레나를 준 호스트는 스크립트 하나가 큰 것만으로 프로세스를 잃을 수 있었다.

측정은 lib 테스트에 임시로 넣은 `ProbeAlloc`(eval 하나에서 N번째 할당만 실패, N마다 새 프로세스, 누수 검사 할당자 위)으로 했다.
코드와 실행 스크립트는 `src/tools/alloc_fuzz/`에 있다(`README.md`).
스크립트는 struct · enum · 템플릿 · 제너레이터 · 클로저 · 오류 union을 쓰고 Array · Map · 문자열 · `^Node` 리스트를 600번 키운다.

- 시나리오 0(새 VM의 첫 eval, 할당 10444회): 8554회 정상(오류를 돌려주고 누수 없음), 1261회 누수, 629회 프로세스 종료.
- 시나리오 1(`persist_main` 세션의 두 번째 eval, 할당 485회): 361회 정상, 39회 누수, 85회 프로세스 종료.

종료는 `catch fatal()`(오류를 돌려줄 수 없는 콜백과 요약 API), 반쯤 지은 상태를 읽는 `deinit`(union 필드 오접근, 초기화 안 된
포인터), 실패한 컴파일 위에 다시 컴파일하는 다음 eval이었고, 누수는 `errdefer` 없는 중간 할당이었다.

## 결정

1. 할당 실패로 끝난 컴파일의 상태는 다시 쓰지 않는다. `MemAccount`가 호스트 할당자의 `alloc` 실패 수(`failed`)를 세고,
   `Compiler.compile`이 시작 때의 값을 쥐었다가 실패하면 비교한다. 오류가 `error.CompileError`가 아니거나 `failed`가 움직였으면
   `Compiler.alloc_failed`를 켠다. 오류 값만 보지 않는 이유: comptime 함수 안의 실패는 `CompileError: error.OutOfMemory`라는
   평범한 컴파일 오류로 올라온다. `resize`의 false와 `remap`의 null은 세지 않는다(호출자가 `alloc`으로 넘어간다).
2. `VM.eval` · `VM.validate`는 `first_compile_failed or alloc_failed`면 컴파일 전에 `resetVM()`한다. 컴파일 오류는 정해진
   지점에서만 나지만 할당 실패는 어디서든 나므로, 실패 지점마다 되감기를 짜는 대신 F-04의 첫 컴파일 실패와 같은 길을 쓴다.
   대가: `persist_main` 세션에서 컴파일이 메모리 부족으로 끝나면 앞선 eval의 지역 변수와 선언을 잃는다. 호스트의 설정
   (연료, 스택 · 메모리 한도, 프린터, user data)은 reset을 넘어 남는다.
3. 오류를 돌려줄 수 없는 호스트 콜백은 `Compiler.host_error`에 오류를 남긴다. `cl_mod_add_func` · `cl_mod_add_type` ·
   `cl_mod_add_global` 등 모듈에 바인딩을 넣는 C API와 builtin 타입 생성 콜백(`CLCreateTypeFn`, `failCreateType`)이 그렇다.
   콜백을 부른 직후(`on_load`, 모듈 로더)와 컴파일 끝에서 그 오류로 컴파일이 실패한다. 이전에는 `fatal`이었다.
4. 결과 코드는 실패한 곳을 따른다.
   - 컴파일러: `CL_ERROR_COMPILE`. 요약은 `CompileError: OutOfMemory` 계열이거나, 리포트를 만들 메모리도 없으면 빈 문자열이다.
     할당하는 writer(`std.Io.Writer.Allocating`) 뒤에서 난 실패는 요약에 `WriteFailed`로 적힌다(한계).
   - 스크립트 실행: `CL_ERROR_PANIC`, `panic: OutOfMemory`. VM은 reset 없이 계속 쓴다.
   - 실행 뒤 정리(`copyMainLocalSaves`의 지역 변수 이월, `main_res` 복사): `CL_ERROR_UNKNOWN`, 요약 없음. 스크립트는 끝까지
     돌았지만 결과나 세션 상태를 넘길 수 없다. 지역 변수 이월이 실패하면 다음 eval은 reset한다.
5. 요약 API(`cl_vm_error_summary` · `cl_vm_compile_error_summary` · `cl_thread_panic_summary`)는 문자열을 할당하지 못하면
   null `CLBytes`를 돌려준다. `cl_vm_freeb`에 그대로 넘겨도 된다.
6. panic 처리는 메모리 없이도 끝난다. 메시지를 할당하지 못하면 정적 메시지 `OutOfMemory`(`PANIC_STATIC_MSG`)로 바꾸고
   (원래 메시지는 가려진다), 스택 트레이스를 기록하지 못하면 트레이스 없이 진행한다. 어느 쪽이든 스레드 힙은 해제한다.
   그러지 않으면 그 실행의 객체가 VM이 끝날 때까지 남는다.
7. Trace 빌드의 `traceAlloc`은 `fatal` 대신 오류를 전파하고 받은 풀 슬롯을 free list에 되돌린다(`untakePoolObject`).
   `project_memory_limit.md`의 한계 하나가 없어진다.
8. `alloc_failed`인 컴파일러의 `deinit`은 컴파일 타임 힙을 스윕한다(`Heap.sweep`). 소유자가 만들어지기 전에 버려진 comptime
   값(문자열, 버퍼)은 sym을 따라가서는 닿지 않는다. 스윕은 sym이 쥔 값을 모두 놓은 뒤, 객체 크기를 주는 타입이 아직 살아 있을 때 돈다.
9. `cl_find_type`은 할당 실패를 "없음"과 구분하지 않고 `NULL`을 돌려주지만 안쪽 `findType`은 `OutOfMemory`를 전파한다.
   이전에는 comptime 평가의 모든 오류를 null로 삼켜, 타입이 있다고 아는 호출자(`findType(...).?`)가 null을 풀었다.
10. 하지 않는 것: VM을 만드는 구간(`cl_vm_init*`)과 호스트가 값을 만드는 API(`cl_str_init*`, `cl_array_empty`, `cl_map_empty`,
    `cl_vm_alloc` 등)의 할당 실패는 여전히 `fatal`이다. VM 포인터나 값을 돌려주는 시그니처라 실패를 알릴 길을 새로 정해야 한다.

## 구현 메모

- `VM`(Zig) 구조체는 `vm.h` `ZVM` 패딩에 묶여 있어 `alloc_failed` · `host_error`는 `Compiler`에 뒀다.
- reset이 도는 `deinit` 경로가 반쯤 지은 상태에서 죽지 않게 지점별로 고쳤다. 반복된 모양과 고친 방식:
  - `getOrPut` 뒤 값을 채우기 전에 실패: `errdefer map.removeByPtr(...)`(`chunk_map`, `func_sig_map`, `const_string_map`, `ptr_layout_map`, 템플릿 `instance_cache`).
  - `create` 뒤 리스트 `append`가 실패: `ensureUnusedCapacity`를 먼저 하고 `appendAssumeCapacity`(`chunks`, `funcs`,
    `func_sigs`, `ptr_layouts`, 템플릿 `instances`, `env_local_saves`, `vm.globals`).
  - 구조체 리터럴 안의 `try`: 먼저 지역 변수로 받아 `errdefer`를 건다.
  - `dupe` 뒤 `append` · `put`이 실패: 사본을 해제(`find_type_cache`, 이름 · uri 사본).
  - 타입이 리스트를 가져간 뒤에도 실패할 수 있는 해석: 소유가 넘어갔는지 플래그로 가른다(`cases_owned`).
  - `types.createType` · `createTypeWithId`: `create` 뒤 `errdefer destroy`.
- 힙: `new_byte_buffer` 계열의 `errdefer`, `allocBigObject`의 포인터 객체 반환(앞 커밋)에 더해 `traceAlloc` 실패 시 슬롯 반환.
- 퍼즈가 가리킨 지점 가운데 셋은 할당 실패와 무관하게 평범한 컴파일 오류에서도 새던 것이다.
  - trait: 해석 중 메서드 하나가 실패하면 그때까지 예약한 멤버 함수를 타입이 소유하지 않았다. `GenericTrait.members_cap`으로
    예약한 만큼을 소유한다.
  - enum · choice · cunion: case 하나가 실패하면(없는 payload 타입, 중복 이름) cases 리스트가 샜다.
  - 중복 case 이름은 누수 이전에 컴파일러를 abort시켰다. 별도 이슈 F-81(아래 "부수 발견").
- `bc_gen.prepareSym`: 전역(`hostVar` · `extern_var` · `userVar`)의 `GlobalSym`을 만들기 전에 `vm.globals`와 `genSymMap`의
  자리를 잡는다. 만들어진 `GlobalSym`은 항상 소유자 `vm.globals`에 들어간다.
  `genAll`의 trait vtable(`vm.vtables` · `gen_vtables`)과 Trace 빌드의 타입 이름(`vm.types`)도 같은 방식이다.
- 리포트: `Compiler.compile`은 `Error: OutOfMemory` 리포트를 만들 메모리가 없어도 `error.CompileError`로 끝난다(결정 4의
  빈 요약). 이전에는 리포트 할당의 `OutOfMemory`가 그대로 나가 지속 실패에서 `CL_ERROR_UNKNOWN`이 됐다. `addReportConsume`은
  리스트에 넣지 못한 메시지를 해제한다.
- 컴파일러가 만든 노드의 오류 위치: 숨은 함수(`@init` 등, `reserve_hidden_func`)의 `funcDecl`과 이름 ident는 `pos`가
  `NullId`다. 코드 생성이 그 함수에서 실패하면 `curNode`가 그 선언이라 요약의 `node.end()`가 `NullId + 이름 길이`를 `u32`에
  담다가 `integer does not fit in destination type`으로 abort했다(퍼즈 N 9031 · 9032 · 9038). `writeUserErrorTrace2`와
  `reportLoc`은 `pos`가 `NullId`인 노드를 위치 없는 오류로 다룬다(`in <uri>`, `has_loc = false`).

## 부수 발견: 중복 필드 · case 이름의 컴파일러 abort (F-81)

struct 필드, enum case, choice case, cunion case의 이름이 한 타입 안에서 겹치면 컴파일러가 `panic: Unsupported: .field`
(`.enum_case` · `.choice_case` · `.union_case`)로 프로세스를 끝냈다(ReleaseSafe CLI도 같다, 종료 코드 134). `reportDupSym`이
"First declared at" 문맥을 붙이려고 `sym.declNode()`를 부르는데 이 sym들은 선언 노드를 갖지 않는다.

- 결정: 선언 노드가 없는 sym이면 문맥 없이 오류만 보고한다. `Sym.declNodeOrNull`을 더하고 `declNode`는 그 위에서 panic한다.
  필드와 case sym에 선언 노드를 더하는 쪽은 sym 크기를 늘리므로 택하지 않았다. 두 선언은 같은 타입 안 몇 줄 사이에 있다.
- 오류: ``CompileError: `red` has already been declared as a `enum_case`.`` 위치는 두 번째 선언이다.
- 테스트: `types/enum_dup_case_error.cy` · `choice_dup_case_error.cy` · `struct_dup_field_error.cy` · `cunion_dup_case_error.cy`.

## 한계

- 컴파일 OOM 뒤의 reset은 세션을 버린다(결정 2). 세션을 지키려는 호스트는 컴파일 전에 여유를 확인하거나
  (`cl_vm_memory_used`), 할당자가 아니라 `cl_vm_set_memory_limit`으로 상한을 건다. 한도는 컴파일 단계를 막지 않는다.
- 요약의 오류 이름이 둘이다. 텍스트 writer 뒤의 할당 실패는 `error.WriteFailed`로 올라와 요약이 `CompileError: Error: WriteFailed`
  (또는 `error.WriteFailed`)다. 시나리오 0의 컴파일 오류 7636회 가운데 1235회가 그렇다. 결과 코드는 같으므로 호스트는 요약 문구가
  아니라 코드로 가른다. `OutOfMemory`로 모으지는 않았다.
- 실패를 삼키는 지점이 남아 있다. 퍼즈에서 "실패를 한 번 맞고도 eval이 성공"한 경우는 대부분 제자리 성장(`resize` · `remap`)
  거절 뒤 새 블록으로 넘어간 것이지만, 일부는 선택적 기록(디버그 정보, 캐시)을 건너뛴 것이다.
- `PANIC_INFLIGHT_OOM`은 이제 아무도 켜지 않는다. 마지막 사용처 `z_panic_unexpected_choice`가 정적 `OutOfMemory` 메시지를 쓰고,
  `allocPanicMsg`의 그 분기는 abort 대신 `OutOfMemory`를 돌려준다(F-52가 남긴 것). 퍼즈 스크립트는 이 경로에 닿지 않는다.
- 남은 `catch fatal()`: `lib.zig` 23(VM 생성, 값 생성 API, `resetVM`, `setApiError`, `cl_vm_resolve` 등), `runtime.zig` 11,
  `string.zig` 5, `vm.zig` 3, `os_ffi.zig` 3, `core.zig` 2, `mem_account.zig` · `heap_value.zig` · `cgen.zig` ·
  `builtins/string.zig` 각 1. 이번 퍼즈의 스크립트가 닿지 않은 경로(FFI, C 백엔드, 문자열 포맷 일부)다.
- 퍼즈는 스크립트 하나(와 세션 스크립트 하나)의 경로만 본다. 그 밖의 문법 · 모듈 로더 · `spawn` 경로는 같은 방식으로 다시
  돌려야 드러난다. `ProbeAlloc`은 빌드에 넣지 않고 `src/tools/alloc_fuzz/`에 두었다(`fuzz.sh build`가 `src/lib.zig`에 잠깐 덧붙여
  빌드한다). 평소 회귀는 lib 테스트의 `FailingAlloc`(`src/lib_test/alloc_fail.zig`)이 본다.

## 검증

- lib-test `An allocation that fails during an eval is an error, and the VM can be used again.`: 새 VM과 세션 각각에서 eval의
  할당 수를 센 뒤, 고르게 나눈 4지점의 한 번 실패와 2지점의 지속 실패(그 뒤 모든 할당 실패)를 돌린다. 요약은 할당자가 실패하는
  채로 요청한다. 결과는 성공이거나 `CL_ERROR_COMPILE` · `CL_ERROR_PANIC` · `CL_ERROR_UNKNOWN`, 세션에서 컴파일이 실패했으면
  앞선 지역 변수가 없고, 다음 eval은 성공, 누수 없음.
- lib-test `A type declaration that fails part way frees what it reserved.`: trait 메서드 · enum 중복 case · choice payload 오류.
- 퍼즈 재실행(수정 뒤, Debug · Trace 빌드):
  - 시나리오 0, 한 번 실패(N 1..10600, 할당 수 약 10444를 넘는 N은 실패 없이 성공): 10600회 모두 정상, 누수 0, 종료 0.
    수정 전은 정상 8554 · 누수 1261 · 종료 629였다. 결과는 `CL_ERROR_COMPILE` 7636(요약 `CompileError: Error: OutOfMemory` 3397,
    `error.OutOfMemory` 3004, `Error: WriteFailed` 737, `error.WriteFailed` 498), `panic: OutOfMemory` 636, 성공 2328.
  - 시나리오 0, 지속 실패(N번째부터 모든 할당 실패): 10600회 모두 정상. `CL_ERROR_COMPILE` + 빈 요약 9766, `panic: OutOfMemory` 671, 성공 163.
  - 시나리오 1, 한 번 실패(N 1..500, 할당 485회): 500회 모두 정상. 수정 전은 정상 361 · 누수 39 · 종료 85였다. `CL_ERROR_COMPILE` 407,
    `panic: OutOfMemory` 15, `CL_ERROR_UNKNOWN` 11, 성공 67.
  - 시나리오 1, 지속 실패: 500회 모두 정상. `CL_ERROR_COMPILE` + 빈 요약 458, `panic: OutOfMemory` 16, `CL_ERROR_UNKNOWN` 11, 성공 15.
  - "정상"은 프로세스가 살아 있고, 누수 검사 할당자가 누수를 보고하지 않고, 실패 뒤 같은 VM의 다음 eval이 성공한 것이다.
  - 과정: 수정을 넣은 중간 바이너리의 시나리오 0 전체 실행에 11지점(누수 8, 종료 3)이 남았다. `genAll`의 vtable · 타입 이름과
    컴파일러가 만든 노드의 요약이다. 고친 뒤 최종 바이너리로 네 실행을 모두 다시 돌린 것이 위 수치다.
- 13단계 검증(네이티브 test 4모드, lib-test 2모드, lib-standalone, wasm32 4개) 통과.

## 남은 것

- VM 생성 구간과 값 생성 API의 `fatal`(결정 10).
- 요약의 `WriteFailed`를 `OutOfMemory`로 모으기.
- 컴파일 OOM 뒤에도 세션을 지키는 되감기. 필요해지면 컴파일을 세션의 사본 위에서 하는 쪽을 먼저 본다.
