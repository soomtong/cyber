# tree-sitter 문법 (`exts/tree-sitter`)

작성일 2026-11-02.

## 배경

`exts/README.md`가 가리키던 instance-id/tree-sitter-cyber(마지막 커밋 2023-04-28 `fd1440e`)는 2023년 문법
(`func`, `var x = 1`, `import`, `object`)용이라 지금 문법(`fn`, `:=`, `use`, `type X:`, `#[bind]`, `?else`,
`%{}` 보간 등)을 거의 파싱하지 못한다. 라이선스는 `Cargo.toml`의 `license = "MIT"` 한 줄뿐이고 `LICENSE` 파일과
GitHub 라이선스 표시는 없다.

## 결정

- 문법은 `src/tokenizer.zig` · `src/parser.zig`를 기준으로 새로 썼다. 원본에서 가져온 것은 구성(외부 들여쓰기
  scanner, `highlights` · `locals` · `tags` 쿼리, `cy` 확장자 · shebang 감지)뿐이다.
- `LICENSE`는 MIT로 두고 원저작자(instance.id, 2023)와 이번 재작성(2026) 저작권 표시를 함께 적었다.
- 생성물 `src/parser.c`(약 12.5 MB) · `grammar.json` · `node-types.json` · `src/tree_sitter/`는 커밋하지 않는다
  (`.gitignore`). 사용 전에 `tree-sitter generate`를 실행한다. nvim-treesitter는 `requires_generate_from_grammar`로 대응.
- 식 안에서 `:` 뒤 한 줄 본문(람다, `?else:`, `!else:`)은 `return` · `break` · `continue` · `pass` · `yield` ·
  식 · 대입만 허용한다. 모든 문장을 허용하면 `parser.c`가 32 MB까지 커진다. 저장소 코드에서 쓰이는 형태는 `return`뿐이다.

## 검증

- `tree-sitter test`: 코퍼스 15건 통과.
- 저장소 `.cy` 333개 중 311개가 오류 노드 없이 파싱된다. 나머지 22개는 파싱 오류를 기대하는 테스트(`*_error.cy`,
  `src/test/syntax/`)이거나 옛 문법(`var a = 1`, `func`)이 남은 파일이다.
- `tree-sitter build`로 공유 라이브러리 생성 확인(macOS arm64, 약 1.4 MB).

## 컴파일러 파서와 다른 점

- 매개변수 목록의 단독 식별자는 이름으로 읽는다(`fn(int) -> bool`의 `int`).
- 호출 인자는 쉼표로만 구분한다(컴파일러는 줄바꿈도 허용).

## 2026-11-11 갱신 (0.4.6)

- 대조 방법을 바꿨다. `cyber fmt --check`(컴파일러 파서)가 받아들이는 파일만 골라 `tree-sitter parse -q`에 넣는다. 오류 기대
  테스트와 옛 문법 파일이 자동으로 빠진다.
- 차이는 둘이었다. `try: … else |err|:`의 캡처(문법은 `else err:`였다. `project_try_block.md`에서 `|err|`로 정해졌다)와 이번에
  생긴 숫자 구분자 `100_000`. `catch_clause`와 `number`를 고치고 코퍼스에 `Numbers`를 더했다(16건 통과).
- 결과: 컴파일러가 파싱하는 `.cy` 417개(`src` · `examples` · `docs` · `exts`) 모두 오류 노드 없음. tree-sitter CLI 0.27.2.
- 쿼리 네 개(`highlights` · `indents` · `locals` · `tags`)는 `tree-sitter query`로 로드되는 것만 확인했다. 에디터에서의 실제
  하이라이트는 확인하지 않았다.
