# `os` 파일 함수의 텍스트 · 바이트 이름

작성일 2026-11-16.

## 배경

0.4.12의 파일 함수는 짝이 맞지 않았다.

| 함수 | 반환 / 인자 |
|---|---|
| `read_file(path)` | `![]byte` |
| `read_file_str(path)` | `!str` (UTF-8 검사 없음) |
| `write_file(path, str)`, `write_file(path, []byte)` | 오버로드 |

tars-agent 요청(`cyber-0.4.12-spike-defects.md` (c))에서 모델이 `write_file`의 짝으로 `read_file`을 짐작하고 텍스트로 써서
`{0x68, 0x69}`가 찍혔다. 컴파일 오류가 나지 않아 틀린 값이 조용히 지나간다.

## 비교

- Rust: `fs::read` 바이트, `fs::read_to_string` 텍스트(UTF-8 검사), `fs::write`는 둘 다 받는다.
- Python pathlib: `read_text` · `read_bytes` · `write_text` · `write_bytes`. `open().read()`는 텍스트가 기본이다.
- Nim: `readFile` · `writeFile`, 둘 다 `string`.
- Go · Zig: 바이트만.

## 결정

기본 이름은 텍스트, 바이트는 `_bytes` 접미사로 명시한다. 쓰기의 오버로드는 없앤다.

| 함수 | 반환 / 인자 |
|---|---|
| `read_file(path)` | `!str`. UTF-8이 아니면 `error.Unicode` |
| `read_file_bytes(path)` | `![]byte` |
| `write_file(path, str)` | `!void` |
| `write_file_bytes(path, []byte)` | `!void` |

- 가장 먼저 짐작하는 이름이 가장 흔한 일(텍스트)을 한다. Python 습관과 맞는다.
- 네 이름이 대칭이라 하나를 알면 나머지를 짐작할 수 있다. 오버로드로 `write_file`이 바이트도 받으면 `write_file_bytes`와
  같은 일을 하는 길이 둘이 되므로 받지 않는다(사용자 결정). 오버로드 자체는 컴파일 때 정해져 실행 비용이 없다.
- `read_file`은 `str.from_utf8`로 검사한다(Rust `read_to_string`과 같다). 파일은 프로그램 밖의 바이트이므로
  `project_str_from_utf8.md`의 기준을 따른다.
- `read_file_str`은 별칭 없이 지웠다(1.0 전). 쓰면 'Can not find the symbol `read_file_str` in `os`.'다.
  `write_file(p, bytes)`는 'Expected argument `str`, found `[]byte` ...'다. 둘 다 고치는 이름을 말하지 않는다.
  모델이 자주 걸리면 고치는 법을 말하는 문구를 더한다.

## 바뀐 곳

`src/std/os.cy`, 저장소 안 호출 19곳(`str(os.read_file(..)!)` → `os.read_file(..)!`, `read_file_str` → `read_file`,
tzif 픽스처 → `read_file_bytes`), `docs/docs.md` "Strings from bytes" 예제, `docs/agent-guide.md` Modules 절.
테스트 `src/test/modules/os.cy` "Text and bytes".
