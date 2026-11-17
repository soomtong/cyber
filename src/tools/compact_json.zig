//! Build tool: writes a JSON file without the whitespace between its tokens.
//! `cyber doc --api` embeds `docs/api.json` this way (build.zig `create_cli_module`).
//! Usage: compact_json <in> <out>

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.Usage;
    const alloc = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const src = try cwd.readFileAlloc(init.io, args[1], alloc, .limited(64 << 20));
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, src, .{});
    const out = try std.json.Stringify.valueAlloc(alloc, parsed.value, .{});
    try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = out });
}
