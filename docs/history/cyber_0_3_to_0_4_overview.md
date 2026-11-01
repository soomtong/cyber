# Cyber 0.3 → 0.4 재설계 개요

2026-11-01 작성. upstream(fubark/cyber)의 0.3 릴리스(2023-12-10)에서 이 fork의 0.4.2 릴리스(2026-10-31)까지 언어 설계가
어떻게 바뀌었는지를 구간과 주제로 정리한 문서다. 각 주제의 자세한 내용은 같은 폴더의 주제 문서에 있다.

이 폴더(`docs/history`)는 이미 일어난 변화를 기록한다. 착수 설계는 `docs/specs`, fork의 결정은 `docs/decisions`에 둔다.
주제 문서의 "미완 지점"과 "fork의 결정 · 미결" 절이 다음 작업의 출발점이다.

## 한 줄 요약

0.3은 동적 타입이 기본이고 ARC와 fiber · throw/catch를 쓰는 스크립트 언어였다. 0.4는 정적 타입이 기본이고 값 소유권 ·
빌림 · Result 타입 · 제너레이터 · 스레드를 쓰는 언어다. 이 전환은 upstream이 2024년과 2025년 두 차례에 걸쳐 했고,
끝나지 않은 상태에서 2025-12 이후 멈췄다. fork는 그 상태를 0.4.1로 처음 정식 릴리스하고 빈 부분을 직접 채우기 시작했다.

## 세 구간

| 구간 | 기간 | 범위 | 커밋 수 | 성격 |
|---|---|---|---|---|
| A. upstream 재설계 1차 | 2024-01 ~ 2024-09 | `13a7bef2`(0.3) .. `c992b94e` | 약 460 | 동적 타입 중심에서 정적 타입 중심으로 |
| B. upstream 재설계 2차 | 2025-10 ~ 2025-12 | `81bce037` .. `c853fcc2` | 약 60 | 소유권 · 코루틴 · 에러 · 임베딩 ABI 재설계 |
| C. fork | 2026-10 ~ | `d64bcde5` .. | 약 90 | Zig 0.17, 릴리스, 임베딩 검토, 메모리 수정 |

- A와 B 사이(2024-10 ~ 2025-09)는 외부 기여 몇 개를 빼면 비어 있다. upstream은 2024-11-24에 master를 `v0.4-DEV`
  prerelease로 올렸고 정식 0.4는 내지 않았다.
- B의 핵심은 커밋 `b751ca6c`(2025-11-21, 메시지 "[all] some updates") 하나다. 444개 파일, +65,789 / −46,061 줄이며
  이유를 적은 설명이 없다. 그 뒤 한 달은 플랫폼 수정(Linux · macOS · Windows · WASM) · libcyber 분리 · 스텐실 JIT이다.
- C는 upstream 마지막 커밋 `c853fcc2`(2025-12-21) 위에 쌓였다. 0.4.1(2026-10-29) · 0.4.2(2026-10-31) 태그가 fork의
  첫 정식 0.4 릴리스다. 버전 번호의 뜻은 "upstream의 v0.4-DEV 계열을 릴리스 가능한 상태로 만든 것"이다.

## 구간 A의 기준 커밋

커밋 제목만으로 읽히는 전환이다. 날짜순.

| 날짜 | 커밋 | 내용 |
|---|---|---|
| 2024-01-12 | `843471f5` | `type X object`에서 `object` 제거 |
| 2024-01-19 | `0a57ae4f` | C 백엔드 착수 |
| 2024-01-29 | `9d4eb7e2` | choice 타입(tagged union) |
| 2024-02-11 | `0c1132cd` `516156af` `233f7c48` | 값 타입(struct), Option 타입, 템플릿 기반 제네릭 |
| 2024-03-08 | `427755b0` `439863b3` | `none` 값 제거 · `void` 타입, 에러 처리 단순화 |
| 2024-03-24 | `4c4c1ac5` | `my` → `let` |
| 2024-04-07 | `3d24d2ce` | `import` → `use` |
| 2024-04-12 | `1ad836ce` | CLI REPL |
| 2024-05-13 | `f2db5f04` `519f7039` | Zig 0.12 · 옛 VM 삭제, 함수 템플릿 |
| 2024-05-23 | `16cfe032` | `await` · `Future` · `FutureResolver` |
| 2024-07-10 | `946ed790` `94bade94` `8500ea15` | 포인터 타입, 64비트 unboxed `int`, zero-cost 예외 |
| 2024-08-25 | `d40d97fd` `6c29fa5a` | 반환 타입 기본 `void`, 함수 포인터 · 함수 union 타입 |
| 2024-08-27 | `2a224217` | `let` → `dyn` |
| 2024-09-09 | `103b8ddb` | 문자열 interpolation 제거(뒤에 `%{}` 형태로 복귀) |
| 2024-09-20 | `35e84dd9` | 참조 타입을 값 타입에서 유도, object 타입 제거 |
| 2024-09-21 | `9a06dfc2` `0c5ddea5` | CYON 제거, unboxed enum |
| 2024-09-22 | `9bb9a495` | `string` 이름 정리 |
| 2024-09-23 | `84df10db` `e80054e9` `c992b94e` | `fn` · `Fn`, 동적 메서드 디스패치 제거, 동적 오버로드 호출 제거 |

