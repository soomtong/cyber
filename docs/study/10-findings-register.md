---
aliases: [발견 이슈 종합표, findings]
tags:
  - study
  - cyber
  - bugs
  - maintenance
---

# 부록. 학습 중 발견한 이슈 종합표

> 이 문서는 00~08장을 쓰면서 각 챕터 작성자가 소스를 읽고 실행해서 찾아낸 버그, 한계, 문서와 코드의 차이를 한곳에 모은 목록이다.
> 줄 번호와 동작은 HEAD b40531a1, aarch64 macOS, Zig 0.17.0 기준이다.
> 이 fork를 인수해서 고칠 사람에게 "어디부터 손대야 하는가"를 알려 주는 것이 목적이다.

## 읽는 법

검증 표기는 세 가지다.

- 메인 재현: 이 문서를 취합한 사람이 CLI로 직접 다시 실행해 같은 결과를 확인했다.
- 챕터 재현: 해당 챕터 작성자가 실행으로 재현했고 챕터에 명령과 출력이 실려 있다.
- 코드 판독: 실행하지 못했거나 하지 않았고 소스를 읽어서만 확인했다. 틀릴 수 있으므로 고치기 전에 재현부터 한다.

영향 열은 "이 런타임을 코딩 에이전트 루프에 임베딩한다"는 용도 기준이다.

- 치명: 호스트 프로세스가 죽거나, 조용히 틀린 결과가 나온다.
- 높음: 안전 장치가 없거나 상태가 깨진다.
- 중간: 에러 메시지, 디버깅, 문서에 문제가 있다.
- 낮음: 용도와 거의 무관하다.

수정은 하나도 하지 않았다(src 불변). 각 항목의 "첫 걸음"은 제안이다.

## A. 호스트를 죽이거나 상태를 깨는 것

