//! Wake-ups of suspended fibers by the futures that they await, and the ready queue of a `Scope`.
//!
//! A fiber that is suspended at an `await` or in `Future.wait_any` is registered in its thread's wait table under
//! each future that it awaits. Completing a future on the thread (`FutureResolver.complete`, `cl_future_complete`)
//! takes its waiters out of the table and wakes them: a fiber of a `Scope` goes to the scope's ready queue, and the
//! fiber that waits for that queue (`@scope_wait`) is woken the same way, up to the first one that is not waiting.
//! A spawned thread can not touch the table of the owner's thread. Its futures are checked by the owner when the
//! worker pool made progress (`pollShared`).
//!
//! So `Scope.run` resumes the fibers that can go on instead of asking every fiber of the scope in each round
//! (`docs/decisions/project_coroutines.md` "Scope 준비 큐").

const std = @import("std");
const builtin = @import("builtin");
const cy = @import("cyber.zig");
const vmc = @import("vmc");
const FutureValue = cy.heap.FutureValue;
const Fiber = vmc.Fiber;

pub const WaitEntry = struct {
    /// The fibers that await the future. A fiber of `Future.wait_any` can be in it more than once.
    fibers: std.ArrayList(*Fiber) = .empty,
    /// The index in `Thread.shared_waits` of a future of a spawned thread.
    shared_idx: ?u32 = null,
};

/// The fibers of a `Scope`. Allocated by `@scope_queue_new` and linked from `Thread.scope_queues`, so a panic that
/// frees the heap without the `Scope`'s `@deinit` frees it with the thread's fibers.
pub const ScopeQueue = struct {
    /// The fibers that are not done, in the order they were started (`Fiber.scope_next`).
    first: ?*Fiber = null,
    last: ?*Fiber = null,
    count: usize = 0,
    /// The fibers that can run (`Fiber.ready_next`).
    ready_head: ?*Fiber = null,
    ready_tail: ?*Fiber = null,
    /// The fiber that is suspended in `@scope_wait` of this queue.
    waiter: ?*Fiber = null,
    prev: ?*ScopeQueue = null,
    next: ?*ScopeQueue = null,

    pub fn of(fiber: *const Fiber) ?*ScopeQueue {
        return @ptrCast(@alignCast(fiber.scope));
    }

    /// Adds a fiber that was just started. It can run.
    pub fn add(q: *ScopeQueue, fiber: *Fiber) void {
        fiber.scope = q;
        fiber.scope_prev = q.last;
        fiber.scope_next = null;
        if (q.last) |last| last.*.scope_next = fiber else q.first = fiber;
        q.last = fiber;
        q.count += 1;
        q.push(fiber);
    }

    /// Puts a fiber at the end of the ready queue.
    pub fn push(q: *ScopeQueue, fiber: *Fiber) void {
        if (fiber.queued) return;
        fiber.queued = true;
        fiber.parked = false;
        fiber.ready_prev = q.ready_tail;
        fiber.ready_next = null;
        if (q.ready_tail) |tail| tail.*.ready_next = fiber else q.ready_head = fiber;
        q.ready_tail = fiber;
    }

    pub fn pop(q: *ScopeQueue) ?*Fiber {
        const fiber = q.ready_head orelse return null;
        q.unqueue(fiber);
        return fiber;
    }

    fn unqueue(q: *ScopeQueue, fiber: *Fiber) void {
        if (!fiber.queued) return;
        if (fiber.ready_prev) |prev| prev.*.ready_next = fiber.ready_next else q.ready_head = fiber.ready_next;
        if (fiber.ready_next) |next| next.*.ready_prev = fiber.ready_prev else q.ready_tail = fiber.ready_prev;
        fiber.ready_prev = null;
        fiber.ready_next = null;
        fiber.queued = false;
    }

    /// Takes a fiber out of the scope, when it is freed.
    pub fn remove(q: *ScopeQueue, fiber: *Fiber) void {
        q.unqueue(fiber);
        if (fiber.scope_prev) |prev| prev.*.scope_next = fiber.scope_next else q.first = fiber.scope_next;
        if (fiber.scope_next) |next| next.*.scope_prev = fiber.scope_prev else q.last = fiber.scope_prev;
        fiber.scope_prev = null;
        fiber.scope_next = null;
        fiber.scope = null;
        fiber.parked = false;
        q.count -= 1;
    }

    /// Puts every parked fiber in the ready queue. For a wait that has nothing to wait for.
    pub fn wakeAll(q: *ScopeQueue) void {
        var it = q.first;
        while (it) |fiber| : (it = fiber.scope_next) {
            if (fiber.parked) q.push(fiber);
        }
    }
};

