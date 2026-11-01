# 소유권과 메모리: ARC 단일 모델에서 값 소유권 · 빌림 · ARC 혼합으로

2026-11-01 작성. 개요는 `cyber_0_3_to_0_4_overview.md`. fork의 관련 결정은 `docs/decisions/project_embedding_agent_loop.md`,
`docs/decisions/project_slice_append_aliasing.md`.

## 0.3 상태 (2023-12)

- 메모리 모델은 ARC 하나였다. 원시 값은 복사, 객체는 참조 카운트. 클로저가 잡은 원시 변수는 heap에 박스로 올라가 ARC 관리.
- fiber도 객체라 ARC로 해제되고, 해제 시 콜 스택을 되감았다.
- 40바이트 이하 객체는 풀에서, 큰 객체는 mimalloc으로 할당했다.
- 참조 순환은 `performGC()`로 수거했다(GC 역할, "main fiber 스택만 정리" Incomplete). Weak references는 Planned.
- 호스트 객체는 `getChildren` · `finalizer` 콜백으로 ARC에 참여했다.

## 구간 A에서 바뀐 것 (2024-01 ~ 2024-09)

| 날짜 | 커밋 | 변화 |
|---|---|---|
| 2024-02-11 | `0c1132cd` `6d85e885` | 값 타입 struct, 중첩 struct, 참조 opcode |
| 2024-05-13 | `f2db5f04` | 옛 VM 삭제 |
| 2024-07-10 | `f401a101` `94bade94` `946ed790` `b5e11796` | `Slot` · unboxed 슬롯, 64비트 unboxed `int`, 포인터 타입, `Memory` · `IMemory` · `DefaultMemory` · `ptrcast` · `sizeof` |
| 2024-09-20 | `35e84dd9` | 참조 타입을 값 타입에서 유도, object 타입 제거 |
| 2024-09-21 | `c5cc2d6f` | 클로저 `UpValue`를 참조로 대체 |

`c992b94e` 시점 문서의 "Memory" 장은 두 부분이었다. "Automatic memory"가 기본이고 ARC의 장점(결정적 · 세분화 · 소멸자 ·
호환성 · 작음)을 길게 적었다. "Structured memory"는 "1.0 이후로 미뤄질 가능성이 크고 의미론이 바뀔 수 있다"는 NOTE가 붙은
계획이었다. 그 계획은 `ListValue`(값 타입 리스트), `Copyable` · `NonCopyable` · `Cloneable` trait와 `copy(self)` · `clone(self)`
메서드, 빌림 `&`, Lifted values, Deferred borrows, Shared ownership을 담았다. 순환 수거는 `collectCycles()`로 이름이 바뀌었고
"앞으로는 수거가 아니라 탐지만 한다"고 예고했다. Manual memory와 Runtime memory checks는 Planned.

## 구간 B에서 바뀐 것 (2025-11 ~ 2025-12)

`b751ca6c`에서 미뤄 두었던 Structured memory가 기본 모델이 됐다. `move` · `sink` · `scope` 키워드가 들어왔다.
`^T`(공유 참조)만 ARC로 남고 나머지는 단일 소유권으로 설명한다.

## 0.4.2 현재 상태

- 값 소유권: 스택 값은 소유자 하나. 블록 끝 · 재대입 시 deinit. heap 값은 `^T`로 여러 소유자.
- 복사: 원시 · `str` · `Slice` · 모든 멤버가 복사 가능한 struct는 암시적 복사. `@copy` 메서드로 깊은 복사 정의.
  `NoCopy` trait(`core.cy`의 `type NoCopy trait`)로 복사 금지. `Array`는 복사 불가, move만.
- 이동: `move a`, 부분 이동 `move f.b`, 이동 후 사용은 컴파일 에러. 함수 반환은 암시적 move(fork `eb060d5`).
- 빌림: `&T`(여러 개 가능), `&&T`(배타, 크기 변경 메서드가 자동 획득), `self` 빌림 `fn (&Foo) m()`, `scope` 매개변수로 빌림 반환,
  `sink` 매개변수(문서가 "제거될 수 있다"고 적음).
