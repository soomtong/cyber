//! The files of the workspace. The server has no index: a request that needs every source lists the folders
//! again, so that it sees the files as they are. Parsing or compiling them is what costs, and the caller
//! narrows the list before that.

const std = @import("std");
const stdx = @import("stdx");

/// A workspace with more sources than this is searched up to here. A request should stay interactive.
pub const max_files = 2000;

pub const max_file_size = 1 << 22;

/// Directories that hold no sources of the project: hidden ones (`.git`, `.zig-cache`), build output and
/// dependencies.
pub fn skipDir(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    const skipped = [_][]const u8{ "node_modules", "zig-out", "zig-cache", "zig-pkg" };
    for (skipped) |dir| {
        if (std.mem.eql(u8, name, dir)) return true;
    }
    return false;
}

/// Directories that one listing visits at most, and how deep it goes. A workspace folder can be a home
/// directory or `/`: the listing has to end, and the server answers nothing else while it runs.
pub const max_dirs = 5000;
pub const max_depth = 24;

pub const Budget = struct {
    dirs: usize = 0,
};

/// Appends the paths of the `.cy` files below `root` to `files`, up to `max_files` in all and within `budget`.
/// A directory that can not be read is skipped. Symbolic links are not followed. The paths are allocated in
/// `arena`.
pub fn collectFiles(arena: std.mem.Allocator, root: []const u8, files: *std.ArrayList([]const u8), budget: *Budget, depth: usize) !void {
    if (files.items.len >= max_files or budget.dirs >= max_dirs or depth > max_depth) return;
    budget.dirs += 1;
    const io = stdx.io();
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var found: std.ArrayList([]const u8) = .empty;
    var subdirs: std.ArrayList([]const u8) = .empty;
    var iter = dir.iterate();
    while (true) {
        const entry = (iter.next(io) catch break) orelse break;
        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".cy")) {
                    try found.append(arena, try std.Io.Dir.path.join(arena, &.{ root, entry.name }));
                }
            },
            .directory => {
                if (!skipDir(entry.name)) {
                    try subdirs.append(arena, try std.Io.Dir.path.join(arena, &.{ root, entry.name }));
                }
            },
            else => {},
        }
    }
    // The order of a directory listing is not defined. Sorted, the result is the same on every run.
    std.mem.sort([]const u8, found.items, {}, lessThan);
    std.mem.sort([]const u8, subdirs.items, {}, lessThan);
    for (found.items) |file| {
        if (files.items.len >= max_files) break;
        try files.append(arena, file);
    }
    // Recurse after the iteration so that only one directory handle is open per level at a time.
    for (subdirs.items) |subdir| {
        try collectFiles(arena, subdir, files, budget, depth + 1);
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub fn readFile(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(stdx.io(), path, arena, .limited(max_file_size)) catch null;
}

/// Whether `text` has `name` as a whole word. A source that does not can not refer to a symbol of that name,
/// and does not have to be compiled to find out.
pub fn hasWord(text: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var pos: usize = 0;
    while (std.mem.findPos(u8, text, pos, name)) |at| {
        const before = at == 0 or !isIdent(text[at - 1]);
        const after = at + name.len >= text.len or !isIdent(text[at + name.len]);
        if (before and after) return true;
        pos = at + 1;
    }
    return false;
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Whether `name` has the letters of `query` in order, without regard to case: `vsc` finds `Vec2.scale`.
/// An empty query finds everything.
pub fn matches(name: []const u8, query: []const u8) bool {
    var i: usize = 0;
    for (query) |q| {
        while (i < name.len and std.ascii.toLower(name[i]) != std.ascii.toLower(q)) i += 1;
        if (i == name.len) return false;
        i += 1;
    }
    return true;
}

test "Words and queries." {
    const t = std.testing;
    try t.expect(hasWord("x := add(1, 2)", "add"));
    try t.expect(hasWord("add", "add"));
    try t.expect(!hasWord("x := addr(1)", "add"));
    try t.expect(!hasWord("x := my_add(1)", "add"));
    try t.expect(hasWord("pad add2 add", "add"));
    try t.expect(!hasWord("x", ""));

    try t.expect(matches("Vec2.scale", "vsc"));
    try t.expect(matches("Vec2.scale", "SCALE"));
    try t.expect(matches("add", ""));
    try t.expect(!matches("add", "adds"));
    try t.expect(!matches("scale", "sv"));

    try t.expect(skipDir(".git"));
    try t.expect(skipDir("node_modules"));
    try t.expect(!skipDir("src"));
}
