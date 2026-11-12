-- A source formatter for Cyber, written in Cyber.
--
-- Usage:
--     cyber examples/fmt.cy <file.cy>           Print the formatted source.
--     cyber examples/fmt.cy --check <file.cy>   Print nothing, exit with 1 if the file would change.
--
-- This is an example program. Use the built-in `cyber fmt` for real work, it applies the same style but
-- reads block structure and operators from the syntax tree. This script only looks at tokens:
--
--   * Blocks are detected from the original indentation.
--   * Binary and unary operators are told apart by the token before them.
--   * Where that is ambiguous (`a *T`, `if (a) -b else b`), the spacing is kept as written.
--
-- Like `cyber fmt`, it never joins or splits lines and never touches the inside of a string literal.
-- The pipeline is: tokenize -> classify operators -> indent lines -> emit -> verify.

use cy
use os

const indent_width = 4

fn main():
    check := false
    path := ''
    for os.args()[1..] |arg|:
        if arg == '--check':
            check = true
        else path == '' and !arg.starts_with('-'):
            path = arg
        else:
            path = ''
            break
    if path == '':
        eprint('Usage: cyber examples/fmt.cy [--check] <file.cy>')
        os.exit(2)

    src := os.read_file_str(path) !else |err|:
        eprint('error: can not read `%{path}`: %{err}')
        os.exit(1)

    -- Refuse to format source that does not parse. On a syntax error `cy.parse` prints the error and
    -- returns a result without a root.
    if cy.parse(src).root == none:
        eprint('error: can not parse `%{path}`.')
        os.exit(1)

    f := Formatter(src)
    f.tokenize()
    f.classify()
    f.indent()
    out := f.emit()

    -- The output must hold the same tokens as the input.
    check_f := Formatter(out)
    check_f.tokenize()
    if !same_tokens(f.tokens, check_f.tokens):
        eprint('error: formatting `%{path}` would change its tokens. This is a bug in fmt.cy.')
        os.exit(3)

    if !check:
        os.stdout().write_all(out) !else |err|:
            eprint('error: can not write to stdout: %{err}')
            os.exit(1)
    else out != src:
        eprint('%{path} is not formatted.')
        os.exit(1)

type Kind enum:
    -- Identifier, keyword or number.
    case word
    -- Any string literal. A template is one token, including its `%{}` expressions.
    case string
    case comment
    -- `(`, `[` or `{`
    case open
    -- `)`, `]` or `}`
    case close
    case comma
    case colon
    -- Any other operator or punctuation.
    case op

type Mark enum:
    case none
    case binary
    case unary
    -- The operator of an op assignment such as `+` in `+=`.
    case assign_op
    -- A binary operator inside a range bound. Its spacing is kept as written.
    case keep

type Token:
    kind Kind
    text str

    -- First token on its source line.
    line_start bool = false

    -- At least one blank line precedes this line. Only for `line_start`.
    blank_before bool = false

    -- Number of whitespace bytes between this token and the previous one on the same line.
    gap int = 0

    -- Index into `Formatter.lines`.
    line int = 0

    mark Mark = .none

    -- Inside brackets that were opened by the statement this token belongs to.
    in_brackets bool = false

type Line:
    -- Index of the first token.
    head int

    -- Width of the original indentation. A tab counts as `indent_width`.
    width int

    is_comment bool
    new_width int = 0

    -- Continues the statement of a line above.
    is_cont bool = false

-- A block of statements that is open at the current line.
type Block:
    -- Original and new indentation of its statements.
    width int
    new_width int

    -- Number of open brackets around the block. Not 0 for the body of a lambda inside a call.
    depth int

    -- The statement and its bracket depth to return to when the block ends.
    outer_stmt int
    outer_base int

type Formatter:
    src str
    tokens []Token
    lines []Line

    -- Bytes before the first token: UTF-8 BOM and shebang line.
    prefix str

fn Formatter :: @init(src str) -> Formatter:
    return {src = src, tokens = {}, lines = {}, prefix = ''}

-- ---------------------------------------------------------------------------------------------------------
-- Tokenizer.
-- ---------------------------------------------------------------------------------------------------------

