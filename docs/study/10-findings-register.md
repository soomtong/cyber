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
> 2026-11-06 갱신: `b40531a1..db9f636d`(50개 커밋)에서 고쳐진 항목에 커밋 해시를 적고, 코드가 옮겨간 항목에는 현재 줄 번호를
> "현재 …" 로 덧붙였다. 표의 원래 줄 번호는 b40531a1 기준 그대로다. 표 밖에서 고친 것은 G절에 있다.

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

처음 작성 때는 수정을 하나도 하지 않았다(src 불변). 각 항목의 "첫 걸음"은 제안이다. 이후 고쳐진 항목은 "첫 걸음" 칸에 날짜 · 커밋 해시를 적었다.

## A. 호스트를 죽이거나 상태를 깨는 것

| ID | 증상 | 위치 | 검증 | 영향 | 첫 걸음 |
| --- | --- | --- | --- | --- | --- |
| F-01 | 제너레이터 본문의 지역 변수가 yield를 넘어 보존되지 않는다. `i := 10; yield i; i += 1; yield i; i += 1; yield i`가 10, 11, 11을 낸다. `for 0..3 \|i\|`는 소비 측에서 다른 호출이 끼면 무한 루프 | `bc_gen.zig:2345`(ret_gen), `vm.c:1415`(RET_Y에 되돌려 저장 없음), `thread.zig:17` | 메인 재현 + [07 §2.4](07-coroutines-concurrency.md) | 치명 | 2026-11-04 수정 `a2236c78`(`ret_gen` 프레임 저장 · `RET_Y` 되저장 · 재개 시 스택 검사) · `07e66fad` · `5d78b14f`, `project_coroutines.md`의 "제너레이터 프레임 보존 수정". 재현 코드가 10, 11, 12를 낸다 |
| F-02 | yield를 넘는 관리 타입 지역(str 등)이 있으면 segfault | F-01과 같은 원인 | 챕터 재현 [07 실습 4](07-coroutines-concurrency.md) | 치명 | 2026-11-04 수정 `a2236c78` + `3422e526`(yield · 생성기 `return` 값에 `semaOwn`). `generator.cy`와 lib 테스트가 관리 타입 지역을 덮는다 |
| F-03 | 제너레이터 안에서 panic이 나면 언와인드가 죽고 호스트 프로세스가 abort한다. `meta.stack_trace()`도 같다 | `thread.zig:1006~1009`(gen 분기가 반환 슬롯 1개를 가정), `recordCurFrames` | 메인 재현(ReleaseSafe CLI: `integer does not fit in destination type`) + [07 §2.5](07-coroutines-concurrency.md). 트레이스 빌드에서는 메시지가 `incorrect alignment`로 다르다 | 치명 | 2026-11-04 수정 `c8d85d6f`(`FrameInfo.prev_context()` · `prev_fp_slot()`이 `Generator.prev_fp`를 따라감) · `0ea223d9`(`meta.stack_trace`). 제너레이터 안 panic이 `panic: boom`과 프레임을 찍는다 |
| F-04 | 첫 eval이 컴파일에 실패하면 다음 eval에서 SIGSEGV(구문 오류) 또는 `@program_init has already been declared`(의미 오류). 우회: 빈 소스를 먼저 eval하거나 실패 뒤 `cl_vm_reset` | `compiler.zig:310`(`cont`는 첫 성공 뒤에만 true) 근처로 추정 | 챕터 재현 [08 §7.3](08-embedding-builtins-tests.md). 원인은 코드 판독 | 치명 | 2026-11-08 수정 `f5f2d241`. 추정이 맞았다. 실패한 첫 컴파일은 core 타입 · core 청크 · main 청크를 반쯤 만든 채 `cont=false`로 남기고, 다음 컴파일이 core를 다시 올렸다. `cont`를 중간에 true로 바꾸는 것만으로는 부족했다(core 청크의 sema · 코드 생성이 `chunk_start` 뒤 범위에만 돌아 `No such field` panic). 지금은 `Compiler.first_compile_failed`를 세우고 다음 `VM.eval`이 `resetVM()`으로 처음부터 시작한다(fuel · 스택 상한 · printer · user data는 유지). 둘째 구멍: 성공 뒤 실패한 eval의 선언(`fn broken`, 바이트코드 없음)이 `persist_main` alias로 넘어가 다음 호출에서 SIGSEGV. `last_compile_failed`면 실패한 main 청크 자신의 선언은 넘기지 않고 이전 eval에서 물려받은 alias만 넘긴다. lib-test `Evals after a failed first compile.`(구문 오류 2회 · 의미 오류 · 다른 uri · `cl_vm_validate` · `persist_main` REPL 시나리오, 누수 검사 allocator) |
| F-05 | `cl_vm_validate`/`cl_vm_compile`이 VM을 리셋해 `persist_main` 변수를 지운다. validate가 구문 오류로 실패하면 이후 eval이 깨지고 요약 조회가 SIGBUS | `vm.zig` `VM.compile`의 resetVM 호출(validate가 거침) | 챕터 재현 [08 §7.3](08-embedding-builtins-tests.md) | 높음 | 2026-11-08 수정 `707b03e1`. `VM.validate`가 reset 없이 현재 세션 위에 cont 컴파일하고 실행하지 않는다. 검증한 소스의 선언은 `Compiler.main_discarded`로 다음 eval에 넘기지 않는다(실패한 컴파일과 같은 규칙). 코드 생성은 하고, 검증이 처음 로드한 모듈의 `@init` · extern 바인딩은 `Chunk.rt_ready` · `rt_inited`로 다음에 도는 프로그램이 대신 한다. SIGBUS 쪽은 F-04 수정이 먼저 막았다. `cl_vm_compile`은 전체 프로그램 컴파일이라 그대로 reset(헤더에 명시). lib 테스트 `cl_vm_validate checks against the session without resetting it.`, `docs/decisions/project_vm_validate.md` |
| F-06 | 스크립트가 `use c` 없이 `p := as[Ptr[int]] 8; print(p.*)`로 임의 주소를 역참조해 프로세스를 죽인다 | `as[Ptr[T]]` 캐스트 sema | 메인 재현(`Segmentation fault at address 0x8`) + [08 §7.4](08-embedding-builtins-tests.md) | 치명 | 2026-11-08 `534a0a9d`. 컴파일 옵션 `deny_raw_ptrs`(`CLEvalConfig` · `CLCompileConfig`, 기본 false)를 켜면 표준 모듈이 아닌 청크의 식이 `Ptr[T]` · `PtrSpan[T]` · `?Ptr[T]` 타입이면 `Raw pointer type ... is not allowed.` 컴파일 오류(`sema.check_raw_ptr`). `Ptr[int](8)` · `as[Ptr[int]] &x` · `alloc(int)` · `PtrSpan[int]{length=4}`도 막힘. `docs/decisions/project_deny_raw_ptrs.md`. CLI 기본은 그대로 열림 |
| F-07 | 비-main 스레드의 `await`가 `@panic("TODO")`로 프로세스를 죽인다. 스레드 panic의 원래 메시지는 사라지고 `Spawned thread did not finish.`만 남는다 | `vm.zig`의 zAwait | 코드 판독 + [07 §2.6](07-coroutines-concurrency.md) | 높음 | 2026-11-08 수정 `56af553f`. spawn된 스레드의 `await`도 main처럼 블록하고, 기다리는 스레드(main 포함)는 큐에 쌓인 스레드 작업을 직접 실행해 풀이 가득 차도 교착하지 않는다(`Pool.run_queued_task`). 스레드 panic 메시지는 공유 상태(`FutureSyncState`)로 전달되어 `Spawned thread panicked: boom`이 된다(중첩이면 겹침). VM 해제 때 worker 스레드를 멈추고 join한다(이전에는 해제된 풀 위에서 잠든 채 남아 다음 VM이 깨우면 세그폴트). behavior `concurrency/spawn.cy`(중첩 · 깊이 30 체인 · 팬아웃), lib `Spawned threads stop with the eval and do not abort the host.`, `docs/decisions/project_spawn_nested_await.md` |
| F-08 | 컴파일러의 `std.debug.panic` 경로가 호스트를 abort시킨다. 알려진 사례: 한 함수에 지역 변수 257개(256개는 통과) | `sema.zig:3416`(`LocalVarS.id`가 u8, 현재 `sema.zig:50` 선언, 검사는 `checkLocalLimit` · `checkParamLimit` · `checkArgLimit` · `checkFieldLimit` 약 3395~3430) | 메인 재현(`integer does not fit in destination type`) + [03 §7](03-sema-and-ir.md) | 치명 | 2026-11-08 수정 `04096230`. u8 폭은 그대로 두고 sema가 한계를 컴파일 오류로 보고한다: 한 함수(main 포함)의 IR 지역(매개변수 · 숨은 임시 포함) 256개 초과는 `Too many local variables.`, 매개변수 255개 초과(함수 · 람다 · 함수 타입, `FuncSig.numParams` · `Proc.numParams`가 u8)는 `Too many parameters.`, 구조체 필드 255개 초과(init `nargs` · 필드 `idx`가 u8)는 `Too many fields.`, C 가변 인자 호출의 인자 255개 초과는 `Too many arguments.`. 같은 계열이던 매개변수 257개(`numParams += 1` overflow · 호출 `nargs` 캐스트)와 필드 300개 init도 같이 막았다. 테스트 `functions/too_many_locals_error.cy` · `types/struct_too_many_fields_error.cy` · lib-test `Compiler limits are compile errors, not panics.`(경계값 255 · 256은 정상 실행 확인) |
| F-09 | 같은 계열의 다른 한계: 루프 본문 `s += 1` 9000줄 이상, if 본문 17000줄 이상, 점프 오프셋 `int16_t`(앞 점프가 32767단위를 넘으면 런타임 크래시) | `bc_gen.zig`의 점프 패치, `vm.c:867`(현재 861, 여전히 `int16_t`) | 챕터 재현 [04 §5](04-bytecode-gen.md), [05 §5 실습 6](05-vm-runtime.md) | 높음 | 2026-11-08 수정 `8560b025`. `chunk.zig` `checkJump`가 패치 때 거리를 재서 `Function body too large. A jump can span at most N bytecode slots.` 컴파일 오류(`jump` · `break` · `continue`는 32767, `jump_f` · `jump_t`는 65535). 폭은 그대로. lib-test `Jumps past the one-slot offset are compile errors` |
| F-10 | 스택 포인터 패치 구멍. 스택이 재할당될 때 main 프레임의 `&x`, `call_ptr`/`call_union`로 부른 호출 중의 포인터는 갱신되지 않아 쓰레기를 읽는다 | `thread.zig:890`(init 프레임 미패치, 현재 902), `bc_gen.zig:3127`(ptr_table은 call/call_host만, `call_ptr` · `call_union`은 현재 2125 · 2151) | 챕터 재현 [04 §7](04-bytecode-gen.md), [05 §7](05-vm-runtime.md) | 치명 | 2026-11-08 수정 `c94f1569`. `growStackPrecise`가 main(`.init`) 프레임도 패치하고, `gen_call_ptr` · `gen_call_union` · `gen_call_trait`가 `push_site_ptr_layout`으로 `ptr_table` 항목을 남긴다. behavior 테스트 `functions/stack_grow_ptr_patch.cy`, `docs/decisions/project_stack_ptr_patch.md`. (`a2236c78`은 `gen_next` · `gen_end`만 더했었다) |
| F-11 | `g := math.sqrt; g(16.0)`처럼 호스트 함수를 함수 값으로 쓰면 segfault. `addr \| (1<<63)`가 정의되지 않은 시프트라 컴파일러가 대입을 지운다 | `vm.c:1718`(FN_HOST, 현재 1695) | 챕터 재현 [05 §5 실습 6](05-vm-runtime.md) | 높음 | 2026-11-06 수정 `dfaab96a`(`vm.c` `FN_HOST`가 `(u64)1 << 63`, 현재 1704). `g := math.sqrt; g(16.0)`이 `4`. 테스트 `modules/math.cy` |
| F-12 | `#[generator]` 밖에서 `yield`를 쓰면 컴파일러가 segfault | `sema.zig:711`(현재 724) | 챕터 재현 [07 §7.1](07-coroutines-concurrency.md) | 높음 | 2026-11-04 수정 `3aa5b400`(컴파일 오류, 테스트 `concurrency/yield_outside_generator_error.cy`) |
| F-13 | 끝난 제너레이터에 `next()`를 한 번 더 부르면 릴리스 CLI가 `unexpected 4`만 찍는다. `gen_next`/`gen_end`에 debug sym이 없다(추정) | `bc_gen.zig:720, 733` | 챕터 재현 [07 §2.5](07-coroutines-concurrency.md) | 중간 | 2026-11-04 수정 `a2236c78`(`pushFCode`로, 현재 `bc_gen.zig:719` · `734`). `panic: Generator is already done.`을 찍는다 |
| F-14 | 빌림 `&int` 매개변수를 받는 제너레이터는 힙 스냅샷에 스택 주소를 담아 use-after-return이 된다. 컴파일 에러가 없다 | sema의 `semaLift` 우회 | 챕터 재현 [07 실습 8](07-coroutines-concurrency.md) | 높음 | 2026-11-08 수정 `a7418c29`. `#[generator]` 함수의 `borrow_only` 매개변수(`&T` · `[&]T` · 빌림 필드 구조체 · `&self` 수신자)는 `A \`#[generator]\` function can not take the borrow type ... as a parameter.` 컴파일 오류. 같이 발견한 구멍으로 `?&T`가 빌림으로 취급되지 않아 lift · `scope` 없는 반환 · 제너레이터 매개변수를 모두 통과했는데, Option이 자식의 `borrow_only`를 물려받게 했다(core `Option.@init`에 `scope`). behavior `concurrency/generator_borrow_param_error.cy` · `generator_borrow_option_param_error.cy` · `memory/lift_borrow_option_error.cy`, `docs/decisions/project_generator_borrow_params.md` |
| F-79 | 부분 이동 뒤 옮겨 나간 멤버에 재대입(`a := move p.a; p.a = Res{name='a2'}`)이 컴파일되지만 멤버 상태를 되살리지 않는다. `set_field`가 이미 `a`로 옮겨 간 옛 값을 파괴해 `Res.@deinit`이 두 번 돌고(재대입 시점 · `a`의 블록 끝), 새 값 `a2`는 상태가 죽은 채라 `@partial_destruct`가 건너뛰어 누수된다. 대입 뒤 `p.a` 읽기는 여전히 `Member is no longer alive.` | `sema.zig` `semaAssignStmt`의 `.value_field` 분기(죽은 멤버 검사 · 상태 복원 없음) | 메인 재현(`deinit a` 2회, `deinits=3`, `a2` 없음) + [06 §7.1 19번 · Q9](06-memory-ownership.md) | 치명 | 죽은 멤버 대입을 읽기와 같은 규칙으로 컴파일 오류로 막거나, Rust처럼 되살린다(`set_field`를 옛 값 파괴 없이 내보내고 상태 칸을 true로). `docs/decisions/project_partial_move.md` 설계 메모 |

