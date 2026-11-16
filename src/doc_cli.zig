//! `cyber doc`. Prints the manual (`docs/docs.md`) and the guide for agents (`docs/agents.md`) that are embedded
//! in the executable, so the text always matches the `cyber` that prints it.

const std = @import("std");
const stdx = @import("stdx");
const C = @import("capi.zig");
const cli = @import("cli.zig");

pub const docs_md = @embedFile("docs_md");
pub const agents_md = @embedFile("agents_md");

pub const usage =
    \\Usage: cyber doc [topic]
    \\       cyber doc --list
    \\       cyber doc --for-agents
    \\
    \\Prints the manual of this version of Cyber.
    \\A topic is a section id such as `optionals` or `for-range`, the same id
    \\as the anchor of the section on the docs site. A part of an id also works
    \\when only one section matches it.
    \\
    \\Options:
    \\  --list        List every section id, indented by level.
    \\  --for-agents  Print a short guide for coding agents and the topic index.
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

    var topic: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--for-agents")) {
            try forAgents(alloc, &out, version, &toc);
            return write(out.items);
        } else if (std.mem.eql(u8, arg, "--list")) {
            try writeList(alloc, &out, &toc);
            return write(out.items);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return write(usage);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown option `{s}`\n\n{s}", .{ arg, usage });
            return 2;
        } else if (topic != null) {
            std.debug.print("error: expected one topic, found `{s}` after `{s}`\n\n{s}", .{ arg, topic.?, usage });
            return 2;
        } else {
            topic = arg;
        }
    }

    const query = topic orelse {
        try out.appendSlice(alloc, usage);
        try out.appendSlice(alloc, "\nTopics:\n");
        try writeIndex(alloc, &out, &toc);
        return write(out.items);
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
                    std.debug.print("docs/agents.md example {} failed:\n{s}\n", .{ num, report });
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
