//! The matcher of the `regex` module: a Pike VM (Thompson NFA simulation) over the program that `regex.cy` compiles.
//! One search is O(m * n) for a program of m instructions and an input of n bytes. Nothing backtracks.
//! The layout of the program is described in `regex.cy` ("Program layout") and must match the constants below.
const std = @import("std");
const cy = @import("../cyber.zig");
const C = @import("../capi.zig");
const uni = @import("regex_unicode.zig");

const Src = @embedFile("regex.cy");

comptime {
    @export(&bind, .{ .name = "cl_mod_bind_regex", .linkage = .strong });
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
    .{ "set_ascii", zErrFunc(setAscii) },
    .{ "uni_table", zErrFunc(uniTable) },
    .{ "unicode_version", zErrFunc(uniVersion) },
};

// Header words.
const H_MAGIC = 0;
const H_NINST = 1;
const H_NSLOTS = 2;
const H_FLAGS = 3;
const H_PREFIX_LEN = 4;
const H_PREFIX_OFF = 5;
const H_INST_OFF = 6;
const H_LEN = 8;

const Magic: i64 = 0x5245_0001;

const F_ANCHORED: i64 = 1;

/// Words per instruction: `op, a, b`.
const InstLen = 3;

const Op = enum(i64) {
    match = 0,
    char = 1,
    any = 2,
    any_nl = 3,
    set = 4,
    split = 5,
    jmp = 6,
    save = 7,
    assert = 8,
};

const Assert = enum(i64) {
    start_text = 0,
    end_text = 1,
    start_line = 2,
    end_line = 3,
    word = 4,
    not_word = 5,
    word_start = 6,
    word_end = 7,
    word_start_half = 8,
    word_end_half = 9,
};

// Set words: `ascii_lo, ascii_hi, flags, nops`, then `nops` ops of three words in postfix order.
const S_ASCII_LO = 0;
const S_ASCII_HI = 1;
const S_FLAGS = 2;
const S_NOPS = 3;
const S_OPS = 4;

const SF_FOLD: i64 = 1;

const SetOp = enum(i64) {
    range = 0,
    table = 1,
    @"or" = 2,
    @"and" = 3,
    diff = 4,
    xor = 5,
    not = 6,
};

/// The deepest stack a set expression may need. `regex.cy` limits the nesting of classes well below it.
const SetStack = 512;

/// A code point that no instruction matches: a byte that is not UTF-8, or the end of the input.
const NoChar: i32 = -1;

const Decoded = struct { cp: i32, len: u32 };

