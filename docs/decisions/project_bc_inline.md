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
