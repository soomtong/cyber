# Differential fuzzing of the `regex` module against ripgrep: writes random patterns and inputs with ripgrep's
# answers as JSON. `regex_fuzz_run.cy` compares them with the module.
# Usage: python3 src/tools/regex_fuzz_gen.py <seed> <count> <out.json>
#        cyber src/tools/regex_fuzz_run.cy <out.json>
import json, random, subprocess, sys, tempfile, os

seed, count, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
rnd = random.Random(seed)
LIT = ['a', 'b', 'c', 'A', 'B', 'k', 'K', 's', 'é', 'É', '가', '나', ' ', '1', '2', '_', '-', 'K', 'ſ', 'x', '😀', 'ß', 'σ', 'ς', 'Σ']

def lit():
    c = rnd.choice(LIT)
    if c in '-' and rnd.random() < 0.5:
        return '\\-'
    return c

def cls_item(depth):
    r = rnd.random()
    if r < 0.35:
        return rnd.choice(['a', 'b', 'c', 'k', 'é', '가', '1', '_', ' ', 'K', 's'])
    if r < 0.55:
        return rnd.choice(['a-c', '0-9', 'A-Z', 'a-z', '가-힣', 'à-ÿ', '1-2'])
    if r < 0.7:
        return rnd.choice(['\\d', '\\w', '\\s', '\\D', '\\W', '\\S'])
    if r < 0.8:
        return rnd.choice(['[:alpha:]', '[:digit:]', '[:^alpha:]', '[:space:]', '[:upper:]', '[:punct:]', '[:word:]', '[:xdigit:]', '[:alnum:]', '[:lower:]'])
    if r < 0.88:
        return rnd.choice(['\\p{L}', '\\p{Lu}', '\\P{Ll}', '\\pN', '\\p{Hangul}', '\\p{Greek}', '\\p{^Latin}', '\\p{sc=Latin}', '\\p{gc=Nd}', '\\p{Alphabetic}', '\\p{White_Space}', '\\p{Lowercase}', '\\p{Any}', '\\p{ASCII}', '\\p{Assigned}', '\\p{P}', '\\p{Cased_Letter}'])
    if r < 0.96 and depth < 3:
        return cls(depth + 1)
    return rnd.choice(['\\-', '\\]', '\\\\', '\\x41', '\\u00e9', '\\n'])

def cls(depth=0):
    s = '[' + ('^' if rnd.random() < 0.25 else '')
    for _ in range(rnd.randint(1, 3)):
        s += cls_item(depth)
    if rnd.random() < 0.2:
        s += rnd.choice(['&&', '--', '~~'])
        for _ in range(rnd.randint(1, 2)):
            s += cls_item(depth)
    return s + ']'

def atom(depth):
    r = rnd.random()
    if r < 0.4:
        return lit()
    if r < 0.48:
        return '.'
    if r < 0.6:
        return cls()
    if r < 0.7:
        return rnd.choice(['\\d', '\\w', '\\s', '\\D', '\\W', '\\S', '\\p{L}', '\\p{Lu}', '\\P{L}', '\\pN', '\\p{Hangul}'])
    if r < 0.8:
        return rnd.choice(['^', '$', '\\b', '\\B', '\\A', '\\z', '\\b{start}', '\\b{end}', '\\b{start-half}', '\\b{end-half}', '\\<', '\\>'])
    if depth < 3:
        body = alt(depth + 1)
        k = rnd.random()
        if k < 0.4:
            return '(' + body + ')'
        if k < 0.6:
            return '(?:' + body + ')'
        if k < 0.7:
            return '(?P<n%d>' % rnd.randint(0, 99999) + body + ')'
        if k < 0.9:
            return '(?' + rnd.choice(['i', 's', 'm', 'U', 'x', 'is', 'i-s', '-i', 'im', 'sU']) + ':' + body + ')'
        return '(?' + rnd.choice(['i', 's', 'm', 'U', '-i', 'x']) + ')' + body
    return lit()

def rep(depth):
    a = atom(depth)
    r = rnd.random()
    if r < 0.55:
        return a
    q = rnd.choice(['*', '+', '?', '{2}', '{1,2}', '{0,2}', '{2,}', '{0}', '{1,}', '{0,1}', '{3}'])
    if rnd.random() < 0.3:
        q += '?'
    return a + q

def cat(depth):
    return ''.join(rep(depth) for _ in range(rnd.randint(0 if depth else 1, 4)))

def alt(depth):
    return '|'.join(cat(depth) for _ in range(1 if rnd.random() < 0.7 else rnd.randint(2, 3)))

SOUP = list('()[]{}|*+?\\^$.-&~:,<>=!#Pab1 ') + ['é', '\\b', '\\d', '(?', '[^', '{1,', '\\x', '\\A', '[:alpha:]', '(?i)', '(?P<a>', '(?<b>', '\\z', '\\Z', '\\<', '{,2}', '(?x)', '\\1', 'k', '\\k']

def soup():
    return ''.join(rnd.choice(SOUP) for _ in range(rnd.randint(1, 8)))

def hay():
    return ''.join(rnd.choice(LIT + ['ab', 'abc', 'aa', '12', 'k', 'K']) for _ in range(rnd.randint(0, 14)))

def run_rg(pattern, text, path):
    with open(path, 'wb') as f:
        f.write(text.encode('utf-8'))
    p = subprocess.run(['rg', '--json', '-U', '--no-config', '--regex-size-limit', '10M', '-e', pattern, path], capture_output=True)
    if p.returncode == 2:
        return None
    res = []
    for line in p.stdout.split(b'\n'):
        if not line:
            continue
        msg = json.loads(line)
        if msg['type'] != 'match':
            continue
        base = msg['data']['absolute_offset']
        for sm in msg['data']['submatches']:
            res.append([base + sm['start'], base + sm['end']])
    return res

cases = []
tmp = tempfile.mkdtemp()
path = os.path.join(tmp, 'hay.txt')
for i in range(count):
    pattern = soup() if i % 3 == 2 else alt(0)
    text = hay()
    if '\n' in pattern or not pattern:
        continue
    want = run_rg(pattern, text, path)
    cases.append({'regex': pattern, 'hay': text, 'matches': want})
with open(out, 'w') as f:
    f.write('[\n' + ',\n'.join(json.dumps(c, ensure_ascii=False, separators=(',', ':')) for c in cases) + '\n]\n')
print(len(cases), 'cases,', sum(1 for c in cases if c['matches'] is None), 'rejected by rg')