| ID | 증상 | 위치 | 검증 | 영향 | 첫 걸음 |
| --- | --- | --- | --- | --- | --- |
| F-01 | 제너레이터 본문의 지역 변수가 yield를 넘어 보존되지 않는다. `i := 10; yield i; i += 1; yield i; i += 1; yield i`가 10, 11, 11을 낸다. `for 0..3 \|i\|`는 소비 측에서 다른 호출이 끼면 무한 루프 | `bc_gen.zig:2345`(ret_gen), `vm.c:1415`(RET_Y에 되돌려 저장 없음), `thread.zig:17` | 메인 재현 + [07 §2.4](07-coroutines-concurrency.md) | 치명 | **2026-11-04 수정**(안 A + 재개 시 스택 검사, `project_coroutines.md`의 "제너레이터 프레임 보존 수정") |
| F-02 | yield를 넘는 관리 타입 지역(str 등)이 있으면 segfault | F-01과 같은 원인 | 챕터 재현 [07 실습 4](07-coroutines-concurrency.md) | 치명 | F-01과 함께 |
| F-03 | 제너레이터 안에서 panic이 나면 언와인드가 죽고 호스트 프로세스가 abort한다. `meta.stack_trace()`도 같다 | `thread.zig:1006~1009`(gen 분기가 반환 슬롯 1개를 가정), `recordCurFrames` | 메인 재현(ReleaseSafe CLI: `integer does not fit in destination type`) + [07 §2.5](07-coroutines-concurrency.md). 트레이스 빌드에서는 메시지가 `incorrect alignment`로 다르다 | 치명 | **2026-11-04 수정**(`FrameInfo.prev_context()`가 `Generator.prev_fp`를 따라감) |
| F-04 | 첫 eval이 컴파일에 실패하면 다음 eval에서 SIGSEGV(구문 오류) 또는 `@program_init has already been declared`(의미 오류). 우회: 빈 소스를 먼저 eval하거나 실패 뒤 `cl_vm_reset` | `compiler.zig:310`(`cont`는 첫 성공 뒤에만 true) 근처로 추정 | 챕터 재현 [08 §7.3](08-embedding-builtins-tests.md). 원인은 코드 판독 | 치명 | C 호스트 최소 재현을 `lib.zig` 테스트로 고정 |
| F-05 | `cl_vm_validate`/`cl_vm_compile`이 VM을 리셋해 `persist_main` 변수를 지운다. validate가 구문 오류로 실패하면 이후 eval이 깨지고 요약 조회가 SIGBUS | `lib.zig`의 resetVM 호출 | 챕터 재현 [08 §7.3](08-embedding-builtins-tests.md) | 높음 | 검증용 VM을 따로 두거나 리셋하지 않게 |
| F-06 | 스크립트가 `use c` 없이 `p := as[Ptr[int]] 8; print(p.*)`로 임의 주소를 역참조해 프로세스를 죽인다 | `as[Ptr[T]]` 캐스트 sema | 메인 재현(`Segmentation fault at address 0x8`) + [08 §7.4](08-embedding-builtins-tests.md) | 치명 | 로더 허용 목록으로는 막을 수 없다. 캐스트 자체를 막는 컴파일 옵션이 필요 |
| F-07 | 비-main 스레드의 `await`가 `@panic("TODO")`로 프로세스를 죽인다. 스레드 panic의 원래 메시지는 사라지고 `Spawned thread did not finish.`만 남는다 | `vm.zig`의 zAwait | 코드 판독 + [07 §2.6](07-coroutines-concurrency.md) | 높음 | 에이전트 환경에서는 spawn 금지 또는 이 경로 차단 |
| F-08 | 컴파일러의 `std.debug.panic` 경로가 호스트를 abort시킨다. 알려진 사례: 한 함수에 지역 변수 257개(256개는 통과) | `sema.zig:3416`(`LocalVarS.id`가 u8) | 메인 재현(`integer does not fit in destination type`) + [03 §7](03-sema-and-ir.md) | 치명 | 한계 검사를 사용자 오류로 바꾼다 |
| F-09 | 같은 계열의 다른 한계: 루프 본문 `s += 1` 9000줄 이상, if 본문 17000줄 이상, 점프 오프셋 `int16_t`(앞 점프가 32767단위를 넘으면 런타임 크래시) | `bc_gen.zig`의 점프 패치, `vm.c:867` | 챕터 재현 [04 §5](04-bytecode-gen.md), [05 §5 실습 6](05-vm-runtime.md) | 높음 | LLM이 긴 스크립트를 생성할 때 닿는다 |
| F-10 | 스택 포인터 패치 구멍. 스택이 재할당될 때 main 프레임의 `&x`, `call_ptr`/`call_union`로 부른 호출 중의 포인터는 갱신되지 않아 쓰레기를 읽는다 | `thread.zig:890`(init 프레임 미패치), `bc_gen.zig:3127`(ptr_table은 call/call_host만) | 챕터 재현 [04 §7](04-bytecode-gen.md), [05 §7](05-vm-runtime.md) | 치명 | 깊은 재귀 + 빌림 조합에서 발생 |
| F-11 | `g := math.sqrt; g(16.0)`처럼 호스트 함수를 함수 값으로 쓰면 segfault. `addr \| (1<<63)`가 정의되지 않은 시프트라 컴파일러가 대입을 지운다 | `vm.c:1718`(FN_HOST) | 챕터 재현 [05 §5 실습 6](05-vm-runtime.md) | 높음 | 시프트를 `(u64)1 << 63`으로 |
| F-12 | `#[generator]` 밖에서 `yield`를 쓰면 컴파일러가 segfault | `sema.zig:711` | 챕터 재현 [07 §7.1](07-coroutines-concurrency.md) | 높음 | 사용자 오류로 |
| F-13 | 끝난 제너레이터에 `next()`를 한 번 더 부르면 릴리스 CLI가 `unexpected 4`만 찍는다. `gen_next`/`gen_end`에 debug sym이 없다(추정) | `bc_gen.zig:720, 733` | 챕터 재현 [07 §2.5](07-coroutines-concurrency.md) | 중간 | **2026-11-04 수정**(`pushFCode`로) |
| F-14 | 빌림 `&int` 매개변수를 받는 제너레이터는 힙 스냅샷에 스택 주소를 담아 use-after-return이 된다. 컴파일 에러가 없다 | sema의 `semaLift` 우회 | 챕터 재현 [07 실습 8](07-coroutines-concurrency.md) | 높음 | borrow 매개변수 거부 |

