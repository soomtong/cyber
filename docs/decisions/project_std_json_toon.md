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
  외부 태그 꼴(`"case"`, `{"case": payload}`)이다. 반대 방향은 아래 "`Value` → 타입 역변환".
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
- F-142(수정): `Int.parse`가 넘침을 검사하지 않았다. 이제 `json.parse_int`와 같이 음수로 누적하며 `error.Overflow`를 돌려준다.
- F-143(수정): wasm32에서 `str.is_utf8`이 포인터 칸의 위 32비트를 읽어 panic. `json.parse`가 입력 검사로 부르면서 드러났다.

## `Value` → 타입 역변환 (2026-11-15)

`json.to(T, v)` · `json.to(T, v, &diag)`, `json.decode(T, src)` · `json.decode(T, src, &diag)`. serde `Deserialize`의 기본 동작을 따랐다.

- 받는 타입은 `from`과 같다(`Array` · 고정 길이 배열 제외). struct 필드는 있어야 하고(옵션 필드만 없으면 `none`), 필드가 아닌 멤버는
  무시한다(serde 기본, `deny_unknown_fields` 없음). 필드 기본값(`x int = 3`)은 메타로 읽을 수 없어 쓰지 않는다.
- 수: 정수 타입은 정수 `float`(`3e2`)도 받는다(serde는 거부). 에이전트가 쓴 JSON에 흔하고, 우리 `stringify`가 `1.0`을 `1`로 쓰는
  것과 짝이다. 범위 밖은 `error.Overflow`(`int.parse`와 같은 이름). 실수 타입은 정수도 받는다.
- 오류: `error.Type`(다른 종류 · 모르는 case 이름), `error.MissingField`, `error.Overflow`. `Diag`에 `path` 필드를 더해 `$.users[1].id`
  꼴로 적는다. 경로는 성공 경로에서 만들지 않고 실패가 올라오면서 앞에 붙인다. 식별자 꼴이 아닌 키는 `["a b"]`.
- struct는 `var res T = undef`에 필드를 하나씩 `@ptr_init`한다. 중간에 실패하면 실패한 필드부터 끝까지 0 값(`zero(T)`, 받는 타입마다
  정의)으로 채워 `res`를 온전하게 만든 뒤 보통처럼 해제한다. `meta.consume`로 버리는 길은 하위 블록에서 쓸 수 없어(옮김과 같은 규칙,
  `else` 갈래의 consume이 뒤까지 죽은 상태로 남음) 택하지 않았다.
- 같이 고친 컴파일러 제약: `!else`(식 · 블록 꼴)가 호출이 돌려준 결과에서도 페이로드를 복사해 `!Map[...]` 같은 `NoCopy` 결과를 쓸 수
  없었다(`!`는 옮김). 이제 소유한 결과면 옮긴다(`sema.zig` `semaMoveOrCopyResultPayload`). `meta.access(T, name)`의 `T`가 `%T type`
  템플릿 인자면 `Unsupported expansion of compile-time value of type: type`였다. 이제 타입 심볼로 찾는다(`semaAccessExpr3`).
- 아직 컴파일 타임 `#for x |v|`(EvalBuffer 반복)는 `#case` 바로 아래 문장으로 못 쓴다(`for_iter_stmt`). `#for 0..n |i|`로 돈다.

## 큰 수 · 고정밀 수 (검토, 사용자 결정 대기)

지금: 소수부 · 지수 없는 수가 `int`에 맞으면 `int`, 나머지는 `float`(가장 가까운 값). 그래서 `9223372036854775808`은
`9223372036854776000`, `12345678901234567890123`은 `1.2345678901234568e+22`, 17자리를 넘는 소수는 잘린다. 오류 없이 값이 바뀐다.
읽고 다시 쓰면 원문과 다르다(TOON 인코드도 같다).

다른 구현:
- Go `encoding/json`: `Decoder.UseNumber()`면 수를 `json.Number`(원문 문자열 타입)로 두고 `Int64()` · `Float64()`로 바꾼다. 기본은 `float64`.
- Rust `serde_json`: 기본은 `u64` · `i64` · `f64`. `arbitrary_precision` 기능을 켜면 `Number`가 원문 문자열을 들고 직렬화도 원문 그대로.
- Zig `std.json`: `Value.number_string`. `int`에 안 맞는 정수와 `parse_numbers = false`일 때의 모든 수를 원문으로 둔다.
- Python `json`: `parse_int` · `parse_float` 훅(`decimal.Decimal`). 기본 `int`는 임의 정밀도라 정수는 손실이 없다.
- JavaScript `JSON.parse`: 모두 `number`(손실). TOON 참조 구현도 이것을 따른다.

안:
- 안 1: 그대로 두고 문서에 손실을 적는다. 비용 없음. 거래 ID · 해시 같은 큰 정수를 다루는 에이전트 코드가 조용히 틀린다.
- 안 2(추천): `Value`에 `case number str`(원문 10진 텍스트)을 더한다. 파서는 `int`에 안 맞는 정수를 항상 `number`로 두고(손실 대신
  보존, Zig와 같음), `ParseOptions{exact=true}`면 소수 · 지수가 있는 수도 원문으로 둔다(Go `UseNumber`). `stringify`는 원문을 쓰고,
  TOON 인코더는 §2 정규형으로 바꿔 쓴다(지수 풀기 · 뒤 0 제거, 문자열 연산). `as_float`는 변환, `as_int`는 `none`, `eq`는 정규형 비교,
  `json.to`는 `float`으로 근사하거나 `str` 필드로 원문을 받는다. 큰 정수 타입이 std에 없으므로 원문 문자열이 유일한 무손실 출구다.
- 안 3: 모든 수를 원문으로(serde `arbitrary_precision`). 가장 정확하지만 `as_int` · 산술마다 파싱이 들어 느리고 쓰기 번거롭다.

시점: `json`은 아직 릴리스 전(0.4.12에 처음 나감)이라 `Value`에 case를 더해도 호환성 문제가 없다. 릴리스 뒤에 더하면 `Value`를
빠짐없이 `switch`하는 사용자 코드가 깨진다. 안 2를 하려면 0.4.12 전에 하는 것이 맞다.

## 남은 일

- 큰 수: 위 안 중 결정.
- core `@eq`의 choice 지원 여부.
