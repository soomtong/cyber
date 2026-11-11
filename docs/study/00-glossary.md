---
aliases: [용어집, glossary]
tags:
  - study
  - cyber
  - glossary
---

# Cyber 소스 읽기 용어집

> 00~09장에서 쓰는 용어를 한곳에 모았다. 약어 풀이(IR, cte, Cstr 등)는 [약어집](00-abbreviations.md)에 있다. 정의는 각 챕터가 코드로 확인한 내용이며, 자세한 설명은 오른쪽 열의 장에 있다.
> TS/Node 대응은 이해를 돕기 위한 비유이고 정확한 동치가 아니다(일반 지식).
> 줄 번호가 필요한 항목은 HEAD b40531a1 기준이다.

## 읽는 법

- 이름이 같아도 모듈마다 뜻이 다른 용어가 있다. 특히 `Cstr`는 `sema.zig`와 `bc_gen.zig`에 서로 다른 타입으로 있다(아래 표시).
- "죽은 코드"는 import되지 않거나 현재 IR/바이트코드와 맞지 않아 실행되지 않는 코드를 뜻한다.

## 1. 컴파일러 파이프라인

| 용어 | 정의 | 장 |
| --- | --- | --- |
| chunk(청크) | 컴파일 단위. 소스 파일 하나와 그 sema 상태. 내장 `core.cy`도 청크이며 매 실행마다 컴파일된다 | 01, 02 |
| module(모듈) | 이름 공간. 청크의 `symMap`이 곧 모듈이다. `use`로 가져온다. `core`는 모든 청크의 `fallback_modules`로 자동 포함 | 02 |
| sym(심볼) | 이름 있는 모든 것(타입, 함수, 변수, `use` 별칭, 템플릿 등)의 공통 머리. 종류가 21가지다 | 02 |
| reserve / resolve | 심볼 처리의 두 단계. reserve는 이름만 등록하고, resolve는 타입과 시그니처를 확정한다. 선언 순서에 의존하지 않기 위한 구조 | 02 |
| tokenizer(토크나이저) | 소스 문자열을 토큰으로 자르는 단계. TS의 scanner에 대응. 토큰은 8바이트(8비트 타입 + 24비트 시작 위치) | 01 |
| indent 토큰 | 줄 맨 앞 공백/탭 수를 담은 토큰. dedent 토큰은 없고 블록 끝은 파서가 판정한다 | 01 |
| precedence climbing | 이 파서의 이항식 방식(Pratt가 아님). 모든 연산자가 왼쪽 결합이라 `2 ** 3 ** 2`가 64가 된다 | 01 |
| parser / AST | 토큰으로 구문 트리를 만드는 단계(재귀 하강). 노드는 `ast.zig`에 정의. 노드는 아레나에 `[태그 1바이트][페이로드]`로 놓이고 `NodeType`(120개)의 순서는 `builtins/cy.cy`의 `Node`와 같아야 한다(중간에 끼우면 `cy.parse`가 조용히 깨진다) | 01 |
| `cy.parse` | 파서를 Cyber 코드에서 호출해 AST를 받는 API. 프런트엔드를 관찰하는 도구 | 01 |
| `fallback_modules` | 이름을 못 찾을 때 core에서 찾게 하는 목록. `print`와 `str`이 `use` 없이 보이는 이유 | 01, 02 |
| `mod_root` | 0.4.6까지 CLI가 표준 모듈 `.cy`를 읽던 기준 경로(빌드 옵션 또는 실행 파일 옆 `src/`). 0.4.7부터 CLI는 내장 소스를 쓰고, 이 빌드 옵션은 테스트가 기대 트레이스의 경로를 만드는 데만 쓴다 | 01, 08 |
| sema | 의미 분석. 이름 해석, 타입 검사, 소유권 삽입, IR 생성을 한 번 훑으면서 한다. TS의 binder + checker에 대응. `sema.zig`는 10.6K줄 | 03 |
| `ExprResult` | sema에서 식 하나를 처리한 결과(타입, IR 노드, 소유 여부, 주소 가능 여부, 출처 지역) | 03 |
| `Cstr`(sema) | `sema.zig:3735`. 식에 내려보내는 기대 타입과 변환/오류 정책 | 03 |
| `Cstr`(bc_gen) | `bc_gen.zig:3315`. 값을 어디(임시 레지스터, 지역 레지스터, 버림 등)에 놓을지에 대한 제약. sema의 `Cstr`와 다른 타입이다 | 04 |
| `host_builtin` | Zig로 구현되어 sema 중에 IR을 직접 만드는 내장 함수. `await_` 문장과 `gen_next`/`gen_end` 식이 이렇게 만들어진다 | 03 |
| IR | sema의 산출물. 코드젠 직후 버려진다. 청크 arena에서 노드별로 할당되고 포인터로 연결된다. `else`가 없고 모든 분기는 `block`/`if_block`/`break_`로 풀린다 | 03 |
| cte | 컴파일타임 평가기. VM이 아니라 AST 인터프리터이며 `Compiler.heap`("compile-time heap")을 쓴다 | 03 |
| `ct_inline` | cte가 계산한 값을 IR 상수로 바꾸고 `#if`/`#for`를 sema와 잇는 모듈 | 03 |
| `EvalInt` / `EvalStr` | 컴파일 타임에만 존재하는 정수/문자열 타입 | 03 |
| bc_gen | IR을 바이트코드로 번역하는 단계. 소유권과 소멸자는 이미 IR에 박혀 있어 번역만 한다 | 04 |
| `ByteCodeBuffer` | 바이트코드 명령 목록과 부가 테이블(debugTable, func_table, ptr_table, inline_sites)을 담는 구조 | 04 |
| `@program_init` / `@program_deinit` | 컴파일러가 만들어 넣는 숨은 함수. 전역 초기화와 종료 정리를 맡는다 | 01, 04 |
| `reg_end` | bc_gen이 함수를 생성하는 동안 다음 빈 슬롯 번호. 임시 레지스터 스택의 꼭대기 | 04 |
| `GenValue` | bc_gen에서 식 하나를 생성한 결과가 놓인 위치(레지스터 등) | 04 |
| dump(덤프) | `cyber compile file.cy`가 출력하는 함수별 명령 목록. 일부 명령은 피연산자가 잘못 찍힌다(F-62) | 04 |