## B. 조용히 틀린 결과를 내는 것

| ID | 증상 | 위치 | 검증 | 영향 | 첫 걸음 |
| --- | --- | --- | --- | --- | --- |
| F-20 | 컴파일타임 평가(cte)가 복합 대입(`+=` 등)을 버린다. 같은 함수가 런타임에서는 15, `const x = f()`에서는 5. `for 0..10 \|i\|: total += i`를 const로 평가하면 45 대신 9 | `cte.zig:423`(변수), `cte.zig:460`(벡터 원소) | 메인 재현(15와 5) + [03 §7.1](03-sema-and-ir.md) | 치명 | 2026-11-08 수정 `02f39e67`. `eval_assign_right`가 세 분기(`ct_var` · `deref` · 벡터 원소) 모두에서 `left op right`를 평가하고 목적지 타입을 검사한다. 컴파일 타임 벡터 원소 읽기(`v[i]`, 이전 `TODO ct_var`)를 추가했고 범위 밖 인덱스는 `Index out of bounds.` 컴파일 오류. cte가 지원하지 않는 연산(`float`의 `+` 등)은 조용히 버리지 않고 `Unsupported inline eval` 오류. 테스트 `meta/ct_op_assign.cy` · `meta/ct_vector_index_error.cy`, `docs/decisions/project_cte_op_assign.md` |
| F-21 | 오버로드는 선언 순서대로 처음 성공하는 후보를 고른다. `float` 오버로드를 먼저 선언하면 `int` 인자도 `float` 쪽으로 간다. 파라미터가 같고 반환만 다른 오버로드도 에러 없이 통과 | `sema_func.zig`(롤백 TODO는 653) | 메인 재현(`show(n)`이 `float`) + [03 §7.1](03-sema-and-ir.md), [02 §5](02-symbols-and-types.md) | 높음 | 2026-11-08 수정 `cf4aa84a`. 1단계로 암시적 변환 없이 매개변수 타입이 그대로 맞는 후보(정수 리터럴은 `int` · `raw` 매개변수에만)를 선언 순서와 무관하게 고르고, 없으면 2단계로 이전 동작(선언 순서 · 암시적 변환). 매개변수가 같고 반환만 다른 오버로드는 선언 시 `X has already been declared with the same parameters.` 컴파일 오류. 테스트 `functions/call_overload_exact.cy` · `call_overload_ret_only_error.cy`, `docs/decisions/project_overload_exact_match.md`. 롤백 TODO는 그대로 |
| F-22 | trait 구현 검사가 파라미터 타입 불일치를 무시한다(trait는 `k float`, 구현은 `k int`가 컴파일). `Dyn`으로 부르면 값이 깨진다. 파라미터가 trait보다 적으면 컴파일러가 index out of bounds로 죽는다 | `types.zig:625~640`(`get_trait_method_impl`의 안쪽 `for`의 `continue`, 현재 609 · 루프 626~630) | 메인 재현(컴파일되고 실행됨) + [02 §5](02-symbols-and-types.md) | 높음 | 2026-11-08 수정 `40bfa711`. `get_trait_method_impl`이 매개변수 개수 · 모든 매개변수 타입 · 반환 타입이 정확히 같은 메서드만 구현으로 채택한다(안쪽 `for`의 `continue`가 바깥 `while`에 걸리지 않던 것, 길이 검사 없음). 세 경우(타입 불일치 · 적은 매개변수 · 많은 매개변수) 모두 `X does not implement fn ... from Trait.` 컴파일 오류. 이 검사로 `os.File`이 `io.Writer`의 `write([&]byte)`를 구현하지 않은 것이 드러나 추가(`Dyn[io.Writer]` 회귀는 `modules/os.cy`). 테스트 `types/trait_param_type_error.cy` · `trait_param_count_error.cy` · `trait_param_extra_error.cy` |
| F-23 | 템플릿 캐시 비교가 틀리다. 비-Type 매개변수에서 조기 return해 `Buf[1,47]`이 `Buf[1,45]`로 조용히 대체된다 | `template.zig:189~224` | 챕터 재현 [02 §5](02-symbols-and-types.md) | 높음 | 2026-11-08 수정 `1ec8d581`. `VariantKeyContext.eql`이 비-Type 매개변수(`int` · `EvalInt` · `EvalStr` · 함수 시그니처 · 함수 심볼 · enum)에서 다르면 false, 같으면 다음 매개변수로 넘어간다. 함수 템플릿 캐시도 같은 문맥이라 함께 고쳐짐. 테스트 `types/template_const_params.cy`(`Buf[1, 1..59]` 크기 · 타입 동일성) |
| F-24 | 문자열 리터럴이 65536바이트 이상이면 길이가 잘린다(65536 → 0, 70000 → 4464). 길이가 `const_str`의 16비트에 들어간다 | `bc_gen.zig:1272`(현재 1489~1494 `pushConstString`, `len << 48`) | 메인 재현(70000 → 4464) + [04 §7](04-bytecode-gen.md) | 중간 | 2026-11-08 수정 `10f8290b`. `pushConstString`이 65535바이트 초과를 `String literal too long. A string literal can have at most 65535 bytes.` 컴파일 오류로 보고(보간 문자열의 조각도 같음). 인코딩은 그대로. lib-test `String literals past 65535 bytes are compile errors` |
| F-25 | 빌림 검사 구멍. `Local.parent_local`이 대입되지 않아 `active_borrows` 감소가 죽은 코드라 `r := &a; a.append(4)`가 막힌다(과잉 거부). 반대로 `&&`를 먼저 쥐고 `&`를 나중에 만들면 통과하고, 블록을 벗어난 빌림 재대입도 못 막는다(과소 거부) | `sema.zig:322`, `:4926`(현재 4982, `parent_local`은 `cy.NullId`로만 초기화) | 챕터 재현 [06 §7.1](06-memory-ownership.md) | 높음 | 2026-11-08 수정 `77d3e881`. 모델을 `docs/decisions/project_borrow_model.md`에 적고 구현: 지역에 저장된 빌림만 세고(`bindBorrowLocal`, 공유 · 배타 계수 2종) 블록이 끝나면 푼다. 인자로 넘긴 빌림은 문장과 함께 끝나 `peek(&a); a.append(4)`가 통과. `&&`가 살아 있는 동안 `&` · `&self`는 `Cannot borrow \`a\`. There is an active exclusive borrow to it.`, 같은 호출의 `&&a`와 `&a[0]`는 순서 무관하게 오류, 재대입은 `\`ref\` can not outlive \`b\`.`. 수명은 어휘적이라 같은 블록의 `elem := &a[2]; a << 4`는 여전히 오류(매뉴얼을 모델대로 고침). 이 검사가 core `Wyhash.final`의 실제 use-after-scope(`input = scratch[0..16]`)를 드러내 고쳤다 |
| F-26 | `Array.append(val T)`가 복사해서 `@deinit`이 원소마다 3번 돈다. NoCopy 원소는 append 불가. `Array.clone()`은 없는 필드 때문에 컴파일되지 않고 `ArrayStore.append(slice)`는 블록이 두 번 실행된다 | `core.cy`(현재 `Array.append` 1888, `Array.clone` 1912, `ArrayStore.append(slice)` 1712) | 챕터 재현 [06 §7.1](06-memory-ownership.md) | 높음 | 2026-11-08 수정 `3979bb13`. `append` · `insert`가 `@ptr_init(…, move val)`로 매개변수를 옮기고(`^T` · 함수 값은 호출자 관리라 retain 유지), `ensure_cap`은 `@memcpy`로 원소를 옮겨 복사 생성자 · 파괴자를 부르지 않는다. 실습 6의 `deinit` 3회가 1회(배열이 죽을 때)로. `clone`은 `header = length`, `ArrayStore.append(slice)` 중복 블록 삭제. `NoCopy` 원소는 다른 복사 메서드(`init(val T)` 채우기 등) 때문에 여전히 `Array[R]{}`부터 컴파일되지 않는다(결정 문서 "남은 것"). behavior `memory/array_append_move.cy`, `docs/decisions/project_array_append_move.md`. `90fafc1f`는 ArrayStore 순회만 더했었다 |
| F-27 | 구조체 필드(`str` 포함)를 가진 관리 구조체의 `move f.b`(부분 이동)가 `core.cy:2849`의 컴파일타임 `if \|x\|` 미지원으로 컴파일되지 않는다. 문서의 예제가 이 형태 | `core.cy:2849`(현재 2954) | 챕터 재현 [06 §7.1](06-memory-ownership.md) | 중간 | 2026-11-08 수정 `19873949`. `ct_inline`이 `#if <opt> \|x\|:`를 지원한다. 같이 드러난 것: 템플릿의 `#partial_destruct` 오타, `?PartialStructLayout`(zero-union 옵션) 해제가 포인터를 힙 객체로 release, 멤버 읽기 검사가 `state_offset` 대신 필드 색인을 더해 중첩 멤버 이동 뒤 형제 거부, 멤버 통째 이동이 첫 상태 칸만 비활성(이중 해제), 부분 이동된 값의 통째 복사 · 빌림 · 이동 미검사. 상태 모델: `@deinit` 없는 구조체 필드만 하위 상태를 펼치고 `str` 등 `@deinit` 있는 타입은 상태 하나로 통째로만 이동(`Cannot move a member out of \`Res\`...`), 통째 사용은 `Cannot copy|borrow|move a partially moved value.`. 테스트 `memory/partial_move_struct_fields.cy` + 오류 4종, `docs/decisions/project_partial_move.md` |
| F-28 | `type X const:`의 결과 타입 이름이 덮어써진다(`IntBox`가 `Pick[int]`로 개명). `const` 매개변수로 `bool`, `EvalStr`, enum을 쓰는 타입 템플릿은 컴파일러 패닉 | `sema_type.zig:27~30`, `template.zig` | 챕터 재현 [02 §5](02-symbols-and-types.md) | 중간 | 이름 덮어쓰기는 2026-11-04 수정 `ab8163bc`(`resolve_type_const`가 본문이 만든 타입만 개명, 테스트 `meta/type_const.cy`). `bool` · `EvalStr` · enum `const` 매개변수 패닉은 2026-11-08 수정 `bb5d1a05`(해시 · 비교에 `bool` · 모든 폭 정수, 이름 출력을 `writeTemplateParam` 하나로, `EvalStr` 인자 이중 해제 수정, 지원 밖 타입은 컴파일 오류. 테스트 `types/template_const_param_kinds.cy` · `template_const_param_type_error.cy`, `docs/decisions/project_template_const_params.md`) |
| F-29 | 정상 종료 시 전역 `@deinit`이 main 지역보다 먼저 돈다. `single_run`/panic의 `freeHeapPages` 스윕은 `@deinit`을 한 번도 돌리지 않는다 | 종료 경로 | 챕터 재현 [06 §7.1](06-memory-ownership.md) | 중간 | 2026-11-08 순서 수정 `19873949`. `sema_program`이 main 지역을 선언 역순으로 먼저 정리한 뒤 `@program_deinit`을 부른다(`return`과 같은 순서). `single_run` · panic 스윕이 `@deinit`을 돌리지 않는 것은 계약으로 문서화(매뉴얼 Deinitializers 절, `docs/decisions/project_program_deinit_order.md`). 릴리스 CLI는 ReleaseSafe라 `single_run`이 아님. 테스트 `memory/program_deinit_order.cy` |
| F-30 | `-` 가시성이 `fn`, 필드, 변수에서 강제되지 않는다(`use *`에서 `-type` 별칭을 거르는 것이 전부) | `module.zig` | 챕터 재현 [02 §5](02-symbols-and-types.md) | 중간 | 문서와 일치시키거나 문서를 고친다 |
| F-31 | `meta.stack_trace()`가 `pop()`을 두 번 불러 가장 바깥 프레임 두 개를 지운다. `dump_frame`은 `chk_stk`의 `stack_size`를 `+3`에서 읽는다(정답은 `+2`) | `meta.zig:194~195`, `debug.zig:59` | 챕터 재현 [04](04-bytecode-gen.md), [05](05-vm-runtime.md) | 낮음 | `stack_trace` 쪽 2026-11-04 수정 `0ea223d9`(가장 안쪽 호스트 프레임만 뺌, 현재 `meta.zig:188~198`). `dump_frame`의 `+3`은 2026-11-06 수정 `ca4ea5b8`(`debug.zig:59`가 `+2`, locals가 프레임 크기 안에서 끝남). 맨 위(main)에서 부르면 main에 `chk_stk`가 없어 `@program_deinit`의 메타데이터를 읽고 locals가 비는 한계는 남음 |
| F-32 | `try ... else err:`는 파서를 통과하지만 sema가 항상 `Unsupported statement: tryStmt`로 거부한다. 문서의 `catch err:`는 파서 단계에서 거부된다 | `sema.zig`, `docs.md:2667` | 챕터 재현 [03 §7.2](03-sema-and-ir.md) | 중간 | Unwrap block 구현(로드맵 1순위)과 묶는다 |
| F-33 | `cyber -cc`, `-tcc`가 sema 단계에서 `Expected function implementation.`으로 실패한다. `cyber fmt`는 `TODO: Embed src/tools/fmt.cy` panic(종료 134) | `sema.zig:2870`(현재 2849), `main.zig:121` | 챕터 재현 [03](03-sema-and-ir.md), [08](08-embedding-builtins-tests.md) | 낮음 | 용도 범위 밖. 도움말에서 숨길지 결정 |

