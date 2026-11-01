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

## 남은 일

손으로 푸는 방식은 표준 라이브러리 몇 곳에만 듣는다. Lua 수준(`for` 벤치 약 16 ms)에 가려면 다음이 필요하다.

- 작은 함수(본문이 `return <식>` 하나 등)를 sema 또는 IR 단계에서 인라인. 사용자 코드의 메서드 호출에도 듣는다.
- 상수 접기: `3 << 62`가 `const` · `const` · `lsl` · `not` 네 명령으로 남는다.
- 인덱스 주소 계산: `const 8` + `mul` + `add`가 매번 나온다. 크기를 곱한 주소로 바로 읽는 명령이나 `mul_i16`이 있으면 줄어든다.
