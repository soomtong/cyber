# regex 적합성 fixture

`src/test/modules/regex_spec.cy`가 읽는 테스트 데이터다. Rust `regex` 크레이트(ripgrep의 기본 엔진)의 `testdata/*.toml`을
`convert.py`로 JSON으로 바꾼 것이다. 한 줄이 테스트 하나이고 `hay`는 입력 바이트의 16진수다.

- 출처: https://github.com/rust-lang/regex `testdata/`
- 커밋: `3d79fe92666a9f191d7677ebc123ac165eac200c`(2026-11-15에 받음)
- 라이선스: MIT 또는 Apache-2.0 중 MIT로 받는다(`LICENSE-MIT`). `fowler-*.json`의 원본(`testdata/fowler/dat`)은 AT&T testregex
  모음(Glenn Fowler)에서 Go 배포본을 거쳐 온 것이고, `testregex.c`의 라이선스가 "testregex.c and all associated test data"를
  덮는다. 그 문구를 `LICENSE-FOWLER`에 두었다(Rust 저장소에는 이 파일이 없어 Go 저장소의 `testregex.c`에서 옮겼다).

## 변환 규칙

`python3 convert.py <rust-lang/regex의 testdata 경로> <이 폴더>`. 이 모듈의 API로 같은 뜻을 물을 수 있는 테스트만 남긴다(820개).

- 뺀 것: 정규식 여러 개(`RegexSet`), `match-kind`가 leftmost-first가 아닌 것, `search-kind`가 earliest · overlapping인 것,
  `line-terminator` 지정, 끝 경계(`bounds`의 end)가 입력 끝이 아닌 것, UTF-8이 아닌 입력, `regex-lite.toml`(Unicode 클래스가
  없는 엔진의 답), 이 모듈이 설계상 받지 않는 문법(`(?-u)` · `(?R)`, 일반 범주 · 스크립트 밖의 `\p{..}` 속성).
- `unicode = false` · `utf8 = false` 테스트는 정규식과 입력이 모두 ASCII일 때만 남긴다(그때는 뜻이 같다).
- `anchored = true`는 일치가 하나 이하일 때 `\A(?:...)`로 감싸 첫 일치만 본다. `case-insensitive = true`는 `(?i)`를 앞에 붙인다.

갱신할 때는 새 커밋의 `testdata`로 다시 변환하고 이 파일의 커밋과 `regex_spec.cy`의 개수를 고친다.
