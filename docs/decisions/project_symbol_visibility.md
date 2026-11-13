# `-` 가시성 강제 (2026-11-09, F-30)

## 배경

매뉴얼(`docs/docs.md` Symbol visibility · Field visibility)은 `-` 접두가 붙은 심볼과 필드를 "선언한 모듈 안에서만 접근할 수 있다"고
적는다. 실제로는 파서가 `hidden` 플래그를 AST에 남길 뿐이고, sema는 `type_alias` · `type_const` · `use_alias` · 청크 심볼에만
`Sym.metadata.private`를 세웠다. 강제되는 곳은 `use *`가 `private` 심볼을 건너뛰는 것 하나였다(`sema.declareUseImport`).

- `use p 'mods/priv.cy'` 뒤 `p.secret()`(`-fn`), `p.Info{a=1, b=2}.b`(`-b` 필드), `p.counter`(`-global`), `p.Hidden{}`(`-type`)이
  모두 통과했다(02장 §5.15 재현).
- `type Foo:`(struct · cstruct) · `trait` · `cunion` 선언은 AST 노드에 `hidden` 필드 자체가 없어 `-type Foo:`의 `-`가 버려졌다.
- 임베딩 환경에서 호스트 모듈의 내부 함수를 `-`로 감추는 용도(샌드박스 경계)로 쓸 수 없었다.

## 결정

- 모듈은 청크(파일)다. `-`로 선언한 심볼은 같은 청크의 코드만 이름으로 접근할 수 있다. 대상은 `fn`(메서드 포함) · `global` ·
  `const` · 타입(struct · cstruct · enum · choice · trait · cunion · `#[bind] type X _`) · 타입 템플릿 · 함수 템플릿 · 타입 별칭 ·
  `type X const` · 필드다. `use` 별칭은 전부터 private(매뉴얼 "Any symbol alias declared from `use` is not exported").
- 접근하는 쪽은 `c`(sema가 도는 청크)가 아니라 접근 노드의 청크(`node.src()`)다. core.cy의 템플릿 본문(`Array[T]`)이 사용자 타입으로
  확장될 때도 core의 `-fn compute_new_cap`을 그대로 부를 수 있어야 하고, 사용자 청크 문맥에서 평가되는 필드 기본값도 선언 파일 기준으로
  판정돼야 하기 때문이다(F-06 `deny_raw_ptrs`와 같은 기준).
- `persist_main` 세션(REPL · 임베딩의 연속 eval)은 main 청크가 eval마다 새로 만들어지지만 `srcUri`가 같다. `srcUri`가 같은 청크는 같은
  모듈로 본다. 앞 eval이 선언한 `-fn (&Foo) m()`을 다음 eval이 `f.m()`으로 부를 수 있다. 앞 eval의 최상위 선언은 `use_alias`로
  넘어오는데 별칭은 현재 청크 소유라 어차피 통과한다.
- 검사 위치는 이름으로 심볼을 찾는 한 곳 `module.getResolvedSym`(모듈 · 타입 멤버 · 템플릿 인스턴스 멤버)과, 필드를 `getMod().getSym`으로
  직접 찾는 sema의 네 곳(필드 읽기 · 포인터 필드 · 필드 대입 · 레코드 초기화)이다. 별칭은 찾은 별칭 심볼 자체를 검사하고 가리키는
  대상은 검사하지 않는다. 그래서 `use *`로 들여온 공개 심볼과 `persist_main` 별칭은 통과한다. `use` 별칭(`use_alias` · `module_alias`)은
  전부터 private이지만(`use *`가 다시 내보내지 않도록) 검사에서 제외해 한정 경로 `libc.macos.Stat`은 그대로 열어 둔다
  (`modules/libc.cy` 테스트가 의존, 매뉴얼 "not exported"는 `use *` 기준).
- 폴백 모듈(core) 조회 `get_pub_resolved_chunk_sym`은 private 심볼을 "없음"으로 본다. 사용자 스크립트의 맨 `alloc_(8)` · `panic_oob(1)`은
  `Undeclared variable`이다(이전에는 core 내부 함수가 그대로 불렸다).
- 오버로드는 가시성이 같아야 한다. `fn f(a int)` 뒤 `-fn f(a float)`는 컴파일 오류 ``Overloads of `f` must have the same visibility.``.
  템플릿 인스턴스의 `variant_func` 오버로드도 같은 규칙이다.
