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

## 릴리스 번들

- 릴리스 CLI는 `build_config.mod_root`가 없어서 실행 파일 디렉터리에서 `src/builtins/*.cy`,
  `src/std/*.cy`를 읽는다. 번들에 `src/`를 함께 넣는다(`cli` 스텝이 `zig-out/bin/src`에 설치).
- `install.sh`는 번들을 `CYBER_HOME`(기본 `/usr/local/lib/cyber`)에 풀고 `CYBER_BIN`(기본
  `/usr/local/bin`)에 `cyber`를 심링크한다. 실행 파일 경로는 심링크를 푼 실제 경로로 잡히므로 `src/`를
  찾는다. sudo는 대상 디렉터리(또는 가장 가까운 존재하는 상위)가 쓰기 불가일 때만 쓴다
  (`CYBER_SUDO=0|1`로 강제). sudo 경로는 가짜 `sudo`로 명령 구성만 확인했고, 실제 `/usr/local` 설치는
  사용자가 `bash install.sh`로 돌려야 한다.
- 번들의 `src/`는 타깃별로 다르다. `build.zig`의 `cli` 스텝이 공통 10개에 macOS(`os.macos.cy`,
  `libc.macos.cy`) · Linux(`os.linux.cy`, `libc.linux.cy`) · Windows(`os.windows.cy`, `windows/*.cy`)만
  더한다. 플랫폼 모듈은 전부 `#[cond=meta.system() == ...]` 뒤의 `use`라서 다른 타깃 파일이 없어도 된다.
  0.4.1 릴리스 번들은 트리밍 전 17개 파일 그대로다(태그를 다시 찍지 않음).
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
