# 레지스터에 있는 레코드의 필드 접근과 인라인 `&지역` 인자 묶기

작성일 2026-11-06.

## 배경

`for` 벤치(`src/test/bench/for/for.cy`)는 인라인 작업(`project_bc_inline.md`)이 끝난 뒤에도 Lua의 3.2배(50 ms vs 16 ms)였다.
덤프를 보면 `append` · `next`는 모두 인라인되어 있고 남은 비용은 명령 수 자체다. append 루프 한 바퀴가 17개, `for arr` 루프가
21개 디스패치인데 그중 상당수가 두 패턴이다.

- `addr %r = *%지역` 뒤에 `[%r + 상수]`를 `load_64` · `store_64`. 값 타입 지역(구조체 · option · result · `str` · `[&]T`)은
  레지스터에 메모리 레이아웃 그대로 놓이므로 8바이트 정렬된 필드는 그냥 `지역 + offset/8` 레지스터다.
  `?T`를 만드는 `addr` + `const` + `store` ×2와 그걸 바로 해체하는 `addr` + `load` + `is_zero` + `lnot` + `jump_f`가 여기에 든다.
- 인라인된 `arr.append(i)`의 `self`는 `&arr`를 `addr`로 임시에 담은 포인터고, 본문의 `self.length` · `self.header` · `self.buf`는
  그 포인터로 load · store한다(append 루프 17개 중 7개). 포인터가 가리키는 것이 호출자 지역이므로 역시 레지스터다.

## 결정

bc_gen에서 레코드가 레지스터에 있을 때 주소를 거치지 않는다. 의미는 바꾸지 않는다.

1. 값 타입 지역의 필드(`gen_field` · `gen_set_field` · `genAddressOfField`): `fold_rec_offset`으로 접은 최종 레코드가 `.local`이고
   ref-like가 아니며 바이트 offset이 8의 배수, 필드 크기가 8의 배수(0 제외)면 레지스터 `base + offset/8`을 쓴다. 읽기는 cstr이
   `.simple`이면 그 레지스터를 `.local` GenValue로 돌려주고(명령 없음), 아니면 `mov`. 쓰기는 `gen_set_local`처럼 오른쪽을
   `Cstr.toLocal(reg)`로 생성. 주소는 `addr dst = *(base + offset/8)` 하나. 1 · 2 · 4바이트 필드(`bool` 등)는 레지스터 상위
   바이트가 보장되지 않아 그대로 메모리 경로(`local_field_reg` · `local_field_base`).
2. `init` 직접 생성(`gen_init_regs`): option · choice · result · c_union · struct_t의 모든 필드가 정렬된 전체 레지스터면 목적지
   레지스터에 바로 쓴다. 목적지가 임시면 각 필드 식을 `Cstr.toTemp(dst + offset/8)`로 바로 생성하고, 목적지가 지역이면
   `p = {x=p.y, y=p.x}`처럼 뒤 필드 식이 앞 필드 쓰기를 볼 수 있으므로 모든 인자가 상수 · 목적지 밖의 지역일 때만 직접 생성,
   아니면 인자를 먼저 평가한 뒤 `mov`. vector · partial_vector는 기존 경로.
3. `if !x`(`gen_if_block`): `while opt |v|` · `for` 순회 · `and`가 `lnot(is_zero(...))`로 내려오므로 `lnot`을 빼고 `jump_t`로 분기
   (`push_cond_miss_jump`, `Chunk.pushEmptyJumpCond`). `is_zero`는 64비트 전체 비교라 `jump_f`(bool 1바이트)와 합치지 않는다.
4. 인라인 `&지역` 인자(`gen_inline_call`): 인자가 `address_of(.local)`이거나 이미 묶인 포인터 매개변수(`.local`)면 `addr`를 내지 않고
   callee 매개변수를 `LocalSlot{.kind = .addr_of, .reg = 그 지역}`으로 묶는다. 본문의 `self.field`(`local_field_base`) ·
   `p.*`(`gen_deref`) · `p.* = v`(`gen_set_deref`)는 그 지역의 레지스터를 직접 쓰고, 매개변수를 값으로 쓰는 곳(`gen_local`: 다른 호출에
   넘기기 · 비교 · 저장)에서만 `addr`를 만든다. 본문이 매개변수에 대입하거나(`set_local`) `&param`을 잡으면 저장소가 필요하므로
   묶지 않는다. `check_inline_stmts` · `check_inline_expr`가 본문 전체를 걷는 자리에서 그런 매개변수를 비트마스크로 모아
   `ir.FuncBlock.bc_param_pinned`에 캐시한다(`InlineCount.pinned`).

