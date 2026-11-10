#!/bin/sh
# Allocation-failure fuzz for one eval. See README.md.
#   fuzz.sh build                        build the probe binary
#   fuzz.sh count <scn>                  print how many allocations the eval makes
#   fuzz.sh run <name> <scn> <last> [1]  fail allocation 1..<last>, one process each. 1 = sticky
#   fuzz.sh where <scn> <n> [1]          print the stack of failing allocation <n>
#   fuzz.sh agg <name>                   aggregate a result again
# env: FUZZ_OUT (default zig-out/alloc_fuzz), JOBS (default 8)
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
out_root=${FUZZ_OUT:-$root/zig-out/alloc_fuzz}
bin=$out_root/lib_test
lib=$root/src/lib.zig

need_bin() {
  [ -x "$bin" ] || { echo "no probe binary. run: $0 build" >&2; exit 1; }
}

build() {
  if rg -q '^const ProbeAlloc = struct' "$lib"; then
    echo "src/lib.zig already has the probe section. Restore it first" >&2
    echo "(a backup may be at $out_root/lib.zig.orig)." >&2
    exit 1
  fi
  [ -f "$here/probe.zig" ] || { echo "no $here/probe.zig" >&2; exit 1; }
  mkdir -p "$out_root"
  backup=$out_root/lib.zig.orig
  cp -p "$lib" "$backup" || exit 1
  trap 'cp -p "$backup" "$lib" && rm -f "$backup"' EXIT
  trap 'exit 1' INT TERM
  wc -l < "$lib" | tr -d ' ' > "$out_root/probe_line"
  cat "$here/probe.zig" >> "$lib" || exit 1
  rm -f "$root/zig-out/bin/lib_test" "$bin"
  # The filter leaves other test binaries without a test, and the step can fail on those
  # after it has installed lib_test. Only lib_test and errors in src count.
  (cd "$root" && zig build build-test -Dtest-filter=PROBE) > "$out_root/build.log" 2>&1
  echo "zig build rc=$? (log: $out_root/build.log)"
  if rg -n 'src/[^ ]*: error' "$out_root/build.log"; then
    echo "build failed" >&2
    exit 1
  fi
  [ -x "$root/zig-out/bin/lib_test" ] || { echo "build made no lib_test" >&2; exit 1; }
  cp "$root/zig-out/bin/lib_test" "$bin"
  PROBE_N=999999999 "$bin" 2>&1 | rg -aq 'PROBE n=' || { echo "the binary has no PROBE test" >&2; exit 1; }
  echo "built $bin"
}

cmd=${1:-}
case "$cmd" in
  build)
    build
    ;;
  count)
    need_bin
    PROBE_N=999999999 PROBE_SCN=${2:-0} "$bin" 2>&1 | rg -ao 'PROBE n=.*'
    ;;
  run)
    need_bin
    [ $# -ge 4 ] || { echo "usage: $0 run <name> <scn> <last> [1]" >&2; exit 1; }
    dir=$out_root/$2
    [ -e "$dir" ] && { echo "$dir exists" >&2; exit 1; }
    mkdir -p "$dir"
    seq 1 "$4" | PROBE_SCN=$3 PROBE_STICKY=${5:-0} OUT=$dir BIN=$bin \
      xargs -P "${JOBS:-8}" -n 1 "$here/run_one.sh"
    python3 "$here/agg.py" "$dir"
    ;;
  where)
    need_bin
    [ $# -ge 3 ] || { echo "usage: $0 where <scn> <n> [1]" >&2; exit 1; }
    PROBE_WHERE=1 PROBE_SCN=$2 PROBE_N=$3 PROBE_STICKY=${4:-0} "$bin"
    ;;
  agg)
    python3 "$here/agg.py" "$out_root/$2"
    ;;
  *)
    sed -n '2,8p' "$0"
    exit 1
    ;;
esac
