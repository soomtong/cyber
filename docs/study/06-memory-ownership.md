---
aliases: [메모리, 소유권, ARC, 힙]
tags:
  - study
  - cyber
  - memory
  - ownership
  - arc
  - heap
---

# Day 6 (오전). 메모리 모델: 값 소유권 · 빌림 · `^T` ARC

> 대상 소스: `src/sema.zig`(소유권 코드), `src/sema_func.zig`(호출 인자 소유), `src/sema_type.zig`/`src/types.zig`(copy/managed 비트), `src/ir.zig`, `src/bc_gen.zig`,
> `src/vm.c`/`src/vm.h`(retain/release 명령), `src/heap.zig`/`src/heap_value.zig`(힙), `src/thread.zig`(패닉 정리, 스택 포인터 패치), `src/vm.zig`(`VM.deinit`),
> `src/builtins/core.cy`(`@destruct`/`@deinitObject`/`str`/`Slice`/`Array`/`Map`), `src/builtins/string.zig`, `src/lib.zig`(호스트 소유 규약)
> 줄 번호는 모두 HEAD `b40531a1` 기준이다.
> 예상 학습 시간: 4시간 (읽기 1.5 / 소스 탐독 1.5 / 실습 1)
> 선행: [05 VM 런타임](05-vm-runtime.md), [03 의미 분석과 IR](03-sema-and-ir.md). 타입 레이아웃은 [02 심볼과 타입](02-symbols-and-types.md), 제너레이터 프레임의 소유 문제는 [07 코루틴](07-coroutines-concurrency.md)에서 다룬다.

이 문서에서 `cyber`는 `zig-out/bin/cyber`(ReleaseSafe 빌드)이고, `cyber-trace`는 `-Dtrace=true`로 빌드한 CLI다.
실행 결과는 모두 이 두 바이너리로 직접 돌려 얻은 것이다. 에러 메시지의 절대 경로는 `<repo>`로 줄였다.
"코드 근거"라고 적은 것은 소스를 읽어 확인했지만 돌려 보지 못한 것이고, "일반 지식"은 다른 언어 이야기라서 이 저장소 코드로 확인한 것이 아니다.

## 한줄 요약

0.3은 "모든 객체를 참조 카운트(ARC)하고 순환은 `performGC()`로 수거"하는 단일 모델이었다. 0.4는 스택 값에 소유자를 하나 두고
(copy / move / borrow를 컴파일러가 검사), 힙 객체를 여러 곳에서 공유해야 할 때만 `^T`(ARC)를 쓰는 혼합 모델이다.
컴파일러(sema)가 블록 끝, 재대입, 반환, 호출 인자마다 "누가 언제 해제하는가"를 IR에 `release`/`@destruct` 호출로 박고,
런타임은 풀 + 큰 객체 힙에 8바이트 헤더(타입 id, rc)만 유지한다. GC는 없고, 순환 탐지는 아직 껍데기다.

## 오늘의 학습 목표

- [ ] 값 타입과 `^T`, 소유자, copy / move / `&` / `&&` / `scope` / `sink`가 TS의 참조 의미론과 어떻게 다른지 설명하고, 같은 로직을 네 방식으로 바꿔 돌려 본다
- [ ] sema에서 소유권이 코드로 구현된 곳(`semaOwn`, `sema_copy`, `semaManage`, `semaDestructLocal`, `popLocals`, `move_expr`, `ownOrManageArg`)을 찾고, 무엇이 IR/바이트코드로 나오는지 `cyber compile`로 확인한다
- [ ] 객체 헤더, 풀 슬롯, 큰 객체, `Release` 명령에서 `@deinitObject[T]`로 이어지는 해제 경로와 `@destruct`의 호출 순서를 그림으로 그릴 수 있다
- [ ] `str`, `Slice`, `Array`, `Map`이 소유 규약을 어떻게 구현하는지(정적 문자열, 버퍼 헤더 count, 복사 후 파괴 vs 이동)를 코드와 실험으로 구분한다
- [ ] 순환 참조, 패닉, 종료(`single_run`) 때 무슨 일이 일어나는지(소멸자가 도는지 아닌지)와 누수 보고 방법을 안다
- [ ] 빌림 검사가 Rust와 어디서 다른지, 이 fork를 유지보수할 때 어디를 의심해야 하는지 체크리스트로 말할 수 있다

## 1. 왜 이것이 필요한가?

### 1.1 TS 개발자에게 "GC 없는 세계"

TS/Node에서는 객체를 만들고 변수에 담기만 하면 엔진(V8)이 도달 가능성을 추적해 언제 회수할지 알아서 정한다(일반 지식: 세대별 추적 GC).
`const b = a`는 같은 객체를 가리키게 만들 뿐이고, 해제 시점은 개발자가 모른다. 파일 핸들을 닫는 일은 `try/finally`나 `using`처럼 개발자가 쓰는 코드가 맡는다.
`FinalizationRegistry`는 있지만 "언제 불릴지 보장하지 않는다"(일반 지식).

Cyber에는 추적 GC가 없다. 대신 질문 네 개에 컴파일러가 답한다.

1. 이 값의 주인은 누구인가? 스택 값은 변수 하나, 힙 값은 `^T`를 쥔 소유자들.
2. 언제 정리하는가? 주인이 블록을 벗어나거나 다시 대입될 때, 즉 코드의 모양으로 정해진다.
3. 대입/호출에서 복사가 일어나는가, 소유권이 옮겨 가는가? copy / move.
4. 소유권 없이 잠깐 빌려 쓰려면? `&T`, `&&T`.

장점은 결정적 해제다. `@deinit`이 "범위를 벗어난 바로 그 자리에서" 돈다(Rust의 `Drop`, Swift의 `deinit`과 같은 쓰임, 일반 지식).
비용은 학습 곡선이다. 복사할 수 없는 타입이 있고, 쓰고 난 변수를 다시 쓰면 컴파일 에러가 난다.

### 1.2 0.3은 무엇이었나

`git show 0.3:docs/hugo/content/docs/toc/memory.md`에 0.3의 설명이 남아 있다.

- 값은 원시 값과 객체로 나뉘고, 객체는 전부 ARC였다. 동적 타입이라 컴파일러가 값의 종류를 몰랐으므로 모든 값을 보수적으로 다뤄야 했다.
- 0 이 되면 `freeObject`가 자식을 재귀적으로 release하고 호스트 객체는 `finalizer`를 부른다(`git show 0.3:src/arc.zig`의 `release`, 15줄).
- 순환은 `performGC()`로 수거했다(`arc.zig` 233줄: `performMark` + `performSweep`, 메인 fiber 스택만 루트로 삼는 "Incomplete" 기능).
- 40바이트 이하 객체는 풀에서, 더 큰 것은 mimalloc에서 할당했다.

### 1.3 0.4는 무엇을 바꿨나

정적 타입이 들어오자 컴파일러가 "이 값은 정수라서 해제할 게 없다", "이 값은 마지막 사용 뒤 끝난다"를 알 수 있게 됐다.
그러면 대부분의 값은 카운트 없이 스코프 규칙만으로 정리할 수 있다. 그래서 모델이 다음 둘로 갈라졌다(`docs/history/ownership_memory.md`, `docs/docs.md` 2143줄 이후).

| 구분 | 어디에 사는가 | 수명 결정 | 공유 |
|---|---|---|---|
| 값 소유권 | 스택(또는 다른 값의 내부) | 소유 변수의 스코프 | 불가. 빌림 `&T`/`&&T`만 가능 |
| 공유 참조 `^T` | 힙 객체 | 참조 카운트 0 | 가능. 소유자가 여럿 |

"해제 코드를 누가 쓰는가"도 바뀌었다. 0.3은 Zig 함수 하나(`arc.release`)가 타입별로 분기했지만, 0.4는 `@destruct[T]`와 `@deinitObject[T]`를
`core.cy`에 Cyber 코드(컴파일 타임 템플릿)로 적어 두고, 컴파일러가 타입마다 인스턴스를 만들어 호출한다(2.4절). 사용자 `@deinit`이 이 한 경로에 끼어들 수 있는 이유다.

## 2. 근본적인 동작 원리

### 2.1 세 층으로 보기

```
 언어 층 (사용자가 쓰는 규칙)          컴파일러 층 (sema, 03/04장)             런타임 층 (이 장 2.4~)
 ----------------------------        ---------------------------------      ----------------------------
 a := b        copy 또는 error       semaOwn -> sema_copy                    copy_str / retain 명령
 a := move b   b 는 죽음             move_expr: Local.type = .dead           (런타임 흔적 없음)
 f(&a)         빌림                  semaBorrow: active_borrows += 1         포인터 한 개(주소)
 ^T            힙 객체, 공유         semaLift: ir.lift                       new 명령 + 헤더 rc=1
 블록 끝       자동 정리             semaDestructLocal -> dtor 호출 /        dtor_str / release 명령 +
                                    ir.release                              @deinitObject[T] 호출
 @deinit       사용자 정리 코드      @destruct[T] 템플릿이 먼저 호출         (일반 Cyber 함수 호출)
 temp 값       문장 끝에 정리        semaManage: _temp 지역 + popLocals      위와 동일
```

흐름을 한 줄로 쓰면 "AST --sema--> IR(`release`, `retain`, `lift`, `@destruct` 호출이 박힘) --bc_gen--> 명령어(`retain`, `release`, `dtor_str`, `copy_str`, `new`) --vm.c--> 헤더 rc 증감과 풀/큰 객체 해제"다.
핵심은 IR이 이미 모든 정리를 명시한다는 점이다. `bc_gen`은 소유권을 판단하지 않고 번역만 한다(`src/ir.zig` 9~17줄의 설계 주석).

### 2.2 언어 층: 복사, 이동, 빌림, 공유

#### 값 타입과 참조 타입이 TS와 어떻게 다른가

TS에서는 객체 리터럴이 모두 참조 타입이라 `const b = a`가 같은 객체를 가리킨다. Cyber에서 `type Point` 같은 구조체는 값 타입이고 `b := a`는 복사다.
공유하려면 `^`로 힙에 올려야 한다. 같은 로직을 네 방식으로 바꾸면 다음과 같이 돈다(실행 확인, `cyber cmp1.cy`).

```cy
type Counter:
    n int

fn bump_value(c Counter) -> Counter:    -- 값 매개변수: 호출자의 값은 그대로
    c.n += 1
    return c
fn bump_borrow(c &Counter):             -- 빌림: 호출자의 값을 직접 변경
    c.n += 1
fn bump_ref(c ^Counter):                -- 공유 참조: 모든 소유자가 같은 객체를 본다
    c.n += 1

a := Counter{n=0}
r := bump_value(a)
print('value : a.n=%{a.n} r.n=%{r.n}')
bump_borrow(&a)
print('borrow: a.n=%{a.n}')
shared := ^Counter{n=0}
alias := shared
bump_ref(alias)
print('ref   : shared.n=%{shared.n} alias.n=%{alias.n}')
s1 := []int{1, 2, 3}                    -- Slice: 복사는 버퍼를 공유한다
s2 := s1
s2[0] = 100
print('slice : s1[0]=%{s1[0]} s2[0]=%{s2[0]}')
arr := Array[int]{1, 2, 3}              -- Array: 복사 불가, move 로 소유권만 이전
arr2 := move arr
arr2[0] = 100
print('array : arr2[0]=%{arr2[0]} (arr 는 더 이상 쓸 수 없다)')
```

```
value : a.n=0 r.n=1
borrow: a.n=1
ref   : shared.n=1 alias.n=1
slice : s1[0]=100 s2[0]=100
array : arr2[0]=100 (arr 는 더 이상 쓸 수 없다)
```

관찰할 점. (1) `Slice`는 "복사 가능"하지만 얕은 복사다. 버퍼를 가리키는 `^RawBuffer`가 retain될 뿐이라 원소 쓰기가 양쪽에서 보인다(2.5절).
(2) `Array`는 `with NoCopy`라서 `b := a`가 컴파일 에러다. TS의 `const b = [...a]`처럼 복제하려면 `clone()`이 있어야 하는데, 이 저장소에서는 `Array.clone()`이 컴파일되지 않는다(7절).
(3) `&Counter`는 Rust의 `&mut`처럼 쓴다. 이 언어의 `&T`는 읽기 전용이 아니다.

#### 복사 가능성은 타입의 비트 네 개로 정해진다

`src/types.zig:55~75`의 `TypeInfo`가 sema와 코드젠이 공유하는 요약이다.

| 비트 | 의미 | 정해지는 곳 |
|---|---|---|
| `managed` | 정리할 것이 있다(자식이 managed이거나 `@deinit`이 있다) | `sema_type.zig:919~920` (struct), 포인터는 `ref`면 항상 true(`:161~172`) |
| `copy_base` | 단순 `memcpy`로는 부족하다(자식 중 복사 생성자가 필요한 것이 있다) | `resolve_type_info`(`sema_type.zig:942~959`) |
| `copy_user` | 사용자가 `@copy`를 정의했다 | 같은 함수의 `sym.has_decl("@copy")` |
| `no_copy` | `with NoCopy`를 선언했거나 멤버 중에 `no_copy`가 있다 | `sema_type.zig:945~953`, `resolve_type_impls` 989줄 |

예를 들어 `^T`는 `managed = true`, `copy_base = true`(복사 = retain)다. `str`은 `buf ?^StrBuffer`를 가진 구조체라서 자동으로 `managed`이고 `copy_base`다.
정수만 가진 `Counter`는 `managed = false`라서 복사도 정리도 컴파일러가 아무 코드를 만들지 않는다.

`core.cy`의 주석(758~761줄)은 "모든 멤버가 `Copyable`이거나 `@copy`가 구현되면 `Copyable`"이라고 쓰지만, 코드는 다르다.
`resolve_type_info`는 멤버 중 `no_copy`가 있으면 `@copy`가 있어도 `no_copy = true`로 만든다. 실험에서 `Array`를 멤버로 가진 구조체에 `@copy`를 달아도
"Cannot copy `Buf`, type member implements `NoCopy`."가 났다(7절 목록에 정리).

#### 사용자 `@copy`와 `@deinit`이 도는 순간

```cy
type Buf:
    id int
    data []int
fn (&Buf) @copy() -> Buf:
    print('@copy Buf %{self.id}')
    return Buf{id=self.id + 1, data=self.data}
fn (&Buf) @deinit():
    print('deinit Buf %{self.id}')
fn take(b Buf):
    print('take %{b.id}')

a := Buf{id=1, data=[]int{1, 2}}
b := a
print('b.id=%{b.id}')
take(a)
print('end')
```

```
@copy Buf 1
b.id=2
@copy Buf 1
take 2
deinit Buf 2
end
deinit Buf 2
deinit Buf 1
```

`b := a`가 `@copy`를 부르고(복사본 id=2), `take(a)`도 인자마다 복사한다. 값으로 받은 매개변수는 호출된 함수가 소유하므로 `take`가 끝날 때 `deinit Buf 2`가 돈다.
main 끝에서는 선언의 역순으로 `b`(id=2), `a`(id=1) 순이다. 같은 규칙이 `^a`에도 적용된다. `^`는 "소유한 값"을 박스에 넣으므로 rvalue는 그대로 이동하고, 지역 변수는 복사한다.
`lift_moves_rvalue.cy`가 rvalue 쪽을 검증하고, `r2 := ^a`는 `@copy Buf 1`을 출력했다.

