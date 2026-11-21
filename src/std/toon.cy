use json

--| TOON (Token-Oriented Object Notation, spec v4.4) encoder and decoder.
--| TOON encodes the JSON data model (`json.Value`) with indentation, declared array lengths
--| and one header for arrays of uniform objects, which takes fewer tokens than JSON in a prompt.
--| Spec: https://github.com/toon-format/spec
--| Sample usage:
--| ```cy
--| use json
--| use toon
--|
--| v := json.parse('{"users": [{"id": 1, "name": "Ada"}, {"id": 2, "name": "Bob"}]}')!
--| print(toon.encode(v)!)
--| --> users[2]{id,name}:
--| -->   1,Ada
--| -->   2,Bob
--| back := toon.decode('tags[2]: a,b')!
--| print(json.stringify(back))     --> {"tags":["a","b"]}
--| ```
--| Numbers decode as `json.parse` reads them: an integer token that fits `int` to `json.Value.int`, another integer and
--| a number beyond the `float` range to `json.Value.number` (its text, without loss), others to `json.Value.float`.
--| The reference implementation decodes a number beyond the `float` range to a string instead.

--| The delimiter of inline arrays and table rows.
type Delim enum:
    case comma
    case tab
    case pipe

type EncodeOptions:
    --| Spaces per indentation level.
    indent int = 2
    delim  Delim = .comma

type DecodeOptions:
    --| Spaces per indentation level.
    indent int = 2
    --| When `false`, the decoder accepts count mismatches, duplicate keys (the last wins), tab indentation,
    --| blank lines inside arrays and deeper first lines of a nested scope, as the spec's non-strict mode.
    strict bool = true
    --| Keeps every number with a fraction or an exponent as `json.Value.number`, as `json.ParseOptions`.
    exact  bool = false

--| Encodes a value as TOON text. Returns `error.Unicode` when a string or key is not valid UTF-8.
fn encode(v json.Value) -> !str:
    return encode(v, EncodeOptions{})

fn encode(v json.Value, opts EncodeOptions) -> !str:
    e := Encoder{indent=opts.indent, delim=delim_byte(opts.delim), sym=delim_sym(opts.delim)}
    e.root(v)
    if e.bad_utf8:
        return error.Unicode
    return str(e.buf)

--| Decodes TOON text. Returns `error.Syntax` for malformed input and `error.Unicode` for input that is not UTF-8.
fn decode(src str) -> !json.Value:
    var diag json.Diag = {}
    return decode(src, DecodeOptions{}, &&diag)

--| Decodes TOON text. On failure, `diag` tells where and why.
fn decode(src str, diag &&json.Diag) -> !json.Value:
    return decode(src, DecodeOptions{}, diag)

fn decode(src str, opts DecodeOptions, diag &&json.Diag) -> !json.Value:
    if !str.is_utf8(src.span()):
        diag.msg = 'The input is not valid UTF-8.'
        return error.Unicode
    d := Decoder{strict=opts.strict, indent=opts.indent, exact=opts.exact}
    res := d.run(src) !else |err|:
        diag.msg = d.msg
        diag.line = d.err_line
        diag.col = d.err_col
        diag.pos = 0
        return err
    return res

--| Converts JSON text to TOON text.
fn from_json(src str) -> !str:
    return encode(json.parse(src)!)

--| Converts TOON text to compact JSON text.
fn to_json(src str) -> !str:
    return json.stringify(decode(src)!)

-fn delim_byte(d Delim) -> byte:
    switch d:
        case .comma: return ','
        case .tab: return '\t'
        case .pipe: return '|'

-fn delim_sym(d Delim) -> str:
    switch d:
        case .comma: return ''
        case .tab: return '\t'
        case .pipe: return '|'

-fn hex2(c byte) -> str:
    digits := '0123456789abcdef'
    return digits[int(c) >> 4..(int(c) >> 4) + 1] + digits[int(c) && 15..(int(c) && 15) + 1]

-fn hex_val(c byte) -> int:
    if c >= '0' and c <= '9':
        return int(c - '0')
    if c >= 'a' and c <= 'f':
        return int(c - 'a') + 10
    if c >= 'A' and c <= 'F':
        return int(c - 'A') + 10
    return -1

--| A column of a table header. A column with `sub` columns is a nested field group.
-type Col:
    name str
    sub  []Col

-fn is_primitive(v json.Value) -> bool:
    switch v:
        case .array: return false
        case .object: return false
        else: return true

