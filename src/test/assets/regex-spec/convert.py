# Converts the TOML test data of rust-lang/regex to the JSON fixtures of modules/regex_spec.cy.
# Usage: python3 conv.py <testdata dir> <out dir>
import json, os, re, sys, tomllib, collections

src, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
skipped = collections.Counter()
kept = 0

def unescape(s):
    # The escapes of the regex-test crate: \xNN, \n, \r, \t, \\ and \0.
    b = bytearray()
    raw = s.encode('utf-8')
    i = 0
    while i < len(raw):
        c = raw[i]
        if c == 0x5c and i + 1 < len(raw):
            n = chr(raw[i + 1])
            if n == 'x':
                b.append(int(raw[i + 2:i + 4].decode(), 16)); i += 4; continue
            m = {'n': 10, 'r': 13, 't': 9, '\\': 0x5c, '0': 0}
            if n in m:
                b.append(m[n]); i += 2; continue
        b.append(c); i += 1
    return bytes(b)

def is_utf8(b):
    try:
        b.decode('utf-8'); return True
    except UnicodeDecodeError:
        return False

def unsupported_class(regex):
    # Unicode properties other than general categories, scripts and a few binary ones are left out by design.
    for m in re.finditer(r'\\[pP]\{\^?([^}]*)\}', regex):
        body = m.group(1)
        sep = re.search(r'!?[=:]', body)
        if sep:
            prop = re.sub(r'[-_ ]', '', body[:sep.start()]).lower()
            if prop not in ('gc', 'generalcategory', 'sc', 'script'):
                return True
        elif re.sub(r'[-_ ]', '', body).lower() in ('math', 'emoji', 'extendedpictographic', 'regionalindicator'):
            return True
    return False

def norm_match(m):
    # Returns (groups, has_groups): a list of [start, end] or None by group.
    if isinstance(m, dict):
        if m.get('id', 0) != 0:
            return None
        if 'span' in m:
            return [m['span']], False
        m = m['spans']
    if len(m) == 2 and all(isinstance(x, int) for x in m):
        return [m], False
    return [g if g else None for g in m], True

files = []
for root, _, names in os.walk(src):
    for n in sorted(names):
        if n.endswith('.toml'):
            files.append(os.path.join(root, n))
for path in sorted(files):
    rel = os.path.relpath(path, src)
    data = tomllib.load(open(path, 'rb'))
    tests = []
    for t in data.get('test', []):
        def skip(why):
            skipped[why] += 1
        if not isinstance(t['regex'], str):
            skip('regex set'); continue
        if t.get('match-kind', 'leftmost-first') != 'leftmost-first':
            skip('match-kind'); continue
        if t.get('search-kind', 'leftmost') != 'leftmost':
            skip('search-kind'); continue
        if 'line-terminator' in t:
            skip('line-terminator'); continue
        if rel.startswith('regex-lite'):
            # The answers of an engine without Unicode classes.
            skip('regex-lite'); continue
        if unsupported_class(t['regex']):
            skip('unicode property'); continue
        hay = t['haystack']
        hay = unescape(hay) if t.get('unescape', False) else hay.encode('utf-8')
        if not is_utf8(hay):
            skip('haystack not utf8'); continue
        ascii_only = all(c < 128 for c in hay) and all(ord(c) < 128 for c in t['regex'])
        # Without Unicode or UTF-8 mode the meaning is the same only when everything is ASCII.
        if not t.get('unicode', True) and not ascii_only:
            skip('unicode off'); continue
        if not t.get('utf8', True) and not ascii_only:
            skip('utf8 off'); continue
        # Flags that this module rejects by design: (?-u) and (?R).
        if re.search(r'\(\?[a-zA-Z]*-[a-zA-Z]*u', t['regex']) or re.search(r'\(\?[a-zA-Z-]*R', t['regex']):
            skip('flag -u or R'); continue
        anchored = t.get('anchored', False)
        if anchored and len(t.get('matches', [])) > 1:
            skip('anchored iteration'); continue
        start = 0
        if 'bounds' in t:
            b = t['bounds']
            s, e = (b['start'], b['end']) if isinstance(b, dict) else b
            if e != len(hay):
                skip('end bound'); continue
            start = s
        regex = t['regex']
        if t.get('case-insensitive', False):
            regex = '(?i)' + regex
        if anchored and start != 0:
            skip('anchored with start'); continue
        matches = []
        caps = False
        bad = False
        for m in t.get('matches', []):
            r = norm_match(m)
            if r is None:
                bad = True; break
            matches.append(r[0])
            caps = caps or r[1]
        if bad:
            skip('pattern id'); continue
        e = {'name': rel[:-5] + '/' + t['name'], 'regex': regex, 'hay': hay.hex(), 'matches': matches}
        if caps: e['caps'] = True
        if start: e['start'] = start
        if not t.get('compiles', True): e['compiles'] = False
        if 'match-limit' in t: e['limit'] = t['match-limit']
        if anchored:
            # An anchored search with at most one match is the first match of the pattern after \A.
            if e.get('compiles', True):
                e['regex'] = '\\A(?:' + regex + ')'
            e['limit'] = 1
        tests.append(e)
    if tests:
        name = rel[:-5].replace(os.sep, '-') + '.json'
        with open(os.path.join(out, name), 'w') as f:
            lines = [json.dumps(e, ensure_ascii=False, separators=(',', ':')) for e in tests]
            f.write('[\n' + ',\n'.join(lines) + '\n]\n')
        kept += len(tests)
        print(f'{name}: {len(tests)}')
print('kept', kept, 'skipped', dict(skipped))
