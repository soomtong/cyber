# 코루틴: 옛 fiber API의 제거 경위와 현재 상태

2026-10-31, `src/test/bench/fiber/fiber.cy`를 포팅하면서 조사한 내용. 이 fork가 바꾼 것은 없고 upstream의 결정을 기록한다.

## 사실

아래 기록의 `#[generator]`는 적을 당시의 문법이다. 2026-11-11부터 선언은 `generator fn f(...)`이고 `#[generator]` 속성은 없어졌다(아래 "선언 모양 변경과 구현" 절).

- upstream 커밋 `b751ca6c`(2025-11-21, "[all] some updates")에서 tokenizer의 `coinit` · `coresume` · `coyield`
  키워드가 삭제되고 `yield`가 추가됐다. 옛 테스트 `test/concurrency/fibers.cy` · `test/functions/call_fiber_param.cy`도
  같이 지워졌다. 정적 타입 전환을 포함한 대규모 재설계 커밋이라 fiber만의 이유는 적혀 있지 않다.
- 옛 fiber는 동적 타입에 묶여 있었다. fiber 함수는 `dyn`을 반환했고 인자는 `List[dyn]`, `coresume`은 아무 값이나 돌려줬다.
- 지금 동작하는 코루틴은 `#[generator]` 함수뿐이다. 호출하면 `Generator[Fn]`이 돌아오고 `next()`가
  `?(type.fn_ret(Fn))`, `status()`가 `paused` · `running` · `done`을 준다. 스택리스라 프레임 하나만 저장한다
  (`src/builtins/core.cy`의 `type Generator`). 테스트는 `src/test/concurrency/generator.cy`.
- 스택형 `Fiber` 타입은 `docs/docs.md`의 "Fibers." 절에 설계만 있다(`Fiber(fn, args)` · `f.resume()` · `Fiber.yield()`). (2026-11-11에 구현했다. 아래 "Fiber 구현" 절)
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
  `consteval` · `call` · `inline` 아홉 개이고(`jit`는 2026-11-06 삭제) `src/parser.zig`의 `attributes` 고정 목록으로 검사한다. Rust와 같은 모양이다.
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

남은 것: F-31의 다른 절반(`dump_frame`이 `chk_stk`의 `stack_size`를 `+3`에서 읽음)은 손대지 않았다. 2026-11-06에 `+2`로 고쳤다(`debug.zig` `get_pc_func_metadata`).

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

`^ArrayStore`도 같은 이유로 `for`가 안 되던 것을 `iterator()` · `next(idx &int)`를 더해 돌게 했다(테스트 `core/ArrayStore.cy`).
테스트는 `concurrency/generator.cy` 끝의 `for` 절 5개.

## 설계 결정 (2026-11-07)

`docs/specs/2026-11-03-generator-and-fiber-coexistence.md`를 검토해 다음을 결정했다. 스펙 문서 5절의 코드가 결정된 문법이다.
2번의 제너레이터 선언은 2026-11-11에 모양을 `generator fn f(...)`로 바꿔 구현했다(아래 "선언 모양 변경과 구현" 절).
`fiber` · `suspend`와 3번의 enum 개명도 같은 날 구현했다("Fiber 구현" 절).

1. 공존 방식은 역할 분리 병존이다. generator는 값을 내고, fiber는 기다린다. 둘 다 언어 내장 타입(`Generator`, `Fiber`)이다.
2. 새 키워드 세 개: `generator` · `fiber` · `suspend`. upstream이 0.3의 `coinit` · `coresume` · `coyield`를 지운 자리에
   역할이 분명한 셋이 들어간다. 저장소 내 식별자 사용은 셋 모두 0건이다.
   - `generator f(...) -> T:`가 `#[generator]` 속성을 대체한다. 속성은 키워드 도입과 함께 제거한다(테스트 · 예제 · 문서 24곳).
     `iter` · `gen`은 변수명으로 이미 쓰여(13건) 기각했다. (2026-11-11: 모양을 `generator fn f(...) -> T:`로 바꿨다.)
   - `fiber f(args)`가 `Fiber(f, {args})` 생성자를 대체한다. Go의 `go f(x)`와 같은 "키워드 + 호출식"이다. 인자는 지금 평가하고
     호출은 첫 `resume()`에서 한다. 블록이 필요하면 `fiber:` 뒤에 본문을 둔다(트레일링 블록 람다와 같은 파싱, `^T`만 캡처).
   - `suspend`가 `Fiber.yield()`를 대체한다. 값을 싣지 않는 문장이다. 원칙: 수신자가 있는 조작은 메서드(`f.resume()`, `g.next()`),
     현재 실행 맥락을 멈추는 조작은 키워드(`return` · `yield` · `suspend`). `pause`는 식별자 충돌 가능성으로, 값 없는 `yield`는
     generator 본문 안에서의 혼동으로 기각했다.
3. 상태 enum의 `.paused`를 `.suspended`로 바꾼다. `GeneratorStatus`와 새 `FiberStatus` 모두 `.suspended` · `.running` · `.done`이다.
   `suspend` → `.suspended` → `resume()`이 한 어휘가 된다(Lua의 `suspended` · `running` · `dead`와 같은 꼴).
4. `f.resume()`은 `FiberStatus`(`.suspended` 또는 `.done`)를 돌려준다. 끝난 fiber의 `resume()`은 panic 없이 `.done`이다.
   fiber 진입 함수는 `void`만 반환한다. 결과는 `^T` · Future · 채널로 전달한다.
