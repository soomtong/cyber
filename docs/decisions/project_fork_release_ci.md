# fork(soomtong/cyber) 릴리스와 CI에서 정한 것

2026-10-29, 0.4.1 릴리스를 내면서 확인한 사실과 결정.

## 저장소와 태그

- origin은 `soomtong/cyber`, upstream은 `fubark/cyber`. `install.sh`는 origin 릴리스를 받는다
  (`CYBER_REPO`로 바꿀 수 있음).
- 워크플로의 Setup 스크립트는 `git rev-list --count <major>.<minor-1>..HEAD`로 빌드 번호를 센다.
  그 태그(현재 `0.3`)가 origin에 있어야 한다. 로컬에만 있던 `0.2`, `0.3`을 푸시해 두었다.
- 버전 태그를 push하면 `latest-build.yml`이 릴리스를 만든다. `on.push.tags`가 없으면 태그 push에
  워크플로가 아예 돌지 않는다.
- 태그 체크아웃에서는 `actions/checkout`이 만든 로컬 태그 때문에 `git fetch --tags`가 거부된다.
  Setup 스크립트의 fetch에 `--force`를 둔 이유.
- 워크플로 파일은 태그가 가리키는 커밋에서 읽힌다. 워크플로를 고치면 태그를 다시 찍어야 한다.
- `concurrency.group: latest`에 `cancel-in-progress`가 켜져 있어 master push와 태그 push를 동시에 하면
  master 쪽 run이 취소되고 `latest` 릴리스가 만들어지지 않는다. 둘을 따로 push하거나
  `gh workflow run latest-build.yml --ref master`로 다시 돌린다.
- GitHub Pages는 fork에서 꺼져 있었다. `gh api -X POST repos/soomtong/cyber/pages`로 `gh-pages` 루트를
  소스로 켰다. 문서 주소는 `https://soomtong.github.io/cyber/`.

## 릴리스 노트 (2026-11-01)

- 릴리스 노트의 원본은 `docs/releases/<버전>.md`이고 한국어로 쓴다. GitHub 릴리스 본문은 이 파일에서 제목 줄
  (`# Cyber x.y.z`)과 빈 줄을 뺀 것이다:
  `tail -n +3 docs/releases/<v>.md > notes.md && gh release edit <v> -R soomtong/cyber --notes-file notes.md`.
- 릴리스 워크플로는 본문을 비워 둔 채 릴리스를 만든다. 태그를 다시 찍어 릴리스가 새로 생기면 본문도 다시 올려야 한다.
- 사용자가 GitHub 웹에서 본문을 고칠 수 있다(줄 끝이 CRLF가 된다). `gh release delete`는 본문도 지우므로, 다시 찍기 전에
  `gh release view <v> --json body --jq .body > saved.md`로 저장하고 새 릴리스에 그대로 올린다. 로컬 `docs/releases/<v>.md`는
  CR을 지운 사용자 버전에 맞춘다. 2026-11-01 사용자가 0.4.2 본문에서 "이전 0.4.2 빌드와의 차이" 절을 지웠다.
- 0.4.2 노트에는 이전 빌드(`build-562`)와 구분하는 스크립트 · 표를 넣었다. 성능 표는 이전 빌드를 worktree에서
  ReleaseSafe로 빌드해 같은 머신에서 잰 값이다.

## 릴리스 번들