#### move와 sink

`b := move a`는 `a`를 죽은 변수로 만든다. 죽은 변수를 쓰면 컴파일 에러다(`move_use_after_error.cy`).

```
CompileError: `a` is no longer alive in this scope.

<repo>/src/test/memory/move_use_after_error.cy:3:1:
a
^
```

제약도 몇 개 있다(모두 실행 확인).

- 같은 블록에서 선언한 변수만 move할 수 있다. `if` 안에서 바깥 변수를 move하면 `Can only move variable declared in the same block.`
  이 제약 덕분에 "어느 분기에서만 move됐는가"를 추적하는 런타임 drop flag가 필요 없다. 코드가 위에서 아래로 한 번 훑는 sema 상태만으로 충분하다.
- 참조 매개변수(`^T` 등 object 타입)는 move할 수 없다: `Cannot move a reference parameter.` (매개변수가 호출자 소유이기 때문이다.)
- 값 매개변수는 move할 수 있다. `fn put(v Array[int]): ... move v`는 컴파일된다.
- 함수 인자로 `move a`를 넘기면 그 함수가 소유한다(`consume(move a)` 뒤 `a`는 죽음).
- `sink` 매개변수는 호출 지점에 `move`를 안 써도 인자 변수를 죽인다(`sink_use_arg_after_error.cy`, `sink_use_rec_after_error.cy`). 문서가 "move와 크게 다르지 않아 제거될 수 있다"고 적은 기능이다.
- 함수에서 지역 변수를 `return`하면 암시적 move다(fork 커밋 `eb060d5e`, 2.3절).

#### 빌림: `&T`, `&&T`, `scope`

- `&x`는 값의 주소를 빌린다. 스택의 지역이면 스택 슬롯 주소, 필드나 원소이면 그 내부 주소다(`.addr: %2 = *%1` 형태의 명령). 소유자는 여전히 `x`다.
- `&T`는 읽기/쓰기가 모두 된다. 같은 값에 대한 `&` 두 개로 번갈아 쓰기를 해도 컴파일된다(실습 5).
- `&&T`(배타적 빌림)는 크기를 바꾸는 연산을 위한 것이다. `Array`의 `append`, `insert`, `clear` 등이 `fn (&&Array[]) append(...)`로 선언되어 있고(`core.cy:1784`),
  `a.append(4)`처럼 부르면 컴파일러가 자동으로 `&&a`를 얻는다. 에러 메시지에서는 `&&T`가 `&>T`로 인쇄된다("Expected type `&>Array[int]`. Found `^Array[int]`.").
- 빌림을 반환하려면 반환 타입 앞에 `scope`를 쓰고, 정확히 하나의 매개변수에도 `scope`를 붙여 "반환값은 그 인자와 같은 수명"이라고 묶어야 한다.
  어기면 "Returning a borrow requires a `scope` modifier.", "Missing `scope` parameter.", "Expected only one parameter with the `scope` modifier." 중 하나다.
- 빌림은 `^`로 올릴 수 없다: "Cannot lift the borrow type `&int`."

실제 검사가 문서의 설명만큼 엄격하지는 않다. 구현은 2.3절 "빌림 검사"에, 실험 결과는 실습 5에 있다.

#### `@deinit`과 소멸 순서

관찰한 규칙(실습 3): (1) 블록 끝에서 지역 변수는 선언의 역순으로 정리된다. (2) 구조체는 자기 `@deinit`이 먼저, 그다음 필드가 선언 순서로 정리된다.
(3) 재대입은 새 값을 계산한 뒤 옛 값을 정리하고 저장한다. (4) 임시 값은 그 문장의 끝에서 정리되지만, `_ = expr`는 숨은 지역을 만들어 블록 끝까지 산다.

### 2.3 컴파일러 층: sema가 소유권을 코드로 심는 방법

소유권 전용 패스는 없다. sema가 식과 문장을 한 번 훑으면서 아래 자료구조를 갱신하고, 그 자리에서 IR을 낸다(전체 흐름은 [03](03-sema-and-ir.md)).

#### 자료구조 세 가지

- `ExprResult`(`sema.zig:3590` 근처)의 두 비트. `owned`는 "이 식의 결과는 새로 만들어진 소유 값(rvalue)이라 그대로 넘겨도 된다", `addressable`은 "지역/필드라서 주소를 취할 수 있다".
- `Local`(`sema.zig:102`). `decl_t`(타입), `lifetime`(`block` / `temp` / `inout`), `active_borrows`(이 값을 가리키는 `&` 개수), `has_inactive_struct_fields`(부분 이동됨), `type`(`.local` 또는 `.dead`).
  지역들은 `c.varStack`에 쌓이고, 함수마다 시작 위치(`proc.varStart`)가 있다.
- `Block.varStart`(`sema.zig:178~180`). 블록이 시작할 때의 `varStack` 길이. 블록을 닫을 때 그 위의 지역을 거꾸로 정리한다.

#### 규칙 1: 값을 "저장하는 자리"마다 `semaOwn`

변수 선언(`localDecl`, 3450), 대입, 필드 초기화, 함수 인자, 반환값이 모두 `semaOwn`을 거친다.

```zig
// src/sema.zig:5829
pub fn semaOwn(c: *cy.Chunk, expr: ExprResult, node: *ast.Node) !ExprResult {
    if (expr.owned) {
        return expr;
    }
    return sema_copy(c, expr, node);
}
```

이미 소유한 값(rvalue, 함수 반환값, `move`한 값)이면 그대로, 아니면 `sema_copy`(5750)가 타입에 따라 갈린다.

1. `type.info.no_copy`이면 `Cannot copy ...` 컴파일 에러.
2. `hasCopyCtor()`가 false이면(정수, 비관리 구조체) 식을 그대로 쓴다. 바이트 복사이므로 IR이 달라질 게 없다.
3. `^T`이거나 함수 값이고 사용자 `@copy`가 없으면 IR `.retain` 노드. 복사는 곧 rc 증가다.
4. 그 외(`str`, `Slice`, 관리 필드를 가진 구조체)는 `getCopyFunc`로 얻은 `@copy[T]` 호출을 IR에 낸다(9974줄, 템플릿 인스턴스를 타입에 캐시).
   `str`의 `@copy`는 코드젠 단계에서 `copy_str` 한 개 명령으로 바뀐다(2.4절).

복사할 값이 addressable이 아니면 `Unexpected value with managed type is not addressable.` 에러가 난다(`sema_copy` 안). rvalue는 보통 owned라서 여기까지 오지 않는다.

#### 규칙 2: 임시 값은 숨은 지역으로, 문장 끝에서 정리

소유한 값이 어디에도 저장되지 않고 쓰이면(예: `show(&make('x'))`, `'%{make().name}'`) 누군가 정리해야 한다. `semaManage`가 숨은 지역 `_temp`를 만든다.

```zig
// src/sema.zig:5816
pub fn semaManage(c: *cy.Chunk, expr: ExprResult, node: *ast.Node) !ExprResult {
    if (!expr.type.isManaged()) { return expr; }
    if (!expr.owned) { return expr; }
    const tempv = try declareHiddenLocal(c, "_temp", expr.type, expr, node);
    c.varStack.items[tempv.id].lifetime = .initTemp();
    return semaLocal(c, tempv.id, node);
}
```

문장 하나를 분석하는 함수(`localDecl`, `semaExprStmt`, 대입 등)는 시작 때 `var_start = c.varStack.items.len`을 기억하고 끝에서 `popLocals(c, var_start, node)`를 부른다(306, 310).
`popLocals2`는 그 위의 지역을 거꾸로 돌며 `semaDestructLocal`을 부르고 `pop_locals` IR을 낸다. 그래서 임시 값은 문장 끝에서 사라진다.
`_ = expr`만 예외다. `localDecl`(3450)에서 이름이 `_`이면 숨은 지역을 `reserveLocalName`으로 만들어 블록 끝까지 두기 때문이다(실습 3에서 확인).

#### 규칙 3: 지역을 정리하는 방법은 타입이 정한다

`semaDestructLocal`(4702)이 이 장의 중심이다. 지역의 `decl_t`를 보고 다음 중 하나를 IR로 낸다.

| 지역의 타입 | 내는 IR | 이후 바이트코드 |
|---|---|---|
| 비관리 타입 | 없음 | 없음 |
| 일반 함수의 `^T`/함수 값 매개변수 | 없음(호출자가 관리) | 없음. 제너레이터 함수의 매개변수만 예외 |
| `str` | `@destruct[str]` 호출 | `dtor_str` 한 개로 치환 |
| `^T` | `release` stmt(`deinit_obj` = `@deinitObject[T]`) | `release` 명령 + 0이 되면 `call @deinitObject` |
| 함수 값(클로저) | `release` stmt | 위와 같음 |
| `?^T` (zero_union) | `release` stmt, `optional = true` | `release_opt` 명령 |
| 그 밖의 option / choice / result / vector / `Ptr[T]`(`@deinit` 있음) | `@destruct[T]` 호출 | 인라인되거나 `call` |
| struct | 부분 이동이 있으면 `@partial_destruct`, 아니면 `@destruct[T]` 호출 | 위와 같음 |

`^T`만 `release` stmt를 쓰고 나머지는 일반 함수 호출로 풀리는 점이 요점이다. 호출되는 `@destruct[T]`는 `core.cy:2869`에 있는 Cyber 코드이고 컴파일 타임에 타입별로 펼쳐진다(2.4절).

#### 정리 코드가 박히는 위치

`semaDestructBlock2`(4794)는 블록의 지역을 역순으로 `semaDestructLocal`에 넘긴다. 이 함수를 부르는 곳은 다음과 같다.

- 블록이 정상적으로 끝날 때 `popBlock2`(4810). 그 블록 끝에 도달할 수 있을 때만(`endReachable`).
- `break`/`continue`(791, 811): 빠져나가는 루프 블록의 지역.
- `return`(829, 880): 함수 전체 블록의 지역. 반환값을 먼저 저장하고(`set_ret`) 정리한 뒤 `ret`을 낸다.

```zig
// src/sema.zig:829~870 semaReturnExpr 의 끝부분 (줄 바꿈만 줄여 옮김)
    _ = try c.ir.pushStmt(.set_ret, node, .{ .right = expr.ir });
    // TODO: Optimize to a single `ret_expr` if there were no destructors emitted.
    const b = c.procBlock();
    try semaDestructBlock2(c, b);
    if (c.proc().func == null) { try sema_program_deinit(c); }
    _ = try c.ir.pushStmt(.ret, node, .{ .return_value = true });
    c.block().endReachable = false;
```

즉 "return마다 정리 코드를 복제"하는 방식이다. 컴파일된 모습(`cyber compile`, 지역 `r Res`(`@deinit` 있음)와 `s str`을 가진 함수가 `return` 두 개를 가질 때):

```
0:233 .mov: %0 = %5                      -- set_ret: 반환 슬롯에 n 저장
0:236 .addr: %13 = *%9
0:239 .dtor_str: destruct [%13]          -- s (마지막에 선언한 것부터)
0:241 .addr: %13 = *%6
0:244 .mov: %18 = %13
0:247 .call: Res.@deinit(%18..%19) 0     -- r 의 @deinit 먼저
0:252 .add_i16: %14 = %13 + 0
0:256 .dtor_str: destruct [%14]          -- 그다음 필드 r.name
0:258 .ret:
```

`return` 경로마다 이 덩어리가 한 번씩 나온다(실습 8). 런타임에는 "정리 테이블"이 없고, 정리는 평범한 명령어 열이다. 패닉이 중간에 일어나면 이 열은 실행되지 않는다(2.7절).

main 블록은 조금 다르다. `shouldGenMainScopeReleaseOps`(4802)가 `!single_run and !persist_main`일 때만 main 최상위 지역의 정리를 낸다.
`popBlock2`가 `proc.func == null and block_depth == 1`에서 정리를 건너뛰기 때문이다. `single_run`은 ReleaseFast CLI가 켠다(`src/main.zig:161`: `config.single_run = builtin.mode == .fast`).
이 문서의 `cyber`는 ReleaseSafe라서 main 지역이 정상적으로 정리된다(ReleaseFast에서 `@deinit`이 안 도는 현상은 코드 근거이고 실행해 보지는 못했다).

한 가지 더. `sema_program`(4555)은 main 문장을 다 분석한 뒤 `sema_program_deinit`(전역 정리)을 먼저 내고 `popProc`이 main 지역을 정리한다.
그래서 정상 종료에서는 전역 변수의 `@deinit`이 main 지역보다 먼저 돈다(실행 확인: `global g Res`, `local := Res{...}`에서 `deinit global`이 `deinit main-local`보다 먼저 나왔다).

#### 규칙 4: 재대입은 "새 값 → 옛 값 정리 → 저장"

`semaAssignStmt`(1589)의 `.ident` 분기를 읽으면 순서가 보인다. 오른쪽을 평가해 `semaOwn`하고, 관리 타입이면 숨은 `_temp`에 담은 다음
`semaDestructLocal(옛 변수)`를 내고 마지막에 `set_local`로 `_temp`를 옮긴다(`_temp`는 `.dead`로 표시해 이중 정리를 막는다). 필드(`semaAssignToAccessStmt`, 1464),
`*p = v`(`.deref` 분기), 전역(`semaAssignToGlobal`, 1560)도 같은 패턴이다. 새 값 계산이 끝난 뒤에야 옛 값을 건드리는 순서다(의도는 추정).

#### 규칙 5: move와 부분 이동

`move_expr`(7422)를 줄여 읽으면 이렇다.

```zig
// src/sema.zig:7422~ (발췌)
var res = try semaExpr(c, child, .{});
const field_access = try build_move_access_path(c, res, child);
if (c.temp_access_path.var_id < c.block().varStart) {
    return c.reportError("Can only move variable declared in the same block.", child);
}
const local = &c.varStack.items[c.temp_access_path.var_id];
if (local.inner.local.isParam and local.decl_t.isObjectLike()) {
    return c.reportError("Cannot move a reference parameter.", child);
}
if (!field_access) { res.owned = true; local.type = .dead; return res; }   // 통째로 move
// ... 멤버 move: var_active_struct_fields[var_id][필드 오프셋] = false
```

통째로 move하면 지역의 `type`을 `.dead`로 바꾸고 결과를 `owned`로 표시한다. 이후 `semaLocal`(4003)이 죽은 지역을 만나면 `` `a` is no longer alive in this scope. ``를 낸다.
죽은 지역은 `semaDestructLocal`이 `type != .local`이라서 건너뛰므로 move한 값은 정리되지 않는다. 새 주인이 정리한다.