5. 위임 문법(`yield*`)은 두지 않는다. `for inner() |v|: yield v` 두 줄을 이디엄으로 삼는다. 필요해지면 `yield from`을 검토한다.
6. Future를 공통 대기 인터페이스로 삼는다. `await()`의 정의는 "완료될 때까지 현재 실행 맥락을 멈춘다" 하나이고, 멈추는 방법
   (fiber 양보 · 루트 spin · 호스트 `CL_AWAIT`)만 런타임이 고른다. 완료된 Future의 빠른 경로는 지금 비용과 같아야 하고,
   fiber 멈춤에 힙 할당이 없어야 한다.
7. `spawn(fn, {args})`는 이번에 바꾸지 않는다. fiber 구현에서 호출식을 함수와 인자로 분해하는 코드가 생기면 `spawn f(args)`로
   맞추는 일을 후속 작업으로 둔다.

순서는 스펙 6절의 로드맵을 따른다. 단계 1.5(키워드 치환과 enum 개명)는 런타임 변경이 없어 먼저 할 수 있다.

## 선언 모양 변경과 구현 (2026-11-11)

2026-11-07 결정의 `generator f(...) -> T:`를 `generator fn f(...) -> T:`로 바꾸고 구현했다. 키워드 선택(`generator` ·
`fiber` · `suspend`)은 그대로다.

`fn`을 남긴 이유.

1. fiber와 모양이 겹친다. `fiber f(args)`는 선언이 아니라 호출식인데, `generator count(n int) -> int:`와
   `fiber count(3)`이 둘 다 "키워드 + 이름 + 괄호"가 된다. `fn`이 있으면 선언, 없으면 표현식으로 갈린다.
2. 메서드 선언. 수신자가 이름 앞에 오므로 `fn`이 없으면 `generator (^Bag) items() -> int:`가 `generator`라는 함수의
   호출처럼 보인다.
3. 예약어가 필요 없다. `generator`는 바로 뒤에 `fn`이 올 때만 수식어다. `generator := 3`, `fn generator()`는 그대로 된다.
4. 함수 선언에는 항상 `fn`이 있다는 규칙이 남는다. `-fn`(숨김), `#[...]` 속성, `with` 선언, `cyber fmt`, 검색이 기존 경로를 탄다.
5. 제너레이터의 타입이 `Generator[fn() -> int]`로 함수 타입 위에 있어 "수식어가 붙은 함수"라는 모델이 구현과 맞는다.

Nim처럼 `iterator`를 `proc`과 다른 선언 종류로 두는 길(`generator f()`)은 짧지만 위 1 · 2 때문에 택하지 않았다.

구현.

- 파서(`src/parser.zig`): `isGeneratorFn(n)`이 "ident `generator` 다음에 `fn`"을 본다. 문장 머리, `-` 뒤, `#[...]` 뒤,
  `with [...]` 뒤 네 곳에서 확인하고 `parseFuncDecl`에 `generator = true`를 넘긴다. 토크나이저에는 키워드를 더하지 않았다.
- AST: `FuncDecl.generator: bool`(`src/ast.zig`, `cy` 모듈의 `FuncDecl`도 같은 자리). `AttributeType.generator`와
  `cy` 모듈의 `AttributeKind.generator`는 지웠다. sema는 속성 대신 `decl.generator`를 본다.
- `#[generator]`는 ``ParseError: The `#[generator]` attribute was replaced by `generator fn`.``
- 오류 문구: `` `yield` is only allowed in a `generator fn`. ``, ``A `generator fn` can not take the borrow type ...``
- tree-sitter: `generator_fn`은 `generator`와 `fn`을 묶은 한 토큰이다. 낱말 `generator`를 키워드로 두면 식별자로 쓸 수
  없게 되기 때문이다. vim 구문 파일에는 `generator`를 키워드로 더했다(식별자로 써도 강조된다).
- 치환: 테스트 · 예제 · lib 테스트 · 퍼즈 프로브의 `#[generator]` 선언 전부. REPL의 속성 줄 묶기 테스트
  (`src/test/modules/cy.cy`)와 문서 예는 `#[inline]`으로 바꿨다.

확인하면서 본 것(이 변경과 무관, 변경 전 빌드에서도 같음).

- 메서드 제너레이터가 실행 중 죽는다. `generator fn (^Bag) items() -> int:`에서 `yield self.a`를 하고 `for b.items() |v|:`로
  돌리면 `Segmentation fault at address 0xaaaaaaaaaaaaaaaa`(ReleaseSafe). 2026-11-11에 수정: `semaMethodBody2`가
  `ret_gen`을 내지 않아 본문이 일반 호출 프레임에서 바로 돌았고, 첫 `RET_Y`가 호출자 fp 자리를 `Generator*`로 읽었다.
  프롤로그를 `semaGeneratorPrologue`로 뽑아 함수 · 메서드가 같이 쓴다.
