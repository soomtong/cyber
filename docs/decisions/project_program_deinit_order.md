# 프로그램 끝의 정리 순서: main 지역 다음 전역 (2026-11-08)

상태: 구현됨. 발견 이슈 F-29(06장 §7.1의 14 · 15번).

## 배경

`sema_program`은 main 문장을 다 분석한 뒤 `sema_program_deinit`(전역을 정리하는 `@program_deinit` 호출)을 먼저 내고, 그 다음 `popProc`이 main 지역의
파괴자를 냈다. 그래서 정상 종료에서 전역의 `@deinit`이 main 지역보다 먼저 돌았고(`global g Res` · `local := Res{...}`에서 `deinit global`이 먼저),
main 지역의 `@deinit`이 전역(로그 · 카운터 · 풀)을 읽으면 해제된 값을 읽었다. main 안의 `return`은 반대 순서였다(`semaReturn`이 `semaDestructBlock2` 뒤
`sema_program_deinit`). 함수 안의 지역은 함수가 끝날 때 정리되므로 영향이 없다.

## 결정

1. 정상 종료에서 main 블록의 지역을 선언 역순으로 먼저 정리하고 그 뒤 `@program_deinit`을 부른다. `return`과 같은 순서다.
   `sema_program`이 끝이 도달 가능하면 `semaDestructBlock`을 낸 뒤 `sema_program_deinit`을 내고, `popProc2(c, false)`로 블록을 닫아 중복 정리를 피한다.
2. `single_run`(ReleaseFast CLI, `main.zig`의 `config.single_run = builtin.mode == .fast`)과 `persist_main`(REPL)은 main 지역의 정리 코드를 내지 않는
   기존 규칙(`shouldGenMainScopeReleaseOps`) 그대로다. 그 경우 `@program_deinit`만 돌고 main 지역은 `VM.deinit`의 `freeHeapPages` 스윕이 해제한다.
   스윕은 `@deinit`을 부르지 않는다. 패닉 뒤의 스윕도 같다.

## 계약(문서화)

- 정상 종료: main 지역 `@deinit`(선언 역순) → 전역 `@deinit`. 함수 지역은 함수가 끝날 때.
- 패닉: 어떤 `@deinit`도 돌지 않는다. 힙 객체와 raw 버퍼는 스윕이 해제한다(메모리만). 파일 · 소켓 같은 외부 자원은 OS가 프로세스 종료 때 정리한다.
  매뉴얼의 "Deinitializers" 절에 적었다(이전 문장은 `Unwind` trait 미정(TBD)이었다).
- `single_run` 임베딩: main 최상위 지역의 `@deinit`이 돌지 않는다. `@deinit`에 의존하는 정리가 있으면 기본값 `false`를 쓴다. 릴리스 CLI는 ReleaseSafe라 해당 없음.

## 구현 메모

- `src/sema.zig` `sema_program`의 끝(main 함수 없는 경로) · `popProc2`.
- 테스트: behavior `memory/program_deinit_order.cy`(전역 `order`를 main 지역의 `@deinit`이 1로, 전역 `Log`의 `@deinit`이 1을 확인하고 2로. 순서가 바뀌면 panic).

## 남은 것

- 패닉 경로에서 `@deinit`을 돌리는 것(스택 언와인드 중 파괴자 호출). 지금은 언와인드가 스택 트레이스만 만든다.
- `single_run`에서도 `@deinit`만은 돌리는 선택지(정리 코드를 내되 해제 명령만 생략)는 검토하지 않았다.
