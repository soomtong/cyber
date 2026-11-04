# 코루틴: 옛 fiber API의 제거 경위와 현재 상태

2026-10-31, `src/test/bench/fiber/fiber.cy`를 포팅하면서 조사한 내용. 이 fork가 바꾼 것은 없고 upstream의 결정을 기록한다.

## 사실

- upstream 커밋 `b751ca6c`(2025-11-21, "[all] some updates")에서 tokenizer의 `coinit` · `coresume` · `coyield`
  키워드가 삭제되고 `yield`가 추가됐다. 옛 테스트 `test/concurrency/fibers.cy` · `test/functions/call_fiber_param.cy`도
  같이 지워졌다. 정적 타입 전환을 포함한 대규모 재설계 커밋이라 fiber만의 이유는 적혀 있지 않다.
- 옛 fiber는 동적 타입에 묶여 있었다. fiber 함수는 `dyn`을 반환했고 인자는 `List[dyn]`, `coresume`은 아무 값이나 돌려줬다.
- 지금 동작하는 코루틴은 `#[generator]` 함수뿐이다. 호출하면 `Generator[Fn]`이 돌아오고 `next()`가
  `?(type.fn_ret(Fn))`, `status()`가 `paused` · `running` · `done`을 준다. 스택리스라 프레임 하나만 저장한다
  (`src/builtins/core.cy`의 `type Generator`). 테스트는 `src/test/concurrency/generator.cy`.
- 스택형 `Fiber` 타입은 `docs/docs.md`의 "Fibers." 절에 설계만 있다(`Fiber(fn, args)` · `f.resume()` · `Fiber.yield()`).
  본문에 TODO 표시가 있고 소스 어디에도 `type Fiber` 선언이 없다. `src/fiber.zig`는 옛 VM용 코드이며 현재 어디서도
  import하지 않는다.
- 2026-11-02, `examples/fiber.cy`를 제너레이터로 다시 썼다. 옛 fiber API는 deprecated로 보고, 예제는 `#[generator]`
  함수와 `gen.next()` · `gen.status()`로 같은 흐름(`start` 출력 후 0..99를 한 번에 하나씩)을 보여 준다.
- 제너레이터 10만 개를 만들어 두 번씩 resume하는 벤치는 ReleaseSafe CLI에서 28 ms다(`fiber.cy`, 결과 200000).

## 제거 이유에 대한 해석

- 정적 타입 전환과 맞지 않았다. 반환 타입이 정해지지 않는 `coinit` · `coresume`을 두기 어려웠고, 새 설계는 제너레이터의
  결과 타입을 함수 시그니처에서 유도한다.
- 역할을 둘로 나눴다. "값을 조금씩 내놓는 코루틴"은 스택리스 제너레이터로, "독립 실행 컨텍스트"는 자체 힙과 성장형 스택을
  가진 Thread와 Future · await로 보냈다. Generator 주석도 "격리된 실행 컨텍스트가 필요하면 threads를 쓰라"고 적는다.
- 비용 정리. 옛 fiber는 각자 스택을 가진 stackful 코루틴이었고, 가벼운 쪽은 stackless로, 무거운 쪽은 Thread로 정리했다.
- 키워드 세 개 대신 `yield` 하나만 남긴 것은 같은 커밋의 문법 축소 흐름과 맞는다.
- 따라서 현재는 "제거"라기보다 "교체 도중"이다. upstream은 2025-11 이후 사실상 멈춰 있어 교체가 끝나지 않았다.

## `#[generator]` 표기에 대한 평가

- `#[...]` 속성은 언어 안에 이미 자리 잡았다. 현재 `extern` · `bind` · `reserve` · `cond` · `generator` · `unsafe` ·
  `consteval` · `jit` 여덟 개이고 `src/parser.zig`의 `attributes` 고정 목록으로 검사한다. Rust와 같은 모양이다.
