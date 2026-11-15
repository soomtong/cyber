use meta

--| JSON (RFC 8259) values, parser and serializer.
--| `Value` is also the data model of the `toon` module.
--| Sample usage:
--| ```cy
--| use json
--|
--| v := json.parse('{"name": "Ada", "tags": ["a", "b"]}')!
--| print(v['name'].as_str().?)     --> Ada
--| print(v['tags'][1])             --> Value.str('b')
--| print(json.stringify(v))        --> {"name":"Ada","tags":["a","b"]}
--|
--| var diag json.Diag = {}
--| try:
--|     _ = json.parse('[1,', &diag)!
--| else |err|:
--|     print('%{err} %{diag.line}:%{diag.col} %{diag.msg}')
--| ```

--| Parsing stops with `error.Syntax` when arrays and objects nest deeper than this.
const MaxDepth = 256

--| A JSON value.
--| A number without a fraction or an exponent that fits `int` is parsed as `int`. Other numbers are `float`.
type Value enum:
    case null
    case bool   bool
    case int    int
    case float  float
    case str    str
    case array  []Value
    case object Object

--| An object member.
type Entry:
    key   str
    value Value

--| A JSON object. Entries keep their insertion order and keys are unique.
type Object:
    entries []Entry = {}

--| Where and why parsing failed. `line` and `col` start at 1, `col` counts bytes.
type Diag:
    msg  str = ''
    line int = 0
    col  int = 0
    pos  int = 0

--| Returns the number of entries.
fn (&Object) len() -> int:
    return self.entries.len()

--| Returns the position of `key` in `entries`.
fn (&Object) index_of(key str) -> ?int:
    for 0..self.entries.len() |i|:
        if self.entries[i].key == key:
            return i
    return none

fn (&Object) contains(key str) -> bool:
    if self.index_of(key) |i|:
        return true
    return false

fn (&Object) get(key str) -> ?Value:
    if self.index_of(key) |i|:
        return self.entries[i].value
    return none

--| Sets the value of `key`. An existing key keeps its position.
fn (&Object) set(key str, value Value):
    if self.index_of(key) |i|:
        self.entries[i].value = value
        return
    self.entries = self.entries.append(Entry{key=key, value=value})

--| Removes `key` and returns whether it was present.
fn (&Object) remove(key str) -> bool:
    if self.index_of(key) |i|:
        self.entries = self.entries.remove(i)
        return true
    return false

fn (&Object) keys() -> []str:
    var res []str = {}
    for self.entries |e|:
        res = res.append(e.key)
    return res

--| Returns the member `key` of an object, or `Value.null` when the value is not an object or has no such key.
fn (&Value) @index(key str) -> Value:
    switch self.*:
        case .object |o|:
            return o.get(key) ?else Value.null
        else:
            return Value.null

--| Returns the element at `idx` of an array, or `Value.null` when the value is not an array or `idx` is out of bounds.
fn (&Value) @index(idx int) -> Value:
    switch self.*:
        case .array |a|:
            if idx >= 0 and idx < a.len():
                return a[idx]
            return Value.null
        else:
            return Value.null

--| Returns the member `key` of an object.
fn (&Value) get(key str) -> ?Value:
    switch self.*:
        case .object |o|:
            return o.get(key)
        else:
            return none

--| Returns the element at `idx` of an array.
fn (&Value) at(idx int) -> ?Value:
    switch self.*:
        case .array |a|:
            if idx >= 0 and idx < a.len():
                return a[idx]
            return none
        else:
            return none

--| Returns the number of elements of an array or entries of an object, otherwise 0.
fn (&Value) len() -> int:
    switch self.*:
        case .array |a|:
            return a.len()
        case .object |o|:
            return o.len()
        else:
            return 0

fn (&Value) is_null() -> bool:
    switch self.*:
        case .null:
            return true
        else:
            return false

fn (&Value) as_bool() -> ?bool:
    switch self.*:
        case .bool |b|:
            return b
        else:
            return none

--| Returns an `int` value. A `float` is not converted.
fn (&Value) as_int() -> ?int:
    switch self.*:
        case .int |i|:
            return i
        else:
            return none