## 2. 타입과 표현

| 용어 | 정의 | 장 |
| --- | --- | --- |
| `Type` / kind | 타입은 `Type*` 포인터로 동일성을 비교한다. kind는 struct_t, enum, choice, option, result, pointer, borrow 계열, func_ptr, vector, trait 계열 등 | 02 |
| `reg_size` | 값이 차지하는 스택 슬롯(8바이트) 수. `(size+7)>>3` | 02, 04 |
| 값 타입 / `^T` | 값 타입은 스택에 inline. `^T`는 힙 박스를 가리키는 공유 참조(ARC) | 02, 06 |
| `&T` / `&&T` | 빌림 / 배타 빌림. `&T`도 가변이라는 점이 Rust와 다르다 | 06 |
| `Ptr[T]` | 원시 포인터. `as[Ptr[T]]` 캐스트로 임의 주소에 접근할 수 있다(F-06) | 02, 08 |
| Option `?T` | 값 있음/없음. 자식이 포인터, 함수 포인터, eval_ref면 `zero_union`(0 = none) 한 칸, 그 외는 태그 + 페이로드 | 02 |
| `zero_union` | 0이 곧 none인 Option의 한 칸 표현. `unwrap_nz` 명령이 쓴다 | 02, 03 |
| Result `!T` | 에러 또는 값을 담는 choice 타입. 예외가 아니다. `error=0`, `result=1` | 02 |
| choice | 태그(i64, 오프셋 0) + 페이로드(오프셋 8)의 tagged union | 02 |
| `.?` | Option 언랩. none이면 `Expected active choice tag` 패닉. 검사 없는 경로는 `meta.access_*` 계열뿐 | 02, 03 |
| trait / `Dyn[T]` | 인터페이스와 그 동적 디스패치 컨테이너. 동적 디스패치는 `^Dyn[Shape]`로만 한다 | 02 |
| template(템플릿) | 제네릭. `type C[T Any]`, `fn f[T]`. 확장 결과는 `Instance`로 캐시된다 | 02 |
| hash-consing | 같은 값이면 같은 포인터를 돌려주는 캐시. 템플릿 인스턴스와 `FuncSig`가 이렇게 관리된다 | 02 |
| `type X const:` | 타입 평가로 특수화하는 타입 템플릿 | 02, 03 |
| attribute(속성) | `#[...]`. `extern`, `bind`, `reserve`, `cond`, `generator`, `unsafe`, `consteval`, `jit` 여덟 개가 고정 목록 | 01 |

## 3. VM과 실행

