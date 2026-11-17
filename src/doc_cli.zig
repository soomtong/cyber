//! `cyber doc`. Prints the manual (`docs/docs.md`) and the guide for agents (`docs/agent-guide.md`) that are embedded
//! in the executable, so the text always matches the `cyber` that prints it.

const std = @import("std");
const stdx = @import("stdx");
const C = @import("capi.zig");
const cli = @import("cli.zig");

pub const docs_md = @embedFile("docs_md");
pub const agents_md = @embedFile("agents_md");
/// `docs/api.json` without whitespace: the functions and types of the core and std modules.
pub const api_json = @embedFile("api_json");

pub const usage =
    \\Usage: cyber doc [topic]
    \\       cyber doc --list
    \\       cyber doc --for-agents
    \\       cyber doc --api [module]
    \\
    \\Prints the manual of this version of Cyber.
    \\A topic is a section id such as `optionals` or `for-range`, the same id
    \\as the anchor of the section on the docs site. A part of an id also works
    \\when only one section matches it.
    \\
    \\Options:
    \\  --list        List every section id, indented by level.
    \\  --for-agents  Print a short guide for coding agents and the topic index.
    \\  --api [module]
    \\                Print the functions and types of a module with their
    \\                signatures, or list the modules without a module name.
    \\  --help        Print this usage.
    \\
;

pub const Heading = struct {
    level: u8,
    /// The heading text without the `#` marks.
    title: []const u8,
    /// The same id as `docs/gen-docs.cy` gives the section: `basic-types`, `var-declaration`, `wrap-none`.
    id: []const u8,
    /// Byte range of the section in the source: from the heading line to the next heading of the same or a higher level.
    start: usize,
    end: usize,
};

pub const Toc = struct {
    alloc: std.mem.Allocator,
    headings: []Heading,

    pub fn deinit(self: *Toc) void {
        for (self.headings) |h| {
            self.alloc.free(h.id);
        }
        self.alloc.free(self.headings);
    }

    pub fn find(self: *const Toc, id: []const u8) ?*const Heading {
        for (self.headings) |*h| {
            if (std.mem.eql(u8, h.id, id)) return h;
        }
        return null;
    }
};