-- Splits the source into tokens and lines.
fn (&Formatter) tokenize():
    src := self.src
    pos := prefix_end(src)
    self.prefix = src[0..pos]

    while true:
        -- Skip whitespace.
        ws_start := pos
        newlines := 0
        while pos < src.len():
            ch := src[pos]
            if ch == '\n':
                newlines += 1
            else ch != ' ' and ch != '\t' and ch != '\r':
                break
            pos += 1
        if pos == src.len():
            break

        start := pos
        ch := src[pos]
        kind := Kind.op
        pos += 1
        switch ch:
            case '(', '[', '{': kind = .open
            case ')', ']', '}': kind = .close
            case ',': kind = .comma
            case '\'', '"':
                kind = .string
                pos = scan_string(src, start)
            case '`':
                kind = .string
                pos = scan_raw_string(src, start)
            else:
                if is_word_char(ch) or ch == '@':
                    kind = .word
                    pos = scan_word(src, start)
                else is_at(src, start, '--'):
                    kind = .comment
                    pos = line_end(src, start)
                else:
                    pos = scan_op(src, start)
                    if ch == ':' and pos == start + 1:
                        kind = .colon

        end := pos
        if kind == .comment:
            -- Drop trailing whitespace, including the `\r` of a CRLF line end.
            while is_space(src[end - 1]):
                end -= 1

        token := Token{kind = kind, text = src[start..end]}
        if self.tokens.len() == 0 or newlines > 0:
            token.line_start = true
            if self.tokens.len() > 0:
                token.blank_before = newlines > 1
            else:
                -- The shebang line of the prefix ends with its own line break, so one more is a blank line.
                token.blank_before = self.prefix.ends_with('\n') and newlines > 0
            self.lines += Line{
                head = self.tokens.len(),
                width = indent_of(src, start),
                is_comment = kind == .comment,
            }
        else:
            token.gap = start - ws_start
        token.line = self.lines.len() - 1
        self.tokens += token

-- End of the bytes that are skipped before the first token.
fn prefix_end(src str) -> int:
    pos := 0
    if is_at(src, 0, '\xEF\xBB\xBF'):
        pos = 3
    if is_at(src, pos, '#!'):
        pos = line_end(src, pos)
        if pos < src.len():
            pos += 1
    return pos

fn is_at(src str, pos int, s str) -> bool:
    return pos + s.len() <= src.len() and src[pos..pos + s.len()] == s

-- Position of the next `\n` or the end of the source.
fn line_end(src str, pos int) -> int:
    end := pos
    while end < src.len() and src[end] != '\n':
        end += 1
    return end

fn is_space(ch byte) -> bool:
    return ch == ' ' or ch == '\t' or ch == '\r'

fn is_digit(ch byte) -> bool:
    return ch >= '0' and ch <= '9'

fn is_word_char(ch byte) -> bool:
    switch ch:
        case '0'..'9', 'A'..'Z', 'a'..'z', '_': return true
        else: return ch >= 0x80

-- Width of the indentation in front of `pos`.
fn indent_of(src str, pos int) -> int:
    width := 0
    i := pos
    while i > 0:
        i -= 1
        if src[i] == ' ':
            width += 1
        else src[i] == '\t':
            width += indent_width
        else:
            break
    return width

-- Returns the end of an identifier, keyword, `@name` or number.
fn scan_word(src str, start int) -> int:
    pos := start + 1
    while pos < src.len() and is_word_char(src[pos]):
        pos += 1
    if !is_digit(src[start]) or is_at(src, start, '0x'):
        return pos

    -- A number can have a fraction and a negative exponent: `1.5`, `2e-3`, `1_000.5`.
    if pos + 1 < src.len() and src[pos] == '.' and is_digit(src[pos + 1]):
        pos += 2
        while pos < src.len() and is_word_char(src[pos]):
            pos += 1
    if pos + 1 < src.len() and src[pos - 1] == 'e' and src[pos] == '-' and is_digit(src[pos + 1]):
        pos += 2
        while pos < src.len() and is_word_char(src[pos]):
            pos += 1
    return pos

