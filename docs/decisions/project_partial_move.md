# 부분 이동의 상태 모델과 관리 멤버 지원 (2026-11-08)

상태: 구현됨. 발견 이슈 F-27(06장 §7.1의 4번). 매뉴얼 `docs/docs.md` "Moving" 절의 예제(`Foo{a int, b str}`에서 `move f.b`)가 이 수정으로 컴파일된다.

## 배경

`move s.b`처럼 구조체의 멤버만 옮기면 sema가 지역마다 `[]bool` 상태 벡터(`proc.var_active_struct_fields`)를 두고 옮긴 칸을 false로 바꾼다.
지역이 정리될 때 `get_partial_dtor`가 그 벡터를 `PartialStructLayout`으로 중복 제거해 `@partial_destruct(T, Layout, ptr)`(core.cy) 템플릿을 펼치고,
템플릿 안의 `Layout.is_field_active(offset)` · `Layout.field_layout(offset, len)`이 컴파일 타임 상수라 "어느 필드를 정리하는가"가 인스턴스마다 고정된다.

구조체 필드는 자기 필드의 상태를 그대로 펼친다(`state_offset`이 누적되고 `field_state_len`이 합). 그래서 템플릿의 구조체 필드 분기는
`#if Layout.field_layout(...) |layout|:`로 "일부만 옮겨진 하위 레이아웃"을 받는데, 이 컴파일 타임 `if` 언랩 문장을 `ct_inline.evalStmt`가 지원하지 않아
(`Unsupported compile-time statement. if_unwrap_stmt`) `str`처럼 구조체인 관리 필드를 가진 타입은 어떤 멤버를 옮겨도 컴파일되지 않았다.
`int` · `^int` · `?int` · choice 필드만 있으면 그 분기를 타지 않아 통과했다(`memory/partial_move.cy`).

고치면서 같은 경로의 결함이 더 나왔다.

- 템플릿의 재귀 호출이 `#partial_destruct(...)`로 적혀 있어 심볼을 찾지 못했다(`@partial_destruct`가 맞다).
- `?PartialStructLayout`은 포인터 자식의 zero-union 옵션인데 `heap_value.destructValue2`가 값이 0이 아니면 무조건 힙 객체로 release해
  컴파일 타임 값 해제에서 죽었다(ReleaseSafe `integer overflow`, Debug `attempt to use null value`).
- 멤버 읽기 검사(`semaField`)가 필드 색인(`idx`)을 더했다. 상태 오프셋(`state_offset`)과 다르므로 중첩 구조체 멤버 하나를 옮기면 형제 멤버
  (`move o.inner.s` 뒤 `o.inner.t`)가 `Member is no longer alive.`로 거부됐다.
- 구조체 멤버를 통째로 옮기면(`move o.inner`) 첫 상태 칸만 false가 됐다. 나머지 하위 멤버는 살아 있는 것으로 보고 블록 끝에 다시 정리하므로 이중 해제였다.
- `str`은 `@deinit`을 가진 구조체다. 그 하위 필드(`buf`)의 상태를 따로 세면 `move f.b` 뒤 `@partial_destruct(str, …)`가 필요해지는데 템플릿은
  `@deinit`이 있는 타입의 부분 파괴를 `meta.error`로 거부한다. 모델이 어긋나 있었다.
- 부분 이동된 지역을 통째로 쓰는 것(`g := f` 복사, `&f` · `&o.inner` 빌림, `move f`)을 막지 않았다. 죽은 멤버를 복사하거나 읽는 use-after-move다.

## 결정

1. 컴파일 타임 `#if <opt> |x|:`를 지원한다. `ct_inline.ifUnwrapStmt`가 옵션 값을 평가해 값이 있으면 `x`를 컴파일 타임 변수로 묶고 블록을 인라인 평가하고,
   없으면 `#else` · `#elseif`로 간다(`ifStmt`와 `elseBlocks` 공유). `?PartialStructLayout`처럼 zero-union 옵션의 값 해제는 자식 타입으로
   `destructValue2`를 부른다(raw 포인터 · `PartialStructLayout`은 힙 객체가 아님).
2. 상태 모델. 필드 하나가 차지하는 상태 수는 `sema_type.fieldStateLen`이 정한다. `@deinit`이 없는 구조체 필드는 자기 필드들의 상태를 펼치고(멤버를 하나씩 옮길 수 있음),
   그 밖의 필드(`@deinit`이 있는 구조체 포함)는 상태 하나다. `str` · `Array` · 사용자 자원 타입은 통째로만 옮기고 통째로만 정리된다.
   `@partial_destruct` 템플릿의 구조체 분기도 `meta.has_decl(field.type, '@deinit')`로 같은 구분을 한다.