| 용어 | 정의 | 장 |
| --- | --- | --- |
| `Inst` | 명령 단위. u16이다. 첫 단위의 하위 바이트가 opcode이고 피연산자는 u16 단위(큰 값은 u32/u48/u64를 나눠 저장) | 04, 05 |
| opcode | 132개. `vm.h`의 `OpCode` enum이 의미의 기준이다 | 04 |
| slot(슬롯) | 스택의 8바이트 칸 | 05 |
| `%N` | 덤프에서 `fp` 기준 슬롯 번호. `stack[N]` | 04, 05 |
| fp | 현재 함수 프레임의 첫 슬롯. callee 기준으로는 반환 슬롯의 맨 앞 | 05 |
| base | `CALL`이 callinfo를 쓰는 위치. 반환 슬롯 바로 다음. 덤프에서는 `dst + ret_size` | 05 |
| callinfo | 프레임 종류(vm/host/init/gen)와 호출 명령 길이를 담은 u64 비트 필드 | 05 |
| 호출 프레임 | `[ret_size개 반환 슬롯][callinfo][ret pc][prev fp][callee][인자들][지역/임시]`. 호출자와 피호출자의 프레임이 겹쳐 인자와 반환값을 복사하지 않는다 | 04, 05 |
| `CHK_STK` | 함수 첫 명령. `stack -= ret_size`로 반환 슬롯을 프레임 앞에 두고 스택 여유를 검사 | 05 |
| computed goto | 라벨 주소 테이블로 한 명령의 끝에서 다음 명령으로 바로 점프하는 디스패치. 빌드는 항상 `-DCGOTO=1` | 05 |
| `execBytecode` | `vm.c`의 인터프리터 루프(416줄~). `register Inst* pc`, `register Value* stack`를 지역 변수로 둔다 | 05 |
| `ResultCode` | `RES_SUCCESS`, `RES_AWAIT`, `RES_PANIC`, `RES_STACK_OVERFLOW`, `RES_UNKNOWN`, `RES_INTERRUPT`. `STACK_OVERFLOW`는 오류가 아니라 스택 확장 요청 | 05 |
| checkpoint(체크포인트) | fuel과 interrupt를 확인하는 자리. 역방향 `JUMP`와 `CALL` 계열 | 05 |
| fuel | 체크포인트 횟수 상한. 소진되면 `CL_ERROR_INTERRUPT`. N이면 N번 통과하고 N+1번째에서 멈춘다 | 05, 08 |
| interrupt | 다른 스레드가 `cl_vm_interrupt`로 거는 외부 중단 요청 | 05, 08 |
| host function(호스트 함수) | `#[bind] fn`에 연결된 C/Zig 함수. `HostFn = uint8_t (*)(ZThread*)`. 인자와 반환을 스택 슬롯으로 주고받는다 | 05, 08 |
| `#[bind]` | 선언을 호스트 표의 이름과 연결하는 속성 | 05, 08 |
| `ptr_table` / `ptr_layouts` | 호출 지점마다 "이 프레임의 어느 슬롯이 스택 안을 가리키는 포인터인가"를 적은 표. 스택이 재할당될 때 포인터를 패치하는 데 쓴다. 패닉 정리용이 아니다 | 04, 05, 06 |
| `debugTable` | pc에서 소스 위치로의 변환표. 스택 트레이스와 에러 메시지에 쓰인다 | 04, 05 |
| `inline_sites` | 인라인된 호출 본문의 pc 범위. 스택 트레이스에서 인라인된 프레임을 복원한다 | 04 |
| unwind(언와인드) | 패닉 시 스택을 거슬러 올라가며 트레이스를 만드는 과정. 지역 소멸자는 돌리지 않고 `freeHeapPages`로 힙을 통째로 쓸어 버린다 | 05, 06 |
| inline(인라인) | 작은 leaf 함수를 호출 없이 호출 지점에 펼치는 최적화(bc_gen 단계). 노드 40개 한도 | 04 |

## 4. 메모리와 소유권

| 용어 | 정의 | 장 |
| --- | --- | --- |
| ARC | 자동 참조 계수. 이 언어에서는 `^T`에만 적용된다 | 06 |
| 객체 헤더 | 힙 객체 앞 8바이트. `meta`(28비트 타입 id + 플래그), `rc` | 06 |
| 풀 / 큰 객체 | 본문 32바이트 이하는 40바이트 풀 슬롯(`HeapPage`당 102개), 초과는 allocator 블록 | 06 |
| retain / release | rc 증감. 0이면 바로 뒤의 `@deinitObject`로 떨어진다 | 06 |
| owner(소유자) | 스택 값을 정리할 책임이 있는 변수 하나 | 06 |
| move | 소유권을 옮기고 원 변수를 `.dead`로 표시. 이동 후 사용은 컴파일 오류. 함수 반환은 암시적 move | 06 |
| `@copy` / `NoCopy` | 깊은 복사 정의 / 암시적 복사를 금지하는 trait. 멤버에 NoCopy가 있으면 전파된다 | 06 |
| `@deinit` | 소멸자 메서드. 순서는 `@deinit`, 필드 선언 순, `^T` 필드 순 | 06 |
| `scope` / `sink` | 빌림 수명을 묶는 매개변수 / 소유권을 받는 매개변수(존속 여부는 upstream이 정하지 않음) | 06 |
| `ownOrManageArg` | 호출 규약 하나로 정한 인자 소유 규칙. 객체형은 호출자가 관리하고 그 외는 복사해 피호출자가 정리. 호스트 함수도 같다 | 06, 08 |
| `single_run` | "이 프로세스는 eval 한 번만 한다"는 설정. main 지역 변수의 해제 코드를 생략하고 종료 시 힙을 쓸어 버린다(소멸자 건너뜀) | 06, 08 |
| `persist_main` | main의 선언과 지역 변수를 다음 eval로 이월하는 설정. REPL과 에이전트 루프의 상태 유지 수단 | 08 |

