# REPL 세션이 가져오는 모듈: CLI가 자기 VM에 준다 (2026-11-24)

## 배경 (F-200)

CLI의 REPL에서 `use os`가 'Failed to load module: os'였다. 파일로 돌리면 된다.

~~~text
$ printf 'use os\nuse math\nmath.sqrt(4.0)\n.exit\n' | cyber
CompileError: Failed to load module: os
`float` 2.0
~~~

원인은 VM이 둘이라는 데 있다. `cli.repl()`(`src/std/cli.cy`)은 CLI의 VM에서 도는 Cyber 코드이고, 세션은 `cy.VM()`으로 만든
다른 VM에서 돈다. `UserVM_init`(`src/builtins/cy.zig`)은 `C.vm_init()`으로 새 VM을 만들고 printer · error printer · logger · 오류
색만 부모에서 복사한다. `cli.init_cli`(`src/cli.zig`)가 CLI의 VM에 건 resolver · dl resolver · loader · user data(`cli.App`)는
넘어가지 않는다. 세션은 라이브러리의 기본 loader(`compiler.default_loader`)가 아는 모듈만 가져온다.

영향을 받는 모듈(변경 전 빌드에서 `use <이름>`을 넣어 확인):

| 모듈 | 변경 전 REPL | 이유 |
| --- | --- | --- |
| `os`, `cli`, `libc` | 실패 | CLI의 loader에만 있다(`cli.zig` `named_std_mods`) |
| `core`, `meta`, `math`, `cy`, `c`, `io`, `test`, `time`, `json`, `peg`, `regex`, `toon`, `path` | 됨 | 라이브러리의 기본 loader에 있다 |
| 파일(`use m 'm.cy'`), URL | 실패 | 기본 loader는 파일을 읽지 않는다 |

## 지켜야 할 계약

매뉴얼의 libcyber 장은 "`cy.eval` runs code in a new VM that has none of the host's settings"라고 적고, 그래서 신뢰하지 않는
스크립트에서 막을 모듈에 `cy`를 든다. tars-agent 같은 호스트는 resolver로 허용 표를 만든다
(`project_embedding_module_allowlist.md`). 이 계약에서 나오는 조건은 둘이다.

1. `cy.VM()`과 `cy.eval`은 격리된 채로 둔다.
2. 호스트가 `cy.repl`을 직접 부를 때 호스트의 모듈 정책이 그대로여야 한다. `os`를 거절하는 호스트가 REPL을 거쳐 `os`를 얻으면
   안 된다.

## 검토한 안

### 안 A. `REPL.new()`가 부모의 resolver · loader · user data를 물려받는다

`cy` 모듈에 물려받는 생성자를 두고 `REPL.new()`만 쓴다.

- 좋은 점: `cli.cy`가 바뀌지 않는다. 호스트의 REPL도 호스트의 모듈을 얻는다.
- 나쁜 점:
  - 조건 2를 깬다. 허용 표 resolver는 가져오는 쪽의 uri가 `main`일 때만 표와 맞춘다(allowlist 결정). 세션의 main 청크는 uri가
    `eval`이라 표를 비껴가고, 호스트의 loader가 `os`를 주면 REPL에서 `os`가 열린다.
  - 호스트의 콜백이 자기가 만들지 않은 VM 포인터로 불린다. VM 포인터를 전역에 두고 쓰는 호스트(tars-agent)의 bind 함수가 다른
    VM을 만진다.
  - 절반만 물려받는다. `deny_raw_ptrs` · `deny_spawn` · 메모리 한도 · fuel은 넘어가지 않으므로 "호스트의 설정을 가진 VM"도 아니다.
  - 라이브러리(`cy.zig`)가 "REPL이면 물려받는다"는 정책을 품는다. 정책은 호스트의 것이다.

### 안 B. 세션을 CLI의 VM에서 돌린다

자식 VM을 없애고 `main.zig`가 CLI의 VM에 `persist_main` eval을 줄마다 한다.

- 좋은 점: VM이 하나라 물려줄 것이 없다. `cyber main.cy`와 완전히 같은 환경이다.
- 나쁜 점:
  - REPL 본체(`cy.cy`의 `REPL`: 줄 모으기, 들여쓰기, `.which` · `.bc` · `.doc`)를 Zig로 다시 써야 한다. 돌고 있는 eval 안에서
    같은 VM을 다시 eval할 수 없기 때문이다. `cy.repl`을 쓰는 호스트의 REPL과 CLI의 REPL이 두 구현으로 갈린다.
  - 세션의 panic이 REPL을 모는 코드의 힙을 함께 지운다. 지금은 세션 VM만 리셋되고 REPL은 이어진다.