`bc_local_map`은 `Reg`에서 `LocalSlot`으로 바뀌었다. `toLocalReg`는 `.addr_of` 슬롯이면 panic하므로 매개변수를 레지스터로 쓰는 다른
경로(`gen_release` · 클로저 캡처 · `gen_pop_locals`)는 묶인 매개변수에 닿지 않아야 한다. 람다는 인라인 허용 목록에 없고, 빌림 매개변수는
해제 대상이 아니고, `pop_locals`는 본문 지역만 가리킨다(`popProc`는 varStack만 자른다).

## 함정

- `gen_field`가 `.simple`에 지역 레지스터를 그대로 돌려주면서 `init`의 인자가 목적지 레지스터와 겹칠 수 있게 됐다
  (`v = Vec{x=v.y, y=v.x}`). 주소를 거치는 기존 경로(`gen_init_to`)에도 같은 위험이 생기므로 두 경로 모두 `gen_init_arg`가
  목적지 범위와 겹치는 `.local` 인자를 임시로 복사한다.
- `init_arg_is_simple`의 `.local`은 묶인 매개변수일 수 있다(`return {ptr = self, ...}`). `toLocalReg`가 아니라 `local_slot`로 보고,
  묶인 것은 `addr`만 내므로 단순 인자로 친다. 처음에 이걸 빠뜨려 `tools/cbindgen.cy` 컴파일에서 panic했다.
- VM의 `JUMP_T`(`src/vm.c`)는 쓰는 곳이 없어 bool이 거짓일 때 점프하도록 뒤집혀 있었고 offset도 부호 있는 16비트였다. 참이면 점프,
  offset은 `JUMP_F`와 같은 부호 없는 16비트로 고쳤다. 첫 빌드에서 `os.now()`가 오류 경로로 들어가고 `Array.ensure_cap`이
  `PtrSpan.init` InvalidLen으로 죽은 원인.
- 덤프(`src/bytecode.zig`)의 `is_zero`가 피연산자를 `pc[3]`(다음 opcode)에서 읽었고 `and_` · `xor` · `lsr` · `ult` · `ugt` · `ule` · `uge`는
  덤프 케이스가 없어 빈 줄로 나왔다. 둘 다 고쳤다.
- 지역 레지스터를 그대로 돌려주는 것은 `gen_local`이 이미 하던 일이라 평가 순서 의미는 같다(`x + f(&x)`에서 f가 x를 바꾸면 더하기가
  바뀐 값을 읽는 것도 기존과 같다).

## 결과 (Apple M1 Max, ReleaseSafe, hyperfine wall 10회, `9b378ced` 대비)

| 벤치 | 전 | 후 |
|---|---|---|
| for | 50.3 ms | 39.1 ms (−22%) |
| alloc | 666 ms | 623 ms (−6.5%) |
| fiber | 41.2 ms | 38.6 ms (−6%) |
| heap · fib · string index · index_rare | 31.7 · 29.7 · 80.6 · 56.0 ms | ±1% |
| 덤프 명령 줄(for · heap · fib · alloc) | 10283 · 10801 · 9906 · 11148 | 9259 · 9785 · 8941 · 10044 (−10%) |

append 루프는 17 → 13개(`lt` · `jump_f` · each 지역 `mov` · 인자 `mov` · `const_64` 마스크 · `and_` · `ge` · `jump_f` · `add_mul_i16` ·
`store_64` · `add_i16` ×2 · `jump`), `for arr` 루프는 21 → 15개다.

## 테스트

- `src/test/functions/inline_addr_param.cy`(behavior_test 등록): 값 지역 · 중첩 필드 읽기 · 쓰기, 필드 교환 init, `&지역` 인자로 묶인
  매개변수의 읽기 · 쓰기 · 중첩 인라인 전달, 매개변수를 값으로 돌려주기(`id_ptr`), 재대입되는 매개변수(`pick`), `&param`(`through`),
  `while` 안 `?int` 결과, 1바이트 필드. 2단계: 인라인된 `return {…}`을 임시(rvalue `swap(&v).x` · `rot(&v).sum()` · 더하기의 오른쪽 ·
  선언 지역 `s := rot(&v)`)로 받는 경우, 선언 지역의 식 인자 `init`(`d := Vec{x=v.y + 1, ...}`), 지역 재대입 `v = swap(&v)`가 함께 있음.
- 커밋 전 검증 12단계(네이티브 `zig build test` Debug · ReleaseFast · ReleaseSafe · `-Dtrace=false`, lib-test Debug · ReleaseSafe,
  standalone ReleaseFast, wasm32 behavior · cli · lib · trace) 모두 exit 0.

## 2단계: 인라인 반환의 임시 목적지 (2026-11-06)

`gen_ret_expr` · `gen_set_ret`는 인라인 본문 안에서 반환식을 항상 `Cstr.toLocal(ctx.ret_reg)`로 생성했다. `ret_reg`가 `gen_inline_call`이
새로 잡은 임시거나 호출자가 준 임시 목적지(`.tempReg`)여도 `gen_init_regs`는 지역 규칙(모든 인자가 상수 · 목적지 밖 지역일 때만 직접)을
적용해 `{ptr, length}`처럼 식 인자가 있는 반환은 인자를 임시에 먼저 평가하고 `mov`로 옮겼다.

