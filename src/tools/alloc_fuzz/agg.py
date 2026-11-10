"""Aggregates one fuzz result directory. usage: agg.py <dir>

Prints the count per kind (ok, leak, crash), the count per result
(r1, r2, r3, first line of the error summary), and the crash and leak
sites grouped by the top frames inside this repository.
"""
import sys, re, os, collections

d = os.path.abspath(sys.argv[1])
root = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))

# Frames of the probe itself are noise. The probe was appended to src/lib.zig,
# so they are the lib.zig frames past the original end of the file.
probe_line = None
p = os.path.join(os.path.dirname(d), 'probe_line')
if os.path.exists(p):
    probe_line = int(open(p).read().strip())
else:
    probe_line = len(open(os.path.join(root, 'src', 'lib.zig')).read().splitlines())

def in_probe(loc):
    f, line = loc.rsplit(':', 1)
    return f == 'src/lib.zig' and int(line) > probe_line

summ = [l.split(' ', 2) for l in open(os.path.join(d, 'summary.txt')).read().splitlines()]
kinds = collections.Counter(k for _, k, _ in summ)
print(dict(kinds))
res = collections.Counter()
for n, k, rest in summ:
    m = re.search(r'r1=(\d+) r2=(\d+) r3=(\d+)', rest)
    res[(k, m.groups() if m else None, rest.rsplit('|', 1)[-1].strip()[:60])] += 1
for key, c in res.most_common(25): print(c, key)

frame = re.compile(r'(?:%s|%s)/(src/[^:]+:\d+):\d+: \S+ in (\S+)' % (re.escape(root), re.escape(os.path.abspath(root))))
crash = collections.Counter(); crash_ex = {}
leak = collections.Counter(); leak_ex = {}
for n, k, rest in summ:
    p = os.path.join(d, n + '.log')
    if not os.path.exists(p): continue
    t = open(p, errors='replace').read()
    if k == 'crash':
        i = t.find('panic:')
        msg = t[i:t.find('\n', i)][:90] if i >= 0 else ('SEGV' if 'Segmentation' in t else ('BUS' if 'Bus error' in t else t[:80].replace('\n', ' ')))
        j = t.find('stack trace:', i if i >= 0 else 0)
        fr = frame.findall(t[j:] if j >= 0 else t[i if i >= 0 else 0:])
        fr = [f for f in fr if not in_probe(f[0])]
        key = (msg, ' < '.join(f'{a} {b}' for a, b in fr[:3]))
        crash[key] += 1; crash_ex.setdefault(key, n)
    else:
        for blk in t.split('leaked [')[1:]:
            fr = frame.findall(blk.split('(additional stack frames')[0])
            fr = [f for f in fr if not in_probe(f[0])]
            key = ' < '.join(f'{a} {b}' for a, b in fr[:2])
            leak[key] += 1; leak_ex.setdefault(key, n)
print('--- crash sites', len(crash))
for key, c in crash.most_common(60): print(c, 'ex', crash_ex[key], '|', key[0], '|', key[1])
print('--- leak sites', len(leak))
for key, c in leak.most_common(80): print(c, 'ex', leak_ex[key], '|', key)
