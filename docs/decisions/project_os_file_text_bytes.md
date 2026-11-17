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
- `read_file_str`은 별칭 없이 지웠다(1.0 전). 처음에는 'Can not find the symbol `read_file_str` in `os`.',
  `write_file(p, bytes)`는 'Expected argument `str`, found `[]byte` ...'뿐이라 고치는 이름을 말하지 않았다.

## 오류 문구에 새 이름 (2026-11-17, 사용자 결정)

옛 꼴은 모두 고칠 이름을 말한다. 별칭을 두지 않는 대신 오류가 옮기는 법을 알려 준다.

| 쓴 코드 | 붙는 힌트 |
|---|---|
| `os.read_file_str(p)`, `os.readFileStr(p)` | Use `os.read_file`. It returns `str`. |
| `os.write_file(p, bytes)` | Write bytes with `os.write_file_bytes`. |
| `os.write_file_bytes(p, s)` | Write text with `os.write_file`. |
| `os.read_file(p)!`을 `[]byte` 자리에 | `os.read_file` returns `str`. Read bytes with `os.read_file_bytes`. |
| `os.read_file_bytes(p)!`를 `str` 자리에 | `os.read_file_bytes` returns `[]byte`. Read text with `os.read_file`. |

- 출처 힌트(아래 두 줄)는 값이 그 호출에서 바로 왔거나(`!`, 괄호를 벗겨서) 그 호출로 초기화한 지역 변수일 때 붙는다
  (`LocalVarS.init_node`). 대입으로 값이 바뀐 변수도 선언의 초기식을 본다. 모듈 이름은 쓴 그대로 비교한다(`use os`의 `os`).
- 인자 불일치에서 출처 힌트가 쓰기 함수 힌트보다 먼저다. `os.write_file_bytes(p, os.read_file(q)!)`는 바이트 복사를 하려다
  읽기를 잘못 고른 경우가 많다.
- 표는 `sema.zig`의 `moved_module_syms`(없는 이름), `call_arg_hints`(함수 · 인자 타입), `result_type_hints`(출처 호출 ·
  기대 타입 · 실제 타입). 다른 std 이름을 나누거나 옮기면 이 표에 한 줄을 더한다. 0.4.14의 snake_case 이름은
  `toSnakeCase` · `member_aliases`로, `os.baseName` · `os.dirname`은 `moved_module_syms`로 이미 알려 준다.
- 테스트 `modules/os_read_file_str_error.cy` · `os_write_file_bytes_arg_error.cy` · `os_read_file_bytes_hint_error.cy` ·
  `os_read_file_text_hint_error.cy`.

## 바뀐 곳

`src/std/os.cy`, 저장소 안 호출 19곳(`str(os.read_file(..)!)` → `os.read_file(..)!`, `read_file_str` → `read_file`,
tzif 픽스처 → `read_file_bytes`), `docs/docs.md` "Strings from bytes" 예제, `docs/agent-guide.md` Modules 절.
테스트 `src/test/modules/os.cy` "Text and bytes".