## C. 자원 제한이 없는 것

| ID | 증상 | 위치 | 검증 | 영향 | 첫 걸음 |
| --- | --- | --- | --- | --- | --- |
| F-40 | 스택 성장에 상한이 없다. 무한 재귀 1초에 최대 RSS 4.5GB. 메모리 한도 API도 없다 | `thread.zig`의 `growStackAuto`(1.5배, 상한 없음, 현재 861~870) | 챕터 재현 [05 §5](05-vm-runtime.md) | 치명 | 2026-11-08 수정 `f03cf24c`. 스레드마다 `stack_limit`(기본 128 MiB, `thread.default_stack_limit`)을 두고 `growStackAuto`가 그 이상 키우지 않는다. 상한에 닿으면 `Stack overflow. The stack limit is N bytes.` panic(`CL_ERROR_PANIC`, VM 재사용 가능). 호스트 API `cl_vm_set_stack_limit(vm, bytes)`(0 이하 무제한, spawn 스레드에 전파). 긴 panic 트레이스는 양 끝 20프레임 + `... N frames omitted ...`. 결정 문서 `project_stack_limit.md`, lib-test `cl_vm_set_stack_limit turns runaway recursion into a panic.`. 힙 한도(F-41)는 별개 |
| F-41 | `CLAllocator`가 Zig `std.mem.Allocator` 배치라 C 호스트가 `cl_vm_initx`로 할당 상한을 걸기 어렵다 | `capi.zig:32-38` | 코드 판독 + [08 §7.4](08-embedding-builtins-tests.md) | 높음 | C 친화적 할당자 훅 추가 |
| F-42 | fuel의 off-by-one. `--fuel < 0`이라 fuel N이면 N번 통과하고 N+1번째 체크포인트에서 멈춘다. 호스트 함수 안에서 막힌 호출은 interrupt로 끊지 못한다 | `vm.c:330-336` | 챕터 재현 [05 §2.7](05-vm-runtime.md), 결정 문서 `project_vm_interrupt.md` | 중간 | 2026-11-06 문서로 확정(코드 그대로): fuel N은 검사점 N개를 통과시키고 N+1번째에서 멈춘다. `cyber.h`의 `Limits each following eval to fuel checkpoints`와 같은 뜻이며 `project_vm_interrupt.md`에 적음. 호스트 함수 안에서 막힌 호출은 `project_tars_agent_runtime_review.md`의 알려진 한계 |
| F-43 | 순환 참조는 수거도 탐지도 없다. `check_memory`는 껍데기이고 릴리스 CLI는 조용히 누수한다. `Weak` 참조가 없다 | `thread.zig:1018`(현재 1025) | 챕터 재현 [06 §5](06-memory-ownership.md) | 중간 | 에이전트 환경에서는 VM 폐기로 정리 |