--| Returns the columns of a table when every row is a non-empty object with the same keys
--| and every column holds only primitives or only uniform objects.
-fn columns(rows []json.Object) -> ?[]Col:
    first := rows[0]
    n := first.len()
    if n == 0:
        return none
    var cols []Col = {}
    for first.entries |e|:
        all_prim := true
        all_obj := true
        var subs []json.Object = {}
        for rows |r|:
            if r.len() != n:
                return none
            val := r.get(e.key) ?else:
                return none
            switch val:
                case .array:
                    return none
                case .object |o|:
                    if o.len() == 0:
                        return none
                    all_prim = false
                    subs.append(o)
                else:
                    all_obj = false
        if all_prim:
            cols.append(Col{name=e.key, sub={}})
        else all_obj:
            sub := columns(subs) ?else:
                return none
            cols.append(Col{name=e.key, sub=sub})
        else:
            return none
    return cols

--| Returns the table columns of an array, or `none` when it does not fit a table.
-fn array_columns(a []json.Value) -> ?[]Col:
    var rows []json.Object = {}
    for a |e|:
        switch e:
            case .object |o|:
                rows.append(o)
            else:
                return none
    return columns(rows)

--| Returns the table columns of an object whose values are uniform objects (keyed table form).
-fn keyed_columns(o json.Object) -> ?[]Col:
    if o.len() < 2:
        return none
    var rows []json.Object = {}
    for o.entries |e|:
        switch e.value:
            case .object |v|:
                rows.append(v)
            else:
                return none
    return columns(rows)

--| Returns whether `s` matches `[+-]?[0-9]+(\.[0-9]+)?(e[+-]?[0-9]+)?`, ignoring case.
-fn is_numeric_like(s str) -> bool:
    n := s.len()
    i := 0
    if i < n and (s[i] == '+' or s[i] == '-'):
        i += 1
    start := i
    while i < n and str.is_ascii_digit(s[i]):
        i += 1
    if i == start:
        return false
    if i < n and s[i] == '.':
        i += 1
        start = i
        while i < n and str.is_ascii_digit(s[i]):
            i += 1
        if i == start:
            return false
    if i < n and (s[i] == 'e' or s[i] == 'E'):
        i += 1
        if i < n and (s[i] == '+' or s[i] == '-'):
            i += 1
        start = i
        while i < n and str.is_ascii_digit(s[i]):
            i += 1
        if i == start:
            return false
    return i == n

--| Returns whether `s` matches `[A-Za-z_][A-Za-z0-9_.]*`.
-fn is_plain_key(s str) -> bool:
    if s.len() == 0:
        return false
    c := s[0]
    if !(str.is_ascii_alpha(c) or c == '_'):
        return false
    for 1..s.len() |i|:
        c = s[i]
        if !(str.is_ascii_alpha(c) or str.is_ascii_digit(c) or c == '_' or c == '.'):
            return false
    return true

-type Encoder:
    buf      []byte = {}
    indent   int
    delim    byte
    sym      str
    bad_utf8 bool = false

fn (&&Encoder) put(s str):
    self.buf.append(s.span())

fn (&&Encoder) line(depth int):
    if self.buf.len() > 0:
        self.buf.append(byte('\n'))
    for 0..depth * self.indent:
        self.buf.append(byte(' '))

fn (&Encoder) check_utf8(s str):
    if !s.is_ascii() and !str.is_utf8(s.span()):
        self.bad_utf8 = true

fn (&Encoder) quoted(s str) -> str:
    var out []byte = {}
    out.append(byte('"'))
    start := 0
    for 0..s.len() |i|:
        c := s[i]
        if c >= 0x20 and c != '"' and c != '\\':
            continue
        if i > start:
            out.append(s[start..i].span())
        start = i + 1
        switch c:
            case '"': out.append('\\"'.span())
            case '\\': out.append('\\\\'.span())
            case '\n': out.append('\\n'.span())
            case '\r': out.append('\\r'.span())
            case '\t': out.append('\\t'.span())
            else: out.append(('\\u00' + hex2(c)).span())
    if s.len() > start:
        out.append(s[start..].span())
    out.append(byte('"'))
    return str(out)

fn (&Encoder) key(k str) -> str:
    self.check_utf8(k)
    if is_plain_key(k):
        return k
    return self.quoted(k)