fn futures(fiber: *const Fiber) []const *FutureValue {
    if (fiber.await_len == 0) return &.{};
    const ptr: [*]const *FutureValue = @ptrCast(@alignCast(fiber.await_ptr));
    return ptr[0..fiber.await_len];
}

/// Registers a suspended fiber under the futures that it awaits.
pub fn register(t: *cy.Thread, fiber: *Fiber) !void {
    if (fiber.wait_registered) return;
    fiber.wait_registered = true;
    errdefer unregister(t, fiber);
    for (futures(fiber)) |future| {
        const res = try t.waits.getOrPut(t.alloc, future);
        if (!res.found_existing) {
            res.value_ptr.* = .{};
            if (future.shared_state != null) {
                t.shared_waits.append(t.alloc, future) catch |err| {
                    t.waits.removeByPtr(res.key_ptr);
                    return err;
                };
                res.value_ptr.shared_idx = @intCast(t.shared_waits.items.len - 1);
            }
        }
        try res.value_ptr.fibers.append(t.alloc, fiber);
    }
}

/// Takes a fiber out of the wait table. Only reads the fiber's own list: a future can already be freed when the
/// thread is torn down.
pub fn unregister(t: *cy.Thread, fiber: *Fiber) void {
    if (!fiber.wait_registered) return;
    fiber.wait_registered = false;
    for (futures(fiber)) |future| {
        const entry = t.waits.getPtr(future) orelse continue;
        for (entry.fibers.items, 0..) |item, i| {
            if (item == fiber) {
                _ = entry.fibers.swapRemove(i);
                break;
            }
        }
        if (entry.fibers.items.len == 0) removeEntry(t, future);
    }
}

fn removeEntry(t: *cy.Thread, future: *FutureValue) void {
    var kv = t.waits.fetchRemove(future) orelse return;
    dropShared(t, &kv.value);
    kv.value.fibers.deinit(t.alloc);
}

fn dropShared(t: *cy.Thread, entry: *WaitEntry) void {
    const idx = entry.shared_idx orelse return;
    entry.shared_idx = null;
    _ = t.shared_waits.swapRemove(idx);
    if (idx < t.shared_waits.items.len) {
        const moved = t.shared_waits.items[idx];
        t.waits.getPtr(moved).?.shared_idx = idx;
    }
}

/// Wakes the fibers that await a future that was completed on this thread.
pub fn wakeFuture(t: *cy.Thread, future: *FutureValue) void {
    var kv = t.waits.fetchRemove(future) orelse return;
    dropShared(t, &kv.value);
    defer kv.value.fibers.deinit(t.alloc);
    for (kv.value.fibers.items) |fiber| {
        // The other futures of a `Future.wait_any` do not wake it again.
        unregister(t, fiber);
        wakeFiber(fiber);
    }
}

/// A fiber that waited can go on. A fiber of a scope goes to the scope's ready queue, and the fiber that waits for
/// that queue is woken too. A fiber in `Fiber.wait_ready` is woken when a fiber that it runs is.
pub fn wakeFiber(fiber: *Fiber) void {
    var it = fiber;
    while (true) {
        if (ScopeQueue.of(it)) |q| {
            if (!it.parked) return;
            q.push(it);
            const waiter = q.waiter orelse return;
            q.waiter = null;
            waiter.waiting_in = null;
            it = waiter;
            continue;
        }
        const owner = it.owner orelse return;
        if (owner.*.state != vmc.FIBER_SUSPENDED or !owner.*.await_fibers) return;
        it = owner;
    }
}

