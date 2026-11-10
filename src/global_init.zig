//! Compile-time check of global initializers (F-88).
//!
//! Globals are initialized at the start of the program in a fixed order: chunk by chunk
//! (`initOrder`), and inside a chunk in declaration order. An initializer cannot name a global,
//! but it can call a function, and that function can read or write a global that is not
//! initialized yet. That read is of undefined memory.
//!
//! Sema records what each function touches (`Deps`). After sema, `check` follows the calls
//! that start at each initializer and reports an access to a global that is initialized later,
//! or to the global that is being initialized.
const std = @import("std");
const cy = @import("cyber.zig");
const sema = cy.sema;
const fmt = @import("fmt.zig");
const v = fmt.v;

/// What a function body, or a global initializer, does that matters to the check.
pub const Deps = struct {
    /// Globals that are read, written or have their address taken.
    globals: std.ArrayListUnmanaged(*cy.sym.UserVar) = .empty,

    /// Functions called by name.
    callees: std.ArrayListUnmanaged(*cy.Func) = .empty,

    /// Has a call through a function value or a trait. The callee is not known.
    indirect: bool = false,

    pub fn deinit(self: *Deps, alloc: std.mem.Allocator) void {
        self.globals.deinit(alloc);
        self.callees.deinit(alloc);
    }
};

/// The `Deps` that the code being analyzed belongs to. Null for the main block, which runs after
/// every global is initialized.
fn owner(c: *cy.Chunk) !?*Deps {
    if (c.semaProcs.items.len == 0) {
        return null;
    }
    const proc = c.proc();
    if (proc.global_init_var) |global| {
        return &global.init_deps;
    }
    const func = proc.func orelse return null;
    if (func.deps == null) {
        const deps = try c.alloc.create(Deps);
        deps.* = .{};
        func.deps = deps;
    }
    return func.deps.?;
}

pub fn recordGlobal(c: *cy.Chunk, global: *cy.sym.UserVar) !void {
    const deps = (try owner(c)) orelse return;
    for (deps.globals.items) |it| {
        if (it == global) return;
    }
    try deps.globals.append(c.alloc, global);
}

pub fn recordCall(c: *cy.Chunk, func: *cy.Func) !void {
    if (func.info.generator) {
        // The call only creates the generator. The body runs from `next()`, which is recorded as an
        // indirect call (`recordIndirectCall` at `@gen_next`).
        func.info.escaped = true;
        return;
    }
    const deps = (try owner(c)) orelse return;
    // Repeated calls to one function are usually next to each other.
    if (deps.callees.items.len > 0 and deps.callees.items[deps.callees.items.len - 1] == func) {
        return;
    }
    try deps.callees.append(c.alloc, func);
}

pub fn recordIndirectCall(c: *cy.Chunk) !void {
    const deps = (try owner(c)) orelse return;
    deps.indirect = true;
}

/// The chunks whose `@init` runs in this program, in the order that they run. A chunk comes after
/// the chunks that it imports, so a function of an imported module sees that module's globals
/// initialized. The builtins chunk is first. `@deinit` runs in the reverse order.
pub fn initOrder(compiler: *cy.Compiler, out: *std.ArrayListUnmanaged(*cy.Chunk)) !void {
    const alloc = compiler.alloc;
    const chunks = compiler.chunks.items;
    const visited = try alloc.alloc(bool, chunks.len);
    defer alloc.free(visited);
    @memset(visited, false);
    try out.ensureUnusedCapacity(alloc, chunks.len);

    if (compiler.importCore) {
        visit(compiler, compiler.builtins_chunk, visited, out);
    }
    for (chunks) |chunk| {
        visit(compiler, chunk, visited, out);
    }
}

fn visit(compiler: *cy.Compiler, chunk: *cy.Chunk, visited: []bool, out: *std.ArrayListUnmanaged(*cy.Chunk)) void {
    if (visited[chunk.id]) {
        return;
    }
    visited[chunk.id] = true;
    if (!runsInit(compiler, chunk)) {
        // Initialized by an earlier program, and so are the chunks that it imports.
        return;
    }
    for (chunk.imports.items) |import| {
        visit(compiler, import, visited, out);
    }
    out.appendAssumeCapacity(chunk);
}

/// Besides the chunks of this compile, a chunk from an earlier compile runs `@init` if its code was
/// generated but `@init` never ran: it was loaded by a `VM.validate`, or by evals since then that
/// did not run either (F-05). `VM.eval` marks chunks after a program ran.
fn runsInit(compiler: *cy.Compiler, chunk: *cy.Chunk) bool {
    if (chunk.id >= compiler.chunk_start) {
        return true;
    }
    return chunk.rt_ready and !chunk.rt_inited;
}

/// A host function can call back a function value that it receives.
fn takesFuncValue(func: *cy.Func) bool {
    for (func.sig.params()) |param| {
        switch (param.get_type().kind()) {
            .func_ptr, .func, .func_sym => return true,
            else => {},
        }
    }
    return false;
}

