# 표준 모듈 `path`

작성일 2026-11-17.

## 배경

tars-agent ADR 0010은 세계에 닿지 않는 순수 계산의 예로 "경로 문자열 다루기"를 적었다. cyber에는 `os.baseName`과
`os.dirname`만 있었다. 둘 다 `os` 안에 있어 `os`를 막는 임베딩 호스트에서는 쓸 수 없었고, 이름 규칙(camelCase와
소문자)도 서로 달랐다. agent-guide는 `p.split('/').last()`라는 우회를 가르쳤다.

## 비교 (Python, Rust, Zig, Nim, Go)

| 기능 | Python `os.path` | Rust `Path` | Zig `std.fs.path` | Nim `os` | Go `path` |
|---|---|---|---|---|---|
| 잇기 | `join` (절대 경로가 앞을 버림) | `join` (같음) | `join` (이어 붙임) | `joinPath` (이어 붙임) | `Join` (이어 붙이고 Clean) |
| 마지막 이름 | `basename` (`'a/'`는 `''`) | `file_name` (끝 `/` 무시) | `basename` (끝 `/` 무시) | `extractFilename` | `Base` (끝 `/` 무시, `''`는 `'.'`) |
| 상위 | `dirname` (`'a/b/'`는 `'a/b'`) | `parent` (Option) | `dirname` (끝 `/` 무시, optional) | `parentDir` | `Dir` (`'.'`, Clean) |
| 확장자 | `splitext` (`'.bashrc'`는 없음) | `extension` (같음, `.` 빼고) | `extension` (`.` 포함) | `splitFile` | `Ext` (`'.bashrc'`도 확장자) |
| 줄기 | — | `file_stem` | `stem` | `splitFile` | — |
| 정리 | `normpath` | — | `resolve` | `normalizedPath` | `Clean` |
| 절대 | `isabs` | `is_absolute` | `isAbsolute` | `isAbsolute` | `IsAbs` |

## 결정

- 구분자는 `/` 하나. Go `path`(not `filepath`)처럼 순수 문자열 규칙이다. 파일 시스템을 보지 않는다.
- `join`은 이어 붙이고 정규화한다(Go · Zig · Nim). 뒤 인자가 `/`로 시작해도 앞을 버리지 않는다. 빈 인자는 건너뛰고, 모두
  비면 `''`(Go).
- `base`, `dir`은 끝 `/`를 무시한다(Rust · Zig · Go의 `Base`). 그래서 `dir`과 `base`를 다시 이으면 원래 경로(정규화)다.
  `dir`은 옵션이 아니라 `str`이고 폴더가 없으면 `'.'`(Go). 에이전트가 `.?`를 빠뜨리는 실수를 줄인다.
- `ext`는 `.`을 포함하고(Python · Zig · Go), `'.bashrc'`는 확장자가 없다(Python · Rust · Zig). `stem`은 Rust · Zig 이름.
- 이름은 snake_case 한 단어 위주(`base`, `dir`, `ext`, `stem`, `normalize`, `is_absolute`).
- `os.baseName`, `os.dirname`은 뺐다. 옛 이름에는 옮긴 곳을 알려 주는 힌트(`sema.moved_module_syms`).

## 넣지 않은 것

- `relative(from, to)`, `split`(둘을 돌려줄 타입이 먼저 정해져야 한다), Windows 구분자. 필요의 증거가 생기면 다시 본다.