fn (&Encoder) needs_quote(s str, root bool) -> bool:
    n := s.len()
    if n == 0:
        return true
    first := s[0]
    last := s[n - 1]
    if first == ' ' or first == '\t' or last == ' ' or last == '\t':
        return true
    if first == '-' or first == '#':
        return true
    if s == 'true' or s == 'false' or s == 'null':
        return true
    -- U+FEFF at the start of a root string would read as a byte-order mark.
    if root and n >= 3 and first == 0xef and s[1] == 0xbb and s[2] == 0xbf:
        return true
    if is_numeric_like(s):
        return true
    for 0..n |i|:
        c := s[i]
        if c < 0x20 or c == ':' or c == '"' or c == '\\' or c == '[' or c == ']' or c == '{' or c == '}' or c == self.delim:
            return true
    return false

fn (&Encoder) prim(v json.Value, root bool) -> str:
    switch v:
        case .null: return 'null'
        case .bool |b|: return if (b) 'true' else 'false'
        case .int |i|: return i.fmt()
        case .float |f|:
            if json.is_finite(f):
                return json.fmt_float(f)
            return 'null'
        case .number |s|:
            return json.fmt_number(s)
        case .str |s|:
            self.check_utf8(s)
            if self.needs_quote(s, root):
                return self.quoted(s)
            return s
        else:
            panic('Expected a primitive.')

fn (&Encoder) join_prims(a []json.Value) -> str:
    var out []byte = {}
    for a |i, e|:
        if i > 0:
            out.append(self.delim)
        out.append(self.prim(e, false).span())
    return str(out)

fn (&Encoder) fields_text(cols []Col) -> str:
    out := '{'
    for cols |i, c|:
        if i > 0:
            out += str.init_rune(int(self.delim))
        out += self.key(c.name)
        if c.sub.len() > 0:
            out += self.fields_text(c.sub)
    return out + '}'

fn (&Encoder) cells(o json.Object, cols []Col, out &&[]byte, first bool) -> bool:
    is_first := first
    for cols |c|:
        v := o.get(c.name).?
        if c.sub.len() > 0:
            is_first = self.cells(v.as_object().?, c.sub, out, is_first)
        else:
            if !is_first:
                out.append(self.delim)
            out.append(self.prim(v, false).span())
            is_first = false
    return is_first

fn (&Encoder) row(o json.Object, cols []Col) -> str:
    var out []byte = {}
    _ = self.cells(o, cols, &&out, true)
    return str(out)

-fn all_primitive(a []json.Value) -> bool:
    for a |e|:
        if !is_primitive(e):
            return false
    return true

fn (&&Encoder) root(v json.Value):
    switch v:
        case .array |a|:
            if a.len() == 0:
                self.line(0)
                self.put('[]')
                return
            self.array('', a, 0, 1, '', true)
        case .object |o|:
            if o.len() == 0:
                return
            if keyed_columns(o) |cols|:
                self.keyed('', o, cols, 0, 1, '')
                return
            self.fields(o, 0)
        else:
            self.line(0)
            self.put(self.prim(v, true))

fn (&&Encoder) fields(o json.Object, depth int):
    for o.entries |e|:
        self.field(self.key(e.key), e.value, depth, depth + 1, '')

--| Writes a field whose line is at `depth` and whose nested content is at `child`.
fn (&&Encoder) field(k str, v json.Value, depth int, child int, prefix str):
    switch v:
        case .array |a|:
            if a.len() == 0:
                self.line(depth)
                self.put(prefix + k + ': []')
                return
            self.array(prefix + k, a, depth, child, '', true)
        case .object |o|:
            if o.len() > 0:
                if keyed_columns(o) |cols|:
                    self.keyed(prefix + k, o, cols, depth, child, '')
                    return
            self.line(depth)
            self.put(prefix + k + ':')
            for o.entries |e|:
                self.field(self.key(e.key), e.value, child, child + 1, '')
        else:
            self.line(depth)
            self.put(prefix + k + ': ' + self.prim(v, false))

--| Writes a non-empty array with the header `head`. Items are at `child`.
fn (&&Encoder) array(head str, a []json.Value, depth int, child int, prefix str, allow_table bool):
    n := a.len()
    self.line(depth)
    if all_primitive(a):
        self.put(prefix + head + '[%{n}%{self.sym}]: ' + self.join_prims(a))
        return
    if allow_table:
        if array_columns(a) |cols|:
            self.put(prefix + head + '[%{n}%{self.sym}]' + self.fields_text(cols) + ':')
            for a |e|:
                self.line(child)
                self.put(self.row(e.as_object().?, cols))
            return
    self.put(prefix + head + '[%{n}%{self.sym}]:')
    for a |e|:
        self.item(e, child)