## B. 조용히 틀린 결과를 내는 것

| ID | 증상 | 위치 | 검증 | 영향 | 첫 걸음 |
| --- | --- | --- | --- | --- | --- |
| F-20 | 컴파일타임 평가(cte)가 복합 대입(`+=` 등)을 버린다. 같은 함수가 런타임에서는 15, `const x = f()`에서는 5. `for 0..10 \|i\|: total += i`를 const로 평가하면 45 대신 9 | `cte.zig:423`(변수), `cte.zig:460`(벡터 원소) | 메인 재현(15와 5) + [03 §7.1](03-sema-and-ir.md) | 치명 | `rec_op`를 적용한다 |
| F-21 | 오버로드는 선언 순서대로 처음 성공하는 후보를 고른다. `float` 오버로드를 먼저 선언하면 `int` 인자도 `float` 쪽으로 간다. 파라미터가 같고 반환만 다른 오버로드도 에러 없이 통과 | `sema_func.zig`(롤백 TODO는 653) | 메인 재현(`show(n)`이 `float`) + [03 §7.1](03-sema-and-ir.md), [02 §5](02-symbols-and-types.md) | 높음 | 가장 적합한 후보 선택 또는 모호성 에러 |
| F-22 | trait 구현 검사가 파라미터 타입 불일치를 무시한다(trait는 `k float`, 구현은 `k int`가 컴파일). `Dyn`으로 부르면 값이 깨진다. 파라미터가 trait보다 적으면 컴파일러가 index out of bounds로 죽는다 | `types.zig:625~640`(`get_trait_method_impl`의 안쪽 `for`의 `continue`) | 메인 재현(컴파일되고 실행됨) + [02 §5](02-symbols-and-types.md) | 높음 | 불일치 시 해당 후보를 실패로 |
| F-23 | 템플릿 캐시 비교가 틀리다. 비-Type 매개변수에서 조기 return해 `Buf[1,47]`이 `Buf[1,45]`로 조용히 대체된다 | `template.zig:189~224` | 챕터 재현 [02 §5](02-symbols-and-types.md) | 높음 | 매개변수 전부 비교 |
| F-24 | 문자열 리터럴이 65536바이트 이상이면 길이가 잘린다(65536 → 0, 70000 → 4464). 길이가 `const_str`의 16비트에 들어간다 | `bc_gen.zig:1272` | 메인 재현(70000 → 4464) + [04 §7](04-bytecode-gen.md) | 중간 | 긴 리터럴은 거부하거나 u32 길이 |
| F-25 | 빌림 검사 구멍. `Local.parent_local`이 대입되지 않아 `active_borrows` 감소가 죽은 코드라 `r := &a; a.append(4)`가 막힌다(과잉 거부). 반대로 `&&`를 먼저 쥐고 `&`를 나중에 만들면 통과하고, 블록을 벗어난 빌림 재대입도 못 막는다(과소 거부) | `sema.zig:322`, `:4926` | 챕터 재현 [06 §7.1](06-memory-ownership.md) | 높음 | 빌림 모델을 문장으로 먼저 적는다 |
| F-26 | `Array.append(val T)`가 복사해서 `@deinit`이 원소마다 3번 돈다. NoCopy 원소는 append 불가. `Array.clone()`은 없는 필드 때문에 컴파일되지 않고 `ArrayStore.append(slice)`는 블록이 두 번 실행된다 | `core.cy` | 챕터 재현 [06 §7.1](06-memory-ownership.md) | 높음 | move 시맨틱으로 |
| F-27 | 구조체 필드(`str` 포함)를 가진 관리 구조체의 `move f.b`(부분 이동)가 `core.cy:2849`의 컴파일타임 `if \|x\|` 미지원으로 컴파일되지 않는다. 문서의 예제가 이 형태 | `core.cy:2849` | 챕터 재현 [06 §7.1](06-memory-ownership.md) | 중간 | |
| F-28 | `type X const:`의 결과 타입 이름이 덮어써진다(`IntBox`가 `Pick[int]`로 개명). `const` 매개변수로 `bool`, `EvalStr`, enum을 쓰는 타입 템플릿은 컴파일러 패닉 | `sema_type.zig:27~30`, `template.zig` | 챕터 재현 [02 §5](02-symbols-and-types.md) | 중간 | |
| F-29 | 정상 종료 시 전역 `@deinit`이 main 지역보다 먼저 돈다. `single_run`/panic의 `freeHeapPages` 스윕은 `@deinit`을 한 번도 돌리지 않는다 | 종료 경로 | 챕터 재현 [06 §7.1](06-memory-ownership.md) | 중간 | 종료 시 정리 코드가 생기면 계약 재검토 |
| F-30 | `-` 가시성이 `fn`, 필드, 변수에서 강제되지 않는다(`use *`에서 `-type` 별칭을 거르는 것이 전부) | `module.zig` | 챕터 재현 [02 §5](02-symbols-and-types.md) | 중간 | 문서와 일치시키거나 문서를 고친다 |
| F-31 | `meta.stack_trace()`가 `pop()`을 두 번 불러 가장 바깥 프레임 두 개를 지운다. `dump_frame`은 `chk_stk`의 `stack_size`를 `+3`에서 읽는다(정답은 `+2`) | `meta.zig:194~195`, `debug.zig:59` | 챕터 재현 [04](04-bytecode-gen.md), [05](05-vm-runtime.md) | 낮음 | `stack_trace` 쪽 **2026-11-04 수정**(가장 안쪽 호스트 프레임만 뺌). `dump_frame`은 남음 |
| F-32 | `try ... else err:`는 파서를 통과하지만 sema가 항상 `Unsupported statement: tryStmt`로 거부한다. 문서의 `catch err:`는 파서 단계에서 거부된다 | `sema.zig`, `docs.md:2667` | 챕터 재현 [03 §7.2](03-sema-and-ir.md) | 중간 | Unwrap block 구현(로드맵 1순위)과 묶는다 |
| F-33 | `cyber -cc`, `-tcc`가 sema 단계에서 `Expected function implementation.`으로 실패한다. `cyber fmt`는 `TODO: Embed src/tools/fmt.cy` panic(종료 134) | `sema.zig:2870`, `main.zig:121` | 챕터 재현 [03](03-sema-and-ir.md), [08](08-embedding-builtins-tests.md) | 낮음 | 용도 범위 밖. 도움말에서 숨길지 결정 |

