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

## wasm32의 4바이트 포인터 (2026-11-16, F-156)

- wasm32는 값 칸이 8바이트, 포인터가 4바이트라 구조체가 4바이트 필드 둘을 한 칸에 담는다(`Two{a &int, b &int}`는 8바이트,
  `[3]&int`는 12바이트). 표시가 "포인터 필드는 8바이트 정렬"을 가정해 오프셋 4의 포인터를 놓쳤고, 보정은 칸 전체를 덮어 같은 칸의
  다른 필드를 지웠다.
- `PtrSlot`의 남는 비트를 `ptr_hi`로 썼다: `ptr`은 칸 전체(64비트) 또는 아래 4바이트, `ptr_hi`는 위 4바이트. 개수 세기
  (`gen_pop_locals` 등)는 `PtrSlot.any()`로 칸 단위로 센다. `mark_stack_ptr_bytes`는 바이트 오프셋을 따라가고 포인터 크기
  (`@sizeOf(usize)`, 바이트 코드는 컴파일한 곳에서 돈다) 정렬로 판정한다. 태그가 있는 옵션 · result · choice는 태그가 8바이트라
  늘 칸 경계에서 시작한다. 4바이트 원소 벡터는 둘째 원소가 0을 세므로 원소를 다 본다.
- 보정은 32비트에서 해당 절반만 바꾸고 나머지 절반은 그대로 둔다(다른 필드이거나 쓰레기).
- 검증: native는 포인터가 8바이트라 변화가 없다. 수정 전 wasm은 `functions/packed_borrow_stack_grow.cy`에서 `Expected 78, found 120`,
  `concurrency/scope_block_borrow_cancel.cy`에서 trap.

## wasm32에서 절반마다 다른 case (2026-11-16, F-159)

- 칸의 아래 절반이 한 case의 포인터, 위 절반이 다른 case의 포인터일 수 있다(`case one &int`, `case mix Mix{n i32, p Ptr[int]}`).
  조건을 칸 단위로 합치면 `mix`에서 `n`이 보정된다. `PtrSlot`은 조건 한 벌(검사 둘)뿐이라 절반별 조건을 못 담았다.
- `PtrSlot.split`(`back0`에서 1비트를 가져옴, `max_back`은 14비트): `back0`의 태그 하나만 보고 아래 절반은 `tags0`, 위 절반은
  `tags1`의 case에서 포인터다. 둘째 조건(`back1`)은 버린다(더 많은 경우에 보정하는 쪽, 값의 범위 검사는 그대로).
- `merge_ptr_slots`: 표시한 절반이 같으면 전과 같다(64비트는 늘 이쪽). 절반이 다르고 조건이 같으면 한 구조체의 두 필드라
  표시만 합친다. 조건이 다르면 `split`. 같은 태그 아래가 아니면 조건 없이 합친다(전과 같은 대체 경로).
- 검증: wasm CLI(`zig build cli -Dtarget=wasm32-wasi`, `wasmtime run --dir=.::/ --dir=<repo>/zig-out/bin::/zig-out/bin`)로 탐침을 돌렸다.

## 취소 패드 (2026-11-16, F-158)

- 취소된 fiber의 패드는 위 프레임부터 돈다. 패드가 부른 `@deinit`이 스택을 옮기면 자기 패드를 기다리는 아래 프레임도 보정돼야
  한다(그 패드의 `@deinit`이 빌림을 읽는다). 두 곳이 빠져 있었다.
  - `unwindFiber`가 반환 주소를 패드 시작으로 바꾼 프레임은 `ptr_table`에 없는 pc로 찾아졌다. 패드 시작 pc에 지점의 레이아웃을
    기록한다(`gen_cancel_pads`의 `push_site_ptr_layout(c, pad_pc)`). 멈춘 fiber의 맨 위 프레임(`Fiber.pc`가 패드 시작)도 같다.
  - 패드 안 호출 지점은 `num_ptr_locals = 0`에서 시작해 임시 레지스터가 포인터일 때만, 그것도 몸체 끝에 남은 builder 내용으로
    기록됐다. `CancelSite`가 지점의 builder와 `num_ptr_locals`를 복사해 두고 패드 생성 전에 되살린다.
- 패드를 같이 쓰는 조건(`cancel_sites_share_pad`)에 레이아웃이 같을 것을 더했다. 패드 시작의 레이아웃이 하나여야 한다.
- 검증: 수정 전 ReleaseSafe는 `concurrency/fiber_cancel_stack_grow.cy`에서 `0xAAAA…`(해제된 옛 스택)를 읽었다.

## 남은 것

- 호스트 함수 안에서 VM을 다시 부르는 경로가 생기면 `.host` 프레임의 pc가 null이라 그 아래 프레임의 레이아웃 조회가 빠진다.
  그때 `FrameInfo.prev_context`에 호출 지점 pc를 남기는 방식을 정해야 한다.
