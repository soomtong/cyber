# 바이트코드 생성 단계의 작은 함수 인라인 (1단계: leaf 함수)

작성일 2026-11-02.

## 배경

VM의 `CALL` · `CHK_STK` · `RET`은 이미 가볍다(저장 몇 개, 스택 검사 하나, checkpoint 하나). 남은 격차는 호출 횟수 자체다.
for 벤치(배열 100만, 58 ms, python 41 ms)는 `Array.next`, `Array.append`, Map은 `set` → `findSetSlot` → `AutoHash` 같은 작은
함수 호출이 반복마다 일어난다. core.cy에서 손으로 식을 풀어 쓰는 방식(`project_array_index_calls.md`)은 거의 다 썼다.

## 결정

`bc_gen.gen_call`에서 조건을 만족하는 사용자 함수는 `call` 대신 callee의 IR(`func.data.userFunc.loc`의 `funcBlock`)을
caller의 proc 안에서 그대로 생성한다.

호출 규약상 callee 프레임은 `[ret][호출 정보 4칸][params][locals]`이고 caller의 `base - ret_size`부터와 같다. 인라인은
이 프레임을 흉내 내지 않고 더 단순하게 한다.

1. 반환값용 임시 레지스터를 잡고, 인자를 차례로 임시 레지스터에 생성한다(호출과 같은 평가 순서).
2. `Chunk.inline_ctx`를 켜고, callee IR local id `i`가 `bc_local_map[local_base + i]`를 가리키도록 한다. 매개변수 `i`는
   인자 레지스터에 묶는다. `toLocalReg` · `reserve_local` · `gen_pop_locals`가 `local_base`를 더한다.
3. `ret_expr` · `set_ret`은 `Cstr.toLocal(0)` 대신 반환 레지스터로, `ret` · `ret_expr` 뒤에는 끝으로 가는 `jump`를 내고
   마지막에 고친다. 본문 최상위의 마지막 `ret_expr`이면 jump를 생략한다.
4. 끝나면 local map과 레지스터를 되돌리고, cstr에 따라 반환 레지스터를 옮기거나(`push_mov`) 임시로 돌려주거나 버린다.
5. 인라인 중에 생성한 명령의 디버그 심볼은 호출 지점 노드로 기록한다(callee 노드는 다른 chunk의 소스 위치라 caller
   chunk id로 기록하면 줄 번호가 틀리거나 범위를 벗어난다). `genStmt`의 Trace용 `formatTrunc`도 caller encoder로 callee
   노드를 읽지 않게 한다.

## 1단계 대상 조건 (보수적인 허용 목록)

- `func.type == .userFunc`, generator · jit · lambda 아님, 매개변수 8개 이하.
- 문장: `declare_local`, `set_local`, `set_ret`, `set_field`, `set_deref`, `set_global`, `ret`, `ret_expr`, `if_block`,
  `block`, `discard`, `nop_label`, `pop_locals`, `release`, `trap`. 루프 · switch · try · yield · await · captured는 거부.
  `trap`은 사용자 함수 끝(마지막 `return` 뒤)에 붙는 도달 불가 표시라 인라인 중에는 생성하지 않고, `return` 뒤에 `trap`만
  있으면 본문 끝으로 본다. 처음에 `trap`을 허용 목록에 넣지 않아 사용자 함수가 하나도 인라인되지 않았다.
- 식: local, 상수, 이항 · 비교 · 단항 연산, field, cast, bitcast, address_of, deref, trunc, sext · zext, init, init_zero,
  retain, string, global, intrinsic 호출(`dtor_str` · `cmp_str` · `copy_str`). 그 밖의 호출은 거부(leaf).
- panic할 수 있는 식은 거부: 정수 `/` · `%`(0으로 나누기), 런타임 cast, `unwrap_nz`. leaf라 호출도 루프(역방향 jump
  checkpoint)도 없으므로, 인라인된 본문은 panic · 중단 지점이 될 수 없고 스택 트레이스가 인라인 전과 똑같다.