- 템플릿 제너레이터 `generator fn rep[T Any](x T, n int) -> T:`의 호출은 `Unsupported call from symbol: func_template`.
  이 오류는 제너레이터와 무관하다. `[T]` 템플릿은 일반 함수도 인자로 추론하지 않는다(`rep[int](1, 3)`으로 확장하거나
  `%T`를 쓴다). 사용자 결정(2026-11-11): `[T]`는 명시적 확장 전용, 추론은 `%T`라는 구분을 유지하고
  `[T]`에 추론을 넣지 않는다. 실제 결함은 그 다음에 있었다: 인스턴스가 `resolveUserFuncVariant`로 해석돼 제너레이터 설정을
  건너뛰었고 `rep[int](1, 3)` · `%T` 형태가 ``Can not find the symbol `iterator` for `int`.``였다. 같은 날 수정:
  시그니처 변환을 `resolveGeneratorSig`로 뽑아 인스턴스에도 적용한다. 테스트 `concurrency/generator_method.cy`.
- 함수 본문 안의 `generator fn`은 일반 `fn`과 같이 `` `fn` declarations are not allowed here. ``

남은 것: `.paused` → `.suspended` 개명(단계 1.5의 나머지), `fiber` · `suspend`(단계 2). 둘 다 같은 날 아래 절에서 했다.

## Fiber 구현 (2026-11-11)

단계 1.5의 나머지(`GeneratorStatus.paused` → `.suspended`)와 단계 2(`fiber f(args)` · `fiber:` · `suspend` · `Fiber`)를 구현했다.
단계 1(루트 맥락의 `CL_AWAIT` 탈출과 호스트 Future C API)은 건너뛰었다. fiber의 스택 교체는 그 코드에 기대지 않는다.

모델.

- fiber마다 자기 스택을 둔다(`vmc.Fiber`, `thread.newFiber`). `resume`은 `Thread`의 `stack_ptr` · `stack_len` · `stack_end`와
  `pc` · `fp`를 fiber 것으로 바꾸고, `suspend`와 진입 함수의 반환은 resume한 쪽으로 되돌린다. 복사가 없고 힙 할당도 없다.
- 전환은 호스트 함수가 아니라 VM 명령이다(`FIBER_RESUME dst, fiber` · `SUSPEND` · `FIBER_END`). C 스택이 끼지 않아
  호출 깊이 어디서든 멈출 수 있다.
- 진입 프레임은 fiber 스택의 오프셋 0에 둔다. `getFrame`이 오프셋 0을 `.init`(main 프레임)으로 보기 때문에 스택 성장
  (`growStackPrecise`의 포인터 패치) · `recordCurFrames` · `unwindStack`이 고치지 않고도 fiber 스택 안에서 멈춘다.
- 진입 프레임의 반환 주소는 정적 명령 하나(`fiber_end_code`, `FIBER_END`)다. 진입 함수가 `RET_0`로 돌아오면 그 명령이
  fiber를 `done`으로 두고 resume한 쪽으로 넘어간다.
- resume한 쪽 프레임에는 포인터 레이아웃이 필요 없다. fiber가 도는 동안 그 스택은 자라지 않는다.
- `fiber f(a, b)`는 sema에서 core의 `@new_fiber(f, {a, b})` 호출로 바꾼다(`spawn`과 같은 꼴: `FnTuple[Sig]`,
  `@fiber_entry[Sig]`가 `@call(func, &args)`). `fiber:`는 본문을 `lambda_multi`로 파싱해 `@new_fiber_block(클로저)`로 바꾼다.
  AST에는 `fiber_expr` · `suspend_stmt` 노드가 그대로 남는다(`cyber fmt`는 토큰 기반이라 영향 없음).
- `Fiber`는 `NoCopy` 구조체이고 필드는 호스트가 만든 상태의 포인터 하나다. 상태와 스택은 `Thread.alloc`으로 잡고
  스레드의 fiber 목록(`ThreadC.fibers`)에 건다. panic · `single_run` 스윕은 `@deinit`을 부르지 않으므로
  `freeHeapPages`가 목록을 따라 해제한다.
- panic. 트레이스는 `allocContextTrace`가 fiber 스택을 다 걷고 `Fiber.prev_*`로 resume 지점의 스택으로 넘어가 이어 붙인다.
  그 뒤 `exitFibers`가 스레드를 루트 스택으로 돌려놓는다. `prepEval`도 같은 일을 한다.
- `Thread.host_depth`는 `callFunc2`가 바이트코드를 도는 동안 1 늘어난다. resume 때의 값과 다른 깊이의 `suspend`는
  `Cannot suspend across a host call.` panic이다. 지금은 스크립트에서 닿는 경로가 없다(호스트가 VM으로 되부르는 곳은
  spawn 스레드 진입과 AOT뿐이고, C API에는 스크립트 함수 호출이 없다). 그런 API가 생길 때를 위한 가드다.

검사.

- sema(`semaFiberExpr`): 진입점이 식별자이거나 경로(`T.method` · `mod.func`, 2026-11-12부터)일 때 시그니처를 먼저 보고 generator · 비-void 반환 · 빌림 매개변수를 `fiber` 식의
  위치에서 보고한다. 그 밖의 꼴은 `@new_fiber` 안의 `meta.error`가 잡는다(위치가 core.cy가 된다).
- 파서: `suspend` 뒤에 값이 오면 오류, `fiber` 뒤가 호출이 아니면 오류, 이름 있는 인자 오류.

스펙과 달라진 점 · 제약.

1. `a.resume()`만 쓰면 컴파일 오류다. 반환값을 버릴 수 없는 언어 규칙 때문에 `_ = a.resume()`으로 쓴다. 스펙 5절 예제를 고쳤다.
2. 인자는 첫 resume에서 `@call`이 복사해 넘긴다(`spawn`의 `@thread_entry`와 같다). `NoCopy` 매개변수는 컴파일 오류이고,
   `@deinit`이 있는 복사 가능한 구조체는 사본과 원본이 각각 deinit된다.