- 소멸자: `@deinit` 메서드. 패닉 시 "fatal deinitialization"은 평탄한 순서로 돌고, `Unwind` trait 조건은 TBD.
- 공유 참조 `^T`: ARC, retain 최적화, 순환은 런타임 에러로 보고(safe mode에서 스레드 끝에 탐지).
- 테스트: `src/test/memory` 36개(borrow · move_* · partial_move · scope_* · sink_* · custom_deinit · arc_cases ·
  gc_reference_cycle_* · override_copy · lift_* · return_* · slice_shared_buffer · host_str_params · future_resolver).
- 문서만 있고 소스에 없는 것: `clone`, `@check_cycles`, Weak references, `Unwind`.

## fork가 한 것 (2026-10 ~ 11)

- 지역 변수 반환을 복사 대신 move로 바꿔 `@deinit` 이중 호출을 고침(`eb060d5`). `?R` · `!R` 감싸기도 move.
- 호스트 함수 매개변수 소유 규약을 확정했다. 값 매개변수는 피호출 호스트 함수가 소유하고 해제한다. `^T` 등 object 타입 인자는
  빌림. 근거는 `ownOrManageArg`(`src/sema_func.zig`). 위반 7개 수정, `cl_slice_deinit` 추가, `@notifyFutureComplete`를
  `&FutureValue[T]` 빌림으로 변경.
- Slice 버퍼 앞 8바이트에 초기화 원소 수를 두고 `Slice.@deinit`이 그만큼 해제한다(Swift식). `append`의 유일 참조 버퍼 공유
  빠른 경로 때문에 관리 원소가 새던 문제를 고쳤다.
- `single_run`(ReleaseFast CLI) 종료 시 `VM.deinit` 맨 앞에서 힙을 스윕한다. 큰 객체(`allocBigObject`)와 `^Generator` 메타의
  박스를 놓치던 문제를 함께 고쳤다. 이 스윕은 소멸자를 건너뛴다.

## 미완 지점

- Slice 별칭 의미 문제. `b := a.size_down(0)` 뒤 `a[0]`을 읽으면 해제된 칸을 본다. 제자리 갱신을 소유한 값에만 허용하려면
  컴파일러에 마지막 사용 분석이 있는지부터 조사한다(`project_slice_append_aliasing.md` 후보 2).
- 명시적 `move`의 "같은 블록 선언만" 제약. return이 암시적 move가 되어 급하지 않다.
- `single_run` 스윕이 소멸자를 건너뛰는 계약. 종료 시 돌아야 하는 정리 코드가 생기면 다시 본다.
- 문서 TBD · Planned: Cloning, Weak references, Cycle detection의 `@check_cycles`, Manual memory, Memory allocations, Deinitializers의 `Unwind`.
- `sink`의 존속 여부를 upstream이 정하지 않았다.

## fork의 결정 · 미결

- 결정: 호스트 함수 값 매개변수 소유 규약(위). Slice 버퍼 헤더 방식. `single_run` 종료 스윕.
- 미결: Slice 별칭 의미. `sink` 유지 여부. Cloning · Weak references는 지금 용도에 필요하지 않아 3순위.

## 해석

- 0.3의 ARC 단일 모델은 동적 타입과 맞는 선택이었다. 값의 타입을 모르면 모든 값을 참조 카운트해야 한다. 정적 타입으로
  옮기자 수명을 컴파일 시점에 알 수 있게 되어 소유권 모델이 가능해졌고, upstream은 그것을 1.0 이후 계획에서 기본으로 끌어올렸다.
- 그래서 지금 모델은 Rust(소유권 · 빌림)와 Swift(ARC `^T`, `@copy`, 버퍼 헤더)의 혼합이다. 빌림 검사는 Rust보다 느슨하다.
  `&T`가 가변이고 배타 빌림 `&&T`는 재할당이 일어나는 연산에만 요구된다.
- fork가 찍은 버그 세 가지(반환 복사 이중 해제, 호스트 매개변수 누수, Slice 버퍼 공유 누수)는 모두 "소유권 모델은 들어왔지만
  런타임 · 표준 라이브러리가 그 규약을 끝까지 따르지 않은" 자리였다. 남은 자리도 같은 유형일 가능성이 크므로, 메모리 관련 작업은
  먼저 소유 규약을 문장으로 적고 그 규약에 맞춰 코드를 맞추는 순서가 맞다.