- IR 노드 수 40 이하. 결과는 함수별로 캐시.

## 스택 트레이스를 지키는 이유

처음에는 정수 나눗셈도 허용했는데 lib 테스트 "Stack trace unwinding."(`foo`가 `a / 0`으로 panic하면 `foo` 프레임이
보여야 함)이 깨졌다. 스크립트 언어에서 사용자 함수가 트레이스에서 사라지는 것은 디버깅 비용이 커서, 테스트를 고치지 않고
panic할 수 있는 함수를 인라인 대상에서 빼는 쪽을 택했다. 핫 경로 대상(`Array.next` · `iterator` 등)은 panic하지 않아서
성능 차이는 없었다. callee 본문은 별도로도 계속 생성된다(함수 포인터 · 인라인 조건 밖 호출용).

## 구현 메모

- 캐시: `FuncInfo.bc_inline: u2`(0 미정, 1 가능, 2 불가). `padding`을 u5 → u3으로 줄였다.
- `Chunk.inline_ctx`(`bc.InlineCtx`)와 `Chunk.inline_local_base`. 인라인 안의 인라인은 하지 않는다(leaf라 해당 없음).
- 반환 레지스터: cstr가 `localReg` · `tempReg`면 그 레지스터에 바로 쓴다(인자는 먼저 새 임시로 복사되므로 `x = f(x)`도
  옛 값을 읽는다). 그 밖에는 임시를 잡는다. 처음에는 항상 임시 + `mov`였고, 바로 쓰기로 for가 약 5% 더 빨라졌다.
- `reg_end`가 160 이상이면 인라인하지 않는다(레지스터 창 여유).
- `nop_label`은 라벨 문자열이 callee chunk의 IR 버퍼에 있어서 인라인 중에는 내지 않는다.
- 테스트: `src/test/functions/inline_leaf.cy`(조기 반환, void, struct 반환, 버린 결과, 메서드, `x = f(x)`, 루프, str),
  `inline_leaf_panic.cy`(0으로 나눌 수 있는 함수는 인라인되지 않아 자기 프레임이 트레이스에 남음).

## 결과 (ReleaseSafe, hyperfine wall, 부하 높은 상태라 30회)

for 58.7 → 53.4 ms(−9%), fiber 38.7 → 35.2 ms, alloc 745 → 710 ms, 나머지는 잡음 수준. 효과가 작은 이유는 핫 함수
대부분(`Array.append` → `ensure_cap`, `HashMap.set` → `findSetSlot`, `findSetSlot`의 while 루프, `@index_addr`의 panic 경로)이
호출이나 루프를 품어 leaf가 아니기 때문이다. 다음 단계 후보: 본문 안의 일반 호출 허용(드문 경로의 panic · `ensure_cap` 호출은
그대로 call로 남김), 그다음 루프 허용(break · continue의 block_offset 처리 필요).

# 2단계: 인라인 프레임을 트레이스에 펼치기, 본문 안 호출 허용

작성일 2026-11-03.

## 결정

1단계는 "인라인된 본문은 panic할 수 없다"는 조건으로 트레이스를 지켰다. 2단계는 조건 대신 디버그 정보로 지킨다.

1. 인라인 1회마다 caller chunk의 `funcs_debug`에 callee 항목(`func`, 이름, `src_chunk = func.decl.src()`)을 하나 추가한다.
2. 인라인 중에 기록하는 DebugSym은 노드가 callee 소스(`node.src() == callee src_chunk`)이면 `loc = 노드 위치`,
   `frameLoc = 그 callee 항목`으로 기록한다. 그 밖의 노드(호출 지점 등)는 1단계처럼 호출 지점과 caller proc으로 기록한다.
   `getStackFrame`은 줄 번호를 `sym.file`이 아니라 `funcs_debug[frameLoc].src_chunk`로 계산하므로 다른 chunk의 위치도 맞다.