/// Wakes the fibers that await a future of a spawned thread that is done. Checks only when the worker pool made
/// progress since the last check, or with `force`.
pub fn pollShared(t: *cy.Thread, force: bool) void {
    if (t.shared_waits.items.len == 0) return;
    const epoch = t.c.vm.worker_pool.progressEpoch();
    // Without threads the epoch does not move: a task runs on the waiting thread itself.
    if (!force and !builtin.single_threaded and epoch == t.shared_epoch) return;
    t.shared_epoch = epoch;
    var i = t.shared_waits.items.len;
    while (i > 0) {
        i -= 1;
        // `wakeFuture` moves the last entry to `i`, which was checked already.
        if (i >= t.shared_waits.items.len) continue;
        const future = t.shared_waits.items[i];
        if (cy.vm.futureDone(future)) wakeFuture(t, future);
    }
}

/// A fiber of a scope that was resumed and suspended again. It waits to be woken, or it can run again.
pub fn park(t: *cy.Thread, q: *ScopeQueue, fiber: *Fiber) void {
    _ = t;
    if (fiber.await_len > 0) {
        // A future that is done already, or one that no completion is told of.
        if (!fiber.wait_registered or anyDone(fiber)) return q.push(fiber);
        fiber.parked = true;
        return;
    }
    if (fiber.await_fibers) {
        if (fiber.waiting_in != null) {
            // In `@scope_wait` of a scope of its own, which had nothing to run.
            fiber.parked = true;
            return;
        }
        // In `Fiber.wait_ready`, which gives control back once even when a future of the fibers that it runs
        // is done.
        if (ownedReady(fiber)) return q.push(fiber);
        fiber.parked = true;
        return;
    }
    // Stopped at `suspend`.
    q.push(fiber);
}

fn anyDone(fiber: *const Fiber) bool {
    for (futures(fiber)) |future| {
        if (cy.vm.futureDone(future)) return true;
    }
    return false;
}

fn ownedReady(root: *Fiber) bool {
    var it = root;
    while (cy.thread.nextOwnedFiber(root, it)) |fiber| : (it = fiber) {
        if (fiber.state == vmc.FIBER_SUSPENDED and anyDone(fiber)) return true;
    }
    return false;
}

/// Frees a queue. A fiber that is left in it (one that could not be cancelled and was not run to its end) is
/// no fiber of a scope anymore.
pub fn freeQueue(t: *cy.Thread, q: *ScopeQueue) void {
    while (q.first) |fiber| q.remove(fiber);
    if (q.waiter) |waiter| waiter.waiting_in = null;
    if (q.prev) |prev| prev.next = q.next else t.scope_queues = q.next;
    if (q.next) |next| next.prev = q.prev;
    t.alloc.destroy(q);
}

pub fn newQueue(t: *cy.Thread) !*ScopeQueue {
    const q = try t.alloc.create(ScopeQueue);
    q.* = .{ .next = t.scope_queues };
    if (t.scope_queues) |head| head.prev = q;
    t.scope_queues = q;
    return q;
}

/// Takes a fiber that is freed out of its scope and the wait table.
pub fn forgetFiber(t: *cy.Thread, fiber: *Fiber) void {
    unregister(t, fiber);
    if (ScopeQueue.of(fiber)) |q| q.remove(fiber);
    if (fiber.waiting_in) |ptr| {
        const q: *ScopeQueue = @ptrCast(@alignCast(ptr));
        q.waiter = null;
        fiber.waiting_in = null;
    }
}

/// Frees the queues whose `Scope` went away without its `@deinit` (a panic, the end of the thread).
pub fn freeAllQueues(t: *cy.Thread) void {
    while (t.scope_queues) |q| freeQueue(t, q);
}

pub fn deinit(t: *cy.Thread, reset: bool) void {
    var it = t.waits.valueIterator();
    while (it.next()) |entry| entry.fibers.deinit(t.alloc);
    if (reset) {
        t.waits.clearRetainingCapacity();
        t.shared_waits.clearRetainingCapacity();
    } else {
        t.waits.deinit(t.alloc);
        t.shared_waits.deinit(t.alloc);
    }
}
