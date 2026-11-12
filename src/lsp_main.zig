//! `cyber-lsp`, the language server. A separate program on top of libcyber (docs/specs/2026-11-12-lsp-design.md).
//! The server speaks the Language Server Protocol over stdin and stdout.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("capi.zig");
const cli = @import("cli.zig");
const transport = @import("lsp/transport.zig");
const lsp = @import("lsp/server.zig");

test {
    _ = @import("lsp/position.zig");
    _ = @import("lsp/transport.zig");
    _ = @import("lsp/symbols.zig");
    _ = @import("lsp/server.zig");
    _ = @import("lsp/test.zig");
}

/// A changed document is checked once the client has sent nothing for this long.
const debounce_ms = 150;

const usage =
    \\Usage: cyber-lsp [options]
    \\
    \\The Cyber language server. Speaks the Language Server Protocol over stdin and stdout.
    \\An editor starts it, it is not used from a terminal.
    \\
    \\Options:
    \\  --stdio     Use stdin and stdout. This is the only transport and the default.
    \\  --version   Print the version.
    \\  -h, --help  Print this text.
    \\
;

pub fn main(init: std.process.Init.Minimal) !u8 {
    const alloc = cli.getAllocator();
    defer cli.deinitAllocator();

    var args_arena: std.heap.ArenaAllocator = .init(alloc);
    defer args_arena.deinit();
    const args = try init.args.toSlice(args_arena.allocator());
    for (args[@min(1, args.len)..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("{s} {s}\n", .{ lsp.name, c.full_version() });
            return 0;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        } else if (std.mem.eql(u8, arg, "--stdio")) {
            // The default.
        } else {
            std.debug.print("Unknown option `{s}`.\n\n{s}", .{ arg, usage });
            return 2;
        }
    }

    // Compile errors are diagnostics. The library does not print them.
    c.setSilent(true);

    var server: lsp.Server = undefined;
    try server.init(alloc);
    defer server.deinit();

    var reader = transport.Reader.init(alloc);
    defer reader.deinit();

    while (!server.exit) {
        const event = reader.next(if (server.hasPending()) debounce_ms else null) catch |err| {
            std.debug.print("{s}: can not read the next message: {s}\n", .{ lsp.name, @errorName(err) });
            return 1;
        };
        switch (event) {
            .message => |body| try server.handle(body),
            .idle => try server.flush(),
            .eof => break,
        }
        for (server.out.items) |body| {
            defer alloc.free(body);
            try transport.writeMessage(body);
        }
        server.out.clearRetainingCapacity();
    }
    // `exit` without `shutdown` before it, or a closed stream, is an abnormal end.
    return if (server.exit and server.shutdown) 0 else 1;
}