## 구간 B의 기준 커밋

| 날짜 | 커밋 | 내용 |
|---|---|---|
| 2025-10-07 | `81bce037` | Zig 0.14 |
| 2025-11-21 | `b751ca6c` | 재설계 본체. 아래 "키워드로 보는 변화" 참고 |
| 2025-11-27 | `e1ac563d` | libcyber와 CLI 앱 분리 |
| 2025-12-03 | `830addae` | Windows Win32 바인딩(외부 기여) |
| 2025-12-09 | `435813c1` | libcyber 빌드에서 FFI 기본 꺼짐 |
| 2025-12-11 | `99baa594` | WASM · WASI, 내장 훅 방식, const eval 제한 시작 |
| 2025-12-12 | `e4804c08` | `$` 실험 제거, `self`만 허용 |
| 2025-12-13 ~ 19 | `53e37ed6` `a9e03404` | 명령어 2바이트, 스텐실 JIT를 바이트코드에서 직접 생성, x64 |
| 2025-12-21 | `c853fcc2` | upstream 마지막 커밋 |

## 키워드로 보는 변화

`src/tokenizer.zig`의 키워드 표를 `c992b94e`(B 직전)와 HEAD에서 비교한 결과다. 0.3의 토크나이저는 파일 구조가 달라
같은 방식으로 비교하지 못했다.

- 사라진 키워드: `await` `catch` `coinit` `context` `coresume` `coyield` `def` `dyn` `mod` `symbol` `throw`
- 생긴 키워드: `begin` `const` `cunion` `fnsym` `global` `move` `scope` `sink` `undef` `yield`
- 남은 키워드: `and` `as` `break` `case` `continue` `cstruct` `else` `enum` `error` `false` `for` `fn` `if` `none`
  `not` `or` `pass` `return` `struct` `switch` `trait` `true` `try` `type` `use` `var` `void` `while` `with`

사라진 쪽은 동적 타입(`dyn`), 예외(`throw` · `catch`), stackful 코루틴(`coinit` · `coresume` · `coyield`), `await`
키워드다. 생긴 쪽은 소유권(`move` · `sink` · `scope`), 제너레이터(`yield`), 선언 종류(`const` · `global`)다.
현재 문서는 일반 키워드 23개로 정리한다(`docs/docs.md`의 "Reserved identifiers.").

## 문서 구조로 보는 변화

| 시점 | 문서 형태 | 특징 |
|---|---|---|
| 0.3 | Hugo 분할 파일 `docs/hugo/content/docs/toc/*.md` | "Type System" 장이 Dynamic typing과 Static typing으로 나뉨. Embedding 장은 `cs*` API |
| `c992b94e` | 단일 `docs/docs.md`(4,426줄) | "Dynamic Typing" 장이 남아 있고 "Memory" 장에 Structured memory가 1.0 이후로 미뤄진 계획으로 적힘 |
| HEAD | 단일 `docs/docs.md`(3,984줄) | "Dynamic Typing" 장 삭제. "Memory" 장이 Structured memory를 기본으로 설명. `TBD` · `Incomplete` · `Planned` 표시 40곳 |

## 주제 문서

fork의 용도(`docs/decisions/project_direction.md`)에 직접 닿는 다섯 주제를 먼저 썼다.