## D. 임베딩 API와 문서의 불일치

| ID | 증상 | 위치 | 검증 | 영향 |
| --- | --- | --- | --- | --- |
| F-50 | print/eprint 콜백의 첫 인자가 `CLThread*`라고 선언돼 있는데 실제로는 VM 포인터 | `core.zig:1248-1262` | 챕터 재현 [08 §7.3](08-embedding-builtins-tests.md) | 중간 |
| F-51 | 헤더에만 있고 구현이 없는 함수 3개(`clResolveType`, `cl_array_empty_new`, `cl_map_empty_new`), 인자 수가 다른 `cl_type_from_id`, 죽은 매크로(`CL_CUSTOM_TYPE` 등) | `cyber.h` 대 `lib.zig` | 챕터 재현 [08 §7.2](08-embedding-builtins-tests.md) | 중간 |
| F-52 | `cyber.h:383`의 "마지막 표현식 값 반환" 주석이 틀렸다. 값은 `fn main() -> T` 반환으로만 받는다. 컴파일 에러는 첫 리포트만 문자열로 나오고 ANSI 색 코드가 무조건 섞인다 | `debug.zig:345`(ANSI는 현재 325 · 330) | 챕터 재현 [08](08-embedding-builtins-tests.md) | 중간. 일부 수정: 2026-11-04 `f81693f3` · `4e3af453` · `46faf101`로 `persist_main` eval은 마지막 맨 표현식을 `CLEvalResult`로 돌려준다(`project_repl_result.md`). 비-`persist_main`의 주석 · ANSI · 첫 리포트만 반환은 그대로 |
| F-53 | CLI 로더는 내장 소스를 버리고 디스크의 `src/builtins/core.cy`를 읽는다. 릴리스는 실행 파일 옆 `src/`가 필요하다. 라이브러리는 `@embedFile` | `cli.zig` | 챕터 재현 [08](08-embedding-builtins-tests.md) | 낮음 |
| F-54 | 바이트코드 직렬화가 없다. `call_host`가 호스트 함수 주소를 u48 즉시값으로 박아 넣기 때문. 그래서 core 컴파일 비용(VM당 약 3ms)을 캐시로 줄일 수 없다 | `bc_gen.zig:3110`(현재 3556 · 2550) | 챕터 재현 [08 §5.7](08-embedding-builtins-tests.md) | 낮음 |

