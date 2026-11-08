const std = @import("std");
const builtin = @import("builtin");
const cy = @import("cyber.zig");
const log = cy.log.scoped(.worker);
const build_config = @import("build_config");
const stdx = @import("stdx");

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
            fut: *cy.heap.FutureValue,

            // Byte size, not reg size. void return if ret_size == 0.
            ret_size: u16,
        },
    },
};

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

    /// Waits until no task is queued or running. Queued tasks are run on the calling thread when
    /// no worker picks them up (a pool without workers, or workers that are all busy).
    pub fn wait_idle(self: *Pool) void {
        while (true) {
            if (self.run_queued_task()) continue;
            self.mutex.lockUncancelable(stdx.io());
            const idle = self.active_workers == 0 and self.task_queue.first == null;
            self.mutex.unlock(stdx.io());
            if (idle) return;
            std.atomic.spinLoopHint();
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

    pub fn add_thread_task(self: *Pool, thread: *cy.Thread, func_ptr: cy.Value, fut: *cy.heap.FutureValue, ret_size: usize) !void {
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
                    .fut = fut,
                    .fut_sync_state = fut.shared_state.?,
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
                        // The owner already invalidated the future. Nobody reads the message.
                        if (msg) |m| {
                            sync_state.panic_msg_ptr = null;
                            sync_state.panic_msg_len = 0;
                            pool.alloc.free(m);
                        }
                    }
                    thread.deinit(false);
                    pool.alloc.destroy(thread);
                    return;
                };

                while (@cmpxchgWeak(u8, &sync_state.state, 0, 1, .acquire, .monotonic)) |actual| {
                    if (actual == 3) {
                        @panic("TODO: future was invalidated");
                    }
                }

                @as(*u64, @ptrCast(&task.data.thread.fut.data)).* = 1;
                if (ret_reg_size > 0) {
                    const dst = @as([*]u8, @ptrCast(&task.data.thread.fut.data)) + 8;
                    @memcpy(dst[0..ret_byte_size], @as([*]u8, @ptrCast(ret))[0..ret_byte_size]);
                }

                @atomicStore(u8, &sync_state.state, 2, .release);

                if (cy.Trace) {
                    const grc = thread.heap.c.refCounts;
                    if (grc != 0) {
                        cy.C.thread_dump_live_objects(@ptrCast(thread));
                        cy.panicFmt("unreleased refcount: {}", .{grc});
                    }
                }

                thread.deinit(false);
                pool.alloc.destroy(thread);
            },
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
            }
            pool.run_task(task);
        }
    }
};