-- Returns the end of the operator that starts at `start`. Takes the longest match like the compiler.
fn scan_op(src str, start int) -> int:
    if is_at(src, start, '..>='):
        return start + 4
    if is_at(src, start, '..=') or is_at(src, start, '..>'):
        return start + 3
    if start + 2 <= src.len():
        switch src[start..start + 2]:
            case '..', '.!', '.?', '.*', ':=', '::', '->', '=>', '==', '!=', '<=', '>=', '<>':
                return start + 2
            case '&&', '||', '**', '<<', '>>':
                return start + 2
            else:
                pass
    return start + 1

-- Returns the end of the raw string that starts at the backtick at `start`.
fn scan_raw_string(src str, start int) -> int:
    delim := if (is_at(src, start, '```')) '```' else '`'
    pos := start + delim.len()
    while pos < src.len() and !is_at(src, pos, delim):
        pos += 1
    return pos + delim.len()

-- Returns the end of the string literal that starts at the quote at `start`.
-- The expressions of a template are skipped, they are emitted as written.
fn scan_string(src str, start int) -> int:
    quote := src[start]
    delim := src[start..start + 1]
    if is_at(src, start, delim ** 3):
        delim = delim ** 3
    pos := start + delim.len()
    while pos < src.len():
        ch := src[pos]
        if ch == '\\':
            pos += 2
        else ch == quote and is_at(src, pos, delim):
            return pos + delim.len()
        else is_at(src, pos, `%{`):
            pos = scan_template_expr(src, pos + 2)
        else:
            pos += 1
    return pos

-- Returns the position after the `}` that ends a template expression.
fn scan_template_expr(src str, start int) -> int:
    pos := start
    open_braces := 0
    while pos < src.len():
        ch := src[pos]
        switch ch:
            case '\'', '"': pos = scan_string(src, pos)
            case '`': pos = scan_raw_string(src, pos)
            case '{':
                open_braces += 1
                pos += 1
            case '}':
                pos += 1
                if open_braces == 0:
                    return pos
                open_braces -= 1
            else:
                if is_at(src, pos, '--'):
                    pos = line_end(src, pos)
                else:
                    pos += 1
    return pos

fn same_tokens(a []Token, b []Token) -> bool:
    if a.len() != b.len():
        return false
    for 0..a.len() |i|:
        if a[i].text != b[i].text:
            return false
    return true

-- ---------------------------------------------------------------------------------------------------------
-- Operators.
-- ---------------------------------------------------------------------------------------------------------

-- Keywords that are followed by an expression or a type. An operator after one of them is not binary.
fn is_prefix_keyword(word str) -> bool:
    switch word:
        case 'and', 'or', 'not', 'if', 'else', 'while', 'for', 'switch', 'case', 'return': return true
        case 'as', 'try', 'move', 'yield', 'with', 'use', 'var', 'const', 'global', 'type': return true
        case 'fn', 'scope', 'sink': return true
        else: return false

-- Decides for each operator whether it is binary, unary or part of an op assignment.
fn (&Formatter) classify():
    -- For each open bracket, whether its closing bracket ends an operand.
    -- It does not for a type such as `[]int`: `[]*int`.
    operands := []bool{}

    -- For each open bracket, whether it holds the condition of an `if`: `if (a) -b else b`.
    conds := []bool{}

    -- Whether the previous token ends an operand.
    after_operand := false
    after_cond := false
    prev_text := ''

    for 0..self.tokens.len() |i|:
        t := self.tokens[i]
        if t.kind == .comment:
            continue
        if t.line_start and operands.len() == 0:
            -- A new statement.
            after_operand = false

        operand := false
        cond := false
        switch t.kind:
            case .word:
                operand = !is_prefix_keyword(t.text)
                if t.text == 'and' or t.text == 'or':
                    self.tokens[i].mark = .binary
            case .string:
                operand = true
            case .open:
                operands += t.text != '[' or (after_operand and t.gap == 0 and !t.line_start)
                conds += t.text == '(' and prev_text == 'if'
            case .close:
                operand = true
                if operands.len() > 0:
                    operand = operands.last()
                    cond = conds.last()
                    operands = operands.size_down(operands.len() - 1)
                    conds = conds.size_down(conds.len() - 1)
            case .op:
                self.tokens[i].mark = self.op_mark(i, after_operand, after_cond)

                -- Postfix operators. `!` is also a type prefix: `res !int`.
                postfix_bang := t.text == '!' and after_operand and t.gap == 0
                operand = t.text == '.?' or t.text == '.!' or t.text == '.*' or postfix_bang
            else:
                pass
        after_operand = operand
        after_cond = cond
        prev_text = t.text

    for 0..self.tokens.len() |i|:
        if self.tokens[i].kind == .op and self.tokens[i].text.starts_with('..'):
            self.keep_range_bound(i, -1)
            self.keep_range_bound(i, 1)

