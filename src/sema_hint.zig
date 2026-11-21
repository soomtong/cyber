const std = @import("std");
const cy = @import("cyber.zig");
const bt = cy.types.BuiltinTypes;
const fmt = cy.fmt;
const v = fmt.v;
const ast = cy.ast;
const Sym = cy.Sym;
const sema = cy.sema;

// `docs/gen-api-json.cy` reads this table as text: one `.{ "from", "to" }` pair per entry, ending at `};`.
// If the format changes, the generator fails with `error.MissingAliases` or drops pairs.
const member_aliases = [_][2][]const u8{
    .{ "startswith", "starts_with" }, .{ "startsWith", "starts_with" }, .{ "hasPrefix", "starts_with" },
    .{ "endswith", "ends_with" }, .{ "endsWith", "ends_with" }, .{ "hasSuffix", "ends_with" },
    .{ "find", "index" }, .{ "indexOf", "index" },
    .{ "basename", "base" }, .{ "dirname", "dir" }, .{ "extname", "ext" }, .{ "isabs", "is_absolute" },
    .{ "rfind", "last_index" }, .{ "rindex", "last_index" }, .{ "lastIndexOf", "last_index" }, .{ "isNaN", "is_nan" }, .{ "isInf", "is_inf" }, .{ "indexOfNewLine", "index_newline" },
    .{ "strip", "trim" }, .{ "trimSpace", "trim" },
    .{ "lstrip", "trim_left" }, .{ "trimStart", "trim_left" }, .{ "trim_start", "trim_left" }, .{ "ltrim", "trim_left" },
    .{ "rstrip", "trim_right" }, .{ "trimEnd", "trim_right" }, .{ "trim_end", "trim_right" }, .{ "rtrim", "trim_right" },
    .{ "toLowerCase", "lower" }, .{ "toUpperCase", "upper" },
    .{ "toLower", "lower" }, .{ "toUpper", "upper" }, .{ "lowercase", "lower" }, .{ "uppercase", "upper" },
    .{ "to_lowercase", "lower" }, .{ "to_uppercase", "upper" },
    .{ "push", "append" }, .{ "add", "append" },
    .{ "length", "len" }, .{ "size", "len" }, .{ "count", "len" },
    // `Map` has `size` instead of `len`.
    .{ "length", "size" }, .{ "len", "size" }, .{ "count", "size" },
    .{ "includes", "contains" }, .{ "has", "contains" },
    .{ "splitlines", "lines" }, .{ "reversed", "reverse" },
    .{ "rjust", "pad_left" }, .{ "padStart", "pad_left" }, .{ "pad_start", "pad_left" },
    .{ "ljust", "pad_right" }, .{ "padEnd", "pad_right" }, .{ "pad_end", "pad_right" },
};

pub var suggest_buf: [256]u8 = undefined;

/// The name that the last hint of `suggestMember`, `suggestField` or `suggestModuleSym` offers in place of the
/// name that was not found: `trim_left`, or `len()` for a method. Empty when the hint offers no name.
var suggest_new_buf: [80]u8 = undefined;
var suggest_new: []const u8 = "";

pub fn setSuggestNew(comptime format: []const u8, args: anytype) void {
    suggest_new = std.fmt.bufPrint(&suggest_new_buf, format, args) catch "";
}

/// The edit that writes the name of the last hint over `node`, the name `name` that was not found. The report
/// drops the fix when there is none (`Chunk.reportErrorFix`).
pub fn suggestedFix(c: *cy.Chunk, name: []const u8, node: *ast.Node) cy.compiler.ReportFix {
    const none: cy.compiler.ReportFix = .{ .pos = cy.NullId, .end_pos = 0, .text = "" };
    if (suggest_new.len == 0) return none;
    const pos = node.pos();
    if (pos == cy.NullId) return none;
    const src = c.compiler.chunks.items[node.src()].src;
    const end = node.end();
    if (end > src.len or pos > end or !std.mem.eql(u8, src[pos..end], name)) return none;
    var text = suggest_new;
    // `v.len(1)` for `v.length(1)`: the call is already written.
    if (std.mem.endsWith(u8, text, "()") and end < src.len and src[end] == '(') text = text[0 .. text.len - 2];
    return .{ .pos = pos, .end_pos = end, .text = text };
}

