# 0.4.4 이후 변경 (미릴리스)

0.4.4(2026-11-09) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

## 언어와 표준 라이브러리

## 임베딩 API

- `print` · `eprint` 콜백(`CLPrintFn` · `CLPrintErrorFn`)의 첫 인자가 선언대로 실행 중인 스레드(`CLThread*`)다. 이전에는 VM 포인터를
  넘겨 콜백 안의 `cl_thread_vm(t)` 같은 호출이 쓰레기를 읽었다. 콜백에서 VM이 필요하면 `cl_thread_vm(t)`를 쓴다(F-50,
  `docs/decisions/project_capi_header_sync.md`).
- `cyber.h`를 실제 export에 맞췄다(F-51). 구현이 없던 `clResolveType` · `cl_array_empty_new` · `cl_map_empty_new` 선언을 지우고
  `cl_array_empty(CLThread*, CLType*)` · `cl_map_empty(CLThread*, CLType*)`를 선언했다. `cl_type_from_id`는 `(CLVM* vm, CLTypeId id)`다.
  정의되지 않은 타입을 참조하던 `CL_CUSTOM_TYPE` · `CL_CUSTOM_PRE_TYPE` · `CL_CREATE_TYPE` 매크로는 `cl_mod_add_type`에 넘길
  `CLBindType`을 만드는 `CL_BIND_DECL_TYPE(id)` · `CL_BIND_CREATE_TYPE(fn)` · `CL_BIND_ALIAS_TYPE(fn)`으로 바꿨다. 주석의 옛 이름
  (`cl_free` → `cl_vm_freeb` 등)을 고쳤다. 헤더에 없던 export `clAlloc` · `clGetAllocator`는 지웠다(`cl_vm_alloc` · `cl_vm_allocator` 사용).
  lib 테스트가 헤더의 모든 `cl*` 함수 선언이 export되는지 링크로 검사한다.

## 변경

- `cyber compile` 덤프의 `addr` 명령 표기를 `%dst = *%src`에서 `%dst = &%src`로 바꿨다. 이 명령은 레지스터 `src`의 스택 주소를 `dst`에
  넣는 것이라 옛 표기가 역참조로 읽혔다(`docs/decisions/project_ex_borrow_field_addr.md`).
- 빌드 버전 문자열(`cyber version`의 `build-N-xxxxxxx`)을 `zig build -Dbuild=N -Dcommit=xxxxxxx` 옵션으로 넘긴다. `BUILD` · `COMMIT` 환경
  변수는 폴백으로 남지만 Zig 0.17.1의 configure 캐시가 환경 변수를 추적하지 않아 같은 인자의 이전 빌드 결과가 남을 수 있다
  (`docs/decisions/project_fork_release_ci.md`).
- 빌드 · CI의 Zig를 0.17.0에서 0.17.1로 올렸다(`build.zig.zon` `minimum_zig_version`, 워크플로 `ZIG_VERSION`, `Taskfile.yml`, `docs/build.md`).

## 문서