## E. 문서, 죽은 코드, 테스트 체계

| ID | 항목 | 검증 |
| --- | --- | --- |
| F-60 | `ptr_table`/`ptr_layouts`는 패닉 정리용이 아니라 스택 재할당 때 스택 포인터를 패치하는 용도다. 이 학습 가이드의 초기 브리프도 이를 잘못 짐작했고 04, 05, 06, 07장이 각자 코드로 바로잡았다 | 챕터 재현 [06](06-memory-ownership.md), [05](05-vm-runtime.md) |
| F-61 | 죽은 코드: `src/fiber.zig`(import 없음, `vm.h`의 `Fiber`도 잔재), `src/map.zig`(사용자 `Map`은 `core.cy`의 `HashMap`), `src/jit/`, `llvm_gen.zig`, `ByteCodeBuffer.clear()`(없는 필드 참조), `consts`/`getOrPushConst`, `labels`/`push_label`, `elseBlocks`, `ir.zig`의 `visitStmts`(913~1139)와 낡은 주석(20, 802), sema가 만들지 않는 IR 코드 9종, `compiler.zig:560-571`(없는 `cy.generics`를 참조) | 챕터 재현 [04](04-bytecode-gen.md), [03](03-sema-and-ir.md), [06](06-memory-ownership.md), [07](07-coroutines-concurrency.md). 일부 삭제: 2026-11-04 `bc169c5b`(lib-test가 모든 pub 선언을 참조, `fiber.zig` · `llvm_gen.zig` · `llvm.zig` · `dce.zig` · `ByteCodeBuffer.clear()` · `ir.visitStmts`/`visitExpr`), `a7b51ceb` · `32fab0fa`(`fifo.zig` · `stdx/heap.zig` · `web.zig` · `string.zig` 일부), 2026-11-06 `b4145397`(`src/jit/` · `labels`/`push_label` · `enter_jit` opcode, opcode 수 131; 같은 날 `132d5504`의 `and_64`로 132). 2026-11-06 `7a7ee183`로 나머지 삭제: `src/map.zig`, `vm.h` `Fiber`/`FiberObject`(`cy.Fiber` 별칭 포함), `VM.consts_ptr`/`consts_len` · `Const` typedef · `ByteCodeBuffer.consts`/`consts_boxed`/`constMap`/`getOrPushConst`(VM 구조체는 C · Zig 미러를 같이 줄임), `elseBlocks`, `compiler.zig`의 `resolveCopyCtor`/`resolveFuncTemplate`(`cy.generics` 참조). IR 코드는 `newExpr`/`pushStmt` 등 생성 API 기준으로 다시 세어 sema가 만들지 않는 것은 `StmtCode.set` · `ExprCode.mainEnd` 둘뿐이라 삭제(9종은 과대 추정). 04장이 꼽은 bc_gen의 `selectForDstInst` · `DstInst` · `NoErrInst` · `GenValue.constant`/`initConstant` · `Cstr.none`도 삭제. `ir.zig:20` 주석(C 백엔드 언급)은 설계 배경이라 둠 |
| F-62 | `bytecode.zig`의 `write_inst` 덤프가 1바이트 명령어 시절 위치를 쓴다. 뒤로 가는 `jump`가 `jmp @65674`로 찍히고(실제 138), `is_zero`, `lnot`, `sext`, `zext`, `unwrap_nz`, `new`, `trait`, `release`, `call_trait`, `fn_union`, `gen_next`의 오른쪽 피연산자가 다음 명령어의 opcode 번호로 나온다. 덤프를 읽을 때 이 명령어들은 믿지 말 것 | 챕터 재현 [04 §7](04-bytecode-gen.md), [05](05-vm-runtime.md). 일부 수정: 뒤로 가는 `jump`는 2026-11-04 `7563e3b4`(i16), `is_zero`는 2026-11-06 `15a85a9e`(같은 커밋이 `and_` · `xor` · `lsr` · `ult` · `ugt` · `ule` · `uge`의 빈 덤프도 채움). 나머지(`lnot` · `sext` · `zext` · `fn_union` · `unwrap_nz` · `new` · `trait` · `release` · `release_opt` · `call_trait` · `gen_next`, 추가로 `memsetz`)는 2026-11-06 `ca4ea5b8`로 수정(`Inst`가 u16이라 `pc + 3`이 pc[3]이었음, `vm.c`의 레이아웃대로 `pc[k].val`로). 덤프 피연산자는 이제 믿어도 된다 |
| F-63 | 트레이스 로그의 `main stack size: 43690`(0xAAAA)은 실제 값이 아니다. `popProc` 뒤에 읽어서 Zig 0.17 `ArrayList.pop`이 `undefined`로 덮은 슬롯을 읽는다(원인은 추정, 위치 `bc_gen.zig:630`) | 챕터 재현 [05](05-vm-runtime.md). 2026-11-04 수정 `07e66fad`(`popProc` 앞에서 읽음, 현재 `bc_gen.zig:631`). 추정한 원인이 맞았다 |
| F-64 | behavior-test는 파일을 자동 발견하지 않고 `behavior_test.zig`의 수작업 목록(경로 284개)으로 돈다. `src/test`의 .cy 303개 중 20개가 목록 밖이다(통과하는 2개 포함). 죽은 테스트: `gc_reference_cycle_*.cy`, `default_memory.cy`, `table.cy`는 0.3 문법이라 ParseError, `scope_return_too_ephemeral_error.cy`는 미등록, "Unreachable statement." 테스트는 등록이 빠졌고 검사 자체가 `sema.zig:381`에서 주석 처리 | 챕터 재현 [08 §2.8](08-embedding-builtins-tests.md), [06](06-memory-ownership.md), [03](03-sema-and-ir.md). 2026-11-06 현황: 살아 있는 `run.case` 285개(주석 처리 ), .cy 312개. 새로 등록된 것은 `functions/inline_*.cy` · `inline_addr_param.cy`, `meta/type_const.cy`, `concurrency/yield_outside_generator_error.cy`, `core/ArrayStore.cy`, `core/strings_utf8.cy`, `types/method_mut_self_array_field.cy`(F-73). `functions/jit_func.cy`는 삭제. `scope_return_too_ephemeral_error.cy` · `control_flow/unreachable_error.cy`(`behavior_test.zig:415` 주석) · `gc_reference_cycle_*` · `default_memory.cy` · `core/table.cy`는 그대로, "Unreachable statement." 검사는 현재 `sema.zig:389`에서 여전히 주석 |
| F-65 | 문서와 코드의 차이: `docs/build.md`의 `test-trace`는 실제로 `trace-test`. 안전/샌드박스 모드 플래그는 소스에 없다(`ct_inline.zig:146` 주석뿐). docs의 Attributes 절은 비어 있다. `Sendable` 목록과 `@send`가 받는 타입(int 계열과 str뿐)은 문서보다 훨씬 좁다. `Future.get`, `aio` 모듈은 없다. `^T -> Object` 암시적 캐스트는 문서에만 있다. 타입 임베딩은 문서에 Planned라 적혔지만 동작한다 | 챕터 재현 [07](07-coroutines-concurrency.md), [08](08-embedding-builtins-tests.md), [02](02-symbols-and-types.md) |
| F-66 | `docs/history/embedding_cli.md`의 C API "101개"는 현재 `cyber.h` 기준 113개 선언이다. 같은 문서의 `int` 64비트 전환 순서 서술은 `94bade94`(힙 박스 `struct Int`)와 `cfe806d9`(태그 없는 BITCAST)로 나뉜다 | 챕터 재현 [08](08-embedding-builtins-tests.md), [02](02-symbols-and-types.md) |

