#!/bin/sh
# Runs the probe binary once with allocation N failing and appends one line to $OUT/summary.txt.
# usage: run_one.sh N   (env: OUT dir, BIN, PROBE_SCN, PROBE_STICKY)
#   ok     the process exited 0: no abort, no leak, and the eval after the failure passed.
#   leak   the test allocator reported a leak and nothing else went wrong.
#   crash  anything else (panic, signal, unfreed objects).
# The log of an `ok` run is removed. The others stay in $OUT/N.log.
n=$1
log="$OUT/$n.log"
PROBE_N=$n "$BIN" >"$log" 2>&1
rc=$?
line=$(rg -ao 'PROBE n=.*' "$log" | head -1)
msg=$(rg -ao 'PROBE_MSG .*' "$log" | head -1 | sed 's/PROBE_MSG //')
if [ $rc -eq 0 ]; then
  echo "$n ok | $line | $msg" >> "$OUT/summary.txt"
  rm -f "$log"
elif [ -n "$line" ] && rg -aq 'leaked' "$log" && ! rg -aq 'panic:|Segmentation|Bus error|Unfreed' "$log"; then
  echo "$n leak | $line | $msg" >> "$OUT/summary.txt"
else
  echo "$n crash rc=$rc | $line | $msg" >> "$OUT/summary.txt"
fi