-- `after_cond` is set when the operator follows the condition of an `if`. It is then binary in an `if`
-- statement and unary in an `if` expression.
fn (&Formatter) op_mark(i int, after_operand bool, after_cond bool) -> Mark:
    t := self.tokens[i]
    switch t.text:
        case '==', '!=', '<=', '>=':
            return .binary
        case '!':
            return if (after_operand) .none else .unary
        case '+', '-', '*', '/', '%', '**', '<', '>', '<<', '>>', '&&', '||', '~':
            pass
        else:
            return .none

    if !after_operand:
        return if (t.text == '-' or t.text == '~') .unary else .none

    if i + 1 < self.tokens.len():
        next := self.tokens[i + 1]
        if !next.line_start and next.kind != .comment:
            if next.text == '=' and next.gap == 0:
                return .assign_op
            if (after_cond or is_type_prefix(t.text)) and !t.line_start and (t.gap > 0) != (next.gap > 0):
                -- Looks like a prefix: `a *T`, `if (a) -b else b`.
                return .none
    return .binary

-- Operators that also start a type: `a *T`, `a &&T`, `a %T`.
fn is_type_prefix(op str) -> bool:
    return op == '*' or op == '&&' or op == '%'

-- The spacing of `0..n-1` is kept. `0..n - 1` would read as if the range bound tighter.
-- Walks from the range operator to the start (`step` is -1) or the end (`step` is 1) of the bound.
fn (&Formatter) keep_range_bound(range int, step int):
    enter := if (step > 0) Kind.open else Kind.close
    depth := 0
    i := range
    while true:
        if step < 0 and self.tokens[i].line_start:
            break
        i += step
        if i == self.tokens.len():
            break
        t := self.tokens[i]
        if step > 0 and t.line_start:
            break

        if t.kind == enter:
            depth += 1
        else t.kind == .open or t.kind == .close:
            if depth == 0:
                break
            depth -= 1
        else depth == 0:
            if ends_range_bound(t):
                break
            if t.mark == .binary:
                self.tokens[i].mark = .keep

fn ends_range_bound(t Token) -> bool:
    switch t.kind:
        case .comma, .colon, .comment:
            return true
        case .word:
            return is_prefix_keyword(t.text) and t.text != 'and' and t.text != 'or' and t.text != 'not'
        else:
            return t.text == '=' or t.text == ':=' or t.text == '|' or t.text == '=>' or t.text == '->'

-- ---------------------------------------------------------------------------------------------------------
-- Indentation.
-- ---------------------------------------------------------------------------------------------------------

-- Whether a statement continues on the next line when this is the last token of a line.
fn continues_line(t Token) -> bool:
    switch t.text:
        case ',', 'and', 'or', 'not': return true
        case '=', ':=', '=>', '+', '-', '*', '/', '%', '**', '<', '>', '<<', '>>', '&&', '||', '~': return true
        case '==', '!=', '<=', '>=': return true

        -- A block `else` ends with a colon. This one is the `else` of an expression: `a ?else`.
        case 'else': return true
        else: return false