/// Reads the headings of a Markdown source. Lines inside fenced code blocks are skipped.
pub fn parseToc(alloc: std.mem.Allocator, src: []const u8) !Toc {
    var headings: std.ArrayList(Heading) = .empty;
    errdefer {
        for (headings.items) |h| alloc.free(h.id);
        headings.deinit(alloc);
    }
    var id_counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer id_counts.deinit(alloc);

    var fence: ?u8 = null;
    var pos: usize = 0;
    while (pos < src.len) {
        const line_end = std.mem.indexOfScalarPos(u8, src, pos, '\n') orelse src.len;
        const line = std.mem.trimEnd(u8, src[pos..line_end], "\r");
        const line_start = pos;
        pos = @min(line_end + 1, src.len);

        if (line.len >= 3 and (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~"))) {
            if (fence) |f| {
                if (line[0] == f) fence = null;
            } else {
                fence = line[0];
            }
            continue;
        }
        if (fence != null) continue;

        var level: u8 = 0;
        while (level < line.len and line[level] == '#') level += 1;
        if (level == 0 or level > 6 or level >= line.len or line[level] != ' ') continue;

        const title = std.mem.trim(u8, line[level..], " \t");
        var id = try headingId(alloc, title);
        if (id_counts.getPtr(id)) |count| {
            const numbered = std.fmt.allocPrint(alloc, "{s}-{}", .{ id, count.* }) catch |err| {
                alloc.free(id);
                return err;
            };
            count.* += 1;
            alloc.free(id);
            id = numbered;
        } else {
            // The key is the first occurrence's id, which `headings` owns.
            id_counts.put(alloc, id, 1) catch |err| {
                alloc.free(id);
                return err;
            };
        }
        errdefer alloc.free(id);
        try headings.append(alloc, .{ .level = level, .title = title, .id = id, .start = line_start, .end = src.len });
    }

    // A section ends where the next heading of the same or a higher level starts.
    const items = headings.items;
    for (items, 0..) |*h, i| {
        for (items[i + 1 ..]) |next| {
            if (next.level <= h.level) {
                h.end = next.start;
                break;
            }
        }
    }
    return .{ .alloc = alloc, .headings = try headings.toOwnedSlice(alloc) };
}

/// The rule of `docs/gen-docs.cy`: the text of the heading (Markdown marks such as backticks are not text), spaces
/// become `-`, the characters `./$[]#` are removed, then lower case. A repeated id gets `-1`, `-2` and so on.
fn headingId(alloc: std.mem.Allocator, title: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (title) |ch| {
        switch (ch) {
            '`', '*', '.', '/', '$', '[', ']', '#' => {},
            ' ' => try out.append(alloc, '-'),
            else => try out.append(alloc, std.ascii.toLower(ch)),
        }
    }
    return out.toOwnedSlice(alloc);
}

const Lookup = union(enum) {
    found: *const Heading,
    none,
    /// Several ids contain the query and none is equal to it.
    ambiguous: []*const Heading,
};

fn lookup(alloc: std.mem.Allocator, toc: *const Toc, query: []const u8) !Lookup {
    const norm = try headingId(alloc, query);
    defer alloc.free(norm);
    // Nothing is left of `.` or of an empty topic, and every id contains that.
    if (norm.len == 0) return .none;
    if (toc.find(norm)) |h| return .{ .found = h };

    var matches: std.ArrayList(*const Heading) = .empty;
    errdefer matches.deinit(alloc);
    for (toc.headings) |*h| {
        if (std.mem.indexOf(u8, h.id, norm) != null) {
            try matches.append(alloc, h);
        }
    }
    switch (matches.items.len) {
        0 => {
            matches.deinit(alloc);
            return .none;
        },
        1 => {
            const h = matches.items[0];
            matches.deinit(alloc);
            return .{ .found = h };
        },
        else => return .{ .ambiguous = try matches.toOwnedSlice(alloc) },
    }
}

/// The text of a section, without the `[^top](...)` links that only make sense on the site.
fn writeSection(alloc: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8, h: *const Heading) !void {
    var it = std.mem.splitScalar(u8, src[h.start..h.end], '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "[^top](")) continue;
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    // One new line at the end, however many blank lines the section ended with.
    while (out.items.len >= 2 and out.items[out.items.len - 1] == '\n' and out.items[out.items.len - 2] == '\n') {
        out.items.len -= 1;
    }
}

fn writeList(alloc: std.mem.Allocator, out: *std.ArrayList(u8), toc: *const Toc) !void {
    for (toc.headings) |h| {
        if (std.mem.eql(u8, h.id, "table-of-contents")) continue;
        try out.appendNTimes(alloc, ' ', (h.level - 1) * 2);
        try out.appendSlice(alloc, h.id);
        try out.append(alloc, '\n');
    }
}

/// The level 1 sections, each with the ids of its level 2 sections on one line.
fn writeIndex(alloc: std.mem.Allocator, out: *std.ArrayList(u8), toc: *const Toc) !void {
    var first = true;
    for (toc.headings) |h| {
        if (h.level > 2 or std.mem.eql(u8, h.id, "table-of-contents")) continue;
        if (h.level == 1) {
            if (!first) try out.append(alloc, '\n');
            first = false;
            try out.print(alloc, "- {s}:", .{h.id});
        } else {
            try out.print(alloc, " {s}", .{h.id});
        }
    }
    if (!first) try out.append(alloc, '\n');
}

pub fn forAgents(alloc: std.mem.Allocator, out: *std.ArrayList(u8), version: []const u8, toc: *const Toc) !void {
    try out.print(alloc, "<!-- Printed by `cyber doc --for-agents`. Cyber {s} -->\n\n", .{version});
    try out.appendSlice(alloc, agents_md);
    if (!std.mem.endsWith(u8, agents_md, "\n")) try out.append(alloc, '\n');
    try out.appendSlice(alloc,
        \\
        \\## Topics
        \\
        \\Run `cyber doc <id>` to read a section of the manual, `cyber doc --list` for every id.
        \\Each line is a chapter followed by the ids of its sections.
        \\
        \\
    );
    try writeIndex(alloc, out, toc);
}

/// Runs `cyber doc` with the arguments after `doc`. Returns the exit code.
pub fn main(alloc: std.mem.Allocator, args: []const []const u8, version: []const u8) !u8 {
    var toc = try parseToc(alloc, docs_md);
    defer toc.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const query = switch (parseArgs(args)) {
        .help => return write(usage),
        .for_agents => {
            try forAgents(alloc, &out, version, &toc);
            return write(out.items);
        },
        .list => {
            try writeList(alloc, &out, &toc);
            return write(out.items);
        },
        .index => {
            try out.appendSlice(alloc, usage);
            try out.appendSlice(alloc, "\nTopics:\n");
            try writeIndex(alloc, &out, &toc);
            return write(out.items);
        },
        .api => |module| {
            if (!try apiText(alloc, &out, version, module)) {
                std.debug.print("error: no module `{s}`. Run `cyber doc --api` for the list.\n", .{module});
                return 1;
            }
            return write(out.items);
        },
        .topic => |topic| topic,
        .unknown_option => |arg| {
            std.debug.print("error: unknown option `{s}`\n\n{s}", .{ arg, usage });
            return 2;
        },
        .two_topics => |pair| {
            std.debug.print("error: expected one topic, found `{s}` after `{s}`\n\n{s}", .{ pair[1], pair[0], usage });
            return 2;
        },
        .conflict => |pair| {
            std.debug.print("error: `{s}` can not be used with `{s}`\n\n{s}", .{ pair[1], pair[0], usage });
            return 2;
        },
    };
    switch (try lookup(alloc, &toc, query)) {
        .found => |h| {
            try writeSection(alloc, &out, docs_md, h);
            return write(out.items);
        },
        .none => {
            std.debug.print("error: no section matches `{s}`. Run `cyber doc --list` for every id.\n", .{query});
            return 1;
        },
        .ambiguous => |list| {
            defer alloc.free(list);
            std.debug.print("error: `{s}` matches {} sections. Use one of the ids:\n", .{ query, list.len });
            for (list) |h| {
                std.debug.print("  {s}\n", .{h.id});
            }
            return 1;
        },
    }
}

const Command = union(enum) {
    help,
    for_agents,
    list,
    /// `--api` with the module name, or "" for the list of modules.
    api: []const u8,
    /// No argument: the usage and the topic index.
    index,
    topic: []const u8,
    unknown_option: []const u8,
    two_topics: [2][]const u8,
    /// An option together with a topic or with another option, in the order they were given.
    conflict: [2][]const u8,
};

/// Every argument is read before one is acted on, so a wrong argument after `--list` is an error too.
/// `--help` goes before the other errors, an unknown option before a conflict.
fn parseArgs(args: []const []const u8) Command {
    var help = false;
    // The topic or the option that says what to print, with the argument that gave it.
    var cmd: ?Command = null;
    var cmd_arg: []const u8 = "";
    var err: ?Command = null;
    for (args) |arg| {
        var next: Command = undefined;
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--for-agents")) {
            next = .for_agents;
        } else if (std.mem.eql(u8, arg, "--list")) {
            next = .list;
        } else if (std.mem.eql(u8, arg, "--api")) {
            next = .{ .api = "" };
        } else if (arg.len > 0 and arg[0] == '-') {
            return .{ .unknown_option = arg };
        } else {
            next = .{ .topic = arg };
        }
        if (cmd) |cur| {
            // `--api json` (or `json --api`): the topic is the module.
            if (cur == .api and cur.api.len == 0 and next == .topic) {
                cmd = .{ .api = next.topic };
                continue;
            }
            if (cur == .topic and next == .api and next.api.len == 0) {
                cmd = .{ .api = cur.topic };
                continue;
            }
            if (err == null) {
                err = if (cur == .topic and next == .topic)
                    .{ .two_topics = .{ cmd_arg, arg } }
                else
                    .{ .conflict = .{ cmd_arg, arg } };
            }
            continue;
        }
        cmd = next;
        cmd_arg = arg;
    }
    if (help) return .help;
    if (err) |e| return e;
    return cmd orelse .index;
}

/// `cyber doc --api [module]`. Prints the entries of `docs/api.json` for one module: its functions, then its types
/// with their methods (`fn (&T) m(...)`) and type functions (`fn T :: f(...)`). Each signature is followed by the
/// first line of its doc. Without a module, lists the modules.
/// Returns false for a module that has no entry.
fn apiText(alloc: std.mem.Allocator, out: *std.ArrayList(u8), version: []const u8, module: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, api_json, .{});
    defer parsed.deinit();
    const types = parsed.value.object.get("types").?.array.items;
    const funcs = parsed.value.object.get("funcs").?.array.items;

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);
    for ([_][]const std.json.Value{ funcs, types }) |list| {
        for (list) |e| {
            const m = str(e, "module");
            for (names.items) |n| {
                if (std.mem.eql(u8, n, m)) break;
            } else try names.append(alloc, m);
        }
    }

    if (module.len == 0) {
        try out.print(alloc, "Modules of Cyber {s}. Run `cyber doc --api <module>` for the functions and types of one.\n\n", .{version});
        for (names.items) |n| {
            try out.print(alloc, "  {s}: {} functions, {} types\n", .{ n, countIn(funcs, n), countIn(types, n) });
        }
        return true;
    }
    for (names.items) |n| {
        if (std.mem.eql(u8, n, module)) break;
    } else return false;

    try out.print(alloc, "-- Module `{s}` of Cyber {s}: {} functions, {} types.\n\n", .{ module, version, countIn(funcs, module), countIn(types, module) });
    for (funcs) |f| {
        if (!std.mem.eql(u8, str(f, "module"), module)) continue;
        try out.appendSlice(alloc, "fn ");
        try writeSig(alloc, out, f);
    }
    for (types) |ty| {
        if (!std.mem.eql(u8, str(ty, "module"), module)) continue;
        try out.print(alloc, "\ntype {s}{s}", .{ str(ty, "syntax"), str(ty, "tparams") });
        if (str(ty, "kind").len > 0) try out.print(alloc, "  ({s})", .{str(ty, "kind")});
        try out.append(alloc, '\n');
        try writeDoc(alloc, out, str(ty, "doc"), "    ");
        for (ty.object.get("funcs").?.array.items) |f| {
            try out.print(alloc, "  fn {s} :: ", .{str(ty, "name")});
            try writeSig(alloc, out, f);
        }
        for (ty.object.get("methods").?.array.items) |f| {
            try out.print(alloc, "  fn ({s}) ", .{str(f, "recv")});
            try writeSig(alloc, out, f);
        }
    }
    return true;
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    const field = v.object.get(key) orelse return "";
    return switch (field) {
        .string => |s| s,
        else => "",
    };
}

