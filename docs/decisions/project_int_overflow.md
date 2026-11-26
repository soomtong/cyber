# 정수 넘침: 부호 있는 산술은 panic (2026-11-26)

상태: 구현됨. 사용자 결정(2026-11-26, Fibonacci 예제를 쓰다 F(93)이 `int`를 넘는 자리에서 질문): "넘치면 panic (권장)".

## 배경

`int`의 `+ - *`가 넘치면 조용히 감겨 음수가 나왔다. 확인하는 연산도 없었고 매뉴얼에 감김이 적혀 있지도 않았다. 같은 자리에 결함이
둘 있었다.

- F-219: 컴파일 타임의 `-(int.min)`(`const k = -(-9223372036854775807 - 1)`)이 호스트 panic이었다(`cte.eval_un_expr`의 Zig `-`).
- F-220: 런타임 `int.min / -1`과 `int.min % -1`이 C의 정의되지 않은 동작이었다(`vm.c` `IDIV` · `IMOD`). arm64는 감긴 값을 냈고,
  x86_64는 SIGFPE로 호스트가 죽을 수 있다(이 기계에서는 확인하지 못함).

## 비교

- Zig 0.17.1: 부호 있는 · 없는 정수의 `+ - *`와 `-x`, `@divTrunc(minInt, -1)`의 넘침은 illegal behavior이고 Debug · ReleaseSafe에서
  'integer overflow' panic이다. 감김은 `+% -% *%`, 포화는 `+| -| *|`, 확인은 `@addWithOverflow`(값과 넘침 비트의 튜플).
- Rust: debug 빌드는 'attempt to add with overflow' panic, release는 감김(설정으로 바꿈). `i64::MIN / -1`과 `% -1`은 언제나 panic.
  메서드 `checked_*`(`Option`), `wrapping_*`, `saturating_*`, `overflowing_*`.
- Nim 2.4: 넘침은 `OverflowDefect`(기본으로 검사, release에서도). 감김은 `+%` 등.
- Python 3.15: 정수가 무한 정밀도라 넘침이 없다.
- Swift: 넘침은 trap, 감김은 `&+ &- &*`, 확인은 `addingReportingOverflow`.

## 결정

1. 부호 있는 정수(`int` = `i64`, `i32`, `i16`, `i8`)의 `+ - * **`, 단항 `-`, `/`의 결과가 타입에 들어가지 않으면
   'Integer overflow.' panic이다. 빌드 모드와 상관없다(VM은 한 가지다). Zig · Nim · Swift와 같고, Rust의 debug와 같다.
2. `x % -1`은 언제나 0이다(`int.min % -1` 포함). 수학적으로 넘침이 없다(Rust는 panic, Zig `@rem`은 0).
3. raw 정수(`byte` = `r8`, `r16`, `r32`, `r64`)는 감긴다. 매뉴얼이 말하듯 마스크와 메모리를 위한 비트다(Zig는 부호 없는 정수도
   검사하지만, Cyber의 raw는 C의 부호 없는 정수에 가깝게 쓰인다: 해시, 주소).
4. 감김과 확인은 메서드로 둔다: `wrapping_add` · `wrapping_sub` · `wrapping_mul`, `checked_add` · `checked_sub` · `checked_mul`
   (`?Self`). 연산자(`+%`)는 두지 않았다. 토크나이저 · 파서 · tree-sitter · 포매터가 모두 바뀌고, 쓰는 자리(해시 · 난수)가 드물다.
   saturating · overflowing은 쓸 곳이 생기면 더한다.
5. 컴파일 타임(`cte`)도 같은 결과다: 넘치면 'Integer overflow.' 컴파일 오류(`const k = int.max + 1`). sema의 상수 접기
   (`fold_const_int`)는 넘치는 `int` 식을 접지 않고 남겨 런타임 명령이 panic하게 한다.
6. 시프트와 비트 연산은 넘침이 없다.

## 구현

- VM(`vm.c` · `vm.h` · `bytecode.zig`): `AddOvf` · `SubOvf` · `MulOvf`(dst, left, right, bits), `AddI16Ovf`(dst, left, imm, bits),
  `NegOvf`(dst, child, bits). 좁은 정수는 레지스터 위쪽 비트가 미정이라 bits로 부호 확장한 뒤 `__builtin_*_overflow`와 폭 검사를 한다.
  `IDIV`에 bits 피연산자를 더했다(좁은 정수의 `min / -1`). `IMOD`는 `-1`이면 0. `Pow`(`ipow`)도 검사한다.
- `bc_gen.zig`: 타입이 `.int`이면 검사 명령(`ovfBits`, `gen_int_ovf`, `gen_neg`, `gen_idiv`). `gen_add`의 `add_mul_i16`은 오른쪽이
  부호 없는 `.mul`인 주소 계산(`semaMadd`, 인덱스 주소)만 받는다. 사용자 코드의 부호 있는 곱은 `.imul`이라 검사 명령으로 간다.
- `core.cy`: `Int[]`의 `wrapping_*`(`Raw[Bits]`로 계산)와 `checked_*`. `AutoHash`와 `splitmix64_hash`의 덧셈을 `r64`로 옮겼다
  (`Wyhash`는 이미 `umul`).
- 비용: `s += 1` 한 문장이 4칸(`add_i16`)에서 5칸(`add_i16_ovf`)이 됐다. 함수 본문 크기 한계를 시험하는 lib 테스트의 수를 고쳤다.

## 검증

- `core/int_overflow.cy`(들어가는 결과, 감김 · 확인 메서드, raw의 감김, 컴파일 타임 접기), panic 테스트 넷(`int` 덧셈, `i32`
  곱셈, 부호 반전, `min / -1`), 컴파일 오류 테스트 하나.
- 감김을 기대하던 테스트(`core/ints.cy`, `core/Map.cy`, `modules/core.cy`의 `i8(100) + i8(100)` 등)는 `wrapping_add`로 바꿨다.
  좁은 정수의 레지스터 위쪽 비트를 시험하려는 뜻은 그대로다.