3. 끝나지 않은 fiber의 소멸은 panic이다. 한 번도 resume하지 않은 fiber는 2026-11-12부터 소멸할 수 있다.
   `Fiber.@deinit`이 `@fiber_cancel`로 `vmc.Fiber.cancelled`를 켜고 한 번 resume하면 `@fiber_entry`가
   `@fiber_cancelled()`를 보고 호출 없이 반환한다. 인자는 진입 프레임의 매개변수라 그 반환에서 해제된다.
   `Sig`를 아는 해제 함수를 `Fiber`에 따로 둘 필요가 없다. 대가는 fiber 시작마다 호스트 함수 호출 한 번이다.
   인자의 `@deinit`이 `suspend`하면 fiber가 끝나지 않아 `Fiber is still in progress.` panic이 된다.
4. 진입점은 함수 이름이다. `fiber obj.work()`는 수신자를 묶지 못한다. 메서드는 `fiber Job.work(job, 2)`로 쓴다
   (원래 되던 형태다). 값에 대한 메서드 호출 꼴은 2026-11-12부터 이 표기를 알려 주는 컴파일 오류다(수신자가
   식별자일 때만 본다. 그 밖의 수신자 식은 이전의 필드 오류 그대로). `obj.work()` 꼴을 받아들일지는 정하지 않았다.
5. `fiber:` 본문은 기존 클로저 규칙을 그대로 따른다(`^T` 또는 `&T`로 선언한 변수만 캡처). `&T` 캡처를 fiber에서 막는
   규칙은 넣지 않았다.
6. `Future.await()`는 fiber 안에서도 spin했다(spawn의 Future). 2026-11-12 단계 3부터 fiber를 멈춘다(아래 "단계 3 구현" 절).
7. 루트 맥락의 `suspend`는 no-op이다. 임베딩의 `CL_YIELD`는 없다.
8. AOT(`cgen.zig`)는 미지원.

테스트: behavior `concurrency/fiber.cy`(성장 · 중첩 · 제너레이터 소비 · 블록 형태 포함)와 오류 6개 · panic 3개,
lib 테스트 3개(누수 검사 할당자: 정상 종료, 중첩 fiber 안 panic 뒤 재사용, `single_run`에서 진행 중인 fiber).
tree-sitter `fiber_expression` · `suspend_statement`.

남은 것: 단계 4(취소, 구조적 동시성). 4의 `obj.work()` 꼴은 넣지 않기로 했다(2026-11-12 사용자 결정). 단계 1(`CL_AWAIT`)은 2026-11-12에 구현했다(아래 절).

## 단계 1 구현 (2026-11-12)

tars-agent(이 언어를 code-act 주 언어로 내장할 에이전트)의 요청으로 구현했다. 능력 함수가 사용자 승인을 호스트 함수 안에서
동기적으로 기다리면 벽시계 상한이 고민하는 시간까지 세고, 취소해도 VM을 끊을 수 없다(F-42). 호스트 함수가 미완료 Future를
바로 돌려주고 VM 밖에서 기다리게 하는 것이 해법이다.

동작.

- main 스레드의 `Future.await()`가 미완료이고 `shared_state`가 없는 Future(호스트 Future, 완료 전의 `FutureResolver`)를 만나면
  eval이 `CL_AWAIT`로 돌아온다. 스택 · 지역 변수 · `persist_main` 상태 · 연료 · 현재 fiber가 그대로 남는다.
- `cl_vm_resume`이 같은 `AWAIT` 명령을 다시 실행한다. 완료됐으면 이어 가고, 아니면 다시 `CL_AWAIT`다. 그래서 "완료하지 않고
  resume"에 따로 코드가 없다.
- 호출 깊이에 제약이 없다. generator의 `next`와 fiber 전환이 모두 같은 루프 안의 VM 명령이고 실행 상태가 전부 `ThreadC`에 있어
  루프를 나갔다 들어와도 된다.

결정(사용자 동의 2026-11-12).

1. fiber 안의 await도 eval을 탈출한다(요청 8번). 재개는 그 fiber 안에서 이어진다. 단계 3(다른 fiber에 양보)은 아니다.
2. spawn한 스레드 안에서는 panic이다(요청 9번). `Cannot wait in a spawned thread for a future that the host or another context
   completes.` 이전의 `Local future will never complete.` 자리다.
3. Future 완료는 eval을 돌리는 스레드에서만 한다(요청 12번). 완료는 힙 값을 쓰는 일이고 힙은 스레드 소유다. 원자 연산을 넣지
   않았다.
4. 완료하지 않고 `cl_vm_resume`을 부르면 다시 `CL_AWAIT`다.
   `cl_vm_resume`은 멈춘 동안 들어온 interrupt 요청을 지운다(새 eval의 시작과 같은 규칙, 사용자 결정 2026-11-12). 처음에는
   남겨 두었는데, 그러면 승인 대기 중에 발동한 벽시계 타이머가 resume 직후 스크립트를 끊고(요청서의 첫 번째 문제가 그대로),
   호스트가 `CL_AWAIT`를 받고 타이머를 멈추기 전의 틈도 막을 수 없다. 플래그를 내리는 API도 없다. 멈춘 eval을 끊는 수단은
   `cl_vm_abandon`이다. 연료는 다시 채우지 않는다(스크립트가 한 일의 양이다).
