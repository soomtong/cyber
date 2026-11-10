# 할당 실패 퍼즈

호스트 할당자가 eval 하나의 N번째 할당에서 실패할 때 VM이 abort나 누수 없이 오류를 돌려주는지 본다.
N마다 새 프로세스를 띄우고, 누수 검사를 하는 테스트 할당자 위에 `ProbeAlloc`을 얹는다.
배경과 처리 설계는 `docs/decisions/project_compile_alloc_failure.md`에 있다.
평소 회귀를 보는 `FailingAlloc` 테스트 둘은 `src/lib_test/alloc_fail.zig`에 있다.

## 파일

- `probe.zig`: `ProbeAlloc`, 퍼즈 스크립트 둘(`probe_src`, `probe_src2`), lib 테스트 `PROBE`. 빌드에 포함되지 않는다.
- `fuzz.sh`: 빌드 · 실행 · 집계 명령.
- `run_one.sh`: N 하나를 실행하고 결과 한 줄을 `summary.txt`에 붙인다. `fuzz.sh run`이 `xargs`로 부른다.
- `agg.py`: 결과 디렉터리를 집계한다.

## 쓰는 법

저장소 어디에서 실행해도 된다. 결과는 `zig-out/alloc_fuzz/`에 쌓인다(git이 무시하는 경로). `rg`와 `python3`이 필요하다.

```sh
src/tools/alloc_fuzz/fuzz.sh build            # 프로브 바이너리 빌드(약 15초)
src/tools/alloc_fuzz/fuzz.sh count 0          # 시나리오 0의 할당 횟수(total=)
src/tools/alloc_fuzz/fuzz.sh run s0 0 10600   # 시나리오 0, N = 1..10600, 한 번만 실패
src/tools/alloc_fuzz/fuzz.sh run s0k 0 10600 1  # 같은 범위, N번째부터 전부 실패
src/tools/alloc_fuzz/fuzz.sh run s1 1 500     # 시나리오 1
src/tools/alloc_fuzz/fuzz.sh where 0 4321     # N = 4321에서 실패한 할당의 스택
src/tools/alloc_fuzz/fuzz.sh agg s0           # 집계만 다시
```

- `build`는 `probe.zig`를 `src/lib.zig` 끝에 덧붙여 `zig build build-test -Dtest-filter=PROBE`로 빌드하고 `src/lib.zig`를
  되돌린다. 필터 때문에 `behavior_test` · `trace_test`가 링크 오류를 내 `zig build`는 rc=1로 끝나지만 `lib_test`는
  만들어진다. 스크립트는 `src/` 안의 컴파일 오류와 `lib_test` 유무만 본다. 중간에 강제 종료되면 원본이
  `zig-out/alloc_fuzz/lib.zig.orig`에 남는다. `probe.zig`는 `src/lib.zig`가 선언한 `std` · `zt` · `C`를 쓰므로 그 이름들은
  `src/lib.zig`에 남겨 둔다.
- 소스를 고치면 `build`를 다시 한다. 할당 횟수도 달라지므로 `count`로 `run`의 범위를 다시 정한다. 범위는 횟수보다
  조금 크게 잡는다(넘는 N은 실패 없이 성공으로 끝난다).
- 시나리오 0은 새 VM의 첫 eval이다. 시나리오 1은 `persist_main` 세션에서 `probe_src`를 실패 없이 돌린 뒤 두 번째
  eval(`probe_src2`)에서만 실패시킨다.
- `JOBS`(기본 8)가 동시 프로세스 수다. 시나리오 0 전체는 `JOBS=8`로 약 25분, 시나리오 1은 약 2분 걸린다.
  테스트나 벤치와 같이 돌리지 않는다.
- `FUZZ_OUT`으로 결과 위치를 바꾼다. 같은 이름의 결과 디렉터리가 있으면 `run`은 멈춘다.
- 다른 문법 · 모듈 로더 · `spawn` 경로를 보려면 `probe.zig`의 `probe_src` · `probe_src2`를 바꾼다.

## 결과 읽기

`summary.txt`의 한 줄은 `N 종류 | PROBE n=.. total=.. fired=.. r1=.. r2=.. r3=.. | 오류 요약 첫 줄`이다.

| 종류 | 뜻 |
|---|---|
| `ok` | 프로세스가 0으로 끝났다. abort도 누수도 없고 실패 뒤의 eval(`r3`)도 성공했다 |
| `leak` | 테스트 할당자가 누수를 보고했고 그 밖의 문제는 없다 |
| `crash` | 그 밖의 전부(panic, 시그널, 해제되지 않은 객체) |

`ok`가 아닌 N의 로그는 `<결과 디렉터리>/N.log`에 남는다. `agg.py`는 종류별 개수, 결과별 개수, 그리고 crash · leak을
저장소 안의 위쪽 프레임으로 묶어 자리별 개수와 예시 N을 낸다. 목표는 `ok`만 남는 것이다.

`r1` · `r2` · `r3`은 첫 eval · 두 번째 eval(시나리오 1) · 실패 뒤의 확인 eval의 결과 코드다.

| 값 | 코드 | 실패한 곳 |
|---|---|---|
| 0 | `CL_SUCCESS` | 실패한 할당이 결과에 영향을 주지 않았다(예: 실패한 `resize` 뒤의 새 할당) |
| 2 | `CL_ERROR_COMPILE` | 컴파일러. 요약은 `OutOfMemory`나 `WriteFailed`, 리포트 메모리도 없으면 빈 문자열 |
| 3 | `CL_ERROR_PANIC` | 실행 중. `panic: OutOfMemory` |
| 4 | `CL_ERROR_UNKNOWN` | 실행 뒤 정리 |
| 99 | | 실행하지 않음 |

## 기준 수치

2026-11-10, `87248791`. 수정 전은 그 부모 커밋이다.

| 실행 | 수정 전 | 수정 뒤 |
|---|---|---|
| 시나리오 0, 한 번 실패, N 1..10600 | ok 8554 · leak 1261 · crash 629 | ok 10600(컴파일 오류 7636 · panic 636 · 성공 2328) |
| 시나리오 0, 지속 실패, N 1..10600 | | ok 10600(빈 요약 컴파일 오류 9766 · panic 671 · 성공 163) |
| 시나리오 1, 한 번 실패, N 1..500 | ok 361 · leak 39 · crash 85 | ok 500(컴파일 오류 407 · panic 15 · UNKNOWN 11 · 성공 67) |
| 시나리오 1, 지속 실패, N 1..500 | | ok 500(빈 요약 컴파일 오류 458 · panic 16 · UNKNOWN 11 · 성공 15) |
