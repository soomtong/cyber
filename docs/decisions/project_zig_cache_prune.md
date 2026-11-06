# `.zig-cache/o` 부분 정리는 안전하지 않다

2026-11-06, `Taskfile.yml`에 넣으려던 `clean:cache` 태스크를 버리면서 적어 둔 것.

## 시도

디스크를 되찾되 전체 재빌드는 피하려고, `.zig-cache/o/<digest>/` 가운데 1 MB 넘는 산출물을 파일 이름(종류)별로 묶어
mtime 기준 최신 KEEP개(기본 2)만 남기고 지우는 태스크를 만들었다. 네 가지 최적화 모드와 wasm32를 번갈아 빌드하는
이 저장소에서는 같은 `tcc.o` · `libcyber.a`가 모드마다 따로 있어 KEEP=2면 일부 모드의 산출물이 지워진다.

## 깨지는 방식

정리 뒤 `zig build test -Doptimize=ReleaseFast`가 다음과 같이 실패했다.

```
error: failed to open object .zig-cache/o/dc3e2a26124f7eb332de199c9799d7ea/tcc.o: FileNotFound
error: failed updating file from .zig-cache/o/efa167c97596efc241ffff53e3bdb5f7/libcyber.a to zig-out/lib/libcyber.a: FileNotFound
```

Zig의 캐시는 `h/<초기 해시>` 매니페스트에 입력 파일 목록을 두고, 빌드 때 입력을 다시 해시해 최종 digest를 얻은 뒤
"산출물은 `o/<최종 digest>/`에 있다"고 결론낸다. 그 디렉터리가 실제로 있는지는 확인하지 않는다. 그래서 `o/`만 지우면
해당 단계는 cache hit로 남고, 그 산출물을 입력으로 쓰는 다음 단계(링크 · install)가 없는 파일을 열다 실패한다.

## 매니페스트까지 지워도 안 되는 이유

`h/*`에서 `o/[0-9a-f]{32}/` 문자열을 찾아 지워진 디렉터리를 가리키는 매니페스트를 삭제하는 2단계를 붙여 봤다
(`LC_ALL=C grep -aoE 'o/[0-9a-f]{32}/' h/*`). 이것은 산출물을 입력으로 쓰는 하위 단계의 매니페스트만 잡는다.
산출물을 만드는 단계의 매니페스트는 자기 출력 경로를 담지 않는다(최종 digest는 초기 해시 + 입력 내용 해시로 계산되며
파일 이름과도 다르다). 그 단계가 hit로 남으므로 하위 단계가 재실행되어도 같은 경로를 다시 열다 실패하고, 새 매니페스트가
또 지워진 경로를 가리키게 된다. 실제로 매니페스트 정리 뒤 남은 stale 참조가 0이었는데 재빌드하자 ReleaseFast · Debug ·
CLI 빌드가 모두 같은 오류로 실패했다. 매니페스트 이름 → 출력 digest 대응은 Zig 내부 해시 순서에 달려 있어 밖에서
재현할 수 없고, 매니페스트 형식도 0.17에서는 확장자 없는 이진 파일이다.

## 결정

- `clean:cache`는 넣지 않는다. 디스크가 필요하면 `task clean`(`zig-out` · `.zig-cache` 전체 삭제) 뒤 재빌드한다.
- `.zig-cache/o` 아래를 선택적으로 지우지 않는다. 지웠다면 `h/`도 같이 비워야 하고, 그러면 결국 전체 재빌드다.
- 매니페스트 삭제 자체는 안전하다(재빌드만 유발). 위험한 것은 산출물만 지우는 쪽이다.
- `failed to open object .zig-cache/o/...: FileNotFound`가 보이면 원인은 캐시 불일치이고 코드 변경과 무관하다. `rm -rf .zig-cache`로 푼다.

## 복구 기록

2026-11-06 두 번 `rm -rf .zig-cache` 뒤 재빌드로 복구했다. 첫 번째는 JIT 잔재 제거 검증 중(12단계 모두 통과), 두 번째는 위 2단계
실험 뒤.