3. `ByteCodeBuffer.inline_sites`에 `{start, end, call_loc, caller_frame}`(pc는 버퍼 오프셋)를 남긴다. 중첩 인라인이 없어
   구간은 겹치지 않고 pc 순서로 쌓인다.
4. `debug.allocStackTrace`는 VM 프레임의 pc가 인라인 구간 안이면 프레임 두 개(callee, 호출 지점의 caller)로 펼친다.
   그래서 인라인 여부와 관계없이 트레이스가 같다.

이 장치로 1단계의 panic 가능 식 거부(정수 `/` · `%`, 런타임 cast)를 풀고, 본문 안의 일반 `call`을 허용한다(호출된 함수는
인라인하지 않는 한 단계만). 핫 경로 대상은 `Array.@index` · `@set_index`(드문 경로의 `panic_oob`), `append`(`ensure_cap`),
`HashMap.set`(`grow` · `findSetSlot`).

panic 때 unwind는 프레임 기록만 하고 지역 변수를 해제하지 않으므로(힙 페이지 통째 해제) 인라인 지역 변수의 해제 정보는
필요 없다. 호출 지점의 스택 포인터 레이아웃(`ptr_table`)은 인라인 지역 변수도 caller proc의 `reserve_reg`로 잡으므로 이미 맞다.

## 2단계 구현 메모

- 처음에는 callee 소스가 아닌 노드를 1단계처럼 호출 지점 + caller 프레임으로 기록했다. 소스 노드가 없는 생성 함수
  `@program_init`이 main에 인라인되자 그 안의 `@init` 호출 심볼이 caller 프레임을 가리켜, 펼치면 `main`이 두 번 나왔다
  (cli 테스트 "Stack traces."). 인라인 중에는 항상 callee 프레임으로 기록하고, callee 소스가 아닌 노드는 위치를 `NullId`로
  두어 숨은 함수처럼 보이게 했다.
- 새로 인라인되는 핫 함수: `Array.append`(`ensure_cap` 호출은 그대로), `@index` · `@set_index`(`panic_oob` 호출은 그대로),
  재귀 함수의 한 단계(fib). `HashMap.set`은 노드 40개를 넘어 아직 호출이다.
- 테스트: `functions/inline_call.cy`(본문 안 호출 순서, 재귀, append · 인덱스, str 원소), `inline_call_panic.cy`(인라인된
  `outer` 안의 실제 호출 `inner`가 panic하면 트레이스가 inner · outer · main). `inline_leaf_panic.cy`는 이제 `div`가 인라인된
  상태에서 같은 트레이스를 확인한다.

## 2단계 결과 (ReleaseSafe, hyperfine wall 20회, master `d8ddbe44` 대비)

for 52.8 → 48.8 ms(−7.6%), heap 36.6 → 33.7 ms(−8.1%), fiber 34.9 → 33.1 ms(−5.2%), fib 33.4 → 29.1 ms(−13%),
alloc 696 → 670 ms(−3.7%). 다음 후보: `HashMap.set`(노드 한도 · `findSetSlot`의 while 루프), 루프가 있는 본문 허용,
중첩 인라인(인라인 구간에 부모 구간을 두면 트레이스 펼치기를 그대로 확장할 수 있다).

# 3단계: 중첩 인라인과 `#[inline]` (HashMap.set)

작성일 2026-11-03.

## 원인

`m[k] = v`는 `Map.@set_index`(작은 래퍼) → `HashMap.set` → `findSetSlot` 순서로 호출한다. 2단계에서는 래퍼가 인라인되고
그 안의 `HashMap.set` 호출은 "한 단계만" 제한 때문에 인라인 후보조차 아니었다. `HashMap.set` 자체도 세 가지로 막혀 있었다.

1. `if ... else`가 IR에서 `block` + `if_block` + 블록을 빠져나가는 `break_`가 된다. `break_`는 허용 목록 밖이었다.
2. 일반 이항 · 단항 연산 IR(`binary_op` · `unary_op`, 예: `slot && int.min`)이 허용 목록 밖이었다.
3. IR 노드 87개(str 키 91개)로 한도 40을 넘는다.