fn (&&Encoder) keyed(head str, o json.Object, cols []Col, depth int, child int, prefix str):
    self.line(depth)
    self.put(prefix + head + '[%{o.len()}:%{self.sym}]' + self.fields_text(cols) + ':')
    for o.entries |e|:
        self.line(child)
        self.put(self.key(e.key) + ': ' + self.row(e.value.as_object().?, cols))

--| Writes a list item whose hyphen is at `depth`.
fn (&&Encoder) item(v json.Value, depth int):
    switch v:
        case .array |a|:
            if a.len() == 0:
                self.line(depth)
                self.put('- [0%{self.sym}]:')
                return
            -- A keyless table header is only valid at the root, so nested arrays use list form.
            self.array('', a, depth, depth + 1, '- ', false)
        case .object |o|:
            if o.len() == 0:
                self.line(depth)
                self.put('-')
                return
            first := o.entries[0]
            self.field(self.key(first.key), first.value, depth, depth + 2, '- ')
            for 1..o.entries.len() |i|:
                e := o.entries[i]
                self.field(self.key(e.key), e.value, depth + 1, depth + 2, '')
        else:
            self.line(depth)
            self.put('- ' + self.prim(v, false))

------------------------------------------------------------------------------
-- Decoder.

-type Line:
    depth int
    text  str
    num   int
    col   int
    blank bool

--| A parsed array header.
-type Header:
    key        ?str
    n          int
    keyed      bool
    delim      byte
    has_fields bool
    fields     []Col
    rest       str

--| The first unquoted colon, `[` and active delimiter of a line.
-type Scan:
    colon   int
    bracket int
    delim   int

--| Finds the first unquoted colon, `[` and `delim`. A quote opens a span to the next unescaped quote
--| or the end of the line.
-fn scan(s str, delim byte) -> Scan:
    res := Scan{colon=-1, bracket=-1, delim=-1}
    in_quote := false
    i := 0
    n := s.len()
    while i < n:
        c := s[i]
        if in_quote:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_quote = false
        else c == '"':
            in_quote = true
        else c == ':':
            if res.colon < 0:
                res.colon = i
        else c == '[':
            if res.bracket < 0:
                res.bracket = i
        if !in_quote and c == delim and res.delim < 0 and c != '"':
            res.delim = i
        i += 1
    return res

-fn trim_spaces(s str) -> str:
    start := 0
    end := s.len()
    while start < end and s[start] == ' ':
        start += 1
    while end > start and s[end - 1] == ' ':
        end -= 1
    return s[start..end]

-fn leaf_count(cols []Col) -> int:
    n := 0
    for cols |c|:
        if c.sub.len() > 0:
            n += leaf_count(c.sub)
        else:
            n += 1
    return n

-type Decoder:
    lines    []Line = {}
    pos      int = 0
    strict   bool
    indent   int
    exact    bool
    msg      str = ''
    err_line int = 0
    err_col  int = 0
    --| Content depths of the header spans that are open, outermost first.
    spans    []int = {}

fn (&&Decoder) fail_at(num int, col int, msg str) -> error:
    self.msg = msg
    self.err_line = num
    self.err_col = col
    return error.Syntax

fn (&&Decoder) fail(l Line, msg str) -> error:
    return self.fail_at(l.num, l.col, msg)

fn (&&Decoder) run(src str) -> !json.Value:
    self.prepare(src)!
    return self.root()

fn (&&Decoder) prepare(src str) -> !void:
    text := src
    if text.starts_with('\xEF\xBB\xBF'):
        text = text[3..]
    num := 0
    start := 0
    n := text.len()
    while start <= n:
        end := n
        if text[start..].index('\n') |i|:
            end = start + i
        num += 1
        raw := text[start..end]
        start = end + 1
        if raw.len() > 0 and raw[raw.len() - 1] == '\r':
            raw = raw[0..raw.len() - 1]
        raw = raw.trim_right(' ')
        spaces := 0
        tabs := 0
        i := 0
        while i < raw.len() and (raw[i] == ' ' or raw[i] == '\t'):
            if raw[i] == ' ':
                spaces += 1
            else:
                tabs += 1
            i += 1
        content := raw[i..]
        if raw.len() == 0 or (!self.strict and content.len() == 0):
            self.lines.append(Line{depth=0, text='', num=num, col=1, blank=true})
            continue
        if tabs == 0 and content[0] == '#':
            continue
        var depth int = 0
        if self.strict:
            if tabs > 0:
                return self.fail_at(num, 1, 'Indentation must use spaces, found a tab.')
            if spaces % self.indent != 0:
                return self.fail_at(num, 1, 'Indentation of %{spaces} spaces is not a multiple of %{self.indent}.')
            depth = spaces / self.indent
        else:
            depth = tabs + spaces / self.indent
        self.lines.append(Line{depth=depth, text=content, num=num, col=i + 1, blank=false})