/// A hint for a member that `rec_t` does not have: ` Did you mean `x`?`, or an empty string.
/// Names from Python and JavaScript are mapped to the Cyber names, then a camelCase name is tried
/// as snake_case, then a member whose name is close.
pub fn suggestMember(c: *cy.Chunk, rec_t: *cy.Type, name: []const u8, node: *ast.Node) ![]const u8 {
    var base_t = rec_t;
    switch (rec_t.kind()) {
        .pointer => base_t = rec_t.cast(.pointer).child_t,
        .borrow => base_t = rec_t.cast(.borrow).child_t,
        .ex_borrow => base_t = rec_t.cast(.ex_borrow).child_t,
        else => {},
    }
    suggest_new = "";
    if (name.len == 0 or name.len > 64) return "";

    if (base_t.kind() == .result and try hasMember(c, base_t.cast(.result).child_t, name, node)) {
        return " Unwrap it with `!` first, or handle the error with `!else` or `try`.";
    }
    if (base_t.kind() == .option and try hasMember(c, base_t.cast(.option).child_t, name, node)) {
        return " Unwrap it with `.?` first, or give a default with `?else`.";
    }
    if (base_t.id() == bt.Str and std.mem.eql(u8, name, "join")) {
        return " `join` is a method of a list: `xs.join(sep)`.";
    }
    if (std.mem.eql(u8, name, "pop") and try hasMember(c, base_t, "remove", node)) {
        return " Use `last()` and `remove(i)`.";
    }
    if (std.mem.eql(u8, name, "items") and try hasMember(c, base_t, "keys", node)) {
        return " Iterate the map with `for m |e|:` and use `e.key` and `e.value`.";
    }
    for (member_aliases) |alias| {
        if (std.mem.eql(u8, alias[0], name) and try hasMember(c, base_t, alias[1], node)) {
            setSuggestNew("{s}", .{alias[1]});
            return std.fmt.bufPrint(&suggest_buf, " Did you mean `{s}`?", .{alias[1]}) catch "";
        }
    }

    // `to_upper` for `upper`.
    if (std.mem.startsWith(u8, name, "to_") and name.len > 3 and try hasMember(c, base_t, name[3..], node)) {
        setSuggestNew("{s}", .{name[3..]});
        return std.fmt.bufPrint(&suggest_buf, " Did you mean `{s}`?", .{name[3..]}) catch "";
    }

    // camelCase to snake_case.
    var snake_buf: [128]u8 = undefined;
    if (toSnakeCase(name, &snake_buf)) |snake| {
        if (try hasMember(c, base_t, snake, node)) {
            setSuggestNew("{s}", .{snake});
            return std.fmt.bufPrint(&suggest_buf, " Did you mean `{s}`?", .{snake}) catch "";
        }
    }

    // A member whose name is close. Short names only match one edit away.
    const mods = [_]?*cy.Module{
        base_t.sym().getMod(),
        if (base_t.sym().instance) |inst| (if (inst.type == .sym) inst.getSymTemplate().getMod() else null) else null,
    };
    if (closestSym(&mods, name)) |cand| {
        setSuggestNew("{s}", .{cand});
        return std.fmt.bufPrint(&suggest_buf, " Did you mean `{s}`?", .{cand}) catch "";
    }
    return "";
}

/// `fileExists` as `file_exists`, or null when `name` has no upper case letter. `name` is at most 64 bytes.
fn toSnakeCase(name: []const u8, buf: *[128]u8) ?[]const u8 {
    var len: usize = 0;
    var has_upper = false;
    for (name, 0..) |ch, i| {
        if (std.ascii.isUpper(ch)) {
            has_upper = true;
            if (i > 0) {
                buf[len] = '_';
                len += 1;
            }
            buf[len] = std.ascii.toLower(ch);
        } else {
            buf[len] = ch;
        }
        len += 1;
    }
    if (!has_upper) return null;
    return buf[0..len];
}

