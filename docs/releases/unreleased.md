# 0.4.3 이후 변경 (미릴리스)

0.4.3(`a26645f1`, 2026-11-06) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의
원본이다. 사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

- `[]T.index(needle)`가 `self[..]`로 자기 자신을 불러 끝나지 않았다. `span().index`를 거친다(`dfaab96a`, F-70).
- `int.parse`가 숫자를 거꾸로 읽고 부호 처리 뒤 빠져나가 `'-5'`가 `error.InvalidCharacter`, `''`가 `0`이었다. 앞에서부터 읽고
  `-` · `+` 접두는 첫 글자 하나만, 빈 문자열 · 부호만 · 숫자 아닌 글자는 `error.InvalidCharacter`. `int('abc')` · `int('')`가 `0`인 것은
  `@init`의 `!else 0`이라 그대로(`dfaab96a`, F-71).
- `Map.keys()`가 옛 `@iterator()` · `@next()` 문법을 써서 컴파일되지 않았다(`dfaab96a`, F-72).
- 호스트 함수를 값으로 쓰면(`g := math.sqrt; g(16.0)`) 세그폴트. `vm.c` `FN_HOST`의 `(1<<63)`이 정의되지 않은 int 시프트라 컴파일러가
  대입을 지웠다. `(u64)1 << 63`으로(`dfaab96a`, F-11).
- `cyber compile` 덤프가 `lnot` · `unwrap_nz` · `sext` · `zext` · `fn_union` · `new` · `trait` · `release` · `release_opt` · `call_trait` ·
  `gen_next` · `memsetz`의 피연산자를 바이트 시절 오프셋으로 읽어 다음 명령의 opcode를 찍었다. `meta.dump_frame`이 프레임 크기를
  `+3`에서 읽어 프레임 밖까지 출력했다(`ca4ea5b8`, F-62 · F-31).
- `^Dyn[Trait]` 값을 `[]T` · `Array` · `ArrayStore`에 넣으면(`xs += d`) impl 객체를 retain하지 않아 use-after-free와 이중 해제
  (ReleaseSafe `integer overflow`). `@copy`의 `.ref_trait` 분기가 impl을 retain한다. 빌림 `&Dyn[Trait]`는 소유하지 않으므로 그대로
  (`e2a7515d`, F-74).
- 64비트를 넘는 10진 정수 리터럴이 조용히 wrap됐다(`9223372036854775808`이 `-9223372036854775808`, `18446744073709551615`가 `-1`).
  이제 컴파일 오류 `Integer literal does not fit the target type.`(`aeded5b1`, F-76). 규칙은 아래 "언어" 절.
- 한 함수에 지역 변수 257개를 두면 컴파일러가 `integer does not fit in destination type` panic으로 호스트 프로세스를 죽였다.
  매개변수 256개(`integer overflow`), 구조체 필드 256개 init도 같은 계열이었다. 모두 컴파일 오류로 보고한다(`04096230`, F-08).
  한계값은 아래 "언어" 절.
- 임베딩에서 첫 eval이 컴파일에 실패하면 다음 eval이 호스트를 죽였다(구문 오류 뒤 SIGSEGV, 의미 오류 뒤
  `@program_init has already been declared`). 다음 eval이 VM을 자동으로 reset하고 처음부터 시작한다. 또 성공한 eval 뒤 실패한
  eval의 함수 · 타입 선언이 `persist_main`으로 넘어가 호출 시 SIGSEGV였던 것도 막았다. "빈 소스로 예열" · 실패 뒤 `cl_vm_reset`
  우회는 더 필요 없다(`f5f2d241`, F-04).
- 폭주 재귀가 VM 스택을 상한 없이 키워 호스트 메모리를 소진했다(1초에 RSS 4.5GB). 스택 상한(기본 128 MiB)에 닿으면
  `Stack overflow. The stack limit is N bytes.` panic이고 VM은 계속 쓸 수 있다(`f03cf24c`, F-40). 아래 "임베딩" 절.
