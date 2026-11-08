const std = @import("std");

/// Contains synchronized state between a thread that owns and consumes the future's result
/// and the thread that produces the result.
/// When a future has a sync state, `FutureValue.completed` should not be used.
/// 0, pending: Initially marked as pending. At this point, the future's result can not be read.
/// 1, writing: Transition from `pending` by producer to prevent a race when the owner invalidates the future.
/// 2, completed: Transition from `writing` by producer once it's done writing the result.
/// 3, failed: Transition from `pending` by the worker when the spawned thread panicked.
///    `panic_msg` carries the thread's panic message when it had one. Also reserved for the owner
///    invalidating a pending future when it is deinitialized.
/// 4, stopped: Transition from `pending` by the worker when the spawned thread was interrupted or ran out of fuel.
///
/// `state` is the first field: `core.cy` holds the state as `Ptr[byte]` and writes the initial 0 through it.
/// Owned by `VM.shared_states` and freed with the VM (or its reset), so an awaiting thread only reads `panic_msg`.
pub const FutureSyncState = extern struct {
    state: u8,
    panic_msg_ptr: ?[*]const u8 = null,
    panic_msg_len: usize = 0,

    pub fn panic_msg(self: *const FutureSyncState) ?[]const u8 {
        const ptr = self.panic_msg_ptr orelse return null;
        return ptr[0..self.panic_msg_len];
    }
};

pub const SeqLock = packed struct(u8) {
    value: u8 = 0,

    pub fn read_start(self: *SeqLock) ?u8 {
        const state = @atomicLoad(SeqLock, self, .acquire);
        if (state.value & 1 == 1) {
            return null;
        }
        return state.value;
    }

    pub fn read_needs_retry(self: *SeqLock, start: u8) bool {
        return @atomicLoad(SeqLock, self, .acquire).value == start;
    }

    pub fn write_lock(self: *SeqLock) u8 {
        var state: SeqLock = undefined;
        while (true) {
            state = @atomicLoad(SeqLock, self, .monotonic);
            if (state.value & 1 == 0) {
                break;
            }
            std.atomic.spinLoopHint();
        }
        const new = SeqLock{.value=state.value + 1};
        while (@cmpxchgWeak(SeqLock, self, state, new, .acquire, .monotonic)) |_| {}
        return state.value;
    }

    pub fn write_unlock(self: *SeqLock, start: u8) void {
        @atomicStore(SeqLock, self, .{.value=start +% 2}, .release);
    }
};

pub const RWLock = packed struct(u8) {
    readers: u7 = 0,
    writing: u1 = 0,

    pub fn read_lock(self: *RWLock) void {
        var state: RWLock = undefined;
        while (true) {
            state = @atomicLoad(RWLock, self, .monotonic);
            if (state.writing == 0) {
                break;
            }
            std.atomic.spinLoopHint();
        }
        const new = RWLock{.readers=state.readers+1, .writing=0};
        while (@cmpxchgWeak(RWLock, self, state, new, .acquire, .monotonic)) |_| {}
    }

    pub fn read_unlock(self: *RWLock) void {
        _ = @atomicRmw(u8, @as(*u8, @ptrCast(self)), .Sub, 1, .release);
    }

    pub fn write_lock(self: *RWLock) void {
        var state: RWLock = undefined;
        while (true) {
            state = @atomicLoad(RWLock, self, .monotonic);
            if (state.readers == 0 and state.writing == 0) {
                break;
            }
            std.atomic.spinLoopHint();
        }
        const new = RWLock{.readers=0, .writing=1};
        while (@cmpxchgWeak(RWLock, self, state, new, .acquire, .monotonic)) |_| {}
    }

    pub fn write_unlock(self: *RWLock) void {
        @atomicStore(RWLock, self, .{.readers=0, .writing=0}, .release);
    }
};