### 안 C. `cli.cy`가 넘긴다 (`doc` 함수처럼)

`cy.repl(read_line, doc)`이 문서 함수를 받듯이 loader를 받는다.

- 좋은 점: 주는 쪽이 명시된다. `cy.repl(read_line)`만 부르는 호스트는 전과 같다.
- 나쁜 점: Cyber 함수 하나로는 loader가 되지 못한다. `os` · `cli`는 소스와 함께 네이티브 bind 함수(`os_mod.bind`)가 세션 VM에
  걸려야 하고, 그것은 C 수준의 loader만 한다. 소스 문자열을 돌려주는 콜백으로는 `#[bind]` 함수가 채워지지 않는다.

## 결정: 안 C의 꼴, 네이티브 구현

"VM을 만든 쪽이 그 VM이 가져올 수 있는 것을 정한다." 세션 VM은 여전히 `cy.VM()`으로 격리되어 태어나고, CLI가 자기 모듈을
명시적으로 준다. 선택이 조건 1 · 2에서 바로 나오므로 사용자에게 묻지 않고 정했다(요청: "ask the user if the choice is not clear").

~~~cy
-- src/std/cli.cy
fn repl() -> void:
    ctx := cy.REPL.new(new_vm())
    ctx.doc_fn = repl_doc
    ctx.run(repl_read_line_)

fn new_vm() -> cy.VM:
    vm := cy.VM()
    use_cli_modules(vm.inner)
    return vm

#[bind] -fn use_cli_modules(vm Ptr[void]) -> void
~~~

| 조각 | 자리 | 하는 일 |
| --- | --- | --- |
| `cy.REPL.new(vm VM)` | `src/builtins/cy.cy` | 받은 VM에서 세션을 돈다. `REPL.new()`는 `REPL.new(VM())` |
| `cy.REPL.run(read_line)` | 같은 파일 | 소개 줄, 읽고 평가하는 반복. `cy.repl`의 두 오버로드와 `cli.repl`이 쓴다 |
| `cli.new_vm() -> cy.VM` | `src/std/cli.cy` | `cyber`가 돌리는 스크립트가 가져오는 것을 가져오는 VM |
| `use_cli_modules`(private bind) | `src/cli.zig` `useCliModules` | 자식 VM에 user data(공유) · `child_resolver` · `dl_resolver` · `loader`를 건다 |
| `child_resolver` | `src/cli.zig` | main 청크의 uri(`eval` · `which`)는 그대로 돌려주고 `use`는 `resolver`에 넘긴다 |

조건이 지켜지는 이유:

- `cy.VM()` · `cy.eval` · `cy.repl(read_line)` · `cy.repl(read_line, doc)`의 코드 경로가 바뀌지 않았다. `UserVM_init`은 그대로다.
- 모듈을 주는 함수는 `cli` 모듈에 있다. `cli`는 CLI의 loader만 준다. `cli`를 주지 않는 호스트의 스크립트에는 이 함수가 없고,
  `cli`를 주는 호스트는 같은 loader로 `os`도 이미 준다. 스크립트가 새로 얻는 권한이 없다.
- 호스트가 자기 REPL에 자기 모듈을 주고 싶으면 같은 길을 쓴다. 자기 bind 함수가 `cy.VM().inner`(`CLVM*`)에
  `cl_vm_set_resolver` · `cl_vm_set_loader`를 걸고 `cy.REPL.new(vm)`에 넘긴다.

### `cli.new_vm()`을 공개한 이유

`cli.repl()`만 쓰는 private 함수로 둘 수도 있었다. 공개한 이유는 둘이다. 테스트가 세션의 결과를 값으로 확인하려면 VM을 손에
쥐어야 하고(`cli.repl()`은 터미널을 읽는다), F-200과 같은 놀람이 `cy.eval`에도 있다(`cyber`로 돌린 스크립트의 `cy.eval('use os')`가
실패한다). `cy.VM()`은 라이브러리의 VM, `cli.new_vm()`은 CLI의 VM이라는 한 쌍이 된다. 결정(사용자, 2026-11-24: "cli.new_vm() 공개"):
공개로 둔다.

### `cli.App`의 수명 · `reload` · `mod_uris`