3. `@deinit`이 있는 타입의 멤버는 옮길 수 없다(`move p.a.name`에서 `Res`가 `@deinit`을 가지면
   `Cannot move a member out of \`Res\`. The type has a custom \`@deinit\`.`). 부분 파괴가 `@deinit`과 양립하지 않기 때문이다(core 템플릿의 기존 규칙을 sema 오류로 앞당김).
4. 옮기는 멤버의 상태 범위 전체를 false로 만든다. 범위는 접근 경로의 가장 바깥 필드 접근(choice 페이로드 언랩 뒤면 그 다음 필드)의 `fieldStateLen`이다.
   멤버 읽기는 `state_offset`을 누적하고 "범위 안에 살아 있는 상태가 하나라도 있으면" 통과한다. 그래서 중첩 멤버 하나를 옮긴 뒤 형제 멤버와 바깥 멤버는 읽을 수 있고,
   통째로 옮긴 멤버의 하위 멤버는 `Member is no longer alive.`다.
5. 부분 이동된 값은 통째로 쓸 수 없다. 범위에 죽은 상태가 하나라도 있으면 복사(`sema_copy`) · 빌림(`semaBorrow` · `sema_ex_borrow2`)이
   `Cannot copy|borrow a partially moved value.`, 통째 `move`는 `Cannot move a partially moved value.`다. 멤버 접근과 재대입(기존 규칙, 같은 블록에서만)은 그대로다.
6. 옮겨 나간 멤버에 대입하면 그 멤버가 되살아난다(2026-11-09, F-79). 옛 값은 파괴하지 않고 상태 칸을 true로 돌리며, 모든 칸이 살아나면 변수는 다시 온전하다.
   변수가 선언된 블록 안에서만 된다(`Can only assign to a moved member of a variable declared in the same block.`). 아래 설계 메모.

## 구현 메모

- `src/ct_inline.zig` `evalStmt`의 `.if_unwrap_stmt` · `ifUnwrapStmt` · `elseBlocks`, `src/heap_value.zig` `destructValue2`의 `.option` zero-union 분기,
  `src/sema_type.zig` `fieldStateLen`(두 구조체 해석기가 사용), `src/chunk.zig` `VarAccessPath.state_len`,
  `src/sema.zig` `check_struct_access_path`(범위) · `checkPartialMoveWhole` · `build_move_access_path`(`@deinit` 거부, `state_len` 기록) · `semaField`(`state_offset` 누적) ·
  `semaLocal`(지역 전체 범위) · `move_expr`(범위 `@memset`, 통째 move 거부) · `sema_copy` · `semaBorrow` · `sema_ex_borrow2`,
  `src/builtins/core.cy` `@partial_destruct`의 구조체 분기(`has_decl` 구분, `@partial_destruct` 재귀 호출).
- 접근 경로는 청크 하나의 임시(`temp_access_path`)에 남으므로 `semaLocal` · `semaField` 직후의 소비자(`sema_copy` 등)에서만 믿을 수 있다. `move_expr`도 같은 전제다.
- 테스트: behavior `memory/partial_move_struct_fields.cy`(`str` 멤버, 중첩 멤버와 형제 · 바깥 접근, 중첩 멤버 통째 이동, `@deinit` 멤버 이동 뒤 파괴 횟수 2,
  재대입 뒤 4), 오류 `partial_move_deinit_member_error.cy` · `partial_move_copy_error.cy` · `partial_move_borrow_error.cy` · `partial_move_whole_error.cy`.
  기존 `partial_move.cy`(choice · option 페이로드) 그대로 통과.

## 기대 동작

- 매뉴얼 예제 `f := Foo{a=123, b='abc'}; b := move f.b; print(b); print(f.a)`가 `abc` · `123`.
- `o := Outer{inner=Inner{s, t, n}, x, k}; s := move o.inner.s` 뒤 `o.inner.t` · `o.inner.n` · `o.x` · `o.k` 읽기 가능, `&o.inner` · `x := o.inner`는 오류.
- `a := move p.a`(`Res`에 `@deinit`) 뒤 함수가 끝나면 `deinit`이 `a`와 `p.b`에서 한 번씩(2회).
- `a := move p.a; p.a = Res{name='a2'}` 뒤 `q := move p`가 되고 함수가 끝나면 `deinit`이 `a` · `a2` · `b`에서 한 번씩(3회). `s := move o.inner.s; o.inner = Inner{..}`는 옛 `t`만 파괴(누수 없음, Debug 누수 검사 통과).
- `type Two: a Res, b Res; b := move t.b` 뒤 `t.a.name` 읽기 · `t.a.name = 'a2'` 대입이 된다(F-80).

