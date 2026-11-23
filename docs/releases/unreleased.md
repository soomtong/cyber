# 0.4.18 이후 변경 (미릴리스)

0.4.18(2026-11-22) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 추론할 수 없는 템플릿 파라미터의 오류 문구 (2026-11-23)

앞선 템플릿 파라미터를 쓰면서 새 infer 파라미터를 함께 선언하는 파라미터 타입(`f MapFn[T, %U]`, `p Pair[T, %U]`)으로 제네릭 함수를 호출하면
위치 없이 내부 오류 이름만 나왔다('CompileError: Error: FoundInferParam'). 이런 타입은 앞선 파라미터에 의존하는 타입으로 분류되어 호출 때 추론 없이 평가되기 때문이다.

- 이제 해당 호출 인자 위치와 함께 'Can not infer the template parameter `U` from the argument for `f`. Declare it as its own parameter (`%U type`) and pass the type in the call.'을 보고한다.
- 추론 자체는 아직 지원하지 않는다. `fn map(%U type, items []%T, f MapFn[T, U]) -> []U`처럼 따로 선언하고 `map(str, items, name)`으로 타입을 넘긴다.
- 테스트: `src/test/meta/infer_param_dependent_error.cy`. 매뉴얼: `docs/docs.md`의 'Infer parameter'.

## wasm32-freestanding 빌드 제거 (2026-11-22, 깨지는 변경)

웹용 라이브러리 빌드(`zig build lib -Dtarget=wasm32-freestanding`)를 지원 대상에서 뺐다. 0.4.18에서 다시 빌드되게 고쳤지만 쓰는 곳이 없었다.
웹 플레이그라운드는 WASI 빌드(`cyber-wasi.wasm`)를 `examples/web-playground/wasi.js` 위에서 돌리고, 릴리스 asset에도 `cyber-web.wasm`이 없었다.

- 브라우저에서 Cyber를 돌리거나 임베딩하려면 `wasm32-wasi` 빌드와 WASI 호스트를 쓴다. `zig build lib -Dtarget=wasm32-wasi`가 libcyber를 만든다.
- `meta.system()`의 `SystemKind`에서 `.freestanding`을 뺐다. 저장소의 `.cy` 코드는 이 값을 쓰지 않았다.
- 호스트가 채워야 했던 import(`hostLogDebug/Info/Warn/Error`, `hostMilliTimestamp`, `hostFileWrite`, `hostSleep`, `hostFetchUrl`)는 더 이상 없다.
- `task lib:wasm`, CI의 freestanding 컴파일 확인 단계를 지웠다.
