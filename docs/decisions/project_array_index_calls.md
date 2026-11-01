# 배열 인덱스 · 순회 · append의 내부 호출 줄이기

작성일 2026-11-01.

## 배경

`for` 벤치(`src/test/bench/for/for.cy`, 100만 개 append 후 `for arr` 합산)가 Lua · Luau보다 6배, Python · Perl보다도
느렸다. 구간을 나눠 재면(ReleaseSafe, M1 Max) append 39 ms, `for arr` 50 ms, `arr[i]` 순회 29 ms, 빈 범위 루프 5 ms였다.

## 원인

VM의 `CALL` · `CHK_STK` · `RET`은 이미 가볍다(`src/vm.c:902`, `:917`). 문제는 디스패치 수다. 바이트코드 VM에 인라인이
없어서, 표준 라이브러리 메서드가 부르는 작은 보조 함수가 모두 실제 호출이 된다.

- `arr[i]`: `Array.@index_addr` → `Int.uge`(본문은 `.uge` 한 명령) → `Ptr.+`(`mul` + `add`). 호출 3회.
- `for arr`: `Array.next` → `@index_addr` → `uge` · `Ptr.+`. 호출 4회.
- `append`: `ensure_cap` → `cap()`, 그리고 `Ptr.+`. 호출 4회.

## 결정

`src/builtins/core.cy`에서 핫 경로의 보조 호출을 식으로 직접 쓴다. 의미는 바꾸지 않는다.

- 경계 검사 `idx.uge(n)`을 `(as[r64] idx) >= (as[r64] n)`로 바꾼다. `Raw` 비교는 sema가 `.uge` 명령으로 내린다.
  `Buffer` · `Slice` · `Span` · `ArrayStore` · `Array` · `PartialVector` · `PtrSpan`의 인덱스 함수와 `str.rune_at` · `str.next`.
- 주소 계산 `p + idx`(`Ptr.+` 호출)를 `*p[idx]`로 바꾼다. `Ptr.@index_addr`는 `#[reserve]`라 명령으로 내려간다.
  `Buffer` · `Slice` · `Array`의 `@index_addr`, `Array.append`.
- `Array.append`는 `length >= cap`일 때만 `ensure_cap`을 부른다. cap은 `header && ~(3 << 62)`를 직접 쓴다.
- `Array.next`는 `self[idx.*]`(`@index` 호출) 대신 `self.buf[i]`를 읽는다. 범위 검사를 `==`에서 `>=`(부호 없는 비교)로
  바꿔 경계를 넘는 인덱스도 `none`을 돌려준다.

결과(ReleaseSafe): append 39 → 29 ms, `for arr` 50 → 30 ms, `arr[i]` 29 → 17 ms.

## 제외한 것

- `Span.@index_addr`의 `as[Ptr[T]] self.base + idx`를 `*(as[Ptr[T]] self.base)[idx]`로 바꾸면 Debug 빌드에서
  "Retaining untracked heap object" panic이 난다. `base`가 `&T`(빌림)라 캐스트 결과의 인덱스 주소가 다르게 처리되는
  것으로 보인다. 원인은 조사하지 않았고 `uge`만 바꿨다.
- `Vector.@index_addr`의 `idx.uge(N)`을 `as[r64] N`으로 바꾸면 컴파일러가 "integer does not fit in destination type"으로
  panic한다(ct 상수 `N`의 `as[r64]` 변환). 원래대로 둔다.

## 2단계: 상수 접기와 주소 계산 명령 (2026-11-01)

- 상수 접기(`src/sema.zig` `fold_const_int`): 정수 이항 연산(`+ - * && || ~ << >>`)과 `~` 단항에서 피연산자가 모두
  `const64`이고 타입이 `int` · `r64`이면 `const64` 하나로 바꾼다. VM과 같게 덧셈 · 뺄셈 · 곱셈은 wrap, 시프트 양이 64
  이상이면 접지 않는다(VM은 `& 0xff`로 자르므로 결과가 플랫폼 따라 다를 수 있음). 나눗셈 · 나머지는 0 나누기 오류를
  런타임에 남기려고 접지 않는다. 64비트가 아닌 타입은 리터럴이 `const8` · `const16` 등으로 오므로 대상에서 뺐다.
  `3 << 62` · `~(...)`가 명령 4개에서 `const_64` 하나가 됐다.
- `add_mul_i16`(`src/vm.c` `AddMulI16`): `dst = left + idx * scale`, `scale`은 u16 즉시값. `Ptr[T]` 인덱싱
  (`sema_ptr_index`)이 만드는 `add(p, mul(idx, const))`를 bc_gen `gen_add`가 이 명령 하나로 내린다. 명령 3개 → 1개.
- `gen_add`는 오른쪽이 i16 범위 상수인 덧셈도 기존 `add_i16`으로 내린다(`x + 1`이 `const_16s` + `add`였음).
- 새 opcode는 `CodeAddI16` 바로 뒤에 넣었다. jump table(`JENTRY`)이 enum 순서를 따르므로 두 곳을 같이 고쳐야 한다.
  JIT(`src/jit/gen.zig`)는 이 명령을 모르지만 JIT는 fork 범위 밖이다.

결과(ReleaseSafe): append 29 → 23 ms, `for arr` 30 → 24 ms, `arr[i]` 17 → 15 ms. 벤치 전체(hyperfine)는 for 70 → 58 ms
(Lua 16 ms), heap 47 → 39 ms(Lua 28.5 ms), fib는 33 ms로 변화 없음. opcode 수 검사(`src/bytecode.zig` 테스트)를 131로 올렸다.

## 남은 일

- 작은 함수(본문이 `return <식>` 하나 등)를 sema 또는 IR 단계에서 인라인. 남은 비용의 대부분은 `@index_addr` ·
  `next` · `append` 호출 자체(호출 · `chk_stk` · 인자 `mov` · `ret`)다. 사용자 코드의 메서드 호출에도 듣는다.
- `Span.@index_addr`의 포인터 식 panic과 `as[r64] N` 컴파일러 panic의 원인.
