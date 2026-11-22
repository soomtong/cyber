const std = @import("std");
const builtin = @import("builtin");
const cy = @import("cyber.zig");
const log = cy.log.scoped(.worker);
const build_config = @import("build_config");
const stdx = @import("stdx");
const vmc = @import("vmc");

const TaskKind = enum(u8) {
    thread,
};

pub const Task = struct {
    kind: TaskKind,
    node: std.SinglyLinkedList.Node,
    data: union {
        thread: struct {
            thread: *cy.Thread,
            func_ptr: cy.Value,
            fut_sync_state: *cy.sync.FutureSyncState,

            // Byte size, not reg size. void return if ret_size == 0.
            ret_size: u16,
        },
    },
};

/// Bumped when a task is queued or finishes, and on an interrupt. A thread that waits for a spawned thread
/// (`await`, `Future.wait_any`, `Fiber.wait_ready`) sleeps on it instead of spinning.
/// Not behind `Pool.mutex`: `cl_vm_interrupt` can be called from a signal handler. One for the process, not a
/// `Pool` field: `vm.h` mirrors the layout of `VM`. Another VM's event only wakes a waiter once more.
var progress: std.atomic.Value(u32) = .init(0);

pub const Pool = struct {
    vm: *cy.VM,
    alloc: std.mem.Allocator,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    // Protected by `mutex`.
    workers: []Worker,
    active_workers: usize,
    num_workers: usize,
    task_queue: std.SinglyLinkedList,
    last_task_node: ?*std.SinglyLinkedList.Node,
    // Set by `deinit`. Workers that wake up exit instead of waiting again.
    shutdown: bool,

    pub fn init(vm: *cy.VM, max_workers: usize) !Pool {
        return .{
            .vm = vm,
            .alloc = vm.alloc,
            .workers = try vm.alloc.alloc(Worker, max_workers),
            .active_workers = 0,
            .last_task_node = null,
            .task_queue = .{},
            .num_workers = 0,
            .shutdown = false,
        };
    }

    /// Read before checking what to wait for, then pass to `waitProgress`. A change between the read and the
    /// wait makes the wait return at once.
    pub fn progressEpoch(self: *Pool) u32 {
        _ = self;
        return progress.load(.acquire);
    }

    /// Wakes the threads in `waitProgress`.
    pub fn notifyProgress(self: *Pool) void {
        _ = self;
        if (comptime builtin.single_threaded) return;
        _ = progress.fetchAdd(1, .release);
        stdx.io().futexWake(u32, &progress.raw, std.math.maxInt(u32));
    }

    /// `notifyProgress` for a signal handler (`cl_vm_interrupt`). It does not build the process `Io`: before it
    /// is built no thread waits in `waitProgress`, which builds it first. The wake itself is one system call on
    /// Linux, the Apple systems and FreeBSD. Elsewhere the futex can be a userland one with locks (Windows), so
    /// only the epoch moves, and a waiter sees it within the timeout of `waitProgress`.
    pub fn notifyProgressFromSignal(self: *Pool) void {
        _ = self;
        if (comptime builtin.single_threaded) return;
        _ = progress.fetchAdd(1, .release);
        const syscall_wake = comptime builtin.os.tag == .linux or builtin.os.tag == .freebsd or builtin.os.tag.isDarwin();
        if (!syscall_wake) return;
        if (!stdx.ioReady()) return;
        stdx.io().futexWake(u32, &progress.raw, std.math.maxInt(u32));
    }

    /// Sleeps until `notifyProgress` is called after `seen` was read. Also wakes up after a few ms, for what
    /// does not notify (fuel, a spawned thread's own interrupt flag).
    pub fn waitProgress(self: *Pool, seen: u32) void {
        _ = self;
        if (comptime builtin.single_threaded) {
            std.atomic.spinLoopHint();
            return;
        }
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } };
        stdx.io().futexWaitTimeout(u32, &progress.raw, seen, timeout) catch {};
    }

    /// Waits until no task is queued or running. Queued tasks are run on the calling thread when
    /// no worker picks them up (a pool without workers, or workers that are all busy).
    pub fn wait_idle(self: *Pool) void {
        while (true) {
            const epoch = self.progressEpoch();
            if (self.run_queued_task()) continue;
            self.mutex.lockUncancelable(stdx.io());
            const idle = self.active_workers == 0 and self.task_queue.first == null;
            self.mutex.unlock(stdx.io());
            if (idle) return;
            self.waitProgress(epoch);
        }
    }

    /// Stops and joins the worker threads. The caller has stopped the tasks first (`VM.stopSpawnedThreads`).
    /// Workers used to outlive the VM, waiting on the condition inside the freed pool; a later VM at the same
    /// address could wake them into freed memory.
    pub fn deinit(self: *Pool, alloc: std.mem.Allocator) void {
        if (comptime !builtin.single_threaded) {
            self.mutex.lockUncancelable(stdx.io());
            self.shutdown = true;
            self.mutex.unlock(stdx.io());
            self.cond.broadcast(stdx.io());
            for (self.workers[0..self.num_workers]) |worker| {
                worker.os_thread.join();
            }
        }
        alloc.free(self.workers);
    }

    // Assumes in critical section.
    pub fn request_idle_worker(self: *Pool) !void {
        // A single-threaded target (wasm32) never spawns workers. Keeps `std.Thread.spawn` out of its analysis.
        if (comptime builtin.single_threaded) return error.Unsupported;
        if (self.active_workers < self.num_workers) return;
        if (self.num_workers == self.workers.len) return;

        self.workers[self.num_workers] = .{
            .id = self.num_workers,
            .os_thread = try std.Thread.spawn(.{
                .stack_size = 16 * 1024 * 1024,
                .allocator = self.alloc,
            }, Worker.run, .{&self.workers[self.num_workers], self}),
        };
        self.num_workers += 1;
    }

    pub fn add_thread_task(self: *Pool, thread: *cy.Thread, func_ptr: cy.Value, sync_state: *cy.sync.FutureSyncState, ret_size: usize) !void {
        if (!build_config.threads) {
            @panic("unsupported");
        }
        {
            self.mutex.lockUncancelable(stdx.io());
            defer self.mutex.unlock(stdx.io());

            try self.request_idle_worker();       

            const task = try self.alloc.create(Task);
            task.* = .{
                .kind = .thread,
                .node = .{},
                .data = .{ .thread = .{
                    .thread = thread,
                    .func_ptr = func_ptr,
                    .fut_sync_state = sync_state,
                    .ret_size = @intCast(ret_size),
                }},
            };
            if (self.last_task_node) |last| {
                last.insertAfter(&task.node);
            } else {
                self.task_queue.first = &task.node;
            }
            self.last_task_node = &task.node;
        }

        self.cond.signal(stdx.io());
        // A thread that waits in `await` can run the task itself.
        self.notifyProgress();
        log.tracev("signal new thread task", .{});
    }

    // Assumes in critical section.
    fn pop_task(self: *Pool) ?*Task {
        const node = self.task_queue.popFirst() orelse return null;
        if (self.task_queue.first == null) {
            // No more tasks in queue.
            self.last_task_node = null;
        }
        return @fieldParentPtr("node", node);
    }

    /// Runs one queued task on the calling OS thread. Called by a thread that waits in `await`
    /// (a worker or the main thread) so a full pool can not deadlock on queued tasks.
    /// Returns false when the queue was empty.
    pub fn run_queued_task(self: *Pool) bool {
        if (comptime builtin.single_threaded) return false;
        self.mutex.lockUncancelable(stdx.io());
        const task = self.pop_task() orelse {
            self.mutex.unlock(stdx.io());
            return false;
        };
        self.mutex.unlock(stdx.io());
        self.run_task(task);
        return true;
    }

    /// Runs a thread task to completion and frees it. The task's future state is set to
    /// 2 (completed), 3 (panicked) or 4 (stopped).
    fn run_task(pool: *Pool, task: *Task) void {
        if (comptime builtin.single_threaded) return;
        defer pool.alloc.destroy(task);
        switch (task.kind) {
            .thread => {
                const thread = task.data.thread.thread;
                const ret_byte_size = task.data.thread.ret_size;
                const ret_reg_size = (task.data.thread.ret_size + 7) >> 3;

                // Ensure `fp_end` is set.
                thread.c.fp_end = thread.c.stack_ptr + 1;
                const sync_state = task.data.thread.fut_sync_state;
                const ret = thread.callFunc2(thread.c.stack_ptr, ret_reg_size, task.data.thread.func_ptr) catch |err| {
                    // The thread already unwound and freed its heap. Mark the future so `await` stops
                    // waiting, instead of aborting the host: 4 when it was stopped (interrupt, fuel), 3 otherwise.
                    // A panic message is handed to the awaiting thread through the sync state.
                    log.tracev("thread task failed: {}", .{err});
                    const failed: u8 = if (err == error.Interrupted) 4 else 3;
                    var msg: ?[]const u8 = null;
                    if (failed == 3) {
                        if (thread.panic_msg()) |thread_msg| {
                            msg = pool.alloc.dupe(u8, thread_msg) catch null;
                        }
                    }
                    if (msg) |m| {
                        sync_state.panic_msg_ptr = m.ptr;
                        sync_state.panic_msg_len = m.len;
                    }
                    if (@cmpxchgStrong(u8, &sync_state.state, 0, failed, .acq_rel, .monotonic) != null) {
                        // The owner destructed the future (6). Nobody reads the message.
                        if (msg) |m| {
                            sync_state.panic_msg_ptr = null;
                            sync_state.panic_msg_len = 0;
                            pool.alloc.free(m);
                        }
                    }
                    thread.deinit(false);
                    pool.alloc.destroy(thread);
                    pool.vm.releaseSharedState(sync_state);
                    pool.notifyProgress();
                    return;
                };

                // The result stays in this thread's heap. Nothing here touches the owner's heap or its
                // `FutureValue`: the owner copies the result out on its own thread (`Future.await`).
                // The bytes move out of the stack, which can move while the drop function runs on it.
                var result: ?[*]align(8) u8 = null;
                if (ret_byte_size > 0) {
                    const buf = pool.alloc.alignedAlloc(u8, .@"8", ret_byte_size) catch {
                        // No room to keep the result. Sweep the thread's heap like a panic does.
                        _ = cy.thread.freeHeapPages(thread) catch {};
                        // Abandoned (6) when this fails. Nobody waits then.
                        _ = @cmpxchgStrong(u8, &sync_state.state, 0, 3, .acq_rel, .monotonic);
                        thread.deinit(false);
                        pool.alloc.destroy(thread);
                        pool.vm.releaseSharedState(sync_state);
                        pool.notifyProgress();
                        return;
                    };
                    @memcpy(buf, @as([*]const u8, @ptrCast(ret))[0..ret_byte_size]);
                    result = buf.ptr;
                }
                sync_state.thread = thread;
                sync_state.result = result;
                sync_state.result_len = ret_byte_size;

                if (@cmpxchgStrong(u8, &sync_state.state, 0, 2, .acq_rel, .acquire)) |actual| {
                    // The owner destructed the future while the thread ran (6). The thread drops its result.
                    std.debug.assert(actual == 6);
                    pool.dropThreadResult(sync_state);
                }
                // The producer is done with the state. The owner can free it from here on.
                pool.vm.releaseSharedState(sync_state);
                pool.notifyProgress();
            },
        }
    }

    /// Destructs a done thread's result in the thread's own heap and frees the thread. The caller owns the
    /// thread exclusively: the producer after the owner abandoned the future (6), or the owner after 2.
    /// Runs the thread's drop function on the calling OS thread, like `run_queued_task` runs a task there.
    pub fn dropThreadResult(pool: *Pool, sync_state: *cy.sync.FutureSyncState) void {
        const thread: *cy.Thread = @ptrCast(@alignCast(sync_state.thread orelse return));
        const result = sync_state.result;
        const result_len = sync_state.result_len;
        sync_state.thread = null;
        sync_state.result = null;
        sync_state.result_len = 0;

        // The drop runs to its end even while the VM stops its spawned threads (`stopSpawnedThreads`) or the
        // thread's fuel ran low: stopping it would leak the result.
        var no_interrupt: u8 = 0;
        thread.c.interrupt = &no_interrupt;
        thread.c.fuel_limit = 0;
        thread.resetFuel();

        const prev_thread = vmc.cur_thread;
        defer vmc.cur_thread = prev_thread;
        thread.c.fp_end = thread.c.stack_ptr + 1;
        // `@thread_drop(res Ptr[T])` returns `void`. Its argument is right after the call info.
        thread.c.stack_ptr[cy.thread.CallArgStart] = cy.Value{ .val = @intFromPtr(result) };
        if (thread.callFunc2(thread.c.stack_ptr, 0, .{ .val = sync_state.drop_func })) |_| {
            if (cy.Trace) {
                const grc = thread.heap.c.refCounts;
                if (grc != 0) {
                    cy.C.thread_dump_live_objects(@ptrCast(thread));
                    cy.panicFmt("unreleased refcount: {}", .{grc});
                }
            }
        } else |err| {
            // A destructor panicked. The thread already unwound and freed its heap.
            log.tracev("thread result drop failed: {}", .{err});
        }
        if (result) |ptr| {
            pool.alloc.free(ptr[0..result_len]);
        }
        thread.deinit(false);
        pool.alloc.destroy(thread);
    }

    /// The owner took a done thread's result (`Future.await`): 2 -> 5, and the thread is freed.
    pub fn claimThreadResult(pool: *Pool, sync_state: *cy.sync.FutureSyncState) void {
        // Only the owner moves the state on from 2.
        std.debug.assert(@atomicLoad(u8, &sync_state.state, .acquire) == 2);
        @atomicStore(u8, &sync_state.state, 5, .release);
        pool.dropThreadResult(sync_state);
    }

    /// The owner destructs the future of a spawned thread. Whichever of the owner and the producer ends
    /// last frees the thread: a pending future is marked abandoned (0 -> 6) and the producer drops its result
    /// when it ends. A done future's thread is freed here (2 -> 5).
    pub fn dropFuture(pool: *Pool, sync_state: *cy.sync.FutureSyncState) void {
        if (@cmpxchgStrong(u8, &sync_state.state, 0, 6, .acq_rel, .acquire)) |actual| {
            if (actual == 2) {
                pool.claimThreadResult(sync_state);
            }
            // 3, 4: the producer freed the thread. 5: the result was received.
        }
    }

    /// Frees the done threads whose futures were never awaited nor destructed (a main local that the eval
    /// does not release, a future in an object that a panic sweep freed). Called after `stopSpawnedThreads`,
    /// while the compiled code still exists.
    pub fn dropUnclaimedResults(pool: *Pool, states: []const *cy.sync.FutureSyncState) void {
        for (states) |sync_state| {
            if (@atomicLoad(u8, &sync_state.state, .acquire) == 2) {
                pool.claimThreadResult(sync_state);
            }
        }
    }
};

pub const Worker = struct {
    id: usize,
    os_thread: std.Thread,

    pub fn run(self: *Worker, pool: *Pool) void {
        // Never spawned on a single-threaded target (wasm32); its `@fieldParentPtr` does not type-check there.
        if (comptime builtin.single_threaded) return;
        pool.mutex.lockUncancelable(stdx.io());
        defer pool.mutex.unlock(stdx.io());
        while (true) {
            if (pool.shutdown) return;
            const task = pool.pop_task() orelse {
                log.tracev("w{}: cond wait", .{self.id});
                pool.cond.waitUncancelable(stdx.io(), &pool.mutex);
                log.tracev("w{}: woke up", .{self.id});
                continue;
            };
            pool.active_workers += 1;
            pool.mutex.unlock(stdx.io());
            defer {
                pool.mutex.lockUncancelable(stdx.io());
                pool.active_workers -= 1;
                // `wait_idle` waits for this.
                pool.notifyProgress();
            }
            pool.run_task(task);
        }
    }
};
