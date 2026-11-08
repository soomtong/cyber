# 컴파일 타임 평가의 복합 대입 (2026-11-08, F-20)

## 배경

`const x = f()` · `type X const:` 본문 · `#{}`는 `cte.zig`가 AST를 직접 해석한다. 런타임 경로는 `semaAssignStmt`가 `t += 5`를
`t = t + 5`로 풀지만(`semaExprOrOpAssignBinExpr`), cte의 `eval_assign`은 대입 대상 종류마다 오른쪽 식을 따로 평가했고 그중
`.deref` 분기만 복합 연산자 정보(`RecOp`)를 썼다. 컴파일 타임 변수(`.ct_var`)와 벡터 원소(`v[i]`) 대입은 `evalCheck(right_n)`만
불러 `t += 5`가 `t = 5`가 됐다(발견 이슈 F-20). 같은 함수가 런타임에서는 39, `const`에서는 3을 내고 `for 0..10 |i|: total += i`가
45 대신 9가 되는 조용한 오답이었다. `src/test/meta`에 `+=`를 쓰는 케이스가 없어 테스트에 걸리지 않았다.

그 밖에 cte의 벡터 원소 읽기(`v[i]`)는 `TODO ct_var` 오류였고, 벡터 원소 쓰기는 인덱스 범위를 검사하지 않아 컴파일 타임에 범위
밖 인덱스가 컴파일러 프로세스의 메모리를 썼다.

## 결정

02f39e67.

- `eval_assign_right(c, right, rec_op, target_t)`가 오른쪽 식을 평가하고 목적지 타입을 검사한다. 복합 대입이면 `eval_bin_expr(left, op, right)`
  결과를 쓰고, 타입이 다르면 `evalFitTarget`(EvalInt ↔ int 등)으로 맞추거나 `Expected type ... Found ...` 오류. 세 분기(`.ct_var` ·
  `.deref` · 벡터 원소)가 모두 이 함수를 쓴다. 이전에는 `.deref` 분기가 타입 검사 없이 `eval`만 했다.
- 벡터 원소의 주소 계산은 `ct_vector_elem_ptr`로 모으고 범위 밖이면 `Index out of bounds. Index `N` is not in range `0..M`.` 컴파일 오류.
  음수도 같은 오류(이전에는 `@intCast` panic).
- `evalExprNoCheck`의 `.index_expr`에 컴파일 타임 벡터 원소 읽기를 넣었다(`copyValue3`로 복사). `v[1] += 40`의 왼쪽 읽기가 이 경로다.
- cte가 지원하지 않는 연산(`float`의 `+` · `-` · `/`, 사용자 타입 연산자 없음)은 전처럼 `Unsupported inline eval: plus` 오류다.
  복합 대입에서도 이제 같은 오류가 나온다(수정 전에는 연산을 버리고 오른쪽 값을 대입했다). 지원 범위를 넓히는 것은 별개 작업.

## 검증

- behavior 테스트 `meta/ct_op_assign.cy`: 같은 함수를 런타임과 `const`로 실행해 `+=` · `-=` · `*=` · `/=`(13), 루프 누적(45), 벡터 원소
  `v[1] += 40` · `v[0] -= v[1]`(1)을 비교. `meta/ct_vector_index_error.cy`: `v[3] += 1`이 컴파일 오류.
- 기존 `meta/ct_eval_loop.cy` · `meta/type_const.cy`(벡터 원소 `=` 대입)는 그대로 통과.

## 남은 것

- cte는 언어의 두 번째 구현이다. sema에 문장 · 연산이 추가되면 `cte.zig`도 따라가야 하고, 회귀 테스트는 "같은 함수를 런타임과
  `const`로 모두 실행해 비교"하는 모양으로 둔다(03장 Q4).
- `float` 산술은 `*`만 있다. `const w = 1.5 + 2.0`도 `Unsupported inline eval: plus`.