- 다만 다른 속성은 선언의 메타데이터인데 `#[generator]`는 호출 결과 타입을 `int`에서 `Generator[fn() -> int]`로 바꾼다.
  시그니처의 `-> int`만 보고 반환 타입을 오해할 수 있다. JS는 `function*`로 선언에 표시하고 Python은 `yield`로 추론한다.
  의미상으로는 `gen fn` 같은 선언 키워드나 `yield` 기반 추론이 더 가깝다.
- 문서의 "Attributes." 절은 `TBD`로 비어 있다. 속성 목록과 `#[generator]`가 반환 타입을 바꾼다는 점은 fork 문서에 적어 둔다.

## 결정

- 당장은 upstream 문법을 그대로 따른다. 벤치 · 예제 · 임베딩 코드는 `#[generator]`를 쓴다.
- upstream이 비활성이므로 비어 있는 부분(스택형 `Fiber`, 제너레이터 reset, 속성 문법 정리)은 필요해지면 이 fork가 직접
  설계하고 구현한다. 에이전트 루프(`docs/decisions/project_embedding_agent_loop.md`)에서 실행 중단 · 재개가 필요해지면
  스택형 Fiber 또는 VM 체크 포인트가 첫 후보다. 그때 이 문서의 해석을 출발점으로 삼고, 결정은 여기에 덧붙인다.

## 제너레이터 프레임 보존 수정 (2026-11-04)

`docs/study/07-coroutines-concurrency.md` 2.4의 "본문 지역 변수가 `yield`를 넘어 보존되지 않는다"를 고쳤다. 같은 경로에서
드러난 결함도 함께 고쳤다(2~8번).

1. 프레임 저장 범위. `ret_gen`은 내보낼 때의 `reg_end`(매개변수 끝)까지만 힙에 복제했다. 본문 지역 · 루프 상태 · 임시값은
   소비자 스택에만 살아서, `next()` 사이에 호출이 있거나 다른 호출 지점에서 `next()`하면 값이 바뀌었다(관리 타입이면 segfault).
   이제 `genFuncBlock`이 `chk_stk`처럼 본문 생성 뒤 최대 레지스터 수로 `ret_gen`의 끝을 되채운다(`Proc.ret_gen_pc`).
2. 복원만 있고 저장이 없었다. `GEN_NEXT` · `GEN_END`는 힙 → 스택 복사만 했다. `RET_Y`가 멈출 때마다 프레임을 힙으로 되돌려
   쓴다. 비용은 `yield`마다 프레임 크기만큼의 복사다.
3. 재개 시 스택 검사. 재개는 제너레이터의 `CHK_STK`를 건너뛰므로 프레임을 소비자 스택 끝 너머에 쓸 수 있었다. `GEN_NEXT` ·
   `GEN_END`가 자리를 확인하고 `RES_STACK_OVERFLOW`를 돌려준다. `growStackPrecise`는 `chk_stk` 외에 이 두 명령에서 멈춘 경우를
   받는다(`fp`를 되돌리지 않음). 소비자 프레임의 스택 포인터를 고치도록 두 명령 지점에도 포인터 레이아웃을 남긴다.
4. 실행 중인 제너레이터 프레임을 지나는 스택 성장. 복사 경로가 프레임 `base[2]`를 ret fp로 읽었는데 제너레이터 프레임에서는
   그 자리가 `Generator*`다. 제너레이터 본문에서 깊은 호출을 하면 `integer overflow`로 죽었다(master에서 재현). 이제
   `Generator.prev_fp`를 따라가고 그것을 새 스택으로 고친다.
5. `yield` · 제너레이터 `return`이 값을 복사하지 않았다. 살아 있는 관리 지역(`yield s`)을 비트 복사로 넘겨, 소비자가 해제한 버퍼를
   제너레이터가 다시 읽고 다시 해제했다. 일반 `return`처럼 `semaOwn`을 거친다.
