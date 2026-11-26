#!/bin/sh
# 16-step verification to run before a commit that changes src/. Sequential, about 10 minutes.
# usage: verify.sh [log dir]   (default: zig-out/verify)
# Prints "<step> rc=N" per step and exits 1 if a step failed. The log of a step is <log dir>/<step>.log.
# - Needs wasmtime for steps 9 to 12.
# - Do not run it together with benchmarks or another test run, and do not edit src/ while it runs:
#   a later step would compile the edited source.
# - The last step leaves zig-out/bin/cyber as a ReleaseSafe build.
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root" || exit 1
L=${1:-zig-out/verify}
mkdir -p "$L" || exit 1
command -v wasmtime >/dev/null || echo "warning: wasmtime not found, steps 9 to 12 will fail"
fail=0
run() {
  name=$1; shift
  "$@" > "$L/$name.log" 2>&1
  rc=$?
  echo "$name rc=$rc"
  [ $rc -eq 0 ] || fail=1
}
run 01-test-debug        zig build test
run 02-test-fast         zig build test -Doptimize=ReleaseFast
run 03-test-safe         zig build test -Doptimize=ReleaseSafe
run 04-test-notrace      zig build test -Dtrace=false
run 05-lib-debug         zig build lib-test -Dno-cache=true --summary all
run 06-lib-safe          zig build lib-test -Dno-cache=true -Doptimize=ReleaseSafe --summary all
run 07-lib-standalone    zig build lib-standalone-test -Doptimize=ReleaseFast
# Remove the old wasm binaries so that a failed build cannot be followed by a run of stale ones.
wasm_tests="behavior_test cli_test lib_test trace_test"
for w in $wasm_tests; do rm -f "$root/zig-out/bin/$w.wasm"; done
run 08-wasm-build        zig build build-test -Dtarget=wasm32-wasi -Doptimize=ReleaseSafe
n=9
for w in $wasm_tests; do
  run "$(printf '%02d' $n)-wasm-$w" wasmtime run --dir=.::/ "zig-out/bin/$w.wasm"
  n=$((n+1))
done
run 13-cli-safe          zig build cli -Doptimize=ReleaseSafe
# docs/api.json is committed and embedded by `cyber doc --api`. It must match the API of the sources.
api_fresh() {
  zig-out/bin/cyber docs/gen-api-json.cy -out="$L/api.json" || return 1
  cmp -s "$L/api.json" docs/api.json || { echo "docs/api.json is out of date: run zig-out/bin/cyber docs/gen-api-json.cy"; diff docs/api.json "$L/api.json" | head -20; return 1; }
}
run 14-api-json          api_fresh
# The REPL reads lines from a pipe, and its session imports the modules of the CLI (F-200). `os` after `math`
# binds extern functions in a second eval of the session (F-203). The first line of the output has the version.
repl_stdin() {
  out=$(printf 'use math\nmath.sqrt(4.0)\nuse os\nos.cwd()!.len() > 0\nuse cli\nuse libc\n.exit\n' | zig-out/bin/cyber 2>&1) || return 1
  exp=$(printf 'Commands: .exit, .help\n`float` 2.0\n`bool` true')
  got=$(printf '%s\n' "$out" | tail -n +2)
  [ "$got" = "$exp" ] || { echo "unexpected REPL output:"; printf '%s\n' "$out"; return 1; }
}
run 15-repl-stdin        repl_stdin
# A script reads a pipe through `os.input`, `os.read_line`, `os.stdin_lines` and `os.stdin()` (src/test/stdin/stdin.cy).
script_stdin() {
  out=$({ printf 'Ann\nx\r\nabcdef\nl1\nl2\nlast'; head -c 9000 /dev/zero | tr '\0' 'y'; } | zig-out/bin/cyber src/test/stdin/stdin.cy 2>&1) || { printf '%s\n' "$out"; return 1; }
  [ "$out" = "$(printf 'Name: \ndone')" ] || { echo "unexpected output:"; printf '%s\n' "$out"; return 1; }
}
run 16-script-stdin      script_stdin
if [ $fail -eq 0 ]; then echo "DONE all steps rc=0"; else echo "FAILED see $L"; fi
exit $fail