## F. 표준 라이브러리, 리터럴, 코드젠의 동작 오류 (00, 01장에서 발견)

LLM이 쓴 스크립트가 가장 먼저 닿을 만한 곳이다. 모두 문법이 정상인데 결과가 틀리거나 멈춘다.

| ID | 증상 | 위치 | 검증 | 영향 | 첫 걸음 |
| --- | --- | --- | --- | --- | --- |
| F-70 | `[]T.index(needle)`이 끝나지 않는다. `xs := []int{3, 1, 2}; print(xs.index(1))`가 무한 대기. `self[..]`가 다시 Slice를 돌려줘 자기 자신을 부른다. `contains`는 정상 | `core.cy:1293-1294`(현재 1386~1387) | 메인 재현(4초 타임아웃) + [00 §7.3](00-language-tour.md) | 높음 | 2026-11-06 수정 `dfaab96a`(`contains`처럼 `self.span().index`로, 현재 1386~1387). 테스트 `core/Slice.cy` · `core/Array.cy` |
| F-71 | `int.parse('-5')`가 `error.InvalidCharacter`. `-`를 만나 부호를 뒤집은 뒤 `else` 없이 숫자 검사로 떨어진다. `int.parse('')`은 에러 대신 `0`, `int('abc')`는 오류 없이 `0` | `core.cy:476-482`, `:417`(현재 558~575, `int(str)`은 510) | 메인 재현(`-5`와 빈 문자열) + [00 §7.3](00-language-tour.md)(`int('abc')`는 챕터 재현) | 높음 | 2026-11-06 수정 `dfaab96a`(앞에서부터 읽고 `-` · `+` 접두는 첫 글자만, 빈 문자열 · 부호만 · 숫자 아닌 글자는 `error.InvalidCharacter`, 현재 558~578). `int('abc')` · `int('')`이 `0`인 것은 `@init`의 `!else 0`이라 그대로. 테스트 `core/ints.cy` |
| F-72 | `Map.keys()`를 부르면 컴파일 에러(`Undeclared variable @iterator`). 옛 문법 `@iterator()`/`@next(&iter)`가 남았다 | `core.cy:2362-2367`(현재 2466~2471) | 메인 재현 | 중간 | 2026-11-06 수정 `dfaab96a`(`self.iterator()` · `self.next(&iter)`, `<<`가 없어 `res = res.append(e.key)`, 현재 2466~2471). 테스트 `core/Map.cy` |
| F-73 | `&&` 수신자 메서드에서 구조체의 `Array` 필드를 바꾸면 틀린 결과가 나온다. `fn (&&D) push(x int): self.items << x`를 세 번 부르면 3이 아니라 1. 필드 앞에 다른 필드가 있으면 segfault. 에러 없이 틀린 답이 나온다 | 원인 후보: bc_gen의 "빌림 매개변수를 거친 필드 주소 취하기"(`addr %7 = *%4`가 포인터 슬롯의 주소를 필드 시작으로 쓴다). 추정 | 메인 재현(`1`) + [00 §7.3](00-language-tour.md) | 치명 | 2026-11-06 `db9f636d`에서 재현되지 않는다(메인 재현: 3을 내고, 앞에 `n int` 필드를 두어도 3 · 7). 고친 커밋은 특정하지 못했다(후보 `d99a8aa9` 역참조 addressable, `38272a0c` 레지스터 필드 접근). 덤프에는 여전히 `addr %7 = *%4`가 보이므로 원래 진단이 틀렸을 수 있다. 회귀 테스트 `types/method_mut_self_array_field.cy`로 고정(2026-11-06) |
| F-74 | `^Dyn[Trait]` 값을 `[]T`/`Array`/`ArrayStore`에 넣으면 죽는다(`xs += d`). ReleaseSafe는 `integer overflow`, 트레이스 빌드는 `Double free` | `@copy` 경로(추정) | 챕터 재현 [00 §7.3](00-language-tour.md) | 높음 | 2026-11-06 수정 `e2a7515d`. 추정이 맞았다: `core.cy` `@copy`의 `.ref_trait` 분기가 `TraitStruct`를 `@copyStruct`로 원시 복사해 impl 객체를 retain하지 않았다(`[]T{...}` 리터럴 임시가 해제되면서 use-after-free, 끝에 이중 해제 → ReleaseSafe `integer overflow`). `@retain(as trait_s.impl)`을 더함. `&Dyn[Trait]`(borrow_trait)는 소유하지 않아 그대로. 테스트 `types/trait.cy` |
| F-76 | 64비트를 넘는 정수 리터럴이 에러 없이 wrap된다. `9223372036854775808`이 `-9223372036854775808`, `18446744073709551615`가 `-1`로 출력된다. 모델이 큰 수(ID, 타임스탬프 나노초 등)를 쓰면 조용히 틀린 값이 된다 | 정수 리터럴 처리(현재 `sema.zig:6463` `.dec_u`가 u64로 파싱해 i64로 `@bitCast`) | 메인 재현 + [00 §7.3](00-language-tour.md) | 높음 | 2026-11-06 수정 `aeded5b1`. 평범한 10진 리터럴은 i64로 파싱해 넘으면 컴파일 오류 `Integer literal does not fit the target type.`(목표 타입이 `int`일 때도 같음, `r64` 목표는 u64 범위). 비트 패턴은 `18446744073709551615u`(`u` 접미) · 16진 · `r64` 목표로 쓴다. 2진 · 8진 · 16진 · 단항 `-`의 64비트 초과도 같은 메시지(이전에는 `Error: Overflow`). 테스트 `core/ints.cy` · `core/int_literal_overflow_error.cy` |
| F-77 | `!else \|err\|:` 블록이 끝에서 빠져나가지 않으면 `Expected unreachable block end.`. 문서의 case fallthrough 예제(본문 없는 `case 100`)는 `Unexpected indentation.`으로 파싱 실패. `{1,2,3}`은 목표 타입이 없으면 `TODO: infer tuple type`. `int(enum)`은 컴파일 에러. 문서의 `Func(FN)`은 실제로 `Func[FN]` | `docs/docs.md` 해당 절들 | 챕터 재현 [00 §7.2](00-language-tour.md) | 중간 | 문서 정정 |
| F-78 | 토크나이저 쪽 작은 결함: `tokenizer.cy:408`은 `:=` 뒤 `advance`가 빠져 `=` 토큰이 중복된다(`cy.parse` 경로). `struct := 1`은 통과하는데 `scope := 1`은 거부된다(예약어 취급 불일치). 열 번호는 바이트 기준이라 한글이 앞에 있으면 캐럿이 어긋난다. 오류 복구가 없어 첫 오류만 보고한다 | `src/tokenizer.cy:408`, `src/tokenizer.zig` | 챕터 재현 [00](00-language-tour.md), [01 §7](01-pipeline-front-end.md) | 낮음 | |
| F-75 | `print(slice)`는 내용 대신 `[]int`를 찍고 `dump(x)`는 값 대신 타입 구조를 찍는다. 정수 값 실수는 소수점 없이 출력(`add[float](1, 2)`가 `3`) | `core.cy`의 print 변환 | 챕터 재현 [00 §7.2](00-language-tour.md) | 낮음 | 2026-11-04 수정 `6f46a8aa`(print · 보간) · `17d61251`(`dump` · `dump_str`) · `b106f0cd`(빌림 `Map` · `Array`), `docs/decisions/project_print_string.md`. 정수 값 실수가 소수점 없이 나오는 것은 그대로 |