6. `?T`가 넓은 제너레이터 호출의 컴파일 실패. `beginCall`의 `reg_end - ret_reg_size`가 언더플로해, safe 빌드에서
   `-> str` 제너레이터를 지역에 받는 코드가 컴파일 중 panic했다(ReleaseFast는 감싸져 우연히 동작).
7. `mainBlock`이 `popProc` 뒤에 `getMaxUsedRegisters()`를 읽었다. Debug · ReleaseSafe에서는 지워진 슬롯(0xAA)을 읽어 main 스택이
   항상 43690 슬롯으로 시작했고, 그 때문에 safe 빌드에서는 얕은 스택 성장 경로가 테스트되지 않았다. 순서를 바꿨다.
8. 프레임 버퍼 해제. 프레임 버퍼를 `heap.alloc.dupe`로 따로 잡아 `Generator.deinit`만 풀었다. panic · `single_run` 힙 스윕은
   소멸자를 건너뛰므로 매개변수 있는 제너레이터의 버퍼가 샜다(1번 뒤로는 모든 제너레이터). lib "single_run frees big heap
   objects at deinit."이 누수 10건으로 잡았다. 이제 `heap.new_byte_buffer`로 잡아 `freeAllBuffers`가 스윕 때 함께 푼다.
   레지스트리가 주소를 키로 쓰므로 빈 프레임도 한 슬롯을 잡는다.

테스트: `src/test/concurrency/generator.cy`(지역 · 루프 상태 · 호출 지점 · 관리 지역 복사 · 버림 · 깊은 재개 · 중첩 제너레이터 성장 ·
넓은 프레임을 깊이마다 재개해 `next()`가 스택 끝에 닿게 하는 경우), lib "Generator frames keep locals across yields and free them."
(누수 검사 allocator). 수정 전 master에서 behavior 테스트는 `Expected 12, found 11`로 실패하고, 4번 수정을 빼면 중첩 제너레이터와
깊이 sweep이 실패한다.

남은 것:
- 프레임은 `next()`마다 다른 위치로 옮겨 다닌다. 제너레이터 자기 프레임 안을 가리키는 빌림(`&local`)을 `yield` 너머로 들고 가면
  여전히 무효다. sema가 막는 규칙은 없다(학습 문서 실습 8).
- `unwindStack`의 `.gen` 분기는 ret 슬롯 1개를 가정한다(학습 문서 2.5 (1)). 이번 수정 범위 밖이다.

## 제너레이터 프레임을 지나는 언와인드 · 스택 트레이스 수정 (2026-11-04)

`docs/study/07-coroutines-concurrency.md` 2.5의 세 결함. 실행 중인 제너레이터 프레임(`GEN_NEXT` · `GEN_END`)은 다른 프레임이
호출자 fp를 두는 `base[2]`에 `Generator*`를 두고, 호출자 fp는 `Generator.prev_fp`에 있다. 이 프레임을 이해하는 코드가 흩어져
있었다.

1. `unwindStack`의 `.gen` 분기가 `fp+1..fp+3`을 하드코딩해 ret 슬롯 1개를 가정했다. `?int`(2슬롯) · `?str` 제너레이터 안의 panic이
   `incorrect alignment`로 호스트를 abort시켰다(master에서 재현). fuel · interrupt 중단도 같은 경로라 같이 죽었다.
2. `gen_next` · `gen_end`에 debug sym이 없어 릴리스 빌드가 `unexpected 4`만 냈다. 프레임 보존 수정(위)에서 `pushFCode`로 바꿔
   이미 고쳐져 있었다.
3. `recordCurFrames`(`meta.stack_trace()`)에는 `.gen` 분기가 없어 `Generator*`를 fp로 읽고 `integer overflow`로 abort했다.

결정: 이전 fp를 읽는 곳을 `FrameInfo.prev_context()` 하나로 모았다. `prev_fp_slot()`이 프레임 종류에 따라 `base[2]` 또는
`Generator.prev_fp`를 돌려준다. `unwindStack`과 `recordCurFrames`는 제너레이터 프레임을 VM 프레임처럼 기록하고,
`growStackPrecise`는 같은 슬롯을 새 스택으로 고친다(제너레이터는 힙에 있으므로 제자리에서).

