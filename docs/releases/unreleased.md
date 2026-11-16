# 0.4.13 이후 변경 (미릴리스)

0.4.13(2026-11-16) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.


## 오류 문구

- `let x := 1`(`mut` · `let mut`도)이 ``Cyber has no `let`. Declare with `x := 1`.``다. 전에는 `:=`를 값의 일부로 읽어
  ``Declare with `var x := 1 = value`.``라는 틀린 고치는 법이었다. 테스트 `syntax/foreign_decl_infer_error.cy`.

## 버그 수정

- 세션(`persist_main`)에서 스크립트 마지막 줄의 `out.remove(1)` · `out.clear()`가 마지막 표현식 값으로 받아들여져 컴파일 오류
  없이 지나갔다. 같은 줄이 다른 자리에서는 버린 결과의 컴파일 오류라 줄의 자리에 따라 뜻이 달랐다. 이제 마지막 줄에서도
  같은 오류다. 다른 값은 그대로 eval 결과다. tars-agent 요청 `cyber-0.4.13-dev-findings.md`. 테스트 `lib_test/session.zig`.