- 2026-11-11(0.4.7)부터 CLI는 표준 모듈을 실행 파일에 내장한다. 번들은 `cyber`(Windows는 `cyber.exe`) 하나다. 아래 항목의
  `src/` 이야기는 0.4.6까지의 번들에 해당한다.
  - `src/cli.zig`의 `std_mods`가 이름을 소스(`@embedFile` 또는 bind 함수가 돌려주는 소스)와 bind 함수에 잇는다. 이름으로
    import하는 모듈은 `core` · `meta` · `math` · `cy` · `c` · `io` · `test` · `libc` · `os` · `cli`, 플랫폼 모듈
    (`os.macos.cy` 등)은 타깃 것만 내장하고 표준 모듈 안에서 상대 경로로만 import된다.
  - chunk uri는 라이브러리의 기본 로더와 같은 이름(`core`)이다. 스택 트레이스와 컴파일 오류의 위치가
    `/usr/local/lib/cyber/src/builtins/core.cy:196:5`에서 `core:196:5`로 바뀐다.
  - 디스크의 소스를 읽는 경로는 남기지 않았다(Node.js의 `--node-builtin-modules-path` 같은 개발용 옵션 없음). 이유: 실행 파일과
    맞지 않는 `src/`가 옆에 있으면 bind 표와 소스가 어긋나고, builtin 모듈 전용 규칙(intrinsic · `#[consteval]`)이 디스크 파일을
    고친 사람에게 열린다. `.cy`를 고치면 `zig build cli`가 다시 내장한다.
  - `install.sh`의 배치(`CYBER_HOME`에 풀고 `CYBER_BIN`에 심링크)는 그대로다. 이전 설치의 `CYBER_HOME/src`는 남아도 읽지 않는다.
  - `build_config.mod_root`는 테스트 바이너리만 받는다(기대 트레이스의 테스트 스크립트 경로).
- 릴리스 CLI는 `build_config.mod_root`가 없어서 실행 파일 디렉터리에서 `src/builtins/*.cy`,
  `src/std/*.cy`를 읽는다. 번들에 `src/`를 함께 넣는다(`cli` 스텝이 `zig-out/bin/src`에 설치).
- `install.sh`는 번들을 `CYBER_HOME`(기본 `/usr/local/lib/cyber`)에 풀고 `CYBER_BIN`(기본
  `/usr/local/bin`)에 `cyber`를 심링크한다. 실행 파일 경로는 심링크를 푼 실제 경로로 잡히므로 `src/`를
  찾는다. sudo는 대상 디렉터리(또는 가장 가까운 존재하는 상위)가 쓰기 불가일 때만 쓴다
  (`CYBER_SUDO=0|1`로 강제). 실제 `/usr/local` 설치는 2026-10-31에 사용자가 `install.sh`로 0.4.2를 받아
  `cyber version`까지 확인했다. macOS arm64(build-552, 이후 build-562)와 Rocky Linux 9(el9_6 x86_64, 일반 사용자
  `rocky`로 실행해 sudo 자동 사용 경로를 지남, build-562-56e3740) 두 곳이다. Rocky에서는 `print('hello')` 스크립트
  실행까지 확인했고 번들 내용은 `cyber`와 `src/` 둘뿐이다(`examples/`는 들어가지 않는다). 그 VM은 `getenforce`가
  `Disabled`라 SELinux Enforcing 환경은 아직 확인하지 않았다. `-Dselinux` 번들은 TCC 백엔드의
  JIT 메모리 확보 방식만 바꾸므로 기본 VM 백엔드로 스크립트를 돌리는 데는 일반 Linux 번들이면 되고, `install.sh`가
  SELinux 번들을 자동으로 고르지 않는 것은 그대로 둔다.
- 0.4.2는 2026-10-31에 다시 찍었다. 기존 릴리스와 태그를 지우고(`gh release delete 0.4.2 --cleanup-tag`)
  `56e3740`(translate-c 패키지 · `stdx.utf8Decode` · `-Dffi=false` panic · `SafeAllocator` 포함)에
  annotated 태그로 다시 push했다. 빌드 번호는 `build-562-56e3740`, 에셋 14개. 태그를 지우고 다시 push하면
  `latest-build.yml`이 그대로 새 릴리스를 만든다. 사용자가 혼자 쓰는 저장소라 태그 재사용을 허용했다.
- 2026-11-01에 0.4.2를 한 번 더 `e6401ce7`(배열 핫 경로 호출 줄이기 · 상수 접기 · `add_mul_i16` · JIT 거절 포함)로
  다시 찍었다. 순서: master push → 그 Latest Build run 완료 대기 → `gh release delete 0.4.2 --cleanup-tag -y` →
  `git tag -d 0.4.2` · `git tag -a 0.4.2 -m 0.4.2 e6401ce7` → `git push origin 0.4.2`. 빌드 번호
  `build-601-e6401ce`, 에셋 14개. 받은 macOS arm64 번들로 `version` · 스크립트 실행 · `-jit` 오류를 확인했다.
