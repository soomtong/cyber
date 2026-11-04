# `str.decode` 폐기와 `str.from_utf8`

작성일 2026-11-04.

## 배경

`str.decode`는 선언 · 바인딩 · 구현이 모두 주석 처리되거나 참조되지 않은 채 남아 있었다(upstream `b751ca6c` 이전부터).
옛 구현 `String_decode2`는 `[]byte`를 받아 UTF-8을 검증하고 같은 버퍼를 가리키는 `str`을 돌려줬으며, 인코딩 인자는
`.utf8`만 받았다. 삭제된 heap API(`newAstrSlice`)를 써서 컴파일되지 않아 미참조 decl 정리(2026-11-04)에서 지웠다.

지금 바이트에서 문자열을 만드는 길은 `str(bytes)`(`str :: @init(PtrSpan[byte])` → `heap.init_str`)뿐인데, ASCII 여부만
보고 UTF-8 유효성은 검사하지 않는다. 깨진 바이트도 `str`이 되고, `count()`처럼 유효한 UTF-8을 전제로 코드포인트를 걷는
함수가 잘못된 값을 낼 수 있다. `File.read_all()`이 `[]byte`를 주므로 외부 입력은 모두 이 길을 지난다.

## 결정

- `str.decode`는 되살리지 않는다. 지원 인코딩이 UTF-8 하나이고 다른 인코딩 변환 계획이 없으므로 인코딩 인자는 API 표면만
  넓힌다. 선언 주석도 지웠다.
- 검증하는 생성자 `str.from_utf8(bytes) -> !str`을 추가한다(`PtrSpan[byte]` · `[]byte` 오버로드). 실패는 `error.Unicode`.
  검증은 host 함수 `str.is_utf8(span PtrSpan[byte]) -> bool`(`string.validateUtf8`)로 하고 이것도 공개한다.
- `str(bytes)`는 그대로 둔다. 검증을 넣어 `!str`로 바꾸면 기존 호출부가 전부 `!`를 달아야 해 호환이 깨진다. 대신 doc 주석과
  `docs/docs.md`에 검증하지 않는다는 점과 `from_utf8`을 적었다.
- 옛 구현처럼 복사 없이 버퍼를 공유하지 않는다. `str(bytes)`와 같은 복사 경로를 쓴다(단순함 우선, 필요하면 나중에).

## 테스트

`src/test/core/strings_utf8.cy` 끝: 유효한 바이트 · 빈 바이트는 문자열, 잘못된 선두 바이트 · 잘린 시퀀스 · overlong 인코딩은
오류, `str(bytes)`는 같은 입력을 거부하지 않음.