/// Functions that moved or were renamed: module uri, old name, hint, and the new name when it is in the same
/// module (the fix writes it over the old name).
const moved_module_syms = [_][4][]const u8{
    .{ "os", "baseName", " Use `path.base` from `use path`.", "" },
    .{ "os", "basename", " Use `path.base` from `use path`.", "" },
    .{ "os", "base_name", " Use `path.base` from `use path`.", "" },
    .{ "os", "dirname", " Use `path.dir` from `use path`.", "" },
    .{ "os", "read_file_str", " Use `os.read_file`. It returns `str`.", "read_file" },
    .{ "os", "readFileStr", " Use `os.read_file`. It returns `str`.", "read_file" },
};

/// Hints for an argument that a std function does not take: module uri, function name, argument type, hint.
/// The function was split into a text and a bytes function, and the hint names the other one.
const call_arg_hints = [_][4][]const u8{
    .{ "os", "write_file", "[]byte", " Write bytes with `os.write_file_bytes`." },
    .{ "os", "write_file_bytes", "str", " Write text with `os.write_file`." },
};

/// Hints for a value that came from a std call and has the other type of a text and bytes pair:
/// module name as written, function name, the type that was expected, the type that was found, hint.
const result_type_hints = [_][5][]const u8{
    .{ "os", "read_file", "[]byte", "str", " `os.read_file` returns `str`. Read bytes with `os.read_file_bytes`." },
    .{ "os", "read_file_bytes", "str", "[]byte", " `os.read_file_bytes` returns `[]byte`. Read text with `os.read_file`." },
};

/// The hint from `call_arg_hints` for the argument type `arg_t` of `func`, or an empty string.
pub fn callArgHint(c: *cy.Chunk, func: *cy.Func, arg_t: *cy.Type) ![]const u8 {
    if (func.type == .userLambda) return "";
    const mod_sym = func.parent.parent orelse return "";
    if (mod_sym.type != .chunk) return "";
    const uri = mod_sym.cast(.chunk).chunk.srcUri;
    const name = func.name();
    const arg_name = try c.sema.allocTypeName(arg_t);
    defer c.alloc.free(arg_name);
    for (call_arg_hints) |hint| {
        if (std.mem.eql(u8, hint[0], uri) and std.mem.eql(u8, hint[1], name) and std.mem.eql(u8, hint[2], arg_name)) {
            return hint[3];
        }
    }
    return "";
}

/// The call that produced the value of `node`: `os.read_file(p)!`, `(…)`, or a local declared with such a call
/// (`b := os.read_file(p)!`). Returns the callee as written: `os`, `read_file`.
fn producerCall(c: *cy.Chunk, node: *ast.Node) ?struct { []const u8, []const u8 } {
    var cur = node;
    var depth: u32 = 0;
    while (depth < 8) : (depth += 1) {
        switch (cur.type()) {
            .group => cur = cur.cast(.group).child,
            .unwrap_res => cur = cur.cast(.unwrap_res).res,
            .ident => {
                if (c.semaProcs.items.len == 0) return null;
                const name = c.nodeString(cur);
                const entry = c.proc().var_cache_entries.get(name) orelse return null;
                if (entry.type != .local) return null;
                const local = &c.varStack.items[entry.data.local.varId];
                if (local.type != .local) return null;
                const inner = local.inner.local;
                if (inner.isParam or !inner.hasInit) return null;
                cur = inner.init_node orelse return null;
            },
            .callExpr => {
                const callee = cur.cast(.callExpr).callee;
                if (callee.type() != .accessExpr) return null;
                const access = callee.cast(.accessExpr);
                if (access.left.type() != .ident or access.right.type() != .ident) return null;
                return .{ c.nodeString(access.left), c.nodeString(access.right) };
            },
            else => return null,
        }
    }
    return null;
}

/// The hint from `result_type_hints` when `node` has the type `act_t` but `exp_t` was expected, or an empty string.
pub fn resultTypeHint(c: *cy.Chunk, exp_t: *cy.Type, act_t: *cy.Type, node: *ast.Node) ![]const u8 {
    const call = producerCall(c, node) orelse return "";
    const exp_name = try c.sema.allocTypeName(exp_t);
    defer c.alloc.free(exp_name);
    const act_name = try c.sema.allocTypeName(act_t);
    defer c.alloc.free(act_name);
    for (result_type_hints) |hint| {
        if (std.mem.eql(u8, hint[0], call[0]) and std.mem.eql(u8, hint[1], call[1]) and
            std.mem.eql(u8, hint[2], exp_name) and std.mem.eql(u8, hint[3], act_name)) {
            return hint[4];
        }
    }
    return "";
}