fn (&Decoder) at_end() -> bool:
    return self.pos >= self.lines.len()

--| Skips blank lines. In strict mode a blank line inside an open header span is an error.
fn (&&Decoder) skip_blanks() -> !void:
    start := self.pos
    while self.pos < self.lines.len() and self.lines[self.pos].blank:
        self.pos += 1
    if self.pos > start and self.strict and self.spans.len() > 0 and self.pos < self.lines.len():
        if self.lines[self.pos].depth >= self.spans[0]:
            blank := self.lines[start]
            return self.fail(blank, 'A blank line can not appear inside an array or a keyed table.')

fn (&&Decoder) root() -> !json.Value:
    self.skip_blanks()!
    if self.at_end():
        return json.Value.object({})
    l := self.lines[self.pos]
    if l.depth > 0:
        return self.fail(l, 'The first line can not be indented.')
    if l.text == '[]':
        self.pos += 1
        self.expect_end()!
        return json.Value.array({})
    s := scan(l.text, ',')
    if s.colon >= 0 and s.bracket >= 0 and s.bracket < s.colon:
        h := self.header(l, l.text)!
        if h.key == none:
            self.pos += 1
            res := self.header_value(h, l, 1)!
            self.expect_end()!
            return res
    if s.colon < 0 and self.count_content() == 1:
        self.pos += 1
        return self.prim(l, l.text)
    var obj json.Object = {}
    self.fields(&&obj, 0, 0)!
    return json.Value.object(obj)

fn (&Decoder) count_content() -> int:
    n := 0
    for self.lines |l|:
        if !l.blank:
            n += 1
    return n

fn (&&Decoder) expect_end() -> !void:
    self.skip_blanks()!
    if !self.at_end():
        l := self.lines[self.pos]
        return self.fail(l, 'Unexpected content after the root array.')

--| Returns the content depth of a nested scope whose content should be at `depth`.
--| In non-strict mode a deeper first line sets the depth.
fn (&&Decoder) scope_depth(depth int) -> !int:
    self.skip_blanks()!
    if self.at_end():
        return depth
    l := self.lines[self.pos]
    if l.depth <= depth:
        return depth
    if self.strict:
        return self.fail(l, 'Expected indentation depth %{depth}, found %{l.depth}.')
    return l.depth

--| Reads fields at `depth` into `obj` until a line shallower than `floor`.
fn (&&Decoder) fields(obj &&json.Object, depth int, floor int) -> !void:
    while:
        self.skip_blanks()!
        if self.at_end():
            return
        l := self.lines[self.pos]
        if l.depth < floor:
            return
        if l.depth < depth:
            return self.fail(l, 'Expected indentation depth %{depth}, found %{l.depth}.')
        if l.depth > depth:
            return self.fail(l, 'Unexpected indentation: this line belongs to no field.')
        self.field(obj, l, l.text, depth + 1)!

--| Parses a key-value or array-header line and its nested content at `child`.
fn (&&Decoder) field(obj &&json.Object, l Line, text str, child int) -> !void:
    s := scan(text, ',')
    if s.colon < 0:
        return self.fail(l, 'Expected `key: value`, found a line without a colon.')
    if s.bracket >= 0 and s.bracket < s.colon:
        h := self.header(l, text)!
        k := h.key ?else:
            return self.fail(l, 'An array header without a key is only allowed at the root or after `- `.')
        self.pos += 1
        v := self.header_value(h, l, child)!
        self.put(obj, l, k, v)!
        return
    k := self.key_token(l, text[0..s.colon])!
    rest := trim_spaces(text[s.colon + 1..])
    self.pos += 1
    if rest.len() == 0:
        d := self.scope_depth(child)!
        var nested json.Object = {}
        self.fields(&&nested, d, child)!
        self.put(obj, l, k, json.Value.object(nested))!
    else rest == '[]':
        self.put(obj, l, k, json.Value.array({}))!
    else:
        self.put(obj, l, k, self.prim(l, rest)!)!

fn (&&Decoder) put(obj &&json.Object, l Line, k str, v json.Value) -> !void:
    if self.strict and obj.contains(k):
        return self.fail(l, 'Duplicate key `%{k}`.')
    obj.set(k, v)

