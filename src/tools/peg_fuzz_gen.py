# Differential fuzzing of the `peg` module against the `re` module of LPeg: writes random grammars and inputs with
# LPeg's answers as JSON. `peg_fuzz_run.cy` compares them with the module.
# Needs `lua` with `lpeg` and `re` on its path.
# Usage: python3 src/tools/peg_fuzz_gen.py <seed> <count> <out.json>
#        cyber src/tools/peg_fuzz_run.cy <out.json>
import json, random, subprocess, sys, tempfile, os

seed, count, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
rnd = random.Random(seed)
LITS = ['a', 'b', 'ab', 'ba', 'x', '(', ')', ',', '=', '1', ' ', 'aa', '']
CLASSES = ['[ab]', '[a-c]', '[^a]', '[%d]', '[_%a]', '[^,%s]', '[x1]', '[^()]', '[%l%d]', '[(),]']
PERCENT = ['%d', '%a', '%s', '%w', '%x', '%l', '%u', '%p', '%D', '%S', '%A', '%W', '%nl']
NAMES = ['n', 'm']
# The last five are bytes that are not part of valid UTF-8 in any order: no byte here starts a sequence. LPeg counts
# bytes and the module counts code points, and both count such a byte as one unit, so the answers still compare.
ALPHABET = b'aabbx(),=1 A_\x80\xbf\xc0\xf8\xff'

# `caps` is what captures the expression may hold: 'all', 'none', or 'string' (inside a substitution capture,
# where only string captures and named captures keep the comparison simple).
def expr(depth, rules, caps):
    r = rnd.random()
    if depth > 4 or r < 0.22:
        return "'" + rnd.choice(LITS) + "'"
    if r < 0.32:
        return rnd.choice(CLASSES)
    if r < 0.38:
        return rnd.choice(PERCENT)
    if r < 0.42:
        return '.'
    if r < 0.56:
        return ' '.join(expr(depth + 1, rules, caps) for _ in range(rnd.randint(2, 3)))
    if r < 0.66:
        return '(' + ' / '.join(expr(depth + 1, rules, caps) for _ in range(rnd.randint(2, 3))) + ')'
    if r < 0.76:
        suffix = rnd.choice(['*', '+', '?', '?', '*', '^2', '^+1', '^-2', '^0', '^+0'])
        return '(' + expr(depth + 1, rules, caps) + ')' + suffix
    if r < 0.81:
        return rnd.choice(['&', '!']) + '(' + expr(depth + 1, rules, caps) + ')'
    if r < 0.86 and rules:
        return rnd.choice(rules)
    if r < 0.89:
        return '=' + rnd.choice(NAMES)
    if r < 0.905:
        return '{:' + rnd.choice(NAMES) + ': ' + expr(depth + 1, rules, 'none') + ' :}'
    if r < 0.92:
        # A capture with the name of a capture inside it, then a back reference: it must see the outer one.
        n = rnd.choice(NAMES)
        return ('{:' + n + ': ' + expr(depth + 1, rules, 'none') + ' {:' + n + ': ' + expr(depth + 1, rules, 'none')
                + ' :} :} =' + n)
    if caps == 'none':
        return "'" + rnd.choice(LITS) + "'"
    if r < 0.95:
        tmpl = rnd.choice(['#', '#%0', '<%1#>', '%0#%0', '#%%', '%1#%2'])
        return '(' + expr(depth + 1, rules, 'all') + " -> '" + tmpl + "')"
    if caps == 'string':
        return "'" + rnd.choice(LITS) + "'"
    if r < 0.97:
        return '{~ ' + expr(depth + 1, rules, 'string') + ' ~}'
    if r < 0.98:
        return '{}'
    return '{ ' + expr(depth + 1, rules, caps) + ' }'

def grammar():
    if rnd.random() < 0.4:
        return expr(0, [], 'all'), ''
    rules = ['A', 'B', 'C', 'D'][:rnd.randint(1, 4)]
    # A rule that is called from a substitution capture must follow its restriction, so rules hold no captures
    # half of the time and string captures otherwise.
    caps = rnd.choice(['none', 'string'])
    g = '\n'.join(r + ' <- ' + expr(1, rules, caps) for r in rules)
    return g, 'Z <- ' + ' / '.join(rules) + '\n' + g