- 같은 날 REPL EOF 수정(`a2c586c2`)으로 0.4.2를 한 번 더 찍었다. `build-605-a2c586c`, 에셋 14개, 릴리스 본문은 사용자가
  고친 버전을 그대로 다시 올림. 받은 macOS arm64 번들로 `version`, `printf 'print(1)\n' | cyber`(종료 코드 0), `-jit` 오류 확인.
- 0.4.3은 2026-11-06에 `a26645f1`(버전 올림 + `docs/releases/0.4.3.md`)로 찍었다. master push → Latest Build 성공 확인 → annotated 태그 push →
  릴리스 run 성공(`build-668-a26645f`, 에셋 14개) → `gh release edit 0.4.3 --notes-file --latest`로 본문 업로드 → `install.sh 0.4.3`로
  macOS arm64 번들 설치 · `cyber version` 확인. 성능 표는 0.4.2 태그 커밋을 worktree에서 ReleaseSafe로 빌드해 같은 시각에 번갈아 쟀다.
- 0.4.4는 2026-11-09에 `b02d2f63`(버전 올림 `6aab6658` + `macos-26` 워크플로)으로 찍었다. 워크플로만 바뀐 커밋은 push 트리거가 없어
  `gh workflow run`으로 Latest Build(run 42627626892, 12 job 성공) → annotated 태그 push → 릴리스 run 42631294431 성공(`build-730-b02d2f6`,
  에셋 14개, `macos-26` arm64 job도 정상 배정) → `gh release edit 0.4.4 --notes-file --latest` → `install.sh 0.4.4`를 `CYBER_HOME` · `CYBER_BIN`
  override로 임시 경로에 설치해 `cyber version` 확인. `/usr/local`의 설치본은 sudo가 필요해 사용자가 직접 올린다. 성능 표는 성능 변경이 없어
  넣지 않았다.
- 0.4.7은 2026-11-12에 `a5ad6c23`(버전 올림 + `docs/releases/0.4.7.md`, 바로 앞 `919667f7`이 표준 모듈 내장)으로 찍었다. master push →
  Latest Build run 43043548521은 `macos-26` arm64 lib job이 러너 미배정으로 취소(나머지 11 job 성공) → 코드 문제가 아니므로 annotated
  태그 push → 릴리스 run 43047352546 12 job 성공(`build-802-a5ad6c2`, 에셋 14개) → `gh release edit 0.4.7 --notes-file --latest` →
  `install.sh 0.4.7`을 `CYBER_HOME` · `CYBER_BIN` override로 임시 경로에 설치. 번들 내용이 `cyber` 하나인 것(macOS arm64 · Linux x64 ·
  Windows zip)과 `src/` 없이 `use os` · `use math` · `use test` 스크립트와 REPL이 도는 것을 확인했다. `/usr/local` 설치본은 사용자가 올린다.
- 0.4.8은 2026-11-12에 `2dfc061d`(버전 올림 + `docs/releases/0.4.8.md`)로 찍었다. 내용은 코루틴 단계 1(`CL_AWAIT`) · `Future.wait_any` ·
  호스트 Future 태그 · 평가 순서(F-98) · `a[..n]`과 버그 수정이다. master push → Latest Build run 43168448515 13 job 성공 → annotated
  태그 push → 릴리스 run 43170310099 성공(`build-815-2dfc061`, 에셋 14개) → `gh release edit 0.4.8 --notes-file --latest` →
  macOS arm64 자산을 임시 경로에 풀어 `Cyber 0.4.8 build-815-2dfc061`과 0.4.8 동작(평가 순서, `a[..2]`, `var f float = 0x10`)을 확인했다.
  개발 빌드 릴리스 `latest`는 워크플로가 `prerelease: true`로 만들므로(`e4d48258`) 따로 표시하지 않는다. `/usr/local` 설치본은 사용자가 올린다.