## 우선순위 한 장 요약

에이전트 루프 용도에서 먼저 막아야 하는 순서(제안이다. 공식 로드맵은 [09장](09-agent-loop-and-roadmap.md)).

1. 호스트가 죽는 경로: 모두 수정됨(F-03 · F-04 · F-06 · F-08 · F-09 · F-10 · F-11 · F-12 · F-40. F-06은 호스트가 `deny_raw_ptrs`를 켜야 함)
2. 조용한 오답: 모두 수정됨(F-01 · F-20 · F-21 · F-22 · F-23 · F-24. F-73은 재현 안 됨 · 미확정)
3. 상태가 깨지는 경로: 모두 수정됨(F-05 · F-07 · F-14 · F-25 · F-26, 2026-11-08. F-26의 `NoCopy` 원소 지원은 남음). 소유권의 중간 항목 F-27(부분 이동) · F-29(종료 정리 순서)와 타입 시스템의 F-28(`const` 매개변수 패닉)도 2026-11-08 수정. F-27 문서 보강 중 발견한 F-79(옮긴 멤버 재대입의 이중 파괴 · 누수)는 미수정
4. 표준 라이브러리와 리터럴에서 LLM 스크립트가 바로 닿는 곳: 모두 수정됨(F-70 · F-71 · F-72 · F-74 · F-76)
5. 정리: F-50~F-54, F-60~F-66, F-77, F-78 (F-64는 일부 정리, F-61 · F-62 · F-63 · F-75는 수정됨, F-31 · F-42는 종료)

