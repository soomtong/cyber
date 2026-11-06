# Zig 0.17 업그레이드에서 정한 것

설계 · 실측 · 릴리즈 노트 체크리스트: `docs/specs/2026-10-25-zig-0.17-upgrade-design.md`.

## 검증 환경

- 호스트(macOS 27)에서 Zig 0.15.2는 build runner가 링크되지 않는다. 0.15.2 기준선은 Linux 컨테이너
  (`debian:stable-slim`, aarch64)에서만 잰다.
- Linux 컨테이너 기준선은 원래 빨갛다. `modules/os.cy:25`(`os.open_dir` InvalidArgument)와 `FFI.`
  (FileNotFound). 비교는 "같은 실패가 같은 자리에서 나는가"로 한다.
- `-Dffi=false`의 `modules/os.cy` 세그폴트는 0.15.2에서도 나던 문제였고 고쳤다(2026-10-31). std의 libc 바인딩은
  `#[extern]`이라 TCC 없이는 실행할 수 없다. FFI가 없으면 extern 호출은 panic으로 끝나고, FFI가 필요한
  테스트는 `test_config.ffi`(build.zig `TestConfig.ffi`)로 거른다.

## 코드 규칙

- C 헤더 번역은 `build.zig`의 `translateC`(translate-c 패키지의 `Translator`)로 한다. `b.addTranslateC`는
  0.17에서 deprecated다. 패키지는 codeberg 주소와 커밋으로 고정한다(ghostty 미러와 해시가 같다).
  `default_init = true`가 없으면 extern struct 필드의 0 기본값이 사라져 `CLBindFunc` 초기화가 깨진다.
  받은 패키지는 `zig-pkg/`(gitignore, CI 캐시 경로)에 풀린다.
- `Io`는 `stdx.io()`에서 얻는다. 환경 변수는 `stdx.getEnvVarOwned`(libc). 인자는 `std/os.zig`의
  `process_args`를 CLI `main`과 테스트 러너의 `test_init`이 채운다.
- extern struct에 std 컨테이너를 흉내 내 넣지 않는다. std 타입은 배치가 정의되지 않고(0.17
  `ArrayList`의 `pointer_stability`), 바뀌면 조용히 깨진다. 필요하면 크기 · 정렬만 맞춘 저장소를 둔다.
- `vm.h`의 `ZVM`/`ZHeap` padding은 Zig `VM`/`Heap`의 `c` offset을 모드별로 잰 값이다. safety를 켜면
  `ArrayList`와 `HashMapUnmanaged`마다 `usize` lock이 붙고 Zig가 필드 순서를 바꾸므로 공식으로 세지 않는다.
  64-bit은 safe 120/536, unsafe 96/432, wasm32 `ZVM`은 220/172. 어긋나면 `vm.zig` · `heap.zig` ·
  `thread.zig`의 comptime 검사가 두 offset을 찍으며 빌드를 멈춘다(모든 모드 · 타깃).
- 읽힐 수 있는 필드와 out 파라미터는 `undefined`로 두지 않는다. 최적화 빌드에서 undefined 값을 읽는 비교나
  `std.debug.assert`는 UB라 결과가 임의로 정해지거나 주변 코드가 사라진다. 실제로 난 두 곳:
  `resolveFuncSig`의 `out_generic`(템플릿 함수 `sig`가 null), `FuncSym.firstFuncSig`(wasm32에서 첫 resolve가
  "same function signature" 중복으로 판정됨, 이제 `?*FuncSig` + `null`).
