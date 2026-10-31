# MEMORY

- [Zig 0.17 업그레이드](docs/decisions/project_zig_017_upgrade.md) — 검증 환경(0.15.2는 Linux 컨테이너에서만), Io · env · args 규칙, `vm.h` 모드별 padding, out 파라미터와 ReleaseFast UB
- [fork 릴리스와 CI](docs/decisions/project_fork_release_ci.md) — origin 태그 필요(0.3), 태그 push 릴리스, 번들에 src/ 포함, install.sh는 lib/cyber + 심링크, msvc malloc · macOS x86_64 INODE64 · wasm32 Value ABI
- [fork의 용도와 방향](docs/decisions/project_direction.md) — Python · Perl · Shell 대용 스크립트 CLI, 네이티브 바이너리 불필요(TCC/C AOT로 충분), LLVM 백엔드 닫음, TARS 에이전트 루프(CodeAct) 언어 후보
