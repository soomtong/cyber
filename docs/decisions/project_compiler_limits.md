# 컴파일러 · VM의 고정 한계와 그 처리 (2026-11-08)

## 배경

컴파일러와 VM의 여러 번호가 좁은 정수형이다. 한계를 넘는 스크립트가 들어오면 Zig의 `@intCast` · `+=`가 safe 빌드에서
panic을 내 호스트 프로세스가 abort했다(발견 이슈 F-08 · F-09 · F-24). 에이전트가 생성한 긴 스크립트를 임베딩해 돌리는 용도
(`project_direction.md`)에서는 스크립트 한 장이 호스트를 죽이는 경로가 가장 먼저 막혀야 한다.

## 결정

폭을 넓히지 않고 sema가 한계를 세어 `CompileError`로 보고한다. 폭을 u16으로 넓히려면 IR의 `extern struct`(`DeclareLocal.id` ·
`FuncParam.reg` · `Call.nargs` · `Field.idx`), `FuncSig.numParams()`, `Proc.numParams`, bc_gen의 지역 매핑과 wasm32 `@sizeOf`
검사까지 번지는데, 에이전트 스크립트가 그 한계에 정상적으로 닿을 이유가 없다. 한계는 상수 `sema.max_proc_locals` ·
`sema.max_func_params` · `sema.max_struct_fields`로 두고 오류 메시지에 값을 찍는다(`04096230`).

## 한계 표

사용자 문서(`docs/docs.md` Local variables 절)에는 "지역 256 · 매개변수 255 · 필드 255"만 적었다. 아래가 전체다.

| 대상 | 한계 | 폭이 좁은 곳 | 넘으면 | 상태 |
| --- | --- | --- | --- | --- |
| 한 함수(main 포함)의 IR 지역. 매개변수 + 선언 지역 + 숨은 임시(`_opt` · `_temp` · `_main_res` 등) | 256 | `LocalVarS.id` · `ir.DeclareLocal.id` · `ir.FuncParam.reg`(u8) | `Too many local variables. A function can have at most 256 locals, including hidden temporaries.` | `04096230` 컴파일 오류. `checkLocalLimit`(`reserveLocalName` · `declareParam`) |
| 함수 · 메서드 · 람다 · 함수 타입의 매개변수 | 255 | `FuncSig.numParams() u8` · `Proc.numParams u8` · `ir.Call.numArgs u8` | `Too many parameters. A function can have at most 255 parameters.` | `04096230`. `checkParamLimit`(`resolveFuncSig` · `pushLambdaFuncParams` · `sema_type.resolveFuncType`) |
| C 가변 인자 함수 호출의 인자(고정 매개변수 포함) | 255 | `ir.Call.numArgs u8` | `Too many arguments. A call can have at most 255 arguments.` | `04096230`. `checkArgLimit`(`sema_func.getVmCVariantFunc`). 일반 호출은 매개변수 한계가 먼저 막는다 |
| 구조체 · cstruct 필드 | 255 | init IR `nargs u8` · `ir.Field.idx u8` | `Too many fields. A struct can have at most 255 fields.` | `04096230`. `checkFieldLimit`(`resolveStructFields`는 256번째 필드 위치에, `reifyStructType`은 타입 노드에) |
| 바이트코드 레지스터 번호 | 65535 | `Inst.val u16`(피연산자 슬롯) | 지역 한계가 먼저 걸려 닿지 않음 | 한계 아님 |
| 문자열 리터럴 길이 | 65535바이트 | `pushConstString`의 `len << 48`(16비트) | 길이가 잘림(70000 → 4464). 오류 없음 | 미처리, F-24 |
| 점프 거리. `jump`(`break` · `continue` · 루프 끝 · if 갈래 끝) · `release` · `release_opt` | 32767 명령 슬롯 | `vm.c` `JUMP`의 `int16_t`, `Inst.val u16` | `Function body too large. A jump can span at most 32767 bytecode slots. Move part of the body into another function.` | `8560b025` 컴파일 오류. `chunk.zig` `checkJump` · `backJump`(`patchJumpToCurPc` · `patchBreaks` · `patchForBlockJumps` · `pushJumpBackTo`), F-09 |
| 조건 점프 거리. `jump_f` · `jump_t`(앞으로만) | 65535 명령 슬롯 | `vm.c` `JUMP_F` · `JUMP_T`의 `pc += pc[2]`(부호 없음) | 같은 메시지, 65535 | `8560b025`. `patchJumpCondToCurPc` · `patchJumpNotCondToCurPc`. 수정 전: 32768~65535 슬롯의 앞 `jump`는 VM이 음수로 읽어 세그폴트, 그 이상은 `@intCast` panic |
| 한 청크의 함수 수 · 심볼 수 | u32 | `FuncSig.id` 등 | 실질적으로 닿지 않음 | 한계 아님 |
| VM 스택 크기 | 상한 없음 | `thread.zig` `growStackAuto`(1.5배) | 무한 재귀가 메모리를 다 쓴다 | 미처리, F-40. 스택 상한과 `RES_STACK_OVERFLOW` 오류가 필요 |

## 검증

- behavior 테스트 `functions/too_many_locals_error.cy`(257개 지역) · `types/struct_too_many_fields_error.cy`(256개 필드).
- lib-test `Compiler limits are compile errors, not panics.`: 함수 · main · 람다 · 함수 타입 · 구조체의 초과 6케이스와 경계값
  (255 매개변수 + 지역 1개 = IR 지역 256, 255 필드 init)이 정상 실행되는 2케이스. 소스는 `repeat_src`로 생성한다.
- 수정 전 재현: 지역 257 `integer does not fit in destination type`, 매개변수 256 `integer overflow`(`numParams += 1`),
  매개변수 257 호출 `integer does not fit`(`numArgs` 캐스트), 필드 300 init `integer does not fit`(`nargs` 캐스트).
- 점프(F-09): lib-test `Jumps past the one-slot offset are compile errors, not panics or runtime crashes.`: `while` 본문 `s += 1` 9000줄(역방향
  `jump`) · `if` 본문 17000줄(`jump_f`) · `else` 본문 9000줄에 `if` 갈래 실행(앞 `jump`, 수정 전 세그폴트)이 오류, 7000줄 루프 · 15000줄 `if`
  (60000 슬롯, u16에 맞음)는 정상 실행. `s += 1`은 `add_i16` 4슬롯. behavior 테스트는 소스가 수천 줄이라 두지 않았다. 오류 위치는 점프를
  가진 문(루프 · `if` · `switch` · `case`)이고, `break` · `continue`의 위치는 `BlockJump`에 없어 둘러싼 루프 문으로 보고한다.

## 기록 규칙

사용자에게 보이는 동작이 바뀌는 수정(버그 · 언어 규칙 · 한계)은 커밋과 함께 `docs/releases/unreleased.md`에 적고, 언어 규칙이면
`docs/docs.md`에도 적는다. 릴리스 때 `unreleased.md`를 `docs/releases/<v>.md`로 옮긴다. 발견 이슈 표(`docs/study/10-findings-register.md`)는
원인 · 위치의 기록이고, 매뉴얼 갱신의 원본은 `unreleased.md`다.