5. 스크립트가 만든 미완료 Future(`FutureResolver`)도 같은 경로로 `CL_AWAIT`가 된다. 호스트 Future와 구조가 같아 구분하지 않는다.
   호스트는 모르는 Future면 버린다. CLI(`main.zig` `reportAbandonedAwait`)와 `cy.eval`(자식 VM)은 버리고 panic으로 보고한다.
6. 켜는 옵션은 두지 않았다. `CL_AWAIT`를 모르는 호스트는 이전의 panic 대신 `CL_AWAIT`를 받는다.
7. 호스트 함수가 스크립트를 다시 부른 안쪽(`host_depth != 0`)은 C 프레임이 끼어 있어 `Cannot await across a host call.` panic이다.

C API(`cyber.h`의 "Suspended evals and host futures" 절).

~~~c
CLFuture* cl_future_new(CLThread* t, CLType* future_t, uint64_t tag);
uint64_t cl_future_tag(CLFuture* future);
size_t cl_vm_pending_futures(CLVM* vm, CLFuture** out, size_t cap);
bool cl_future_complete(CLVM* vm, CLFuture* future, const void* value);
bool cl_future_complete_error(CLVM* vm, CLFuture* future, int64_t err);
CLFuture* cl_vm_pending_future(CLVM* vm);
CLResultCode cl_vm_resume(CLVM* vm, CLEvalResult* res);
void cl_vm_abandon(CLVM* vm);
// 새 결과 코드: CL_ERROR_SUSPENDED
~~~

- `CLFuture`는 `FutureValue[T]` 힙 객체다. `Future[T]`는 그 포인터 하나짜리 구조체라 반환 슬롯(`CLValue`, 모든 타깃에서 8바이트)에
  포인터 값을 쓴다. 32비트 타깃(wasm32)에서 포인터 크기로 쓰면 위쪽 4바이트가 채워지지 않는다.
- `cl_future_new`의 `future_t`는 `cl_find_type(vm, "Future[!void]")`로 얻는다. 이미 확장된 인스턴스만 찾으므로 스크립트(호스트
  함수의 선언)가 그 타입을 이름 지은 뒤여야 한다. 타입 포인터는 `cl_vm_reset` 뒤에 무효다.
- 값은 복사되고 Future가 소유한다(반환 슬롯과 같은 규칙). `Future[!U]`는 `U`를 받아 `Result`로 감싼다. 크기 없는 타입은
  `value`를 읽지 않는다.
- 호스트가 포인터를 보관하면 만들 때 `cl_thread_retain`으로 잡는다(규칙, tars-agent 피드백 2026-11-12). 처음에는 "비교만 하면
  잡지 않아도 된다"고 적었는데 틀렸다. 스크립트가 await하지 않고 버린 미완료 Future는 바로 해제되고 그 주소가 다음
  `cl_future_new`에 다시 쓰인다. 재현: `for 0..8 |i|: _ = host.ask(i)`에서 Future 8개가 전부 같은 주소였다. 포인터로 요청을
  찾는 호스트의 표에 같은 포인터가 여럿 남는다. 잡아 둔 Future는 주소를 혼자 쓰고, 스크립트가 버린 뒤에도 완료시킬 수 있다.
  놓는 때: 완료시킨 뒤, 또는 eval이 `CL_SUCCESS`로 끝났을 때. panic · interrupt · `cl_vm_abandon` · `cl_vm_reset` 뒤에는 그
  eval의 힙이 통째로 해제됐으므로(`freeHeapPages`는 참조 계수를 보지 않는다) 놓지 않고 잊는다. 놓으면 해제된 메모리를 건드린다.
  lib 테스트 `A host that keeps the pointers of its futures retains them.`
- 태그(사용자 결정 2026-11-12, 0.4.8 전에 넣음): `cl_future_new(t, future_t, tag)` · `cl_future_tag(f)`. 위 규칙이 세 갈래라
  호스트가 틀리기 쉬워서, 포인터를 보관할 필요 자체를 없앴다. 호스트는 요청 번호를 태그로 주고, `cl_vm_pending_future(s)`가 준
  Future의 태그로 요청을 찾는다. 그 Future들은 멈춘 eval이 쥐고 있어 살아 있다. `FutureValue`에 `tag int` 필드를 더했다(40 → 48
  바이트, `core.cy`와 `heap.zig`의 미러). 호스트가 만들지 않은 Future는 0이다. retain 규칙은 지금 기다리지 않는 Future를
  완료시키려고 포인터를 보관하는 호스트에만 남는다. 예제 `host_await.c`는 태그만 쓰고 포인터를 보관하지 않는다.
  lib 테스트 `cl_future_tag identifies the request of a pending future.`

구현.

- `vm.zig` `zAwait`: 미완료 로컬 Future에서 `Compiler.await_future`에 기록하고 `RES_AWAIT`. `vm.c`의 `AWAIT`는 pc를 그 명령으로
  되돌려 저장한다.
- `VM.eval`의 뒤처리를 `finishExec`(성공) · `failExec`(실패)로 떼어 `resumeEval`과 공유한다. `failExec`는 `error.Await`면 아무것도
  버리지 않는다. `resumeEval`은 `prepEval` · `resetStop`을 부르지 않는다(fiber와 연료를 초기화한다). interrupt 플래그만 직접 지운다.