## 결정

- 중첩 인라인: `InlineCtx.parent`, 깊이 한도 3, 같은 함수 재진입 금지(재귀는 한 단계만 펼침), 바깥 인라인 하나 아래의
  누적 노드 예산 160. `InlineSite.parent`를 두고, 구간은 본문 생성 전에 자리를 잡아 `start` 순서(부모가 자식보다 앞)를
  유지한다. 빈 본문이면 마지막 항목이므로 지운다. 중첩 구간의 `caller_frame`은 부모 인라인의 callee 항목이고, 호출 노드가
  부모 소스가 아니면 위치를 `NullId`로 둔다.
- 트레이스: `getInlineSite`는 `start <= pc`인 마지막 구간에서 시작해, pc를 포함하지 않으면 부모를 따라 올라간다(구간이
  올바르게 중첩되므로 포함하는 가장 안쪽 구간은 그 후보의 조상이다). `allocStackTrace`는 그 구간부터 부모 사슬을 따라
  caller 프레임을 하나씩 붙인다.
- `break_` · `continue_`: IR `block_offset`은 callee 함수 블록 기준이므로 인라인 중에는 시작 시점의 caller 블록 깊이
  (`InlineCtx.block_base`)를 더한다. 루프는 아직 거부하므로 허용 목록에는 `break_`만 넣었다.
- `binary_op` · `unary_op` 허용(프레임에 의존하지 않는 일반 생성).
- 한도: 기본 40은 유지하고, 함수 속성 `#[inline]`이 붙으면 120. 전역 한도를 100으로 올려 봤을 때 Map은 빨라졌지만 for가
  조금 느려 보였고(잡음 범위) 모든 함수의 코드가 커지므로, 핫 함수에만 명시하는 쪽을 택했다. 속성은 bc_gen이 `funcDecl`의
  attrs를 직접 본다(제네릭 타입의 메서드 인스턴스도 같은 decl을 가리켜 sema 경로를 건드릴 필요가 없다). 지금은
  `HashMap.set`에만 붙였다. 카운터는 전역 변수 없이 `InlineCount{n, limit}`로 넘긴다(VM별 스레드 컴파일 대비).

드문 경로인 `grow`도 함께 펼쳐진다(코드만 조금 늘고 `resize` 호출은 그대로). 필요하면 나중에 "드문 분기 안의 호출은
인라인하지 않음" 같은 규칙을 추가한다.

## 테스트와 결과

- `functions/inline_nested.cy`(else 사슬을 가진 함수의 3단 중첩, 루프 안 if/else, 재귀, Map[int] · Map[str] set/get),
  `inline_nested_panic.cy`(3단 중첩 안의 panic이 inner · middle · outer · main 프레임으로 보임).
- ReleaseSafe, hyperfine 30회, `b40531a1` 대비(부하 있는 상태): Map[int] 100만 채우기+갱신 563.5 → 516.0 ms(−8.4%),
  heap 33.9 → 31.7 ms(−6.6%), alloc 670 → 667 ms, for · fiber · fib는 잡음 범위(fib 함수 본문 바이트코드는 같음).

# 4단계: 루프가 있는 본문

작성일 2026-11-03.

## 결정

허용 목록에 `loop_block`(`while`), `forRangeStmt`(`for a..b`), `continue_`를 더한다. 따로 바꿀 생성 코드는 없다.

- 루프 생성(`gen_loop_block` · `gen_for_range_stmt`)은 break · continue를 고칠 때 `cur_proc.block_depth`(caller proc 기준
  절대 깊이)를 쓰고, 인라인 중의 `break_` · `continue_`는 3단계에서 이미 `InlineCtx.block_base`를 더한다. 그래서 callee의
  break는 callee의 루프로, caller의 break는 caller의 루프로 간다.
- 루프 안의 `return`은 다른 조기 반환과 같이 끝으로 가는 `jump`가 된다. 루프 지역 변수의 해제는 IR이 `return` 앞에 이미
  넣어 둔다.