멤버 move(`move s.b`, `move s.c.!a`, `move s.d.?`)는 구조체 하나당 `[]bool` 상태 벡터(`proc.var_active_struct_fields`)를 두고 해당 칸을 false로 만든다.
이 벡터는 `ensure_partial_struct_layout`(2138)이 `PartialStructLayout` 값으로 중복 제거하고, 지역이 정리될 때 `get_partial_dtor`(9983)가
`@partial_destruct(T, Layout, ptr)`(`core.cy:2836`) 템플릿을 그 레이아웃으로 펼친다. 템플릿 안의 `Layout.is_field_active(offset)`이 컴파일 타임 상수라서
"어느 필드를 정리하는가"가 인스턴스마다 고정된 코드가 된다. 죽은 멤버를 읽으면 `Member is no longer alive.`(`check_struct_access_path`, 2129).
`^T` 안의 멤버를 move하려 하면 `Cannot move a member from a shared reference.`(`build_move_access_path`, 2152).

한계: 정리 템플릿이 구조체 필드마다 `#if Layout.field_layout(...) |layout|:`(`core.cy:2849`)를 쓰는데, 이 형태의 컴파일 타임 `if` 언랩을 `ct_inline.zig:309`가 지원하지 않는다.
결과적으로 구조체 필드(`str` 포함)를 가진 관리 구조체의 부분 이동은 컴파일되지 않는다(7절 이슈 4, 실습 2).

#### 규칙 6: 함수 호출 인자 — 누가 소유하는가

`sema_func.zig:817`의 `ownOrManageArg`가 호출 규약의 전부다. 실제 호출 경로인 `matchArg`(`sema_func.zig:1259`)가 인자마다 부른다.

```zig
// src/sema_func.zig:817~833
pub fn ownOrManageArg(c: *cy.Chunk, arg: sema.ExprResult, node: *ast.Node) !sema.ExprResult {
    if (arg.resType == .infer_error) { return arg; }
    // Object types are managed from the caller side.
    // Other types are copied and managed from the callee side.
    if (arg.type.isObjectLike()) {
        if (arg.resType == .value_local) {
            return arg;
        } else {
            const res = try sema.semaOwn(c, arg, node);
            return sema.semaManage(c, res, node);
        }
    } else {
        return sema.semaOwn(c, arg, node);
    }
}
```

- 객체형 타입(`^T`, 함수 값; `Type.isObjectLike`, `types.zig:285`)은 호출자가 관리한다. 인자가 지역 변수 그 자체이면 rc를 올리지 않는다(+0). 지역은 호출이 끝날 때까지 살아 있기 때문이다.
  그 밖의 식(`a.a`처럼 필드, rvalue)은 `semaOwn` + `semaManage`로 retain하고 문장 끝에 release한다. `call_with_ref_rvalue.cy`가 이유를 보여 준다. 필드 인자를 retain하지 않으면 피호출 함수가 `parent.a = ^234`로 필드를 바꾸는 순간 `param`이 해제된다.
- 그 밖의 타입(`str`, 구조체, `Array` 등)은 호출자가 복사해(`semaOwn`) 넘기고, 피호출 함수가 매개변수를 소유해 끝에서 정리한다(`semaDestructLocal`에서 일반 함수의 객체형 매개변수만 건너뛰는 이유).
- `sink` 매개변수는 `resolveRtArg`(`sema_func.zig:835` 근처)가 인자 지역을 죽이고 `owned = true`로 표시한다.
- 같은 규약이 호스트 함수에도 적용된다(2.8절).

+0 전달에는 구멍이 있다. 호출자의 지역을 +0으로 넘기면서 같은 지역의 `&`도 함께 넘기면, 피호출 함수가 그 빌림으로 재대입할 때 첫 인자의 객체가 해제된다(실습 5).

#### 규칙 7: 빌림 검사

- `&x`(`semaBorrow`, 8779)는 `x`를 addressable로 만들고(임시이면 `_temp`) 빌림 타입의 `address_of` IR을 낸다. 그리고 소유 지역의 `active_borrows`를 1 올리고 결과에 `parent_local`(소유 지역)을 기록한다.
- `&&x` 또는 `&&` 수신자(`sema_ex_borrow2`, 8750)는 소유 지역의 `active_borrows > 0`이면 "Expected exclusive access. There is another active borrow to `a`."로 거부한다.
- 호출 결과의 수명: 시그니처에 `scope` 매개변수가 있으면 `matchFuncSig`(`sema_func.zig:504`)가 그 인자의 `parent_local`을 호출 결과의 `parent_local`로 이어 준다.
  `localDecl`(3495)은 빌림 값이 `temp` 수명 지역에 매여 있으면 "Cannot assign to local `b` with a value that has a shorter lifetime."로 거부한다(`foo(&123)`처럼 `&123`이 임시 지역을 만드는 경우).
  `semaReturnExpr`(829)는 `scope` 함수가 반환하는 빌림의 `parent_local`이 `scope` 매개변수인지 확인한다("Expected to return a borrow from the same scope as `c`.").

실제로 돌려 보면 이 검사는 Rust의 NLL(마지막 사용까지만 빌림이 산다)과 다르다. `popLocals2`(322)에는 빌림을 쥔 지역이 사라질 때 `active_borrows`를 줄이는 코드가 있지만,
`Local.parent_local`(120)은 선언 때 `cy.NullId`(4926)로만 초기화되고 다른 곳에서 대입되지 않아 이 감소는 실행되지 않는다. 그래서 같은 변수에 한 번이라도 명시적 `&`를 취하면,
그 빌림이 끝난 뒤에도 같은 함수에서 이후의 `&&` 연산(`a.append(4)` 등)이 모두 컴파일 에러가 된다(실습 5). 반대 방향(`&&`를 쥔 상태에서 `&` 취득)은 검사하지 않는다.

#### IR에서 바이트코드로

`ir.zig`에서 소유권에 관여하는 노드는 몇 개뿐이다. stmt `release`(`ir.Release{reg, optional, deinit_obj}`, `ir.zig:276`), expr `retain`(283), `lift`(288), 그리고 일반 `call`(destruct/copy 호출).
`bc_gen`의 번역은 기계적이다.

- `gen_lift`(`bc_gen.zig:913`): `new` 명령으로 힙 객체를 만들고(`push_new(dst, child_t, size)`) 값을 저장한다. 자식이 `init` 리터럴이면 객체에 바로 필드를 쓴다.
- `gen_retain`(1246): 자식을 만든 뒤 `retain reg`.
- `gen_release` -> `pushRelease`(3040): `release slot, <점프>` 다음에 `mov ret+4, slot; call @deinitObject[T]`를 이어 붙이고 점프 거리를 되돌려 쓴다(`optional`이면 `release_opt`).
  VM의 `Release`는 rc를 줄여 0이 아니면 점프로 호출을 건너뛰고, 0이면 다음 명령(= `@deinitObject` 호출)으로 떨어진다(`vm.c:887`).
- `gen_call`이 `info.gen_intrinsic`이 켜진 함수를 만나면 `genCallIntrinsic`(1333)이 `dtor_str`/`cmp_str`/`copy_str`로 치환한다(`genAll`, `bc_gen.zig:84~90`).

`^123`을 만들어 `b := a`로 복사하는 프로그램의 바이트코드(`cyber compile rc1.cy`, main 부분)가 이 모두를 보여 준다. 덤프의 `byte{size=1}`은 `NEW`의 피연산자(`vm.c:1269`: 타입 id, 크기)를 덤퍼가 인쇄한 표기이고 정확한 읽는 법은 확인하지 못했다.

```
0:75  .new: %1 = byte{size=1}            -- ^123: 힙 객체 할당, rc=1
0:79  .store_64: [%1 + 0] = %2
0:83  .mov: %2 = %1                      -- b := a  (복사 = 포인터 복사 ...
0:86  .retain: %2.rc += 1                --  ... + retain)
   ...
0:117 .call: core.@deinit(%7..%7) 148    -- sema_program_deinit 이 낸 종료 훅 호출(전역 정리)이 먼저
0:122 .release: %2.rc -= 1; jmp 9        -- b 해제(마지막 선언부터)
0:125 .mov: %7 = %2
0:128 .call: core.@deinitObject(%7..%8) 3
0:133 .release: %1.rc -= 1; jmp 9        -- a 해제
0:136 .mov: %7 = %1
0:139 .call: core.@deinitObject(%7..%8) 3
```

### 2.4 런타임 층: 힙, 헤더, 해제 경로

#### 객체의 실제 메모리 모양

힙 객체는 8바이트 헤더(`meta: u32`, `rc: u32`)와 그 뒤의 본문으로 이루어지고, `^T` 값(스택의 8바이트 슬롯)은 본문의 시작 주소를 가리킨다. 헤더는 값 주소 - 8에 있다
(`HeapObject.header()`, `heap.zig:582`. `vm.h:117`의 `VALUE_AS_OBJHEADER`). `meta`의 하위 28비트가 타입 id다(`TYPE_MASK`, `vm.h:83`).
`EXTERNAL_TYPE_BIT`, `GC_MARK_BIT`도 정의돼 있지만 쓰는 코드가 없어서 0.3 GC의 잔재다(`GC_MARK_BIT`를 읽는 `markValue`(`thread.zig:1213`)도 호출처가 없다). 값 크기가 32바이트 이하인지에 따라 두 곳 중 하나에 할당된다.

```
풀 객체 (본문 <= 32바이트)                               큰 객체 (본문 > 32바이트)
HeapPage = 102 x PoolObject (4080바이트)                allocator 블록 하나 (본문 + 16바이트)
+------------+--------------------------+              +-----------+------+------+---------------+
| meta | rc  |  data[32]                |              | obj_addr  | meta | rc   | 본문 ...      |
| u32  | u32 |  (본문, 8바이트 정렬)    |              | u64       | u32  | u32  |               |
+------------+--------------------------+              +-----------+------+------+---------------+
 ^ 값 주소 - 8   ^ ^T 값이 가리키는 곳                  |                           ^ ^T 값이 가리키는 곳
                                                         +-> 풀의 "포인터 객체"를 가리킴
                                                             (meta = BigObjectPtrType = 0xFFFFFFFE,
                                                              rc = 0, data.pointer.ptr = 본문 주소)
빈 슬롯: meta = 0xFFFFFFFF(NullId), data 의 둘째 8바이트가 free list 의 next
```

- 풀: `PoolObject = {head: 8, data: [32]u8}`(`heap.zig:518`), `HeapPage`는 102개(`:524`, "4KB 바로 밑"이라는 주석). 빈 슬롯은 연결 리스트(`heapFreeHead`)로 이어지고,
  `freePoolObject`(219)는 해제한 슬롯을 리스트 앞에 끼운다(비트레이스 빌드의 MRU). 리스트가 비면 페이지를 지금까지 쌓인 수만큼 더 만든다(`growHeapPages(@max(1, pages.len))`, 1074).
  `allocPoolObject`(1072)는 `meta = type_id, rc = 1`로 쓴다. 새 객체의 rc가 1이라는 점이 "owned 값은 +1을 이미 갖고 나온다"는 sema의 가정과 맞물린다.
- 큰 객체: `allocBigObject`(1015)가 allocator에서 `size + 16`바이트를 잡고 앞 16바이트에 `{obj_addr, meta, rc}`를 쓴다. 풀에도 슬롯 하나(포인터 객체)를 잡아
  본문 주소를 저장한다. 이유는 코드에 적혀 있지 않지만, 힙 전체를 훑는 코드(`freeHeapPages`, `count_objects`)가 페이지만 돌면서 큰 객체도 찾으려는 것으로 보인다(추정).
  `freeBigObject`(189)는 포인터 객체를 풀에 돌려주고 allocator로 블록을 반납한다.
- 분기 기준은 `size <= 4 * 8`이고 한 곳이 아니다. `NEW` 명령(`vm.c:251`의 `allocObjectInit`), Zig의 `new_object_undef`(`heap.zig:1539`), 해제 쪽 `freeObject`(209)가 같은 기준을 쓴다.
  `NEW`의 크기 피연산자가 `u16`이라 한 번에 만드는 힙 객체가 65535바이트를 넘을 수 없다(코드 근거, 큰 구조체는 미실험).
- allocator: CLI는 Debug가 아니고 wasm/MSVC가 아니면 mimalloc, Debug는 Zig의 `SafeAllocator`(`build.zig:436~448`, `cli.zig:686~740`). libcyber는 `cl_vm_init`에서 `std.heap.c_allocator`(libc malloc)를 쓰고(`lib.zig:28`),
  `cl_vm_initx`로 호스트 할당자를 주입할 수 있다.
- 스레드마다 `Heap`이 따로 있고(`Thread.heap`) `rc` 증감은 비원자적 일반 연산이다(`vm.c:92~143`의 `head->rc -= 1`). 스레드 사이로 `^T`를 공유하지 않는다는 전제다. 자세한 것은 [07](07-coroutines-concurrency.md).

`Array`/`Map`이 쓰는 원시 버퍼는 이 힙 객체가 아니다. `alloc(T, n)`은 `new_byte_buffer`(`heap.zig:1249`)로 가서 allocator에서 바로 받고, 포인터와 크기를 `Heap.buffers` 해시 맵에 등록한다.
이 맵 덕분에 패닉/종료 때 새는 버퍼를 일괄 해제할 수 있고(`freeAllBuffers`, 136), `Heap.deinit`(97)은 남은 버퍼가 있으면 `Unfreed raw buffers: N`으로 패닉한다(실습 7에서 관찰).
버퍼 할당마다 해시 맵 삽입/삭제가 따라붙는 비용이 있다(성능 영향은 미측정).

#### retain / release 명령

```c
// src/vm.c:887 (Release) — 줄 정리
CASE(Release): {
    if (!releaseOnly(t, (HeapObject*)(size_t)stack[pc[1]])) {   // rc -= 1, 0 이면 true
        pc += (uintptr_t)(int16_t)pc[2];                        // 0 이 아니면 정리 코드를 건너뜀
        NEXT();
    }
    pc += 3;                                                     // 0 이면 바로 뒤의 mov + call @deinitObject 로 진입
    NEXT();
}
```

`Retain`(`vm.c:1518`)은 `rc += 1`만 한다. nullable용 `RetainNZ`(1510), `ReleaseOpt`(875)가 있다. 해제 자체는 VM이 하지 않는다. VM은 rc를 0으로 만들고 "다음 명령으로 떨어질 뿐"이고,
객체를 파괴하는 일은 바이트코드로 컴파일된 Cyber 함수 `@deinitObject[T]`가 한다. trace 빌드에서만 `releaseOnly`가 이중 해제(`zCheckDoubleFree`)를 검사하고 전역 `refCounts`를 갱신한다.

#### 파괴 경로는 두 벌이다

| | A. Cyber 템플릿 | B. Zig 미러 |
|---|---|---|
| 위치 | `core.cy:2798`(`@deinitObject`), `2869`(`@destruct`), `2836`(`@partial_destruct`) | `heap_value.zig:634`(`destroyObject`), `:404`(`destructValueAt`) |
| 부르는 쪽 | 컴파일된 코드(스코프 끝, `release` 명령 뒤) | C의 `release()`(`vm.c:144`, 실사용은 `DTOR_STR`뿐), 호스트 API(`cl_str_deinit`, `cl_slice_deinit`), 컴파일 타임 값, 패닉 스윕 |
| 사용자 `@deinit` | 호출한다 | 호출하지 않는다. 필드만 순회한다 |
| 만든 이유 | 타입별로 모양이 다른 정리를 Cyber 코드로 표현 | 컴파일 타임 평가와 호스트 바인딩이 "단순한 타입"을 다루기 위해(`heap.zig:35~37` 주석) |