/// A hint for a symbol that the module `mod_sym` does not have: ` Did you mean `x`?`, or an empty string.
/// Like `suggestMember`, names from other languages are mapped first, then a camelCase name is tried as snake_case.
pub fn suggestModuleSym(c: *cy.Chunk, mod_sym: *cy.Sym, name: []const u8, node: *ast.Node) ![]const u8 {
    suggest_new = "";
    if (name.len == 0 or name.len > 64) return "";
    if (mod_sym.type == .chunk) {
        const uri = mod_sym.cast(.chunk).chunk.srcUri;
        for (moved_module_syms) |moved| {
            if (std.mem.eql(u8, moved[0], uri) and std.mem.eql(u8, moved[1], name)) {
                suggest_new = moved[3];
                return moved[2];
            }
        }
    }
    for (member_aliases) |alias| {
        if (std.mem.eql(u8, alias[0], name) and try c.getResolvedSym(mod_sym, alias[1], node) != null) {
            setSuggestNew("{s}", .{alias[1]});
            return std.fmt.bufPrint(&suggest_buf, " Did you mean `{s}`?", .{alias[1]}) catch "";
        }
    }
    var snake_buf: [128]u8 = undefined;
    if (toSnakeCase(name, &snake_buf)) |snake| {
        if (try c.getResolvedSym(mod_sym, snake, node) != null) {
            setSuggestNew("{s}", .{snake});
            return std.fmt.bufPrint(&suggest_buf, " Did you mean `{s}`?", .{snake}) catch "";
        }
    }
    // A symbol whose name is close, like `suggestMember`.
    const mod = mod_sym.getMod() orelse return "";
    if (closestSym(&.{mod}, name)) |cand| {
        setSuggestNew("{s}", .{cand});
        return std.fmt.bufPrint(&suggest_buf, " Did you mean `{s}`?", .{cand}) catch "";
    }
    return "";
}

/// The symbol of `mods` whose name is closest to `name`, within two edits (one for a short name).
fn closestSym(mods: []const ?*cy.Module, name: []const u8) ?[]const u8 {
    const max_dist: usize = if (name.len >= 5) 2 else if (name.len >= 3) 1 else 0;
    if (max_dist == 0) return null;
    var best: ?[]const u8 = null;
    var best_dist: usize = max_dist + 1;
    for (mods) |opt_mod| {
        const mod = opt_mod orelse continue;
        var iter = mod.symMap.iterator();
        while (iter.next()) |entry| {
            const cand = entry.key_ptr.*;
            if (cand.len == 0 or !(std.ascii.isAlphabetic(cand[0]) or cand[0] == '_')) continue;
            if (std.mem.eql(u8, cand, name)) continue;
            // An internal member (`_len`) is only suggested for a name that is written like one.
            if (cand[0] == '_' and name[0] != '_') continue;
            const d = editDistance(name, cand, best_dist) orelse continue;
            if (d < best_dist or (d == best_dist and best != null and std.mem.lessThan(u8, cand, best.?))) {
                best = cand;
                best_dist = d;
            }
        }
    }
    return best;
}