`InlineCtx.ret_is_temp`(`cstr.type != .localReg`)를 두고 `inline_ret_cstr`가 임시면 `Cstr.toTemp(ret_reg)`를 준다. 임시는 본문이 이름할 수
없다. 새 임시는 인자 임시 · 본문 지역보다 아래에 있고, 호출자의 임시는 호출자 지역이 아니므로 `.addr_of`로 묶인 매개변수도 닿지 않는다.
목적지가 호출자 지역(`.localReg`)이면 `p = f(&p)`에서 본문이 `self.b`로 목적지를 읽을 수 있으므로 지역 규칙을 그대로 둔다.
bc_gen에서 `.localReg`와 `.tempReg`의 차이는 돌려주는 GenValue 종류와 이 `init` 규칙뿐이라 다른 식에는 영향이 없다.

| 벤치 | 전 | 후 |
|---|---|---|
| for | 39.1 ms | 37.6 ms (−4%) |
| heap · fiber | 30.3 · 38.6 ms | 30.1 · 37.5 ms |
| fib | 28.7 ms | 29.1 ms (잡음) |
| 덤프 명령 줄(for · heap · fib · alloc · fiber) | 9259 · 9785 · 8941 · 10044 · 9472 | 9228 · 9754 · 8912 · 10009 · 9441 |

`Array.ensure_cap`의 인라인된 `@slice` 반환에서 `mov` 둘이 빠지고 임시 둘이 줄어 프레임이 25 → 24.

### 선언 지역 목적지

`gen_declare_local`의 init은 `Cstr.toLocal(reg)`로 와서 `gen_init_regs`가 재대입과 같은 지역 규칙을 적용했다. 선언되는 지역은 init 식이
이름할 수 없으므로(sema가 선언 앞 사용을 막고, 가리는 바깥 지역은 다른 레지스터) 임시와 같다. `Cstr.slot.fresh`(`Cstr.toFreshLocal`)를 두고
`gen_declare_local`이 그것으로 생성, `gen_init_regs`는 `fresh`면 직접 쓰고, `InlineCtx.ret_is_temp`도 `fresh`를 포함한다
(`s := f(&v)`의 인라인 반환). `has_aux_local` 선언(`sp := [&]int{...}`)은 `set_local`로 가므로 그대로 보수 경로다.
덤프 `mov` −41 · `mov_3` −10(for), retain · release 수 동일. for 37.4 · heap 29.9 · fib 28.9 · fiber 37.1 · alloc 605 ms(623에서 −3%),
덤프 명령 줄 for 9177 · heap 9702 · fib 8867 · alloc 9956 · fiber 9390.

## 3단계: `and_64` 명령 (2026-11-06)

`Array.cap()`의 `self.header && ~(3 << 62)`는 루프마다 `const_64`(6슬롯) + `and_`로 두 번 디스패치한다. 상수가 i16에 들어가지 않아
`add_i16` 같은 작은 즉시값 명령으로는 안 되고, 단일 패스 bc_gen에 루프 불변 상수를 끌어올리는 자리가 없다. 대신 `and_64 dst, src, imm64`
(7슬롯, `READ_U64(3)`) 하나로 합친다. `gen_and`가 오른쪽 피연산자가 `.const64`일 때만 내고 아니면 `genBinOp2(.and_)`.
`vm.h` `CodeAnd64`는 `CodeAND` 바로 뒤, `vm.c` `JENTRY` 표의 같은 위치, `bytecode.zig` enum · 길이 7 · 덤프 · opcode 수 131 → 132.

A/B(같은 시각에 두 바이너리를 번갈아, hyperfine 10회): for 39.0 → 38.1 ms(−2.3%), alloc · fiber · heap은 ±1%. 정적 덤프에서 `and_64`는
for 12 · alloc 19 · heap 13곳, 명령 줄 for 9177 → 9165. append 루프는 13 → 12개 디스패치. `hash && mask`처럼 마스크가 변수인 Map 탐사는 해당 없음.

## 남은 것

- `for arr` 루프의 `mov %12 = %7`(`i := idx.*`) · `mov %12 = %10`(unwrap 캡처 지역)은 선언 지역을 소스 레지스터의 별칭으로 두면
  없어지지만, 원본이 별칭 수명 안에 바뀌지 않는다는 보장이 sema에 있어야 한다.
- 인라인 인자가 평범한 `.local`일 때의 복사 `mov`(`self` 빌림 지역 · 루프 변수): 본문이 매개변수에 대입하지 않고 호출자 지역이 본문 중에
  바뀌지 않을 때만 직접 묶을 수 있다. 후자를 보장하기 어려워 보류.
