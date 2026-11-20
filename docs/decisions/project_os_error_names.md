# OS 오류의 표준 이름

2026-11-20. 설계 원칙 검토(`docs/study/11-design-principles-review.md`) 1.4 A를 사용자가 0.5에 넣기로 했다("0.5에, 호환성 절로":
옛 이름은 언어 별칭 없이 릴리스 노트의 호환성 절로 처리).

## 지금 (`0cca0bae` 이후 master)

- `os.cy`의 `from_errno`가 errno 여섯 개만 이름을 붙이고(`OperationDenied` · `FileNotFound` · `BadAddress` · `BadFile` ·
  `AccessDenied` · `InvalidArgument`), 나머지는 stderr에 `errno: N`을 찍은 뒤 `error.Unknown`을 돌려준다. Windows에서는 panic.
  흔한 실패(`EEXIST` · `ENOTDIR` · `EISDIR` · `ENOSPC` · `ENOTEMPTY` · `EINTR` · `EAGAIN`)가 모두 `Unknown`이다.
- `os.windows.cy`는 자체 표로 `FileNotFound` · `AccessDenied` · `BadFile` · `OutOfMemory` · `InvalidArgument` · `FileExists` ·
  `Unknown`을 쓴다. 같은 실패가 플랫폼마다 다른 이름이다(`EEXIST`는 `Unknown`, Windows는 `FileExists`).
- 거부가 `AccessDenied` · `OperationDenied` 두 이름이다. 스크립트(특히 모델이 쓴 코드)가 이름으로 분기하면 틀린다.
- Zig 쪽 네이티브의 `error.UnknownError` · `error.Unexpected`는 스크립트에 값으로 오지 않는다(`zErrFunc`가 panic으로 바꾼다).

## 다른 언어 (일반 지식)

- Rust `std::io::ErrorKind`: `NotFound` · `PermissionDenied` · `AlreadyExists` · `NotADirectory` · `IsADirectory` ·
  `DirectoryNotEmpty` · `StorageFull` · `TimedOut` · `Interrupted` · `WouldBlock` · `BrokenPipe` · `ConnectionRefused` ·
  `InvalidInput` · `OutOfMemory` · `Unsupported` · `ReadOnlyFilesystem` · `CrossesDevices` · `InvalidFilename` · `Other` 등.
  `EPERM`과 `EACCES`를 함께 `PermissionDenied`로 본다. 원래 코드는 `raw_os_error()`로 남긴다.
- Zig `std.fs` · `std.posix`: 함수마다 오류 집합이 따로다(`FileNotFound` · `AccessDenied` · `PathAlreadyExists` · `NotDir` ·
  `IsDir` · `NoSpaceLeft` · `WouldBlock` 등). 이름이 세밀하지만 함수마다 달라 스크립트의 분기 기준으로는 넓다.
- Python: `OSError`의 하위 클래스(`FileNotFoundError` · `PermissionError` · `FileExistsError` · `NotADirectoryError` ·
  `IsADirectoryError` · `TimeoutError` · `InterruptedError` · `BlockingIOError` · `BrokenPipeError` · `ConnectionRefusedError`)와
  `errno` 속성. `EPERM` · `EACCES`가 함께 `PermissionError`다.
- Nim: `OSError`에 `errorCode`(원래 코드)를 담는다. Nimony는 `ErrorCode`라는 고정 어휘를 두고 errno · Windows · HTTP와 양방향으로
  옮긴다(검토 문서 1.3.2).

공통점: 원인별 작은 고정 어휘 하나, 접근 거부는 하나로 합침, 원래 코드는 따로 꺼낼 수 있음.

## 결정

- 이름은 Rust와 검토 문서의 제안을 따른다. 사이버의 `error`는 이름 값이라 새 모듈 없이 `os`가 이 이름들을 돌려준다(검토 문서의
  가칭 `errors` 모듈 · `to_http_status`는 쓰는 곳이 생길 때까지 두지 않는다).

  | 이름 | errno (POSIX) | Windows |
  |---|---|---|
  | `NotFound` | `ENOENT` | `ERROR_FILE_NOT_FOUND` · `ERROR_PATH_NOT_FOUND` |
  | `PermissionDenied` | `EPERM` · `EACCES` | `ERROR_ACCESS_DENIED` · `ERROR_SHARING_VIOLATION` |
  | `AlreadyExists` | `EEXIST` | `ERROR_ALREADY_EXISTS` · `ERROR_FILE_EXISTS` |
  | `NotADirectory` | `ENOTDIR` | `ERROR_DIRECTORY` |
  | `IsADirectory` | `EISDIR` | |
  | `DirectoryNotEmpty` | `ENOTEMPTY` | `ERROR_DIR_NOT_EMPTY` |
  | `NoSpace` | `ENOSPC` | `ERROR_DISK_FULL` · `ERROR_HANDLE_DISK_FULL` |
  | `ReadOnly` | `EROFS` | `ERROR_WRITE_PROTECT` |
  | `NameTooLong` | `ENAMETOOLONG` | `ERROR_FILENAME_EXCED_RANGE` |
  | `TooManyOpenFiles` | `EMFILE` · `ENFILE` | `ERROR_TOO_MANY_OPEN_FILES` |
  | `Busy` | `EBUSY` | `ERROR_BUSY` |
  | `CrossesDevices` | `EXDEV` | `ERROR_NOT_SAME_DEVICE` |
  | `Interrupted` | `EINTR` | |
  | `WouldBlock` | `EAGAIN` | |
  | `TimedOut` | `ETIMEDOUT` | `ERROR_TIMEOUT` |
  | `BrokenPipe` | `EPIPE` | `ERROR_BROKEN_PIPE` · `ERROR_NO_DATA` |
  | `ConnectionRefused` | `ECONNREFUSED` | |
  | `OutOfMemory` | `ENOMEM` | `ERROR_NOT_ENOUGH_MEMORY` · `ERROR_OUTOFMEMORY` |
  | `InvalidArgument` | `EINVAL` · `EBADF` · `EFAULT` | `ERROR_INVALID_PARAMETER` · `ERROR_INVALID_HANDLE` · `ERROR_INVALID_NAME` |
  | `Unsupported` | `ENOSYS` · `ENOTSUP` | `ERROR_NOT_SUPPORTED` · `ERROR_CALL_NOT_IMPLEMENTED` |
  | `Unknown` | 그 밖 | 그 밖 |

- 매핑은 `os.from_errno(code int) -> error`(공개, FFI로 libc를 직접 부른 스크립트도 쓴다)와 Windows의 `from_win32_error` 한곳에
  둔다. 원래 코드는 `os.last_os_error() -> int`로 꺼낸다(Rust `raw_os_error`, Python `errno`). `Unknown`일 때 stderr에 찍던
  것은 뺀다(라이브러리가 출력을 더럽히지 않는다).
- errno 번호는 34 이하만 Linux · macOS가 같다. 그 위(`EAGAIN` · `ENAMETOOLONG` · `ENOTEMPTY` · `ENOSYS` · `ENOTSUP` ·
  `ETIMEDOUT` · `ECONNREFUSED`)는 플랫폼별 상수로 둔다.
- 옛 이름(`FileNotFound` · `AccessDenied` · `OperationDenied` · `FileExists` · `BadFile` · `BadAddress`)은 언어 별칭 없이
  사라진다. 0.5 릴리스 노트의 호환성 절에 옛 → 새 표를 둔다. OS와 관계없는 `os`의 이름(`Closed` · `NotAllowed` · `Unicode`)은
  그대로다.
