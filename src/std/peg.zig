//! The matcher of the `peg` module: a parsing machine, as in LPeg, over the program that `peg.cy` compiles.
//! It backtracks with one explicit stack and does not recurse on the host stack.
//! The layout of the program is described in `peg.cy` ("Program layout") and must match the constants below.
const std = @import("std");
const cy = @import("../cyber.zig");
const C = @import("../capi.zig");
const regex = @import("regex.zig");

const Src = @embedFile("peg.cy");

comptime {
    @export(&bind, .{ .name = "cl_mod_bind_peg", .linkage = .strong });
}

pub fn bind(_: *C.VM, mod: *C.Sym) callconv(.c) C.Bytes {
    cy.core.markBuiltinModule(mod);
    for (funcs) |e| {
        C.mod_add_func(mod, e.@"0", e.@"1");
    }
    return C.to_bytes(Src);
}

const zErrFunc = cy.core.zErrFunc;

const funcs = [_]struct { []const u8, C.BindFunc }{
    .{ "exec", zErrFunc(exec) },
    .{ "unit_len", zErrFunc(unitLen) },
};

// Header words.
const H_MAGIC = 0;
const H_NINST = 1;
const H_INST_OFF = 2;
const H_LEN = 8;

const Magic: i64 = 0x5045_0001;

/// Words per instruction: `op, a, b`.
const InstLen = 3;

const Op = enum(i64) {
    end = 0,
    any = 1,
    str = 2,
    set = 3,
    span = 4,
    choice = 5,
    commit = 6,
    partial_commit = 7,
    back_commit = 8,
    fail = 9,
    fail_twice = 10,
    call = 11,
    ret = 12,
    jmp = 13,
    open = 14,
    close = 15,
    backref = 16,
    str_fold = 17,
};

// Set words: `ascii_lo, ascii_hi, negated, nranges`, then `nranges` pairs `lo, hi`.
const S_ASCII_LO = 0;
const S_ASCII_HI = 1;
const S_NEG = 2;
const S_NRANGES = 3;
const S_RANGES = 4;

/// The named capture kind in the log. 0 closes a capture.
const CapNamed: i64 = 2;
/// Words per entry of the capture log: `kind, aux, position`.
const CapLen = 3;

const MODE_SEARCH: i64 = 1;
const MODE_TRACK: i64 = 2;

// The words of `out`.
const OUT_START = 0;
const OUT_END = 1;
const OUT_CAPS = 2;
const OUT_FAR = 3;
const OUT_FAILS = 4;
const OUT_PCS = 5;
const OUT_RES = 24;
const OUT_LEN = 25;
const MaxFails = OUT_RES - OUT_PCS;

const RES_MATCH: i64 = 1;
const RES_NONE: i64 = 0;
const RES_STACK: i64 = -1;
const RES_CAPS: i64 = -2;
const RES_INTERRUPT: i64 = -4;

/// The same values as `MaxStack` and `MaxCaptures` in `peg.cy`.
const MaxStack = 100000;
const MaxCaptures = 1000000;

/// How often the match looks at the interrupt request of the VM, in instructions.
const InterruptEvery = 1 << 14;

/// A unit of input that is not a code point: a byte that is not part of valid UTF-8.
const NoChar: i32 = -1;

const Decoded = struct { cp: i32, len: u32 };