/// Decodes the code point at `i`. A byte that does not start a well formed sequence is `NoChar` of length 1.
fn decode(hay: []const u8, i: usize) Decoded {
    const b0 = hay[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    const rest = hay.len - i;
    if (b0 < 0xc2) return .{ .cp = NoChar, .len = 1 };
    if (b0 < 0xe0) {
        if (rest < 2 or (hay[i + 1] & 0xc0) != 0x80) return .{ .cp = NoChar, .len = 1 };
        return .{ .cp = (@as(i32, b0 & 0x1f) << 6) | (hay[i + 1] & 0x3f), .len = 2 };
    }
    if (b0 < 0xf0) {
        if (rest < 3 or (hay[i + 1] & 0xc0) != 0x80 or (hay[i + 2] & 0xc0) != 0x80) return .{ .cp = NoChar, .len = 1 };
        const cp = (@as(i32, b0 & 0x0f) << 12) | (@as(i32, hay[i + 1] & 0x3f) << 6) | (hay[i + 2] & 0x3f);
        if (cp < 0x800 or (cp >= 0xd800 and cp <= 0xdfff)) return .{ .cp = NoChar, .len = 1 };
        return .{ .cp = cp, .len = 3 };
    }
    if (b0 < 0xf5) {
        if (rest < 4 or (hay[i + 1] & 0xc0) != 0x80 or (hay[i + 2] & 0xc0) != 0x80 or (hay[i + 3] & 0xc0) != 0x80) return .{ .cp = NoChar, .len = 1 };
        const cp = (@as(i32, b0 & 0x07) << 18) | (@as(i32, hay[i + 1] & 0x3f) << 12) | (@as(i32, hay[i + 2] & 0x3f) << 6) | (hay[i + 3] & 0x3f);
        if (cp < 0x10000 or cp > 0x10ffff) return .{ .cp = NoChar, .len = 1 };
        return .{ .cp = cp, .len = 4 };
    }
    return .{ .cp = NoChar, .len = 1 };
}

/// Returns the code point that ends at `i`, or `NoChar` at the start of the input and after a byte that is not UTF-8.
fn decodeBefore(hay: []const u8, i: usize) i32 {
    if (i == 0) return NoChar;
    if (hay[i - 1] < 0x80) return hay[i - 1];
    var start = i - 1;
    const min = if (i >= 4) i - 4 else 0;
    while (start > min and (hay[start] & 0xc0) == 0x80) start -= 1;
    const d = decode(hay, start);
    if (start + d.len != i) return NoChar;
    return d.cp;
}

/// Moves a position that is inside a code point to its end: no match starts or ends inside a code point.
fn alignStart(hay: []const u8, i: usize) usize {
    if (i >= hay.len or (hay[i] & 0xc0) != 0x80) return i;
    var start = i;
    const min = if (i >= 3) i - 3 else 0;
    while (start > min and (hay[start] & 0xc0) == 0x80) start -= 1;
    const d = decode(hay, start);
    if (d.cp != NoChar and start + d.len > i) return start + d.len;
    return i;
}

fn inTable(table: []const uni.R, cp: u32) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = table[mid];
        if (cp < r[0]) {
            hi = mid;
        } else if (cp > r[1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Returns the next code point of the simple case folding orbit of `cp`, or `cp` when it folds to nothing else.
fn foldNext(cp: u32) u32 {
    var lo: usize = 0;
    var hi: usize = uni.fold.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = uni.fold[mid];
        if (cp < e[0]) {
            hi = mid;
        } else if (cp > e[0]) {
            lo = mid + 1;
        } else {
            return e[1];
        }
    }
    return cp;
}

fn isWord(cp: i32) bool {
    if (cp < 0) return false;
    if (cp < 0x80) {
        const b: u8 = @intCast(cp);
        return std.ascii.isAlphanumeric(b) or b == '_';
    }
    return inTable(uni.tables[uni.word], @intCast(cp));
}

fn leafMatch(op: SetOp, a: i64, b: i64, cp: u32) bool {
    switch (op) {
        .range => return cp >= a and cp <= b,
        .table => return inTable(uni.tables[@intCast(a)], cp),
        else => unreachable,
    }
}

/// Evaluates the postfix expression of the set at `set` for one code point.
/// With `SF_FOLD`, a leaf holds when it holds for any code point of the orbit: the leaf is folded, then the
/// operators apply, which is the order of the Rust `regex` crate.
fn evalSet(set: []const i64, cp: u32) error{BadProgram}!bool {
    const fold = (set[S_FLAGS] & SF_FOLD) != 0;
    const nops: usize = @intCast(set[S_NOPS]);
    var stack: [SetStack]bool = undefined;
    var sp: usize = 0;
    var i: usize = 0;
    while (i < nops) : (i += 1) {
        const w = set[S_OPS + i * 3 ..][0..3];
        const op = std.enums.fromInt(SetOp, w[0]) orelse return error.BadProgram;
        switch (op) {
            .range, .table => {
                if (sp == SetStack) return error.BadProgram;
                var res = leafMatch(op, w[1], w[2], cp);
                if (fold and !res) {
                    var next = foldNext(cp);
                    var guard: u32 = 0;
                    while (next != cp and guard < 8) : (guard += 1) {
                        if (leafMatch(op, w[1], w[2], next)) {
                            res = true;
                            break;
                        }
                        next = foldNext(next);
                    }
                }
                stack[sp] = res;
                sp += 1;
            },
            .not => {
                if (sp < 1) return error.BadProgram;
                stack[sp - 1] = !stack[sp - 1];
            },
            else => {
                if (sp < 2) return error.BadProgram;
                const r = stack[sp - 1];
                const l = stack[sp - 2];
                sp -= 1;
                stack[sp - 1] = switch (op) {
                    .@"or" => l or r,
                    .@"and" => l and r,
                    .diff => l and !r,
                    .xor => l != r,
                    else => unreachable,
                };
            },
        }
    }
    if (sp != 1) return error.BadProgram;
    return stack[0];
}

inline fn setMatch(set: []const i64, cp: i32) error{BadProgram}!bool {
    if (cp < 0) return false;
    if (cp < 64) return (@as(u64, @bitCast(set[S_ASCII_LO])) >> @intCast(cp)) & 1 != 0;
    if (cp < 128) return (@as(u64, @bitCast(set[S_ASCII_HI])) >> @intCast(cp - 64)) & 1 != 0;
    return evalSet(set, @intCast(cp));
}

/// The threads of one step: a sparse set of instructions in priority order, each with its capture slots.
const Threads = struct {
    dense: []u32,
    sparse: []u32,
    len: usize,
    slots: []i64,
    nslots: usize,

    fn init(alloc: std.mem.Allocator, ninst: usize, nslots: usize) !Threads {
        const dense = try alloc.alloc(u32, ninst);
        errdefer alloc.free(dense);
        const sparse = try alloc.alloc(u32, ninst);
        errdefer alloc.free(sparse);
        @memset(sparse, 0);
        const slots = try alloc.alloc(i64, ninst * nslots);
        return .{ .dense = dense, .sparse = sparse, .len = 0, .slots = slots, .nslots = nslots };
    }

    fn deinit(self: *Threads, alloc: std.mem.Allocator) void {
        alloc.free(self.dense);
        alloc.free(self.sparse);
        alloc.free(self.slots);
    }

    inline fn contains(self: *const Threads, pc: u32) bool {
        const i = self.sparse[pc];
        return i < self.len and self.dense[i] == pc;
    }

    inline fn insert(self: *Threads, pc: u32) void {
        self.sparse[pc] = @intCast(self.len);
        self.dense[self.len] = pc;
        self.len += 1;
    }

    inline fn row(self: *Threads, pc: u32) []i64 {
        return self.slots[pc * self.nslots ..][0..self.nslots];
    }
};

const Frame = struct {
    /// An instruction to explore, or `restore` to put `val` back into slot `slot`.
    pc: u32,
    slot: u32,
    val: i64,

    const restore: u32 = std.math.maxInt(u32);
};

const Vm = struct {
    insts: []const i64,
    prog: []const i64,
    hay: []const u8,
    stack: std.ArrayList(Frame),
    alloc: std.mem.Allocator,

    inline fn inst(self: *const Vm, pc: u32) *const [InstLen]i64 {
        return self.insts[pc * InstLen ..][0..InstLen];
    }

    fn set(self: *const Vm, off: i64) error{BadProgram}![]const i64 {
        if (off < 0 or off + S_OPS > self.prog.len) return error.BadProgram;
        const s = self.prog[@intCast(off)..];
        const nops = s[S_NOPS];
        if (nops < 0 or S_OPS + nops * 3 > s.len) return error.BadProgram;
        return s;
    }

    fn assertAt(self: *const Vm, kind: i64, at: usize) error{BadProgram}!bool {
        const hay = self.hay;
        const a = std.enums.fromInt(Assert, kind) orelse return error.BadProgram;
        switch (a) {
            .start_text => return at == 0,
            .end_text => return at == hay.len,
            .start_line => return at == 0 or hay[at - 1] == '\n',
            .end_line => return at == hay.len or hay[at] == '\n',
            else => {},
        }
        const before = isWord(decodeBefore(hay, at));
        const after = at < hay.len and isWord(decode(hay, at).cp);
        return switch (a) {
            .word => before != after,
            .not_word => before == after,
            .word_start => !before and after,
            .word_end => before and !after,
            .word_start_half => !before,
            .word_end_half => !after,
            else => unreachable,
        };
    }

    /// Adds the threads that `pc` reaches at `at` without consuming input. `slots` is the capture state of the thread
    /// that got here. It is changed while a path is explored and is back to its value when this returns.
    fn closure(self: *Vm, list: *Threads, slots: []i64, start_pc: u32, at: usize) !void {
        try self.stack.append(self.alloc, .{ .pc = start_pc, .slot = 0, .val = 0 });
        while (self.stack.pop()) |frame| {
            if (frame.pc == Frame.restore) {
                slots[frame.slot] = frame.val;
                continue;
            }
            var pc = frame.pc;
            while (true) {
                if (pc >= list.dense.len) return error.BadProgram;
                if (list.contains(pc)) break;
                list.insert(pc);
                const in = self.inst(pc);
                const op = std.enums.fromInt(Op, in[0]) orelse return error.BadProgram;
                switch (op) {
                    .match, .char, .any, .any_nl, .set => {
                        @memcpy(list.row(pc), slots);
                        break;
                    },
                    .jmp => pc = try target(in[1]),
                    .split => {
                        try self.stack.append(self.alloc, .{ .pc = try target(in[2]), .slot = 0, .val = 0 });
                        pc = try target(in[1]);
                    },
                    .save => {
                        const slot = in[1];
                        if (slot < 0) return error.BadProgram;
                        // A search that does not ask for a group skips its slots.
                        if (slot < slots.len) {
                            const s: u32 = @intCast(slot);
                            try self.stack.append(self.alloc, .{ .pc = Frame.restore, .slot = s, .val = slots[s] });
                            slots[s] = @intCast(at);
                        }
                        pc += 1;
                    },
                    .assert => {
                        if (!try self.assertAt(in[1], at)) break;
                        pc += 1;
                    },
                }
            }
        }
    }

    inline fn target(a: i64) error{BadProgram}!u32 {
        if (a < 0 or a > std.math.maxInt(u32) - 1) return error.BadProgram;
        return @intCast(a);
    }
};

/// An empty span has no address.
fn spanWords(span: cy.heap.Span) []i64 {
    if (span.len == 0) return &.{};
    return span.items(i64);
}

/// How often the search looks at the interrupt request of the VM, in steps.
const InterruptEvery = 1 << 14;

/// `fn exec(prog [&]int, hay str, start int, skip bool, slots [&]int) -> bool`
///
/// Finds the leftmost match that starts at or after `start`, or with `skip`, after the code point at `start`
/// (the step of a repeated search past an empty match). `slots` gets the byte offsets of the first
/// `slots.len() / 2` groups (-1 for a group that did not take part). With no slots, the search stops at the first
/// match it sees.
fn exec(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(bool);
    const prog: []const i64 = spanWords(t.param(cy.heap.Span));
    const hay_str = t.param(cy.heap.Str);
    defer t.heap.destructStr(&hay_str);
    const start_arg = t.param(i64);
    const skip = t.param(bool);
    const out = spanWords(t.param(cy.heap.Span));
    const hay = hay_str.slice();

    ret.* = false;
    if (prog.len < H_LEN or prog[H_MAGIC] != Magic) return error.BadProgram;
    if (start_arg < 0 or start_arg > hay.len) return C.RetOk;
    var at: usize = alignStart(hay, @intCast(start_arg));
    if (skip) {
        if (at == hay.len) return C.RetOk;
        at += decode(hay, at).len;
    }
    const ninst_w = prog[H_NINST];
    const inst_off = prog[H_INST_OFF];
    if (ninst_w <= 0 or inst_off < H_LEN or inst_off + ninst_w * InstLen > prog.len) return error.BadProgram;
    const ninst: usize = @intCast(ninst_w);
    const insts = prog[@intCast(inst_off)..][0 .. ninst * InstLen];
    if (prog[H_NSLOTS] < 2 or out.len > prog[H_NSLOTS]) return error.BadProgram;
    const nslots = out.len;
    const anchored = (prog[H_FLAGS] & F_ANCHORED) != 0;

    // The literal that every match starts with, one byte a word.
    var prefix_buf: [64]u8 = undefined;
    var prefix: []const u8 = prefix_buf[0..0];
    {
        const plen = prog[H_PREFIX_LEN];
        const poff = prog[H_PREFIX_OFF];
        if (plen < 0 or plen > prefix_buf.len or poff < 0 or poff + plen > prog.len) return error.BadProgram;
        const words = prog[@intCast(poff)..][0..@intCast(plen)];
        for (words, 0..) |w, i| prefix_buf[i] = @truncate(@as(u64, @bitCast(w)));
        prefix = prefix_buf[0..words.len];
    }

    const alloc = t.alloc;
    var curr = try Threads.init(alloc, ninst, nslots);
    defer curr.deinit(alloc);
    var next = try Threads.init(alloc, ninst, nslots);
    defer next.deinit(alloc);
    const scratch = try alloc.alloc(i64, nslots);
    defer alloc.free(scratch);
    var vm = Vm{ .insts = insts, .prog = prog, .hay = hay, .stack = .empty, .alloc = alloc };
    defer vm.stack.deinit(alloc);

    var matched = false;
    var steps: usize = 0;
    while (true) {
        if (curr.len == 0) {
            if (matched) break;
            if (anchored and at > 0) break;
            if (prefix.len > 0) {
                // No thread is alive, so the next match starts at the next occurrence of the prefix.
                if (hay.len - at < prefix.len) break;
                const found = (if (prefix.len == 1)
                    cy.string.indexOfChar(hay[at..], prefix[0])
                else
                    cy.string.indexOf(hay[at..], prefix)) orelse break;
                at += found;
            }
        }
        if (!matched and (!anchored or at == 0)) {
            // A new thread starts here, after the ones that started earlier.
            @memset(scratch, -1);
            try vm.closure(&curr, scratch, 0, at);
        }
        const d: Decoded = if (at < hay.len) decode(hay, at) else .{ .cp = NoChar, .len = 0 };
        const after = at + d.len;
        var i: usize = 0;
        while (i < curr.len) : (i += 1) {
            const pc = curr.dense[i];
            const in = vm.inst(pc);
            const hit = switch (@as(Op, @enumFromInt(in[0]))) {
                .match => {
                    if (nslots == 0) {
                        ret.* = true;
                        return C.RetOk;
                    }
                    @memcpy(out, curr.row(pc));
                    matched = true;
                    // The threads after this one have a lower priority.
                    break;
                },
                .char => d.cp == in[1],
                .any => d.cp >= 0 and d.cp != '\n',
                .any_nl => d.cp >= 0,
                .set => try setMatch(try vm.set(in[1]), d.cp),
                else => false,
            };
            if (hit) {
                try vm.closure(&next, curr.row(pc), pc + 1, after);
            }
        }
        if (at >= hay.len) break;
        at = after;
        std.mem.swap(Threads, &curr, &next);
        next.len = 0;

        steps += 1;
        if (steps % InterruptEvery == 0 and @atomicLoad(u8, t.c.interrupt, .acquire) != 0) {
            // The host asked the VM to stop. The search ends without a match and the VM stops at its next check.
            ret.* = false;
            return C.RetOk;
        }
    }
    ret.* = matched;
    return C.RetOk;
}

/// `fn set_ascii(sets [&]int, off int, half int) -> int`
///
/// Returns the members of the set at `sets[off..]` among the code points 0..63 (`half` 0) or 64..127 (`half` 1)
/// as a bit mask. The two mask words of the set are not read.
fn setAscii(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(i64);
    const sets: []const i64 = spanWords(t.param(cy.heap.Span));
    const off = t.param(i64);
    const half = t.param(i64);
    if (off < 0 or off > sets.len) return error.BadProgram;
    const set = sets[@intCast(off)..];
    if (set.len < S_OPS or set[S_NOPS] < 0 or S_OPS + set[S_NOPS] * 3 > set.len) return error.BadProgram;
    var mask: u64 = 0;
    const base: u32 = if (half == 0) 0 else 64;
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        if (try evalSet(set, base + i)) mask |= @as(u64, 1) << @intCast(i);
    }
    ret.* = @bitCast(mask);
    return C.RetOk;
}

/// `fn uni_table(name str, kind int) -> int`
///
/// Returns the table of a property value by its loose name, or -1. `kind` is 0 for a general category, 1 for a
/// script, 2 for a binary property and -1 for any of them: a binary property first, then a general category, then
/// a script, as the Rust `regex` crate resolves a bare name. Kind 3 is for the tables of the Perl classes:
/// `word`, `digit`, `space` and `unassigned`.
fn uniTable(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(i64);
    const name_str = t.param(cy.heap.Str);
    defer t.heap.destructStr(&name_str);
    const kind = t.param(i64);
    const name = name_str.slice();
    ret.* = -1;
    if (kind == 3) {
        const perl = [_]struct { []const u8, u16 }{
            .{ "word", uni.word },
            .{ "digit", uni.digit },
            .{ "space", uni.space },
            .{ "unassigned", uni.unassigned },
        };
        for (perl) |e| {
            if (std.mem.eql(u8, e[0], name)) ret.* = e[1];
        }
        return C.RetOk;
    }
    const order = [_]u8{ 2, 0, 1 };
    for (order) |k| {
        if (kind >= 0 and kind != k) continue;
        for (uni.names) |n| {
            if (n.kind == k and std.mem.eql(u8, n.name, name)) {
                ret.* = n.table;
                return C.RetOk;
            }
        }
    }
    return C.RetOk;
}

/// `fn unicode_version() -> str`
fn uniVersion(t: *cy.Thread) anyerror!C.Ret {
    const ret = t.ret(cy.heap.Str);
    ret.* = try t.heap.init_astr(uni.version);
    return C.RetOk;
}

test "regex decode" {
    const t = std.testing;
    try t.expectEqual(@as(i32, 'a'), decode("a", 0).cp);
    try t.expectEqual(@as(i32, 0xac00), decode("가", 0).cp);
    try t.expectEqual(@as(u32, 3), decode("가", 0).len);
    try t.expectEqual(@as(i32, 0x1f600), decode("😀", 0).cp);
    try t.expectEqual(NoChar, decode("\xff", 0).cp);
    try t.expectEqual(NoChar, decode("\xc0\x80", 0).cp);
    try t.expectEqual(NoChar, decode("\xed\xa0\x80", 0).cp);
    try t.expectEqual(NoChar, decode("\xea\xb0", 0).cp);
    try t.expectEqual(@as(i32, 0xac00), decodeBefore("a가", 4));
    try t.expectEqual(NoChar, decodeBefore("a\xb0", 2));
    try t.expectEqual(NoChar, decodeBefore("", 0));
    try t.expectEqual(@as(usize, 4), alignStart("😀a", 1));
    try t.expectEqual(@as(usize, 4), alignStart("😀a", 3));
    try t.expectEqual(@as(usize, 4), alignStart("😀a", 4));
    try t.expectEqual(@as(usize, 1), alignStart("a\x80\x80", 1));
    try t.expectEqual(@as(usize, 0), alignStart("😀", 0));
}

test "regex fold orbits" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 'a'), foldNext('A'));
    try t.expectEqual(@as(u32, 0x212a), foldNext('k'));
    try t.expectEqual(@as(u32, 'K'), foldNext(0x212a));
    try t.expectEqual(@as(u32, '1'), foldNext('1'));
    try t.expect(isWord(0xac00));
    try t.expect(!isWord(0x3002));
}