## C. 자원 제한이 없는 것

| ID | 증상 | 위치 | 검증 | 영향 | 첫 걸음 |
| --- | --- | --- | --- | --- | --- |
| F-40 | 스택 성장에 상한이 없다. 무한 재귀 1초에 최대 RSS 4.5GB. 메모리 한도 API도 없다 | `thread.zig`의 `growStackAuto`(1.5배, 상한 없음) | 챕터 재현 [05 §5](05-vm-runtime.md) | 치명 | 스택 상한(`stack_len` 한도)과 `RES_STACK_OVERFLOW`를 진짜 오류로 |
| F-41 | `CLAllocator`가 Zig `std.mem.Allocator` 배치라 C 호스트가 `cl_vm_initx`로 할당 상한을 걸기 어렵다 | `capi.zig:32-38` | 코드 판독 + [08 §7.4](08-embedding-builtins-tests.md) | 높음 | C 친화적 할당자 훅 추가 |
| F-42 | fuel의 off-by-one. `--fuel < 0`이라 fuel N이면 N번 통과하고 N+1번째 체크포인트에서 멈춘다. 호스트 함수 안에서 막힌 호출은 interrupt로 끊지 못한다 | `vm.c:330-336` | 챕터 재현 [05 §2.7](05-vm-runtime.md), 결정 문서 `project_vm_interrupt.md` | 중간 | 문서에 N+1을 적거나 고친다 |
| F-43 | 순환 참조는 수거도 탐지도 없다. `check_memory`는 껍데기이고 릴리스 CLI는 조용히 누수한다. `Weak` 참조가 없다 | `thread.zig:1018` | 챕터 재현 [06 §5](06-memory-ownership.md) | 중간 | 에이전트 환경에서는 VM 폐기로 정리 |