/// Decodes the code point at `i`, which is before the end. A byte that does not start a valid sequence is one unit.
fn decode(hay: []const u8, i: usize) Decoded {
    const b0 = hay[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const n: u32 = if (b0 >= 0xf0) 4 else if (b0 >= 0xe0) 3 else if (b0 >= 0xc2) 2 else return .{ .cp = NoChar, .len = 1 };
    if (b0 > 0xf4 or i + n > hay.len) return .{ .cp = NoChar, .len = 1 };
    var cp: u32 = switch (n) {
        2 => b0 & 0x1f,
        3 => b0 & 0x0f,
        else => b0 & 0x07,
    };
    var k: u32 = 1;
    while (k < n) : (k += 1) {
        const b = hay[i + k];
        if (b & 0xc0 != 0x80) return .{ .cp = NoChar, .len = 1 };
        cp = (cp << 6) | (b & 0x3f);
    }
    const min: u32 = switch (n) {
        2 => 0x80,
        3 => 0x800,
        else => 0x10000,
    };
    if (cp < min or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) return .{ .cp = NoChar, .len = 1 };
    return .{ .cp = @intCast(cp), .len = n };
}

inline fn setMatch(set: []const i64, cp: i32) bool {
    const neg = set[S_NEG] != 0;
    if (cp < 0) return neg;
    if (cp < 64) return ((@as(u64, @bitCast(set[S_ASCII_LO])) >> @intCast(cp)) & 1 != 0) != neg;
    if (cp < 128) return ((@as(u64, @bitCast(set[S_ASCII_HI])) >> @intCast(cp - 64)) & 1 != 0) != neg;
    const n: usize = @intCast(set[S_NRANGES]);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (cp >= set[S_RANGES + i * 2] and cp <= set[S_RANGES + i * 2 + 1]) return !neg;
    }
    return neg;
}

const Entry = struct {
    pc: u32,
    kind: Kind,
    /// The place in the input and the height of the capture log to go back to. Not used by a call.
    at: usize,
    ncap: u32,

    const Kind = enum(u8) { call, choice, pred };
};

/// The capture log: the buffer of the caller while it fits, then memory of its own.
/// Two links for each entry, which only the matcher uses, make a back reference and a close take one step for
/// each capture that they pass, not for each entry: `links[2i]` is the entry that closes the named capture that a
/// back reference after entry `i` sees first, and `links[2i + 1]` is the entry that opens the capture that is open
/// after entry `i`. `None` is for none.
const Caps = struct {
    buf: []i64,
    len: usize,
    owned: bool,
    links: []u32 = &.{},
    alloc: std.mem.Allocator,

    const None = std.math.maxInt(u32);

    fn deinit(self: *Caps) void {
        if (self.owned) self.alloc.free(self.buf);
        self.alloc.free(self.links);
    }

    fn push(self: *Caps, kind: i64, aux: i64, at: usize) !void {
        // A capture takes two entries, one to open it and one to close it.
        if (self.len >= MaxCaptures * 2) return error.TooManyCaptures;
        if ((self.len + 1) * CapLen > self.buf.len) {
            const cap = @max(@as(usize, 64), self.len * 2) * CapLen;
            const new = try self.alloc.alloc(i64, cap);
            @memcpy(new[0 .. self.len * CapLen], self.buf[0 .. self.len * CapLen]);
            if (self.owned) self.alloc.free(self.buf);
            self.buf = new;
            self.owned = true;
        }
        if ((self.len + 1) * 2 > self.links.len) {
            const cap = @max(@as(usize, 64), self.len * 2) * 2;
            const new = try self.alloc.alloc(u32, cap);
            @memcpy(new[0 .. self.len * 2], self.links[0 .. self.len * 2]);
            self.alloc.free(self.links);
            self.links = new;
        }
        const e = self.buf[self.len * CapLen ..][0..CapLen];
        e[0] = kind;
        e[1] = aux;
        e[2] = @intCast(at);
        self.len += 1;
    }

    /// The link `k` after the first `n` entries.
    inline fn link(self: *const Caps, n: usize, k: usize) u32 {
        return if (n == 0) None else self.links[(n - 1) * 2 + k];
    }

    fn open(self: *Caps, kind: i64, aux: i64, at: usize) !void {
        const i = self.len;
        try self.push(kind, aux, at);
        self.links[i * 2] = self.link(i, 0);
        self.links[i * 2 + 1] = @intCast(i);
    }

    /// Closes the capture that is open. The entry keeps the index of the entry that opened it in `aux`.
    fn close(self: *Caps, at: usize) !void {
        const i = self.len;
        const o = self.link(i, 1);
        if (o == None) return error.BadProgram;
        try self.push(0, o, at);
        const e = self.buf[o * CapLen ..][0..CapLen];
        // The captures inside are hidden now.
        self.links[i * 2] = if (e[0] == CapNamed) @intCast(i) else self.link(o, 0);
        self.links[i * 2 + 1] = self.link(o, 1);
    }

    /// Returns the input range of the capture named `name` that was closed last, among the first `n` entries.
    /// As LPeg does, a capture that is closed hides the captures inside it, and a capture that is still open does
    /// not hide the captures before it and inside it.
    fn lastNamed(self: *const Caps, n: usize, name: i64) ?[2]usize {
        var c = self.link(n, 0);
        while (c != None) {
            const o: usize = @intCast(self.buf[c * CapLen + 1]);
            if (self.buf[o * CapLen + 1] == name) {
                return .{ @intCast(self.buf[o * CapLen + 2]), @intCast(self.buf[c * CapLen + 2]) };
            }
            c = self.link(o, 0);
        }
        return null;
    }
};