const Walk = struct {
    alloc: std.mem.Allocator,
    visited: std.AutoHashMapUnmanaged(*cy.Func, void) = .empty,
    queue: std.ArrayListUnmanaged(*cy.Func) = .empty,
    indirect: bool = false,

    fn deinit(self: *Walk) void {
        self.visited.deinit(self.alloc);
        self.queue.deinit(self.alloc);
    }

    fn reset(self: *Walk) void {
        self.visited.clearRetainingCapacity();
        self.queue.clearRetainingCapacity();
        self.indirect = false;
    }

    fn push(self: *Walk, func: *cy.Func) !void {
        const res = try self.visited.getOrPut(self.alloc, func);
        if (res.found_existing) {
            return;
        }
        try self.queue.append(self.alloc, func);
    }

    fn pushAll(self: *Walk, funcs: []const *cy.Func) !void {
        for (funcs) |func| {
            try self.push(func);
        }
    }
};

/// Functions that an unknown callee can be: a function whose value is taken somewhere, and a
/// method that implements a trait.
fn collectIndirectTargets(compiler: *cy.Compiler, out: *std.ArrayListUnmanaged(*cy.Func)) !void {
    for (compiler.chunks.items) |chunk| {
        for (chunk.funcs.items) |func| {
            if (func.info.escaped) {
                try out.append(compiler.alloc, func);
            }
        }
    }
    for (compiler.sema.types.items) |type_| {
        if (type_.kind() != .struct_t) {
            continue;
        }
        for (type_.cast(.struct_t).impls()) |impl| {
            try out.appendSlice(compiler.alloc, impl.funcs);
        }
    }
}

/// Runs after sema of every function body. Reports the first initializer that reaches an access
/// to a global that is not initialized at that point.
pub fn check(compiler: *cy.Compiler) !void {
    const alloc = compiler.alloc;

    var order: std.ArrayListUnmanaged(*cy.Chunk) = .empty;
    defer order.deinit(alloc);
    try initOrder(compiler, &order);

    // Position of each global in the initialization order.
    var rank: std.AutoHashMapUnmanaged(*cy.sym.UserVar, u32) = .empty;
    defer rank.deinit(alloc);
    var globals: std.ArrayListUnmanaged(*cy.sym.UserVar) = .empty;
    defer globals.deinit(alloc);
    var has_call = false;
    for (order.items) |chunk| {
        for (chunk.syms.items) |sym| {
            if (sym.type != .userVar) {
                continue;
            }
            const global = sym.cast(.userVar);
            try rank.put(alloc, global, @intCast(globals.items.len));
            try globals.append(alloc, global);
            if (global.init_deps.callees.items.len > 0 or global.init_deps.indirect) {
                has_call = true;
            }
        }
    }
    if (!has_call) {
        return;
    }

    var indirect_targets: std.ArrayListUnmanaged(*cy.Func) = .empty;
    defer indirect_targets.deinit(alloc);
    var has_indirect_targets = false;

    var walk = Walk{ .alloc = alloc };
    defer walk.deinit();

    for (globals.items, 0..) |global, global_rank| {
        const init = &global.init_deps;
        if (init.callees.items.len == 0 and !init.indirect) {
            continue;
        }
        walk.reset();
        try walk.pushAll(init.callees.items);
        var indirect = init.indirect;

        var i: usize = 0;
        while (true) {
            if (indirect and !walk.indirect) {
                walk.indirect = true;
                if (!has_indirect_targets) {
                    try collectIndirectTargets(compiler, &indirect_targets);
                    has_indirect_targets = true;
                }
                try walk.pushAll(indirect_targets.items);
            }
            if (i == walk.queue.items.len) {
                break;
            }
            const func = walk.queue.items[i];
            i += 1;

            if (func.type == .hostFunc and takesFuncValue(func)) {
                indirect = true;
            }
            const deps = func.deps orelse continue;
            for (deps.globals.items) |used| {
                const used_rank = rank.get(used) orelse continue;
                if (used_rank < global_rank) {
                    continue;
                }
                return report(compiler, global, func, used);
            }
            try walk.pushAll(deps.callees.items);
            if (deps.indirect) {
                indirect = true;
            }
        }
    }
}

fn report(compiler: *cy.Compiler, global: *cy.sym.UserVar, func: *cy.Func, used: *cy.sym.UserVar) anyerror {
    const chunk = compiler.getSymChunk(&global.head);
    const node: *cy.ast.Node = global.decl.?.right.?;
    var buf: [256]u8 = undefined;
    const func_name = if (func.type == .userLambda)
        "a lambda"
    else
        std.fmt.bufPrint(&buf, "`{s}`", .{func.name()}) catch "a function";
    if (used == global) {
        return chunk.reportErrorFmt(
            "The initializer of `{}` can reach {}, which accesses `{}` before it is initialized.",
            &.{ v(global.head.name()), v(func_name), v(used.head.name()) }, node);
    }
    return chunk.reportErrorFmt(
        "The initializer of `{}` can reach {}, which accesses the global `{}`. `{}` is initialized after `{}`.",
        &.{ v(global.head.name()), v(func_name), v(used.head.name()), v(used.head.name()), v(global.head.name()) }, node);
}