## D. 임베딩 API와 문서의 불일치

| ID | 증상 | 위치 | 검증 | 영향 |
| --- | --- | --- | --- | --- |
| F-50 | print/eprint 콜백의 첫 인자가 `CLThread*`라고 선언돼 있는데 실제로는 VM 포인터 | `core.zig:1248-1262` | 챕터 재현 [08 §7.3](08-embedding-builtins-tests.md) | 중간 |
| F-51 | 헤더에만 있고 구현이 없는 함수 3개(`clResolveType`, `cl_array_empty_new`, `cl_map_empty_new`), 인자 수가 다른 `cl_type_from_id`, 죽은 매크로(`CL_CUSTOM_TYPE` 등) | `cyber.h` 대 `lib.zig` | 챕터 재현 [08 §7.2](08-embedding-builtins-tests.md) | 중간 |
| F-52 | `cyber.h:383`의 "마지막 표현식 값 반환" 주석이 틀렸다. 값은 `fn main() -> T` 반환으로만 받는다. 컴파일 에러는 첫 리포트만 문자열로 나오고 ANSI 색 코드가 무조건 섞인다 | `debug.zig:345` | 챕터 재현 [08](08-embedding-builtins-tests.md) | 중간 |
| F-53 | CLI 로더는 내장 소스를 버리고 디스크의 `src/builtins/core.cy`를 읽는다. 릴리스는 실행 파일 옆 `src/`가 필요하다. 라이브러리는 `@embedFile` | `cli.zig` | 챕터 재현 [08](08-embedding-builtins-tests.md) | 낮음 |
| F-54 | 바이트코드 직렬화가 없다. `call_host`가 호스트 함수 주소를 u48 즉시값으로 박아 넣기 때문. 그래서 core 컴파일 비용(VM당 약 3ms)을 캐시로 줄일 수 없다 | `bc_gen.zig:3110` | 챕터 재현 [08 §5.7](08-embedding-builtins-tests.md) | 낮음 |

## E. 문서, 죽은 코드, 테스트 체계

| ID | 항목 | 검증 |
| --- | --- | --- |
| F-60 | `ptr_table`/`ptr_layouts`는 패닉 정리용이 아니라 스택 재할당 때 스택 포인터를 패치하는 용도다. 이 학습 가이드의 초기 브리프도 이를 잘못 짐작했고 04, 05, 06, 07장이 각자 코드로 바로잡았다 | 챕터 재현 [06](06-memory-ownership.md), [05](05-vm-runtime.md) |
| F-61 | 죽은 코드: `src/fiber.zig`(import 없음, `vm.h`의 `Fiber`도 잔재), `src/map.zig`(사용자 `Map`은 `core.cy`의 `HashMap`), `src/jit/`, `llvm_gen.zig`, `ByteCodeBuffer.clear()`(없는 필드 참조), `consts`/`getOrPushConst`, `labels`/`push_label`, `elseBlocks`, `ir.zig`의 `visitStmts`(913~1139)와 낡은 주석(20, 802), sema가 만들지 않는 IR 코드 9종, `compiler.zig:560-571`(없는 `cy.generics`를 참조) | 챕터 재현 [04](04-bytecode-gen.md), [03](03-sema-and-ir.md), [06](06-memory-ownership.md), [07](07-coroutines-concurrency.md) |
| F-62 | `bytecode.zig`의 `write_inst` 덤프가 1바이트 명령어 시절 위치를 쓴다. 뒤로 가는 `jump`가 `jmp @65674`로 찍히고(실제 138), `is_zero`, `lnot`, `sext`, `zext`, `unwrap_nz`, `new`, `trait`, `release`, `call_trait`, `fn_union`, `gen_next`의 오른쪽 피연산자가 다음 명령어의 opcode 번호로 나온다. 덤프를 읽을 때 이 명령어들은 믿지 말 것 | 챕터 재현 [04 §7](04-bytecode-gen.md), [05](05-vm-runtime.md) |
| F-63 | 트레이스 로그의 `main stack size: 43690`(0xAAAA)은 실제 값이 아니다. `popProc` 뒤에 읽어서 Zig 0.17 `ArrayList.pop`이 `undefined`로 덮은 슬롯을 읽는다(원인은 추정, 위치 `bc_gen.zig:630`) | 챕터 재현 [05](05-vm-runtime.md) |
| F-64 | behavior-test는 파일을 자동 발견하지 않고 `behavior_test.zig`의 수작업 목록(경로 284개)으로 돈다. `src/test`의 .cy 303개 중 20개가 목록 밖이다(통과하는 2개 포함). 죽은 테스트: `gc_reference_cycle_*.cy`, `default_memory.cy`, `table.cy`는 0.3 문법이라 ParseError, `scope_return_too_ephemeral_error.cy`는 미등록, "Unreachable statement." 테스트는 등록이 빠졌고 검사 자체가 `sema.zig:381`에서 주석 처리 | 챕터 재현 [08 §2.8](08-embedding-builtins-tests.md), [06](06-memory-ownership.md), [03](03-sema-and-ir.md) |
| F-65 | 문서와 코드의 차이: `docs/build.md`의 `test-trace`는 실제로 `trace-test`. 안전/샌드박스 모드 플래그는 소스에 없다(`ct_inline.zig:146` 주석뿐). docs의 Attributes 절은 비어 있다. `Sendable` 목록과 `@send`가 받는 타입(int 계열과 str뿐)은 문서보다 훨씬 좁다. `Future.get`, `aio` 모듈은 없다. `^T -> Object` 암시적 캐스트는 문서에만 있다. 타입 임베딩은 문서에 Planned라 적혔지만 동작한다 | 챕터 재현 [07](07-coroutines-concurrency.md), [08](08-embedding-builtins-tests.md), [02](02-symbols-and-types.md) |
| F-66 | `docs/history/embedding_cli.md`의 C API "101개"는 현재 `cyber.h` 기준 113개 선언이다. 같은 문서의 `int` 64비트 전환 순서 서술은 `94bade94`(힙 박스 `struct Int`)와 `cfe806d9`(태그 없는 BITCAST)로 나뉜다 | 챕터 재현 [08](08-embedding-builtins-tests.md), [02](02-symbols-and-types.md) |