/// The farthest place where the match failed outside a predicate, and the instructions that failed there.
const Track = struct {
    on: bool,
    far: usize = 0,
    n: usize = 0,
    pcs: [MaxFails]u32 = undefined,

    inline fn fail(self: *Track, at: usize, pc: u32) void {
        if (at < self.far and self.n > 0) return;
        if (at > self.far or self.n == 0) {
            self.far = at;
            self.n = 0;
        }
        for (self.pcs[0..self.n]) |p| {
            if (p == pc) return;
        }
        if (self.n < MaxFails) {
            self.pcs[self.n] = pc;
            self.n += 1;
        }
    }
};

/// An empty span has no address.
fn spanWords(span: cy.heap.Span) []i64 {
    if (span.len == 0) return &.{};
    return span.items(i64);
}

/// `fn unit_len(hay str, i int) -> int`
///
/// Returns the number of bytes in the unit of input at byte `i`, as the matcher counts it: a code point, or one byte
/// that is not part of valid UTF-8. The result is 1 at or after the end so that a search moves on.
fn unitLen(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(i64);
    const hay_str = t.param(cy.heap.Str);
    defer t.heap.destructStr(&hay_str);
    const i = t.param(i64);
    const hay = hay_str.slice();
    ret.* = 1;
    if (i >= 0 and i < hay.len) ret.* = decode(hay, @intCast(i)).len;
    return C.RetOk;
}

