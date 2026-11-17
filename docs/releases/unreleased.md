# 0.4.14 이후 변경 (미릴리스)

0.4.14(2026-11-17) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## `Slice`의 크기 변경은 제자리, 새 목록은 `-ed` 메서드 (깨지는 변경)

- `append`, `insert`, `remove`, `clear`, `size_down`, `size_up`이 받는 변수를 그 자리에서 바꾸고 아무것도 돌려주지 않는다
  (`fn (&&Slice[]) append(val T)`). `Array`와 같은 꼴이다. `xs = xs.append(1)`은 이제 `xs.append(1)`이다.
- 새 목록을 돌려주는 메서드 `appended`, `inserted`, `removed`가 생겼다. 받는 변수는 그대로다. `+`는 `appended`와 같고,
  `xs += v`는 `append`처럼 제자리에서 붙인다(`+=`가 타입의 `` `+=` `` 메서드를 부른다. 없으면 전처럼 `xs = xs + v`).
- `[]T`에 `pop() -> ?T`가 생겼다(`Array.pop`과 같다).
- 옛 꼴은 고칠 방법을 말하는 컴파일 오류다. `xs = xs.append(1)` → '`append` changes `xs` in place and returns nothing.
  Write `xs.append(1)` as a statement.', `ys := xs.append(1)`은 `xs.appended(1)`도 알려 준다. 새 목록 메서드의 결과를 버리면
  (`xs.appended(1)`만 쓴 문장, `_ = xs.removed(0)`) 제자리 메서드를 알려 주는 오류다.
- 버퍼를 다른 값과 나눠 가진 `Slice`(`ys := xs`, 부분 슬라이스)를 제자리에서 키우거나 가운데를 바꾸면 먼저 복사한다.
  다른 값은 원소와 길이를 그대로 본다. 원소 쓰기(`xs[i] = v`, `sort`, `reverse`)는 복사하지 않아 버퍼를 나눈 값 모두에
  보인다(전과 같다). `size_down` · `clear`는 복사하지 않는다(잘린 원소는 다른 값을 위해 살아 있다).
- 끝이 아닌 `remove` · `insert`가 버퍼를 혼자 가진 `Slice`에서 할당 없이 제자리로 돈다(0.4.13부터 항상 복사했다).
- REPL · 세션(`persist_main`)의 마지막 줄 `xs.append(4)`는 결과가 없는 문장이다(0.4.13~0.4.14에서는 오류). 마지막 줄의
  `xs.removed(0)`은 새 목록을 결과로 보여 준다.
- 0.4.13에서 넣은 "버린 크기 변경 결과" 오류(`checkDroppedSliceResult`)는 새 목록 메서드에만 남는다.
- 전역 `[]T` · `Array[T]`, 전역의 필드, 포인터가 가리키는 값에도 제자리 메서드를 쓸 수 있다(take-and-restore). 전역은 배타적으로
  빌릴 수 없으므로, 메서드 호출 동안 값을 숨은 지역으로 옮기고 전역에는 빈 목록을 두었다가 호출 직후 되돌린다. 복사하지 않으니
  전역 목록을 키우는 반복문도 빠르다. 인자가 같은 전역을 읽으면(`g.append(g.len())`) 빈 목록을 보게 되므로 컴파일 오류다
  ('The method takes `g` out while it runs, so an argument can not read `g`. Read it into a local first.'). 메서드 안에서 이름으로
  전역을 읽는 코드(원소 타입의 `@deinit` 등)는 빈 목록을 본다.

## 포인터 · 빌림으로 지역 변수를 대입하면 해제된 메모리를 읽던 결함 (F-161)

- `p.* = r`(`p`가 `Ptr[T]`, `&T`, `&&T`이고 `r`이 관리 대상 값을 든 지역 변수)이 `r`을 복사하지 않고 넣어, 함수가 끝나며 `r`과
  대상이 같은 값을 두 번 놓았다. 뒤에 대상을 읽으면 해제된 메모리였다(ReleaseSafe에서 `-6148914691236517206`). 이제 복사한다.
- `&&T`로 받은 값에 `p.* = v`로 대입할 수 있다(전에는 'Expected pointer type.').
- 빈 목록을 만드는 내부 경로(`sema_init_seq2`의 원소 없는 경우)가 span 포인터를 `int`로 만들어 타입 검사에 걸리던 것을 고쳤다
  (사용자 코드에서는 닿지 않던 경로).

## `os` 파일 함수의 옛 꼴이 고치는 이름을 알려 준다

- 0.4.13에서 나눈 텍스트 · 바이트 파일 함수(`docs/decisions/project_os_file_text_bytes.md`)의 옛 꼴이 고칠 이름을 말한다.
  - `os.read_file_str(p)`(와 `os.readFileStr`): 'Can not find the symbol `read_file_str` in `os`. Use `os.read_file`. It returns `str`.'
  - `os.write_file(p, bytes)`: '... when calling `fn write_file(str, str) -> !void`. Write bytes with `os.write_file_bytes`.'
    `os.write_file_bytes(p, s)`는 `os.write_file`을 알려 준다.
  - `os.read_file`의 결과를 `[]byte` 자리에 쓰면(인자, `var b []byte = ...`) '`os.read_file` returns `str`. Read bytes with
    `os.read_file_bytes`.'를 붙인다. `os.read_file_bytes`의 결과를 `str` 자리에 쓸 때도 반대로 알려 준다. 값을 담은 지역 변수
    (`data := os.read_file(p)!` 뒤의 `data`)도 선언의 초기식을 따라가 같은 힌트를 낸다. 이 힌트가 쓰기 함수의 힌트보다 먼저다
    (`os.write_file_bytes(p, os.read_file(q)!)`는 읽기를 고칠 일이다).
- 힌트 표는 `sema.zig`의 `moved_module_syms` · `call_arg_hints` · `result_type_hints`. 앞으로 std 이름을 나누거나 바꾸면 이 표에
  한 줄을 더한다.