fn countIn(list: []const std.json.Value, module: []const u8) usize {
    var n: usize = 0;
    for (list) |e| {
        if (std.mem.eql(u8, str(e, "module"), module)) n += 1;
    }
    return n;
}

/// `name[tparams](params) -> ret  #[cond=...]`, then the first line of the doc.
fn writeSig(alloc: std.mem.Allocator, out: *std.ArrayList(u8), f: std.json.Value) !void {
    const sig = str(f, "sig");
    const name = str(f, "name");
    if (std.mem.startsWith(u8, sig, name)) {
        try out.print(alloc, "{s}{s}{s}", .{ name, str(f, "tparams"), sig[name.len..] });
    } else {
        try out.appendSlice(alloc, sig);
    }
    if (str(f, "cond").len > 0) try out.print(alloc, "  #[cond={s}]", .{str(f, "cond")});
    try out.append(alloc, '\n');
    try writeDoc(alloc, out, str(f, "doc"), "        ");
}

fn writeDoc(alloc: std.mem.Allocator, out: *std.ArrayList(u8), doc: []const u8, indent: []const u8) !void {
    if (doc.len == 0) return;
    const line = doc[0 .. std.mem.indexOfScalar(u8, doc, '\n') orelse doc.len];
    try out.print(alloc, "{s}{s}\n", .{ indent, line });
}

