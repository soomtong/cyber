# 이 fork의 용도와 방향

2026-10-31, LLVM 백엔드 항목을 닫으면서 적어 둔 것.

## 용도

- soomtong/cyber는 Cyber를 평소 쓰는 Python · Perl · Shell 스크립트의 대용으로 쓰기 위해 직접 fork해서
  빌드하는 저장소다. 목표는 스크립트를 바로 실행하는 CLI이고, Cyber로 네이티브 바이너리를 만들 이유는 없다.
  바이너리가 필요한 일은 Zig나 Odin 같은 안정된 언어로 한다.
- 더 나아가 TARS 리눅스(`/Users/dp/Repository/tars-linux`)에 붙일 내장 에이전트 루프의 실행 언어 후보로
  Cyber를 살펴보는 중이다. 에이전트가 도구 호출을 JSON으로 나열하지 않고 스크립트를 써서 실행하는
  CodeAct 계열 설계라, 작은 런타임 · 빠른 시작 · 임베딩 가능한 라이브러리(`libcyber`)가 중요하다.

## 백엔드

- 기본 백엔드는 바이트코드 VM이다. 네이티브가 필요하면 TCC/C AOT(`-Dtest-backend=tcc|cc`)로 충분하다.
- LLVM 백엔드(`src/llvm.zig` · `src/llvm_gen.zig`, `-Djit`)는 켜지 않는다. upstream도 2025-11 이후
  손대지 않은 미완성 경로다. Zig 0.17 업그레이드의 남은 항목 7(LLVM-C 번역 모듈)은 이 이유로 닫았다.
  코드는 `cy.hasJIT` 뒤에 있어 빌드에 영향이 없으므로 지우지 않고 둔다.

## 따라오는 우선순위

- 릴리스 번들과 `install.sh`는 CLI 실행 환경(실행 파일 + `src/` 표준 모듈)을 바로 쓰게 하는 데 맞춘다.
- 에이전트 루프 쪽 검토는 임베딩 API(`src/lib.zig`, `cyber.h`)와 `-Dffi=false` 같은 작은 구성이 기준이 된다.
