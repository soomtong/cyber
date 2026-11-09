# `&&T`를 거친 필드의 주소 (2026-11-09, F-73)

## 배경

발견 이슈 F-73: `fn (&&D) push(x int): self.items << x`를 세 번 부르면 `d.items.len()`이 3이 아니라 1이고, `items` 앞에 다른
필드가 있으면 세그폴트였다(00장 §7.3 4번, HEAD `b40531a1`). 2026-11-06 `db9f636d`에서는 재현되지 않아 회귀 테스트
`types/method_mut_self_array_field.cy`로 고정했지만, 고친 커밋과 원인을 특정하지 못해 표에서 "원인이 밝혀질 때까지 조용한 오답과
같은 급"으로 남겨 두었다. 덤프에는 여전히 `addr %7 = *%4`가 보여 원래 진단(빌림 매개변수를 거친 필드 주소 취하기)이 틀렸을 수 있다고
적었다.

## 조사

`b40531a1`(재현)과 `db9f636d`(재현 안 됨) 사이를 커밋마다 ReleaseSafe CLI를 빌드해 이분 탐색했다(scratchpad `try.sh`, 빌드당 약 50초).

- 재현이 사라진 첫 커밋은 `38272a0c`(레지스터 레코드 필드 직접 접근 · 인라인 `&지역` 인자 묶기, `project_bc_register_fields.md`)다.
- 그 커밋 전후로 `fn D.push` 자체의 바이트코드는 같다. 바뀐 것은 main에 인라인된 `d.push(1)`이다. 전에는 `addr %4 = *%1`로 `&d`를
  임시 `%4`에 담아 매개변수 `self`로 쓰고, 본문의 `self.items` 주소가 `addr %7 = *%4`(레지스터 `%4`의 주소) + 0이었다. 후에는 인라인
  인자 `&&d`가 매개변수를 `LocalSlot.addr_of`로 묶어 `self.items`의 주소가 `addr %5 = *%1`(`d` 자체의 주소)이 됐다. 즉 `38272a0c`는
  인라인 경로에서 버그가 드러날 자리를 없앤 것이지 원인을 고친 것이 아니다.
- 원래 진단은 맞았다. `addr dst = *src`는 VM(`vm.c` `CASE(ADDR)`)에서 `dst = &stack[src]`, 곧 레지스터 `src`의 주소다. 덤프 표기
  `*%src`가 역참조처럼 보일 뿐이다. 인라인되지 않은 `fn D.push`에서 `%4`는 `self`(`&&D`, 포인터 값)인데 `addr %7 = *%4`는 그 포인터가
  든 슬롯의 주소를 `items`의 주소로 썼다. `Array.append`는 `{%4, %5, %6}`을 `Array{buf, length, header}`로 읽어 `buf = self 포인터`,
  `length = x`로 `D` 안의 `x`번째 워드에 `x`를 썼다. `push(1)`이 `d.items.length`에 1을, `push(2)`가 `header`에 2를, `push(3)`은 `D`
  밖을 덮어 `len()`이 1이었다. `items` 앞에 필드가 있으면 `buf`가 정수 필드 값(`+8` 자리의 `x`)이라 세그폴트 · 무한 루프다.
- `38272a0c` 이후에도 인라인되지 않은 호출(본문이 인라인 비용 한도를 넘는 메서드, `&&T` 일반 매개변수)은 같은 코드라 HEAD
  `aa642ed5`에서 본문 10줄짜리 `push_many`가 여전히 세그폴트였다. 회귀 테스트는 인라인된 호출만 담고 있어 잡지 못했다.

## 원인

`bc_gen.genAddressOfField`가 필드의 레코드가 `.pointer`나 `.borrow`(`&T`)면 레코드 식의 값(주소)을 쓰고, 그 밖은 값 레코드로 보고
`genAddressOf2`로 주소를 만든다. 배타 빌림 `&&T`는 별도 종류 `ex_borrow`라 "그 밖"으로 떨어져 `genAddressOf2(.local)` →
`addr dst = *reg`, 곧 빌림이 든 레지스터의 주소가 됐다. 값 읽기 · 쓰기(`gen_field` · `gen_set_field`)는 `Type.isRefLike()`
(`borrow` · `ex_borrow` · `pointer`)로 판별해 멀쩡했으므로 `self.tail = x`나 `self.n` 읽기는 맞았고, 필드의 주소가 필요한 자리
(`self.items << x`처럼 필드를 `&&` · `&` 수신자로 넘기는 호출)만 틀렸다.

`fold_rec_offset`도 같은 두 종류에서만 멈춰 `&&T` 타입 필드(`type H: r &&D`의 `h.r.items`)를 담는 구조체의 레이아웃 안으로 접었다.
이 경우는 인라인 여부와 무관하게 틀렸다(`h.push` 두 번에 `len()`이 1).

## 결정

두 자리 모두 `rec.type.isRefLike()`로 판별한다. 포인터 · 빌림 · 배타 빌림 뒤의 필드는 레코드 식의 값이 주소이고, 값 레코드만 주소를
만든다. 생성되는 코드는 `fn D.push`에서 `addr %7 = *%4; add_i16 %6 = %7 + 0`이 `add_i16 %6 = %4 + 0`으로 바뀐다. 다른 경로의
코드는 그대로다(`gen_field` · `gen_set_field` · `local_field_base`는 이미 `isRefLike`).

## 테스트

`src/test/types/method_mut_self_array_field.cy`를 넓혔다. 기존 인라인 케이스(`Items` · `Bag`)에 더해 인라인 한도를 넘는 본문의
`&&self` 메서드(`push_many`, 앞 필드 · 뒤 필드 보존 확인), `&&T` 일반 매개변수(`fill(d &&Items, x)`), `&&self` 뒤의 중첩 필드
(`self.inner.items`), 구조체에 든 `&&T` 필드(`Holder{r=&&f}`의 `self.r.items`). 수정 전 바이너리(`aa642ed5` ReleaseSafe)에서는
이 테스트가 무한 루프(20초 타임아웃)고 수정 후 통과한다.

## 남은 것

- 인라인 경로의 `.addr_of` 묶기는 그대로 둔다. 이번 수정은 인라인되지 않은 코드와 `&&T` 필드 접기를 고친 것이고, 인라인된 경우는
  `38272a0c` 이후 애초에 `addr`를 내지 않는다.
- (완료 2026-11-10) 덤프의 `addr` 표기 `%dst = *%src`는 "레지스터 `src`의 주소"라는 뜻이었고 이 조사에서 역참조로 오독됐다. 덤프 기대
  문자열을 쓰는 테스트는 없어 `bytecode.zig`의 표기를 `%dst = &%src`로 바꿨다. 이 문서와 발견 이슈 표의 `*%` 인용은 당시 출력 그대로다.