--| Returns a number as a `float`, converting an `int`.
fn (&Value) as_float() -> ?float:
    switch self.*:
        case .int |i|:
            return float(i)
        case .float |f|:
            return f
        else:
            return none

fn (&Value) as_str() -> ?str:
    switch self.*:
        case .str |s|:
            return s
        else:
            return none

fn (&Value) as_array() -> ?[]Value:
    switch self.*:
        case .array |a|:
            return a
        else:
            return none

fn (&Value) as_object() -> ?Object:
    switch self.*:
        case .object |o|:
            return o
        else:
            return none

--| Returns the JSON type name: `null`, `bool`, `number`, `string`, `array` or `object`.
fn (&Value) kind() -> str:
    switch self.*:
        case .null: return 'null'
        case .bool: return 'bool'
        case .int: return 'number'
        case .float: return 'number'
        case .str: return 'string'
        case .array: return 'array'
        case .object: return 'object'

--| Returns whether two values are equal in the JSON model: numbers compare by value (`1 == 1.0`),
--| objects by their key sets and values regardless of key order, arrays element by element.
fn (&Value) eq(other Value) -> bool:
    switch self.*:
        case .null:
            return other.is_null()
        case .bool |b|:
            if other.as_bool() |o|:
                return b == o
            return false
        case .int |i|:
            if other.as_int() |o|:
                return i == o
            if other.as_float() |o|:
                return float(i) == o
            return false
        case .float |f|:
            if other.as_float() |o|:
                return f == o
            return false
        case .str |s|:
            if other.as_str() |o|:
                return s == o
            return false
        case .array |a|:
            o := other.as_array() ?else:
                return false
            if a.len() != o.len():
                return false
            for 0..a.len() |i|:
                if !a[i].eq(o[i]):
                    return false
            return true
        case .object |a|:
            o := other.as_object() ?else:
                return false
            if a.len() != o.len():
                return false
            for a.entries |e|:
                ov := o.get(e.key) ?else:
                    return false
                if !e.value.eq(ov):
                    return false
            return true

--| Returns `Value.object` from `entries`.
fn object(entries [&]Entry) -> Value:
    var obj Object = {}
    for entries |e|:
        obj.set(e.key, e.value)
    return Value.object(obj)

--| Returns `Value.array` from `elems`.
fn array(elems [&]Value) -> Value:
    var arr []Value = {}
    arr = arr.append(elems)
    return Value.array(arr)

--| Parses a JSON text. Returns `error.Syntax` for malformed input and `error.Unicode` for input that is not UTF-8.
fn parse(src str) -> !Value:
    var diag Diag = {}
    return parse(src, &diag)

--| Parses a JSON text. On failure, `diag` tells where and why.
fn parse(src str, diag &Diag) -> !Value:
    if !str.is_utf8(src.span()):
        diag.msg = 'The input is not valid UTF-8.'
        return error.Unicode
    p := Parser{src=src}
    p.skip_ws()
    res := p.value() !else |err|:
        p.report(diag)
        return err
    p.skip_ws()
    if p.pos < src.len():
        p.msg = 'Expected the end of input after the value, found %{describe(src[p.pos])}.'
        p.report(diag)
        return error.Syntax
    return res

--| Returns compact JSON text. NaN and infinite floats become `null`.
fn stringify(v Value) -> str:
    w := Writer{indent=0}
    w.value(v, 0)
    return str(w.buf)

--| Returns JSON text with each nested element on its own line, indented by `indent` spaces.
--| `indent` 0 gives compact text.
fn stringify(v Value, indent int) -> str:
    w := Writer{indent=indent}
    w.value(v, 0)
    return str(w.buf)

--| Returns JSON text for a Cyber value, see `from`.
fn encode(x %T) -> str:
    return stringify(from(x))