- 0.4.9는 2026-11-12에 `03d24f4e`로 찍었다. 버전 올림은 `82877718`이고, 그 뒤 태그 전의 전체 리뷰에서 찾은 결함(F-107 ~ F-111)의
  수정 둘(`06b0cd7b` · `03d24f4e`)이 들어갔다. 내용은 fiber 안 await의 양보 · `Fiber.cancel` · `Scope` · `scope` 블록 · 범위 안 빌림이다.
  master push → Latest Build run 43226879565 성공 → annotated 태그 push → 릴리스 run 43231226185 성공(`build-833-03d24f4`, 에셋 14개)
  → `gh release edit 0.4.9 --notes-file --latest` → macOS arm64 자산을 임시 경로에 풀어 `Cyber 0.4.9 build-833-03d24f4`와
  `concurrency/scope_block.cy` 통과를 확인했다. tars-agent 안내 초안은 그 저장소의 `docs/requests/cyber-0.4.9-report.md`.
- 번들의 `src/`는 타깃별로 다르다. `build.zig`의 `cli` 스텝이 공통 10개에 macOS(`os.macos.cy`,
  `libc.macos.cy`) · Linux(`os.linux.cy`, `libc.linux.cy`) · Windows(`os.windows.cy`, `windows/*.cy`)만
  더한다. 플랫폼 모듈은 전부 `#[cond=meta.system() == ...]` 뒤의 `use`라서 다른 타깃 파일이 없어도 된다.
  0.4.1 릴리스 번들은 트리밍 전 17개 파일 그대로다(태그를 다시 찍지 않음). 0.4.2(2026-10-30)부터
  트리밍된 번들(macOS · Linux 12개)이 나간다. `CYBER_HOME`/`CYBER_BIN`을 임시 디렉터리로 두고 `install.sh`로
  받은 macOS arm64 바이너리가 `examples/hello.cy`를 실행하는 것까지 확인했다.
- `-Doptimize=ReleaseFast`/`ReleaseSmall` CLI가 `examples/hello.cy`에서도 세그폴트하던 문제는 고쳤다(2026-10-30).
  원인은 두 가지였다. `vm.h`의 `ZHeap`/`ZVM` padding이 safety를 켠 배치만 맞췄고, `resolveFuncSig`가
  variant 경로에서 `out_generic`을 쓰지 않아 호출자의 `assert(!generic.generic)`가 undefined를 읽었다.
  CI 릴리스 모드는 여전히 `ReleaseSafe`다.

## 타깃별 메모

- Windows msvc: Zig 0.17 translate-c가 mimalloc.h의 `__declspec`을 처리하지 못한다. `CliConfig`는
  msvc에서 libc `malloc`을 기본으로 쓴다.
- macOS x86_64: libc `stat`/`fstat`는 legacy inode 구조체를 채운다. `libc.cy`는 그 타깃에서
  `stat$INODE64`/`fstat$INODE64`에 바인딩한다(`#[cond=..., extern='...']` 한 줄 형태만 파서가 받는다).
- wasm32: `Value`는 C ABI에서 `uint64_t`이고 Zig 쪽은 extern union이라 wasm32에서는 간접 전달된다.
  C가 호출하는 Zig 진입점은 `u64`로 받는다(`zAwait`, `zAllocFuncUnion`). 로컬 실행은
  `wasmtime --dir=.::/`로 cwd를 루트에 매핑해야 behavior 테스트의 기대 출력(`/src/...`)과 맞는다.
- Linux x86_64: AVX2 경로는 교차 빌드 기본 CPU(baseline)에서 컴파일되지 않는다.
  `-Dcpu=skylake`로 교차 빌드해야 잡힌다.

## 도구

- `Taskfile.yml`에 빌드 · 테스트 · 문서 사이트 · 도구 태스크가 있다. `task`로 목록을 본다.

## macOS 러너 레이블 `macos-26` · `macos-26-intel` (2026-11-09)