--| Decodes a key token: a quoted key or any text with spaces trimmed.
fn (&&Decoder) key_token(l Line, tok str) -> !str:
    t := trim_spaces(tok)
    if t.len() > 0 and t[0] == '"':
        return self.quoted_token(l, t)
    return t

--| Decodes a token that starts with a quote. The closing quote must end the token.
fn (&&Decoder) quoted_token(l Line, t str) -> !str:
    var buf []byte = {}
    i := 1
    n := t.len()
    while i < n:
        c := t[i]
        if c == '"':
            if i != n - 1:
                return self.fail(l, 'Unexpected characters after the closing quote in `%{t}`.')
            return str(buf)
        if c != '\\':
            buf.append(c)
            i += 1
            continue
        if i + 1 >= n:
            break
        e := t[i + 1]
        i += 2
        switch e:
            case '\\': buf.append(byte('\\'))
            case '"': buf.append(byte('"'))
            case 'n': buf.append(byte('\n'))
            case 'r': buf.append(byte('\r'))
            case 't': buf.append(byte('\t'))
            case 'u':
                if i + 4 > n:
                    return self.fail(l, 'Expected four hex digits after `\\u`.')
                cp := 0
                for 0..4 |j|:
                    d := hex_val(t[i + j])
                    if d < 0:
                        return self.fail(l, 'Expected four hex digits after `\\u`.')
                    cp = cp * 16 + d
                i += 4
                if cp >= 0xd800 and cp <= 0xdfff:
                    return self.fail(l, 'A `\\u` escape can not encode a surrogate (`\\u%{cp.fmt(.hex)}`).')
                buf.append(str.init_rune(cp).span())
            else:
                return self.fail(l, 'Unknown escape `\\%{str.init_rune(int(e))}`.')
    return self.fail(l, 'Expected `"` to end the string.')

--| Decodes a value token.
fn (&&Decoder) prim(l Line, tok str) -> !json.Value:
    t := trim_spaces(tok)
    if t.len() > 0 and t[0] == '"':
        return json.Value.str(self.quoted_token(l, t)!)
    if t == 'true':
        return json.Value.bool(true)
    if t == 'false':
        return json.Value.bool(false)
    if t == 'null':
        return json.Value.null
    if is_json_number(t):
        return json.parse_number(t, self.exact) ?else json.Value.str(t)
    return json.Value.str(t)

