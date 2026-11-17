# 0.4.13 이후 변경 (미릴리스)

0.4.13(2026-11-16) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 임베딩: resolver로 모듈 허용 표

- 컴파일러가 스스로 찾는 내장 모듈(`#[extern]` 함수가 있는 모듈의 `@initBindLib`을 위한 `c`, `meta`)은 이제 호스트 resolver를
  부르지 않고 이미 올라온 모듈에서 찾는다. 전에는 스크립트가 `use math`만 해도 resolver에 `main`이 `c`를 가져오는 호출이 와서,
  "스크립트의 `use c`는 막고 `math`는 허용"하는 resolver가 `use math`까지 막았다. 이제 resolver에는 소스의 `use`만 온다.
- resolver가 거부했을 때 문구가 ``Failed to resolve module `c`.``처럼 모듈 이름을 말한다(전에는 ``Failed to resolve module.``).
- `docs/docs.md` "Allowing modules": 믿을 수 없는 스크립트의 모듈 허용 표는 로더가 아니라 resolver(`curUri`)로 만든다.
  결정 기록은 `docs/decisions/project_embedding_module_allowlist.md`.

## `use c` 없는 `#[extern]` 함수가 컴파일 오류

- `c` 모듈이 실리지 않은 채 `#[extern]` 함수를 선언하면(`#[extern='abs'] fn c_abs(a int) -> int`) 프로그램 초기화가 `c`의
  `@initBindLib`을 null로 풀어 프로세스가 끝났다(CLI는 `panic: attempt to use null value`, 임베딩 ReleaseFast는 `cl_vm_validate`
  안의 세그폴트). 이제 선언 위치의 컴파일 오류 ``An `#[extern]` function needs the `c` module. Add `use c`.``다. `use c`나 `c`를
  가져오는 모듈(`math`)이 먼저 있으면 그대로 된다. tars-agent 요청 `cyber-0.4.13-extern-without-c.md`. 테스트
  `syntax/extern_without_c_error.cy`, `lib_test/session.zig` "An `#[extern]` function without the `c` module".