- 역방향 jump는 VM 검사점(중단 · fuel)이다. 인라인 구간 안의 pc이므로 트레이스는 `inline_sites`로 펼쳐진다.
- `for` 루프 카운터 · 끝 · 조건 레지스터 3개가 caller 프레임에 더해진다. `inline_max_reg_end`(160)는 그대로 둔다.

대상: 루프 있는 작은 사용자 함수, `while opt |v|`(loop_block + unwrap)도 포함. `HashMap.findSetSlot` · `findSlot`(노드
117 · 116)은 기본 한도 40을 넘어 인라인되지 않는다(아래 "시도했으나 버린 것").

## 테스트

`functions/inline_loop.cy`(for · while 안의 조기 반환, continue · break, 끝없는 `while:` 안의 반환, 이중 루프, 인라인 루프
안의 인라인 루프, 인라인된 루프 뒤 caller 자신의 continue · break), `inline_loop_panic.cy`(인라인 루프의 세 번째 반복에서
panic해도 inner · outer · main 프레임).

## 결과 (ReleaseSafe, hyperfine wall, `8fbc0f21` 대비, 부하 있는 상태)

for 50.9 → 51.4 ms(+1.0%, 핫 루프 명령은 pc를 빼면 같음), heap 31.9 → 31.4 ms(−1.6%), alloc 669.8 → 655.7 ms(−2.1%),
fib · fiber · 시작 시간(`print(1)` 7.0 → 7.1 ms)은 잡음 범위. 전체 바이트코드(core 포함 덤프 줄 수)는 약 23% 늘었다.
for 벤치에서 새로 펼쳐진 것은 오류 경로의 `@destruct`뿐이다. 성능 이득은 작고, 루프 있는 사용자 함수도 인라인 대상이
된다는 일반성 때문에 남긴다.

### 늘어난 바이트코드의 출처와 `never` 뒤 해제 제거

함수별 덤프 비교(`8fbc0f21` 대비, for 벤치 +4480 명령): `core.@destruct` +3096(69%, 호출 지점 324), `Slice.@deinit` +714,
`PtrSpan.init` +247, `core.compute_new_cap` +236, `PtrSpan.index` +117. 모든 벤치가 약 +24%로 같아 증가는 core 쪽이고, for의
`<main>`은 +60뿐이다. `[N]str`의 `@destruct`에 `for 0..len`이 있어 인라인 대상이 됐는데, 옛 덤프의 `call core.@destruct`
460개 중 438개는 `panic(...)` 바로 뒤(문자열 보간 임시값 해제)라 실행되지 않는 코드였다.

`sema.semaExprStmt`에서 `never` 타입 식문 뒤에는 `popLocals2(..., false, ...)`로 지역을 해제 없이 내린다. 결과:
for +23.9% → +8.2%, alloc +24.8% → +9.5%. 남은 증가는 `Slice.@deinit` · `File.close`(해제 코드가 빠져 한도 안으로 들어옴) ·
`compute_new_cap` · `PtrSpan.init`. 시간(hyperfine, `8fbc0f21` 대비): for +1.3%, heap −1.8%, fiber +1.9%, alloc −1.1%,
fib 잡음. 모두 잡음 범위.

### 재귀 가드와 인라인 검증 테스트

`inline_cost_fits`는 가장 바깥 호출에서 callee가 지금 생성 중인 proc의 함수(`funcs_debug[cur_proc.id].func`)와 같으면
인라인하지 않는다. 전에는 `InlineCtx` 체인만 봐서 루프 있는 재귀 함수가 자기 본문 사본을 한 단계 펼쳤다(`main`에는 한 번
펼쳐지는 것이 맞다).

