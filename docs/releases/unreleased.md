# 0.4.8 이후 변경 (미릴리스)

0.4.8(2026-11-12) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

- `r64` → `float` · `f32` 변환이 값을 부호 있는 정수로 읽었다. `var r r64 = 0xFFFFFFFFFFFFFFFF` 뒤 `float(r)`이
  `-1.0`이었고 이제 `18446744073709551615.0`이다(VM 명령 `U2F` · `U2F32`). `byte` · `r16` · `r32`는 원래 맞았다.
- `float` → raw 정수(`r64(x)` · `byte(x)` 등)는 `x`가 `float` 변수이면 `Expected type f32, got float.` 컴파일 오류였다.
  이제 부호 없는 값으로 변환한다. 2^63 이상도 `r64`에 들어가고, 음수 · NaN · 범위 밖은
  ``panic: Lossy conversion to `r64`.``다. `f32`에서 오는 변환도 같은 규칙을 따른다(이전에는 `r32(4294967295.0)`에
  해당하는 값이 panic이었다).

- `fiber Job.peek(&job)`처럼 타입 경로로 댄 진입점은 빌림 매개변수 검사를 건너뛰었다. `&T` 수신자 메서드가
  fiber에 스택 빌림을 넘길 수 있었다. 이제 이름 하나로 댄 진입점과 같이
  `Cannot borrow a stack value across fibers.` 컴파일 오류다. generator · 비-void 반환 검사도 같이 적용된다.

## 언어와 표준 라이브러리

- 한 번도 `resume`하지 않은 fiber를 소멸할 수 있다. 진입 함수는 불리지 않고 인자만 해제된다. 이전에는
  `panic: Fiber is still in progress.`였다. 한 번이라도 resume한 뒤 끝나지 않은 fiber의 소멸은 여전히 panic이다.
- `fiber obj.work()`는 ``Type `T` does not have a field named `work`.`` 대신 대체 표기를 알려 주는 오류를 낸다.
  메서드를 진입점으로 쓰려면 타입으로 이름을 대고 수신자를 첫 인자로 넘긴다: `fiber Job.work(job, 2)`.

## 임베딩 API

## 변경

- `cyber fmt`가 리터럴 필드의 `=` 양쪽을 한 칸 띄운다: `Vec2{x=1, y=2}` → `Vec2{x = 1, y = 2}`. 이전에는 쓴 그대로
  두었다. 속성(`#[extern='puts']`) 안의 `=`는 계속 쓴 그대로 둔다. 이미 포맷한 파일도 `x=1`로 쓴 곳이 있으면
  다시 바뀐다. `examples/fmt.cy`도 같은 규칙을 따른다.

## 문서