두 구현이 같은 일을 하도록 사람이 맞춰야 한다는 점이 유지보수 위험이다. 예를 들어 `Slice.@deinit`은 원소를 `@destruct`로 정리하지만 호스트의 `cl_slice_deinit`은 `destructValueAt`을 쓰므로
원소 타입에 사용자 `@deinit`이 있으면 호스트 쪽 경로에서는 돌지 않는다(`lib.zig:166~180`, 코드 근거).

`@destruct`가 하는 일(발췌, `core.cy:2869` 이하):

```cy
fn @destruct(%T type, val Ptr[T]):
    -- @deinit is invoked before any child destructors.
    -- This lets the parent read from the children when they are still alive.
    #if meta.has_decl(T, '@deinit'):
        val.@deinit()

    #switch type.info(T):
        #case .struct |struct_t|:
            #for 0..struct_t.fields.len() |i|:
                #field := struct_t.fields[i]
                #if type.managed(field.type):
                    @destruct(field.type, *meta.access(val, field.name))
        #case .option |option_t|:
            if !meta.is_none(val):
                @destruct(option_t.child, *meta.access_option_payload(val.*))
        #case .ref |ref_t|:
            obj := (as[Ptr[Ptr[void]]] val).*
            if @releaseOnly(obj):
                @deinitObject[ref_t.child](obj)
```

`#for`/`#if`/`#switch`는 컴파일 타임에 펼쳐지므로 타입마다 군더더기 없는 함수가 생긴다(필드가 비관리이면 호출 자체가 없다. fork 커밋 `c307197b`의 최적화). 순서 규칙은 이 코드에서 나온다.
`@deinit` -> 필드 선언 순서 -> 필드가 `^T`이면 `@releaseOnly` 후 0이 됐을 때만 `@deinitObject`. 그리고 `@deinitObject[T]`(2798)는 `@destruct(T, obj)` 후 `@freeObject(obj, 크기)`로
메모리를 돌려준다(`@size()`가 있는 타입은 가변 크기, 없으면 `type.size(T)`; 함수 값은 캡처 수만큼 따로 계산).

```
 ^Node 지역이 스코프를 벗어남
   semaDestructLocal -> ir.release(deinit_obj = @deinitObject[Node])
        |
   [VM] Release: rc -= 1
        |-- rc > 0 --> 끝 (다른 소유자가 남아 있음)
        `-- rc == 0 --> call @deinitObject[Node](obj)
                          |- @destruct(Node, obj)
                          |    |- Node.@deinit()            (사용자 정의가 있으면)
                          |    `- 필드 순서대로 @destruct
                          |         |- name: str    -> dtor_str -> [C] release(buf) -> destroyObject(StrBuffer)
                          |         `- next: ?^Node -> release_opt(next) -> 0 이면 @deinitObject[Node](next) (재귀)
                          `- @freeObject(obj, 32) -> Heap.freeObject -> 32바이트 이하이므로 풀 슬롯 반환
```

연결 리스트처럼 긴 `^` 체인은 정리가 재귀로 이어진다. 깊이에 대한 보호 장치는 코드에서 찾지 못했다(스택 깊이 한계는 미실험).

### 2.5 표준 컨테이너의 메모리 설계

이 컨테이너들은 `core.cy`에 Cyber로 쓰여 있고, 위 규약(복사/이동/정리)을 사용자와 같은 규칙으로 따른다. 크기는 `type.size`로 실측했다(실행 확인):
`str` 24, `[]int`(Slice) 32, `Array[int]` 24, `Map[str, int]` 48, `^int` 8, `?^int` 8(null 포인터로 none 표현), `?int` 16, `&P` 8, `[&]int`(Span) 16.

#### str: 슬롯 세 개 + 정적/힙 이원화

```
str (24바이트, 스택 슬롯 3개)
+----------------+----------------+------------------------------+
| buf ?^StrBuffer| ptr Ptr[byte]  | header: 하위 63비트 = 바이트 길이, 최상위 비트 = ASCII 힌트 |
+----------------+----------------+------------------------------+
정적 문자열:  buf = 0, ptr -> 바이트코드 상수 영역     (정리할 것 없음)
힙 문자열:    buf -> StrBuffer{length, 바이트...}, ptr -> 그 버퍼 안
부분 문자열:  같은 buf 를 retain 하고 ptr/len 만 다름 (복사 없음, string.zig:86 sliceFn)
```

- 리터럴은 `CONST_STR`(`vm.c:624`)가 `buf = NULL`로 만든다. 상수는 바이트코드 버퍼에 있고, 명령은 48비트 포인터와 16비트 길이를 한 u64에 담는다(`bc_gen.zig:1272`).
  그래서 `DTOR_STR`(`vm.c:895`)은 `buf != 0`일 때만 release하고, `COPY_STR`(904)은 `buf`가 있을 때만 retain한다. 상수 문자열의 복사/정리는 비용이 사실상 0이다.
- 힙 문자열의 버퍼 `StrBuffer`는 `RawBuffer[byte]`(`{length, 바이트...}`)이고 `8 + 길이`가 32 이하이면 풀, 아니면 큰 객체다(`newStringBufferUndef`, `heap.zig:1236`). 즉 24바이트까지가 풀이다.
- `dtor_str`의 해제는 2.4의 B 경로를 탄다. C `release()` -> `zDestroyObject` -> `destroyObject`의 `bt.StrBuffer` 분기(`heap_value.zig:672`)가 풀/큰 객체를 판단한다. 문자열이 가장 자주 해제되는 경로라서 Cyber 템플릿을 거치지 않게 한 것으로 보인다(추정).
- 실험에서 발견한 문제: 리터럴 길이가 16비트로 잘린다. 70000바이트 리터럴(`s := 'aaaa...'`)을 만든 뒤 `s.len()`을 찍으면 `4464`(= 70000 mod 65536)가 나온다. `bc_gen.zig:1272`의
  `@as(u64, res.slice.len) << 48`이 상위 비트를 버리기 때문으로 읽힌다(실행 확인, 원인은 코드 근거). [04](04-bytecode-gen.md)의 영역이지만 메모리 안전(범위를 넘긴 읽기가 없는지)과 닿아 있다.

문자열 보간(`'a %{x} b'`)은 fork가 단일 할당으로 바꿨다(`docs/decisions/project_string_interpolation.md`). 컴파일러는 조각 `[N+1]str`과 인자 `[N]str`을 스택에 만들어 `str.interpolate(strs, args)`를 부르는데,
이 함수는 `#[bind='str.interpolate']`라서 `string.zig:37`의 Zig 구현이 실행된다. 모든 조각 길이와 ASCII 여부를 먼저 합산해 `init_astr_undef`/`init_ustr_undef`를 한 번 호출하고 `@memcpy`로 채운다.
`core.cy:3313`의 스크립트 본문(`res += arg`를 반복, 할당 2N번)은 `#[bind]`가 있을 때는 쓰이지 않는 참고용이다. 두 `[&]str` 매개변수는 빌림이라 이 함수는 해제하지 않는다.

#### Slice: 공유 버퍼 + 버퍼 안의 초기화 개수

```
Slice[T] (32바이트)                                   버퍼 (^RawBuffer[byte])
+---------------+---------+------+---------------+    +--------+-----------------------------+
| buf ?^RawBuf  | ptr     | _len | header        |    | length | count | e0 | e1 | e2 | ...    |
+---------------+---------+------+---------------+    +--------+-----------------------------+
   |   MSB(63) = 부분 슬라이스 여부, 나머지 = 용량             ^8바이트   ^ ptr 는 e0 를 가리킴
   `-----------------------------------------------------> count = 초기화된 원소 수 (ptr[-1] 위치)
```

- 복사(`b := a`)는 `buf`만 retain하는 얕은 복사다. 실험: `b := a.append(4)` 뒤 `b[0] = 100`을 하면 `a[0]`도 100이다(`a.len=3`, `b.len=4`, 버퍼 공유).
  `append`는 `clone_on_resize`(`core.cy:1250`)가 버퍼를 유일하게 쥐고 있고 용량이 남으면 새 버퍼 없이 `self.*`(복사 = retain)를 돌려주기 때문이다.
  두 번째 `a.append(5)`는 버퍼 rc가 2라서 복사한다(`e[0] = 77`이 `c[0]`에 안 보임).
- `Slice.@deinit`(1094)은 `buf`가 유일 참조일 때 `_len`이 아니라 버퍼 앞 8바이트의 count만큼 원소를 정리한다. 길이가 다른 두 Slice가 한 버퍼를 나눠 가질 수 있어서
  "마지막 소유자가 가장 길게 초기화된 곳까지 정리"하도록 한 Swift식 설계다(`docs/decisions/project_slice_append_aliasing.md`의 후보 1; Zig 쪽 상수 `SliceBufferElemsOffset = 8`, `heap.zig:1168`).
  버퍼 객체 자체의 해제는 `buf` 필드 정리(`?^RawBuffer` -> `release_opt`)가 맡는다.
- 크기를 바꾸는 연산(`append`, `+`, `insert`, `remove`, `size_down`, `size_up`)은 끝에서 count를 결과 길이로 맞춘다. 관리 원소(`#if type.managed(T)`)일 때만 쓴다(성능 이유, 결정 문서의 측정 참조).
- 문서의 "남는 문제"도 실제로 재현된다: `a := []str{...}; b := a.size_down(0)` 뒤 `a[0]`을 읽으면 이미 정리된 칸을 읽는다. 릴리스 CLI는 쓰레기 문자열과 `index out of bounds` 패닉을 냈고,
  trace CLI는 `retain` 시점에 dangling을 감지했다(7절). `slice_shared_buffer.cy`는 두 빌드 모두에서 누수 없이 통과한다.

#### Array / ArrayStore: 값이지만 복사 불가

`Array[T]`는 `buf Ptr[T]`, `length`, `header`(용량 + 상위 2비트는 `Ex` 빌림 표식) 세 칸의 구조체이고 `with NoCopy`다(`core.cy:1662`). 버퍼는 위에서 본 `alloc`이고 `@deinit`이 원소를 `@destruct`한 뒤 `free(self.buf)`한다(1672).
크기를 바꾸는 메서드는 `&&Array[]` 수신자다. 성장 방식이 이 장의 다른 컨테이너와 다르다.

```cy
// core.cy:1846~1853  Array.ensure_cap (일부)
        new_buf := alloc(T, final_cap).ptr
        -- TODO: Move old elements to new buffer.
        new_buf[0..self.length].init(self.buf[0..self.length])
        #if type.managed(T):
            for 0..self.length |i|:
                @destruct(T, self.buf + i)
        free(self.buf)
```

원소를 복사한 뒤 옛 원소를 `@destruct`한다(TODO 주석이 인정하는 비효율). `append(val T)`(1784)도 `@ptr_init(*self.buf[self.length], val)`로 `val`을 복사한다(`move val`이 아님).
`@deinit`이 부수효과를 가진 원소(파일 닫기 등)에서 이것이 어떻게 보이는지는 실습 6에 있다. 실험 결과를 먼저 말하면 `Array[Res]`(`@deinit`이 출력) 한 원소마다 `@deinit`이 세 번 돈다.
임시 값 정리, 성장 때의 옛 복사본 정리, 최종 정리다. `with NoCopy`인 원소 타입은 아예 `append`할 수 없다(`Cannot copy ...` 에러가 `core.cy:1787`을 가리킨다). 즉 "`@deinit`에 의미가 있는 타입"은
`Array`에 안전하게 담을 수 없다. `Array.clone()`(1808)은 존재하지 않는 `cap` 필드를 써서 컴파일되지 않는다("Field `cap` does not exist in `Array`.", 호출한 적이 없어 드러나지 않았다).

`ArrayStore[T]`(1566)는 `&` 수신자만 쓰는 같은 모양의 컨테이너로 제너레이터 테스트가 쓴다. `append(slice [&]T)`(1619)는 같은 세 줄이 두 번 복붙되어 있어서 `s := ArrayStore[int]{1, 2}; s.append(other[..])`의
길이가 4가 아니라 6이 된다(실행 확인: 1, 2, 10, 20, 10, 20).

#### Map: 세 배열 + 이동하는 성장

`Map[K, V]`는 `HashMap[K, V, AutoHash[K], AutoEq[K]]` 한 필드를 감싼 얇은 래퍼이고(`core.cy:2181`), `HashMap`은 `meta Ptr[byte]`, `_keys Ptr[K]`, `vals Ptr[V]`, `len`, `nvac`, `cap` 여섯 칸(48바이트)이다.
개방 주소법 + 선형 탐사이고 `meta` 바이트가 0(빈 칸) / 1(값) / 2(묘비)다. 적재율은 75%이며 `nvac`은 "성장 전에 더 넣을 수 있는 칸 수"(`new_cap * 75 / 100 - len`, `resize`, 2411)다.

최근 변경(`docs/decisions/project_map_str_hash.md` 3단계, 커밋 `c307197b`)으로 `resize`가 엔트리를 옮긴다. 관리 타입은 `@memcpy`로 비트 이동하고 옛 배열은 destruct 없이 `free`한다.
비관리 타입은 `@ptr_init`이다. 앞의 `Array`와 정반대다. 실험(`Map[int, V]`, V의 `@deinit`이 출력): 성장이 일어나는 삽입에서도 옛 엔트리의 `deinit` 출력이 늘지 않았다(실습 6).
다만 삽입 한 번당 `deinit`이 두 번 찍혔다. `Map.@set_index(key K, val V)`가 값 매개변수 복사를 하나 더 만들고, 그 복사를 다시 `set`에 복사로 넘기기 때문으로 읽힌다(원인은 코드 근거, 호출 수 세기는 미실행).

`src/map.zig`(`ValueMap`)는 이름과 달리 이 `Map`과 무관하다. 저장소 어디서도 import하지 않는 0.3 시절 `cy.Value` 키/값 해시 맵이다(`rg "map\.zig"`가 아무것도 찾지 못한다). 2026-11-06에 삭제했다(F-61).

### 2.6 순환 참조와 누수 탐지: 지금은 "보고도 안 한다"

`^T`끼리 서로를 가리키면 rc가 0이 되지 않아 영영 해제되지 않는다. 0.3은 `performGC()`로 수거했다. 0.4의 현실은 이렇다.

- 수거도 탐지도 없다. 순환을 찾아야 하는 자리는 `Thread.check_memory`(`thread.zig:1018`)인데 본문이 `num_cyc_objects = 0`을 돌려주는 껍데기이고 `TODO: Detect cycles by iterating heap.`만 있다.
  C API `cl_thread_check_memory`(`lib.zig:542`, `cyber.h:520`)가 이것을 노출하지만 호출하는 내부 코드가 없다. `docs/docs.md:2520`의 "safe mode에서 스레드 끝에 탐지하고 패닉한다",
  `@check_cycles()`는 코드에 없다(`rg 'check_cycles'`는 문서만 찾는다). `thread.zig:1213`의 `markValue`는 `setGcMarked()`가 주석 처리된 0.3의 잔재다.