트레이스는 인라인 여부와 관계없이 같아서 동작 테스트로는 인라인 회귀를 못 잡는다. lib-test `Bytecode inlining of functions with
loops.`가 main chunk의 `funcs_debug`에서 이름별 항목 수(함수 본문 1 + 인라인 지점마다 1)를 센다: `for` 함수 2곳 → 3,
`while opt |v|` 함수 → 2, 재귀 함수 → 2(가드 없이는 3). `functions/inline_loop.cy`에 `while opt |v|`(`drain`) 동작도 더했다.
`?str` 버전은 기본 한도 40을 넘어 인라인되지 않는다.

### 도달 불가 블록 끝의 해제 코드 제거, 비용 캐시, 덤프 수정

인라인 리뷰 후속으로 `inline_ret_jump`가 `return` 뒤의 `trap`만 건너뛰어 루프 뒤 `return -1` 다음에 param 해제와 끝으로
가는 jump가 남는다고 보았는데, 덤프를 보니 인라인이 아닌 일반 함수 본문에도 같은 코드가 있었다. `sema.popBlock2`가 블록 끝에
도달할 수 없어도(`endReachable == false`) main proc이 아니면 지역 해제를 냈기 때문이다. 함수 proc 블록의 끝은 `return`(명시
또는 `popFuncBlock`이 넣는 암시)이 이미 해제를 끝낸 뒤라 항상 도달 불가이고, `break` · `continue` · `never` 호출로 끝나는
안쪽 블록도 마찬가지다. 그래서 `popBlock2`는 proc 종류와 관계없이 `endReachable`이 거짓이면 해제를 내지 않는다. 생성기의
암시적 끝 `yield`(`procPrologue`) 뒤에도 `endReachable`을 거짓으로 둔다.

결과(ReleaseSafe, `cyber compile` 덤프의 명령 줄 수, `32fab0fa` 대비): for 20271 → 19064(−6.0%), heap −5.7%, fib −6.1%,
fiber −5.9%, alloc −5.8%, string index −6.1%. 줄어든 곳은 모두 죽은 코드다. `parseArgs` −211, `[]ArgOption.append` −103,
`write_file` −100, `[]str.append` −94, `copy_file` −84. 사라진 `call`은 `core.@deinitObject` 80 → 47, `RawBuffer.elems_ptr`
46 → 26, `Ptr.+` 32 → 22로, 죽은 `@destruct[Slice]` 인라인 본문 안의 호출들이다. 인라인 비용 계산이 보는 IR 노드 수도
같이 줄어 전에 한도 40을 넘던 함수가 인라인 대상이 될 수 있다.
시간(hyperfine, 다른 프로세스 부하 있음): for −1.5%, heap +3.8%, fib +1.7%, fiber −0.4%. 모두 잡음 범위(σ 3~7 ms).

lib-test `A function body ends at its last return.`이 main chunk의 `markers`로 함수 시작 pc를 찾아 다음 함수 헤더(`nop32`)
까지 걸으며 마지막 `ret` 뒤의 명령 수를 센다(`trap`만 허용). 수정 전에는 `find_first`에서 "expected 0, found 15"로 실패한다.

비용 캐시: `inline_cost`가 호출 지점마다 callee 본문을 다시 순회하던 것을 없애고, `can_inline`이 `check_inline`에서 센
노드 수를 `ir.FuncBlock.bc_inline_cost`에 저장한다. 처음에는 `FuncInfo`의 padding(u3) 자리에 u7로 두었는데 packed struct가
20비트가 되어 wasm32에서 `@sizeOf(Func)` 테스트가 36 → 40으로 깨졌다(64비트는 정렬 여유로 통과). IR 노드는 크기 제약이 없고
비용은 본문의 속성이라 그쪽이 맞다.

덤프 수정: `bytecode.write_inst`의 `.jump`가 오프셋을 u16으로 읽어 역방향 jump 대상이 `@65811`처럼 찍혔다(`pushJumpBackTo`는
`@bitCast(-i16)`으로 쓴다). `i16`으로 읽어 `jmp @313`처럼 나온다. 실행에는 영향 없음.

## 시도했으나 버린 것: Map 탐사 함수 `#[inline]`