- `abandonEval`: `ret_panic` 뒤 `handleInterrupt`로 되감고 `failExec(error.Interrupted)`. fiber 안이면 `exitFibers` 경로를 탄다.
  `VM.deinit`(reset 포함)이 멈춘 eval을 먼저 버리고 panic 메시지를 지운다(안 지우면 다음 `prepEval`이 이중 해제한다).
- 상태는 `Compiler.await_future` 하나다. `VM` 구조체는 `vm.h` padding 때문에 늘리지 못한다.
- `lib.zig` `futureSlot`: 객체의 타입에서 `data ?T`의 레이아웃을 읽는다(`zero_union`이면 태그 없음, 아니면 태그 8바이트 뒤).

조사 중 찾은 것: `yield` 식의 임시 값 누수(F-97, 수정), 임시 수신자의 평가 순서(F-98, 미수정).

테스트: lib `src/lib_test/await.zig` 10개(누수 검사 할당자). 기본 · 연속 await, 깊은 호출 · generator 본문 · fiber, 값 · 오류
완료와 `!else`, 완료된 Future의 빠른 경로, await하지 않은 · 미완료 Future, `persist_main` 지역 이월과 결과, 버리기 뒤 재사용 ·
멈춘 동안의 거부 · fiber 안에서 버리기 · reset · deinit, resume 뒤 연료 · interrupt · 메모리 상한 · panic, 스크립트 Future와
spawn 스레드. 예제 `examples/libcyber/host_await.c`(`lib-standalone-test`에 등록).

남은 것: 단계 3(fiber 안 await를 양보로) · 단계 4의 취소, `CL_YIELD`, AOT. 호스트 함수가 부른 스크립트 안의 await는 panic이다.

## `Future.wait_any` (2026-11-12)

단계 4의 일부다. 사용자 지시로 단계 1에 이어 구현했다. 도구 여러 개를 먼저 시작해 두고 먼저 끝난 것부터 받는 스크립트를 쓸 수 있다.

- `fn Future :: wait_any(futures [&]Future[%T]) -> int`. 먼저 끝난 Future의 인덱스, 여럿이면 목록에서 앞선 것. 같은 `T`만 섞는다.
- 목록에 spawn Future가 하나라도 있으면 `await`처럼 VM 안에서 기다린다(큐의 스레드 작업을 돌리며 spin). 호스트 Future만
  기다리는 탈출은 하지 않는다: 호스트가 완료시키지 않고 resume하면 호스트 쪽 busy loop가 되기 때문이다.
- 목록이 전부 로컬 Future이고 아무것도 끝나지 않았으면 eval이 `CL_AWAIT`로 나간다. `cl_vm_pending_futures(vm, out, cap)`가 목록
  전체를 돌려주고 호스트는 그중 아무것이나, 여러 개여도 완료시킨 뒤 resume한다. `cl_vm_pending_future`는 목록의 첫 번째다.
- 구현: builtin `@await_any(ptr, len)`(`core.zig` `await_any`)가 `RET_AWAIT`(2, `vm.h`)를 돌려주면 `CALL_HOST`가 pc를 그 호출에
  둔 채 `RES_AWAIT`로 나간다. resume은 같은 호출을 다시 실행한다(인자가 레지스터에 남아 있다). 새 opcode는 없다.
  목록은 `Compiler.await_any`가 가리킨다(스크립트가 넘긴 span의 메모리, 멈춘 동안 움직이지 않는다).
- interrupt: spin 중에 요청이 오면 builtin이 -1을 돌려주고 `wait_any`의 루프가 검사점에서 멈춘다.
- 테스트: lib `Future.wait_any suspends the eval until the host completes one of the futures.`, behavior
  `concurrency/future_wait_any.cy` · `future_wait_any_empty_panic.cy`, `spawn.cy`의 한 절.

`await` 하나씩으로도 동시 실행은 된다: 요청을 먼저 다 보낸 뒤 순서대로 await하면 호스트는 자기가 만든 Future를 전부 알고 있어
한꺼번에 처리할 수 있다. `wait_any`가 더하는 것은 "먼저 끝난 것부터"다.

## 단계 3 구현 (2026-11-12)

사용자 지시("이번 시즌에 fiber 관련 동시성 동작을 모두 완성해 0.5를 낸다")로 구현했다. 스펙 4절의 정의 그대로다:
`await()`는 "완료될 때까지 현재 실행 맥락을 멈춘다"이고 fiber 안에서는 그 fiber를 멈춘다.

동작.

- `AWAIT` 명령이 fiber 안에서 미완료 Future를 만나면 `Fiber.await_single`에 Future를 적고 `FIBER_SWITCH_OUT`으로
  resume한 쪽에 `.suspended`를 돌려준다. `Fiber.pc`는 그 `AWAIT` 명령 자신이라 다음 resume이 같은 명령을 다시 실행한다.
  아직 미완료면 다시 멈춘다. 그래서 "대기 중인 fiber의 resume은 본문에 들어가지 않는다"에 따로 코드가 없다. 힙 할당도 없다.