## 5. 코루틴과 동시성

| 용어 | 정의 | 장 |
| --- | --- | --- |
| stackful / stackless | 코루틴이 자기 스택 전체를 갖는가 / 프레임 하나만 힙에 두는가. 0.3 fiber는 전자, 0.4 generator는 후자 | 07 |
| fiber(0.3) | `coinit`/`coresume`/`coyield`로 쓰던 stackful 코루틴. 0.4에서 삭제되었고 `src/fiber.zig`와 `vm.h`의 `Fiber`는 죽은 잔재 | 07 |
| `generator fn` | 이렇게 선언한 함수를 호출하면(2026-11-11 전에는 `#[generator]` 속성) `^Generator[Fn]`이 돌아온다. 반환 타입이 시그니처와 달라지는 점에 주의. 빌림 매개변수(`&T` · `[&]T` · `?&T`)는 컴파일 오류(2026-11-08, F-14) | 07 |
| `RET_GEN` / `RET_Y` / `GEN_NEXT` / `GEN_END` | 제너레이터 생성 / yield / 다음 값 / 종료 명령. `RET_Y`는 지역을 되돌려 저장하지 않는다(F-01) | 07 |
| `Future` / `FutureValue` / `FutureResolver` | `spawn`의 결과 / 값 저장 객체 / 완료시키는 쪽. await는 어느 스레드에서나 블록(비-main abort였던 F-07은 2026-11-08 수정) | 07 |
| `Thread` / `spawn` | OS 워커 풀에서 도는 격리된 실행 맥락. 스레드마다 힙과 스택. 인자와 결과는 `@send`로 복사(int 계열과 str만) | 07 |
| colorless | 어떤 함수에서도 `await`를 부를 수 있어 함수에 색이 생기지 않는 성질. 제너레이터에는 색이 있다 | 07 |

## 6. 임베딩, 테스트, 운영

| 용어 | 정의 | 장 |
| --- | --- | --- |
| libcyber | 정적/동적 라이브러리로 만든 임베딩용 런타임. 헤더는 `src/include/cyber.h` | 08 |
| `CLVM` / `CLThread` | VM 핸들 / 스레드 핸들. print 콜백의 첫 인자는 실행 중인 스레드(2026-11-10 전에는 선언과 달리 VM 포인터였다, F-50) | 08 |
| loader / resolver | `use`의 spec을 uri로 바꾸는 콜백 / 소스를 돌려주는 콜백. 허용 목록 로더가 격리의 유일한 수단 | 08 |
| `cont` | Compiler의 "이전 컴파일 상태 재사용" 플래그. 첫 컴파일이 성공해야 true | 08 |
| `fn main() -> T` | 호스트가 스크립트 결과 값을 받는 유일한 경로 | 08 |
| builtin 청크 | `core.cy`로 만든 청크. 표준 타입의 상당수가 Cyber 코드이고 필요한 곳만 Zig 호스트 함수에 연결된다 | 08 |
| TinyCC FFI | `#[extern]` 호출용 C 접착 코드를 libtcc로 메모리에서 컴파일하는 방식. `-Dffi=false`면 extern 호출은 panic | 08 |
| cytest | `.cy` 파일 끝 주석 `--cytest: pass\|error\|panic`으로 쓰는 기대값 지시자. 해석은 `behavior_test.zig`가 한다 | 08 |
| behavior-test | `behavior_test.zig`의 수작업 목록(경로 284개)으로 도는 테스트. 목록 밖 파일은 실행되지 않는다(F-64) | 08 |
| trace 빌드 | `-Dtrace=true`. `-v`로 컴파일 각 단계 로그, 바이트코드 덤프, 런타임 호출 트레이스를 낸다 | 01, 05 |
| 결정 문서 | `docs/decisions/*.md`. 이 fork의 방침과 변경 이유를 먼저 적어 두는 곳 | 09 |
