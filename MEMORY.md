# MEMORY

- [Zig 0.17 업그레이드](docs/decisions/project_zig_017_upgrade.md) — 검증 환경(0.15.2는 Linux 컨테이너에서만), Io · env · args 규칙, `vm.h` 모드별 padding, out 파라미터와 ReleaseFast UB
- [fork 릴리스와 CI](docs/decisions/project_fork_release_ci.md) — origin 태그 필요(0.3), 태그 push 릴리스, 번들에 src/ 포함, install.sh는 lib/cyber + 심링크, msvc malloc · macOS x86_64 INODE64 · wasm32 Value ABI
- [fork의 용도와 방향](docs/decisions/project_direction.md) — Python · Perl · Shell 대용 스크립트 CLI, 네이티브 바이너리 불필요(TCC/C AOT로 충분), LLVM 백엔드 닫음, TARS 에이전트 루프(CodeAct) 언어 후보
- [libcyber 임베딩 검토](docs/decisions/project_embedding_agent_loop.md) — 라이브러리 모듈 구성(os 없음, c 남음), 호스트 도구 바인딩 패턴, 외부 중단 수단 없음, persist_main은 upstream 미완성, 반복 eval 버그 수정 기록, CLI REPL 시작 실패
- [코루틴 경위](docs/decisions/project_coroutines.md) — coinit · coresume · coyield는 upstream `b751ca6c`(2025-11)에서 삭제, 지금은 `#[generator]`만 동작, 스택형 `Fiber`는 미구현, `#[generator]`가 반환 타입을 바꾸는 점에 대한 평가, 비어 있는 부분은 fork가 직접 설계