`findSlot`(IR 노드 117) · `findSetSlot`(116)은 기본 한도 40을 넘는다. `AutoHash`는 38, `AutoEq`는 5다. Map 100만 채우기 ·
갱신 · get · contains 벤치(base 824.7 ms)로 잰 결과:

- `findSlot`에 `#[inline]`, 누적 예산 256: +7.6%. `m[i]`는 `Map.@index` → `HashMap.@index` → `findSlot` → `AutoHash`로
  깊이 4라, 깊이 한도 3에 걸려 `AutoHash` · `AutoEq`가 새 호출로 남는다(호출 1개를 없애고 2~3개를 만듦).
- 위에 깊이 한도 4: +0.4%(get 경로가 전부 펼쳐져도 이득 없음).
- `findSetSlot`도 `#[inline]`, 예산 320, 깊이 4: +7.4%(±75, main 바이트코드 243 → 494줄).

Map의 시간은 호출이 아니라 메모리 접근 · 해시 계산 쪽으로 보인다. 깊이 3 · 예산 160 · `#[inline]`은 `HashMap.set`에만
두는 3단계 설정을 유지한다. 깊이 한도를 올리면 래퍼(`Map.@index` 같은 한 줄 함수)가 깊이를 먹는 문제가 있으니, 나중에
래퍼를 깊이에서 빼는 규칙(노드 10 이하는 깊이를 세지 않음 등)을 검토할 수 있다.

# 5단계: 호출 지점 규칙 (비용 모델)

작성일 2026-11-03.

## 배경

인라인을 끈 빌드와 비교하니 전체 바이트코드(core · os 포함 덤프 명령 줄 수)가 for 벤치 기준 8190 → 19064(+133%)였다. 늘어난
곳의 대부분은 실행되지 않는 오류 경로였다. `Vector.@index_addr`(61곳) · `Ptr.@slice` 같은 경계 검사 함수가 지점마다 펼쳐지고,
그 안의 `panic_oob`(22곳)까지 펼쳐져 문자열 보간 · `interpolate` · `panic` 호출(약 25명령)이 지점마다 복사됐다.
`Wyhash.final`은 68 → 938명령. 4단계에서 본 `Slice.@deinit`(23곳) · `File.close`(21곳)도 핫 경로가 아닌 지점에 펼쳐진 것이다.

## 결정

세 규칙을 더한다. 한도(기본 40 · `#[inline]` 120 · 깊이 3 · 누적 160)는 그대로다.

- A. `never`를 반환하는 callee는 인라인하지 않는다(`check_inline`). 돌아오지 않는 함수는 한 번만 실행되므로 호출을 없앨
  이유가 없다. core.cy의 `panic_oob`에 `-> never`를 붙였다(그 덕에 sema도 `panic_oob` 뒤를 도달 불가로 본다).
- B. `never` 호출로 끝나는 문 목록(오류 경로) 안에서는 인라인하지 않는다. `genStmts`가 `stmts_end_in_never`로 판단해
  `Chunk.cold_depth`를 올리고, `gen_call`은 `cold_depth == 0`일 때만 인라인한다. 목록에 루프가 있으면 차갑지 않다.
  마지막 문만 보므로 `never` 호출 뒤에 문이 더 있으면(sema가 허용) 차갑지 않다.
- C. 본문이 `inline_small_nodes`(16)보다 크면 루프 안의 호출 지점이거나 `#[inline]`일 때만 인라인한다(`inline_cost_fits`).
  `Proc.loop_depth`를 `gen_loop_block` · `gen_for_range_stmt`가 올리며, 인라인된 본문 안의 루프도 같은 proc의 깊이라
  중첩 인라인의 호출 지점도 루프 안으로 센다. `#[inline]` 여부는 `ir.FuncBlock.bc_inline_attr`에 비용과 함께 캐시한다.

