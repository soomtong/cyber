const std = @import("std");

/// Wraps the allocator a VM was created with and counts the bytes the VM holds through it. Carries the limit of
/// `cl_vm_set_memory_limit` (F-41).
///
/// A request is never refused here. Most allocation sites of the compiler and the runtime are not prepared to
/// fail at an arbitrary point (`catch fatal()`, half-built state), so the limit is checked only where it ends in a
/// clean `panic: OutOfMemory`: where the heap of a thread grows (`Heap.reserve`) and where its stack grows
/// (`Thread.growStackAuto`).
pub const MemAccount = struct {
    child: std.mem.Allocator,

    /// Bytes currently allocated. The threads of a VM allocate concurrently.
    used: std.atomic.Value(usize) = .init(0),

    /// Zero means no limit.
    limit: std.atomic.Value(usize) = .init(0),

    /// Allocations the host's allocator refused. A compile that fails while this moves leaves compiler state
    /// that is not trusted again (`Compiler.alloc_failed`). A refused `resize` or `remap` is not counted, the
    /// caller falls back to `alloc`.
    failed: std.atomic.Value(usize) = .init(0),

    pub fn allocator(self: *MemAccount) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The account behind `a`, when `a` is the allocator of a VM.
    pub fn of(a: std.mem.Allocator) ?*MemAccount {
        if (a.vtable != &vtable) return null;
        return @ptrCast(@alignCast(a.ptr));
    }

    /// Bytes that can still be allocated under the limit. `null` without a limit.
    pub fn room(self: *const MemAccount) ?usize {
        const limit = self.limit.load(.monotonic);
        if (limit == 0) return null;
        return limit -| self.used.load(.monotonic);
    }

    pub fn fits(self: *const MemAccount, size: usize) bool {
        const left = self.room() orelse return true;
        return size <= left;
    }

    fn resized(self: *MemAccount, old_len: usize, new_len: usize) void {
        if (new_len >= old_len) {
            _ = self.used.fetchAdd(new_len - old_len, .monotonic);
        } else {
            _ = self.used.fetchSub(old_len - new_len, .monotonic);
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *MemAccount = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse {
            _ = self.failed.fetchAdd(1, .monotonic);
            return null;
        };
        _ = self.used.fetchAdd(len, .monotonic);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *MemAccount = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.resized(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *MemAccount = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.resized(memory.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *MemAccount = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        _ = self.used.fetchSub(memory.len, .monotonic);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

test "MemAccount counts what its allocator holds." {
    const zt = std.testing;
    var acct: MemAccount = .{ .child = zt.allocator };
    const a = acct.allocator();
    try zt.expect(MemAccount.of(a) == &acct);
    try zt.expect(MemAccount.of(zt.allocator) == null);

    var buf = try a.alloc(u8, 100);
    try zt.expectEqual(@as(usize, 100), acct.used.load(.monotonic));
    buf = try a.realloc(buf, 4000);
    try zt.expectEqual(@as(usize, 4000), acct.used.load(.monotonic));
    buf = try a.realloc(buf, 10);
    try zt.expectEqual(@as(usize, 10), acct.used.load(.monotonic));

    // Without a limit everything fits. With one, `room` is what is left and never underflows.
    try zt.expect(acct.room() == null);
    try zt.expect(acct.fits(std.math.maxInt(usize)));
    acct.limit.store(64, .monotonic);
    try zt.expectEqual(@as(?usize, 54), acct.room());
    try zt.expect(acct.fits(54));
    try zt.expect(!acct.fits(55));
    acct.limit.store(4, .monotonic);
    try zt.expectEqual(@as(?usize, 0), acct.room());
    try zt.expect(!acct.fits(1));

    a.free(buf);
    try zt.expectEqual(@as(usize, 0), acct.used.load(.monotonic));
}