/// `suggestMember` for a field access `x.name`. A suggested method is written as a call: `len()`.
pub fn suggestField(c: *cy.Chunk, rec_t: *cy.Type, name: []const u8, node: *ast.Node) ![]const u8 {
    suggest_new = "";
    if (name.len <= 64) {
        const own_t = rec_t.getRefLikeChild() orelse rec_t;
        if (try c.accessResolvedSym(own_t, name, node)) |sym| {
            if (sym.type == .func) {
                setSuggestNew("{s}()", .{name});
                return std.fmt.bufPrint(&suggest_buf, " Did you mean the method `{s}()`?", .{name}) catch "";
            }
        }
    }
    const hint = try suggestMember(c, rec_t, name, node);
    const prefix = " Did you mean `";
    if (!std.mem.startsWith(u8, hint, prefix) or !std.mem.endsWith(u8, hint, "`?")) {
        return hint;
    }
    var target_buf: [128]u8 = undefined;
    const target_src = hint[prefix.len .. hint.len - 2];
    if (target_src.len > target_buf.len) return hint;
    @memcpy(target_buf[0..target_src.len], target_src);
    const target = target_buf[0..target_src.len];
    const base_t = rec_t.getRefLikeChild() orelse rec_t;
    const sym = (try c.accessResolvedSym(base_t, target, node)) orelse return hint;
    if (sym.type != .func) {
        return hint;
    }
    setSuggestNew("{s}()", .{target});
    return std.fmt.bufPrint(&suggest_buf, " Did you mean the method `{s}()`?", .{target}) catch "";
}

fn hasMember(c: *cy.Chunk, type_: *cy.Type, name: []const u8, node: *ast.Node) !bool {
    return (try c.accessResolvedSym(type_, name, node)) != null;
}

/// Levenshtein distance, or null when it is more than `limit`.
fn editDistance(a: []const u8, b: []const u8, limit: usize) ?usize {
    if (a.len > 64 or b.len > 64) return null;
    const diff = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (diff > limit) return null;
    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ach, i| {
        cur[0] = i + 1;
        var row_min = cur[0];
        for (b, 0..) |bch, j| {
            const cost: usize = if (std.ascii.toLower(ach) == std.ascii.toLower(bch)) 0 else 1;
            cur[j + 1] = @min(@min(prev[j + 1] + 1, cur[j] + 1), prev[j] + cost);
            row_min = @min(row_min, cur[j + 1]);
        }
        if (row_min > limit) return null;
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return if (prev[b.len] <= limit) prev[b.len] else null;
}

/// Code that the script wrote for one type: not a builtin module and not an instance of a generic function or
/// of a template's method, whose `T` can be a `!T` without the writer knowing (`test.eq`).
pub fn inGenericCode(c: *cy.Chunk) bool {
    if (c.is_builtin) return true;
    var i = c.semaProcs.items.len;
    while (i > 0) {
        i -= 1;
        const func = c.semaProcs.items[i].func orelse continue;
        if (func.instance != null) return true;
        if (func.parent.getStaticType()) |parent_t| {
            if (parent_t.sym().instance != null) return true;
        }
    }
    return false;
}

/// `print(f())` where `f` returns `!T` is a compile error at the call: the value has to be unwrapped first.
pub fn checkPrintCall(c: *cy.Chunk, func_sym: *cy.sym.FuncSym, func: *cy.Func, node: *ast.Node) !void {
    if (inGenericCode(c)) return;
    for (c.sema.print_syms) |sym| {
        if (sym != func_sym) continue;
        const params = func.sig.params();
        if (params.len != 1) return;
        const arg_t = params[0].get_type();
        if (arg_t.kind() != .result) return;
        const type_name = try c.sema.allocTypeName(arg_t);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("Can not print `{}`. Unwrap it with `!` first, or handle the error with `!else` or `try`.", &.{v(type_name)}, node);
    }
}

/// Reports a `Scope.start` whose arguments hold a borrow, unless it is the call that `semaScopeStart` checks.
pub fn checkScopeStartCall(c: *cy.Chunk, func: *cy.Func, node: *ast.Node) !void {
    if (c.scope_start_call == node) return;
    const params = func.sig.params();
    // A `FnTuple` is not marked as a borrow container (`reifyStructType`), so its fields are looked at.
    const args_t = params[params.len - 1].get_type();
    for (args_t.cast(.struct_t).fields()) |field| {
        if (!field.type.info.borrow_only) continue;
        const type_name = try c.sema.allocTypeName(field.type);
        defer c.alloc.free(type_name);
        return c.reportErrorFmt("Cannot borrow a stack value across fibers. The parameter type is `{}`. Only `s.start(func, {...})` on the name of a `scope |s|:` block takes a borrow. Use `^T`.", &.{v(type_name)}, node);
    }
}
