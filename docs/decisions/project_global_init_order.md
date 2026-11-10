# 전역 초기화 순서와 초기화식 검사 (2026-11-10, F-88)

## 배경

전역 변수는 프로그램 시작 때 정해진 순서로 초기화된다. 초기화식 안에서 다른 전역을 이름으로 쓰면
`Cannot reference globals in a global initializer.`로 막지만, 초기화식이 부른 함수의 본문은 보지 않았다. 그래서 함수가 아직
초기화되지 않은 전역을 읽거나 쓰면 정의되지 않은 메모리를 건드렸다.

- `global a str = foo()` · `global b str = "hello".upper()` · `fn foo() -> str: return b + "!"`: ReleaseSafe CLI가
  `panic: integer does not fit in destination type`으로 abort(종료 코드 134).
- `foo`가 초기화 중인 자기 전역에 대입(`global a []int = foo()`, 본문 `a = []int{1, 2, 3}`): 옛 값을 파괴하려다
  `Segmentation fault at address 0xaaaaaaaaaaaaaaa6`.
- 정수 전역은 쓰레기 값을 조용히 읽는다(`-6148914691236517205`).
- 모듈 사이도 같았다. `@program_init`은 청크 id 순서(main → core → 가져온 모듈)로 `@init`을 불렀다. `use lib './lib.cy'` 뒤
  `global x int = lib.compute()`는 `lib`의 전역이 초기화되기 전에 `compute`를 불러 쓰레기 값을 얻었다. core의 전역
  (`Wyhash.secret`)도 main의 초기화식보다 늦게 초기화됐다.

주석 처리돼 있던 `vars/global_init_call_error.cy`(`Expected pure function.`)가 예전 검사의 흔적이고 지금 소스에는 그 검사가 없었다.

## 검토한 방법

1. 정적 검사: 초기화식에서 도달하는 함수가 아직 초기화되지 않은 전역을 건드리면 컴파일 오류. 런타임 비용이 없고 매뉴얼의
   `global a int = load_a()`가 그대로 된다. 간접 호출은 보수적으로 봐야 해서 정상 프로그램을 거부할 수 있다.
2. 런타임 검사: 전역마다 초기화 플래그를 두고 접근마다 확인. 정확하지만 전역 접근(지금은 절대 주소 `const` + `load`)마다 비용이 붙는다.
3. 초기화식에서 사용자 함수 호출 금지. 매뉴얼 예제와 충돌하고 기존 스크립트가 깨진다.

사용자 결정(2026-11-10): 1번.

## 결정

### 초기화 순서

- 청크는 자기가 `use`로 가져온 청크 다음에 초기화된다. core(builtins 청크)가 맨 앞이다. 청크 안에서는 선언 순서 그대로다.
- 순환 import는 먼저 방문한 쪽에서 끊는다(id가 작은 청크부터 깊이 우선, 후위 순서). 끊긴 방향의 접근은 아래 검사가 잡는다.
- `@program_deinit`은 그 역순으로 `@deinit`을 부른다. 가져온 모듈의 전역은 가져다 쓴 쪽의 전역이 파괴된 뒤에 파괴된다.
  (이전에는 초기화와 같은 id 순서였다. main이 먼저라 결과적으로 비슷했지만 모듈끼리의 순서는 로드 순서였다.)
- 구현: `Chunk.imports`(`sema.declareUseImport`가 채움), `global_init.initOrder`. `emit_program_init_func` ·
  `emit_program_deinit_func` · 검사가 같은 함수를 쓴다. 앞선 eval의 청크는 이미 초기화됐으므로 순서에 들지 않는다
  (`VM.validate`만 거쳐 `@init`이 아직 안 돈 청크는 든다, F-05).

### 검사

sema가 함수마다 세 가지를 적는다(`global_init.Deps`, `Func.deps`). 전역 초기화식의 것은 `UserVar.init_deps`에 적는다.

- 건드린 사용자 전역(`sema.symbol`의 `.userVar` 분기. 읽기 · 쓰기 · 주소 모두).
- 이름으로 부른 함수(`.call` IR을 만드는 두 곳: `sema_call_ir`, `sema_func`의 결과 처리).
- 간접 호출이 있는지(`.call_ptr` · `.call_union` · `.call_trait` · `@gen_next`).

모든 함수 본문의 sema와 trait 구현 연결이 끝난 뒤 `global_init.check`가 초기화 순서대로 전역을 훑는다. 초기화식에서 시작해
이름으로 부른 함수를 따라가며, 도달한 함수가 자기보다 늦게 초기화되는 전역이나 초기화 중인 자기 자신을 건드리면 그 초기화식
위치에 컴파일 오류를 낸다.

```
CompileError: The initializer of `a` can reach `bar`, which accesses the global `b`. `b` is initialized after `a`.
CompileError: The initializer of `a` can reach `foo`, which accesses `a` before it is initialized.
```

