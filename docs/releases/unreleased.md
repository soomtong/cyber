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

## 언어와 표준 라이브러리

- 정수 리터럴(`aeded5b1`): 평범한 10진 리터럴은 i64 범위(−9223372036854775808 ~ 9223372036854775807)여야 한다. 목표 타입이
  `r64`면 u64 범위를 받는다. 비트 패턴은 `u` 접미(`18446744073709551615u`) · 16진 · 8진 · 2진으로 쓰고, 이들도 64비트를 넘으면
  같은 오류다(이전에는 `Error: Overflow`). 단항 `-` 리터럴도 같은 규칙. `docs/docs.md` 정수 절에 적혀 있다.
- 컴파일러 한계(`04096230`): 한 함수 본문(main 블록 포함)의 지역은 256개까지이며 매개변수와 컴파일러가 만드는 숨은 임시
  (`_opt` · `_temp` 등)를 포함한다. 함수 · 람다 · 함수 타입의 매개변수는 255개, 구조체 필드는 255개, C 가변 인자 호출의 인자는
  255개까지. 넘으면 각각 `Too many local variables.` · `Too many parameters.` · `Too many fields.` · `Too many arguments.`
  컴파일 오류. `docs/docs.md` Local variables 절에 적혀 있다. 아직 오류로 바뀌지 않은 한계는 `project_compiler_limits.md`.

## 변경

- F-61 죽은 코드 삭제: `src/map.zig`, `vm.h` `Fiber` · `FiberObject`, VM 상수 풀(`consts_ptr` · `getOrPushConst` 등), bc_gen의
  `elseBlocks` · `selectForDstInst` · `GenValue.constant` · `Cstr.none`, `compiler.zig` `resolveCopyCtor` · `resolveFuncTemplate`,
  IR `StmtCode.set` · `ExprCode.mainEnd`(`7a7ee183`). 동작 변화 없음.
- 코루틴 설계의 키워드(`generator` · `fiber` · `suspend`)를 결정했다(`7c05c5c9`, `docs/decisions/project_coroutines.md`). 구현 전.

## 문서

- 발견 이슈 표 · 학습 가이드 갱신: `e66d6316` · `ba0d496d` · `5a75d9c6` · `6e618aec` · `85b5d21b` · `854b4d33` · `6f581b88`.
- fuel 의미를 "fuel N은 검사점 N개를 통과하고 N+1번째에서 멈춤"으로 문서 확정(`ba0d496d`, F-42. 코드 변경 없음).
