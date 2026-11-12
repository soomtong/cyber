# 0.4.9 이후 변경 (미릴리스)

0.4.9(2026-11-12) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

## 언어와 표준 라이브러리

## 임베딩 API

- `cl_vm_compile_report_count(vm)` · `cl_vm_compile_report(vm, idx, &rep)` · `cl_vm_compile_report_note(vm, idx, note_idx, &rep)`가
  컴파일 오류의 전체 범위와 딸린 위치를 `CLReport`로 준다. `cl_vm_compile_error`는 시작 위치와 첫 줄 안의 길이만 줬고
  `First declared at:` · 템플릿 확장 호출 지점은 요약 문자열에만 있었다. `CLReport`는 `line` · `col` ~ `end_line` · `end_col`
  (0부터, 열은 바이트, 끝은 범위 밖)과 같은 범위의 바이트 오프셋 `pos` · `end_pos`를 가진다. 여러 줄에 걸친 노드는 끝 줄까지 간다.
  토큰 · 파싱 오류는 그 자리의 코드포인트 하나(줄 끝 · 소스 끝이면 빈 범위)다. 딸린 위치의 `kind`는 `CL_REPORT_NOTE`이고
  템플릿 확장 호출 지점은 `msg`가 비어 있다. 컴파일러가 첫 오류에서 멈추므로 개수는 아직 0 또는 1이다.
  `cl_vm_compile_error` · `CLCompileError`는 그대로다. LSP 서버 계획의 P0다(`docs/specs/2026-11-12-lsp-design.md`).

## 변경

## 문서
