# 매뉴얼의 Planned 항목 정리

2026-11-24. C 백엔드를 지운 뒤(`project_direction.md`) `docs/docs.md`에 남은 옛 흔적과 `Planned Feature` 표시를 검토했다.
남길 계획과 뺄 계획은 사용자가 항목마다 골랐다.

## 검토 방법

- `docs/docs.md`에서 `Planned`, `not available yet`, `is planned`, `not implemented`, `will be supported`를 모두 찾았다.
- 표시가 붙은 기능이 실제로 구현됐는지 파서 · sema · 테스트(`src/test`)에서 확인했다. 표시가 붙은 기능 중 이미 구현된 것은 없었다.
  남아 있던 흔적은 C 백엔드를 말하는 문장이었다(소개의 "Compilation ahead-of-time to C", `extern`의 "static or runtime binding").
- 각 항목은 fork의 용도(스크립트 CLI, 에이전트 루프 임베딩)와 정체성(세 번째 단계 언어, `docs/study/11-design-principles-review.md` 2절)으로 따졌다.

## 결정 (사용자, 2026-11-24)

남기는 계획(매뉴얼에 `Planned Feature`로 남는다):

| 항목 | 매뉴얼 절 | 이유 |
| --- | --- | --- |
| Optional chaining `a?.b?.c` | Optionals | JSON 같은 중첩 데이터를 다루는 스크립트에 필요하다. 이번 질문 목록에 넣지 않아 그대로 둔다 |
| Named parameters · arguments | Functions | 인자가 많은 호출의 가독성. `docs/study/09` 로드맵 5단계 |
| `error` set 타입 | Error handling | 0.5의 표준 오류 어휘(설계 원칙 1.7 A)와 이어진다 |
| 더 많은 `Sendable` 타입 | Concurrency | `[]T` · `Array` · `Map` · 구조체 · choice를 `spawn`으로 보내는 것은 실용성이 크다 |
| Destructure import | Modules | 꼴을 `use { cos, pi } from 'math'`로 바꿔서 남긴다(전의 꼴은 `use { cos, pi } 'math'`) |

빼는 계획(매뉴얼에서 지우거나, 대신 쓸 방법만 남긴다):

| 항목 | 대신 쓰는 것 |
| --- | --- |
| `fmt`의 이름 있는 자리표시자 | 문자열 보간 `'%{name}'` |
| Line-join 리터럴 | `'''` · `"""` · 백틱 세 개의 여러 줄 리터럴 |
| 가변 문자열 `Str` | `str` 연산과 슬라이스 |
| `?else` 블록의 `break 값` | 식 꼴 `opt ?else 'empty'` |
| `+..` 슬라이스 | `arr[2..4]` |
| No parameter calls · Shorthand calls(내용 없는 절) | 없음 |
| `defer` | `@deinit`(값의 수명에 묶인 정리)과 `scope` 블록 |
| 반환값 구조 분해 `{x, y} := f()` | struct를 돌려주고 필드로 읽는다. 여러 값 반환은 이미 그렇게 안내하는 파싱 오류다 |
| 타입 템플릿을 제네릭 타입으로(`fn size(c MyContainer)`) | infer 파라미터 `c MyContainer[%T]` |
| 내장 `clone(a)`와 `@clone` 재정의 | 타입마다의 `clone` 메서드(`Array.clone`) |
| Weak reference | 부모의 인덱스나 키를 들거나 부모를 인자로 넘긴다. 순환은 버그로 본다 |
| `@check_cycles` 수동 호출 | 스레드 끝의 순환 탐지 |
| 할당마다 고르는 allocator | 기본 allocator(`mimalloc`) |
| `error` payload | 실패의 내용을 담은 struct · choice를 돌려주거나 호출자가 넘긴 `Diag`를 채운다(`json.Diag` 등) |
| Future chain `then_spawn` | future를 await하고 이어 가는 fiber |
| 스레드 사이 공유 메모리 · 채널 | `spawn`의 인자와 결과로 주고받는다 |
| 타입이 다른 future를 기다리는 `await` | 한 타입의 `Future.wait_any` |
| 스레드 상태 조회 | `await`가 결과와 panic을 받는다 |
| 언어 차원의 SIMD 벡터 타입 | 없음(런타임은 안에서 SIMD를 쓴다) |
| Sandbox 모드(전역 · 수동 메모리를 막는 언어 모드) | 호스트의 임베딩 옵션: `deny_raw_ptrs`, 모듈 허용 목록, 메모리 · 스택 상한, fuel · interrupt |
| `os.open_lib` | `#c.bind_lib(path)` 런타임 바인딩 |

## 바꾼 것

- `docs/docs.md`: 위 표대로 절과 문장을 지우거나 고쳤다. 소개의 백엔드 문장은 바이트코드 VM과 임베딩 제어로, `Incomplete`
  표시 안내는 `Planned`만으로 고쳤다(`Incomplete` 표시는 문서에 없었다). Weak references 절은 Back references 절로 바꾸고
  순환을 피하는 방법만 남겼다. Cloning 절은 `clone` 메서드로, `fn size(c MyContainer)` 예는 `MyContainer[%T]`로 바꿨다.
  Planned concurrency features 절은 남긴 계획 하나와 계획하지 않는 것의 대안 목록이 됐다.
- `os.open_lib`: 선언(`src/std/os.cy`의 `type DynLib`과 `open_lib`)과 바인딩(`src/std/os.zig`의 `openLib`)을 지웠다.
  호출하면 'TODO' panic이었다. `docs/api.json`에서도 뺐다.
- C 백엔드 흔적: `MEMORY.md`, `project_direction.md` 첫 줄, `project_coroutines.md`의 "AOT 미지원 · 남은 것", `docs/study`의
  해당 줄에 삭제 사실을 덧붙였다. `docs/study`는 당시 커밋의 기록이라 본문은 고치지 않고 덧붙이기만 했다.
  `docs/history`, `docs/specs`, `docs/releases`의 지난 기록은 그대로 둔다.

## 남긴 것 · 알아 둘 것

- `src/std/os_ffi.zig`는 어디에서도 import하지 않는 파일이다(`os.zig`의 import가 주석). `ffiBindLib`이 옛 `open_lib`의 구현
  후보였다. 지우는 것은 따로 정한다.
- `sema_expr.hook_names`에 `@clone`이 있지만 컴파일러가 부르는 곳은 없다. 스크립트가 `@clone`을 선언할 수 있게 하는 이름일
  뿐이라 이번에는 두었다.
- 남긴 계획 중 destructure import는 꼴이 바뀌었으므로 구현할 때 `from`을 문맥 키워드로 둘지 예약어로 둘지 정해야 한다.
  `json.from` 함수와 `regex.cy`의 지역 변수 `from`이 있어 예약어로 하면 둘을 고쳐야 한다.
- destructure import의 중괄호는 안쪽을 띄운다(`use { cos, pi } from 'math'`, 2026-11-24 사용자 결정). 포매터의 "중괄호 안쪽은
  붙인다"에 대한 유일한 예외이고, 구현할 때 `cyber fmt`가 함께 따라야 한다. `project_fmt_brace_style.md` 결정 절.