- 오류 메시지: ``Can not access the private symbol `secret` in `a`. A symbol declared with `-` is only visible to the module that declares it.``
  필드는 ``Can not access the private field `b` in `Info`. ...``. `in` 뒤는 심볼의 부모(모듈 별칭 이름 또는 타입 이름)다.
- 메타프로그래밍(`type.info(T).fields`, `#[bind]` 호스트 바인딩, 컴파일러가 이름으로 찾는 `@init` · `@deinit` 등 `@` 메서드)은 검사하지
  않는다. 매뉴얼의 "metaprogramming can get around this constraint"를 유지한다. 컴파일러가 만드는 `@program_init` · `@init` · `@deinit`
  청크 함수는 `hidden = true`로 예약되어 이제 private이지만 `getMod().getSym`으로 직접 찾으므로 영향이 없다.
- AST: `StructDecl` · `TraitDecl` · `CUnionDecl`에 `hidden bool`을 추가하고 `src/builtins/cy.cy`의 미러 구조체도 같이 고친다.
  `TemplateDecl`은 `child_decl`의 `hidden`을 쓴다(`ast.isHiddenDecl`).

## 영향

- 표준 모듈의 `-fn`(core `alloc_` · `eprints_` · `prints_` · `log_` · `panic_oob` · `to_elem_string` · `compute_new_cap` ·
  `HashMap.findSetSlot`, math `c_*`, cy `parse_`, libc `-type c_int`)은 이제 사용자 스크립트에서 보이지 않는다. 모두 모듈 안에서만
  쓰이던 것이고 테스트 전체가 통과한다.
- 기존 테스트 `syntax/visibility.cy`는 같은 모듈 안 접근이라 그대로 통과한다.

## 남은 것

- `-`가 붙은 심볼을 `use *`가 건너뛰는 것은 전부터 그랬고 바뀌지 않았다. 숨은 심볼을 들여오려 하면 `Undeclared variable`이다.
- trait 선언 안의 `-fn`은 파서가 받지 않는다(가시성 없음). trait 메서드는 항상 공개다.
- enum · choice의 case에는 `-`가 없다.
- 타입 별칭 `type Pub = Priv`가 private 타입을 공개 이름으로 내보내는 것은 막지 않는다(별칭은 같은 타입을 가리키므로 멤버 접근은 타입
  심볼 기준으로 검사된다. 즉 `p.Pub{}`은 되고 `p.Priv{}`은 안 된다).

## 2026-11-13 보충: `meta.access` (F-116)

위 결정의 "메타프로그래밍은 검사하지 않는다"가 `meta.access`에는 적용돼 있지 않았다. `meta.access(x, name)`은
`sema.semaAccessExpr2`를 그대로 불러 `x.name`과 같은 검사를 받았고, 접근 노드가 `core.cy`에 있으므로 사용자 타입의
private 필드에서 막혔다. `to_print_string` · `dump_str` · `@eq` · `@destruct`가 `type.info(T).fields`를 돌며 `meta.access`로
필드를 읽기 때문에, private 필드가 하나라도 있는 struct는 `print(v)` · `'%{v}'` · `v == w`가 컴파일되지 않았다
(같은 모듈 안에서도. 접근하는 쪽이 `core`이기 때문이다).

- `meta.access`가 값의 필드를 읽을 때는 가시성을 검사하지 않는다(`sema.semaMetaAccess` → `semaAccessFieldName`의
  `check_visible = false`). `type.info`가 private 필드를 이미 나열하므로 이름을 감추는 효과는 원래 없었다.
- `meta.access`의 받는 쪽이 모듈이나 타입일 때(`meta.access(mod, 'name')`)는 `mod.name`과 같이 검사한다. 값의 필드만 연다.
- `v.secret`으로 직접 쓴 접근, 초기화 · 대입 · 주소 취하기는 그대로 오류다.
- 출력은 private 필드를 다른 필드와 같이 보여 준다(`Vec2{x=1, secret=2}`). 출력은 디버깅 수단이고 값을 통째로 보여 주는 것이 일이다.
  감춰야 하는 값은 타입이 출력 방법을 직접 정한다.

테스트 `modules/private_field_meta.cy`.