/// `fn exec(prog [&]int, hay str, start int, mode int, out [&]int, caps [&]int, buffer_t int) -> []int`
///
/// Matches `prog` at byte `start` of `hay`. With `MODE_SEARCH`, a failed match is tried again one code point later
/// until the end of the input. `out[OUT_RES]` gets 1 for a match and 0 for none. `out` also gets the start and the
/// end of the match and the number of entries in the capture log, which is in `caps`: three words an entry,
/// `kind, aux, position`, where kind 0 closes the capture that is open and its `aux` is the index of the entry that
/// opened it. When the log does not fit in `caps`, it is returned in a new slice (`buffer_t` is the type of its
/// buffer) that the caller keeps for the next match; otherwise the result is empty and has no buffer. With
/// `MODE_TRACK`, `out` also gets the farthest place where the match failed outside a predicate and the
/// instructions that failed there. `out[OUT_RES]` is -1 when the stack is over `MaxStack`, -2 when the log is over
/// `MaxCaptures` and -4 when the host asked the VM to stop.
fn exec(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(cy.heap.Slice);
    // An empty slice without a buffer, as `[]int{}` is.
    const words: *[4]u64 = @ptrCast(ret);
    words.* = .{ 0, 0, 0, 1 << 63 };
    const prog: []const i64 = spanWords(t.param(cy.heap.Span));
    const hay_str = t.param(cy.heap.Str);
    defer t.heap.destructStr(&hay_str);
    const start_arg = t.param(i64);
    const mode = t.param(i64);
    const out = spanWords(t.param(cy.heap.Span));
    const caps_arg = spanWords(t.param(cy.heap.Span));
    const buffer_t: cy.TypeId = @intCast(t.param(i64));
    const hay = hay_str.slice();

    if (prog.len < H_LEN or prog[H_MAGIC] != Magic or out.len < OUT_LEN) return error.BadProgram;
    const ninst_w = prog[H_NINST];
    const inst_off = prog[H_INST_OFF];
    if (ninst_w <= 0 or inst_off < H_LEN or inst_off + ninst_w * InstLen > prog.len) return error.BadProgram;
    const ninst: u32 = @intCast(ninst_w);
    const insts = prog[@intCast(inst_off)..][0 .. ninst * InstLen];
    @memset(out[0..OUT_LEN], 0);
    if (start_arg < 0 or start_arg > hay.len) return C.RetOk;

    const alloc = t.alloc;
    var stack: std.ArrayList(Entry) = .empty;
    defer stack.deinit(alloc);
    var caps = Caps{ .buf = caps_arg, .len = 0, .owned = false, .alloc = alloc };
    defer caps.deinit();
    var track = Track{ .on = (mode & MODE_TRACK) != 0 };
    const search = (mode & MODE_SEARCH) != 0;

    var begin: usize = @intCast(start_arg);
    var steps: usize = 0;
    const matched: bool = attempts: while (true) {
        stack.clearRetainingCapacity();
        caps.len = 0;
        var npred: usize = 0;
        var pc: u32 = 0;
        var at: usize = begin;
        var failed = false;
        const ok: bool = run: while (true) {
            if (failed) {
                failed = false;
                // Back to the choice that was made last. The calls that were made after it are dropped.
                while (true) {
                    const e = stack.pop() orelse break :run false;
                    if (e.kind == .call) continue;
                    if (e.kind == .pred) npred -= 1;
                    pc = e.pc;
                    at = e.at;
                    caps.len = e.ncap;
                    break;
                }
            }
            steps += 1;
            if (steps % InterruptEvery == 0 and @atomicLoad(u8, t.c.interrupt, .acquire) != 0) {
                // The host asked the VM to stop. The match ends without a result, and the caller loops so that its
                // checkpoint stops the VM: the result must not be taken for a failed match.
                out[OUT_RES] = RES_INTERRUPT;
                return C.RetOk;
            }
            if (pc >= ninst) return error.BadProgram;
            const in = insts[pc * InstLen ..][0..InstLen];
            const op = std.enums.fromInt(Op, in[0]) orelse return error.BadProgram;
            switch (op) {
                .end => break :run true,
                .any => {
                    if (at < hay.len) {
                        at += decode(hay, at).len;
                        pc += 1;
                    } else {
                        if (track.on and npred == 0) track.fail(at, pc);
                        failed = true;
                    }
                },
                .str => {
                    const off = in[1];
                    const len = in[2];
                    if (off < 0 or len < 0 or off + len > prog.len) return error.BadProgram;
                    const lit = prog[@intCast(off)..][0..@intCast(len)];
                    var hit = hay.len - at >= lit.len;
                    if (hit) {
                        for (lit, 0..) |w, i| {
                            if (hay[at + i] != @as(u8, @truncate(@as(u64, @bitCast(w))))) {
                                hit = false;
                                break;
                            }
                        }
                    }
                    if (hit) {
                        at += lit.len;
                        pc += 1;
                    } else {
                        if (track.on and npred == 0) track.fail(at, pc);
                        failed = true;
                    }
                },
                .str_fold => {
                    const off = in[1];
                    const len = in[2];
                    if (off < 0 or len < 0 or off + len > prog.len) return error.BadProgram;
                    const lit = prog[@intCast(off)..][0..@intCast(len)];
                    var end = at;
                    var hit = true;
                    for (lit) |w| {
                        if (end >= hay.len or w < 0 or w > 0x10ffff) {
                            hit = false;
                            break;
                        }
                        const d = decode(hay, end);
                        if (d.cp == NoChar or !foldEq(@intCast(w), @intCast(d.cp))) {
                            hit = false;
                            break;
                        }
                        end += d.len;
                    }
                    if (hit) {
                        at = end;
                        pc += 1;
                    } else {
                        if (track.on and npred == 0) track.fail(at, pc);
                        failed = true;
                    }
                },
                .set => {
                    const set = try setOf(prog, in[1]);
                    var hit = false;
                    if (at < hay.len) {
                        const d = decode(hay, at);
                        if (setMatch(set, d.cp)) {
                            at += d.len;
                            hit = true;
                        }
                    }
                    if (hit) {
                        pc += 1;
                    } else {
                        if (track.on and npred == 0) track.fail(at, pc);
                        failed = true;
                    }
                },
                .span => {
                    const set = try setOf(prog, in[1]);
                    while (at < hay.len) {
                        const d = decode(hay, at);
                        if (!setMatch(set, d.cp)) break;
                        at += d.len;
                    }
                    // The loop that this stands for fails on the set where it stops.
                    if (track.on and npred == 0) track.fail(at, pc);
                    pc += 1;
                },
                .choice => {
                    if (stack.items.len >= MaxStack) {
                        out[OUT_RES] = RES_STACK;
                        return C.RetOk;
                    }
                    const pred = in[2] != 0;
                    if (pred) npred += 1;
                    try stack.append(alloc, .{
                        .pc = try target(in[1]),
                        .kind = if (pred) .pred else .choice,
                        .at = at,
                        .ncap = @intCast(caps.len),
                    });
                    pc += 1;
                },
                .commit => {
                    const e = stack.pop() orelse return error.BadProgram;
                    if (e.kind == .call) return error.BadProgram;
                    if (e.kind == .pred) npred -= 1;
                    pc = try target(in[1]);
                },
                .partial_commit => {
                    if (stack.items.len == 0) return error.BadProgram;
                    const e = &stack.items[stack.items.len - 1];
                    if (e.kind == .call) return error.BadProgram;
                    e.at = at;
                    e.ncap = @intCast(caps.len);
                    pc = try target(in[1]);
                },
                .back_commit => {
                    const e = stack.pop() orelse return error.BadProgram;
                    if (e.kind == .call) return error.BadProgram;
                    if (e.kind == .pred) npred -= 1;
                    at = e.at;
                    caps.len = e.ncap;
                    pc = try target(in[1]);
                },
                .fail => {
                    if (track.on and npred == 0) track.fail(at, pc);
                    failed = true;
                },
                .fail_twice => {
                    // The pattern of a `!p` matched: drop its choice, then fail where it started.
                    const e = stack.pop() orelse return error.BadProgram;
                    if (e.kind == .call) return error.BadProgram;
                    if (e.kind == .pred) npred -= 1;
                    at = e.at;
                    if (track.on and npred == 0) track.fail(at, pc);
                    failed = true;
                },
                .call => {
                    if (stack.items.len >= MaxStack) {
                        out[OUT_RES] = RES_STACK;
                        return C.RetOk;
                    }
                    try stack.append(alloc, .{ .pc = pc + 1, .kind = .call, .at = 0, .ncap = 0 });
                    pc = try target(in[1]);
                },
                .ret => {
                    const e = stack.pop() orelse return error.BadProgram;
                    if (e.kind != .call) return error.BadProgram;
                    pc = e.pc;
                },
                .jmp => pc = try target(in[1]),
                .open => {
                    caps.open(in[1], in[2], at) catch |err| switch (err) {
                        error.TooManyCaptures => {
                            out[OUT_RES] = RES_CAPS;
                            return C.RetOk;
                        },
                        else => return err,
                    };
                    pc += 1;
                },
                .close => {
                    caps.close(at) catch |err| switch (err) {
                        error.TooManyCaptures => {
                            out[OUT_RES] = RES_CAPS;
                            return C.RetOk;
                        },
                        else => return err,
                    };
                    pc += 1;
                },
                .backref => {
                    var hit = false;
                    if (caps.lastNamed(caps.len, in[1])) |range| {
                        const text = hay[range[0]..range[1]];
                        if (hay.len - at >= text.len and std.mem.eql(u8, hay[at..][0..text.len], text)) {
                            at += text.len;
                            hit = true;
                        }
                    }
                    if (hit) {
                        pc += 1;
                    } else {
                        if (track.on and npred == 0) track.fail(at, pc);
                        failed = true;
                    }
                },
            }
        };
        if (ok) {
            out[OUT_START] = @intCast(begin);
            out[OUT_END] = @intCast(at);
            break :attempts true;
        }
        if (!search or begin >= hay.len) break :attempts false;
        begin += decode(hay, begin).len;
    };

    if (track.on) {
        out[OUT_FAR] = @intCast(track.far);
        out[OUT_FAILS] = @intCast(track.n);
        for (track.pcs[0..track.n], 0..) |p, i| out[OUT_PCS + i] = p;
    }
    if (!matched) return C.RetOk;
    out[OUT_CAPS] = @intCast(caps.len);
    if (caps.owned) {
        const n = caps.len * CapLen;
        if (n > caps_arg.len) {
            // The whole buffer, so that the next match of the caller has room to grow.
            const slice = try t.heap.init_slice_undef(buffer_t, caps.buf.len, @sizeOf(i64));
            const dst = slice.items(i64);
            @memcpy(dst[0..n], caps.buf[0..n]);
            @memset(dst[n..], 0);
            ret.* = slice;
        } else {
            @memcpy(caps_arg[0..n], caps.buf[0..n]);
        }
    }
    out[OUT_RES] = RES_MATCH;
    return C.RetOk;
}

