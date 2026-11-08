# 신뢰하지 않는 스크립트의 raw 포인터 차단 `deny_raw_ptrs` (2026-11-08, F-06)

## 배경

스크립트는 `use c` 없이도 임의 주소를 읽고 쓸 수 있었다. 확인한 경로(모두 CLI에서 세그폴트 또는 임의 읽기):
`p := as[Ptr[int]] 8; p.*`, `Ptr[int](8).*`, `as[Ptr[int]] &x` 뒤 `p[100000000]`, `alloc(int)`로 받은 `Ptr[int]`의
인덱스, `PtrSpan[int]{length=4}`(`ptr`가 `none`)의 인덱스. 모듈 허용 목록 로더로는 막을 수 없다. `core`가 `Ptr` · `PtrSpan` ·
`alloc`을 제공하기 때문이다. `^T`(소유 포인터)와 `&T`(빌림)는 정수에서 캐스트할 수 없어(`Cannot cast \`int\` to \`^int\`.`)
문제가 없다. 라이브러리 호스트에는 시그널 핸들러가 없으므로 스크립트 한 줄이 호스트 프로세스를 죽인다
(`docs/study/08-embedding-builtins-tests.md` §7.4).

## 결정

`534a0a9d`. 컴파일 옵션 `deny_raw_ptrs`(`CLEvalConfig` · `CLCompileConfig`, 기본 false)를 두고, 켜지면 sema의 `semaExpr`가
모든 식의 결과 타입을 보고 `Ptr[T]`(`Type.isPointer`, `ref`가 아닌 `.pointer`) · `PtrSpan[T]`(`ptr_span_tmpl` 인스턴스) ·
그 Option(`?Ptr[T]`)이면 컴파일 오류를 낸다.

```
Raw pointer type `Ptr[int]` is not allowed. The host disabled raw pointers for this script (`deny_raw_ptrs`).
```

- 판별은 식 노드가 속한 청크(`node.src()`)가 표준 모듈(`compiler.is_std_module_uri`: `core` · `meta` · `math` · `cy` ·
  `c` · `io` · `test`)이 아닐 때만 한다. 현재 청크(`c`)가 아니라 노드의 청크를 보는 이유는 구조체 필드 기본값
  (`PtrSpan.ptr = none`, `core:4314`)이 초기화 식을 쓴 사용자 청크 문맥에서 평가되기 때문이다. core 제네릭을 사용자 타입으로
  펼친 본문의 노드는 core 것이라 면제된다. 사용자 모듈(`use foo 'foo.cy'`)은 사용자 청크다.
- 값이 나오는 자리를 막으므로 타입 이름을 쓰지 않고 추론으로 얻는 경우(`alloc(int)`, `StaticMap.get`의 `?Ptr[V]`,
  `Vector.as_ptr_span()`)도 걸린다. 역참조 · 인덱스 · 캐스트 각각을 막는 것보다 구멍이 적다.
- 기본값은 false다. CLI와 기존 임베딩은 그대로다(CLI는 의도적으로 열려 있다, 08장 §7.4). 에이전트 루프 호스트는 허용 목록
  로더와 함께 `cfg.deny_raw_ptrs = true`를 켠다.
- 타입 이름만 쓰는 선언(`fn f(p Ptr[int])`)은 그 자체로는 오류가 아니고, 매개변수를 쓰거나 호출 인자를 만드는 순간 걸린다.
- `use c`(`c.to_strz` 등 포인터 도구)와 FFI는 이 옵션과 별개다. 로더에서 `c`를 거르되 `math`가 `c`에 의존하는 점은 그대로
  (`project_embedding_agent_loop.md`). 다만 `c`를 열어도 `deny_raw_ptrs`가 켜져 있으면 스크립트가 `Ptr` 값을 들 수 없다.

## 검증

lib-test `deny_raw_ptrs rejects raw pointers in script chunks.`: 위 다섯 경로와 `Ptr` 매개변수 함수 · `?Ptr[int]` 반환이 모두
컴파일 오류, 같은 VM에서 `[]int` · `[&]int` · `Map[str, int]` · 빌림 `&x` · 문자열 보간이 정상 실행(core 내부의 `Ptr` 사용은
면제됨을 확인), `persist_main`에서 거부된 eval 뒤 다음 eval 정상, 기본 설정은 `as[Ptr[int]] 8`을 컴파일(실행하지 않음).

## 남은 것

- CLI 옵션(`--deny-raw-ptrs`)은 두지 않았다. 필요하면 `cli.zig`에서 `EvalConfig`에 넣으면 된다.
- 호스트가 자체 로더로 제공하는 Cyber 소스 모듈(예: `agent`)도 사용자 청크로 취급되어 `Ptr`를 쓸 수 없다. 표준 모듈 이름 목록만
  면제한다. 호스트 모듈을 면제하려면 로더 결과에 플래그를 더해야 한다.
- 컴파일타임 평가(`cte`)는 `semaExpr`를 거치지 않는다. `const`에서 `Ptr` 역참조가 되는지는 확인하지 않았다.