F-20(cte)은 "컴파일은 되고 실행도 되는데 답이 틀리는" 종류라서, 에이전트가 쓴 스크립트의 결과를 신뢰하는 모든 설계에 직접 위험했다. 2026-11-08에 고쳤다(`02f39e67`).
F-01(제너레이터)은 같은 종류였고 2026-11-04에 고쳤다. F-73은 재현되지 않고 회귀 테스트로 고정했지만 고친 커밋을 모르므로 원인이 밝혀질 때까지 같은 급으로 본다.

## G. 2026-11-04 ~ 06 커밋에서 고친, 표 밖의 버그

위 표를 쓸 때 발견하지 못했지만 `b40531a1..db9f636d` 사이에 고친 것들이다. 상세는 각 커밋 본문과 `docs/decisions`.

| 커밋 | 내용 | 결정 문서 |
| --- | --- | --- |
| `38272a0c` | VM `JUMP_T`가 거짓일 때 점프하도록 뒤집혀 있었다(쓰는 곳이 없어 드러나지 않음). offset도 `JUMP_F`와 같은 부호 없는 16비트로 | `project_bc_register_fields.md` |
| `d99a8aa9` | `semaDeref`가 `addressable`을 포인터 식에서 물려받아 `*(as[Ptr[T]] p)[i]`가 원소를 임시에 복사한 뒤 해제했다(`Map[str]` 키 이중 해제) | `project_array_index_calls.md` |
| `c67c3e65` | `sp := [&]int{1,2,3}`이 bc_gen에서 "expected mapping to IR local" panic | `project_span_literal_local.md` |
| `7e7268b0` | REPL `persist_main`의 맨 위 빌림 타입 지역이 이월 뒤 스택 재할당으로 해제된 메모리를 읽음 → 컴파일 오류로 거부 | `project_span_literal_local.md` |
| `5d78b14f` | `beginCall`에서 제너레이터의 `?T` 슬롯이 프레임보다 넓으면 `reg_end - ret_reg_size`가 언더플로(safe 빌드 컴파일 시 panic) | `project_coroutines.md` |
| `eb8134b3` | `for`가 `^T` iterable을 retain하지 않아 이중 해제. 제너레이터 `for` 순회 추가 | `project_repl_result.md` |
| `46faf101` | `destructValueAt`에 choice가 빠져 choice 결과가 샘 | `project_repl_result.md` |
| `0ea223d9` | `meta.stack_trace()`가 프레임 이름과 포맷 문자열을 새던 것(F-31과 함께) | `project_coroutines.md` |
| `a1b2a75f` | AVX2 ascii set 검색이 하위 니블이 같은 코드에서 틀린 결과(x86_64_v3) | `project_string_index_simd.md` |
| `1a1bdf60` | Linux rpath의 빈 항목(cwd)에서 라이브러리가 로드될 수 있었다 | `project_fork_release_ci.md` |
| `ab626361` | 정적 musl 빌드가 self dlopen 불가 → libc dlopen 경로 선택, FFI 기본 끔 | `project_zig_017_upgrade.md` |
| `e4c0347c` | `str(bytes)`가 UTF-8을 검증하지 않음 → `str.from_utf8` · `str.is_utf8` 추가, 낡은 `str.decode` 선언 제거 | `project_str_from_utf8.md` |
| `2fe9fb54` · `1d3b8e72` | `never` 식문 뒤 지역 해제 생략, 재귀 함수를 자기 본문에 인라인하지 않음 | `project_bc_inline.md` |
| `af00c105` | REPL이 `#[` 속성 줄을 다음 선언과 묶지 않아 속성만 따로 컴파일됨 | `project_repl_result.md` |
| `15a85a9e` | 덤프 `is_zero` 피연산자 위치, `and_` 등 빈 덤프(F-62 일부) | `project_bc_register_fields.md` |

`HashMap.set` 덮어쓰기 때 `len` · `nvac` 증감 버그(`project_map_str_hash.md`)는 2026-11-02 수정으로 이 범위 앞이다.