-- Computes the new indentation of each line.
fn (&Formatter) indent():
    blocks := []Block{}

    -- The line of each open bracket.
    open := []int{}

    -- The line that starts the current statement and the number of open brackets in front of it.
    stmt := 0
    base := 0

    -- The previous code line and its last token.
    prev := -1
    prev_last := 0

    for 0..self.lines.len() |i|:
        line := self.lines[i]
        if line.is_comment:
            continue

        depth := open.len()
        closes := depth > 0 and self.tokens[line.head].kind == .close
        new_width := 0
        is_cont := false

        if in_block(blocks, depth) and prev >= 0 and continues_line(self.tokens[prev_last]):
            -- For example the right side of a binary operator. Keep it as written.
            is_cont = true
            new_width = self.lines[stmt].new_width
            if line.width > self.lines[stmt].width:
                new_width += line.width - self.lines[stmt].width
        else:
            -- Leave the blocks that end before this line.
            ended := -1
            ended_new := -1
            while blocks.len() > 0:
                b := blocks.last()
                if b.depth != depth or (!closes and b.width <= line.width):
                    break
                if ended_new == -1:
                    ended = b.width
                    ended_new = b.new_width
                stmt = b.outer_stmt
                base = b.outer_base
                blocks = blocks.size_down(blocks.len() - 1)

            block := Block{width = line.width, new_width = 0, depth = depth, outer_stmt = stmt, outer_base = base}
            if in_block(blocks, depth):
                if blocks.len() == 0:
                    -- The first top level statement.
                    blocks += block
                else line.width > blocks.last().width:
                    -- Indented deeper than the statement above. This opens a block.
                    block.new_width = blocks.last().new_width + indent_width
                    blocks += block
                new_width = blocks.last().new_width
            else !closes and ended == -1 and self.opens_block(prev, prev_last, line.width):
                -- The body of a lambda that is declared inside brackets.
                block.new_width = self.lines[prev].new_width + indent_width
                blocks += block
                new_width = block.new_width
            else:
                -- Inside brackets. A closing bracket lines up with the line that opened it.
                is_cont = true
                new_width = self.lines[open.last()].new_width
                if !closes:
                    new_width += indent_width

                -- After the body of a lambda, this line must not look like one more of its statements.
                if new_width == ended_new:
                    if line.width >= ended:
                        new_width += indent_width
                    else new_width >= indent_width:
                        new_width -= indent_width

        if !is_cont:
            stmt = i
            base = depth
        self.lines[i].new_width = new_width
        self.lines[i].is_cont = is_cont

        -- Track the brackets on this line.
        end := if (i + 1 < self.lines.len()) self.lines[i + 1].head else self.tokens.len()
        for line.head..end |j|:
            t := self.tokens[j]
            if t.kind == .comment:
                continue
            self.tokens[j].in_brackets = open.len() > base
            if t.kind == .open:
                open += i
            else t.kind == .close and open.len() > 0:
                open = open.size_down(open.len() - 1)

                -- The bracket also ends the blocks inside it.
                while blocks.len() > 0 and blocks.last().depth > open.len():
                    stmt = blocks.last().outer_stmt
                    base = blocks.last().outer_base
                    blocks = blocks.size_down(blocks.len() - 1)
            prev_last = j
        prev = i

    -- Comment lines follow the code around them.
    for 0..self.lines.len() |i|:
        if self.lines[i].is_comment:
            self.lines[i].new_width = self.comment_indent(i)

-- Whether a line with this indentation starts the body of a lambda that the line `prev` declares.
fn (&Formatter) opens_block(prev int, prev_last int, width int) -> bool:
    return self.tokens[prev_last].kind == .colon and width > self.lines[prev].width

-- Whether a line at this bracket depth is a statement of a block and not a continuation inside brackets.
fn in_block(blocks []Block, depth int) -> bool:
    return depth == 0 or (blocks.len() > 0 and blocks.last().depth == depth)