인라인 가능 함수 35개의 비용 분포(for 벤치, 규칙 A 적용 후): 0~7 6개, 8~15 8개, 16~23 8개, 24~31 6개, 32~39 6개, 40 1개
(`File.close`). `Array.append` 39, `Slice.@slice` 38, `next` 36, `Slice.@deinit` 32, `@index_addr` 23 · 18.

## 결과 (ReleaseSafe, `7563e3b4` 대비)

덤프 명령 줄 수(전체 / for의 main chunk):

| 변형 | for | heap | alloc | fib | fiber | for main |
|---|---|---|---|---|---|---|
| 인라인 없음 | 8190 | 8375 | 8628 | 7864 | 8343 | 586 |
| `7563e3b4` | 19064 | 20120 | 20113 | 18484 | 19464 | 1035 |
| A + B | 13906 | 14424 | 14829 | 13395 | 14200 | 906 |
| A + B + C | 10399 | 10777 | 11140 | 10000 | 10604 | 739 |

인라인 없음 대비 +133% → +27%. 남은 증가는 핫 루프 안의 `@index_addr` · `@slice` · `append` · `next`처럼 의도한 것이다
(경계 검사 `uge` · `jump_f` · `call panic_oob` 약 8명령이 지점마다 남는다).

시간(hyperfine, 부하 있음): A + B는 for −1.4%, heap −2.6%, fib −1.4%, fiber −7.1%, alloc −0.3%. 거기에 C는 for −3.2%,
heap −10.7%, fib −4.9%, fiber +0.5%, alloc +0.8%. 핫 경로의 생성 코드는 같아 모두 잡음 범위이고 회귀는 없다.

## 테스트

lib-test `Inline site rules.`: 작은 함수는 어디서나 펼쳐지지만 `never`로 끝나는 블록 안에서는 아니고(2), 큰 함수는 루프 안
지점에서만(2), `-> never` 함수는 본문이 작고 뒤에 문이 있어도 호출로 남는다(1). 규칙 하나씩 끄면 각각 "expected 2, found 3" ·
"expected 2, found 3" · "expected 1, found 2"로 실패한다. `Bytecode inlining of functions with loops.`는 호출 지점을
`for 0..2` 안으로 옮겼다(루프 있는 본문은 16을 넘으므로).

## 자기 호출 지점 한 단계 펼치기 (2026-11-04)

재귀 가드(`1d3b8e72`) 뒤 fib 시간을 재지 않았었다. 현재 트리(`ab626361`)에서 fib(30)은 32.7 ms로 2단계의 29 ms에서
되돌아가 있었고, 가드를 빼도 규칙 C(16노드 넘는 본문은 루프 안 지점만)가 자기 호출 지점을 막아 덤프가 같았다.
`inline_cost_fits`에서 callee가 현재 proc의 함수(자기 호출)면 규칙 C를 면제하고 가드를 없앴다. 펼쳐진 복사본 안의 자기
호출은 인라인 컨텍스트 사슬에 그 함수가 있어 호출로 남으므로 한 단계만 펼쳐진다(상호 재귀는 깊이 3에서 멈춤).

| 벤치 | 전 | 후 |
|---|---|---|
| fib(30) | 32.7 ms | 28.9 ms (−12%) |
| fib 덤프 명령 줄 | 10001 | 10023 |
| for · heap · fiber · alloc 덤프 | 변화 없음 | |

lib-test `Bytecode inlining of functions with loops.`의 `rec`는 본문 1 + `main` 지점 1 + 자기 본문 지점 1 = 3으로 바꿨다.

## 남은 것

- 콜백 · 생성기 본문처럼 루프 밖이지만 자주 불리는 지점은 규칙 C가 놓친다. `#[inline]`으로 지정하는 수밖에 없다.
- 오류 경로 자체를 지점마다 복사하지 않으려면(callee 안의 `if idx >= len: panic_oob(idx)`) callee 쪽 코드를 바꾸는 게 아니라
  차가운 블록을 한 번만 생성해 공유해야 하는데, 인라인 지점마다 레지스터 base가 달라 간단하지 않다.