fn write(bytes: []const u8) !u8 {
    try std.Io.File.stdout().writeStreamingAll(stdx.io(), bytes);
    return 0;
}

const t = std.testing;

test "doc: ids follow the docs site." {
    var toc = try parseToc(t.allocator, docs_md);
    defer toc.deinit();

    try t.expect(toc.find("basic-types") != null);
    try t.expect(toc.find("var-declaration") != null);
    try t.expect(toc.find("format-source") != null);
    // `#` lines inside code blocks are not headings.
    for (toc.headings) |h| {
        try t.expect(h.title.len > 0);
    }
    // Every id is unique, as the anchors on the site.
    for (toc.headings, 0..) |a, i| {
        for (toc.headings[i + 1 ..]) |b| {
            try t.expect(!std.mem.eql(u8, a.id, b.id));
        }
    }
}

test "doc: a section ends at the next heading of the same level." {
    const src =
        \\# A.
        \\text a
        \\## `b` one.
        \\```
        \\# not a heading
        \\```
        \\### C.
        \\## B one.
        \\# D.
        \\
    ;
    var toc = try parseToc(t.allocator, src);
    defer toc.deinit();

    try t.expectEqual(@as(usize, 5), toc.headings.len);
    try t.expectEqualStrings("b-one", toc.headings[1].id);
    try t.expectEqualStrings("b-one-1", toc.headings[3].id);
    const b = toc.headings[1];
    try t.expectEqualStrings("## `b` one.\n```\n# not a heading\n```\n### C.\n", src[b.start..b.end]);
    try t.expectEqual(src.len, toc.headings[4].end);
}

