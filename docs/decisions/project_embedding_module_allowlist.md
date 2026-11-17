# 임베딩: 스크립트가 쓸 수 있는 모듈의 허용 표

작성일 2026-11-17.

## 배경

tars-agent는 모델이 쓴 스크립트를 세션 VM에서 돌린다. 바깥에 닿는 길은 호스트 능력(`fs`, `proc`)뿐이어야 하고, 능력은
정책 게이트를 지난다. tars-agent 문서(`docs/spec/05` 1층, `08`의 C3)는 표준 모듈 일부만 허용하고 `c`, `io`, `meta`, `cy`,
`test`, `os`를 막는 표를 두며, "호스트 로더로 되면 cyber에 올리지 않는다"고 적었다.

## 로더로는 안 되는 이유 (s1 재현, 0.4.13)

- 로더는 모듈이 처음 올라올 때 한 번만, 이름만 받고 불린다(`src/compiler.zig` `loadChunk`).
- `core`가 `use meta`를 하므로 `meta`는 스크립트보다 먼저 올라온다. 스크립트의 `use meta`는 로더를 부르지 않는다.
  s1에서 `use meta`, `use cy`, `use io`가 모두 로드됐다.
- `math`는 `use c`, `use meta`, `json`은 `use meta`를 한다. 이름으로 `c`를 막으면 `use math`가 'Failed to load module: c'다.

## 결정

- 허용 표는 호스트 resolver(`cl_vm_set_resolver`)로 만든다. resolver는 `use`마다 불리고 가져오는 쪽(`curUri`)을 받는다.
  `curUri`가 `main`(스크립트)인 `use`만 표와 맞추고, 나머지는 `cl_default_resolver`에 넘긴다. `curUri`가 빈 호출은 호스트가
  스크립트 자체를 해석하는 것이다.
- 컴파일러가 스스로 찾는 내장 모듈(`@initBindLib`의 `c`, `meta`)은 resolver를 부르지 않는다(`Chunk.get_builtin_chunk`:
  `chunk_map`에서 이름으로 찾고, 없을 때만 전처럼 resolver). 전에는 `#[extern]` 함수가 있는 `math`를 쓰면 메인 스크립트의
  초기화에서 `get_chunk_by_uri("c")`가 불려 resolver에 `main->c`로 왔고, 스크립트의 `use c`와 구별되지 않았다.
- bind 함수에서 chunk 포인터를 기억하는 안은 버렸다. 세션 reset과 실패한 컴파일이 chunk를 표에서 빼므로 포인터가 남는다.
- 거부 문구는 'Failed to resolve module `c`.'. 호스트는 `clReportApiError`로 자기 문구를 줄 수 있다.
- `CLEvalConfig`에 허용 표 필드는 만들지 않는다. resolver로 된다.

## 확인

- `src/lib_test/session.zig` "A host resolver gates the `use` of the script ...": `core`, `math`만 허용하는 resolver로
  `use math`가 통과하고 `c`, `meta`, `cy`, `io`는 이름을 말하는 오류, 거부 뒤 세션이 이어진다. 수정 전 코드에서는 실패했다.
- tars-agent s1 사본에 검사 7h(허용과 거부), 7i(거부 뒤 세션), 7j(`use math`의 내부 조회)를 넣어 확인했다. 패치는 tars-agent에
  넘길 초안이다(스크래치패드, 저장소에는 넣지 않음).

## 남은 위험

- `cy`: `cy.eval`은 새 `VM()`을 만들어 호스트 설정(로더, `deny_raw_ptrs`, `deny_spawn`)을 물려받지 않는다. 0.4.13 라이브러리
  빌드에서는 `cy.eval("1 + 1")`도 `error.EvalError`라 탈출은 재현되지 않았다. 허용 표에서 뺀다.
- `meta.load(path)`: 메인 스크립트 폴더 기준으로 컴파일 시점에 파일을 읽는다(`src/builtins/meta.zig` `load_`). 지금은 인자
  `str`이 컴파일 시점 값이 될 수 없어 어떤 꼴로도 부를 수 없었다. 고쳐지면 능력을 거치지 않는 읽기가 된다.
