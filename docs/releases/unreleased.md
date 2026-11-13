# 0.4.10 이후 변경 (미릴리스)

0.4.10(2026-11-13) 뒤 master에 들어간 변경을 커밋 순으로 모은다. 다음 릴리스 노트와 `docs/docs.md` 매뉴얼 갱신의 원본이다.
사용자에게 보이는 동작이 바뀌는 커밋은 여기에 바로 적고, 언어 규칙이면 `docs/docs.md`에도 같이 적는다.
전체 발견 이슈 표는 `docs/study/10-findings-register.md`, 컴파일러 한계의 결정은 `docs/decisions/project_compiler_limits.md`.

## 버그 수정

- `!T`의 `T`가 관리되는 타입(`str`, `[]T`, 객체)이면 값을 복사하지 못했다: `y := x`, `print(f())`, `Future[!str]`의
  `await`가 ``Expected type instance of `Result`, found `Ptr[!str]`.``(위치 `core:2918`)로 컴파일되지 않았다.
  `@copy`의 result 분기가 오류 값을 읽을 때 포인터를 역참조하지 않았다. 호스트가 `Future[!str]` · `Future[![]int]`를
  돌려주고 값이나 오류로 완료할 수 있다(F-119, tars-agent M0 스파이크).
- 세션(`persist_main`이나 `cl_vm_validate`로 이어지는 VM)에서 컴파일이 실패하면 다음 컴파일이 프로세스를 죽일 수 있었다
  (Segmentation fault). 실패한 컴파일이 코어 템플릿을 펼친 인스턴스(`[]str`의 `sort`, `Map[str, int]`의 메서드)는
  캐시에 남는데 본문 검사와 코드 생성은 버려진 chunk와 함께 사라졌고, 실패한 컴파일이 처음 불러온 모듈은 코드 없이
  모듈 캐시에 남았다. 이제 다음 컴파일이 그런 인스턴스의 본문을 다시 검사해 코드를 만들고, 그런 모듈은 다음 `use`에서
  다시 불러온다. 다시 검사한 본문이 컴파일되지 않으면(`Map[[]int, int]`처럼 앞의 오류 때문에 검사되지 않았던 것)
  그 인스턴스를 버리고 같은 소스를 다시 컴파일하므로, 그 오류가 관계없는 다음 eval에 보고되지 않는다. 같은 인스턴스를
  다시 쓰면 "because of an earlier error" 오류다. 첫 컴파일이 실패하면 VM을 리셋하는 것은 그대로다(F-120,
  tars-agent M0 스파이크).

## 언어와 표준 라이브러리

## 임베딩 API

## 변경

## 문서