- 자식 VM은 부모의 `App`을 가리키기만 한다. 해제는 부모의 `deinit_cli`가 한다. `cli.repl()` 안에서는 `ctx`가 함수 끝에서 죽으며
  자식 VM을 먼저 없앤다. `cli.new_vm()`의 VM을 전역에 둔 스크립트에서는 `main.zig`의 `defer` 순서로 `deinit_cli`가 `vm_deinit`보다
  먼저 돌 수 있지만, VM은 소멸할 때 user data를 읽지 않는다(모듈의 `on_destroy`를 쓰는 표준 모듈이 없다). CLI의 VM 자신이 이미
  같은 순서로 정리된다.
- `App`은 자식에게 읽기 전용이다. `config.reload`는 공유되므로 `cyber -r`의 REPL에서 URL import가 다시 받아진다. http client도
  공유한다(부모는 자식의 eval 동안 멈춰 있다).
- `mod_uris`에 `eval` 같은 이름을 넣지 않았다. 부모의 resolver까지 바뀌기 때문이다. 대신 `child_resolver`가 main 청크의 uri를
  파일로 보지 않는다. `resolver`에 그대로 넘기면 `realpath('eval')`이 실패해 모든 입력이 'Import path does not exist: `eval`'이 된다.
- 모듈 소스의 allocator: `loader`가 파일 · URL 소스를 `App.alloc`으로 읽었는데, VM은 `manage_src` 소스를 자기 allocator로 푼다.
  CLI의 VM에서는 둘이 같지만 자식 VM(`C.vm_init()`의 기본 allocator)에서는 다르다. `loader`가 `C.vm_allocator(vm)`으로 읽게 했다.
  고치기 전에는 세션의 `use a 'a.cy'` 뒤 'free(): invalid pointer'였다.

### 동작

~~~text
$ cyber
> use os
> os.cwd()!
`str` '/home/user/cyber'
> use m 'm.cy'          -- 작업 디렉터리 기준
> use cli               -- REPL 안의 REPL도 된다
~~~

- 파일 import의 기준은 작업 디렉터리다. 세션의 main 청크는 파일이 아니다(`zResolve`의 `dirname(cur_uri) == null` 갈래).
- 세션은 여전히 다른 VM이다. 값 · 전역 · 타입은 세션의 것이고, 세션의 panic은 세션만 리셋한다.
- `os.cwd()`만 넣으면 'Expected to handle the error case for `!str`.' 컴파일 오류다. REPL도 스크립트와 같은 규칙이다.

## 같이 드러난 결함: 세션의 extern 함수 (F-203)

`os`가 열리자 `use math` 뒤 `use os`가 호스트를 끝냈다. `os`와 무관하게 `cy.VM()` 세션에서도 재현되고 변경 전 빌드에서도 같다.
REPL에서 전에는 닿지 않았을 뿐이다(extern 함수가 있는 모듈이 `math` 하나였다).

1. 두 번째 바인딩: `@initBindLib`(`src/builtins/c.zig`)은 VM에 하나뿐인 TCC state에 모든 청크의 extern 함수를 다시 컴파일했다.
   뒤 eval이 extern 함수가 있는 모듈을 올리면 앞 eval의 것까지 다시 나가 `'thread_ret' defined twice` 뒤
   `cy.panic("Failed to compile c source.")`로 abort했다. TCC state는 relocate한 뒤 다시 컴파일하지 못한다.
2. 뒤 eval의 호출 자리: extern 함수를 부르는 자리의 주소는 `@initBindLib` 끝의 `performRtRelocations`가 채운다. `@initBindLib`은
   그 컴파일에 extern 함수가 있는 청크가 있을 때만 불렸다. 앞 eval이 선언한 extern 함수를 뒤 eval이 부르면 주소가 0인 채로
   실행되어 세그폴트였다(REPL: `use libc` 뒤 다음 입력에서 `libc.getenv(s)`).

고친 것:

- `VM.tcc_state` → `VM.tcc_states`. `@initBindLib`은 컴파일할 것이 있을 때마다 새 state를 만들고(`newTccState`) VM이 끝까지 가진다.
- 이미 묶인 함수는 건너뛴다(`isBound`: 그 함수의 `funcSyms` 칸이 채워졌는지). 가변 인자 extern 함수는 자기 바인딩이 없으므로
  state마다 선언한다. extern 함수 포인터 dispatch는 state마다 다시 만든다(대입이라 겹쳐도 된다).