test "doc: lookup by id, by title and by a unique part." {
    var toc = try parseToc(t.allocator, docs_md);
    defer toc.deinit();

    switch (try lookup(t.allocator, &toc, "Optionals.")) {
        .found => |h| try t.expectEqualStrings("optionals", h.id),
        else => return error.TestUnexpectedResult,
    }
    switch (try lookup(t.allocator, &toc, "for-range")) {
        .found => |h| try t.expectEqualStrings("for-range", h.id),
        else => return error.TestUnexpectedResult,
    }
    switch (try lookup(t.allocator, &toc, "unwrap")) {
        .ambiguous => |list| {
            defer t.allocator.free(list);
            try t.expect(list.len > 1);
        },
        else => return error.TestUnexpectedResult,
    }
    try t.expect(try lookup(t.allocator, &toc, "no-such-topic-xyz") == .none);
    // A topic that has no id character matches nothing, not every section.
    try t.expect(try lookup(t.allocator, &toc, "") == .none);
    try t.expect(try lookup(t.allocator, &toc, ".") == .none);
    try t.expect(try lookup(t.allocator, &toc, "`") == .none);
}

test "doc: every argument is checked." {
    try t.expect(parseArgs(&.{}) == .index);
    try t.expect(parseArgs(&.{"--list"}) == .list);
    try t.expect(parseArgs(&.{"--for-agents"}) == .for_agents);
    try t.expectEqualStrings("optionals", parseArgs(&.{"optionals"}).topic);
    // An empty topic is a topic: it matches no section.
    try t.expectEqualStrings("", parseArgs(&.{""}).topic);

    // A wrong argument after an option is not skipped.
    try t.expectEqualStrings("--bogus", parseArgs(&.{ "--for-agents", "--bogus" }).unknown_option);
    try t.expectEqualStrings("--bogus", parseArgs(&.{ "--bogus", "--for-agents" }).unknown_option);
    try t.expectEqualStrings("--list", parseArgs(&.{ "optionals", "--list" }).conflict[1]);
    try t.expectEqualStrings("optionals", parseArgs(&.{ "--list", "optionals" }).conflict[1]);
    try t.expect(parseArgs(&.{ "--list", "--for-agents" }) == .conflict);
    try t.expect(parseArgs(&.{ "--list", "--list" }) == .conflict);
    try t.expectEqualStrings("b", parseArgs(&.{ "a", "b" }).two_topics[1]);

    try t.expectEqualStrings("", parseArgs(&.{"--api"}).api);
    try t.expectEqualStrings("json", parseArgs(&.{ "--api", "json" }).api);
    try t.expectEqualStrings("json", parseArgs(&.{ "json", "--api" }).api);
    try t.expectEqualStrings("b", parseArgs(&.{ "--api", "a", "b" }).conflict[1]);
    try t.expect(parseArgs(&.{ "--api", "--list" }) == .conflict);

    try t.expect(parseArgs(&.{ "optionals", "--list", "--help" }) == .help);
    try t.expectEqualStrings("--bogus", parseArgs(&.{ "--help", "--bogus" }).unknown_option);
}

