# `cyber doc` 매뉴얼과 에이전트 안내 (2026-11-16)

## 배경

tars-agent는 Cyber 안내(`prompt/cyber-subset.en.md`)를 자기 저장소에 두고 기준 버전을 손으로 고정한다
(`docs/spec/08-cyber-implementation.md`의 "구현 전에 다시 확인한다"). 다른 프로젝트가 같은 안내를 쓰면 사본마다 버전이 어긋난다.
같은 표의 "조건부: spec --for-agents" 항목이 이 기능이다.

## 결정

- 명령 이름은 `cyber doc`이다. `spec`은 형식 명세로 읽히지만 내용은 사용 매뉴얼이다.
- `docs/docs.md`와 `docs/agents.md`를 `@embedFile`로 실행 파일에 넣는다(`src`밖이라 `build.zig`가 anonymous import로 넘긴다).
  실행 파일이 약 230KB 커진다. 문서와 `cyber version`이 항상 맞고 오프라인에서 된다.
- 통째로 출력하지 않는다. `docs.md`는 214KB라 에이전트 컨텍스트를 낭비한다. `--for-agents`는 안내(약 21KB)와 장 · 절 id 목록만,
  나머지는 `cyber doc <id>`로 절 단위로 찾는다.
- 절 id는 `docs/gen-docs.cy`의 anchor 규칙을 그대로 쓴다(공백은 `-`, `./$[]#` 제거, 소문자, 중복은 `-1`). 사이트 링크와 같은 id다.
  id 목록은 실행 때 `docs.md`의 heading에서 만들므로 손으로 고칠 목록이 없다.
- 손으로 쓰는 부분은 `docs/agents.md` 하나다. tars-agent의 안내에서 호스트 전용 내용(능력 함수, 실리지 않는 모듈, 세션 검증 절차)을
  뺐다. 예제는 `cli-test`의 `doc: every example of the guide for agents runs.`가 모두 실행한다. 오류 문구 목록과 메서드 목록은
  2026-11-16 master에서 하나씩 확인했다(자동 검사는 예제만).

## 하지 않은 것

- 모듈 API(`cyber doc json`). `api.json`은 빌드 산출물이 아니라 `cyber`로 생성하는 파일이라 CLI에 넣으려면 부트스트랩이 필요하다.
  지금은 사이트의 `api.html`과 릴리스의 `api.json`을 가리킨다. 필요하면 내장 모듈 소스에서 선언을 뽑는 방식을 검토한다.
- `doc`이 명령이 되어 확장자 없는 스크립트 `doc`은 `cyber ./doc`으로 실행한다(`fmt`, `compile`과 같은 제약).

## 별도 실행 파일(`cyber-doc`)로 나누지 않는다 (2026-11-16 검토)

- `cyber-lsp`가 따로 있는 것은 편집기가 stdio JSON-RPC 서버로 오래 띄우는 프로세스이고 진입점(`lsp_main.zig`)과 의존이 다르기 때문이다.
  `cyber doc`은 한 번 출력하고 끝나는 하위 명령으로 `fmt`와 같은 성격이라 그 이유에 해당하지 않는다.
- 나누면 이 기능의 목적이 약해진다. 한 파일이라 문서와 `cyber version`이 어긋날 수 없던 것이, `cyber`만 복사하거나 옛 번들 · 다른
  PATH에서 어긋난다. 에이전트는 `cyber help`에서 `doc`을 찾지만 별도 이름은 미리 알아야 하고, 다른 프로젝트의 안내도 설치를 가정해야 한다.
  릴리스 CI의 타깃별 빌드, 번들, `install.sh`의 링크 처리도 하나씩 늘어난다.
- 얻는 것은 크기(약 230KB)뿐이다. 네이티브에서는 무시할 만하고, playground의 `cyber.wasm`에서 문제가 되면 빌드 옵션(`-Ddoc=false`)으로
  wasm에서만 뺀다.
- 분리할 실질적 이유는 모듈 API 내장 하나다(`cyber` 뒤에 빌드하면 생성한 `api.json`을 넣을 수 있다). 대신 `api.json`을 커밋하고 생성
  결과와 같은지 테스트로 검사하는 방식을 먼저 검토한다. 그 밖의 길은 두 단계 빌드(빌드 시간 증가)와 내장 모듈 소스에서 실행 때 선언을
  뽑는 것이다.