## 설계 메모: 부분 이동 뒤의 통째 이동

`name := move a.name` 뒤 `b := move a`에서 `b`가 무엇을 가져가야 하는가. 결정 5는 컴파일 오류(`Cannot move a partially moved value.`)이고, 이유는 `b`의 타입이 `User`라는 데 있다.
`User` 타입의 값은 모든 멤버가 살아 있다는 것이 타입의 보장이다. 검토한 선택지와 버린 이유는 다음과 같다.

| 선택지 | 결과 | 판단 |
|---|---|---|
| 컴파일 오류 | 부분 이동 상태는 지역 변수 `a` 하나에만 붙은 sema 정보로 남고 변수 경계를 넘지 않는다. Rust의 E0382(use of partially moved value)와 같다 | 채택 |
| 남은 멤버만 옮기고 `b`도 부분 이동 상태로 | 같은 함수 안에서는 `[]bool` 상태 벡터를 `b`로 복사하면 되지만, `b`를 인자로 넘기거나 반환하거나 `Array[User]`에 넣는 순간 "구멍 난 `User`"가 타입 정보 없이 돌아다닌다. 추적하려면 런타임 drop flag나 부분 타입이 필요해 "sema 한 번 훑기" 설계와 맞지 않는다 | 버림 |
| 빠진 멤버를 기본값으로 채워 옮기기(Rust `mem::take`) | 모든 타입에 기본값이 있지 않고(`@deinit`이 있는 자원 타입), 프로그램이 쓰지 않은 생성이 숨어서 일어난다 | 버림 |

같은 이유로 복사 · 빌림도 통째로는 거부한다. `b`가 `User` 전체를 가져가게 하려면 사용자가 먼저 `a`를 온전하게 만들어야 하고, 현재 그 수단은 같은 블록에서의 통째 재대입뿐이다
(`a = User{name='other', age=a.age}; b := move a`).

Rust는 한 단계 더 허용한다. 옮겨 나간 필드에 `a.name = ...`로 다시 대입하면 그 필드만 되살아나고 그 뒤 `move a`가 된다. 이 규칙은 상태 벡터 모델로 자연스럽게 확장된다.
죽은 멤버에 대한 `set_field`를 "기존 값 파괴 없이 초기화"로 내보내고 해당 상태 칸을 true로 돌리면 된다.

2026-11-08까지의 구현은 이 경로를 막지도 지원하지도 않았다(F-79). `a := move p.a; p.a = Res{name='a2'}`가 컴파일되는데, 좌변 `p.a`는 `semaAssignToAccessStmt`의 필드 대입이라
상태 칸을 보지도 되돌리지도 않았다. 그 결과 `set_field` 앞의 옛 값 파괴가 이미 `a`로 옮겨 간 `Res`를 파괴해 `a`의 `@deinit`이 두 번 돌고(재대입 시점과 `a`의 블록 끝),
새 값 `a2`는 상태가 죽은 채라 `@partial_destruct`가 건너뛰어 한 번도 정리되지 않았다. 대입 뒤 `p.a`를 읽으면 여전히 `Member is no longer alive.`였다.

2026-11-09에 (2) 되살리기로 고쳤다. 결정 6: 옮겨 나간 멤버에 대입하면 그 멤버가 되살아난다.
- `semaAssignToAccessStmt`가 수신자에 접근 경로(`check_struct_field_access`)가 붙어 있으면 우변을 평가하기 전에 대입 대상 멤버의 상태 칸을 읽는다(`ReviveMember`: 변수 · 칸 오프셋 · 길이 · 일부만 살아 있는지).
  우변 평가가 `c.temp_access_path`를 덮어쓸 수 있어 먼저 읽는다.
- 죽은 칸이 하나라도 있으면 옛 값을 파괴하지 않고 `set_field`만 내보낸 뒤 그 칸들을 true로 돌린다. 멤버의 일부 칸만 살아 있으면(`s := move o.inner.s; o.inner = Inner{..}`) 새 함수
  `sema_call_partial_destruct_member`가 그 멤버의 주소에 `@partial_destruct(Inner, layout)`을 불러 산 멤버(`t`)만 파괴한다. 옮겨 나간 멤버는 새 소유자의 것이다.
