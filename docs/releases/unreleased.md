# 0.4.13 이후 변경 (미릴리스)

0.4.13(2026-11-16) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 임베딩: resolver로 모듈 허용 표

- 컴파일러가 스스로 찾는 내장 모듈(`#[extern]` 함수가 있는 모듈의 `@initBindLib`을 위한 `c`, `meta`)은 이제 호스트 resolver를
  부르지 않고 이미 올라온 모듈에서 찾는다. 전에는 스크립트가 `use math`만 해도 resolver에 `main`이 `c`를 가져오는 호출이 와서,
  "스크립트의 `use c`는 막고 `math`는 허용"하는 resolver가 `use math`까지 막았다. 이제 resolver에는 소스의 `use`만 온다.
- resolver가 거부했을 때 문구가 'Failed to resolve module `c`.'처럼 모듈 이름을 말한다(전에는 'Failed to resolve module.').
- `docs/docs.md` "Allowing modules": 믿을 수 없는 스크립트의 모듈 허용 표는 로더가 아니라 resolver(`curUri`)로 만든다.
  결정 기록은 `docs/decisions/project_embedding_module_allowlist.md`.

## `use c` 없는 `#[extern]` 함수가 컴파일 오류

- `c` 모듈이 실리지 않은 채 `#[extern]` 함수를 선언하면(`#[extern='abs'] fn c_abs(a int) -> int`) 프로그램 초기화가 `c`의
  `@initBindLib`을 null로 풀어 프로세스가 끝났다(CLI는 `panic: attempt to use null value`, 임베딩 ReleaseFast는 `cl_vm_validate`
  안의 세그폴트). 이제 선언 위치의 컴파일 오류 'An `#[extern]` function needs the `c` module. Add `use c`.'다. `use c`나 `c`를
  가져오는 모듈(`math`)이 먼저 있으면 그대로 된다. tars-agent 요청 `cyber-0.4.13-extern-without-c.md`. 테스트
  `syntax/extern_without_c_error.cy`, `lib_test/session.zig` "An `#[extern]` function without the `c` module".

## agent-guide: 임베딩 호스트

- `docs/agent-guide.md`(`cyber doc --for-agents`) 머리말에 임베딩 호스트의 지시가 실행 방법과 모듈에 대해 가이드보다 앞선다는
  줄, "Modules" 절에 거부된 모듈의 문구('Failed to load module: name', 'Failed to resolve module `name`.', 호스트의 문구)와
  그때 다시 시도하지 말라는 줄을 더했다. CLI를 기준으로 쓴 절은 그대로다. tars-agent 요청 `cyber-agent-guide-embedding-host.md`.

## 모듈 API: 패키지의 `docs/api.json`과 `cyber doc --api`

- `docs/api.json`(core와 표준 모듈의 함수 · 타입 · 메서드, 시그니처와 doc, 항목마다 `module`)을 저장소에 커밋하고 Zig 패키지
  `.paths`에 넣었다. 임베딩 호스트가 빌드 때 패키지에서 읽어 모듈별로 거를 수 있다. 커밋하는 판의 `version`은 `source`이고,
  릴리스 자산의 `api.json`은 전처럼 버전을 넣어 따로 만든다.
- `cyber doc --api <module>`이 그 모듈의 함수, 타입과 메서드를 시그니처와 doc 첫 줄로 찍는다. `cyber doc --api`는 모듈 목록이다.
  CLI는 공백을 뺀 `api.json`(약 134 KB)을 내장한다(`src/tools/compact_json.zig`).
- `docs/api.json`이 소스와 다르면 `src/tools/verify.sh` 14단계와 Latest Build의 "Check docs/api.json."이 실패한다. 모듈 API를
  바꾸면 `cyber docs/gen-api-json.cy`를 다시 돌려 함께 커밋한다.
- agent-guide의 "Modules" 절이 api.html 대신 `cyber doc --api <module>`을 가리킨다. tars-agent 요청 `cyber-module-api-for-agents.md`.

## x86_64 AVX2에서 `str.index`의 틀린 위치 (F-160)

- AVX2로 빌드된 x86_64(배포된 Linux x64 바이너리, native 빌드)에서 128바이트 이상인 문자열의 한 바이트 검색이 128바이트
  블록의 96~127번째에 있는 첫 위치를 `블록 시작 + 128`로 돌려줬다. `s.index('\n')`, `s.index(byte)`, 그리고 그 위의
  `s.split('\n')` 등이 조용히 틀렸다(줄 둘이 이어 붙음). `src/string.zig`의 inline asm을 Zig 벡터 코드로 바꿨다. arm64와
  AVX2가 없는 x86_64는 영향이 없었다. 테스트 `core/str_index_char_blocks.cy`.
- `gen-docs.yml`이 커밋된 `docs/api.json`을 옮기지 않는다(playground 빌드가 내장한다). 사이트의 `api.json`은 버전을 넣어 따로 쓴다.

## CLI: `cyber --version`

- `cyber --version`이 버전을 찍고 끝난다. 전에는 모르는 옵션으로 무시되어 REPL로 들어갔다. `cyber version`은 그대로다.
- `cyber version`, `cyber --version`, `cyber help`(`-h`, `--help`)의 출력이 stderr에서 stdout으로 옮겨졌다.
  `v=$(cyber --version)`로 버전을 잡을 수 있다. 원본 파일 뒤의 `--version`은 전처럼 스크립트 인자다.

## 컬렉션과 문자열 메소드 보강

