# 스택 이동 때의 스택 포인터 패치 구멍 (2026-11-08, F-10)

## 배경

VM 스택은 `Value[]` 하나이고 `growStackAuto`가 1.5배로 재할당한다. `alloc.resize`가 제자리에서 실패하면 새 배열로 복사하므로,
슬롯 안의 "스택 안을 가리키는 포인터"(`&x` 빌림, `[&]T` 등 `is_stack_ptr()` 타입)는 새 주소로 고쳐 써야 한다. bc_gen은 호출 지점마다
현재 proc의 포인터 레지스터 비트집합(`ptr_layouts`)을 `ptr_table`에 남기고(`push_site_ptr_layout`), `growStackPrecise`는 프레임을
거슬러 올라가며 각 프레임의 호출 지점 pc로 레이아웃을 찾아 `patch_frame_ptrs`로 고친다. 두 군데가 빠져 있었다(발견 이슈 F-10).

- 걷기 루프가 `while (frame.frame_type() != .init)`이라 main 프레임(fp 0)에 닿으면 패치 없이 끝났다. main의 `p := &x`가 깊은 호출 뒤
  해제된 옛 스택을 읽었다(`0xAAAAAAAAAAAAAAAA`).
- `ptr_table` 항목은 `pushCall`(`call` · `call_host`)과 `gen_next` · `gen_end`(`a2236c78`)만 올렸다. `call_ptr` · `call_union` ·
  `call_trait`로 부른 호출이 스택을 키우면 호출자 프레임의 포인터(빌림 매개변수 포함)가 그대로였다.

## 결정

`c94f1569`.

- `growStackPrecise`의 루프를 `while (true)`로 바꾸고 레이아웃 패치를 먼저 한 뒤 `.init`이면 끝낸다. pc가 null인 프레임(호스트에서
  들어온 경우)은 레이아웃 조회를 건너뛴다.
- `gen_call_ptr` · `gen_call_union` · `gen_call_trait`가 명령을 낸 pc로 `push_site_ptr_layout`을 부른다. 레이아웃은 `reserve_reg`가
  잡은 모든 레지스터(인자 임시 포함)를 덮으므로 `f(&x)`처럼 인자로 넘긴 빌림도 호출자 레이아웃에서 고쳐진다.
- extern 함수 포인터 호출(`genCallExternPtr`, `call_host`)은 C 코드라 VM 스택을 키우지 않으므로 그대로 둔다. 호스트 함수가 VM을
  재진입하는 경로는 이 fork에 없다.

## 검증

- behavior 테스트 `functions/stack_grow_ptr_patch.cy`: main 프레임 `&x` + `rec(20000)`, 매 단계로 넘긴 `&int`를 바닥에서 읽기,
  `Func[Fn1]`(`call_union`) · `Fn1`(`call_ptr`) · `&Dyn[Trait]`(`call_trait`) 경유 깊은 호출 뒤 `p.*`. 수정 전 CLI 재현은
  main `-6148914691236517206`, 세 간접 호출 모두 `-6148914691236497205`(기대 20043), 인자 전달은 원래 정상(20042).
- 재할당이 제자리 확장으로 끝나면 이동이 없어 구멍이 드러나지 않는다. 테스트는 macOS · Linux에서 20000 프레임이 이동을 일으키는
  것에 기댄다(04장 §7.1과 같은 크기).

## 남은 것

- 호스트 함수 안에서 VM을 다시 부르는 경로가 생기면 `.host` 프레임의 pc가 null이라 그 아래 프레임의 레이아웃 조회가 빠진다.
  그때 `FrameInfo.prev_context`에 호출 지점 pc를 남기는 방식을 정해야 한다.
