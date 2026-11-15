# 표준 모듈 `json` · `toon` (2026-11-15)

## 배경

LLM 코딩 에이전트는 도구 입출력을 JSON으로 주고받는다. 이 저장소의 방향(`project_direction.md`)은 에이전트가 스크립트를
써서 실행하는 CodeAct 계열인데, 표준 라이브러리에 JSON 파서 · 직렬화가 없었다(`project_tars_agent_runtime_review.md`
"없는 순수 라이브러리"). TOON(Token-Oriented Object Notation)은 같은 JSON 데이터 모델을 들여쓰기 · 선언된 배열 길이 ·
균일한 객체 배열의 표 머리로 적어 프롬프트 토큰을 줄이는 형식이다. 사양 v4.4(Working Draft, 2026-10-08,
https://github.com/toon-format/spec)를 따른다.

## 참고한 설계

- Rust `serde_json`: `Value` enum(`Null` · `Bool` · `Number` · `String` · `Array` · `Object`), `v["a"]["b"]`가 없으면 `Null`,
  `get` · `as_*`는 `Option`, `to_string` · `to_string_pretty`, 오류에 줄 · 칸, 재귀 한도 128, 중복 키는 마지막 값,
  `preserve_order` 기능으로 키 순서 유지, `Serialize` derive.
- Zig `std.json`: `Value` union(`integer` · `float` · `number_string` 분리), `ObjectMap`이 삽입 순서를 지키는
  `ArrayHashMap`, `parseFromSlice` · `stringify`(whitespace 옵션), 실패 위치는 호출자가 넘기는 `Diagnostics`.
- TOON 참조 구현(TypeScript)과 공식 구현 목록(Go · .NET · Java 등 4.4, Python 4.2, Rust · Swift 4.1, 커뮤니티 Zig 3.0).

## 결정

- 두 모듈 모두 순수 Cyber(`src/std/json.cy` · `toon.cy`)로 쓰고 `json.zig` · `toon.zig`는 소스를 내주는 바인드만 한다
  (`test` 모듈과 같은 꼴). 라이브러리 기본 로더(`compiler.zig` `mods`)와 CLI(`cli.zig`) 양쪽에 등록하고 C API에
  `cl_mod_bind_json` · `cl_mod_bind_toon`을 둔다. 표준 모듈이므로 `deny_raw_ptrs` 예외 목록에도 들어가지만 원시 포인터는 쓰지 않는다.
- 데이터 모델은 `json.Value` 하나를 두 모듈이 같이 쓴다. 수는 Zig처럼 `int`와 `float`를 나눈다. 소수부 · 지수가 없고 `int`에
  맞으면 `int`(ID 같은 큰 정수가 2^53을 넘어도 정확), 아니면 `float`. `int` 범위 밖 정수는 `float`(가장 가까운 값)다.
  `number_string` 같은 무손실 경로는 두지 않았다.
- 객체는 `json.Object{entries []Entry}`로 삽입 순서를 지킨다(TOON은 키 순서 보존이 MUST). 조회는 선형 탐색이다. 파싱 중 중복
  키 찾기만 16개를 넘으면 임시 `Map[str, int]`를 쓴다. 중복 키는 serde처럼 마지막 값이 이기고 위치는 첫 번째다(TOON 비엄격과 같다).
- 오류: 언어에 오류 payload가 없어(`docs.md` "error payload") Zig `Diagnostics`처럼 호출자가 넘기는 `json.Diag`에
  `msg` · `line` · `col` · `pos`를 쓴다. 오류 값은 `error.Syntax`와 `error.Unicode`(UTF-8 아님) 둘뿐이다. 문구는 에이전트가 고칠 수
  있게 무엇을 기대했고 무엇을 찾았는지 말한다.
- 중첩 한도 256(serde 128보다 넉넉하다). 파서가 재귀라 VM 스택을 지킨다.
- 직렬화의 수: TOON §2의 정규형을 JSON에도 쓴다(JS `JSON.stringify`와 같다). `1e-6 <= |x| < 1e21`과 0은 지수 없는 소수,
  `.0` 없음, `-0`은 `0`, 범위 밖은 `1e-7` · `1e+21`. 자릿수는 `f64_fmt`(Zig `std.fmt.float.render` decimal, 최단 왕복)의 결과를
  잘라 만들어 바인딩을 더하지 않았다. `float` 1.0이 `1`로 나가 다시 읽으면 `int`가 되지만 `as_float`가 `int`도 받으므로 쓰는 쪽은
  같다(serde는 `1.0`을 남긴다. 여기서는 JS · TOON과 맞췄다).
- 리플렉션 변환 `json.from(x)` · `json.encode(x)`는 serde `Serialize` 대신 `type.info` · `#for` · `meta.access`(core `dump_str`과
  같은 방식)를 쓴다. `Map`은 `NoCopy`라 빌림으로 받는다(`json.encode(&map)`), 키는 정해진 출력을 위해 정렬한다. choice는 serde의
  외부 태그 꼴(`"case"`, `{"case": payload}`)이다. 반대 방향(`Value` → 타입)은 아직 없다. struct를 필드별로 만들 메타 수단이
  필요하다.
- `Value`의 동등성: `==`는 연산자 메서드로 정의할 수 없고 core `@eq`가 choice를 지원하지 않는다. `Value.eq`를 두고(숫자는 값,
  객체는 키 순서 무관) 문서에 `== none` 대신 `?else` · `if |x|`를 쓰라고 적었다. core `@eq`에 choice를 더하는 것은 따로 판단한다
  (슬라이스 `==`의 의미가 먼저 정해져야 한다).
- TOON 인코더는 사양의 형식 선택 순서를 따른다: 원시값 → 빈 배열 → 원시 배열(인라인) → 표(균일 원시 열 또는 중첩 균일 열,
  필드 그룹 `customer{name,country}`) → 키 표(항목 둘 이상, 객체 필드 · 루트 위치) → 목록. 목록 항목 객체는 첫 필드를 하이픈 줄에
  두고 그 범위는 +2, 나머지 필드는 +1. 목록 안의 키 없는 배열에는 표를 쓰지 않는다(키 없는 표 머리는 루트에서만 유효).
  문자열 · 키 인용은 §7.2 · §7.3 열 가지 조건 그대로다. 사양이 MUST로 요구하는 짝 없는 서로게이트 거부는 Cyber `str`이 UTF-8
  바이트이므로 "UTF-8이 아닌 문자열"로 옮겨 `toon.encode`가 `!str`로 `error.Unicode`를 돌려준다. `json.stringify`는 검사하지 않는다.
- TOON 디코더는 줄 준비(BOM · CRLF · 뒤 공백 · 주석 · 빈 줄) 뒤 재귀 하강이다. 헤더 span은 첫 항목부터라 머리와 첫 행 사이 빈 줄은
  허용하고, 열린 span의 바깥쪽 내용 깊이 이상인 줄 앞의 빈 줄은 엄격 모드에서 오류다. 표 행 판별은 §9.3(구분자가 콜론보다 앞이면
  행), 키 표는 콜론 있는 줄은 모두 행. 비엄격 복구 다섯 가지(개수 · 중복 키 · 탭 들여쓰기 · 빈 줄 · 깊이 점프)를 모두 넣었다.
  수 토큰은 JSON 수 문법일 때만 수이고, `float` 범위를 넘으면 참조 구현처럼 문자열이다(사양이 정책 문서화를 요구).
- 적합성: 공식 fixture(spec 커밋 `009074d`, 인코드 160 · 디코드 404)를 `src/test/assets/toon-spec`에 MIT 라이선스와 함께 두고
  `modules/toon_spec.cy`가 우리 `json` 모듈로 읽어 돌린다(564/564). 파일을 읽어야 해서 `os.cy`와 같은 조건(FFI, MSVC · wasm 제외)에서만
  돈다. `modules/json.cy` · `modules/toon.cy`는 모든 대상에서 돈다.

## 성능

ReleaseFast에서 1.5 MB JSON(객체 1만 개) 파싱 약 0.15초, 직렬화 약 0.14초(약 10 MB/s). 에이전트가 다루는 KB 단위 문서에는
충분하다. 더 큰 입력이 필요하면 바이트 스캔(문자열 끝 · 공백)을 Zig 바인딩으로 옮기는 것이 첫 단계다.

## 작업 중 찾은 결함

- F-141(수정): `.?` · `!`로 임시 옵션 · 결과에서 꺼낸 관리 값을 `==`나 `for`가 빌리면 해제되지 않았다. `for v['a'].as_array().? |x|`가
  JSON 코드의 흔한 꼴이라 같이 고쳤다(`sema.zig` `.unwrap` · `.unwrap_res`에서 옮겨 온 결과를 `addressable = false`로).
- F-142(열림): `Int.parse`가 넘침을 검사하지 않는다. `json`은 음수로 누적하는 자체 `parse_int`를 쓴다.
- F-143(수정): wasm32에서 `str.is_utf8`이 포인터 칸의 위 32비트를 읽어 panic. `json.parse`가 입력 검사로 부르면서 드러났다.

## 남은 일

- `Value` → Cyber 타입 역변환(`json.to(T, v)` 또는 `json.decode(T, src)`).
- 큰 정수 · 고정밀 수의 무손실 경로(사양이 SHOULD로 권하는 옵션).
- core `@eq`의 choice 지원 여부.