- `Future.wait_any`(builtin `@await_any`)는 fiber 안에서 `RET_FIBER_AWAIT`(3)를 돌려주고 `CALL_HOST`가 fiber를 멈춘다.
  resume 때 같은 호출이 다시 실행된다. 기다리는 목록은 `Fiber.await_ptr` · `await_len`이고, fiber가 소유한 사본이다
  (`await_owned`, Future마다 참조 하나). 호출이 받은 `[&]Future`는 빌린 것이라 fiber가 멈춘 동안 다른 맥락이 목록을
  바꾸거나 해제할 수 있고, `wait_ready` · `waiting`은 fiber 밖에서 그 Future들을 읽는다. 다시 실행된 호출도 인자가
  아니라 사본을 본다. 사본은 호출이 값을 돌려줄 때 반납한다(커밋 뒤 자동 보안 리뷰가 지적해 고쳤다).
- `FIBER_RESUME`이 대기 기록을 지운다. 멈춘 명령이 다시 실행되며 필요하면 다시 적는다.
- fiber 안의 await는 대기 큐의 스레드 작업을 직접 실행하지 않는다(루트의 await는 한다). 처음에는 멈추기 전에 하나
  실행하게 했는데, 그 작업이 fiber 안에서 끝까지 돌아 다른 fiber가 시작도 못 했다(Release 빌드의 테스트가 순서로 잡았다).
  큐의 작업은 `wait_ready`가 루트에서 실행한다. 그래서 워커가 없는 풀(cpu 1개)에서는 `wait_ready`를 부르지 않는
  루프가 끝나지 않는다.
- `Fiber.wait_ready()`(builtin `@fibers_wait`): 스레드의 fiber 목록에서 `SUSPENDED`이고 대기 기록이 있는 것을 훑는다.
  하나라도 끝났으면 `true`, 기다리는 fiber가 없으면 `false`. 아니면 기다린다: spawn의 Future가 섞여 있으면 VM 안에서,
  호스트 Future뿐이면 `Compiler.await_buf`에 전부 모아 `CL_AWAIT`(`cl_vm_pending_futures`가 그 목록을 돌려준다).
  fiber 안에서 부르면 `Fiber.await_fibers`를 켜고 그 fiber를 멈춘다(중첩 스케줄러용).
- `Fiber.waiting()`: 대기 기록이 있고 아직 끝난 Future가 없는지.

결정.

1. 런타임 스케줄러를 두지 않았다. 누가 다음에 도는지는 스크립트의 resume 루프가 정한다. 다음 단계의 범위 객체
   (구조적 동시성)가 자식들을 돌리는 자리이고, 전역 큐는 그와 겹친다. 런타임이 주는 것은 "모두가 대기 중일 때 쉬는 법"
   (`wait_ready`) 하나다.
2. `resume`의 반환값은 `.suspended` · `.done` 그대로다. 네 번째 상태(`.waiting`)를 넣지 않고 `waiting()`으로 묻는다.
   `FiberStatus`가 `GeneratorStatus`와 같은 모양으로 남는다.
3. 0.4.8의 "fiber 안 await도 eval을 탈출한다"(tars-agent 요청 8번)를 바꿨다. fiber를 쓰면서 호스트 Future를 기다리는
   스크립트는 루트에서 `Fiber.wait_ready()`를 불러야 한다. 부르지 않는 루프는 호스트에 돌아가지 않고 상한까지 돈다.
   tars-agent에 알릴 것.
4. 루트 맥락의 await는 그대로다(spawn Future는 spin, 호스트 Future는 `CL_AWAIT`). spawn한 스레드의 루트가 호스트
   Future를 기다리면 여전히 panic이다. 그 스레드 안의 fiber는 멈출 수 있지만 `wait_ready`가 같은 panic을 낸다.

테스트: behavior `concurrency/fiber_await.cy`(spawn Future 교차 실행, `FutureResolver`, `wait_any`, 중첩 fiber,
generator 본문), lib `Fibers that await host futures run interleaved, and the host sees all of their futures.`와
기존 fiber · abandon 테스트 갱신.

남은 것: 취소(멈춘 fiber의 스택 풀기) · 범위 문법 · 오류 전파(구조적 동시성), `CL_YIELD`, AOT.

## 구조적 동시성 (2026-11-12 시작)

사용자 결정(2026-11-12): 범위는 블록 문법(`scope |s|:`), 실패 정책 기본값은 "하나 실패하면 나머지 취소", 취소는
강제 풀기(프레임의 값은 해제하되 사용자 코드는 더 실행하지 않음. `await`의 타입은 그대로), 진행 중인 fiber의 소멸은
panic 대신 취소. 목표는 0.5.

순서.

1. `Scope` 타입과 합류(2026-11-12 구현). `core.cy`의 `Scope` · `ScopeState`, `@scope_entry[Sig]`, `@start_scope_fiber`
   (`@start_fiber`와 같은 호스트 함수. 상태 참조가 복사되는 인자의 첫 칸이다).
2. 자식의 `!void` 반환과 오류 전파(같이 구현). `@scope_entry`가 `try`로 받아 `ScopeState.err`에 첫 오류를 둔다.
3. 취소(2026-11-12 구현). 아래 "취소 구현".
4. `scope` 블록 문법, 범위 안 빌림 허용.

취소 구현(2026-11-12).