def hay():
    return bytes(rnd.choice(ALPHABET) for _ in range(rnd.randint(0, 10)))

LUA = r'''
local lpeg = require "lpeg"
local re = require "re"
local cases = dofile(arg[1])

-- Every match from left to right as `find_all` gives them: an empty match that touches the end of the match
-- before it is left out. Every unit of the input is one byte here. "!" when LPeg raises an error.
local function find_all(c)
  local ok, p = pcall(re.compile, c[1])
  if not ok then return "!" end
  local search = lpeg.P{ lpeg.Cp() * (p / 0) * lpeg.Cp() + 1 * lpeg.V(1) }
  local s, out, at, last = c[2], {}, 0, -1
  while at <= #s do
    local ok, a, b = pcall(search.match, search, s, at + 1)
    if not ok then return "!" end
    if not a then break end
    local start, stop = a - 1, b - 1
    if start == stop and stop == last then
      at = stop + 1
    else
      at = start == stop and stop + 1 or stop
      last = stop
      out[#out + 1] = start .. "-" .. stop
    end
  end
  return table.concat(out, ",")
end

for _, c in ipairs(cases) do
  local ok, p = pcall(re.compile, "(" .. c[1] .. ") {}")
  -- LPeg does not check a rule that the first rule does not reach. `c[3]` is the grammar with a first rule
  -- that calls every rule.
  local strict = c[3] == "" or pcall(re.compile, c[3])
  io.write(strict and "S" or "L", "\t", find_all(c), "\t")
  if not ok then
    io.write("E\t", (tostring(p):gsub("[\t\n]", " ")), "\n")
  else
    local res = table.pack(pcall(p.match, p, c[2]))
    if not res[1] then
      io.write("R\t", (tostring(res[2]):gsub("[\t\n]", " ")), "\n")
    elseif res[2] == nil then
      io.write("N\n")
    else
      io.write("M\t", res[res.n] - 1)
      for i = 2, res.n - 1 do
        local v = res[i]
        if type(v) == "number" then v = "" end
        io.write("\t", v)
      end
      io.write("\n")
    end
  end
end
'''

def lua_str(s):
    if isinstance(s, bytes):
        return '"' + ''.join('\\%d' % b for b in s) + '"'
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'

cases = []
for _ in range(count):
    g, strict = grammar()
    for _ in range(3):
        cases.append((g, hay(), strict))

with tempfile.TemporaryDirectory() as tmp:
    data = os.path.join(tmp, 'cases.lua')
    prog = os.path.join(tmp, 'run.lua')
    with open(data, 'w') as f:
        f.write('return {\n')
        for g, h, strict in cases:
            f.write('{' + lua_str(g) + ', ' + lua_str(h) + ', ' + lua_str(strict) + '},\n')
        f.write('}\n')
    with open(prog, 'w') as f:
        f.write(LUA)
    # A capture may hold bytes that are not UTF-8, so the answers are read as bytes and kept as lists of bytes.
    lines = subprocess.run(['lua', prog, data], capture_output=True, check=True).stdout.split(b'\n')

res = []
for (g, h, _), line in zip(cases, lines):
    parts = line.split(b'\t')
    strict = parts.pop(0) == b'S'
    found = parts.pop(0).decode()
    kind = parts[0].decode()
    c = {'peg': g, 'hay': list(h), 'kind': kind, 'strict': strict, 'all': found}
    if kind in 'ER':
        c['err'] = parts[1].decode(errors='replace')
    if kind == 'M':
        c['end'] = int(parts[1])
        c['caps'] = [list(v) for v in parts[2:]]
    res.append(c)
with open(out, 'w') as f:
    json.dump(res, f, ensure_ascii=False, separators=(',', ':'))
print(len(res), 'cases:', sum(1 for c in res if c['kind'] == 'M'), 'match,',
      sum(1 for c in res if c['kind'] == 'N'), 'no match,', sum(1 for c in res if c['kind'] == 'E'), 'rejected,',
      sum(1 for c in res if c['kind'] == 'R'), 'runtime errors')