--| Returns whether `s` matches `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
-fn is_json_number(s str) -> bool:
    n := s.len()
    i := 0
    if i < n and s[i] == '-':
        i += 1
    if i >= n or !str.is_ascii_digit(s[i]):
        return false
    if s[i] == '0':
        i += 1
    else:
        while i < n and str.is_ascii_digit(s[i]):
            i += 1
    if i < n and s[i] == '.':
        i += 1
        if i >= n or !str.is_ascii_digit(s[i]):
            return false
        while i < n and str.is_ascii_digit(s[i]):
            i += 1
    if i < n and (s[i] == 'e' or s[i] == 'E'):
        i += 1
        if i < n and (s[i] == '+' or s[i] == '-'):
            i += 1
        if i >= n or !str.is_ascii_digit(s[i]):
            return false
        while i < n and str.is_ascii_digit(s[i]):
            i += 1
    return i == n

--| Splits `s` on unquoted `delim` and decodes each token.
fn (&&Decoder) values(l Line, s str, delim byte) -> ![]json.Value:
    var res []json.Value = {}
    in_quote := false
    start := 0
    i := 0
    n := s.len()
    while i < n:
        c := s[i]
        if in_quote:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                in_quote = false
        else c == '"':
            in_quote = true
        else c == delim:
            res.append(self.prim(l, s[start..i])!)
            start = i + 1
        i += 1
    res.append(self.prim(l, s[start..])!)
    return res

--| Parses an array header line. `text` starts at the key or at `[`.
fn (&&Decoder) header(l Line, text str) -> !Header:
    s := scan(text, ',')
    b := s.bracket
    var key ?str = none
    if b > 0:
        last := text[b - 1]
        if last == ' ' or last == '\t':
            return self.fail(l, 'An array header can not have whitespace before `[`.')
        key_text := text[0..b]
        if key_text[0] == '"':
            key = self.quoted_token(l, key_text)!
        else:
            key = key_text
    n := text.len()
    i := b + 1
    digits_start := i
    while i < n and str.is_ascii_digit(text[i]):
        i += 1
    if i == digits_start or (i - digits_start > 1 and text[digits_start] == '0'):
        return self.fail(l, 'Expected an array length without leading zeros in the array header.')
    count := 0
    for digits_start..i |j|:
        d := int(text[j] - '0')
        if count > (9223372036854775807 - d) / 10:
            -- Too large to represent; the count check reports it.
            count = 9223372036854775807
            break
        count = count * 10 + d
    keyed := false
    if i < n and text[i] == ':':
        keyed = true
        i += 1
    var delim byte = ','
    if i < n and (text[i] == '\t' or text[i] == '|'):
        delim = text[i]
        i += 1
    if i >= n or text[i] != ']':
        return self.fail(l, 'Expected `]` to close the array length.')
    i += 1
    has_fields := false
    var fields []Col = {}
    if i < n and text[i] == '{':
        has_fields = true
        fields = self.field_list(l, text, &i, delim)!
    if i >= n or text[i] != ':':
        return self.fail(l, 'Expected `:` after the array header.')
    i += 1
    if keyed and !has_fields:
        return self.fail(l, 'A keyed table header needs a field list: `key[N:]{a,b}:`.')
    rest := trim_spaces(text[i..])
    if has_fields and rest.len() > 0:
        return self.fail(l, 'A table header can not have values after its colon.')
    return Header{key=key, n=count, keyed=keyed, delim=delim, has_fields=has_fields, fields=fields, rest=rest}

--| Parses `{a,b{c}}` at `i.*`.
fn (&&Decoder) field_list(l Line, text str, i &int, delim byte) -> ![]Col:
    var cols []Col = {}
    n := text.len()
    i.* += 1
    while:
        start := i.*
        -- A quote opens a span, also in the middle of a name, so `{` `}` and delimiters in it do not count.
        while i.* < n:
            c := text[i.*]
            if c == '"':
                i.* += 1
                while i.* < n and text[i.*] != '"':
                    if text[i.*] == '\\':
                        i.* += 1
                    i.* += 1
                i.* += 1
                continue
            if c == delim or c == '{' or c == '}':
                break
            if c == ',' or c == '|' or c == '\t':
                return self.fail(l, 'The field list uses a delimiter other than the one declared in `[...]`.')
            i.* += 1
        if i.* >= n:
            return self.fail(l, 'Expected `}` to close the field list.')
        raw := text[start..i.*]
        if text[i.*] == '{' and raw.len() > 0 and raw[raw.len() - 1] == ' ':
            return self.fail(l, 'A field name can not have whitespace before `{`.')
        name_tok := trim_spaces(raw)
        if name_tok.len() == 0:
            return self.fail(l, 'Expected a field name in the field list.')
        name := self.key_token(l, name_tok)!
        var sub []Col = {}
        if text[i.*] == '{':
            sub = self.field_list(l, text, i, delim)!
            while i.* < n and text[i.*] == ' ':
                i.* += 1
        if self.strict:
            for cols |c|:
                if c.name == name:
                    return self.fail(l, 'Duplicate field `%{name}` in the field list.')
        cols.append(Col{name=name, sub=sub})
        if i.* >= n:
            return self.fail(l, 'Expected `}` to close the field list.')
        c := text[i.*]
        i.* += 1
        if c == '}':
            return cols
        if c != delim:
            return self.fail(l, 'Expected the delimiter or `}` in the field list.')

--| Reads the inline values, rows or items of a header on line `l`. Nested content is at `child`.
fn (&&Decoder) header_value(h Header, l Line, child int) -> !json.Value:
    if h.keyed:
        return self.keyed_rows(h, l, child)
    if h.has_fields:
        return self.table_rows(h, l, child)
    if h.rest.len() > 0:
        vals := self.values(l, h.rest, h.delim)!
        self.check_count(l, h.n, vals.len(), 'values')!
        return json.Value.array(vals)
    return self.list_items(h, l, child)

fn (&&Decoder) check_count(l Line, want int, got int, what str) -> !void:
    if self.strict and want != got:
        return self.fail(l, 'The header declares %{want} %{what}, found %{got}.')

--| Builds an object from row cells by walking the columns.
fn (&Decoder) build(l Line, cols []Col, cells []json.Value, idx &int) -> json.Object:
    var obj json.Object = {}
    for cols |c|:
        if c.sub.len() > 0:
            obj.set(c.name, json.Value.object(self.build(l, c.sub, cells, idx)))
        else:
            obj.set(c.name, cells[idx.*])
            idx.* += 1
    return obj

fn (&&Decoder) open_span(child int) -> !int:
    d := self.scope_depth(child)!
    self.spans.append(d)
    return d

fn (&&Decoder) close_span():
    self.spans.size_down(self.spans.len() - 1)

fn (&&Decoder) table_rows(h Header, l Line, child int) -> !json.Value:
    depth := self.open_span(child)!
    leaves := leaf_count(h.fields)
    var rows []json.Value = {}
    while:
        self.skip_blanks()!
        if self.at_end():
            break
        r := self.lines[self.pos]
        if r.depth < child:
            break
        if r.depth < depth:
            return self.fail(r, 'Expected indentation depth %{depth}, found %{r.depth}.')
        if r.depth > depth:
            return self.fail(r, 'Unexpected indentation inside the table rows.')
        s := scan(r.text, h.delim)
        if s.colon >= 0 and (s.delim < 0 or s.colon < s.delim):
            break
        cells := self.values(r, r.text, h.delim)!
        if cells.len() != leaves:
            return self.fail(r, 'The table header declares %{leaves} fields, found %{cells.len()} values in the row.')
        idx := 0
        rows.append(json.Value.object(self.build(r, h.fields, cells, &idx)))
        self.pos += 1
    self.close_span()
    self.check_count(l, h.n, rows.len(), 'rows')!
    return json.Value.array(rows)

fn (&&Decoder) keyed_rows(h Header, l Line, child int) -> !json.Value:
    depth := self.open_span(child)!
    leaves := leaf_count(h.fields)
    var obj json.Object = {}
    count := 0
    while:
        self.skip_blanks()!
        if self.at_end():
            break
        r := self.lines[self.pos]
        if r.depth < child:
            break
        if r.depth < depth:
            return self.fail(r, 'Expected indentation depth %{depth}, found %{r.depth}.')
        if r.depth > depth:
            return self.fail(r, 'Unexpected indentation inside the keyed table rows.')
        s := scan(r.text, h.delim)
        if s.colon < 0:
            return self.fail(r, 'Expected `key: values` in a keyed table row.')
        k := self.key_token(r, r.text[0..s.colon])!
        rest := trim_spaces(r.text[s.colon + 1..])
        var cells []json.Value = {}
        if rest.len() > 0:
            cells = self.values(r, rest, h.delim)!
        if cells.len() != leaves:
            return self.fail(r, 'The table header declares %{leaves} fields, found %{cells.len()} values in the row.')
        idx := 0
        self.put(&&obj, r, k, json.Value.object(self.build(r, h.fields, cells, &idx)))!
        count += 1
        self.pos += 1
    self.close_span()
    self.check_count(l, h.n, count, 'entries')!
    return json.Value.object(obj)

fn (&&Decoder) list_items(h Header, l Line, child int) -> !json.Value:
    depth := self.open_span(child)!
    var items []json.Value = {}
    while:
        self.skip_blanks()!
        if self.at_end():
            break
        r := self.lines[self.pos]
        if r.depth < child:
            break
        if r.depth < depth:
            return self.fail(r, 'Expected indentation depth %{depth}, found %{r.depth}.')
        if r.depth > depth:
            return self.fail(r, 'Unexpected indentation inside the list.')
        if !(r.text == '-' or r.text.starts_with('- ')):
            break
        items.append(self.list_item(r, depth)!)
    self.close_span()
    self.check_count(l, h.n, items.len(), 'items')!
    return json.Value.array(items)

--| Parses a list item whose hyphen is at `depth`.
fn (&&Decoder) list_item(l Line, depth int) -> !json.Value:
    if l.text == '-':
        self.pos += 1
        return json.Value.object({})
    rest := l.text[1..].trim_left(' ')
    if rest == '[]':
        self.pos += 1
        return json.Value.array({})
    s := scan(rest, ',')
    if s.colon >= 0 and s.bracket >= 0 and s.bracket < s.colon:
        h := self.header(l, rest)!
        if h.key == none:
            if h.has_fields:
                return self.fail(l, 'A table header without a key is only allowed at the root.')
            self.pos += 1
            return self.header_value(h, l, depth + 1)
    if s.colon >= 0:
        -- An object: the first field is on the hyphen line, its scope at `depth + 2`, other fields at `depth + 1`.
        var obj json.Object = {}
        self.field(&&obj, l, rest, depth + 2)!
        self.fields(&&obj, depth + 1, depth + 1)!
        return json.Value.object(obj)
    self.pos += 1
    return self.prim(l, rest)