- 루프 본문이 약 9000줄(`s += 1` 기준)을 넘으면 컴파일러가 `integer does not fit in destination type` panic으로 호스트를 죽였고,
  `if` 본문 17000줄도 같았다. 더 나쁜 경우로 `else` 본문이 약 8200~16000줄이면 컴파일은 되지만 `if` 갈래가 실행될 때 VM이 앞 점프를
  음수로 읽어 세그폴트였다. 모두 컴파일 오류 `Function body too large. A jump can span at most N bytecode slots.`로 보고한다
  (`8560b025`, F-09). 한계값은 아래 "언어" 절.
- 65536바이트 이상의 문자열 리터럴이 조용히 잘렸다(`len()`이 65536 → 0, 70000 → 4464. 보간 문자열의 조각도 같음). 컴파일 오류
  `String literal too long. A string literal can have at most 65535 bytes.`로 보고한다(`10f8290b`, F-24).
- 깊은 호출로 VM 스택이 이동할 때 main 블록의 빌림(`p := &x`)과 함수 값 · `Func[T]` · trait(`&Dyn[T]`)로 부른 호출 중 호출자 프레임의
  빌림이 옛 스택을 가리킨 채 남아 쓰레기(`-6148914691236517206`)를 읽었다. main 프레임도 패치하고 세 간접 호출 지점에도 포인터
  레이아웃을 남긴다(`c94f1569`, F-10, `docs/decisions/project_stack_ptr_patch.md`).
- 스크립트가 `use c` 없이 `as[Ptr[int]] 8` · `Ptr[int](8)` · `alloc(int)` · `PtrSpan[int]{length=4}`로 임의 주소를 역참조해 호스트를
  죽일 수 있었다. 새 컴파일 옵션 `deny_raw_ptrs`를 켜면 컴파일 오류다(`534a0a9d`, F-06). 기본값은 false라 CLI와 기존 임베딩 동작은
  그대로. 아래 "임베딩 API" 절.
- 컴파일 타임 평가(`const x = f()` · `type X const:` 본문 · `#{}`)가 복합 대입(`+=` · `-=` · `*=` · `/=`)을 버리고 오른쪽 값을 그대로
  대입했다. `t := 10; t += 5`가 `5`, `for 0..10 |i|: total += i`가 `45` 대신 `9`로, 같은 함수가 런타임과 다른 답을 냈다. 컴파일 타임
  변수 · 벡터 원소 · 역참조 대입 모두 런타임과 같이 `left op right`를 평가한다. 컴파일 타임 벡터 원소 읽기(`v[i]`, 이전 `TODO ct_var`
  오류)를 지원하고, 범위 밖 인덱스는 `Index out of bounds.` 컴파일 오류(이전에는 컴파일러 메모리를 덮어씀). cte가 지원하지 않는
  연산(`float`의 `+` 등)은 복합 대입에서도 `Unsupported inline eval` 오류로 드러난다(`02f39e67`, F-20,
  `docs/decisions/project_cte_op_assign.md`).

## 언어와 표준 라이브러리

- 정수 리터럴(`aeded5b1`): 평범한 10진 리터럴은 i64 범위(−9223372036854775808 ~ 9223372036854775807)여야 한다. 목표 타입이
  `r64`면 u64 범위를 받는다. 비트 패턴은 `u` 접미(`18446744073709551615u`) · 16진 · 8진 · 2진으로 쓰고, 이들도 64비트를 넘으면
  같은 오류다(이전에는 `Error: Overflow`). 단항 `-` 리터럴도 같은 규칙. `docs/docs.md` 정수 절에 적혀 있다.
- 컴파일러 한계(`04096230`): 한 함수 본문(main 블록 포함)의 지역은 256개까지이며 매개변수와 컴파일러가 만드는 숨은 임시
  (`_opt` · `_temp` 등)를 포함한다. 함수 · 람다 · 함수 타입의 매개변수는 255개, 구조체 필드는 255개, C 가변 인자 호출의 인자는
  255개까지. 넘으면 각각 `Too many local variables.` · `Too many parameters.` · `Too many fields.` · `Too many arguments.`
  컴파일 오류. `docs/docs.md` Local variables 절에 적혀 있다. 아직 오류로 바뀌지 않은 한계는 `project_compiler_limits.md`.