## F. 표준 라이브러리, 리터럴, 코드젠의 동작 오류 (00, 01장에서 발견)

LLM이 쓴 스크립트가 가장 먼저 닿을 만한 곳이다. 모두 문법이 정상인데 결과가 틀리거나 멈춘다.

| ID | 증상 | 위치 | 검증 | 영향 | 첫 걸음 |
| --- | --- | --- | --- | --- | --- |
| F-70 | `[]T.index(needle)`이 끝나지 않는다. `xs := []int{3, 1, 2}; print(xs.index(1))`가 무한 대기. `self[..]`가 다시 Slice를 돌려줘 자기 자신을 부른다. `contains`는 정상 | `core.cy:1293-1294` | 메인 재현(4초 타임아웃) + [00 §7.3](00-language-tour.md) | 높음 | 첫 기여로 적당(수정이 작음) |
| F-71 | `int.parse('-5')`가 `error.InvalidCharacter`. `-`를 만나 부호를 뒤집은 뒤 `else` 없이 숫자 검사로 떨어진다. `int.parse('')`은 에러 대신 `0`, `int('abc')`는 오류 없이 `0` | `core.cy:476-482`, `:417` | 메인 재현(`-5`와 빈 문자열) + [00 §7.3](00-language-tour.md)(`int('abc')`는 챕터 재현) | 높음 | 첫 기여로 적당 |
| F-72 | `Map.keys()`를 부르면 컴파일 에러(`Undeclared variable @iterator`). 옛 문법 `@iterator()`/`@next(&iter)`가 남았다 | `core.cy:2362-2367` | 메인 재현 | 중간 | 새 반복자 문법으로 이식 |
| F-73 | `&&` 수신자 메서드에서 구조체의 `Array` 필드를 바꾸면 틀린 결과가 나온다. `fn (&&D) push(x int): self.items << x`를 세 번 부르면 3이 아니라 1. 필드 앞에 다른 필드가 있으면 segfault. 에러 없이 틀린 답이 나온다 | 원인 후보: bc_gen의 "빌림 매개변수를 거친 필드 주소 취하기"(`addr %7 = *%4`가 포인터 슬롯의 주소를 필드 시작으로 쓴다). 추정 | 메인 재현(`1`) + [00 §7.3](00-language-tour.md) | 치명 | 최소 재현 → `cyber compile`로 `addr`/`load_64` 비교 → [04](04-bytecode-gen.md)의 `gen_field` |
| F-74 | `^Dyn[Trait]` 값을 `[]T`/`Array`/`ArrayStore`에 넣으면 죽는다(`xs += d`). ReleaseSafe는 `integer overflow`, 트레이스 빌드는 `Double free` | `@copy` 경로(추정) | 챕터 재현 [00 §7.3](00-language-tour.md) | 높음 | |
| F-76 | 64비트를 넘는 정수 리터럴이 에러 없이 wrap된다. `9223372036854775808`이 `-9223372036854775808`, `18446744073709551615`가 `-1`로 출력된다. 모델이 큰 수(ID, 타임스탬프 나노초 등)를 쓰면 조용히 틀린 값이 된다 | 정수 리터럴 처리(토크나이저 또는 sema, 위치 미확인) | 메인 재현 + [00 §7.3](00-language-tour.md) | 높음 | 범위 검사를 추가해 컴파일 에러로 |
| F-77 | `!else \|err\|:` 블록이 끝에서 빠져나가지 않으면 `Expected unreachable block end.`. 문서의 case fallthrough 예제(본문 없는 `case 100`)는 `Unexpected indentation.`으로 파싱 실패. `{1,2,3}`은 목표 타입이 없으면 `TODO: infer tuple type`. `int(enum)`은 컴파일 에러. 문서의 `Func(FN)`은 실제로 `Func[FN]` | `docs/docs.md` 해당 절들 | 챕터 재현 [00 §7.2](00-language-tour.md) | 중간 | 문서 정정 |
| F-78 | 토크나이저 쪽 작은 결함: `tokenizer.cy:408`은 `:=` 뒤 `advance`가 빠져 `=` 토큰이 중복된다(`cy.parse` 경로). `struct := 1`은 통과하는데 `scope := 1`은 거부된다(예약어 취급 불일치). 열 번호는 바이트 기준이라 한글이 앞에 있으면 캐럿이 어긋난다. 오류 복구가 없어 첫 오류만 보고한다 | `src/tokenizer.cy:408`, `src/tokenizer.zig` | 챕터 재현 [00](00-language-tour.md), [01 §7](01-pipeline-front-end.md) | 낮음 | |
| F-75 | `print(slice)`는 내용 대신 `[]int`를 찍고 `dump(x)`는 값 대신 타입 구조를 찍는다. 정수 값 실수는 소수점 없이 출력(`add[float](1, 2)`가 `3`) | `core.cy`의 print 변환 | 챕터 재현 [00 §7.2](00-language-tour.md) | 낮음 | 2026-11-04 `print`(`6f46a8aa`) · `dump`(`dump_str` 손질)가 값을 찍도록 수정(`docs/decisions/project_print_string.md`). 실수 표시는 그대로 |

## 우선순위 한 장 요약

에이전트 루프 용도에서 먼저 막아야 하는 순서(제안이다. 공식 로드맵은 [09장](09-agent-loop-and-roadmap.md)).

1. 호스트가 죽는 경로: F-03, F-04, F-06, F-08, F-09, F-10, F-11, F-12, F-40
2. 조용한 오답: F-01, F-20, F-21, F-22, F-23, F-24, F-73
3. 상태가 깨지는 경로: F-05, F-07, F-14, F-25, F-26
4. 표준 라이브러리와 리터럴에서 LLM 스크립트가 바로 닿는 곳: F-70, F-71, F-72, F-74, F-76
5. 정리: F-50~F-54, F-60~F-66, F-75, F-77, F-78

F-01(제너레이터), F-20(cte), F-73(`&&` 수신자의 필드 변경)은 "컴파일은 되고 실행도 되는데 답이 틀리는" 종류라서, 에이전트가 쓴 스크립트의 결과를 신뢰하는 모든 설계에 직접 위험하다.