- `emit_program_init_func`(`src/compiler.zig`)은 앞 컴파일의 청크에 extern 함수가 있으면 `@initBindLib`을 부른다. 묶을 것이
  없으면(`hasUnbound`) TCC 없이 relocation만 한다. `performRtRelocations`는 코드가 없는 청크(실패한 컴파일)를 건너뛴다.

고치지 않은 것(F-204): 가변 인자 extern 함수에 `int`를 넘기면(`libc.printf(s, 7)`) 파일로 돌려도 `'Int_0' undeclared` 뒤 abort다.
`i32(7)`은 된다. cgen이 템플릿 별칭이 된 `int`의 C 이름을 선언하지 않는다(F-195가 적은 `mapType` 문제와 같은 뿌리). 세션과
무관하다.

## 다른 언어의 같은 문제

새 실행 환경이 무엇을 볼 수 있는가는 임베딩 언어마다 답이 갈렸고, 크게 "물려받는다"와 "받은 것만 가진다"다.

- Lua: `lua_newstate`(5.1, 2006. 그 전의 `lua_open`도 같다)의 state는 비어 있다. 호스트가 `luaL_openlibs`나 `luaL_requiref`로 연다. 독립 실행기 `lua.c`의 REPL도
  자기 state에 `luaL_openlibs`를 부른다. 이번 결정과 같은 꼴이다: REPL을 띄우는 호스트가 자기 state에 라이브러리를 연다.
- Tcl의 Safe-Tcl(Tcl 7.5, 1996): `interp create -safe`의 자식은 위험한 명령이 숨겨진 채 태어나고, 부모가 `interp alias` ·
  `interp expose`로 준다. 능력을 물려받지 않고 받는다는 원칙의 이른 예다.
- Java의 class loader 부모 위임(JDK 1.2, 1998): 자식 loader가 부모에게 먼저 묻는다. 안 A의 꼴이다. 편하지만 자식이 볼 수 있는
  것을 부모의 구성이 정하게 되어, 격리가 필요할 때마다 위임을 끊는 loader를 따로 써야 했다.
- Python의 `code.InteractiveConsole`: 같은 인터프리터에서 돈다(안 B). 격리가 없는 대신 import가 그대로다.
- Node.js의 `vm.createContext`: 새 context에는 `require`가 없다. 넘긴 객체에 든 것만 보인다(안 C).

Cyber는 이미 받은 것만 가지는 쪽이다(`cl_vm_init`의 VM은 기본 loader만 가진다, resolver로 허용 표를 만든다). 안 A는 그 방향을
REPL 한 곳에서만 뒤집는다.

## 하지 않은 것

- `cy.eval`은 그대로 격리다. CLI 스크립트에서 `os`를 쓰는 eval은 `cli.new_vm().eval(...)`으로 한다.
- 호스트 설정 전체(`deny_raw_ptrs`, 메모리 한도, fuel)를 자식에게 주는 API. 필요한 호스트가 자기 bind 함수에서 건다.
- REPL에서 `os.cwd()`처럼 `!T`를 돌려주는 식을 그대로 보여 주는 것. 스크립트와 같은 규칙으로 둔다.
- F-199(세션에서 앞 입력의 타입에 메서드 선언)는 이 작업에서 고치지 않았다. 따로 고쳤다(`project_session_methods.md`).

## 확인

- behavior `modules/cy.cy`: `cy.VM()`이 `use cli`를 거절하고 세션이 이어짐, `REPL.new()`의 VM도 같음, `REPL.new(vm)`, `REPL.run`.
- behavior `modules/cli.cy`(wasm 포함): `cli.new_vm()`의 `use cli` · builtin 모듈 · 작업 디렉터리 기준 파일 import · 없는 파일의
  오류와 그 뒤 세션 · `which` · 세션 안의 `cli.new_vm()` · `cy.REPL.new(cli.new_vm()).run(...)`.
- behavior `modules/cli_os.cy`(FFI가 있는 native): REPL 세션의 `use os` 뒤 `use math` 뒤 다시 `os`.
- behavior `ffi/session.cy`(F-203): 선언한 eval의 호출, 뒤 eval의 호출, 뒤 eval의 다른 extern 모듈, 뒤 eval의 새 extern 선언,
  가변 인자의 새 시그니처와 쓰던 시그니처, 실패한 컴파일 뒤의 호출.
- `src/tools/verify.sh` 15단계 `15-repl-stdin`: 빌드한 `cyber`에 줄을 파이프로 넣는다(`use math` · `use os` · `use cli` · `use libc`).
  REPL을 stdin으로 모는 첫 자동 확인이다.
