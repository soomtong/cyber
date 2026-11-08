# VM 스택 상한과 `Stack overflow.` panic (2026-11-08)

상태: 구현됨(`f03cf24c`). 발견 이슈 F-40.

## 배경

VM 스택은 `CHK_STK`(함수 진입) 또는 `GEN_NEXT` · `GEN_END`(제너레이터 재개)가 `RES_STACK_OVERFLOW`를 돌려주면
`Thread.growStackAuto`가 1.5배로 키웠다. 상한이 없어 폭주 재귀는 할당이 실패할 때까지 자랐고(1초에 RSS 4.5GB,
05장 실습 5), 할당 실패 뒤의 동작은 정의되지 않았다. fuel(`project_vm_interrupt.md`)은 호출 수로 끊을 수는 있지만
"메모리를 얼마나 쓰느냐"와는 다른 축이고, 기본값이 무제한이다. 에이전트 루프에서 스크립트 하나가 호스트 메모리를
소진하는 경로를 막아야 한다.

## 결정

1. 스레드마다 `stack_limit`(슬롯 수)을 두고 `growStackAuto`가 그 이상으로 키우지 않는다. 기본값은 16Mi 슬롯 = 128 MiB
   (`thread.default_stack_limit`). 16슬롯 프레임 100만 개 깊이가 들어가는 크기라 정상적인 깊은 재귀는 영향이 없고,
   폭주 재귀는 0.2초 안에 멈춘다(f(n+1) 재귀 약 210만 프레임, peak RSS 약 400 MB: 성장 복사와 compact trace 포함).
2. 상한에 닿은 성장 요청은 `Stack overflow. The stack limit is N bytes.` panic이다. eval은 `CL_ERROR_PANIC`을 돌려주고
   VM은 계속 쓸 수 있다. 다른 panic과 같이 언와인드하며 힙 스윕이 버려진 프레임의 값을 모두 해제한다(누수 검사
   allocator로 확인).
3. 호스트 API `cl_vm_set_stack_limit(vm, bytes)`. 8바이트 슬롯으로 내림, 0 이하는 무제한. `cl_vm_set_fuel`과 같은 자리
   (main 스레드에 저장, `spawn`으로 만든 스레드가 `new_thread`에서 복사).
4. 긴 panic 트레이스는 양 끝 20프레임만 남기고 중간을 `... N frames omitted ...` 한 줄로 줄인다(`debug.allocStackTraceCapped`,
   `max_trace_frames` 40). 스택 상한 panic은 수백만 프레임이라 전체 출력이 무의미했다. 다른 panic도 40프레임을 넘으면 같이 줄어든다.

## 구현 메모

- `vm.h` `Thread`에 `size_t stack_limit`(`stack_end` 뒤)과 `thread.zig` `ThreadC` 미러에 같은 자리. `ZThread` 패딩은
  `Thread.c` 앞에 있어 바뀌지 않는다("thread internals." 테스트가 오프셋을 비교).
- `growStackAuto(handle_panic)`: `stack_len >= stack_limit`면 `stack_overflow`, 아니면 `min(len*1.5, limit)`로 키운다.
  상한까지 키웠는데 프레임이 안 들어가면 다음 `CHK_STK`가 다시 `RES_STACK_OVERFLOW`를 내고 그때 panic이 된다.
- `stack_overflow`: `CHK_STK`에서 멈춘 경우 callee 프레임에는 아직 디버그 심볼이 있는 명령이 없다(`chk_stk`는
  `pushOptionalDebugSym`, trace 빌드에만 심볼). 그래서 `FrameInfo.prev_context()`로 pc · fp를 호출 지점(caller의 `call`
  명령, failable 심볼 있음)으로 옮긴 뒤 `ret_panic` + `handleInterrupt`. 트레이스의 맨 위 프레임은 재귀 호출 줄이다.
  `GEN_NEXT` · `GEN_END`는 caller의 failable 명령이라 그대로 둔다. `CHK_STK`가 fp를 ret 슬롯만큼 내려 둔 상태는
  `getFrame`이 기대하는 모양(`fp + ret_size = 프레임 base`)이라 되돌리지 않는다.
- 한계를 넘는지 보는 곳은 `growStackAuto` 하나다. 호스트가 `stackEnsureTotalCapacity`로 직접 키우는 경로(main 프레임
  크기 · 호스트 호출)는 상한을 보지 않는다. 재귀로만 커지는 것이 문제였고, 그 경로는 모두 `growStackAuto`를 지난다.

## 검증

- lib-test `cl_vm_set_stack_limit turns runaway recursion into a panic.`: 1 MiB 상한에서 `f(n+1)` 재귀가
  `panic: Stack overflow. The stack limit is 1048576 bytes.`, 트레이스에 `frames omitted`와 `main:` 프레임, `str` 인자 재귀도
  누수 없이 panic, 깊이 1000은 정상, 깊이 200000은 panic → 상한 0(무제한)으로 바꾸면 정상.
- CLI: `fn f(n int) -> int: return f(n + 1) + 1`이 0.17초에 panic, `... 2097111 frames omitted ...`, exit 1.

## 남은 것

- CLI 옵션(`cyber --stack-limit`)은 없다. 필요하면 fuel 옵션과 함께 넣는다.
- 힙 메모리 한도(F-41, C 호스트용 할당자 훅)는 별개다. 스택 상한은 재귀만 막는다.
- `docs/docs.md`에는 임베딩 API 절이 없어 적지 않았다. `src/include/cyber.h` 주석과 이 문서가 기준.
