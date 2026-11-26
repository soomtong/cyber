# 0.4.22 이후 변경 (미릴리스)

0.4.22(2026-11-26) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## `os.cmd` 예제 셋 (2026-11-26)

- `examples/build_log.cy`: `stderr_to_stdout`로 stdout · stderr를 쓴 순서대로 받는다(줄 단위 읽기, 로그 파일, 파이프).
- `examples/background_job.cy`: `detach`로 `python3 -m http.server`를 띄우고 `curl`로 확인한 뒤 pid로 멈춘다.
- `examples/parallel_jobs.cy`: `start`로 명령 셋을 동시에 돌리고 `Array[os.Process]`에 담아 종료 코드를 모은다.
- 셋 다 `behavior_test`의 "Compile."에서 컴파일만 확인한다(POSIX 프로그램이 필요해 실행하지 않는다).