같이 고친 것: `meta.stack_trace()`(F-31)가 자기 프레임을 지운다며 `pop()`을 두 번 불러 가장 바깥 프레임 둘(main과 그 호출)을
지웠다. 바이트코드 인라인으로 프레임이 합쳐지면 빈 문자열이 됐다. 이제 기록 전에 버퍼를 비우고 가장 안쪽 호스트 프레임
(`stack_trace` 자신)만 뺀다. 프레임 이름과 `toOwnedSlice` 결과가 매번 새던 것도 `StackTrace.deinit`과 `buf.written()`으로 고쳤다.

테스트(lib, 누수 검사 allocator): "Panics inside generators unwind through the generator frame."(`?int` 본문 panic, `?str`
제너레이터가 부른 함수의 panic, 본문 안 fuel 중단, 이후 VM 재사용), "stack_trace() lists the frames from the caller to main."
(인라인된 호출, 제너레이터 안). 기대 트레이스에 `core.cy` 줄 번호가 들어가지 않도록 behavior 테스트 대신 프레임 이름 순서를 본다.
`thread.zig` 수정을 빼면 두 테스트가 abort하고, `meta.zig` 수정을 빼면 두 번째가 실패한다.

남은 것: F-31의 다른 절반(`dump_frame`이 `chk_stk`의 `stack_size`를 `+3`에서 읽음)은 손대지 않았다.

## 일반 함수 안의 `yield` (2026-11-04)

`#[generator]`가 아닌 함수나 main 블록에 `yield`를 쓰면 sema가 반환 타입을 `^Generator[...]`로 그냥 캐스트해 컴파일을 통과시키고
실행 시 segfault했다(REPL에서 `#[generator]` 줄이 따로 제출돼 속성 없는 `fn gen(): yield 1`이 만들어지면서 발견). 이제 sema가
"`yield` is only allowed in a `#[generator]` function."으로 거절한다. 테스트 `src/test/concurrency/yield_outside_generator_error.cy`.
REPL에서는 속성 줄이 `:`로 끝나지 않아 블록으로 묶이지 않으므로 제너레이터 선언은 파일로 넣어야 한다(남은 과제).

## 제너레이터의 `for` 순회 (2026-11-04)

`for g() |v|:`는 `^Generator[...]`에 `iterator`가 없어 컴파일 오류였다(REPL 속성 줄 작업 중 발견). `for`의 순회 규약은
`iterator()`가 상태 값을 돌려주고 `next(idx &state) -> ?T`가 다음 값을 주는 것이라, `Generator`에 `iterator() -> int`(항상 0,
위치는 제너레이터 자신이 가짐)와 `next(idx &int)` overload를 더했다. 소진된 뒤 `status()`는 `done`이고, 이미 `next()`로 일부
진행한 제너레이터는 멈춘 곳부터 이어서 돈다.

같이 드러난 sema 버그: `for_iter_stmt`가 ref pointer(`^T`) iterable을 숨은 지역 `_iterable`에 넣을 때 `semaOwn`을 거치지 않아,
기존 지역(`for gen |v|`)을 돌리면 루프 끝에서 숨은 지역과 원래 지역이 둘 다 해제해 이중 해제가 났다(소진 뒤 `status()`가 해제된
메모리를 읽어 `paused`, 다음 `next()`는 segfault). 지금까지 `^T` 중 `iterator`를 가진 타입이 없어 드러나지 않았다. ref pointer면
`semaOwn`(retain)하도록 고쳤다(`sema.zig` `.for_iter_stmt`). 임시값(`for g() |v|`)은 이미 owned라 복사가 없다.

`^ArrayStore`는 여전히 `iterator`가 없어 `for`로 돌 수 없다. 별개 과제.
테스트는 `concurrency/generator.cy` 끝의 `for` 절 5개.
