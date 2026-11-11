//! `cyber fmt`. A thin shell over `format.zig`.

const std = @import("std");
const stdx = @import("stdx");
const format = @import("format.zig");

const max_source_size = 1 << 24;

const Mode = enum {
    /// Rewrite files that change and print their paths.
    write,
    /// Print the paths of files that would change. Exit with 1 if there are any.
    check,
    /// Print the formatted source.
    stdout,
};

const State = struct {
    alloc: std.mem.Allocator,
    mode: Mode = .write,
    num_changed: u32 = 0,
    num_failed: u32 = 0,
};

pub const usage =
    \\Usage: cyber fmt [options] [path...]
    \\
    \\Reformats Cyber source files in place and prints the paths that changed.
    \\A directory is searched for `.cy` files. Without a path, or with `-`,
    \\the source is read from stdin and the result is written to stdout.
    \\
    \\Options:
    \\  --check   Do not write. Print the paths that would change and exit with 1 if there are any.
    \\  --stdout  Write the result to stdout instead of the file.
    \\  -h, --help
    \\
;

/// Returns the process exit code.
pub fn main(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    var state = State{ .alloc = alloc };
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(alloc);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            state.mode = .check;
        } else if (std.mem.eql(u8, arg, "--stdout")) {
            state.mode = .stdout;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (arg.len > 1 and arg[0] == '-') {
            std.debug.print("error: unknown option `{s}`\n\n{s}", .{ arg, usage });
            return 2;
        } else {
            try paths.append(alloc, arg);
        }
    }

    if (paths.items.len == 0) {
        try paths.append(alloc, "-");
    }
    for (paths.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try formatStdin(&state);
        } else {
            try formatPath(&state, path);
        }
    }

    if (state.num_failed > 0) {
        return 1;
    }
    if (state.mode == .check and state.num_changed > 0) {
        return 1;
    }
    return 0;
}

fn formatStdin(state: *State) !void {
    const io = stdx.io();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(state.alloc);

    const stdin = std.Io.File.stdin();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stdin.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) {
            break;
        }
        try src.appendSlice(state.alloc, buf[0..n]);
    }

    const out = (try formatSource(state, "<stdin>", src.items)) orelse return;
    defer state.alloc.free(out);
    const changed = !std.mem.eql(u8, out, src.items);
    if (changed) {
        state.num_changed += 1;
    }
    if (state.mode != .check) {
        try std.Io.File.stdout().writeStreamingAll(io, out);
    } else if (changed) {
        try printLine(state.alloc, "<stdin>");
    }
}

fn formatPath(state: *State, path: []const u8) !void {
    const io = stdx.io();
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io, path, .{}) catch |err| {
        reportIoError(state, path, err);
        return;
    };
    if (stat.kind != .directory) {
        return formatFile(state, path);
    }

    // Collect first so that rewriting does not disturb the directory iteration.
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |file| {
            state.alloc.free(file);
        }
        files.deinit(state.alloc);
    }
    try collectFiles(state, path, &files);
    std.mem.sort([]const u8, files.items, {}, lessThan);

    for (files.items) |file| {
        try formatFile(state, file);
    }
}

/// Directories that a search does not enter. A path that is named on the command line is always searched.
fn skipDir(name: []const u8) bool {
    if (name.len > 0 and name[0] == '.') {
        // `.git`, `.zig-cache`, editor and tool state.
        return true;
    }
    return std.mem.eql(u8, name, "zig-out") or std.mem.eql(u8, name, "node_modules");
}

/// Appends the `.cy` files below `dir_path`. An unreadable directory is reported and skipped,
/// the rest of the tree is still searched. Symbolic links are not followed.
fn collectFiles(state: *State, dir_path: []const u8, files: *std.ArrayList([]const u8)) !void {
    const io = stdx.io();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        reportIoError(state, dir_path, err);
        return;
    };
    defer dir.close(io);

    var subdirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (subdirs.items) |subdir| {
            state.alloc.free(subdir);
        }
        subdirs.deinit(state.alloc);
    }

    var iter = dir.iterate();
    while (true) {
        const entry = (iter.next(io) catch |err| {
            reportIoError(state, dir_path, err);
            break;
        }) orelse break;
        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".cy")) {
                    const file = try std.fs.path.join(state.alloc, &.{ dir_path, entry.name });
                    errdefer state.alloc.free(file);
                    try files.append(state.alloc, file);
                }
            },
            .directory => {
                if (!skipDir(entry.name)) {
                    const subdir = try std.fs.path.join(state.alloc, &.{ dir_path, entry.name });
                    errdefer state.alloc.free(subdir);
                    try subdirs.append(state.alloc, subdir);
                }
            },
            else => {},
        }
    }
    // Recurse after the iteration so that only one directory handle is open per level at a time.
    for (subdirs.items) |subdir| {
        try collectFiles(state, subdir, files);
    }
}

fn reportIoError(state: *State, path: []const u8, err: anyerror) void {
    std.debug.print("{s}: error: {s}\n", .{ path, @errorName(err) });
    state.num_failed += 1;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn formatFile(state: *State, path: []const u8) !void {
    const io = stdx.io();
    const cwd = std.Io.Dir.cwd();
    const src = cwd.readFileAlloc(io, path, state.alloc, .limited(max_source_size)) catch |err| {
        reportIoError(state, path, err);
        return;
    };
    defer state.alloc.free(src);

    const out = (try formatSource(state, path, src)) orelse return;
    defer state.alloc.free(out);

    const changed = !std.mem.eql(u8, out, src);
    switch (state.mode) {
        .stdout => {
            if (changed) {
                state.num_changed += 1;
            }
            try std.Io.File.stdout().writeStreamingAll(io, out);
        },
        .check => {
            if (changed) {
                state.num_changed += 1;
                try printLine(state.alloc, path);
            }
        },
        .write => {
            if (!changed) {
                return;
            }
            // Write through the existing file instead of renaming a new file over it. The file keeps its
            // identity: a symbolic link still points at its target (the target is rewritten), hard links
            // stay linked, the permission bits stay, and a read-only file is refused.
            cwd.writeFile(io, .{ .sub_path = path, .data = out }) catch |err| {
                reportIoError(state, path, err);
                return;
            };
            state.num_changed += 1;
            try printLine(state.alloc, path);
        },
    }
}

fn printLine(alloc: std.mem.Allocator, text: []const u8) !void {
    const line = try std.fmt.allocPrint(alloc, "{s}\n", .{text});
    defer alloc.free(line);
    try std.Io.File.stdout().writeStreamingAll(stdx.io(), line);
}

/// Returns null after reporting the error to stderr.
fn formatSource(state: *State, name: []const u8, src: []const u8) !?[]u8 {
    var diag: format.Diagnostic = .{};
    defer diag.deinit(state.alloc);
    return format.format(state.alloc, src, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => {
            std.debug.print("{s}:{}:{}: error: {s}\n", .{ name, diag.line + 1, diag.col + 1, diag.msg });
            state.num_failed += 1;
            return null;
        },
        error.VerifyError => {
            if (diag.pos > 0) {
                std.debug.print("{s}:{}:{}: internal error, file left unchanged: {s}\n", .{ name, diag.line + 1, diag.col + 1, diag.msg });
            } else {
                // Not every verification failure has a position in the source.
                std.debug.print("{s}: internal error, file left unchanged: {s}\n", .{ name, diag.msg });
            }
            state.num_failed += 1;
            return null;
        },
    };
}
