# MEMORY

- [Zig 0.17 업그레이드](docs/decisions/project_zig_017_upgrade.md) — 검증 환경(0.15.2는 Linux 컨테이너에서만), Io · env · args 규칙, `vm.h` 모드별 padding, out 파라미터와 ReleaseFast UB
- [fork 릴리스와 CI](docs/decisions/project_fork_release_ci.md) — origin 태그 필요(0.3), 태그 push 릴리스, 번들에 src/ 포함, install.sh는 lib/cyber + 심링크, msvc malloc · macOS x86_64 INODE64 · wasm32 Value ABI
- [fork의 용도와 방향](docs/decisions/project_direction.md) — Python · Perl · Shell 대용 스크립트 CLI, 네이티브 바이너리 불필요(TCC/C AOT로 충분), LLVM 백엔드 닫음, TARS 에이전트 루프(CodeAct) 언어 후보
- [libcyber 임베딩 검토](docs/decisions/project_embedding_agent_loop.md) — 라이브러리 모듈 구성(os 없음, c 남음), 호스트 도구 바인딩 패턴, 외부 중단 수단 없음, persist_main 지역 변수 이월(2026-11-01 구현, panic이면 초기화), 반복 eval 버그 수정 기록, CLI REPL 시작 실패, 호스트 함수는 값 매개변수를 소유(해제 필요)
- [코루틴 경위](docs/decisions/project_coroutines.md) — coinit · coresume · coyield는 upstream `b751ca6c`(2025-11)에서 삭제, 지금은 `#[generator]`만 동작, 스택형 `Fiber`는 미구현, `#[generator]`가 반환 타입을 바꾸는 점에 대한 평가, 비어 있는 부분은 fork가 직접 설계
- [Slice.append 버퍼 공유](docs/decisions/project_slice_append_aliasing.md) — 유일 참조 버퍼를 공유하는 빠른 경로 때문에 `c := a.append(x)`처럼 받는 쪽을 남기면 관리 원소가 샘. 2026-11-01 버퍼 앞 8바이트에 초기화 원소 수를 두는 방식(Swift식)으로 고침, 관리 타입만 기록, 별칭 의미 문제는 남음
- [VM 실행 중단](docs/decisions/project_vm_interrupt.md) — `cl_vm_interrupt`(스레드 안전) · `cl_vm_set_fuel`(검사점 횟수), 검사점은 역방향 JUMP와 CALL 계열, 결과 `CL_ERROR_INTERRUPT`, 오버헤드 1~2%