test "doc: the guide for agents lists the topics." {
    var toc = try parseToc(t.allocator, docs_md);
    defer toc.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try forAgents(t.allocator, &out, "0.0.0", &toc);
    try t.expect(std.mem.indexOf(u8, out.items, "Cyber 0.0.0") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "- basic-types: ") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "table-of-contents") == null);
}

fn quietPrint(_: ?*C.Thread, _: C.Bytes) callconv(.c) void {}

test "doc: every example of the guide for agents runs." {
    var fence: ?usize = null;
    var num: usize = 0;
    var failed: usize = 0;
    var pos: usize = 0;
    while (pos < agents_md.len) {
        const line_end = std.mem.indexOfScalarPos(u8, agents_md, pos, '\n') orelse agents_md.len;
        const line = agents_md[pos..line_end];
        const next = @min(line_end + 1, agents_md.len);
        if (fence) |start| {
            if (std.mem.eql(u8, line, "~~~")) {
                fence = null;
                num += 1;
                const vm = C.vm_initx(t.allocator);
                defer C.vm_deinit(vm);
                try cli.init_cli(vm, t.allocator);
                defer cli.deinit_cli(vm);
                C.vm_set_printer(vm, quietPrint);
                // The example is an in-memory chunk, not a file, so the resolver must not `realpath` its uri.
                const app: *cli.App = @ptrCast(@alignCast(C.vm_user_data(vm)));
                try app.mod_uris.putNoClobber(t.allocator, "main", "main");

                var res: C.EvalResult = undefined;
                const code = C.vm_evalx(vm, "main", agents_md[start..pos], C.defaultEvalConfig(), &res);
                if (code != C.Success) {
                    failed += 1;
                    const report = if (code == C.ErrorCompile)
                        C.vm_compile_error_summary(vm)
                    else
                        C.thread_panic_summary(C.vm_main_thread(vm));
                    defer C.vm_freeb(vm, report);
                    std.debug.print("docs/agent-guide.md example {} failed:\n{s}\n", .{ num, report });
                }
            }
        } else if (std.mem.eql(u8, line, "~~~cy")) {
            fence = next;
        }
        pos = next;
    }
    try t.expect(num >= 10);
    try t.expectEqual(@as(usize, 0), failed);
}

test "doc: --api prints a module of the embedded api.json." {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try t.expect(try apiText(t.allocator, &out, "test", "json"));
    try t.expect(std.mem.startsWith(u8, out.items, "-- Module `json` of Cyber test: "));
    try t.expect(std.mem.indexOf(u8, out.items, "\nfn parse(src str) -> !Value\n") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "\ntype Value  (choice)\n") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "\n  fn (&Value) get(key str) -> ?Value\n") != null);

    out.clearRetainingCapacity();
    try t.expect(try apiText(t.allocator, &out, "test", ""));
    for ([_][]const u8{ "json", "toon", "regex", "peg", "time", "math", "path" }) |m| {
        var buf: [32]u8 = undefined;
        try t.expect(std.mem.indexOf(u8, out.items, try std.fmt.bufPrint(&buf, "\n  {s}: ", .{m})) != null);
    }
    try t.expect(!try apiText(t.allocator, &out, "test", "nope"));
}
