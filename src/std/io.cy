--| SIMD accelerated.
#[bind] fn index_newline(buf [&]byte) -> ?int

type Reader trait:
    fn read(bytes [&]byte) -> !int

fn Reader :: @init(s str) -> StrReader:
    return {
        val = s
    }

type Scanner[T Reader]:
    reader &T
    buf []byte
    cur int = 0
    end int = 0
    -- The reader returned 0 bytes: the input ended.
    eof bool = false

const Scanner :: DefaultBufferSize = 8192

fn Scanner :: @init(scope reader &%T) -> scope Scanner[T]:
    return Scanner(reader, Scanner.DefaultBufferSize)

fn Scanner :: @init(scope reader &%T, buf_size int) -> scope Scanner[T]:
    return {
        reader = reader,
        buf = []byte(buf_size, 0),
        cur = 0,
        end = 0,
    }

-- Reads into the free part of the buffer once. A reader returns 0 at the end of its input.
-fn (&Scanner[]) read_more() -> !void:
    n := self.reader.read(self.buf.span()[self.end..]) !else |err|:
        if err == error.EndOfFile:
            self.eof = true
            return
        return err
    if n == 0:
        self.eof = true
    self.end += n

type ScannerNextFn = fn([&]byte) -> !?NextRange

type NextRange:
    start int
    end   int
    advance_end int

--| Returns the next piece that `next_fn` finds in the buffered input, reading more while it finds none. `next_fn`
--| returns `none` to ask for more. At the end of the input, the rest is the last piece, and `none` follows.
fn (&Scanner[]) next(next_fn ScannerNextFn) -> !?[]byte:
    var res []byte = {}
    while:
        if self.cur < self.end:
            if next_fn(self.buf.span()[self.cur..self.end])! |range|:
                slice := self.buf[self.cur+range.start..self.cur+range.end]
                self.cur += range.advance_end
                if res.len() > 0:
                    return res + slice
                return slice
            -- Keep the partial piece and read more.
            res += self.buf[self.cur..self.end]
            self.cur = self.end
        if self.eof:
            if res.len() > 0:
                return res
            return none
        self.cur = 0
        self.end = 0
        self.read_more()!

--| Returns the next line without its line break (`\n`, `\r\n` or `\r`). The last line can be without one.
--| Returns `none` at the end of the input.
fn (&Scanner[]) next_line() -> !?[]byte:
    next := fn(span [&]byte) -> !?NextRange:
        idx := index_newline(span) ?else:
            return none
        advance_end := idx + 1
        if span[idx] == '\r':
            if idx + 1 == span.length:
                -- A `\n` can follow in the next read.
                return none
            if span[idx + 1] == '\n':
                advance_end += 1
        return NextRange{start=0, end=idx, advance_end=advance_end}
    line := self.next(next)! ?else:
        return none
    -- The input ended right after a `\r`.
    if line.len() > 0 and line[line.len() - 1] == '\r':
        return line[0..line.len() - 1]
    return line

type Writer trait:
    fn write(bytes [&]byte) -> !int

-- TODO: Wrapper for AsSpan types.
type SpanReader

type StrReader:
    with Reader
    val str
    idx int = 0

fn (&StrReader) read(buf [&]byte) -> !int:
    vlen := self.val.len()
    if self.idx == vlen:
        return error.EndOfFile

    local := self.val
    rest := local.span()[self.idx..]
    if rest.length < buf.length:
        buf[0..rest.length].set(rest)
        self.idx = vlen
        return rest.length
    else:
        buf.set(rest[0..buf.len()])
        self.idx += buf.len()
        return buf.len()