- 순환 테스트 두 개(`gc_reference_cycle_reachable.cy`, `gc_reference_cycle_unreachable.cy`)는 0.3 문법(`var a = List[dyn]{}`, `collectCycles()`)이라 지금은 `ParseError`가 나고,
  `behavior_test.zig:155~156`에서 주석 처리되어 있다(`default_memory.cy`도 같은 이유로 `:153`에서 꺼져 있다). 테스트 폴더에 있다고 해서 현재 동작을 검증하는 것이 아니다.
- Weak reference는 키워드도 라이브러리도 없다(문서는 "TBD").

결과를 직접 봤다(실습 7). 순환을 만든 함수가 끝난 뒤에도 `@deinit`은 돌지 않는다.

| | 릴리스 CLI(`cyber`) | trace CLI(`cyber-trace`) |
|---|---|---|
| 노드 두 개 순환(필드는 `str`뿐) | 아무 출력 없음, exit 0 | `unreleased refcount: 2` + 살아 있는 객체 목록(할당 위치 줄/열, `ev=`) |
| 순환 노드가 `Array[int]`도 가짐 | 마지막에 `panic: Unfreed raw buffers: 2` | 위와 같은 `unreleased refcount: 2` 보고 |
| 순환을 `a.next = none`으로 끊음 | `deinit b`, `deinit a` 정상 | 같음 |

릴리스에서 `Array`가 낀 경우만 소리가 나는 이유는 순환에 걸린 객체(풀 슬롯)는 `Heap.deinit`이 페이지를 통째로 버려서 모르고 지나가지만, 원시 버퍼는 `Heap.buffers` 맵에 남아 `Unfreed raw buffers`에 걸리기 때문이다.
TS 개발자가 조심할 점: 부모 포인터가 있는 트리, 양방향 연결 리스트, 이벤트 핸들러가 자기 소유자를 클로저로 붙잡는 구조는 GC 언어에서는 문제없지만 여기서는 누수다.
자식 -> 부모는 `^`가 아니라 인덱스/id로 두거나, 수명이 끝나기 전에 필드를 `none`으로 끊어야 한다.

누수 도구(모두 trace 빌드, `zig build ... -Dtrace=true`로 만든다):

- 종료 때 `main.zig:246~250`(`compilePath`)과 `:316~320`(`evalPath`)의 `c.TRACE()` 분기가 전역 rc 합계(`thread_rc`)가 0이 아니면 `unreleased refcount: N`과 `thread_dump_live_objects`를 찍는다. 종료 코드는 0이다.
  목록의 `ev=`는 할당 이벤트 번호, 아래에는 소스 위치가 나온다. 이 정보는 `Heap.objectTraceMap`(할당 이벤트, 할당 시점의 pc, 해제 정보; `heap.zig:21`)에서 온다.
- 추적 장치: `vm.zig:32~33`의 상수 `trace_track_object_event`를 `ev=` 값으로 바꿔 다시 빌드하면 그 객체의 retain/release마다 스택 트레이스를 찍는다(`heap.zig:266`, `:287`, 코드 근거. 직접 돌리지는 못했다).
  `-Dlog-mem=true`로 빌드하면 매 retain/release가 `vmc | <rc> +1 | <타입>, <주소>` 형식으로 로깅된다(`vm.c:175~`, `build.zig:649`; 이 챕터의 trace 바이너리는 이 옵션 없이 빌드되어 있어 미실행).
- trace 빌드는 이중 해제(`zCheckDoubleFree`)와 해제된 객체의 retain(`zCheckRetainDanglingPointer`)도 즉시 잡는다. `Slice.size_down` 뒤 읽기 실험에서 후자가 발동했는데,
  보고를 만드는 경로(`zPrintTraceAtPc` -> `debug.indexOfTableEntry`)가 `integer overflow`로 한 번 더 죽었다. 보고기 자체의 버그로 보이며 원인은 조사하지 않았다.
- 자동 테스트의 누수 검사는 한계가 있다. 라이브러리 테스트는 누수 검사 allocator로 VM을 만들지만 풀 페이지는 `Heap.deinit`에서 통째로 반납되므로 풀 객체의 누수는 보이지 않는다.
  그래서 `lib.zig:1259`의 테스트는 32바이트가 넘는 문자열(큰 객체)을 쓴다. `cl_thread_count_objects`도 이 누수를 못 잡았다고 결정 문서에 적혀 있다.

### 2.7 패닉과 종료

#### 패닉: 소멸자 없이 쓸어 담는다

`thread.panic`(`thread.zig:35`)의 순서는 (1) `// TODO: Run stack error destructors.` (2) `unwindStack`으로 스택 트레이스만 기록 (3) `freeHeapPages`(108)다.
`freeHeapPages`는 풀 페이지를 처음부터 끝까지 훑어 빈 슬롯이 아닌 것을 `destroyObject(obj, true)`로 해제한다. `fatal = true`이면 자식 정리를 하지 않으므로
각 객체는 자기 메모리만 반환되고 사용자 `@deinit`은 돌지 않는다. 큰 객체는 풀의 포인터 객체(`meta == BigObjectPtrType`)를 통해 찾는다. 이어서 `freeAllBuffers`가 원시 버퍼를 비운다.
`docs.md`의 "fatal deinitialization은 평탄한 순서, `Unwind` trait에서만 `@deinit` 실행"에서 `Unwind` 쪽은 소스에 없다.

실험(`p1.cy`: `@deinit`이 `print`하는 `R`을 `outer`, `inner`에 지역(값, `^`)으로 두고 `inner`에서 `panic('boom')`): 어느 빌드에서도 `deinit ...`이 한 줄도 나오지 않고
스택 트레이스(`inner`, `outer`, `main`)와 종료 코드 1만 나왔다. trace 빌드도 `unreleased refcount`를 보고하지 않는다. 다만 패닉이면 `main.zig`가 누수 보고 분기에 닿기 전에 `exit(1)`하므로(`main.zig:277~299`, `evalPath`의 `ErrorPanic` 분기) 이 출력만으로 스윕의 효과를 구분할 수는 없다. 스윕 쪽 코드는 `refCounts`에서 객체 rc를 빼도록 되어 있다(`thread.zig:142`).
에이전트 루프처럼 "패닉이 나도 호스트가 계속 도는" 임베딩에서는 `@deinit`에 의존한 외부 자원(파일, 소켓) 정리가 패닉 때 건너뛰어진다는 뜻이다. 메모리는 돌려받지만 자원은 아니다.

#### ptr_table / ptr_layouts는 정리가 아니라 스택 확장용이다

이 챕터를 준비하면서 처음 가정(스택의 포인터 슬롯으로 패닉 시 해제)과 달랐다. 코드가 말하는 용도는 다르다.

- `bc_gen`의 `reserve_reg`(`bc_gen.zig:2214`)는 `is_stack_ptr()` 타입(`Ptr[T]`, `&T`; `types.zig:304`)의 레지스터를 `ptr_layout_builder`에 true로 표시한다.
- 호출 명령을 낼 때마다 `pushCall`(3103)이 그 시점의 비트맵을 `ptr_layouts`에 중복 제거해 저장하고 `{pc, layout}`을 `ptr_table`에 추가한다(3127~3133).
- 스택이 모자라 새 배열로 옮길 때(`growStackPrecise`, `thread.zig:868`, `alloc.resize`가 제자리 확장에 실패한 경우) 프레임을 거슬러 올라가며
  `get_ptr_layout(pc)`로 비트맵을 찾고 `patch_frame_ptrs`(68)가 옛 스택 범위를 가리키던 슬롯을 새 스택 주소로 고친다.

빌림 `&x`가 스택 슬롯의 주소라는 설계(2.2절)를 지탱하는 장치다. 깊이 5000의 재귀로 main의 지역을 `&int`로 계속 넘겨 스택을 키워도 값이 맞게 나왔다(`a=10000`, 실행 확인.
다만 이 실행이 패치 경로를 실제로 탔는지, `alloc.resize`가 제자리로 성공했는지는 구분하지 못했다). 자세한 프레임 구조는 [05](05-vm-runtime.md).

#### 정상 종료와 `single_run`

정상 종료는 2.3절의 순서다(전역 정리 -> main 지역 역순 정리). `single_run`(ReleaseFast CLI) 또는 `persist_main`(REPL)이면 main 최상위 지역의 정리 코드가 아예 없고,
`VM.deinit`(`vm.zig:199`)이 맨 앞에서 `freeHeapPages`를 돌려 힙과 원시 버퍼를 쓸어 담는다(`vm.zig:204~210`). 패닉과 같은 스윕이라 이 경로도 소멸자를 건너뛴다.
`docs/decisions/project_embedding_agent_loop.md`가 이것을 계약으로 못 박았다. "프로세스가 곧 끝나므로 빠르게" 끝내는 대신, 종료 시 돌아야 하는 정리 코드(`@deinit`으로 파일 flush 등)가
생기면 다시 보기로 했다. 임베딩에서 VM을 재사용하거나 누수를 검사하려면 기본값 `single_run = false`를 유지한다(`lib.zig:210`, `:369`).
`lib.zig:1152`, `:1166`의 테스트가 이 스윕이 원시 버퍼와 큰 객체(48바이트 `Generator`)를 놓치지 않음을 보증한다.

### 2.8 호스트 함수의 매개변수 소유 규약

Zig/C로 쓴 `#[bind]` 함수는 컴파일러가 만든 호출 규약을 그대로 받는다. 컴파일러는 호스트인지 스크립트인지 가리지 않고 `ownOrManageArg`를 적용하므로 규약은 다음과 같다.

| 호스트 함수 매개변수의 선언 | 호스트가 해야 하는 일 |
|---|---|
| 값 타입 중 managed (`str`, `[]T`, 관리 필드를 가진 구조체: `Future[T]`, `Object` 등) | 호출자가 이미 복사해 넘겼다. 호스트가 소유한다. 다 쓰면 반드시 정리(`destructStr`, `cl_str_deinit`, `cl_slice_deinit`) |
| 객체형(`^T`) | 호출자가 관리한다. 호스트는 빌리기만 한다 |
| `&T`, `[&]T`(Span) 같은 빌림 | 빌리기만 한다. 해제하지 않는다 |
| 비관리 값(int, float, `Ptr`, 관리 필드 없는 구조체) | 아무것도 안 해도 된다 |

코드로 본 모범 사례는 `string.zig`의 `concat`(27줄)이다. 수신자는 `&str`이라 `t.param(*cy.heap.Str)`로 포인터를 받고 그대로 둔다. 인자 `s str`은 값이라
`const str2 = t.param(cy.heap.Str); defer t.heap.destructStr(&str2);`로 정리한다. `interpolate`(37)의 두 `[&]str`은 빌림이라 정리하지 않는다.
fork가 2026-11-01에 이 규약을 어긴 바인딩 7개(`atof`, `atof32`, `str.index`, `str.insert`, `cy.VM.eval`, `os.fetchUrl`, `os.cacheUrl`)를 고쳤고(커밋 `c755c23f`),
`[]T` 매개변수용으로 `cl_slice_deinit`을 추가했으며(`1490366c`, `lib.zig:166`), `@notifyFutureComplete`를 값 `Future[T]`에서 `&FutureValue[T]` 빌림으로 바꿨다(`memory/future_resolver.cy`).
이 누수들은 문자열이 리터럴(`buf == NULL`)일 때는 드러나지 않았다. 힙 문자열을 넘겨야 샌다는 점이 늦게 발견된 이유다(`memory/host_str_params.cy`는 `'1' + '2.5'`처럼 연결해 힙 문자열로 만든다).

새 바인딩을 추가하는 사람이 던질 질문: (1) 이 매개변수 타입이 `isManaged`인가? (2) 객체형도 빌림도 아닌가? 둘 다 그렇다면 정리 코드를 써야 한다.
선언을 `[&]T`/`&T`로 바꾸는 것이 해제 코드를 쓰는 것보다 싸고 안전하다. 반환값은 반대로 호스트가 만든 소유 값이므로 호출자가 정리한다(`cl_str_init`로 만든 `str`을 `ret`에 쓴다).

## 3. 핵심 개념 정리

| 개념 | Cyber 0.4 | TS/Node에서 가장 가까운 것 | 다른 점 |
|---|---|---|---|
| 값 타입 구조체 | `type P: x int`, 대입은 복사 | `{x: 1}` 객체 리터럴(참조) | 대입이 복사라서 별칭이 생기지 않는다 |
| 공유 참조 `^T` | 힙 박스 + rc | 모든 객체 참조 | 명시적으로 올려야 하고(`^expr`) rc가 보인다. 해제 시점이 결정적이다 |
| 소유자 | 스택 변수 하나 | (없음. GC가 도달성으로 판단) | 블록을 벗어나면 즉시 정리 |
| copy | `semaOwn` -> `sema_copy` | 얕은 복사 `{...a}` 비슷 | 복사 가능 여부가 타입에 정해져 있다(`NoCopy`) |
| move | `b := move a`, `sink`, 반환 | (없음) | 이동한 변수를 쓰면 컴파일 에러 |
| `&T` | 스택/내부 주소 | 지역 변수를 가리키는 getter/참조 | 가변이고, 값이 사라지기 전에만 유효해야 한다 |
| `&&T` | 배타적 빌림 | (없음) | 크기를 바꾸는 연산용. 검사는 부분적(7절) |
| `@deinit` | 사용자 소멸자 | `using`/`Symbol.dispose`, `FinalizationRegistry` | 스코프 끝에서 반드시, 결정적으로 돈다(패닉 제외) |
| 순환 참조 | 누수 | GC가 회수 | 보고도 안 된다 |
| `Object` | `^T`를 타입 지움한 박스 | `any` 참조 | 정리 함수는 런타임에 타입 id로 찾는다(`@getDeinitObject`) |
| `Slice` | 버퍼 공유 + 길이 | 배열 슬라이스/뷰 | 쓰기가 공유되고, 크기 변경은 버퍼를 복제하거나 제자리 재사용 |
| `Array` | 소유권 있는 가변 버퍼 | `T[]` | 복사 불가, 크기 변경은 `&&` |
| `str` | 불변, 정적 상수 or 참조 카운트 버퍼 | `string` | 부분 문자열이 버퍼를 공유(`slice`) |

## 4. 소스 읽기 지도

순서대로 한 번씩 훑으면 이 장의 모든 구현을 다 보게 된다.

1. `src/test/memory/*.cy`: 36개 중 32개가 `behavior_test.zig:141~179`에 등록되어 있다. `borrow.cy`, `partial_move.cy`, `return_local_move.cy`를 먼저 읽는다.
   `scope_return_too_ephemeral_error.cy`는 파일은 있으나 등록되지 않았고, `gc_reference_cycle_*.cy`/`default_memory.cy`는 주석 처리되어 있다(2.6절).