- `type_system.md` — 동적 · 정적 혼합에서 정적 전용으로. `dyn` · `any` · Table 제거, struct · choice · Option · 템플릿 · trait · `Dyn[T]`.
- `ownership_memory.md` — ARC 단일 모델에서 값 소유권 · 빌림 · `^T` ARC 혼합 모델로. `move` · `scope` · `sink` · `@deinit` · `@copy`.
- `coroutines_concurrency.md` — stackful fiber와 `await` 키워드에서 stackless 제너레이터 · Thread · Future 메서드로.
- `error_handling.md` — throw/catch 예외에서 `!T` Result 값과 `!` · `!else` 연산자로.
- `embedding_cli.md` — `cs*` 동적 값 API에서 `cl_*` 정적 스택 ABI와 `#[bind]`로. REPL · JIT · C 백엔드 · fork의 릴리스.

쓰지 않은 주제: 모듈 시스템(`import` → `use`, `$global`), 메타프로그래밍(`#if` · `#for` 인라인 평가, `EvalInt` · `EvalStr`),
문법 일반(`:=` 선언, `[]` 템플릿 인자, `%{}` interpolation), 런타임 · 백엔드(unboxed 값, 2바이트 명령어, 스텐실 JIT).
필요해지면 같은 틀로 추가한다.

## 미완 지점과 우선순위

현재 `docs/docs.md`의 `TBD` · `Incomplete` · `Planned` 표시 40곳과 fork가 작업 중 찾은 항목을 용도 순서로 묶었다.
자세한 근거는 각 주제 문서에 있다.

1순위 — 스크립트 CLI로 쓰는 데 걸리는 것
- REPL 지역 변수 이월은 2026-11-01 `e541090a`로 해결됐다(심볼 재선언 허용 포함). 남은 것은 문서 반영.
- Unwrap block(`try:` … `else |err|:`)과 Unwrap or guard가 TBD. 여러 `!` 호출을 한 블록으로 묶는 관용구가 없다.
- `error` payload · `error` set 타입 TBD. 지금은 `error.Name` 심볼만 있다.
- Slice 크기 축소 연산 뒤 원래 슬라이스를 읽으면 해제된 칸이 보임(`docs/decisions/project_slice_append_aliasing.md`).
- 문서 비어 있음: Attributes(`#[...]` 목록), Named parameters, Destructure import, Mutable strings, Line-join literal.

2순위 — 임베딩 · 에이전트 루프에 걸리는 것
- 외부 중단은 2026-11-01 `f21993e2`로 `cl_vm_interrupt`(다른 스레드에서 호출, 다음 체크포인트에서 중단) · `cl_vm_set_fuel`(체크포인트 수 상한)이
  들어왔다. 남은 것은 spawn된 스레드로의 전파와 메모리 상한.
- 스택형 `Fiber`가 문서만 있고 미구현. 제너레이터 reset도 TBD(`project_coroutines.md`).
- libcyber 타입 바인딩 예제 TODO. 신뢰하지 않는 스크립트용으로 로더에서 `c` 모듈을 거르는 옵션 검토. 문서의 sandbox mode는 소스에 플래그가 없다.
- 패닉한 자식 스레드 상태 조회 TBD. Channels · Shared memory · `await` union · OS threads TBD.
- `single_run` 종료 스윕이 소멸자를 건너뜀. 종료 시 돌아야 하는 정리 코드가 생기면 계약을 다시 본다.

3순위 — 지금 용도에 필요하지 않은 것
- Weak references, Cloning(`clone`), Manual memory · Memory allocations, `Unwind` trait, `@check_cycles`.
- SIMD, Gas mileage, `Future.then_spawn`, 람다 `spawn`, Generic types의 TBD 2곳.
- JIT(불안정) · C 백엔드(진행 중). fork 방침상 네이티브 산출물은 범위 밖이다.

## 작성 방법

- 세 시점의 문서 절 제목 diff(`git show 0.3:docs/hugo/...`, `git show c992b94e:docs/docs.md`, HEAD), 토크나이저 키워드 표 diff,
  `src/test` 하위 테스트 파일 존재 여부를 근거로 삼았다.
- upstream 커밋에는 이유가 거의 없다. 이유는 "해석" 절에 따로 적고 사실과 섞지 않았다.
- 문서에 있지만 소스에 없는 기능은 "문서만 있음"으로 표시했다. 예: `type Fiber`, `clone`, `stack_trace`, `@check_cycles`, `Sendable`, `Channel`.