- sema `semaCancelPad`가 호출(`.call` · `.call_ptr` · `.call_union` · `.call_trait`, `@call`) · `suspend_` · `await_` IR 노드마다
  정리 블록(cancel pad)을 붙인다: `semaDestructBlock2(procBlock)` + `.ret`. `return`과 같은 해제 루틴이라 사용자 `@deinit`이
  불린다. 노드 주소 → 블록 맵은 `Chunk.cancel_pads`. 살아 있는 지역의 해시가 같은 연속 지점은 블록을 공유한다
  (`Proc.cancel_pad_sig`). 메인 블록과 제너레이터 proc에는 만들지 않는다. 패드 안의 소멸자 호출에는 패드를 붙이지 않는다.
- 식 중간의 값: 호출 IR을 만들기 직전 `semaCancelHoist`가 소유한 관리 값이 대기 중(`seq_pending`)이면 `seqFlush`로 지역에
  올린다. 호출 자신의 인자는 그 전에 `seqPop`으로 소유가 넘어가 있어 패드에 들지 않는다(피호출자의 패드가 매개변수를 해제).
  `seq_pending`이 덮지 않는 식 모양(인덱스 식, 캐스트 인자 등)의 임시 값은 취소 때 누수된다(이중 해제는 아니다).
- bc_gen: 지점에서 `push_cancel_site`가 `bc_local_map` 사본 · `reg_end` · 인라인 사슬(지점의 패드 + 바깥 인라인 호출들의 패드)을
  적어 두고, 함수 본문 뒤 `gen_cancel_pads`가 그 상태로 패드를 생성한다(인라인 금지, 포인터 레이아웃 기록 없음). 패드의
  `.ret`는 사슬의 마지막에서만 실제 반환이 된다. 표는 `ByteCodeBuffer.cancel_table`(지점 pc → 패드 pc). 정상 실행 경로에는
  명령이 늘지 않는다. ReleaseFast에서 `fib(32)`와 문자열 연결 30만 회의 시간이 변경 전과 같았다(0.08초).
- 지점 pc: 호출은 호출 명령의 pc(`FrameInfo.prev_context`가 돌려주는 값), `SUSPEND`는 다음 명령(`Fiber.pc`), `AWAIT`와
  `CALL_HOST`(`@await_any` · `@fibers_wait`)는 명령 자신.
- 런타임: `Thread.unwindFiber`가 멈춘 fiber의 프레임을 위에서부터 걸어 전부 패드가 있는지 확인한 뒤, `Fiber.pc`와 각 프레임의
  반환 주소(`base[1]`)를 패드로 바꾼다. 패드가 없는 프레임(제너레이터 본문, 패드 안에서 부른 소멸자)이 있으면 아무것도 바꾸지
  않고 false. `Fiber.cancel()`(core.cy)이 그 뒤 한 번 resume하면 패드들이 차례로 돌아 `FIBER_END`에 닿는다. 그 resume이
  `.done`이 아니면(소멸자가 suspend) panic.
- `Fiber.@deinit`은 `cancel()`을 먼저 부른다. 취소 못 한 fiber는 이전처럼 `Fiber is still in progress.` panic.
- `Scope.run`은 오류 뒤 남은 자식을 `cancel()`한다. 취소 못 한 자식은 끝까지 돌린다.

남은 것: 4번(`scope` 블록 문법, 범위 안 빌림), 제너레이터 본문 프레임의 취소, `seq_pending` 밖의 임시 값, 블록을 오류로
나갈 때 합류 대신 취소할지(지금 `Scope.@deinit`은 합류한다. 블록 문법에서 sema가 출구 종류를 구분할 수 있다).

(구현 전의 조사 기록) 
지금의 한계: 오류 뒤에 시작하지 않은 fiber만 버린다(`@fiber_cancel`). 진행 중인 fiber는 끝까지 돈다. 3이 들어가면
정책 A가 완성된다. `Scope.@deinit`은 합류한 뒤 남은 오류를 `panic_unwrap_error`로 올린다.

취소의 구현 방법(조사 결과, 미구현).

- 끝나지 않은 제너레이터의 소멸이 같은 문제를 한 프레임에 대해 풀고 있다: sema가 `yield`마다 정리 블록
  (`semaDestructBlock2(procBlock)` + 끝 표시)을 만들고 `RET_Y`가 `Generator.deinit_pc`에 그 주소를 둔다. `GEN_END`가 거기로 뛴다.
- fiber는 호출 깊이 어디서든 멈추므로 멈춘 스택의 모든 프레임이 "호출 도중"이다. 호출 지점마다 정리 블록(또는 살아 있는
  소유 레지스터의 표)이 필요하다. 반환 주소 → 정리 블록 표를 두고, 취소가 각 프레임의 반환 주소를 정리 블록으로 바꿔
  fiber를 한 번 resume하면 위에서부터 차례로 정리하고 `FIBER_END`에 닿는다. 평소 실행 비용은 없다.
- 어려운 점: (1) 식 중간의 임시 값(`foo(a(), b())`에서 `b()` 안에서 멈추면 `a()`의 결과). `seq_pending` · `seqFlush`
  (F-98)를 모든 호출 앞에서 강제해 지역으로 올려야 sema가 살아 있는 값을 전부 안다. (2) bc_gen의 임시 레지스터.
  (3) fiber 스택 위에서 도는 제너레이터 본문 프레임. (4) panic 경로는 힙을 통째로 버려 프레임별 해제가 없으니 재사용 불가.
  (5) 호스트 쪽 `destructValueAt`은 사용자 `@deinit`을 부르지 않으므로 표 + 호스트 해제 방식은 정리 의미가 달라진다.

