# C API 헤더와 export 동기화 · print 콜백의 스레드 인자 (2026-11-10, F-50 · F-51)

## 배경

`src/include/cyber.h`는 C 호스트가 보는 유일한 계약인데 `src/lib.zig`의 `export fn`과 어긋난 곳이 있었다
(`docs/study/08-embedding-builtins-tests.md` §7.2 · §7.3).

- 선언만 있고 구현이 없는 함수: `clResolveType`, `cl_array_empty_new`, `cl_map_empty_new`. 실제 export는 `cl_array_empty` ·
  `cl_map_empty`(헤더에 없음). C 호스트가 헤더대로 부르면 undefined symbol.
- 시그니처 불일치: 헤더 `cl_type_from_id(CLTypeId id)`, export `cl_type_from_id(vm, type_id)`. 헤더대로 부르면 id가 vm 자리로 들어간다.
- 죽은 매크로: `CL_CUSTOM_TYPE` · `CL_CUSTOM_PRE_TYPE` · `CL_CREATE_TYPE`가 정의되지 않은 `CLBindTypeEntry` · `CL_STR` ·
  `CL_BIND_TYPE_CUSTOM`을 참조해 쓰는 순간 컴파일 오류.
- 주석의 옛 이름: `cl_new_compile_error_summary` · `cl_free` · `clAlloc` · `clFindType`.
- 헤더에 없는 export: `clAlloc` · `clGetAllocator`(`cl_vm_alloc` · `cl_vm_allocator`와 중복, 참조 없음).
- print 콜백(F-50): 헤더는 `CLPrintFn(CLThread* t, CLBytes str)`인데 `core.zig`의 `prints` · `eprints`가 `t.c.vm`을 넘겨 콜백의 `t`가
  VM 포인터였다. 콜백에서 `cl_thread_vm(t)` · `cl_thread_*`를 쓰면 쓰레기를 읽는다. `runtime.zig`의 VM 수준 `print` · `err` 계열도
  같은 포인터를 넘겼다.

Zig는 참조되지 않는 extern 선언을 분석하지 않으므로 헤더의 틀린 선언은 Zig 빌드 · lib 테스트에서 드러나지 않고, C로 컴파일되는
`examples/libcyber/*.c`가 쓰는 함수만 검사됐다.

## 결정

- 헤더를 export에 맞춘다. `cl_array_empty(CLThread* t, CLType* array_t)` · `cl_map_empty(CLThread* t, CLType* map_t)` ·
  `cl_type_from_id(CLVM* vm, CLTypeId id)`. `clResolveType`은 지운다(`cl_find_type`이 이미 존재하는 템플릿 확장을 찾고, 새 확장은
  `clExpandTypeTemplate`). 주석의 옛 이름을 현재 이름으로 바꾼다.
- 죽은 매크로 세 개를 `cl_mod_add_type`이 받는 `CLBindType`을 만드는 매크로로 바꾼다: `CL_BIND_DECL_TYPE(id)` ·
  `CL_BIND_CREATE_TYPE(fn)` · `CL_BIND_ALIAS_TYPE(fn)`(`CL_BIND_FUNC` · `CL_BIND_GLOBAL`과 같은 꼴). 매크로 매개변수 이름이
  지정 초기화자의 필드 이름(`.type_id`)과 겹치면 치환되므로 `id`를 쓴다.
- `clAlloc` · `clGetAllocator` export를 지운다. 헤더에 없었으므로 C 호스트는 쓸 수 없었다.
- print · eprint 콜백에 실행 중인 스레드(`*cy.Thread`)를 넘긴다. VM 수준 출력(`runtime.zig`)은 `main_thread`.
- lib 테스트 두 개를 둔다.
  - `print and eprint callbacks receive the running thread.`: 콜백의 `t`가 `cl_vm_main_thread(vm)`과 같고 `cl_thread_vm(t)`가 vm.
    `print` · `eprint`는 값과 줄바꿈으로 두 번, `prints` · `eprints`는 한 번 부른다.
  - `Every function declared in cyber.h is exported.`: `std.meta.declarations(C.c)`로 translate-c가 만든 선언 중 `cl`로 시작하는
    함수의 주소를 모두 참조한다. 헤더에 선언만 있고 export가 없으면 lib_test 링크가 `undefined symbol`로 실패한다(임시 선언으로 확인).
    헤더 쪽 계약은 이 테스트가, 매크로의 C 컴파일은 `lib-standalone-test`의 예제가 검사한다.

## 확인

- lib-test Debug에서 수정 전 바이너리는 F-50 테스트만 실패(`73 pass, 1 fail`), 수정 후 전부 통과.
- 헤더에 `cl_bogus_probe`를 임시로 선언하면 `error: undefined symbol: _cl_bogus_probe`로 링크가 실패한다.
- scratchpad의 C 프로그램이 새 매크로 세 개 · `cl_find_type` · `cl_type_id` · `cl_type_from_id(vm, id)` 왕복 · `cl_array_empty` ·
  `cl_map_empty` 참조를 `clang -Wall -Wextra`로 `zig-out/lib/libcyber.a`에 링크해 실행 성공.

## 남은 것

- `examples/android/ndk_app/cyber.h`는 옛 API(`CLHostTypeEntry` · `clAlloc`)의 사본이라 현재 헤더와 다르다. 그 예제를 살릴 때 교체한다.
- F-52(비-`persist_main`의 "마지막 표현식 값" 주석 · ANSI 색) · F-41(C용 할당자 훅)은 별개.