간접 호출은 호출 대상을 모른다. 도달한 함수에 간접 호출이 하나라도 있으면 "값으로 쓰인 적이 있는 함수 전부"로 번진다고 본다.

- 값으로 쓰인 함수: 함수 이름을 값으로 쓴 곳(`.func_ptr` IR), 람다 · 클로저, 제너레이터 함수(`FuncInfo.escaped`).
- trait 메서드를 구현한 메서드 전부(`Struct.impls()[i].funcs`). trait 객체를 실제로 만들었는지는 보지 않는다.
- 함수 값 매개변수를 받는 호스트 함수 호출도 간접 호출로 본다(콜백을 부를 수 있다).
- 제너레이터 함수 호출은 본문을 실행하지 않으므로 따라가지 않고, 본문은 `next()`(`@gen_next`)의 간접 호출 대상이 된다.
  `global gen ^Generator[F] = make()`에서 본문이 `gen`을 읽는 것은 허용된다(`concurrency/generator.cy`).

암묵 호출도 `.call` IR로 나가므로 같이 잡힌다: 연산자 메서드, `@init`, 지역이 죽을 때의 `@deinit`, 템플릿 함수 인스턴스.

## 오탐과 그 대처

검사는 "도달할 수 있다"를 본다. 실제 실행 경로가 그 전역을 건드리지 않아도 오류가 될 수 있다.

- 조건 분기 안의 접근(`if false: return b`)도 접근으로 센다.
- 간접 호출이 하나 있으면 프로그램의 모든 함수 값 · trait 구현이 후보가 된다. 초기화식이 `arr.sort(|x, y| ...)`를 쓰는 함수를
  부르고, 관계없는 다른 람다가 더 늦은 전역을 읽으면 오류다.

대처는 모두 선언 순서다. 읽히는 전역을 그것을 읽는 초기화식보다 먼저 선언하거나, 초기화식을 상수로 두고 main이나 `init()`
함수에서 값을 넣는다. 오류 메시지가 두 전역의 이름과 접근하는 함수를 알려 준다.

## 한계

- 호스트 함수가 인자로 받지 않은 스크립트 함수를 부르는 경우(객체 필드에 든 함수 값, 호스트가 따로 쥔 콜백)는 보지 않는다.
- `spawn`한 스레드가 초기화 중에 전역을 건드리는 경우는 보지 않는다.
- 호스트 전역(`hostVar`)과 `extern` 전역은 대상이 아니다(호스트 · 링커가 초기화).
- `#[extern]` 전역은 초기화식에서 이름으로 쓸 수 없다(`Cannot reference an extern global in a global initializer.`). extern 심볼은
  모든 `@init` 뒤의 `@initBindLib`에서 묶인다. 초기화식이 부른 함수가 extern 전역 · extern 함수를 쓰는 경우는 검사하지 않는다.
- 순환 import에서 양쪽 초기화식이 서로의 전역에 닿으면 한쪽은 반드시 오류다.

## 초기화식의 직접 참조 (같은 날 추가, 사용자 결정)

검사가 생기기 전에는 초기화식 안에서 전역을 이름으로 쓰는 것을 통째로 막았다(`Cannot reference globals in a global initializer.`).
앞에 선언된 전역도 함수를 거쳐야만 읽을 수 있어 규칙이 어긋났다. 이제 같은 기준 하나로 본다.

- 초기화식이 이름으로 쓴 사용자 전역은 `UserVar.init_deps.globals`에 적힌다(함수 본문과 같은 `recordGlobal`).
- `check`가 초기화식의 직접 참조를 먼저 본다. 더 늦게 초기화되는 전역이면
  ``The initializer of `b` accesses the global `a`. `a` is initialized after `b`.``, 자기 자신이면
  ``The initializer of `a` accesses `a` before it is initialized.``
- 가져온 모듈의 전역(`lib.x`)은 먼저 초기화되므로 쓸 수 있다. 앞선 eval의 전역도 쓸 수 있다.
- 호스트 전역(`#[bind] global`)은 모듈 로드 때 묶이므로 허용한다.
- 오류 위치는 참조한 식이 아니라 초기화식 전체다(참조 노드를 따로 적지 않는다).

## 테스트

- behavior: `vars/global_init_ref_error.cy` · `global_init_ref_self_error.cy`(직접 참조), `vars/global_init_call.cy`(이름으로 쓰기, 앞선 전역 읽기 · 쓰기, 함수 값, 제너레이터, 콜백, trait, 가져온 모듈의 전역),
  `vars/global_init_call_error.cy`(전이 호출), `…_self_error.cy`, `…_lambda_error.cy`, `…_trait_error.cy`, `…_deinit_error.cy`,
  테스트 모듈 `modules/test_mods/ginit.cy`.
- lib: `A global initializer can call a function that reads a global of an earlier eval.`(`persist_main` 세션, 오류 뒤 세션 유지).