- 되살린 뒤 변수의 모든 칸이 true면 `var_active_struct_fields`에서 빼고 `has_inactive_struct_fields = false`. 변수는 다시 온전하므로 통째 복사 · 빌림 · 이동이 된다.
- 변수가 선언된 블록 안에서만 되살릴 수 있다(`Can only assign to a moved member of a variable declared in the same block.`). 통째 재대입과 같은 규칙이고 이유도 같다. `if` 안에서 되살리면
  블록 끝의 상태가 분기에 따라 달라져 런타임 drop flag가 필요해진다. move 자체가 선언 블록에서만 되므로 "선언 블록 = move 블록 = 되살리기 블록"이다.
- 산 멤버에 대입하는 것은 이전과 같다(옛 값 파괴 뒤 저장). 죽은 멤버의 하위 멤버에 대입(`inner := move o.inner; o.inner.s = 'x'`)은 수신자 `o.inner` 평가에서 `Member is no longer alive.`다.
  죽은 멤버를 읽는 복합 대입(`p.a += x`)도 읽기 쪽에서 같은 오류다.

같은 수정에서 F-80을 찾았다. `semaField`가 접근 경로를 한 단계 들어갈 때 `state_len = fieldStateLen(field_t)`로 바꾸는데, `@deinit`이 있는 멤버(상태 1칸, 예: `Res`)의 하위 필드 `name str`로
들어가면 `str`이 core.cy의 구조체(`type str:`, 필드 3개, `@deinit` 선언 없음)라 `fieldStateLen(str) = 3`이 되어 1칸짜리 멤버 자리에서 3칸을 읽었다. `type Two: a Res, b Res; b := move t.b; t.a.name`은
상태 벡터가 2칸뿐이라 컴파일러 panic `index out of bounds: index 3, len 2`(호스트 사망), 칸이 더 있는 `Pair{a, b, c str}`에서는 형제 `b`의 false를 읽어 거짓 `Cannot copy a partially moved value.`였다.
기존 테스트가 통과한 것은 첫 멤버를 옮기고 둘째를 읽는 순서라 뒤쪽 칸이 모두 true였기 때문이다. 수정은 `step_member_access_path`: 수신자 타입에 `@deinit`이 있으면 경로를 그대로 둔다
(그 멤버의 하위 멤버는 모두 그 1칸을 공유한다). `semaField`와 되살리기 양쪽이 이 함수를 쓴다. `str`이 3칸을 차지하는 것 자체는 Zig(`fieldStateLen`)와 core.cy(`type.struct_state_len`)가
같은 값을 보므로 일관되고, `str`의 내부 필드를 사용자가 따로 옮길 수 없어 항상 세 칸이 함께 움직인다. 칸을 1로 줄이려면 양쪽을 같이 고쳐야 해 이번에는 두지 않았다.

참고로 `move`는 `NoCopy` 타입 전용이 아니다. `move_expr`은 복사 가능 여부를 보지 않으며 `a := 123; b := move a`도 `a`를 죽인다(`memory/move_use_after_error.cy`).
복사 가능(`NoCopy` 아님)과 이동 가능은 직교하는 두 축이고, `NoCopy`는 암시적 복사가 일어나는 자리(`sema_copy`)에서만 검사된다. Rust는 `Copy` 타입에 move 의미가 없다는 점이 다르다.

## 남은 것

- 부분 이동 뒤 지역을 조건부로 다시 채우는 것(drop flag)은 없다. 재대입은 같은 블록에서만.
- 되살리기도 선언 블록 안에서만. 조건부 되살리기(drop flag)는 없다.
- `str`은 상태 벡터에서 3칸(core.cy 구조체 필드 수)을 차지한다. 1칸으로 줄이려면 `sema_type.fieldStateLen`과 core.cy `@partial_destruct`의 `type.struct_state_len`을 함께 고친다.
- `Local.has_inactive_struct_fields`가 있는 지역은 `implicitReturnMoveLocal`에서 제외되어 `return f`가 복사 경로로 가고, 그 복사는 이제 오류다. 부분 이동된 값을
  반환하려면 멤버를 따로 반환한다.
- 접근 경로가 `.deref`를 지나는 경우(`&Foo` 빌림의 멤버 move)는 이전처럼 검사하지 않는다.