- `Map.values()`(`HashMap`도): 값 목록을 `keys()`와 같은 순서로 준다.
- `[]T`, `[&]T`, `Array`의 `reverse()`: 그 자리에서 뒤집는다. `sort()`처럼 같은 버퍼를 나눈 복사본(`ys := xs`)에도 보인다.
- `Array.pop() -> ?T`: 마지막 원소를 빼서 돌려주고, 비었으면 `none`. 복사 가능한 원소만(`last()`와 같다). `[]T`에는 없다
  (크기 변경이 새 값을 돌려주는 규칙이라 값과 목록을 같이 돌려줄 수 없다).
- `str.lines()`: `\n`과 `\r\n`에서 나누고 줄바꿈은 빼며, 끝의 줄바꿈은 빈 줄을 만들지 않는다. 빈 문자열은 줄이 없다.
- `str.pad_left(width)`, `pad_right(width)`와 `fill`을 받는 형태: rune 수가 `width`가 될 때까지 공백이나 `fill`(한 rune)을
  붙인다. 더 긴 문자열은 그대로, 한 rune이 아닌 `fill`은 'Invalid argument.' panic. 너비는 화면 칸이 아니라 rune 수다.
- 이름 힌트: `splitlines` → `lines`, `reversed` → `reverse`, `rjust` · `padStart` → `pad_left`, `ljust` · `padEnd` → `pad_right`.
- `docs/docs.md`(Slices, Maps, Strings "Lines and padding")와 `docs/agent-guide.md`의 메소드 목록과 Python 대응표.
  테스트 `core/Slice.cy`, `core/Array.cy`, `core/Map.cy`, `core/strings.cy`.

## `float.parse`

- `float.parse(s) -> !float`(`f32.parse`도): 숫자가 아닌 문자열에서 `error.InvalidCharacter`를 돌려준다. `float(s)`는 전처럼 0이다.
  `int.parse`의 짝. `'1.5'`, `'-2'`, `'1e3'`, `'inf'`, `'nan'`을 읽고 앞뒤 공백은 허용하지 않는다(`int.parse`와 같다).
  `docs/docs.md` Integers · Floats, agent-guide. 테스트 `core/floats.cy`.

## 이름을 snake_case로 통일 (깨지는 변경)

- 표준 라이브러리의 camelCase 공개 이름 57개를 snake_case로 바꿨다. 옛 이름은 남기지 않는다. 옛 이름을 쓰면
  'Can not find the symbol `trimLeft` in `str`. Did you mean `trim_left`?'처럼 새 이름을 알려 준다. 모듈 함수
  (`os.fileExists`)도 이제 같은 힌트를 낸다(`sema.suggestModuleSym`, 테스트 `modules/module_suggest_snake_error.cy`).
- 대부분 기계적 변환이다(`trimLeft` → `trim_left`, `fileExists` → `file_exists`, `eqNear` → `eq_near`). 다음은 아니다:
  `str.lastIndexOf` → `str.last_index`(`index`의 짝), `isNaN` → `is_nan`, `isInf` → `is_inf`, `io.indexOfNewLine` →
  `io.index_newline`(`str.index_newline`과 같은 이름). `Array.setLast` → `set_last`는 `Slice.set_last`와, `PtrSpan.toBytes`
  → `to_bytes`는 `str.to_bytes`와 같은 이름이 됐다.
- 바뀐 이름:
  - core: `str`의 `trim_left`, `trim_right`, `last_index`, `is_ascii`, `before_last`, `rune_str_at`, `init_rune`,
    `has_ascii_flag`, `Array.set_last`, `ensure_unused_cap`, `Object.to_string`, `PtrSpan.to_bytes`,
    `PartialVector.set_length`, `HashMap.find_slot`, `Wyhash`의 `read_int`, `read_i32`, `shallow_copy`, `small_key`,
    `utf8_check`, `utf8_decode`, `utf8_seq_len`.
  - os: `file_exists`, `create_dir`, `create_file`, `remove_file`, `remove_dir`, `file_info`, `access_file`, `get_env_all`,
    `nano_time`, `parse_args`, `fetch_url`, `cache_url`, `from_errno`, `open_lib`, `File.read_line`, `seek_from_end`,
    `seek_from_start`, `ArgsResult.get_all`. (`baseName`은 아래 `path` 절.)
  - math: `is_nan`, `is_inf`, `is_int`, `deg_to_rad`, `Vec2.len_sq`, `scale_to`, `Vec3.rotate_axis`, `rotate_y`,
    `Vec4.div_w`, `Transform3D.rotation_x`, `rotation_y`, `rotation_z`.
  - test: `eq_near`, `eq_type`. cli: `repl_read_line`. io: `index_newline`.
- 힌트 별칭 표(`rstrip` → `trim_right` 등)와 `docs/docs.md`, `docs/agent-guide.md`의 이름도 바꿨다. 릴리스 노트와 학습
  문서(`docs/study`)는 그때의 이름 그대로 둔다.

## `path` 모듈

- 새 표준 모듈 `path`(`src/std/path.cy`): `join(a, b)`, `join(parts)`, `base`, `dir`, `ext`, `stem`, `normalize`,
  `is_absolute`. 구분자는 `/` 하나이고 파일 시스템을 보지 않는다(Go `path` 패키지와 같은 방식). 파일 시스템에 닿지 않으므로
  `os`를 막는 임베딩 호스트도 허용할 수 있다. 결정 기록 `docs/decisions/project_std_path.md`.
- 깨지는 변경: `os.baseName`과 `os.dirname`을 뺐다. 'Can not find the symbol `dirname` in `os`. Use `path.dir` from `use path`.'
  처럼 옮긴 곳을 알려 준다. `os.dirname`은 `?str`을 돌려줬고(`'a'`는 none), `path.dir`은 `str`이다(`'a'`는 `'.'`,
  결과를 정규화한다).
- `docs/docs.md` "Paths", agent-guide의 모듈 목록과 Python 대응(`os.path.join` 등). 테스트 `modules/path.cy`.