fn (&Formatter) comment_indent(idx int) -> int:
    width := self.lines[idx].width

    -- The next code line.
    next := idx + 1
    while next < self.lines.len() and self.lines[next].is_comment:
        next += 1
    if next < self.lines.len() and self.lines[next].width == width:
        return self.lines[next].new_width

    -- Closest code line above with the same indentation, unless a shallower statement is in between.
    prev := -1
    for idx - 1..>=0 |i|:
        line := self.lines[i]
        if line.is_comment:
            continue
        if prev == -1:
            prev = i
        if line.width == width:
            return line.new_width
        if line.width < width and !line.is_cont:
            break

    -- Keep the distance to the closest code line.
    near := if (next < self.lines.len()) next else prev
    if near == -1:
        return width
    if width > self.lines[near].width:
        return self.lines[near].new_width + width - self.lines[near].width
    return self.lines[near].new_width

-- ---------------------------------------------------------------------------------------------------------
-- Spacing and output.
-- ---------------------------------------------------------------------------------------------------------

fn (&Formatter) emit() -> str:
    -- The output is built as bytes. Appending to a `str` copies it each time.
    out := []byte{}
    -- Byte order mark and shebang line, copied as they are.
    out += self.prefix.span()

    for 0..self.tokens.len() |i|:
        t := self.tokens[i]
        if !t.line_start:
            out = append_spaces(out, self.spacing(i))
        else:
            if i > 0:
                out += '\n'
                if t.blank_before:
                    out += '\n'
            else t.blank_before:
                -- A blank line after the shebang line.
                out += '\n'
            out = append_spaces(out, self.lines[t.line].new_width)
        out += t.text.span()
    if self.tokens.len() > 0:
        out += '\n'
    return str(out)

fn append_spaces(out []byte, n int) -> []byte:
    if n == 1:
        return out + ' '
    return out + (' ' ** n).span()

-- Number of spaces between the token `i` and the token before it on the same line.
fn (&Formatter) spacing(i int) -> int:
    a := self.tokens[i - 1]
    b := self.tokens[i]
    keep := if (b.gap > 0) 1 else 0

    if b.kind == .comment:
        -- Keep the column of a trailing comment, they are often aligned by hand.
        return if (b.gap > 1) b.gap else 1

    want := keep
    if b.text == '[' and !starts_term(a):
        -- After an operand, whitespace before `[` decides between indexing and a new term.
        return keep
    else a.kind == .open or b.kind == .close or b.kind == .comma:
        want = 0
    else a.kind == .comma:
        want = 1
    else a.mark == .assign_op:
        -- `+=`
        want = 0
    else b.mark == .assign_op:
        want = 1
    else a.text == '=' and !a.line_start and self.tokens[i - 2].mark == .assign_op:
        want = 1
    else b.kind == .colon:
        want = 0
    else a.kind == .colon:
        want = 1
    else a.mark == .binary or b.mark == .binary:
        want = 1
    else a.mark == .unary:
        want = 0
    else is_spaced_op(a) or is_spaced_op(b):
        want = 1
    else (a.text == '=' and !a.in_brackets) or (b.text == '=' and !b.in_brackets):
        want = 1

    if want == 0 and keep == 1 and !can_join(a, b):
        return 1
    return want

-- Whether the token is followed by the start of a new term, never by a postfix operator.
fn starts_term(t Token) -> bool:
    return t.kind == .open or t.kind == .comma or t.kind == .colon or t.text == '=' or is_spaced_op(t) or
        t.mark == .binary

-- Operators that always take a space on both sides.
fn is_spaced_op(t Token) -> bool:
    return t.text == ':=' or t.text == '->' or t.text == '=>'

-- Whether removing the space between two tokens keeps them apart. `- -x` must not turn into a comment.
fn can_join(a Token, b Token) -> bool:
    left := a.text.last()
    right := b.text[0]
    if is_word_char(left) and is_word_char(right):
        return false
    if is_operator_char(left) and is_operator_char(right):
        return false

    -- `1 .5` and `1. 5`
    if (left == '.' and is_word_char(right)) or (is_word_char(left) and right == '.'):
        return false
    return true

fn is_operator_char(ch byte) -> bool:
    switch ch:
        case '-', '+', '*', '/', '<', '>', '=', '!', '.', ':', '&', '|', '%', '^', '~', '?', '@', '#': return true
        else: return false
