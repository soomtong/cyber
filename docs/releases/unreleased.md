# 0.4.5 이후 변경 (미릴리스)

0.4.5(2026-11-11) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

- tokenizer가 `!=` · `<=` · `>=` · `<<` · `>>` · `<>` 토큰의 끝 위치를 한 글자 짧게 기록했다. 파서는 이 값을 쓰지 않아 동작
  차이는 없었고, 토큰 원문을 잘라 쓰는 포매터에서 드러났다.
- `a + b * c * d`처럼 우선순위가 높은 연산자가 이어질 때 두 번째 이후 `binExpr`의 `op_pos`가 첫 연산자 위치였다. 위치만
  고쳤고 구문 트리 모양은 그대로다.

## 언어와 표준 라이브러리

- `cyber fmt`가 동작한다(이전에는 `TODO` panic, F-33). 파일이나 디렉터리를 받아 제자리에서 다시 쓰고 바뀐 경로를 출력한다.
  `--check`는 쓰지 않고 바뀔 경로만 출력하며 있으면 종료 코드 1, `--stdout`은 결과를 표준 출력으로, 경로가 없거나 `-`면
  stdin → stdout이다. 공백만 바꾼다: 블록 4칸 들여쓰기, 이항 연산자 · `:=` · `->` 양쪽 한 칸, 괄호 안쪽 공백 제거, 줄 끝 공백 ·
  연속 빈 줄 정리. 줄을 합치거나 나누지 않고 옵션이 없다. 결과를 다시 파싱해 원본과 구문 트리 · 주석이 같을 때만 쓴다.
  규칙은 `docs/docs.md`의 "Format source.", 설계는 `docs/decisions/project_fmt.md`.
- `examples/fmt.cy`: 같은 규칙을 Cyber로 구현한 예제.

## 임베딩 API

- `cl_vm_format(vm, src, &out)`: `cyber fmt`와 같은 포매터. 파서만 돌고 VM 상태는 바뀌지 않는다. 구문 오류면 false와
  `line:col: message`를 돌려준다. `out`은 `cl_vm_freeb`로 해제한다.

## 변경

## 문서