- 점프 거리(`8560b025`): 한 갈래(루프 본문, `if` · `else` 갈래, `switch` case 본문, `break` · `continue`가 건너뛰는 구간)는 바이트코드
  32767 슬롯(`s += 1` 같은 단순 문 약 8000개)까지, `else` 없는 `if` 본문은 65535 슬롯까지. 넘으면 `Function body too large.` 컴파일 오류.
  긴 본문은 함수로 나눈다. `docs/docs.md` Local variables 절에 적혀 있다.
- 문자열 리터럴(`10f8290b`): 한 리터럴(보간 문자열의 각 조각 포함)은 65535바이트까지. 넘으면 `String literal too long.` 컴파일 오류.
  긴 텍스트는 여러 리터럴로 나눠 실행 시 이어 붙인다. `docs/docs.md` Strings 절에 적혀 있다.

## 임베딩 API

- `CLEvalConfig.deny_raw_ptrs` · `CLCompileConfig.deny_raw_ptrs`(`534a0a9d`): true면 표준 모듈(`core` · `meta` · `math` · `cy` · `c` · `io` ·
  `test`)이 아닌 청크에서 `Ptr[T]` · `PtrSpan[T]` · `?Ptr[T]` 타입의 식이 `Raw pointer type \`Ptr[int]\` is not allowed. The host disabled
  raw pointers for this script (\`deny_raw_ptrs\`).` 컴파일 오류. `[]T` · `[&]T` · `Map` · `&T` 등 core가 내부에서 포인터로 구현한 타입은
  그대로 쓴다. 신뢰하지 않는 스크립트를 돌리는 호스트는 허용 목록 로더와 함께 켠다(`docs/decisions/project_deny_raw_ptrs.md`).
- `cl_vm_set_stack_limit(vm, bytes)`(`f03cf24c`): main 스레드와 `spawn` 스레드의 VM 스택 상한. 8바이트 슬롯으로 내림,
  0 이하는 무제한, 기본 128 MiB. 넘는 호출은 `Stack overflow.` panic으로 `CL_ERROR_PANIC`. `cl_vm_set_fuel` · `cl_vm_interrupt`와
  함께 쓴다(`src/include/cyber.h`, `docs/decisions/project_stack_limit.md`).
- panic 트레이스가 40프레임을 넘으면 양 끝 20프레임만 남기고 가운데를 `... N frames omitted ...` 한 줄로 줄인다(`f03cf24c`).
  `cl_thread_panic_trace`가 돌려주는 프레임 배열도 같다(생략 프레임은 `chunk` · `line`이 `NullId`).

## 변경

- F-61 죽은 코드 삭제: `src/map.zig`, `vm.h` `Fiber` · `FiberObject`, VM 상수 풀(`consts_ptr` · `getOrPushConst` 등), bc_gen의
  `elseBlocks` · `selectForDstInst` · `GenValue.constant` · `Cstr.none`, `compiler.zig` `resolveCopyCtor` · `resolveFuncTemplate`,
  IR `StmtCode.set` · `ExprCode.mainEnd`(`7a7ee183`). 동작 변화 없음.
- 코루틴 설계의 키워드(`generator` · `fiber` · `suspend`)를 결정했다(`7c05c5c9`, `docs/decisions/project_coroutines.md`). 구현 전.

## 문서

- 발견 이슈 표 · 학습 가이드 갱신: `e66d6316` · `ba0d496d` · `5a75d9c6` · `6e618aec` · `85b5d21b` · `854b4d33` · `6f581b88`.
- fuel 의미를 "fuel N은 검사점 N개를 통과하고 N+1번째에서 멈춤"으로 문서 확정(`ba0d496d`, F-42. 코드 변경 없음).