2. `src/types.zig:55` `TypeInfo`, `:285` `isObjectLike`, `:324` `isManaged` -> `src/sema_type.zig:942` `resolve_type_info`.
3. `src/sema.zig`:
   - `:102` `Local`, `:306~340` `popLocals`/`popLocals2`, `:342` `semaExprStmt`
   - `:829` `semaReturnExpr`, `:904` `semaReturnExprStmt`, `:994` `implicitReturnMoveLocal`(fork `eb060d5e`)
   - `:1589` `semaAssignStmt`(`.ident` / `.deref` 분기), `:1464` `semaAssignToAccessStmt`, `:1560` `semaAssignToGlobal`
   - `:2129~2200` 부분 이동 보조(`check_struct_access_path`, `ensure_partial_struct_layout`, `build_move_access_path`)
   - `:3450` `localDecl`, `:4003` `semaLocal`, `:4555` `sema_program`
   - `:4668~4800` `semaDestructLocal` 일가, `:4810` `popBlock2`
   - `:5750` `sema_copy`, `:5816` `semaManage`, `:5829` `semaOwn`, `:5836` `semaLift`
   - `:7422` `move_expr`, `:8750` `sema_ex_borrow2`, `:8779` `semaBorrow`, `:9974~10010` `getCopyFunc`/`getDtorFunc`/`getDeinitObjFunc`
4. `src/sema_func.zig:504` `matchFuncSig`, `:817` `ownOrManageArg`, `:835` `resolveRtArg`(sink), `:1259` `matchArg`.
5. `src/ir.zig:276~290` `Release`/`Retain`/`Lift` -> `src/bc_gen.zig:913` `gen_lift`, `:1246` `gen_retain`, `:1333` `genCallIntrinsic`, `:3040` `pushRelease`, `:2214` `reserve_reg`.
6. `src/vm.h:83~100` 메타 비트, `:460~490` `String`/`ObjectHeader` -> `src/vm.c:92` `releaseOnly`, `:175` `retain`, `:875~910` `ReleaseOpt`/`Release`/`DTOR_STR`/`COPY_STR`, `:1269` `NEW`.
7. `src/heap.zig:518~560` 풀/큰 객체 구조, `:1015` `allocBigObject`, `:1072` `allocPoolObject`, `:189~260` 해제, `:1236` `newStringBufferUndef`, `:1249` `new_byte_buffer`.
8. `src/heap_value.zig:404` `destructValueAt`, `:634` `destroyObject`.
9. `src/builtins/core.cy`: `:2798` `@deinitObject`, `:2836` `@partial_destruct`, `:2869` `@destruct`, `:2679` `@copy`, `:1026` `Slice`, `:1662` `Array`, `:2181` `Map`/`HashMap`, `:3224` `StrBuffer`/`str`, `:662` `Object`.
10. `src/thread.zig:35` `panic`, `:68~100` 스택 포인터 패치, `:108` `freeHeapPages`, `:1018` `check_memory`(껍데기). `src/vm.zig:199` `VM.deinit`.
11. `src/lib.zig:166` `cl_slice_deinit`, `:1152~1330` 메모리 관련 라이브러리 테스트.

## 5. 실습

작업 폴더는 자유다. 아래 파일은 모두 임시 폴더에서 만들어 실행한 것이다(`cyber`는 ReleaseSafe, `cyber-trace`는 trace 빌드). 출력은 실제 실행 결과다.

### 실습 1. 같은 로직을 값 / `&` / `^T` / move로 바꿔 보기

2.2절의 `cmp1.cy`를 그대로 실행하고 네 줄의 차이를 설명해 본다: 값 매개변수는 호출자에게 안 보이고, `&`와 `^`는 보이지만 이유가 다르다(같은 스택 값을 빌렸는가, 같은 힙 객체를 가리키는가).
변형 과제: (a) `arr2 := arr`로 바꿔 에러를 읽는다. (b) `Counter`에 `with NoCopy`를 달고 `bump_value(a)`를 `bump_value(move a)`로 고친다. (c) `bump_ref`의 매개변수를 `Counter` 값으로 바꾸고 `shared.n`을 예상한 뒤 확인한다.

### 실습 2. use-after-move와 소유권 에러 읽기

저장소에 있는 기대 실패 테스트를 직접 돌려 메시지를 모은다. 파일명과 첫 줄(실행 결과):

```
$ for f in move_use_after_error partial_move_use_after_error partial_move_ref_child_error \
           sink_use_arg_after_error scope_return_error lift_borrow_error borrow_index_addr_error; do
    cyber src/test/memory/$f.cy 2>&1 | head -1; done
CompileError: `a` is no longer alive in this scope.
CompileError: Member is no longer alive.
CompileError: Cannot move a member from a shared reference.
CompileError: `a` is no longer alive in this scope.
CompileError: Expected to return a borrow from the same scope as `c`.
CompileError: Cannot lift the borrow type `&int`.
CompileError: Cannot borrow. Missing `@index_addr`.
```

직접 만든 변형(모두 실행 확인):

```
$ cyber m1.cy        -- if true: b := move a  (a 는 바깥 블록 변수)
CompileError: Can only move variable declared in the same block.
$ cyber m3.cy        -- consume(a)  (Array 를 복사해 넘김)
CompileError: Cannot copy `Array[int]`, type implements `NoCopy`.
$ cyber m5.cy        -- fn f(a ^int): b := move a
CompileError: Cannot move a reference parameter.
```

이어서 문서(`docs/docs.md` "Moving")의 부분 이동 예제를 그대로 돌려 본다.

```cy
type Foo:
    a int
    b str

f := Foo{a=123, b='abc'}
b := move f.b
print(b)
```

```
CompileError: Unsupported compile-time statement. if_unwrap_stmt

<repo>/zig-out/bin/src/builtins/core.cy:2849:25:
                        #if Layout.field_layout(field.state_offset, type.struct_state_len(field.type)) |layout|:
                        ^~~~~~~~~~~~~~~~...
```

문서의 예제가 컴파일되지 않는다. 필드가 `int`/`^int`/`?int`/choice뿐이면(`partial_move.cy`) 되고, 구조체 필드(`str` 포함)가 있는 관리 구조체이면 실패한다(`move f.a`로 바꿔도 실패, `m9.cy`).
정수만 가진 구조체 필드는 비관리라서 정리 코드를 만들지 않아 통과한다(`m8.cy`). 원인은 2.3절 규칙 5다.
변형 과제: `b ^int`로 바꾸면 통과하는지, 에러가 `core.cy`를 가리키는 이유를 `ct_inline.zig:309`에서 찾아본다.

### 실습 3. `@deinit` 호출 순서 관찰

```cy
type Res:
    name str
fn (&Res) @deinit():
    print('deinit %{self.name}')
type Pair:
    a Res
    b Res
fn (&Pair) @deinit():
    print('deinit Pair')

fn scope_demo():
    x := Res{name='x'}
    y := Res{name='y'}
    print('end of scope_demo')
scope_demo()
print('--- reassign')
r := Res{name='first'}
r = Res{name='second'}
print('after reassign')
print('--- struct fields')
fn pair_demo():
    p := Pair{a=Res{name='pa'}, b=Res{name='pb'}}
    print('end of pair_demo')
pair_demo()
print('--- temp')
fn make(n str) -> Res:
    return Res{name=n}
_ = make('temp')
print('after temp')
print('--- end of main')
```

```
end of scope_demo
deinit y
deinit x
--- reassign
deinit first
after reassign
--- struct fields
end of pair_demo
deinit Pair
deinit pa
deinit pb
--- temp
after temp
--- end of main
deinit temp
deinit second
```

읽는 법. 지역은 역순(`y`, `x`), 재대입은 그 자리에서 옛 값(`first`), 구조체는 `Pair.@deinit` 뒤 필드 선언 순서(`pa`, `pb`).
`_ = make('temp')`의 결과는 `after temp` 뒤에도 살아 있다가 main 끝에서 `second`보다 먼저(나중에 선언된 것이 먼저) 사라진다. 반면 `show(&make('arg-temp'))`나
`'name=%{make('interp-temp').name}'`의 임시 값은 그 문장이 끝나자마자 사라진다(`d2.cy`: `use arg-temp` 바로 다음 줄이 `deinit arg-temp`, `f2 after use`는 그 뒤).
변형 과제: (a) 함수 안의 `_ =`도 함수 끝까지 사는지 본다(`d2.cy`의 `f1`: `f1 body after placeholder` 다음에 `deinit placeholder`). (b) `global g Res = Res{name='global'}`을 추가해 전역과 main 지역의 순서를 본다(`deinit global`이 먼저).

### 실습 4. ARC 카운트 변화와 retain 최적화

`@refCount`가 `core.cy:2557`에 노출되어 있어서 사용자 코드에서 부를 수 있다.

```cy
a := ^123
print('rc after create: %{@refCount(as a)}')
b := a
print('rc after b := a: %{@refCount(as a)}')
fn borrow_it(r ^int) -> int:
    return @refCount(as r)
print('rc inside call (local arg): %{borrow_it(a)}')
print('rc inside call (rvalue arg): %{borrow_it(^5)}')
if true:
    c := a
    print('rc in inner block: %{@refCount(as a)}')
print('rc after inner block: %{@refCount(as a)}')
b = ^999
print('rc after b reassigned: %{@refCount(as a)}')
holder := Array[^int]{a, a}
print('rc with array of two: %{@refCount(as a)}')
```

```
rc after create: 1
rc after b := a: 2
rc inside call (local arg): 2
rc inside call (rvalue arg): 1
rc in inner block: 3
rc after inner block: 2
rc after b reassigned: 1
rc with array of two: 3
```

`local arg`가 2인 것(호출이 retain하지 않음, +0)과 블록 안에서 3이었다가 블록을 나오면 2로 돌아오는 것이 2.3절 규칙 3과 6의 결과다.
바이트코드로도 보인다. `a := ^123; b := a`는 `new`, `mov`, `retain %2.rc += 1`이고 종료 부분은 `release %2.rc -= 1; jmp 9` 뒤에 `mov`, `call core.@deinitObject`가 따라붙는다(2.3절 마지막 블록).
`take_ref(^8)`처럼 rvalue를 넘기면 호출 뒤에 `release`가 따로 나온다(`o1.cy` `cyber compile`에서 `0:167 .release: %8.rc -= 1; jmp 9`).

변형 과제: (a) `holder`의 원소를 `none`/재대입으로 바꿔 rc가 줄어드는지 본다. (b) `fn borrow_it(r ^int)`를 필드에서 꺼낸 값으로 호출(`borrow_it(wrapper.inner)`)해 rc가 올라가는지 본다(`call_with_ref_rvalue.cy` 참고).
(c) `-Dlog-mem=true` 빌드가 가능하면 retain/release 로그를 `@refCount` 값과 대조한다(이 챕터에서는 미수행).

### 실습 5. 빌림 검사의 실제 경계

(`peek`는 `a &Array[int]`를 받아 `a.len()`을 돌려주는 함수, `a`는 `Array[int]{1, 2, 3}`이다.) 먼저 `&`는 읽기 전용이 아니다.
`x := &a; y := &a; x.* = 20; y.* = y.* + 1; print(a)`(`b5.cy`)는 `21`을 낸다.

`active_borrows`가 줄지 않는 문제(2.3절 규칙 7). 아래는 모두 빌림이 끝난 뒤인데도 `append`가 거부된다.

```
$ cyber bb1.cy     -- print(a.len()); print(peek(&a)); a.append(4)
CompileError: Expected exclusive access. There is another active borrow to `a`.

<repo>/.../bb1.cy:7:1:
a.append(4)
^
$ cyber bb3.cy     -- if true: r := &a; print(r.len())  (블록 밖에서) a.append(4)
CompileError: Expected exclusive access. There is another active borrow to `a`.
```

`docs.md`의 예제(`elem := &a[2]` 뒤 `a << 4`는 "elem이 더 이상 살아 있지 않아 OK")도 같은 에러다(`b2.cy`). 암시적 수신자 빌림은 세지 않아서 `a.len()`, `a.append(4)`, `r := &a`, `r.len()` 순서는 통과한다(`bb5.cy`: `3`, `4`, `4`).
`r := &a; print(r.len()); a.append(4)`처럼 순서를 뒤집으면(`bb6.cy`) `r`을 그 뒤에 안 써도 에러다.

반대 방향은 검사가 없다. `&&`를 먼저 쥐거나 넘기고 `&`를 나중에 만들면 통과하고, 재할당된 버퍼를 가리키는 빌림이 남는다.

```
$ cyber b7.cy      -- ex := &&a; r := &a[0]; ex.append(...) x4; print(r.*)
r=1 len=7
$ cyber b9.cy      -- fn grow(arr &&Array[int], elem &int): 100번 arr.append(i); elem.* = 999
                   -- grow(&&a, &a[0]); print(a[0])
wrote through stale borrow
a[0]=1
```

`append`가 버퍼를 새로 할당하고 옛 버퍼를 해제한 뒤 `elem.* = 999`가 해제된 메모리에 써진다(`a[0]`은 그대로). 순서를 뒤집은 `append_to(&a[2], &&a)`(`b4.cy`)만 에러가 난다.

범위를 벗어난 빌림 대입도 막지 않는다. 문서는 "`ref`가 `b`보다 오래 살 수 없다"는 에러를 약속하지만(`b6.cy`: `a := 123; ref := &a`, `if true:` 안에서 `b := 234; ref = &b`, 블록 뒤에 `c := 999; d := 777`):

```
inner b=234 ref=234
after: ref=777 c=999 d=777
```

블록 밖에서 `ref`가 이미 죽은 `b`의 슬롯을 읽는데 그 슬롯을 `d`가 재사용해 777이 나온다. `localDecl`에는 짧은 수명 검사가 있지만(`temp` 수명만) 재대입 경로에는 같은 검사가 없다(코드 근거 + 위 실행).

마지막으로 +0 전달의 구멍(2.3절 규칙 6). `Node`는 정수 필드 `v`, `pad1`~`pad4`(40바이트, 큰 객체)를 가지고 `@deinit`이 `deinit Node %{self.v}`를 출력한다.

```cy
fn f(p ^Node, q &^Node):
    q.* = ^Node{v=2, pad1=0, pad2=0, pad3=0, pad4=0}
    print('p.v=%{p.v}')

a := ^Node{v=1, pad1=0, pad2=0, pad3=0, pad4=0}
f(a, &a)
print('a.v=%{a.v}')
```

```
deinit Node 1
p.v=-6148914691236517206
a.v=2
deinit Node 2
```

`f(a, &a)`에서 `a`는 지역이라 +0으로 넘어가고, `q.*` 재대입이 마지막 참조였던 객체를 해제한다. 그 뒤 `p.v`는 해제된 메모리를 읽는다. trace 빌드도 같은 값을 출력했다(읽기는 감지하지 못한다).
`call_with_ref_local.cy`의 `NOTE: although 'move' might complicate this.`와 이웃한 문제로 보인다(주석이 정확히 이 경우인지는 추정).
변형 과제: (a) `peek(&a)`를 지우면 `append`가 통과하는지 본다. (b) `Node`를 32바이트 이하(풀 객체)로 줄여 `p.v`가 어떻게 나오는지 비교한다(미실험).