/// Whether `a` and `b` are the same code point under simple case folding, as `(?i)` of `regex` compares them.
fn foldEq(a: u32, b: u32) bool {
    if (a == b) return true;
    var next = regex.foldNext(a);
    while (next != a) : (next = regex.foldNext(next)) {
        if (next == b) return true;
    }
    return false;
}

inline fn target(a: i64) error{BadProgram}!u32 {
    if (a < 0 or a > std.math.maxInt(u32) - 1) return error.BadProgram;
    return @intCast(a);
}

fn setOf(prog: []const i64, off: i64) error{BadProgram}![]const i64 {
    if (off < 0 or off + S_RANGES > prog.len) return error.BadProgram;
    const s = prog[@intCast(off)..];
    const n = s[S_NRANGES];
    if (n < 0 or S_RANGES + n * 2 > s.len) return error.BadProgram;
    return s;
}

test "peg decode" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 'a'), decode("a", 0).cp);
    try t.expectEqual(@as(i32, 0xac00), decode("가", 0).cp);
    try t.expectEqual(@as(u32, 3), decode("가", 0).len);
    try t.expectEqual(@as(i32, 0x1f600), decode("😀", 0).cp);
    try t.expectEqual(NoChar, decode("\xff", 0).cp);
    try t.expectEqual(@as(u32, 1), decode("\xea\xb0", 0).len);
    try t.expectEqual(NoChar, decode("\xed\xa0\x80", 0).cp);
}

test "peg fold" {
    const t = std.testing;
    try t.expect(foldEq('a', 'A'));
    try t.expect(foldEq('K', 0x212a));
    try t.expect(foldEq(0x212a, 'k'));
    try t.expect(foldEq('s', 0x17f));
    try t.expect(!foldEq('a', 'b'));
    try t.expect(foldEq('1', '1'));
    try t.expect(!foldEq('1', '2'));
}

test "peg set" {
    const t = std.testing;
    // `[a-c가-힣]`
    const set = [_]i64{ 0, 0b1110 << 32, 0, 2, 'a', 'c', 0xac00, 0xd7a3 };
    try t.expect(setMatch(&set, 'b'));
    try t.expect(!setMatch(&set, 'd'));
    try t.expect(setMatch(&set, 0xac01));
    try t.expect(!setMatch(&set, 0x3042));
    try t.expect(!setMatch(&set, NoChar));
    const neg = [_]i64{ 0, 0b1110 << 32, 1, 1, 'a', 'c' };
    try t.expect(!setMatch(&neg, 'b'));
    try t.expect(setMatch(&neg, 'd'));
    try t.expect(setMatch(&neg, NoChar));
}
