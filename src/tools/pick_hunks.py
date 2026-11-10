"""Prints the diff of one file with only the chosen hunks, to split a change into commits.

usage: pick_hunks.py <file> <n,n,...|all>   (1-based hunk numbers of `git diff <file>`)
example: pick_hunks.py src/vm.zig 1,3 | git apply --cached
"""
import subprocess, sys, re

f, sel = sys.argv[1], sys.argv[2]
d = subprocess.run(['git', 'diff', '--no-color', f], capture_output=True, text=True).stdout
parts = re.split(r'(?m)^(?=@@ )', d)
head, hunks = parts[0], parts[1:]
if sel != 'all':
    want = {int(x) for x in sel.split(',')}
    hunks = [h for i, h in enumerate(hunks, 1) if i in want]
sys.stdout.write(head + ''.join(hunks))
