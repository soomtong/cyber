const std = @import("std");

/// Contains synchronized state between a thread that owns and consumes the future's result
/// and the thread that produces the result.
/// `FutureValue.completed` is set once the owner received the result.
///
/// The producer never touches the owner's heap or the owner's `FutureValue`: a thread heap is not thread-safe,
/// and the owner can destruct the future at any time. The result stays in the spawned thread's heap (`thread`, with the returned value's bytes in `result`) until
/// the owner takes it: `await` copies it into the owner's heap with `@send` on the owner's thread, then drops
/// the spawned thread (`worker.dropThreadResult`).
///
/// 0, pending: Initially marked as pending. At this point, the future's result can not be read.
/// 2, completed: Transition from `pending` by the producer once `thread` and `result` are set.
/// 3, failed: Transition from `pending` by the worker when the spawned thread panicked.
///    `panic_msg` carries the thread's panic message when it had one.
/// 4, stopped: Transition from `pending` by the worker when the spawned thread was interrupted or ran out of fuel.
/// 5, received: Transition from `completed` by the owner once it took the result (or dropped it) and freed
///    the spawned thread. `await` reads the future's own `data` from then on.
/// 6, abandoned: Transition from `pending` by the owner when the future is destructed before the thread ended.
///    The producer drops the result and frees the spawned thread itself instead of completing.
/// Only the 0 -> 2/3/4 (producer) and 0 -> 6 (owner) transitions race. The side that loses the `cmpxchg` on 0
/// sees the other's state, which says who frees the spawned thread: the owner for 2, the producer for 6.
/// (1 was a writing state when the producer wrote into the owner's future. It is no longer used.)
///
/// `state` is the first field: `core.cy` holds the state as `Ptr[byte]` and writes the initial 0 through it.
/// Owned by `VM.shared_states` and freed with the VM (or its reset), so an awaiting thread only reads `panic_msg`.
pub const FutureSyncState = extern struct {
    state: u8,
    panic_msg_ptr: ?[*]const u8 = null,
    panic_msg_len: usize = 0,

    /// Set by the producer before the transition to 2. A `*cy.Thread` that finished its entry function.
    thread: ?*anyopaque = null,
    /// The returned value's bytes, allocated with the pool's allocator. Not in the spawned thread's stack,
    /// which can move while the drop function runs on it.
    result: ?[*]align(8) u8 = null,
    result_len: usize = 0,
    /// The bytecode function `@thread_drop[Sig]` that destructs a result in the spawned thread's heap.
    /// Set by `@start_thread`.
    drop_func: u64 = 0,

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