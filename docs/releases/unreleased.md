# 0.4.18 이후 변경 (미릴리스)

0.4.18(2026-11-22) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## wasm32-freestanding 빌드 제거 (2026-11-22, 깨지는 변경)

웹용 라이브러리 빌드(`zig build lib -Dtarget=wasm32-freestanding`)를 지원 대상에서 뺐다. 0.4.18에서 다시 빌드되게 고쳤지만 쓰는 곳이 없었다.
웹 플레이그라운드는 WASI 빌드(`cyber-wasi.wasm`)를 `examples/web-playground/wasi.js` 위에서 돌리고, 릴리스 asset에도 `cyber-web.wasm`이 없었다.

- 브라우저에서 Cyber를 돌리거나 임베딩하려면 `wasm32-wasi` 빌드와 WASI 호스트를 쓴다. `zig build lib -Dtarget=wasm32-wasi`가 libcyber를 만든다.
- `meta.system()`의 `SystemKind`에서 `.freestanding`을 뺐다. 저장소의 `.cy` 코드는 이 값을 쓰지 않았다.
- 호스트가 채워야 했던 import(`hostLogDebug/Info/Warn/Error`, `hostMilliTimestamp`, `hostFileWrite`, `hostSleep`, `hostFetchUrl`)는 더 이상 없다.
- `task lib:wasm`, CI의 freestanding 컴파일 확인 단계를 지웠다.