- 바이트코드 피연산자를 `*u48` 포인터로 읽고 쓰지 않는다. `@sizeOf(u48)`는 8이라 6바이트 피연산자 뒤 2바이트까지
  건드린다. `setOpArgU48`이 이렇게 써서, `call` 명령이 `ops` 버퍼 용량 끝에 걸리면 SafeAllocator footer를 덮었다
  (2026-11-01, `-Dmalloc=zig` + trace 끔에서 "remap of invalid memory ... canary" panic, mimalloc에서는 조용히 손상).
  `std.mem.writeInt`/`readInt(u48, *[6]u8, ...)`를 쓴다. 회귀 테스트는 lib "setOpArgU48 writes only its 6-byte operand.".
  `bytecode.zig` 안의 `test` 블록은 어느 테스트 단계에서도 참조되지 않아 실행되지 않는다.
  같은 날 wasm32 CI 실패(run 41253320696)를 음수 `Ptr` 인덱스 탓으로 돌렸는데, 실제 원인은 이 버그였다
  (`project_slice_append_aliasing.md`).
- CI는 x86_64-linux · aarch64-macos cli job에서 `zig build test -Doptimize=ReleaseFast`를, wasi job에서
  ReleaseFast `build-test`를 돌린다. 크기 단언 테스트는 bare union의 safety tag만큼 모드별 값을 둔다
  (64-bit 8, wasm32 `Local` · `Func` 4).
- extern 타입의 재해석은 `@bitCast` 대신 `.val` 또는 `stdx.reinterpret`(0.17은 extern `@bitCast` 금지).
- Zig 쪽 범용 allocator는 `std.heap.SafeAllocator.init(std.heap.page_allocator, ...)`다(`cli.zig` `gpa`). `DebugAllocator`는 deprecated고, 바꿔도 피크 메모리는 Debug +7% · ReleaseFast
  `-Dmalloc=zig` -12%, 시간은 같았다(2026-10-31, `src/test/bench/alloc/alloc.cy`). backing은 메모리를
  재사용하지 않는 page_allocator여야 write-after-free 검출이 된다. 기본 릴리스 CLI는 mimalloc을 쓴다.
- 참조되지 않는 함수는 Zig가 분석하지 않아, 0.17에 없는 API를 불러도 빌드가 통과한다. 2026-11-03에 그런 코드를
  지우거나 고쳤다. 지운 것: `src/fifo.zig`(`std.fifo` 복사본, `std.io` 기반) · `src/stdx/heap.zig`(0.9 시절
  `Allocator` vtable의 wasm allocator, `std.mem.set`) · `fmt.zig` `formatFloatValue`(`std.fmt.formatFloat` ·
  `fixedBufferStream`) · `compiler.zig` `replaceIntoShorterList`(`std.mem.copy`) · `chunk.zig` `nextTempDestValue`
  (`std.math.min`) · `simd.zig` `iotaExt` · `negIotaIntExt`(const에 쓰기). 고친 것: `std.meta.intToEnum` →
  `std.enums.fromInt`, `std.math.epsilon` → `floatEps`, `@typeInfo` 태그 `.Optional` · `.Pointer` · `.Union` ·
  `.Float` → 소문자, `callconv(.C)` → `.c`, `std.mem.zeroes` → `@splat(0)`, `comptime var` + `inline while` →
  `inline for (0..8)`. `string.zig`의 AVX2 분기(`hasAvx2`)는 baseline x86_64 CI에서도 컴파일되지 않으므로
  `-Dtarget=x86_64-linux-gnu -Dcpu=x86_64_v3`로 따로 확인한다.
- 리뷰 뒤 더 지운 것: `string.zig` `HeapStringBuilder`(`std.fmt.format`, 전체 미참조) · `src/web.zig`와 `build.zig`의
  주석 처리된 web-lib 블록(`capi.zig`에 없는 심볼) · `heap.zig` `TraceAllocator`(`cli.zig`에 같은 복사본) · `lib.zig`
  `printLogger` · `stdx/testing.zig` `eqApproxEps`(인자 순서가 뒤바뀜).
- 같은 리뷰에서 `string.zig` AVX2 `indexOfAsciiSetSimd*`의 원래 버그를 고쳤다. LUT를 `=`로 채워 하위 nibble이 같은 문자
  (`,` 0x2C · `<` 0x3C)가 서로 덮어썼고(`"a,b".index_any({',', '<'})`가 none), Fixed 쪽은 절대 인덱스를 `hitMask` 비트
  위치로 썼으며, 분기에 `arch == .x86_64` 가드가 없었다. `string.zig` 테스트 `indexOfAsciiSet matches the scalar
  search.`와 `strings_ascii.cy`가 잡는다. x86_64_v3 실행은 OrbStack `docker run --platform linux/amd64`에서
  `build-test` 산출물을 저장소와 같은 경로로 마운트해 돌렸다(lib_test 54 · behavior_test 8 통과, 수정을 되돌리면 둘 다 실패).
