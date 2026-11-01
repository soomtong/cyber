# MEMORY

- [Zig 0.17 업그레이드](docs/decisions/project_zig_017_upgrade.md) — 검증 환경(0.15.2는 Linux 컨테이너에서만), Io · env · args 규칙, `vm.h` 모드별 padding, out 파라미터와 ReleaseFast UB
- [fork 릴리스와 CI](docs/decisions/project_fork_release_ci.md) — origin 태그 필요(0.3), 태그 push 릴리스, 번들에 src/ 포함, install.sh는 lib/cyber + 심링크, msvc malloc · macOS x86_64 INODE64 · wasm32 Value ABI
- [fork의 용도와 방향](docs/decisions/project_direction.md) — Python · Perl · Shell 대용 스크립트 CLI, 네이티브 바이너리 불필요(TCC/C AOT로 충분), LLVM 백엔드 닫음, TARS 에이전트 루프(CodeAct) 언어 후보
- [libcyber 임베딩 검토](docs/decisions/project_embedding_agent_loop.md) — 라이브러리 모듈 구성(os 없음, c 남음), 호스트 도구 바인딩 패턴, 외부 중단 수단 없음, persist_main 지역 변수 이월(2026-11-01 구현, panic이면 초기화), 반복 eval 버그 수정 기록, CLI REPL 시작 실패, 호스트 함수는 값 매개변수를 소유(해제 필요)
- [코루틴 경위](docs/decisions/project_coroutines.md) — coinit · coresume · coyield는 upstream `b751ca6c`(2025-11)에서 삭제, 지금은 `#[generator]`만 동작, 스택형 `Fiber`는 미구현, `#[generator]`가 반환 타입을 바꾸는 점에 대한 평가, 비어 있는 부분은 fork가 직접 설계
- [Slice.append 버퍼 공유](docs/decisions/project_slice_append_aliasing.md) — 유일 참조 버퍼를 공유하는 빠른 경로 때문에 `c := a.append(x)`처럼 받는 쪽을 남기면 관리 원소가 샘. 2026-11-01 버퍼 앞 8바이트에 초기화 원소 수를 두는 방식(Swift식)으로 고침, 관리 타입만 기록, 별칭 의미 문제는 남음
- [VM 실행 중단](docs/decisions/project_vm_interrupt.md) — `cl_vm_interrupt`(스레드 안전) · `cl_vm_set_fuel`(검사점 횟수), 검사점은 역방향 JUMP와 CALL 계열, 결과 `CL_ERROR_INTERRUPT`, 오버헤드 1~2%
- [0.3 → 0.4 재설계 역사](docs/history/cyber_0_3_to_0_4_overview.md) — 세 구간(upstream 2024 재설계 · upstream 2025 `b751ca6c` · fork 2026), 기준 커밋, 키워드 diff, 미완 40곳의 우선순위. 주제 문서: type_system · ownership_memory · coroutines_concurrency · error_handling · embedding_cli
- [tars 에이전트 요구사항 초안 검토](docs/decisions/project_tars_agent_runtime_review.md) — 초안 §1.3은 0.3 기준이라 틀림, 호스트 함수 안에서 멈추고 재개하는 수단 없음(await는 spin-wait, 비-main await TODO), 대안 A(동기 호스트 함수 + VM당 OS 스레드) 권고, VM당 RSS 약 2 MB(첫 VM 6.7 MB), JSON · 정규식 · 날짜 라이브러리 없음, tcc LGPL은 FFI 끄면 미링크
- [컴파일 타임 루프 결과](docs/decisions/project_ct_eval_loop_result.md) — `cte.zig`의 for · switch 결과가 undefined로 시작해 0회 루프에서 쓰레기 반환(두 번째 VM의 인자 없는 `spawn` crash), 루프 안 return 소실, type const가 기존 타입을 반환하면 이름을 덮어쓰는 문제는 남음
- [문자열 탐색 SIMD](docs/decisions/project_string_index_simd.md) — `indexOfSimdFixed` 앞에 8개 벡터 두 단계 루프(첫 바이트 축약 → 첫+끝 축약 → 비트마스크), aarch64에 movemask가 없어 비트마스크를 피함, index 81→56 ms, index_rare 57→33 ms(Lua memchr 40 ms), 테스트는 벡터 크기 16·32·64를 모두 확인