- GitHub 호스티드 `macos-15`(arm64) 러너는 용량 부족으로 job이 15분 안에 배정되지 않아 "The job was not acquired by Runner of type
  hosted"로 취소되는 일이 잦았다(`aa642ed5` run 42611240702의 lib, `6aab6658` run 42623377479의 cli · lib 둘 다. `--failed` 재실행도
  시작조차 못 하고 취소). Release job은 `needs: build`라 arm64 job 하나가 취소되면 릴리스가 skipped다.
- 중간에 arm64 두 job을 매트릭스에서 빼고 로컬(Apple Silicon) 빌드로 대신하는 커밋(`8ad0d43d`)을 넣었다가, 사용자 결정으로 되돌려
  x86_64 · arm64 둘 다 CI에서 만든다. 레이블은 GitHub 현재 체계(2026-11)에 맞춰 `macos-26`(arm64, `macos-latest`와 같음) ·
  `macos-26-intel`(x64)로 올렸다. macOS 14 이미지는 2026-11-02 퇴역했고 GitHub는 OS 계열당 GA 이미지를 둘만 유지하므로 `macos-15`는
  macOS 27 GA 뒤 퇴역 수순이다. 큐 지연은 무료 arm64 풀 전체의 문제라 레이블로 해결되지는 않는다(GitHub 상태 페이지 2025-03 ·
  2025-10 기록).
- arm64 job이 또 배정되지 않으면 아래 명령으로 이 머신에서 두 자산을 만들어 `gh release upload`로 올린다(0.4.4 때 `build-729-8ad0d43`
  번들을 이 방법으로 만들어 실행 · 버전 문자열을 확인했다). CI와 같은 버전 문자열을 내려면 `-Dbuild` · `-Dcommit` 옵션이 필요하다
  (2026-11-10부터. 그 전에는 `BUILD` · `COMMIT` 환경 변수였고 지금도 폴백으로 읽는다). `BUILD`는 CI의
  `git rev-list --count 0.3..<태그 커밋>`(짧은 버전 0.4.x의 직전 minor 태그 `0.3`부터 센다), `COMMIT`은 태그 커밋 앞 7자리.

```bash
sha=$(git rev-parse <태그>); n=$(git rev-list --count 0.3..$sha)
zig build cli -Doptimize=ReleaseSafe -Dtarget=aarch64-macos-none -Dcpu=baseline -Ddev=false -Dbuild=$n -Dcommit=${sha:0:7}
zig-out/bin/cyber version            # Cyber 0.4.4 build-N-xxxxxxx
tar -C zig-out/bin -czvf cyber-macos-arm64.tar.gz cyber
zig build lib -Doptimize=ReleaseSafe -Dtarget=aarch64-macos-none -Dcpu=baseline -Ddev=false -Dbuild=$n -Dcommit=${sha:0:7}
cp zig-out/lib/libcyber.a libcyber-macos-arm64.a
gh release upload <태그> cyber-macos-arm64.tar.gz libcyber-macos-arm64.a -R soomtong/cyber --clobber
zig build cli -Doptimize=ReleaseSafe   # 네이티브 산출물 되돌리기(-Ddev 기본 true)
```