- musl 정적 타깃(`-Dtarget=x86_64-linux-musl`)은 `src/std/os.zig` `dlopen`이 `link_libc`만 보고 `DlDynLib`의 `handle`을
  채워 컴파일이 안 됐다(2026-11-04 수정). std 0.17은 musl 정적 링크에서 `std.DynLib.inner`를 `ElfDynLib`으로 고르고,
  `ElfDynLib`은 ET_DYN 파일만 열므로 실행 파일 자신(`#c.bind_lib(none)` · `use c`의 self dlopen)은 열 수 없다. 그래서
  `dlopen`은 `@hasField(@FieldType(std.DynLib, "inner"), "handle")`로 libc `dlopen` 경로를 고르고, `build.zig` 기본
  `ffi`는 musl에서 끈다(`-Dffi=true`로 덮어쓸 수 있음). ffi가 꺼지면 extern 함수는 `bindExternFuncsWithoutFFI`
  경로로 정적 링크된 심볼에 묶여 `math`는 동작하고, behavior_test는 `modules/os.cy` · `libc.cy`와 FFI 테스트를 건너뛴다.
  OrbStack 컨테이너 실행: musl lib_test 56 · behavior_test 280/280 통과, gnu(FFI 있음) lib_test 56 · behavior_test 282/282 통과.
- 미참조 decl을 빌드가 잡게 했다(2026-11-04). lib-test `All declarations compile.`이 `cy`에서 닿는 모든 `pub` 선언을
  재귀로 참조한다(std 0.17에는 `refAllDeclsRecursive`가 없어 직접 작성, 선언 이름과 타입 이름이 같은 컨테이너만 내려가므로
  `pub const W = std.Io.File.Writer` 같은 별칭으로 std 내부에 들어가지 않음, translate-c 모듈 `vmc` · `c`와 죽은 JIT
  `jitgen`은 건너뜀). 처음 돌리자 78개 오류가 나왔고 모두 삭제된 API를 쓰는 죽은 코드였다. 지운 것: 약 70개 함수 · 메서드
  (sema의 옛 `declareModuleAlias` · `reserveUserFunc` · `getResolvedSym` 복사본, heap의 `MapValue.set` · `allocVector` ·
  `newAstrSlice` · `allocTrait`, vm의 `dumpValue` · `dumpInfo`, chunk의 `genGetVar` · `dumpLocals` 등), 파일 `src/fiber.zig`
  (어디서도 import 안 됨) · `src/dce.zig`(`enable_dce = false` 뒤의 죽은 DCE) · `src/llvm.zig` · `src/llvm_gen.zig`(닫은 LLVM
  백엔드, `chunk.zig`의 `hasJIT` LLVM 필드와 함께), IR visitor(`ir.visitStmts` · `visitExpr`, DCE만 썼음), `parser.Result`,
  `ByteCodeBuffer.clear`(없는 `unwind_*` 필드), `bounded_array`의 옛 `Writer`, `String_decode` · `String_decode2`(바인딩
  안 된 `str.decode` 구현, 되살리려면 새로 짜야 함). 오류 행이 함수 안이 아니라 그 아래 별칭 행(`pub const x = module.x;`)인
  경우가 있어 감싸는 함수를 기계적으로 지우면 안 된다(`Chunk.findResolvedType`를 그렇게 잘못 지웠다가 복원, `meta.type.field`가 씀).
  복사-패치 JIT(`src/jit/`, `Compiler.jitBuf`, `FuncInfo.jit`, `-Djit`)는 남겨 테스트에서 제외했다가 2026-11-06 지웠다
  (`project_direction.md`).