### 실습 6. 컨테이너의 소유권: Array는 복사 후 파괴, Map은 이동

```cy
type Res:
    name str
fn (&Res) @deinit():
    print('  deinit %{self.name}')

a := Array[Res]{}
for 0..9 |i|:
    if i >= 7:
        print('append r%{i} (cap=%{a.cap()} len=%{a.len()})')
    a.append(Res{name='r%{i}'})
print('--- end of main')
```

처음 7번의 `append`마다 `deinit rN`이 한 줄씩(임시 값 정리) 나온 뒤 출력은 이렇다(`cap=8`이라 9번째에서 성장).

```
append r7 (cap=8 len=7)
  deinit r7
append r8 (cap=8 len=8)
  deinit r0
  ... (r1 ~ r6)
  deinit r7
  deinit r8
--- end of main
  deinit r0
  ... (r1 ~ r8)
```

9번째 원소를 넣을 때(`ensure_cap`) 옛 8개를 복사한 뒤 `@destruct`해서 `deinit r0 ~ r7`이 몰려 나오고, 방금 넣은 `r8`의 임시 값 정리가 이어진다. 끝에서 전부 한 번 더 정리된다.
`r0 ~ r7`은 총 세 번(임시, 성장, 최종), `r8`은 두 번이다. 같은 `@deinit` 타입 `V`로 `Map`을 채우면:

```cy
m := Map[int, V]{}
for 0..8 |i|:
    print('insert %{i} (size=%{m.size()})')
    m[i] = V{name='v%{i}'}
print('--- end of main')
```

```
insert 0 (size=0)
    deinit v0
    deinit v0
insert 1 (size=1)
    ...                          (insert 6, 7 도 동일하게 두 줄)
--- end of main
    deinit v6
    deinit v1
    deinit v7
    deinit v4
    deinit v5
    deinit v3
    deinit v2
    deinit v0
```

삽입마다 두 줄(매개변수 복사본들의 정리)이고, 성장이 일어나는 7번째 삽입(`resize(8)`이 준 `nvac = 8 * 75 / 100 = 6`이 소진되는 시점)에도 줄이 늘지 않는다. 엔트리가 옮겨지기 때문이다.
종료 정리는 해시 슬롯 순서(`Map` 순회 순서와 같다)다. `Slice` 별칭은 2.5절의 실험(`s1.cy`)으로 확인한다.

```
$ cyber s1.cy      -- a := []int{1,2,3}; b := a.append(4); b[0] = 100 ...
a[0]=100 b[0]=100 a.len=3 b.len=4
c[0]=1 d[0]=1 e[0]=77
d[3]=4 e[3]=5
$ cyber as1.cy     -- s := ArrayStore[int]{1, 2}; s.append(other[..])  (other 는 [2]int{10, 20})
len=6
```

(`as1.cy`는 `0: 1`, `1: 2`, `2: 10`, `3: 20`, `4: 10`, `5: 20`을 차례로 출력했다.)
변형 과제: (a) `Res`를 `with NoCopy`로 바꿔 `append`가 거부되는 위치(`core.cy:1787`)를 확인한다. (b) `[]str`로 `Slice` 실험을 하고 trace 빌드가 `unreleased refcount`를 안 내는지 본다.

### 실습 7. 순환 참조 누수, 패닉, 종료

```cy
type Node:
    next ?^Node
    name str
fn (&Node) @deinit():
    print('deinit %{self.name}')

fn make_cycle():
    a := ^Node{next=none, name='a'}
    b := ^Node{next=a, name='b'}
    a.next = b
    print('end of make_cycle')
make_cycle()
print('after make_cycle')
```

```
$ cyber cyc1.cy
end of make_cycle
after make_cycle
$ cyber-trace cyc1.cy
end of make_cycle
after make_cycle
unreleased refcount: 2
begin dump live objects
alloced: heap.HeapObject@39bbb041008, type: Node, rc: 1 at t0@39bbb048276 ev=1
val=Node

<repo>/.../cyc1.cy:9:10:
    a := ^Node{next=none, name='a'}
         ^
alloced: heap.HeapObject@39bbb041030, type: Node, rc: 1 at t0@39bbb0482b2 ev=2
...
end dump live objects
```

`deinit a`/`deinit b`는 어느 빌드에서도 나오지 않는다. `a.next = b` 바로 뒤에 `a.next = none`을 넣으면(`cyc3.cy`) 두 빌드 모두 `deinit b`, `deinit a`로 정상 정리된다.
순환 노드가 `Array[int]` 필드도 가지면(`cyc2.cy`) 릴리스 CLI는 마지막에 죽는다.

```
end of make_cycle
after make_cycle
thread 55137177 panic: Unfreed raw buffers: 2
Cannot print stack trace: stack tracing is disabled
```

패닉(2.7절)은 `p1.cy`로 본다. `outer`의 `o := R{...}`, `inner`의 `r := R{...}`(`name str`, `data Array[int]`, `@deinit`이 출력)와 `boxed := ^R{...}`를 두고 `inner`가 `panic('boom')`을 부른다.

```
$ cyber p1.cy; echo "exit=$?"
panic: boom

<repo>/.../p1.cy:11:5 inner:
    panic('boom')
    ^
<repo>/.../p1.cy:15:5 outer:
    inner()
    ^
<repo>/.../p1.cy:17:1 main:
outer()
^
exit=1
```

`@deinit`이 출력하는데도 `deinit` 줄이 하나도 없다. trace 빌드도 같은 출력이고 `unreleased refcount`가 없다(패닉 경로는 누수 보고 전에 종료하므로 이 점은 참고용).
변형 과제: (a) `d1.cy`를 `single_run` CLI(ReleaseFast)로 돌릴 수 있다면 마지막 두 `deinit`이 사라지는지 본다(코드 근거로는 사라진다; 미실행). (b) `ev=N`을 `vm.zig:33`에 넣어 그 객체의 retain/release를 추적해 본다(미실행).

### 실습 8. 함수 끝의 정리 코드를 바이트코드로 읽기

2.3절의 `work` 함수(`r := Res{name='r'}`, `s := 'a' + str(n)`, `if n > 10: return n`, `return n + 1`)를 `cyber compile c1.cy`로 덤프한다.

```
$ cyber compile c1.cy > c1.dump      # fn work 구간만 보려면 '--1 `fn work`' 이후를 본다
```

`fn work`에는 같은 구조의 정리 덩어리(`.dtor_str` -> `.call Res.@deinit` -> `.add_i16` 필드 오프셋 -> `.dtor_str`)가 세 번 나온다. 두 `return` 앞에 하나씩(각각 뒤에 `.ret`)과
함수 끝(도달할 수 없지만 `popBlock2`가 생성) 하나다. 이 구간에서 `Res.@deinit` 호출은 3개, `.ret`은 2개, `dtor_str`은 7개(덩어리 3개 x 2 + `'a' + str(n)` 임시 문자열 1개)였다.
순서는 `set_ret`(`.mov: %0 = %5`) -> 정리 -> `ret`이다. 호출 규약은 `o1.cy`(`take_str(s str)`, `take_ref(r ^int)`)로 본다: `take_str(x)`는 인라인되어 `copy_str`(호출자 복사)와 `dtor_str`(피호출자 정리)가 나란히 있고,
`take_ref(b)`(지역 인자)에는 `retain`/`release`가 없다.
변형 과제: (a) `Res`의 `@deinit`을 지우면 덩어리가 `dtor_str`만 남는다. (b) `name int`로 바꾸면 비관리가 되어 정리가 완전히 사라진다. (c) 재귀 함수로 바꿔 인라인을 막고 `call` 앞뒤 정리를 본다.

## 6. 0.3 -> 0.4 변경 관점 / 설계 철학 메모

| 항목 | 0.3 (`git tag 0.3`) | 0.4 (HEAD) |
|---|---|---|
| 모델 | ARC 단일. 원시 값은 복사, 객체는 rc | 값 소유권 + 빌림 + `^T` ARC |
| 해제 로직 | `arc.zig`의 `release` -> Zig `freeObject`가 타입별 분기 | `core.cy`의 `@destruct`/`@deinitObject` 템플릿 + 일부 Zig 미러(`heap_value.zig`) |
| 지역/임시 정리 | 실행 시 프레임 정보로 해제(`releaseLocals`, `runTempReleaseOps`) | sema가 IR에 정리 코드를 박는다. 런타임에 정리 테이블이 없다 |
| 순환 | `performGC()` mark-sweep(루트는 main fiber 스택) | 없음. `check_memory`는 껍데기 |
| 할당 | 40바이트 이하 풀 + mimalloc | 같은 구조(풀 슬롯 40바이트 = 헤더 8 + 본문 32). allocator는 빌드 옵션 |
| 호스트 객체 | `getChildren` · `finalizer` 콜백 | 호스트 함수가 값 매개변수를 소유하고 직접 정리하는 규약 |

변화의 이유는 `docs/history/ownership_memory.md`의 해석 절이 잘 요약한다: 동적 타입에서는 모든 값을 보수적으로 카운트해야 했고, 정적 타입에서는 수명이 컴파일 시점에 보인다.
IR이 정리를 명시하므로 새 코드젠 백엔드(C 백엔드 등)도 소유권을 다시 풀지 않아도 된다는 이점이 IR 주석의 설계 의도다.

### "Rust + Swift 혼합" 평가를 코드로 점검하기

같은 점(일반 지식과 코드의 대응): 이동하면 원 변수를 못 쓰는 규칙과 부분 이동, `NoCopy`(Rust의 non-`Copy`), `@deinit`(Rust `Drop`, Swift `deinit`), `^T`(Rust `Rc`와 Swift 클래스 참조에 해당하는 ARC),
버퍼 헤더에 원소 수를 두는 Swift `Array` 방식(결정 문서가 조사한 설계), `@isUniqueRef`(Swift `isKnownUniquelyReferenced`와 같은 쓰임).

다른 점(실험으로 확인):

1. `&T`가 가변이다. Rust의 `&T`/`&mut T` 구분이 없고, `&&T`는 "버퍼를 재할당할 수 있는 연산"을 위한 별도 장치다.
2. 빌림 수명 검사는 NLL이 아니다. 카운터가 줄지 않고(`parent_local`이 대입되지 않음), `&&` 취득 시점에만 확인하며 반대 방향과 스코프 이탈은 확인하지 않는다(실습 5). Rust의 보증(별칭 xor 가변, 댕글링 없음)은 아직 아니다.
3. 빌림 반환은 `scope` 매개변수 하나에 묶는 단순형이다. Rust의 명시적 수명 매개변수가 없다. 그만큼 표현력은 낮고 검사는 단순하다.
4. `move`는 같은 블록의 변수만 허용한다. Rust가 drop flag로 푸는 "조건부 이동"을 아예 금지해 푼 단순화다.
5. 공유 참조 `^T` 안쪽은 아무 제약 없이 변경 가능하다(`alias.n`이 바로 바뀜). Rust의 `Rc<RefCell<T>>` 같은 런타임 빌림 검사(`Ex[T]`)는 `core.cy:784`에 설계만 있고 테스트가 없으며, `Ex.ex_borrow()`는 컴파일되지 않는다
   (`core.cy:797`의 `&inner.child`가 `$` 제거(`e4804c08`) 때 `self.inner.child`로 안 고쳐졌다).
6. Swift의 COW와 달리 `Slice`는 "소유한 변수가 변경될 때만 제자리"가 아니라 "`&Slice` 수신자의 버퍼가 유일하면" 제자리이므로 별칭이 남는다(결정 문서가 Lean/Koka/Swift와 비교해 짚은 부분).
7. Weak/unowned가 없다. Swift와 가장 크게 다른 운영 차이다.

정리하면 "정적 언어의 소유권 문법에 Rust보다 훨씬 느슨한 검사를 얹고, 런타임은 Swift식 ARC"다. 검사가 느슨한 자리에서 생기는 버그(실습 5, 6)가 이 fork에서 실제로 마주칠 종류다.

### 다음에 건드릴 수 있는 곳 (fork 유지보수 관점)

`docs/history/ownership_memory.md`의 결론대로 최근 고친 세 버그(반환 복사의 이중 해제, 호스트 매개변수 누수, Slice 버퍼 공유 누수)는 모두 "소유 규약은 들어왔는데 런타임/표준 라이브러리가 끝까지 안 따른" 자리였다.
이 장에서 같은 유형을 더 찾았다(7절). 순서는 (1) 규약을 문장으로 쓴다(누가 소유, 누가 정리, 빌림은 언제까지), (2) 그 문장에 코드를 맞추고 회귀 테스트를 만든다. 표준 컨테이너의 `append(val T)` -> `move val`,
`Array.ensure_cap` -> 비트 이동(Map이 이미 쓰는 방식), 빌림 카운터의 감소(`Local.parent_local` 대입 또는 별도 구조)가 작고 효과가 큰 후보다. `check_memory`를 실제로 구현하는 일은 큰 작업이다
(`cyclable` 표식은 `vm.h:630`의 `TypeEntryOld`에만 남아 있다. `check_memory` 주석이 말하듯 스택의 일반 포인터 때문에 mark-sweep도 어렵다).

## 7. 알려진 이슈, 문서와 코드의 차이, 미완 지점

아래는 이 장을 쓰며 읽고 돌려서 확인한 것이다. "재현"은 실습의 파일 또는 명령이다.

### 7.1 버그와 의심 지점