- 빌드 번호를 옵션으로 바꾼 이유(2026-11-10): Zig 0.17.1은 configure 단계 결과를 `.zig-cache`에 캐시하고(`zig build --help`의
  `--cache-poison`, 기본 `pure`), `build.zig`가 `b.graph.environ_map.get("BUILD")`로 읽는 환경 변수는 캐시 키에 들어가지 않는다. 같은
  인자로 한 번 빌드하면 다음 빌드는 환경 변수를 바꿔도 configure가 다시 돌지 않아 옛 `build-N-xxxxxxx`가 그대로 박힌다(2026-11-09 확인:
  `BUILD=999`로 빌드해도 `build-729-8ad0d43`). 0.4.4 때는 `--cache-poison=poisoned`로 피했다. 환경 변수를 읽은 configure에서
  `b.graph.poisonCache()`를 부르는 것만으로는 반만 고쳐진다: 환경 변수 없이 configure한 결과는 `pure`로 캐시되고, 뒤에 환경 변수를 주고
  같은 인자로 빌드하면 그 캐시를 맞아 `build.zig`가 아예 실행되지 않는다(2026-11-10 새 캐시 디렉터리로 확인: `BUILD=901` → `902`는
  반영, 환경 변수 없이 한 번 빌드한 뒤 `BUILD=903`은 `build-0-local`). 그래서 `-Dbuild` · `-Dcommit` 옵션을 추가했다. 옵션은 configure
  캐시 키의 일부라 값이 바뀌면 configure가 다시 돈다(`-Dbuild=` 빈 값은 없는 것으로). 환경 변수는 폴백으로 남기되 그 경로는
  `poisonCache()`(0.17.0에는 없으므로 `@hasDecl` 가드)로 캐시하지 않는다. CI `latest-build.yml`의 릴리스 Build 단계는
  `-Dbuild=${{ env.BUILD }} -Dcommit=${{ env.COMMIT }}`를 넘긴다. 이 수정이 들어간 뒤 CI · `Taskfile.yml` · `build.zig.zon`의 Zig를
  0.17.1로 올렸다(0.17.0 CI 산출물 `latest` `build-722-44a8467` · 0.4.3 `build-668-a26645f`는 환경 변수만으로도 커밋과 맞았지만,
  `.zig-cache`를 `actions/cache`로 복원하므로 0.17.1에서는 같은 문제가 생길 수 있었다).
- 워크플로의 `push.paths`가 `.github/**` · `**.md`를 제외하므로 워크플로만 고친 커밋은 Latest Build를 트리거하지 않는다. 확인하려면
  `gh workflow run latest-build.yml -R soomtong/cyber --ref master`로 직접 실행한다.

## 번들에 언어 서버 (2026-11-13)

- Linux · macOS 번들은 `cyber`와 `cyber-lsp` 둘을 담는다(0.4.9 다음 릴리스부터). `latest-build.yml`의 `cli` 작업이
  `zig build lsp`를 같은 옵션(`-Dbuild` · `-Dcommit` 포함)으로 한 번 더 돌리고 `tar`에 둘 다 넣는다. Linux는 둘 다 strip한다.
  `x86_64-selinux-gnu` 번들도 같다.
- 한 번들에 둔 이유: 서버는 스크립트를 실행하는 `cyber`와 같은 버전이어야 한다(진단이 실행 결과와 같다는 것이 이 서버의 전제다).
  따로 받으면 어긋난다.
- Windows 번들과 wasi에는 넣지 않는다. Windows용은 교차 컴파일은 되지만(`x86_64-windows-gnu`, 4.6MB) 돌려 본 적이 없다.
  같은 이유로 `zig build test`는 Windows와 wasm 타깃에서 `lsp-test`를 빼고 돈다(`build.zig`). Windows에서 확인하면 둘 다 푼다.
- 2026-11-13 보충(최종 리뷰): `install.sh`는 번들을 `mktemp` 파일로 먼저 받는다. 이전에는 `curl | tar` 앞에서 서버를 지워,
  다운로드가 실패하면 `cyber`는 남고 `cyber-lsp`만 사라졌다. 낡은 심링크는 경로 문자열 비교가 아니라 가리키는 곳이 없는지로
  가린다(`CYBER_HOME`의 표기가 달라도 정리된다).
- `install.sh`: 번들에 `cyber-lsp`가 있으면 `CYBER_BIN/cyber-lsp`로 심링크한다. 풀기 전에 `CYBER_HOME/cyber-lsp`를 지우고,
  번들에 서버가 없으면(0.4.9까지의 번들) 이전 설치가 남긴 심링크도 지운다. 실행 파일과 버전이 다른 서버가 남지 않게 하기 위해서다.
  로컬 번들 둘(서버 있음 · 없음)을 `curl` 대역으로 번갈아 설치해 확인했다. 실제 릴리스에서의 확인은 다음 태그에서 한다.
- 크기(ReleaseSafe, strip 전): Linux x64 `cyber-lsp` 약 5MB, macOS arm64 3.4MB, macOS x64 3.9MB.