--| Converts a Cyber value to a `Value`:
--| `bool`, integers, floats, `str`, `Value`, `Object`, slices, `Array`, `Map` with `str` keys (sorted by key),
--| structs (fields in declaration order), optionals (`none` becomes `null`), enums (the case name)
--| and choices (`"case"` without a payload, `{"case": payload}` with one).
--| Pass a borrow for a value that can not be copied, such as a `Map`: `json.from(&map)`.
fn from(x %T) -> Value:
    #switch type.info(T):
        #case .borrow:
            return from_ref(x)
        #else:
            return from_ref(&x)

-fn from_ref(x &%T) -> Value:
    #if T == Value:
        return x.*
    #else T == Object:
        return Value.object(x.*)
    #else T == bool:
        return Value.bool(x.*)
    #else T == str:
        return Value.str(x.*)
    #else T == float:
        return Value.float(x.*)
    #else T == f32:
        return Value.float(float(x.*))
    #else type.is_instance_of(T, Slice) or type.is_instance_of(T, Array):
        var arr []Value = {}
        for 0..x.len() |i|:
            arr = arr.append(from_ref(&x[i]))
        return Value.array(arr)
    #else type.is_instance_of(T, Map):
        keys := x.keys()
        keys.sort()
        var obj Object = {}
        for keys |k|:
            elem := x[k]
            obj.entries = obj.entries.append(Entry{key=k, value=from_ref(&elem)})
        return Value.object(obj)
    #else:
        #switch type.info(T):
            #case .int:
                return Value.int(int(x.*))
            #case .raw:
                return Value.int(int(x.*))
            #case .struct |info|:
                var obj Object = {}
                #for 0..info.fields.len() |i|:
                    #field := info.fields[i]
                    obj.entries = obj.entries.append(Entry{key=#{field.name}, value=from_ref(&meta.access(x, field.name))})
                return Value.object(obj)
            #case .option:
                if meta.is_none(x):
                    return Value.null
                payload := meta.access_option_payload(x.*)
                return from_ref(&payload)
            #case .enum:
                return Value.str(meta.enum_name(x.*))
            #case .choice:
                switch meta.choice_tag(x.*):
                    #for meta.enum_values(T.Tag) |Tag|:
                        case Tag:
                            #if meta.CasePayload[T, Tag] != void:
                                payload := meta.access_choice_case(x.*, Tag)
                                var obj Object = {}
                                obj.set(#{meta.enum_case(Tag).name}, from_ref(&payload))
                                return Value.object(obj)
                            #else:
                                return Value.str(#{meta.enum_case(Tag).name})
            #else:
                meta.error('`json.from` does not support `' + type.name(T) + '`.')

--| Formats a finite float in the shortest form that reads back as the same value.
--| `1e-6 <= |x| < 1e21` and 0 use plain decimals without a trailing `.0` (`1.5`, `100`, `-0` becomes `0`).
--| Other values use an exponent (`1e-7`, `1.5e+300`). NaN and infinities are not formatted, see `stringify`.
fn fmt_float(x float) -> str:
    if x == 0:
        return '0'
    a := x.abs()
    s := a.fmt()
    if a >= 1e-6 and a < 1e21:
        return if (x < 0) '-' + s else s
    var digits str = ''
    var exp int = 0
    if a >= 1:
        -- `s` is an integer: shortest digits padded with zeros.
        int_len := s.index('.') ?else s.len()
        digits = s[0..int_len].trimRight('0')
        exp = int_len - 1
    else:
        -- `s` is `0.000...ddd`.
        frac := s[2..]
        zeros := frac.len() - frac.trimLeft('0').len()
        digits = frac[zeros..].trimRight('0')
        exp = -(zeros + 1)
    var out str = if (x < 0) '-' else ''
    out += digits[0..1]
    if digits.len() > 1:
        out += '.' + digits[1..]
    out += if (exp < 0) 'e-%{-exp}' else 'e+%{exp}'
    return out

--| Returns whether `x` is neither NaN nor infinite.
fn is_finite(x float) -> bool:
    return x == x and x - x == 0

--| Parses a token that matches the JSON number grammar. Returns `none` for another token
--| or a number beyond the `float` range.
fn parse_number(text str) -> ?Value:
    p := Parser{src=text}
    v := p.number() !else:
        return none
    if p.pos != text.len():
        return none
    return v

--| Returns a readable name for a byte in an error message.
-fn describe(c byte) -> str:
    if c >= 0x20 and c < 0x7f:
        return '`' + str.initRune(int(c)) + '`'
    return 'byte 0x' + hex2(c)

--| Writes `s` as a quoted JSON string to `buf`.
-fn quote(buf &[]byte, s str):
    buf.* = buf.*.append(byte('"'))
    start := 0
    for 0..s.len() |i|:
        c := s[i]
        if c >= 0x20 and c != '"' and c != '\\':
            continue
        if i > start:
            buf.* = buf.*.append(s[start..i].span())
        start = i + 1
        switch c:
            case '"': buf.* = buf.*.append('\\"'.span())
            case '\\': buf.* = buf.*.append('\\\\'.span())
            case '\n': buf.* = buf.*.append('\\n'.span())
            case '\r': buf.* = buf.*.append('\\r'.span())
            case '\t': buf.* = buf.*.append('\\t'.span())
            case 0x08: buf.* = buf.*.append('\\b'.span())
            case 0x0c: buf.* = buf.*.append('\\f'.span())
            else: buf.* = buf.*.append(('\\u00' + hex2(c)).span())
    if s.len() > start:
        buf.* = buf.*.append(s[start..].span())
    buf.* = buf.*.append(byte('"'))

-fn hex2(c byte) -> str:
    digits := '0123456789abcdef'
    return digits[int(c) >> 4..(int(c) >> 4) + 1] + digits[int(c) && 15..(int(c) && 15) + 1]

-type Writer:
    buf    []byte = {}
    indent int

fn (&Writer) put(s str):
    self.buf = self.buf.append(s.span())

fn (&Writer) newline(depth int):
    self.buf = self.buf.append(byte('\n'))
    for 0..depth * self.indent:
        self.buf = self.buf.append(byte(' '))

fn (&Writer) value(v Value, depth int):
    switch v:
        case .null:
            self.put('null')
        case .bool |b|:
            self.put(if (b) 'true' else 'false')
        case .int |i|:
            self.put(i.fmt())
        case .float |f|:
            if is_finite(f):
                self.put(fmt_float(f))
            else:
                self.put('null')
        case .str |s|:
            quote(&self.buf, s)
        case .array |a|:
            if a.len() == 0:
                self.put('[]')
                return
            self.buf = self.buf.append(byte('['))
            for a |i, e|:
                if i > 0:
                    self.buf = self.buf.append(byte(','))
                if self.indent > 0:
                    self.newline(depth + 1)
                self.value(e, depth + 1)
            if self.indent > 0:
                self.newline(depth)
            self.buf = self.buf.append(byte(']'))
        case .object |o|:
            if o.len() == 0:
                self.put('{}')
                return
            self.buf = self.buf.append(byte('{'))
            for o.entries |i, e|:
                if i > 0:
                    self.buf = self.buf.append(byte(','))
                if self.indent > 0:
                    self.newline(depth + 1)
                quote(&self.buf, e.key)
                self.put(if (self.indent > 0) ': ' else ':')
                self.value(e.value, depth + 1)
            if self.indent > 0:
                self.newline(depth)
            self.buf = self.buf.append(byte('}'))

-type Parser:
    src   str
    pos   int = 0
    depth int = 0
    msg   str = ''

fn (&Parser) report(diag &Diag):
    diag.msg = self.msg
    diag.pos = self.pos
    line := 1
    line_start := 0
    for 0..self.pos |i|:
        if self.src[i] == '\n':
            line += 1
            line_start = i + 1
    diag.line = line
    diag.col = self.pos - line_start + 1

fn (&Parser) fail(msg str) -> error:
    self.msg = msg
    return error.Syntax

fn (&Parser) peek() -> byte:
    if self.pos < self.src.len():
        return self.src[self.pos]
    return 0

fn (&Parser) found() -> str:
    if self.pos < self.src.len():
        return describe(self.src[self.pos])
    return 'the end of input'

fn (&Parser) skip_ws():
    while self.pos < self.src.len():
        c := self.src[self.pos]
        if c == ' ' or c == '\n' or c == '\r' or c == '\t':
            self.pos += 1
        else:
            return

fn (&Parser) value() -> !Value:
    switch self.peek():
        case '{':
            return self.object()
        case '[':
            return self.array()
        case '"':
            return Value.str(self.string()!)
        case 't':
            self.word('true')!
            return Value.bool(true)
        case 'f':
            self.word('false')!
            return Value.bool(false)
        case 'n':
            self.word('null')!
            return Value.null
        else:
            c := self.peek()
            if c == '-' or (c >= '0' and c <= '9'):
                return self.number()
            return self.fail('Expected a value, found %{self.found()}.')

fn (&Parser) word(w str) -> !void:
    if self.src[self.pos..].starts_with(w):
        self.pos += w.len()
        return
    return self.fail('Expected a value, found %{self.found()}.')

fn (&Parser) enter() -> !void:
    self.depth += 1
    if self.depth > MaxDepth:
        return self.fail('Arrays and objects nest deeper than %{MaxDepth} levels.')

fn (&Parser) array() -> !Value:
    self.enter()!
    self.pos += 1
    var arr []Value = {}
    self.skip_ws()
    if self.peek() == ']':
        self.pos += 1
        self.depth -= 1
        return Value.array(arr)
    while:
        self.skip_ws()
        arr = arr.append(self.value()!)
        self.skip_ws()
        c := self.peek()
        if c == ',':
            self.pos += 1
        else c == ']':
            self.pos += 1
            self.depth -= 1
            return Value.array(arr)
        else:
            return self.fail('Expected `,` or `]` in an array, found %{self.found()}.')

fn (&Parser) object() -> !Value:
    self.enter()!
    self.pos += 1
    var obj Object = {}
    -- Finds duplicate keys once the object is too large for a linear search.
    var index Map[str, int] = {}
    self.skip_ws()
    if self.peek() == '}':
        self.pos += 1
        self.depth -= 1
        return Value.object(obj)
    while:
        self.skip_ws()
        if self.peek() != '"':
            return self.fail('Expected a string key in an object, found %{self.found()}.')
        key := self.string()!
        self.skip_ws()
        if self.peek() != ':':
            return self.fail('Expected `:` after an object key, found %{self.found()}.')
        self.pos += 1
        self.skip_ws()
        val := self.value()!
        -- A duplicate key keeps its first position and takes the last value.
        n := obj.entries.len()
        if n < 16:
            obj.set(key, val)
        else:
            if n == 16 and index.size() == 0:
                for obj.entries |i, e|:
                    index[e.key] = i
            if index.get(key) |i|:
                obj.entries[i].value = val
            else:
                index[key] = n
                obj.entries = obj.entries.append(Entry{key=key, value=val})
        self.skip_ws()
        c := self.peek()
        if c == ',':
            self.pos += 1
        else c == '}':
            self.pos += 1
            self.depth -= 1
            return Value.object(obj)
        else:
            return self.fail('Expected `,` or `}` in an object, found %{self.found()}.')

-fn hex_val(c byte) -> int:
    if c >= '0' and c <= '9':
        return int(c - '0')
    if c >= 'a' and c <= 'f':
        return int(c - 'a') + 10
    if c >= 'A' and c <= 'F':
        return int(c - 'A') + 10
    return -1

fn (&Parser) hex4() -> !int:
    if self.pos + 4 > self.src.len():
        return self.fail('Expected four hex digits after `\\u`.')
    res := 0
    for 0..4 |i|:
        d := hex_val(self.src[self.pos + i])
        if d < 0:
            self.pos += i
            return self.fail('Expected four hex digits after `\\u`, found %{self.found()}.')
        res = res * 16 + d
    self.pos += 4
    return res

--| Parses a string at the opening quote.
fn (&Parser) string() -> !str:
    self.pos += 1
    start := self.pos
    src := self.src
    n := src.len()
    -- Fast path: no escapes.
    while self.pos < n:
        c := src[self.pos]
        if c == '"':
            res := src[start..self.pos]
            self.pos += 1
            return res
        if c == '\\':
            break
        if c < 0x20:
            return self.fail('A string can not contain %{describe(c)}, escape it.')
        self.pos += 1
    var buf []byte = {}
    buf = buf.append(src[start..self.pos].span())
    while self.pos < n:
        c := src[self.pos]
        if c == '"':
            self.pos += 1
            return str(buf)
        if c < 0x20:
            return self.fail('A string can not contain %{describe(c)}, escape it.')
        if c != '\\':
            buf = buf.append(c)
            self.pos += 1
            continue
        self.pos += 1
        switch self.peek():
            case '"': buf = buf.append(byte('"'))
            case '\\': buf = buf.append(byte('\\'))
            case '/': buf = buf.append(byte('/'))
            case 'b': buf = buf.append(byte(0x08))
            case 'f': buf = buf.append(byte(0x0c))
            case 'n': buf = buf.append(byte('\n'))
            case 'r': buf = buf.append(byte('\r'))
            case 't': buf = buf.append(byte('\t'))
            case 'u':
                self.pos += 1
                cp := self.hex4()!
                if cp >= 0xdc00 and cp <= 0xdfff:
                    self.pos -= 6
                    return self.fail('`\\u%{cp.fmt(.hex)}` is a low surrogate without a high surrogate before it.')
                if cp >= 0xd800 and cp <= 0xdbff:
                    if !src[self.pos..].starts_with('\\u'):
                        self.pos -= 6
                        return self.fail('`\\u%{cp.fmt(.hex)}` is a high surrogate without a low surrogate after it.')
                    self.pos += 2
                    lo := self.hex4()!
                    if lo < 0xdc00 or lo > 0xdfff:
                        self.pos -= 6
                        return self.fail('`\\u%{lo.fmt(.hex)}` does not complete the surrogate pair.')
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00)
                buf = buf.append(str.initRune(cp).span())
                continue
            else:
                return self.fail('Unknown escape `\\%{str.initRune(int(self.peek()))}`.')
        self.pos += 1
    return self.fail('Expected `"` to end the string, found the end of input.')

fn (&Parser) digits() -> int:
    start := self.pos
    while self.pos < self.src.len():
        c := self.src[self.pos]
        if c < '0' or c > '9':
            break
        self.pos += 1
    return self.pos - start

fn (&Parser) number() -> !Value:
    start := self.pos
    if self.peek() == '-':
        self.pos += 1
    int_start := self.pos
    nd := self.digits()
    if nd == 0:
        return self.fail('Expected a digit, found %{self.found()}.')
    if nd > 1 and self.src[int_start] == '0':
        self.pos = int_start
        return self.fail('A number can not have a leading zero.')
    is_int := true
    if self.peek() == '.':
        self.pos += 1
        if self.digits() == 0:
            return self.fail('Expected a digit after `.`, found %{self.found()}.')
        is_int = false
    if self.peek() == 'e' or self.peek() == 'E':
        self.pos += 1
        if self.peek() == '+' or self.peek() == '-':
            self.pos += 1
        if self.digits() == 0:
            return self.fail('Expected a digit in the exponent, found %{self.found()}.')
        is_int = false
    text := self.src[start..self.pos]
    if is_int:
        if parse_int(text) |i|:
            return Value.int(i)
    f := float(text)
    if !is_finite(f):
        self.pos = start
        return self.fail('The number `%{text}` is out of range.')
    return Value.float(f)

--| Parses `-?[0-9]+` as an `int`, or returns `none` when it does not fit.
-fn parse_int(s str) -> ?int:
    neg := s[0] == '-'
    start := if (neg) 1 else 0
    -- Accumulates as a negative number so that the minimum `int` fits.
    res := 0
    for start..s.len() |i|:
        d := int(s[i] - '0')
        if res < (-9223372036854775807 - 1 + d) / 10:
            return none
        res = res * 10 - d
    if neg:
        return res
    if res == -9223372036854775807 - 1:
        return none
    pos := -res
    return pos