| # | 내용 | 근거 | 재현 |
|---|---|---|---|
| 1 | 명시적 `&x` 뒤 같은 함수의 `x`에 대한 `&&` 연산이 영구 거부됨(`active_borrows` 감소 없음) | `sema.zig:120`, `:322`, `:4926`, `:8788` | `bb1.cy`, `bb3.cy`, `bb6.cy` |
| 2 | `&&` 취득 뒤 만든 `&`와 `&&` 인자 뒤의 `&` 인자를 검사 안 함 -> 해제된 버퍼에 쓰기 | `sema.zig:8750` | `b7.cy`, `b9.cy` |
| 3 | 블록을 벗어난 지역을 가리키는 빌림 재대입을 막지 않음 | `localDecl`에만 수명 검사 | `b6.cy` |
| 4 | 구조체 필드(`str` 포함)가 있는 관리 구조체의 부분 이동이 컴파일 안 됨. `docs.md`의 예제가 그 형태 | `core.cy:2849`, `ct_inline.zig:309` | `m6.cy`, `m9.cy`, `m12.cy` |
| 5 | `f(a, &a)` : 지역 인자 +0 전달 + 같은 지역의 빌림으로 재대입 -> 해제된 객체 읽기 | `sema_func.zig:817` | `al1.cy` |
| 6 | `Array.append(val)`이 `val`을 복사하고 `@deinit`이 임시/성장/최종에 3번 돔. NoCopy 원소는 `append` 불가 | `core.cy:1787`, `:1845~1852` | `ar2.cy`, `d5.cy` |
| 7 | `Array.clone()`이 없는 `cap` 필드를 써서 컴파일 안 됨 | `core.cy:1808~1814` | `Array[int]{1}.clone()` |
| 8 | `ArrayStore.append(slice [&]T)`가 같은 블록을 두 번 실행 | `core.cy:1619~1628` | `as1.cy` (`len=6`) |
| 9 | `Ex[T].ex_borrow()` 컴파일 불가(`&inner.child`) | `core.cy:797` | `e6.cy` |
| 10 | 사용자 `@copy`를 달아도 `NoCopy` 멤버가 있으면 `no_copy` | `sema_type.zig:945~953` | `k2.cy` 첫 버전(`data Array[int]` 멤버 + `@copy`) |
| 11 | 문자열 리터럴이 65536바이트 이상이면 길이가 16비트로 잘림(70000 -> 4464) | `bc_gen.zig:1272` | 70000자 리터럴의 `s.len()` |
| 12 | `Slice.size_down` 등 뒤 원본 슬라이스 읽기 = 해제된 칸 읽기(문서도 인정) | `core.cy:1373` | `s2.cy` |
| 13 | 순환 참조는 수거/탐지 없이 누수. 원시 버퍼가 낀 때만 릴리스 CLI가 `Unfreed raw buffers`로 패닉 | `thread.zig:1018`, `heap.zig:97` | `cyc1.cy`, `cyc2.cy` |
| 14 | 패닉/`single_run` 종료에서 `@deinit` 미실행(자원 정리 불가) | `thread.zig:35`, `vm.zig:204` | `p1.cy` |
| 15 | 정상 종료에서 전역 `@deinit`이 main 지역보다 먼저 | `sema.zig:4555` 근처 | `g1.cy` |
| 16 | `cl_slice_deinit`/호스트 경로의 `destructValueAt`이 사용자 `@deinit`을 안 부름 | `lib.zig:166`, `heap_value.zig:404` | 코드 근거(미실행) |
| 17 | trace 빌드의 `freePoolObject`가 `heapFreeTail`을 갱신하지 않는 것으로 읽힘(해제 슬롯 유실 가능성) | `heap.zig:219~250` | 코드 근거(추정, 미실행) |
| 18 | trace 빌드에서 dangling retain 보고 경로가 `integer overflow`로 죽음 | `debug.zig:106` | `s2.cy`를 trace CLI로 |

### 7.2 문서와 코드의 차이

- `docs/docs.md` "Borrows": 빌림은 수명을 넘을 수 없다고 하지만 재대입 경로는 검사하지 않는다(3번). "Exclusive borrows"의 `elem := &a[2]; a << 4 -- Ok`는 에러가 난다(1번).
- `docs/docs.md` "Cycle detection": 안전 모드에서 스레드 끝에 탐지해 패닉한다고 하지만 `check_memory`는 껍데기다. `@check_cycles`, `Unwind`, Weak references는 소스에 없다.
- `docs/docs.md` "Moving"/`Foo{a int, b str}` 부분 이동 예제는 컴파일되지 않는다(4번).
- `core.cy:758~761`의 `Copyable` 주석("`@copy`가 구현되면 `Copyable`")은 멤버가 `NoCopy`이면 틀리다(10번).
- `behavior_test.zig`와 `src/test/memory`: 폴더에는 36개 파일이 있지만 `gc_reference_cycle_*.cy`와 `default_memory.cy`는 0.3 문법이라 실행 불가이고, `scope_return_too_ephemeral_error.cy`는 등록되지 않았다.
- 작업 지시서의 가정 두 가지를 바로잡는다: `src/map.zig`(`ValueMap`)는 사용되지 않는 코드이고, `ptr_table`/`ptr_layouts`는 패닉 정리가 아니라 스택 확장 때 포인터를 패치하는 용도다.

### 7.3 소유 규약 점검 체크리스트 (fork 유지보수용)

코드를 바꿀 때 아래 질문을 던진다.

1. 새 `#[bind]` 함수: 값으로 받는 관리 타입 매개변수를 정리하는가? 가능하면 `&T`/`[&]T`로 바꾸었는가? (2.8절)
2. 새 컨테이너 연산: 원소를 복사해 넣고 원본을 파괴하는가, 이동하는가? `@deinit`이 부수효과를 가진 원소를 넣어 세 번 도는지 실험했는가? (실습 6)
3. 호출자가 +0으로 넘긴 `^T` 인자를, 피호출자가 같은 변수의 별칭(빌림, 전역, 필드)을 통해 해제할 수 있는가? (실습 5)
4. 복사 가능한 타입에 외부 자원을 붙였는가? 그렇다면 `with NoCopy`를 달고 컨테이너가 그 타입을 받을 수 있는지(`Array.append`) 먼저 확인한다.
5. Zig 미러(`heap_value.zig`)와 Cyber 템플릿(`core.cy`)의 정리 동작이 어긋나지 않는가? 새 타입 분기를 추가하면 둘 다 고친다.
6. 큰 객체(32바이트 초과)로 시험했는가? 누수 검사 allocator는 풀 객체 누수를 못 본다.
7. trace 빌드와 릴리스 빌드에서 둘 다 돌렸는가? 릴리스는 해제된 메모리 읽기를 조용히 넘긴다.
8. 임베딩에서 `single_run`을 켜고 `@deinit`에 의존하는 정리가 없는가? 에이전트 루프는 기본값 `false`를 유지한다.

미완 지점은 `ownership_memory.md`가 정리한 것과 같다: Slice 별칭 의미(후보 2, 마지막 사용 분석 필요), 명시적 `move`의 같은 블록 제약, `single_run` 스윕의 소멸자 생략 계약, `sink`의 존속 여부.

## 8. 이해도 확인 Q&A

### Q1. `move`가 "같은 블록에서 선언한 변수만" 허용되는 이유는 무엇이고, 그 제약으로 무엇을 얻고 무엇을 잃는가?

A: 이동은 `Local.type = .dead`로 표시하는 컴파일 시점 상태(`sema.zig:7440`)다. 조건문 안에서 바깥 변수를 이동하면 "어느 분기에서 이동됐는가"가 실행 시점에야 정해지므로 정리 코드가
런타임 표식(drop flag)을 가져야 한다. 이 언어는 그것을 두지 않고 "같은 블록 선언만"으로 막아서, sema가 위에서 아래로 한 번 훑는 상태만으로 정리 코드가 정해지게 했다(`m1.cy`의 에러).
부분 이동의 필드 상태 벡터도 같은 전제를 쓴다. 잃는 것은 "조건부 이동" 표현력이다. 대신 `return`이 암시적 이동이라 대부분의 필요(생성 함수에서 값 반환)는 충족된다.

### Q2. `foo(a)`에서 `a`가 `^int` 지역이면 rc가 오르지 않는데, `foo(h.r)`처럼 필드이면 오르는 이유는? 이 규칙의 구멍은 어디인가?

A: `ownOrManageArg`(`sema_func.zig:817`)는 객체형 인자가 `value_local`이면 그대로 넘기고(지역은 호출 동안 살아 있다), 그 밖이면 `semaOwn` + `semaManage`로 retain해 문장 끝에 release한다.
필드는 피호출 함수가 부모를 통해 바꿀 수 있어서 retain이 필요하다(`call_with_ref_rvalue.cy`). 구멍은 "지역은 안전하다"는 가정이 지역 자신에 대한 빌림(`&a`)이 함께 넘어가면 깨진다는 점이다.
피호출 함수가 `q.* = ...`로 같은 변수를 재대입하면 +0으로 받은 객체가 해제된다(`al1.cy`, 실습 5). 해법 후보는 "같은 호출에 같은 지역의 빌림이 있으면 retain"이지만 이 저장소에는 없다(추정).

### Q3. `@destruct`는 왜 자식 필드보다 `@deinit`을 먼저 부르는가? 반대 순서(Rust의 Drop과 비교)와 어떤 차이가 생기는가?

A: `core.cy:2872~2873` 주석이 이유를 적었다: 부모가 `@deinit`에서 자식을 읽을 수 있게 하려는 것이다. Rust도 `Drop::drop`을 필드 정리보다 먼저 실행한다(일반 지식)이므로 같은 순서다.
차이는 실패 모델이다. 패닉에서는 이 호출 전체가 건너뛰어진다(실습 7). 필드 정리가 사용자 `@deinit` 안에서 정리된 자원을 다시 건드리지 못하게 해야 하는 책임이 `@deinit` 작성자에게 있다.

### Q4. `Slice`는 길이를 값(`_len`)에 두면서 왜 원소 개수(`count`)는 버퍼 앞 8바이트에 따로 둘까?

A: 한 버퍼를 길이가 다른 여러 `Slice`가 공유할 수 있기 때문이다(`append`의 제자리 재사용). 마지막 소유자가 가진 `_len`은 버퍼에서 가장 길게 초기화된 곳과 다를 수 있어서 `_len`만큼만 정리하면
관리 원소가 샌다(결정 문서가 재현한 `unreleased refcount: 1`). 버퍼에 `count`를 두면 누가 마지막이든 초기화된 만큼 정확히 정리된다(`Slice.@deinit`, `core.cy:1094`). 남는 문제는 길이를 줄이는 연산 뒤 원본을 읽는
별칭 의미이고, 이는 정리 정확성이 아니라 의미론의 문제라 후보 2(마지막 사용 분석)가 필요하다.

### Q5. `Array.ensure_cap`은 복사 후 파괴하고 `HashMap.resize`는 비트 이동한다. `Array`를 `HashMap`처럼 고치려면 무엇이 필요한가?

A: `@memcpy`로 이동할 수 있는 이유는 옛 배열을 destruct 없이 `free`하기 때문이다(옛 원소의 소유권을 새 배열이 가져간다). `Array.ensure_cap`의 TODO가 바로 이것이다. 필요한 변경은 세 가지다.
(1) `ensure_cap`의 복사+파괴 루프를 `#if type.managed(T)`에서 `@memcpy`로 바꾼다(Map `resize`와 같은 형태). (2) `append(val T)`가 `move val`로 값을 넣게 해서 임시/성장/최종의 3회 `@deinit`을 1회로 줄이고 `NoCopy` 원소를 허용한다.
(3) 이동 후 새 소유자가 정리하므로 `Array.@deinit`의 정리 범위는 `length`면 충분하다. 회귀 테스트로 `@deinit`이 출력하는 원소 타입의 호출 횟수를 센다(실습 6의 실험을 테스트로 바꾸면 된다).

### Q6. 패닉이 나도 `@deinit`이 안 돌면 에이전트 루프(CodeAct)에는 어떤 문제가 생기는가? 어떤 대응이 가능한가?

A: 힙 메모리와 원시 버퍼는 `freeHeapPages`가 되돌리지만 파일 핸들, 소켓, 임시 파일, 잠금 같은 외부 자원은 스크립트의 `@deinit`에 맡겼다면 닫히지 않는다. 호스트가 계속 도는 임베딩에서는 누적 누수가 된다.
대응은 (a) 자원을 호스트가 소유하고 스크립트에는 핸들 id만 주기, (b) 패닉 후 VM을 `reset`하면서 호스트가 자원 테이블을 직접 닫기, (c) `thread.panic`의 `TODO: Run stack error destructors`를 구현하기(스택 프레임을 훑어
지역을 정리해야 하는데 정리 코드가 일반 명령열이라 정보가 없다. 구현하려면 지역별 정리 메타데이터가 새로 필요하다, 추정)다. 현재 코드가 허락하는 것은 (a)와 (b)다.

### Q7. 순환 참조가 릴리스 CLI에서 조용히 사라지다가 `Array`가 낀 순환에서만 패닉하는 이유는?

A: 풀 객체와 큰 객체의 헤더는 힙 페이지/allocator가 관리해서 `Heap.deinit`이 페이지를 통째로 버릴 때 누수를 따로 세지 않는다. 반면 `alloc()`으로 받은 원시 버퍼는 `Heap.buffers` 맵에 기록되어 있어서
남은 것이 있으면 `Heap.deinit`이 `Unfreed raw buffers: N`으로 패닉한다(`heap.zig:97`). 정상 종료에서는 main 지역이 정리되며 버퍼도 풀리지만 순환 객체의 필드는 풀리지 않으므로 맵에 남는다.
trace 빌드는 전역 rc 합계로 `unreleased refcount`를 보고해 두 경우 모두 잡는다.

### Q8. 호스트 함수에 `Future[T]`를 값으로 받는 바인딩을 추가하려 한다. 어떤 위험이 있고 어떻게 막는가?

A: `Future[T]`는 관리 필드(`^FutureValue`)를 가진 구조체라서 값 매개변수 규약에 따라 호출자가 복사해 넘기고 호스트가 소유한다. 정리를 빠뜨리면 호출마다 샌다(실제로 `@notifyFutureComplete`가 그랬다).
막는 방법은 선언을 `&FutureValue[T]` 같은 빌림으로 바꾸는 것이 가장 싸고(`memory/future_resolver.cy`), 값이 꼭 필요하면 호스트에서 `destructValueAt` 등으로 정리하되 사용자 `@deinit`이 있는 타입에서는
Zig 미러가 `@deinit`을 부르지 않는다는 점을 확인한다(7.1의 16번). 누수는 32바이트가 넘는 힙 문자열/큰 객체로 테스트해야 누수 검사 allocator에 걸린다.

## 9. 더 알아보기

- 키워드: Perceus / Counting Immutable Beans(참조 카운트 최적화), Swift `ArrayBody`, Rust 소유권, NLL, drop flag, `Rc<RefCell<T>>`, mimalloc, free list 풀 할당. (모두 일반 지식 검색어)
- 이 저장소의 관련 문서: `docs/history/ownership_memory.md`(변화 이력), `docs/decisions/project_slice_append_aliasing.md`(Slice 설계와 다른 언어 비교),
  `docs/decisions/project_map_str_hash.md`(Map 성장과 `copy_str`), `docs/decisions/project_string_interpolation.md`(단일 할당), `docs/decisions/project_embedding_agent_loop.md`(`single_run`, 호스트 규약).
- 앞뒤 장: [03 의미 분석과 IR](03-sema-and-ir.md)의 `Cstr`/`ExprResult` 흐름을 이 장의 `owned`/`addressable`과 겹쳐 읽는다. [04 바이트코드 생성](04-bytecode-gen.md)의 레지스터 할당(`reserve_reg`, `pop_locals`)과
  `release`/`dtor_str` 생성을 이어서 본다. [05 VM 런타임](05-vm-runtime.md)의 패닉 언와인드와 이 장 2.7절을 맞춰 읽는다.
- 다음 날: [07 코루틴과 동시성](07-coroutines-concurrency.md). 이 장의 규약이 제너레이터에서 어떻게 깨지는지(프레임을 힙에 복제하지만 지역 변수가 스냅샷에 안 들어가는 문제, 제너레이터 함수의 매개변수만 callee가 관리)를 본다.
  `Thread.heap`이 스레드마다 따로라는 점과 `Sendable`(현재 `int`만) 제약도 이 장의 비원자적 rc와 이어진다.
