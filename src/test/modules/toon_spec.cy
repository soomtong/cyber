-- Runs the TOON conformance fixtures in `src/test/assets/toon-spec` (spec v4.4).
use json
use toon
use os
use t 'test'

files := []str{
    'encode/arrays-nested', 'encode/arrays-objects', 'encode/arrays-primitive', 'encode/arrays-tabular',
    'encode/delimiters', 'encode/objects-keyed', 'encode/objects', 'encode/primitives', 'encode/whitespace',
    'decode/arrays-nested', 'decode/arrays-primitive', 'decode/arrays-tabular', 'decode/blank-lines',
    'decode/comments', 'decode/delimiters', 'decode/indentation-errors', 'decode/numbers', 'decode/objects-keyed',
    'decode/objects', 'decode/primitives', 'decode/root-form', 'decode/validation-errors', 'decode/whitespace',
}

--| Ordered equality: TOON keeps key order, so the decoded keys must come in the expected order.
fn same(a json.Value, b json.Value) -> bool:
    if !a.eq(b):
        return false
    switch a:
        case .array |x|:
            for 0..x.len() |i|:
                if !same(x[i], b[i]):
                    return false
            return true
        case .object |x|:
            y := b.as_object().?
            for 0..x.len() |i|:
                if x.entries[i].key != y.entries[i].key:
                    return false
                if !same(x.entries[i].value, y.entries[i].value):
                    return false
            return true
        else:
            return true

count := 0
failed := 0
for files |f|:
    doc := json.parse(os.read_file('src/test/assets/toon-spec/' + f + '.json')!)!
    for doc['tests'].as_array().? |i, test|:
        opts := test['options']
        should_err := test['shouldError'].as_bool() ?else false
        delim := opts['delimiter'].as_str() ?else ','
        indent := opts['indentSize'].as_int() ?else 2
        var ok bool = false
        if f.starts_with('encode'):
            var eo toon.EncodeOptions = {indent=indent}
            if delim == '\t':
                eo.delim = .tab
            else delim == '|':
                eo.delim = .pipe
            exp := test['expected'].as_str() ?else ''
            try:
                got := toon.encode(test['input'], eo)!
                ok = !should_err and got == exp
            else:
                ok = should_err
        else:
            var diag json.Diag = {}
            strict := opts['strict'].as_bool() ?else true
            try:
                got := toon.decode(test['input'].as_str().?, {indent=indent, strict=strict}, &&diag)!
                ok = !should_err and same(got, test['expected'])
            else:
                ok = should_err
        count += 1
        if !ok:
            failed += 1
            print('FAIL %{f}[%{i}]: %{test['name'].as_str() ?else ''}')
t.eq(564, count)
t.eq(0, failed)

--cytest: pass
