const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const stdx = @import("stdx");
const t = stdx.testing;
const cy = @import("cyber.zig");
const C = @import("capi.zig");
const rt = cy.rt;
const ir = cy.ir;
const fmt = @import("fmt.zig");
const v = fmt.v;
const vmc = @import("vmc");
const sema = cy.sema;
const sema_type = cy.sema_type;
const bt = cy.types.BuiltinTypes;
const core_mod = @import("builtins/core.zig");
const meta_mod = @import("builtins/meta.zig");
const cy_mod = @import("builtins/cy.zig");
const math_mod = @import("std/math.zig");
const c_mod = @import("builtins/c.zig");
const io_mod = @import("std/io.zig");
const test_mod = @import("std/test.zig");
const cgen = cy.cgen;
const bcgen = @import("bc_gen.zig");
const bindings = cy.bindings;
const module = cy.module;
const ast = cy.ast;

const log = cy.log.scoped(.compiler);

const f64NegOne = cy.Value.initF64(-1);
const f64One = cy.Value.initF64(1);

pub const dumpCompileErrorStackTrace = !cy.isFreestanding and builtin.mode == .debug and !cy.isWasm and true;

const Root = @This();

pub var debug = false;

pub const Compiler = struct {
    alloc: std.mem.Allocator,
    vm: *cy.VM,

    // For BC codegen.
    debug_tables: std.ArrayList(cy.DebugTableEntry),

    // Compile-time heap.
    heap: cy.Heap,

    /// The value of a REPL eval's last top level expression (`sema.semaMainResultStmt`), copied after the run.
    /// Kept here rather than in `VM`, whose field layout `vm.h` mirrors with measured padding.
    main_res: ?cy.vm.MainResult = null,

    /// The future that a suspended eval waits for (`CL_AWAIT`), or null when no eval is suspended.
    /// The main stack and the bytecode stay as they are until `VM.resumeEval` or `VM.abandonEval`.
    await_future: ?*cy.heap.FutureValue = null,

    /// The futures of a suspended `Future.wait_any`. Empty when the eval waits for one future.
    /// Points into the list that the script passed, which stays in place while the eval is suspended.
    await_any: []const *cy.heap.FutureValue = &.{},
    /// Storage of `await_any` when the list is collected from the fibers (`Fiber.wait_ready`).
    await_buf: std.ArrayListUnmanaged(*cy.heap.FutureValue) = .empty,

    reports: std.ArrayList(Report),

    /// Whether a compile error summary marks the reported source range with ANSI escape codes
    /// (`cl_vm_set_error_color`). Off by default: a host that logs or parses the summary gets plain text.
    report_color: bool = false,

    /// Go on after a compile error where that is safe, to report more than one (`cl_vm_set_error_recovery`).
    /// A body (the main block, a function, a method) that fails is abandoned at its first error and the
    /// next body is checked. Errors outside of a body (syntax, declarations) still end the compile.
    /// The compile fails as before, with every report in `reports`. Kept across `cl_vm_reset` like `report_color`.
    recover: bool = false,

    /// Record what the names of the main source refer to (`cl_vm_set_symbol_info`, `refs.zig`).
    /// Kept across `cl_vm_reset` like `report_color`. The references are those of the last compile.
    record_refs: bool = false,
    refs: std.ArrayList(cy.refs.Ref) = .empty,
    /// The text that the last `refs.find` returned.
    ref_detail: []const u8 = "",
    /// The main chunk that `refs` belongs to. Null before a compile reached its main chunk and after a reset:
    /// `main_chunk` is undefined or freed then, and a query has nothing to answer from.
    refs_main: ?*cy.Chunk = null,
    /// The failed allocations of the allocator when the compile started. Recovery stops when it moved.
    failed_allocs_at_start: usize = 0,
    /// The ranges that the last `refs.findAll` returned.
    ref_ranges: std.ArrayList(cy.refs.Range) = .empty,
    /// The tokens that the last `refs.tokens` returned.
    ref_tokens: std.ArrayList(cy.refs.Token) = .empty,
    /// Owns the items that the last `refs.members` or `refs.scope` returned.
    ref_arena: ?std.heap.ArenaAllocator = null,
    
    /// Sema model resulting from the sema pass.
    sema: sema.Sema,

    /// Determines how modules are loaded.
    loader: C.ModuleLoaderFn,

    /// Determines how module uris are resolved.
    resolver: C.ResolverFn,

    dl_resolver: C.DlResolverFn,

    /// Compilation units for iteration.
    chunks: std.ArrayList(*cy.Chunk),

    /// Unowned reference to the builtins chunk.
    builtins_chunk: *cy.Chunk,

    /// Resolved URI to chunk.
    chunk_map: std.StringHashMapUnmanaged(*cy.Chunk),

    /// Key is either a *Sym, *Func, or *cy.types.FuncPtr (for extern func ptrs).
    genSymMap: std.AutoHashMapUnmanaged(*anyopaque, bcgen.Sym),

    /// Key to VM.vtables index.
    gen_vtables: std.AutoHashMapUnmanaged(bcgen.VtableKey, u32),

    config: C.CompileConfig,

    /// Tracks whether an error was set from the API.
    hasApiError: bool,
    apiError: []const u8, // Duped so Cyber owns the msg.

    /// Whether core should be imported.
    importCore: bool = true,

    main_chunk: *cy.Chunk,
    main_func: ?*cy.Func,

    program_ir: *ir.Stmt,

    /// A chunk is reserved for the libcyber API.
    api_chunk: *cy.Chunk,

    find_type_cache: std.StringHashMapUnmanaged(*cy.Type),

    /// Whether this is a subsequent compilation reusing the same state. Set after the first successful compile.
    cont: bool,

    /// The first compile of this VM (or since a reset) failed. The next `VM.eval` resets the VM before compiling.
    first_compile_failed: bool,

    /// A compile ended on an allocation that failed. What it
    /// left behind (chunks, symbols, types, bytecode) can be half built in ways a compile error never leaves, so
    /// the next `VM.eval` or `VM.validate` resets the VM first, like after a failed first compile. Persisted
    /// locals and declarations of earlier evals are lost.
    alloc_failed: bool = false,

    /// Set by a host callback that cannot return an error: a C API function that binds into a module
    /// (`cl_mod_add_func`) or a builtin type creator. The compile that called it fails with this error.
    host_error: ?anyerror = null,

    /// The previous compile failed. Its main chunk's own declarations are not carried over by `persist_main`.
    last_compile_failed: bool,

    /// The previous compile was a `VM.validate`: its main chunk was never run. Like a failed compile, its own
    /// declarations are not carried over by `persist_main` (F-05).
    main_discarded: bool,

    chunk_start: u32,
    type_start: u32,

    /// What a failed compile made that later compiles can still reach: instances of templates declared in
    /// surviving chunks, with arguments from surviving chunks, and the functions and types that belong to them.
    /// They sit in the template caches (`sort[str]`) and in fields of surviving types (`copy_ctor`), but the
    /// chunks that hold them are not compiled again, so their bodies were never checked or generated.
    /// The next compile checks and generates them in its main chunk. The chunks that own them still destroy them.
    carry_funcs: std.ArrayListUnmanaged(*cy.Func) = .empty,
    carry_syms: std.ArrayListUnmanaged(*cy.Sym) = .empty,
    /// The body of a carried function failed in this compile (`semaCarriedFuncs`).
    carried_failed: bool = false,

    c_includes: std.ArrayList([]const u8),
    c_flags: std.ArrayList([]const u8),

    build_flags: std.StringHashMapUnmanaged(void),
    build_options: std.StringHashMapUnmanaged([]const u8),

    /// Useful for custom panic handler to indicate whether it failed at compile-time or runtime.
    compiling: bool,

    pub fn init(self: *Compiler, vm: *cy.VM) !void {
        self.* = .{
            .alloc = vm.alloc,
            .vm = vm,
            .heap = try cy.Heap.init(vm, null, vm.alloc, undefined),
            .reports = .empty,
            .sema = try sema.Sema.init(vm.alloc, self),
            .loader = default_loader,
            .resolver = default_resolver,
            .dl_resolver = default_dl_resolver,
            .chunks = .empty,
            .builtins_chunk = undefined,
            .chunk_map = .empty,
            .genSymMap = .empty,
            .gen_vtables = .empty,
            .config = C.defaultCompileConfig(), 
            .hasApiError = false,
            .apiError = "",
            .main_func = null,
            .main_chunk = undefined,
            .program_ir = undefined,
            .api_chunk = undefined,
            .cont = false,
            .first_compile_failed = false,
            .last_compile_failed = false,
            .main_discarded = false,
            .chunk_start = 0,
            .type_start = 0,
            .find_type_cache = .empty,
            .c_includes = .empty,
            .c_flags = .empty,
            .compiling = false,
            .debug_tables = .empty,
            .build_flags = .empty,
            .build_options = .empty,
        };
        self.heap.sema = &self.sema;

        self.api_chunk = try createModuleUnmanaged(self, "api", "");
        self.api_chunk.resolve_name_fn = sema.apiResolveName;

        try self.reinitPerRun();    
    }

    pub fn deinit(self: *Compiler, comptime reset: bool) void {
        // The chunks own what the lists point to.
        if (reset) {
            self.carry_funcs.clearRetainingCapacity();
            self.carry_syms.clearRetainingCapacity();
        } else {
            self.carry_funcs.deinit(self.alloc);
            self.carry_syms.deinit(self.alloc);
        }
        self.await_buf.clearAndFree(self.alloc);
        self.await_any = &.{};
        self.vm.log_tracev("Deinit compiler reset={}", .{reset});
        self.clearReports();
        if (!reset) {
            self.refs.deinit(self.alloc);
            self.ref_ranges.deinit(self.alloc);
            self.ref_tokens.deinit(self.alloc);
            self.reports.deinit(self.alloc);
        }

        if (reset) {
            self.debug_tables.clearRetainingCapacity();
        } else {
            self.debug_tables.deinit(self.alloc);
        }

        for (self.chunks.items) |chunk| {
            chunk.deinitCtValues();
        }
        if (self.alloc_failed or reset) {
            // A compile that ran out of memory can abandon a compile-time value half built: a string or a
            // buffer whose owner was never created. Every value that a sym owns is released by now, and the
            // types that give each object's size are still alive.
            // A reset sweeps as well. A compile leaves a few compile-time objects that nothing owns, and the
            // heap keeps its pages across a reset: a host that compiles again and again with one VM (the
            // language server) would keep every one of them and grow by a page whenever they filled one (F-114).
            self.heap.sweep();
        }
        for (self.chunks.items) |chunk| {
            log.tracev("Deinit chunk `{s}`", .{chunk.srcUri});
            if (chunk.on_destroy) |on_destroy| {
                on_destroy(@ptrCast(self.vm), @ptrCast(chunk.sym));
            }
            chunk.deinit();
        }
        if (!reset) {
            self.api_chunk.deinit();
            self.alloc.free(self.api_chunk.src);
            self.alloc.destroy(self.api_chunk);
        } else {
            self.api_chunk.fallback_modules.clearRetainingCapacity();
        }

        // Free chunk sources afterwards since syms may depend on them for debugging (type names).
        for (self.chunks.items) |chunk| {
            if (chunk.manage_src) {
                chunk.alloc.free(chunk.src);
            }
            self.alloc.destroy(chunk);
        }

        {
            var iter = self.find_type_cache.keyIterator();
            while (iter.next()) |spec| {
                self.alloc.free(spec.*);
            }
        }
        for (self.c_includes.items) |import| {
            self.alloc.free(import);
        }
        for (self.c_flags.items) |flag| {
            self.alloc.free(flag);
        }
        {
            var iter = self.build_flags.keyIterator();
            while (iter.next()) |key| {
                self.alloc.free(key.*);
            }
        }
        {
            var iter = self.build_options.iterator();
            while (iter.next()) |entry| {
                self.alloc.free(entry.key_ptr.*);
                self.alloc.free(entry.value_ptr.*);
            }
        }
        if (reset) {
            self.chunks.clearRetainingCapacity();
            self.chunk_map.clearRetainingCapacity();
            self.genSymMap.clearRetainingCapacity();
            self.gen_vtables.clearRetainingCapacity();
            self.find_type_cache.clearRetainingCapacity();
            self.c_includes.clearRetainingCapacity();
            self.c_flags.clearRetainingCapacity();
            self.build_options.clearRetainingCapacity();
        } else {
            self.chunks.deinit(self.alloc);
            self.chunk_map.deinit(self.alloc);
            self.genSymMap.deinit(self.alloc);
            self.gen_vtables.deinit(self.alloc);
            self.find_type_cache.deinit(self.alloc);
            self.c_includes.deinit(self.alloc);
            self.c_flags.deinit(self.alloc);
            self.build_flags.clearRetainingCapacity();
            self.build_options.clearRetainingCapacity();
        }

        // Chunks depends on modules.
        self.sema.deinit(self.alloc, reset);

        if (reset) {
            // Every slot is free after the sweep. The pages that the last compile grew go back to the allocator.
            self.heap.releaseFreePages();
        }
        self.heap.deinit(reset);

        self.alloc.free(self.apiError);
        self.apiError = "";
    }

    pub fn reinitPerRun(self: *Compiler) !void {
        self.clearReports();
    }

    pub fn clearReports(self: *Compiler) void {
        for (self.reports.items) |*report| {
            report.deinit(self.alloc);
        }
        self.reports.clearRetainingCapacity();
        // The references point into the symbols and sources of the compile that the reports are from.
        self.refs.clearRetainingCapacity();
        self.refs_main = null;
        self.ref_ranges.clearRetainingCapacity();
        self.ref_tokens.clearRetainingCapacity();
        if (self.ref_arena) |*arena| arena.deinit();
        self.ref_arena = null;
        self.alloc.free(self.ref_detail);
        self.ref_detail = "";
    }

    pub fn newTypes(self: *Compiler) []*cy.Type {
        return self.sema.types.items[self.type_start..];
    }

    pub fn newChunks(self: *Compiler) []*cy.Chunk {
        return self.chunks.items[self.chunk_start..];
    }

    pub fn compile(self: *Compiler, uri: []const u8, src: ?[]const u8, config: C.CompileConfig) !CompileResult {
        self.compiling = true;
        defer self.compiling = false;
        
        // The copy-and-patch JIT was removed. See docs/decisions/project_direction.md.
        if (config.backend == C.BackendJIT) {
            _ = try self.addReportFmt(.compile_err, "The JIT backend is not supported. Use the bytecode VM (default) or the C backend (-tcc, -cc).", &.{}, null, 0);
            return error.CompileError;
        }

        const first_compile = !self.cont;
        // `VM.validate` sets this again after the compile.
        defer self.main_discarded = false;
        const acct = cy.MemAccount.of(self.alloc);
        const failed_allocs = if (acct) |a| a.failed.load(.monotonic) else 0;
        self.failed_allocs_at_start = failed_allocs;
        self.host_error = null;
        var attempts: u32 = 0;
        const res = while (true) {
            self.chunk_start = @intCast(self.chunks.items.len);
            self.type_start = @intCast(self.sema.types.items.len);
            self.carried_failed = false;
            break self.compileInner2(uri, src, config) catch |err_| {
                // A callback that could not return its error ended the compile with a bare `CompileError` or null.
                const err = self.host_error orelse err_;
                self.last_compile_failed = true;
                // A refused allocation can surface as any error, including a compile error reported by a comptime
                // function (`error.OutOfMemory`), so the allocator is asked rather than the error. Another error
                // that is not a compile error (an internal error of the compiler) unwinds like a compile error
                // does and keeps the session.
                if (err == error.OutOfMemory or err == error.WriteFailed or (acct != null and acct.?.failed.load(.monotonic) != failed_allocs)) {
                    self.alloc_failed = true;
                }
                // A failed first compile leaves core types, the core chunk and a main chunk half built while `cont`
                // stays false. Compiling again on top of that loaded core twice (SIGSEGV after a syntax error,
                // `@program_init has already been declared` after a sema error, F-04). `VM.eval` resets the VM first.
                if (first_compile) {
                    self.first_compile_failed = true;
                } else if (!self.alloc_failed) {
                    // The session goes on. What the failed compile left in caches is completed by the next compile.
                    self.carryFailedCompile() catch {
                        self.alloc_failed = true;
                    };
                    // The body of a template instance that an earlier failed compile left behind does not compile
                    // (`Map[[]int, int]` after an error ahead of it). The instance is marked failed and no longer
                    // carried. The error is not this source's, so the source is compiled again without it. Each
                    // attempt fails at least one more instance, and only instances that failed compiles made.
                    if (self.carried_failed and !self.alloc_failed and attempts < max_carry_attempts) {
                        attempts += 1;
                        self.clearReports();
                        continue;
                    }
                }
                if (dumpCompileErrorStackTrace and !C.silent()) {
                    std.debug.dumpErrorReturnTrace(@errorReturnTrace().?);
                }
                if (err == error.CompileError) {
                    return err;
                }
                // Without memory for the report the compile still ends in a compile error. Its summary is empty.
                if (self.chunks.items.len > 0) {
                    // Report other errors using the main chunk.
                    _ = self.main_chunk.addReportFmt("Error: {}", &.{v(err)}, null) catch 0;
                    return error.CompileError;
                } else {
                    _ = self.addReportFmt(.compile_err, "Error: {}", &.{v(err)}, null, 0) catch 0;
                    return error.CompileError;
                }
            };
        };

        // Successful.
        self.cont = true;
        self.last_compile_failed = false;
        if (!config.skip_codegen) {
            // Checked and generated by this compile.
            self.carry_funcs.clearRetainingCapacity();
            self.carry_syms.clearRetainingCapacity();
        }
        return res;
    }

    /// Called after a compile failed in a session that goes on (not the first compile, no refused allocation).
    /// The failed compile's chunks are not compiled again: its main chunk is replaced by the next one, and a
    /// module that it loaded first leaves the module cache, so the next `use` loads it again. What it added to
    /// surviving chunks stays reachable, though: a template declared in a surviving chunk keeps the instances
    /// it expanded (`sort[str]`), and a surviving type keeps the functions derived for it (`copy_ctor`). Their
    /// bodies were checked in a chunk that is gone, or not at all, and no code was generated for them. They are
    /// collected here and completed by the next compile (`carry_funcs`, `carry_syms`).
    fn carryFailedCompile(self: *Compiler) !void {
        const start = self.chunk_start;
        const type_start = self.type_start;
        var funcs: std.ArrayListUnmanaged(*cy.Func) = .empty;
        errdefer funcs.deinit(self.alloc);
        var syms: std.ArrayListUnmanaged(*cy.Sym) = .empty;
        errdefer syms.deinit(self.alloc);

        // Carried by an earlier failed compile and not completed since.
        for (self.carry_funcs.items) |func| {
            if (carryFunc(func, start, type_start)) try funcs.append(self.alloc, func);
        }
        for (self.carry_syms.items) |sym| {
            if (survives(sym, start, type_start, 0)) try syms.append(self.alloc, sym);
        }
        for (self.newChunks()) |chunk| {
            if (chunk != self.main_chunk and !chunk.evicted) {
                if (self.chunk_map.get(chunk.srcUri)) |cached| {
                    if (cached == chunk) _ = self.chunk_map.remove(chunk.srcUri);
                }
                chunk.evicted = true;
            }
            for (chunk.funcs.items) |func| {
                if (carryFunc(func, start, type_start)) try funcs.append(self.alloc, func);
            }
            for (chunk.syms.items) |sym| {
                if (sym.type == .type and survives(sym, start, type_start, 0)) try syms.append(self.alloc, sym);
            }
        }
        self.carry_funcs.deinit(self.alloc);
        self.carry_funcs = funcs;
        self.carry_syms.deinit(self.alloc);
        self.carry_syms = syms;
    }

    fn compileInner2(self: *Compiler, uri: []const u8, src_opt: ?[]const u8, config: C.CompileConfig) !CompileResult {
        const res = try self.compileInner(uri, src_opt, config);
        // A callback failed without a way to say so and the compile went on. Nothing was run yet.
        if (self.host_error) |err| {
            if (config.backend != C.BackendVM and !config.skip_codegen) res.aot.deinit(self.alloc);
            return err;
        }
        return res;
    }

    /// Wrap compile so all errors can be handled in one place.
    fn compileInner(self: *Compiler, uri: []const u8, src_opt: ?[]const u8, config: C.CompileConfig) !CompileResult {
        self.config = config;

        if (!self.cont) {
            try reserveCoreTypes(self);
        }

        // TODO: Types and symbols should be loaded recursively for single-threaded.
        //       Separate into two passes one for types and function signatures, and
        //       another for function bodies.

        const prev_main = self.main_chunk;
        if (self.cont) {
            // Evict the main chunk from cache so a new one can be created.
            _ = self.chunk_map.remove(prev_main.srcUri);
        }

        var mainChunk: *cy.Chunk = undefined;
        var buf: [4096]u8 = undefined;
        const r_uri = try resolveModuleUri(self, &buf, uri);
        if (src_opt) |src_temp| {
            const src_dup = try self.alloc.dupe(u8, src_temp);
            errdefer self.alloc.free(src_dup);
            mainChunk = try ensureModule2(self, r_uri, src_dup);
        } else {
            mainChunk = try ensureModule(self, r_uri);
        }
        self.main_chunk = mainChunk;
        // Queries are answered for a compile that recorded. Without the recording a partial answer (the names
        // in declarations, but no locals) would look like a complete one.
        self.refs_main = if (self.record_refs) mainChunk else null;

        // Load core module. Added as fallback module for each user module.
        if (self.importCore) {
            if (!self.cont) {
                const core_uri = try cy.compiler.resolveModuleUriFrom(mainChunk, &buf, "core", null);
                self.builtins_chunk = try ensureModule(self, core_uri);
            }
            try self.api_chunk.fallback_modules.append(self.alloc, self.builtins_chunk.sym.sym());
        }

        if (self.cont) {
            if (config.persist_main) {
                // Use all *resolved* top level syms from previous main.
                // If a symbol wasn't resolved, it either failed during compilation or didn't end up getting used.
                var iter = prev_main.sym.getMod().symMap.iterator();
                while (iter.next()) |e| {
                    const name = e.key_ptr.*;
                    const sym = e.value_ptr.*;

                    // A failed eval contributes nothing of its own: its functions have no bytecode and its types may
                    // be half resolved. Neither does a validated source, which never ran (F-05). In both cases the
                    // aliases inherited from earlier evals are still carried over.
                    if ((self.last_compile_failed or self.main_discarded) and sym.type != .use_alias) {
                        continue;
                    }
                    // A module that a failed compile loaded first is loaded again by the next `use`.
                    if (sym.type == .use_alias and aliasesEvicted(sym.cast(.use_alias))) {
                        continue;
                    }

                    const resolved = switch (sym.type) {
                        .type => b: {
                            const type_sym = sym.cast(.type);
                            break :b type_sym.type.isResolved();
                        },
                        .func => b: {
                            // Hidden funcs are reserved again for the new main chunk.
                            if (std.mem.eql(u8, sym.name(), "@program_init")) {
                                continue;
                            }
                            if (std.mem.eql(u8, sym.name(), "@program_deinit")) {
                                continue;
                            }
                            break :b sym.cast(.func).isResolved();
                        },
                        else => true,
                    };
                    if (!resolved) {
                        continue;
                    }

                    const alias = try mainChunk.reserveUseAlias(@ptrCast(mainChunk.sym), name, null);
                    if (sym.type == .use_alias) {
                        alias.sym = sym.cast(.use_alias).sym;
                    } else {
                        alias.sym = sym;
                    }
                    alias.resolved = true;
                }
            }
        }

        // Resolve core first.
        if (!self.cont) {
            try loadBuiltinChunk(self.builtins_chunk);
            try resolveChunkSyms(self.builtins_chunk);
        }

        var id: u32 = self.chunk_start;
        while (id < self.chunks.items.len) : (id += 1) {
            const chunk = self.chunks.items[id];
            if (chunk == self.builtins_chunk) {
                continue;
            }
            try loadChunk(chunk);
            try resolveChunkSyms(chunk);
        }

        // Functions that a failed compile left behind are checked again in this compile's main chunk.
        for (self.carry_funcs.items) |func| {
            func.info.emitted = false;
            func.info.bc_inline = 0;
        }

        // Clear the previous eval's `main`, otherwise a later eval without one is rejected.
        self.main_func = null;
        if (self.main_chunk.sym.getMod().getSym("main")) |main_func| {
            if (main_func.type != .func) {
                return self.main_chunk.reportError("Expected `main` to be a function.", null);
            }
            const sym = main_func.cast(.func);
            if (sym.numFuncs > 1) {
                return self.main_chunk.reportError("Expected only one `main` function.", sym.first.decl);
            }
            if (sym.first.sig.params().len > 0) {
                return self.main_chunk.reportError("Expected no parameters for `main` function.", sym.first.decl);
            }
            self.main_func = sym.first;
        }

        const program_init = try reserve_hidden_func(mainChunk, "@program_init");
        const program_deinit = try reserve_hidden_func(mainChunk, "@program_deinit");

        log.tracev("emit @program_init.", .{});
        try emit_program_init_func(mainChunk, program_init);
        log.tracev("emit @program_deinit.", .{});
        try emit_program_deinit_func(mainChunk, program_deinit);

        // Generate main first to expand any templates.
        log.tracev("emit program.", .{});
        if (self.recover) {
            var marks = try RecoverMarks.take(self);
            defer marks.deinit(self);
            if (sema.sema_program(mainChunk, self.main_func)) |program_ir| {
                self.program_ir = program_ir;
            } else |err| {
                try recoverBody(self, mainChunk, &marks, err);
            }
        } else {
            self.program_ir = try sema.sema_program(mainChunk, self.main_func);
        }

        // Before the chunks: what these bodies expand is appended to the main chunk and checked with it.
        try semaCarriedFuncs(self, mainChunk);

        // Perform sema on all chunks.
        log.tracev("Perform sema.", .{});
        for (self.newChunks()) |chunk| {
            performChunkSema(chunk) catch |err| {
                if (err == error.CompileError) {
                    return err;
                } else {
                    // Wrap all other errors as a CompileError.
                    _ = try chunk.addReportFmt("error.{}", &.{v(err)}, chunk.curNode);
                    return error.CompileError;
                }
                return err;
            };
        }

        // With recovery the bodies that failed were skipped. What follows needs all of them.
        if (self.reports.items.len > 0) {
            return error.CompileError;
        }

        // Pass through type syms.
        for (self.newTypes()) |type_| {
            try resolveImplFuncs(self, type_);
        }
        for (self.carry_syms.items) |sym| {
            try resolveImplFuncs(self, sym.cast(.type).type);
        }

        // A global initializer must not reach a global that is not initialized yet (F-88).
        try cy.global_init.check(self);

        if (!config.skip_codegen) {
            log.tracev("Perform codegen.", .{});

            switch (self.config.backend) {
                C.BackendTCC, C.BackendCC => {
                    if (cy.isWasm or !cy.hasCLI) return error.Unsupported;
                    const res = try cgen.gen(self);
                    return .{ .aot = res };
                },
                C.BackendLLVM => {
                    return error.TODO;
                },
                C.BackendVM => {
                    try bcgen.genAll(self);
                    return .{
                        .vm = &self.main_chunk.buf,
                    };
                },
                else => return error.Unsupported,
            }
            log.tracev("Done. Perform codegen.", .{});
        }

        return CompileResult{ .vm = undefined };
    }

    pub fn addReportFmt(self: *Compiler, report_t: ReportType, format: []const u8, args: []const fmt.FmtValue, chunk: ?cy.ChunkId, loc: u64) !usize {
        const msg = try fmt.allocFormat(self.alloc, format, args);
        return self.addReportConsume(report_t, msg, chunk, loc);
    }

    /// Assumes `msg` is heap allocated. It is freed when the report can not be added.
    pub fn addReportConsume(self: *Compiler, report_t: ReportType, msg: []const u8, chunk: ?cy.ChunkId, loc: u64) !usize {
        errdefer self.alloc.free(msg);
        const id = self.reports.items.len;
        try self.reports.append(self.alloc, .{
            .type = report_t,
            .chunk = chunk orelse cy.NullId,
            .loc = loc,
            .msg = msg,
        });
        return id;
    }

    pub fn addReport(self: *Compiler, report_t: ReportType, msg: []const u8, chunk: ?cy.ChunkId, loc: u64) !usize {
        const dupe = try self.alloc.dupe(u8, msg);
        return self.addReportConsume(report_t, dupe, chunk, loc);
    }

    pub fn getSymChunk(self: *Compiler, sym: *cy.Sym) *cy.Chunk {
        return self.chunks.items[sym.declNode().src()];
    }
};

const ReportType = enum(u8) {
    token_err,
    parse_err,
    compile_err,

    /// Additional context trace.
    context,
};

pub const Report = struct {
    type: ReportType,
    msg: []const u8,

    /// If NullId, then the report comes from an aggregate step.
    chunk: cy.ChunkId,

    /// srcPos if token_err or parse_err
    /// *ast.Node if compile_err
    /// If NullId, then the report does not have a location.
    loc: u64,

    /// Backtrace.
    next: ?*Report = null,

    pub fn deinit(self: *Report, alloc: std.mem.Allocator) void {
        if (self.next) |next| {
            next.deinit(alloc);
            alloc.destroy(next);
        }
        alloc.free(self.msg);
    }
};

pub const AotCompileResult = struct {
    exePath: [:0]const u8,

    pub fn deinit(self: AotCompileResult, alloc: std.mem.Allocator) void {
        alloc.free(self.exePath);
    }
};

/// Tokenize and parse.
/// Parser pass collects static declaration info.
pub fn performChunkParse(self: *Compiler, chunk: *cy.Chunk) !void {
    _ = self;
    var tt = cy.debug.timer();

    const S = struct {
        fn parserReport(p: *cy.Parser, format: []const u8, args: []const cy.fmt.FmtValue, pos: u32) anyerror {
            const c: *cy.Chunk = @ptrCast(@alignCast(p.ctx));
            _ = try c.compiler.addReportFmt(.parse_err, format, args, c.id, pos);
            return error.ParseError;
        }

        fn tokenizerReport(ctx: *anyopaque, format: []const u8, args: []const cy.fmt.FmtValue, pos: u32) anyerror!void {
            const c: *cy.Chunk = @ptrCast(@alignCast(ctx));
            _ = try c.compiler.addReportFmt(.token_err, format, args, c.id, pos);
            return error.TokenError;
        }
    };

    chunk.parser.reportFn = S.parserReport;
    chunk.parser.tokenizerReportFn = S.tokenizerReport;
    chunk.parser.ctx = chunk;

    const res = try chunk.parser.parse(chunk.src, chunk.id, .{});
    tt.endPrintVerbose("parse");
    // Update buffer pointers so success/error paths can access them.
    chunk.updateAstView(res.ast);
    if (res.has_error) {
        return error.CompileError;
    }
}

/// Sema pass.
/// Symbol resolving, type checking, and builds the model for codegen.
fn performChunkSema(c: *cy.Chunk) !void {
    // try sema.pushChunkResolveContext(chunk, null);
    // defer sema.popResolveContext(chunk);

    if (c.has_static_init) {
        const init = c.sym.getMod().getSym("@init").?.cast(.func).first;
        try emit_chunk_init_func(c, init);

        const deinit = c.sym.getMod().getSym("@deinit").?.cast(.func).first;
        try emit_chunk_deinit_func(c, deinit);
    }

    try semaChunkFuncs(c);
}

/// Compiles of one source after carried bodies failed (`Compiler.compile`).
const max_carry_attempts = 8;

/// Reports after which recovery stops. A compile that is this wrong gains nothing from more of them.
const max_recover_reports = 100;

/// The stacks of every chunk before a body is checked. The body belongs to one chunk, but a template that it
/// expands is resolved in the chunk that declares it.
const RecoverMarks = struct {
    marks: []sema.StackMark,

    fn take(self: *Compiler) !RecoverMarks {
        const marks = try self.alloc.alloc(sema.StackMark, self.chunks.items.len);
        for (self.chunks.items, 0..) |chunk, i| {
            marks[i] = sema.StackMark.take(chunk);
        }
        return .{ .marks = marks };
    }

    fn deinit(self: *RecoverMarks, compiler: *Compiler) void {
        compiler.alloc.free(self.marks);
    }
};

/// A body failed with `err`. Makes sure the error is reported, drops what the body left on the stacks and
/// returns, so that the caller goes on with the next body. Returns the error if the compile has to end.
fn recoverBody(self: *Compiler, c: *cy.Chunk, marks: *const RecoverMarks, err: anyerror) !void {
    // Without memory there is nothing to go on with. A refused allocation can arrive as any error, a compile
    // error included, so the allocator is asked like `compile` does. What an allocation failure abandoned half
    // built is not something the next body can be checked against.
    if (err == error.OutOfMemory or self.alloc_failed or self.host_error != null) {
        return err;
    }
    if (cy.MemAccount.of(self.alloc)) |acct| {
        if (acct.failed.load(.monotonic) != self.failed_allocs_at_start) return err;
    }
    if (err != error.CompileError) {
        // Wrap all other errors as a CompileError.
        _ = try c.addReportFmt("error.{}", &.{v(err)}, c.curNode);
    }
    if (self.reports.items.len == 0 or self.reports.items.len >= max_recover_reports) {
        return error.CompileError;
    }
    for (marks.marks, 0..) |mark, i| {
        mark.restore(self.chunks.items[i]);
    }
}

fn semaChunkFuncs(c: *cy.Chunk) !void {
    if (c.compiler.recover) {
        return semaChunkFuncsRecover(c);
    }
    // Iterate funcs with explicit index since lambdas could be appended.
    var i: u32 = 0;
    while (i < c.funcs.items.len) : (i += 1) {
        const func = c.funcs.items[i];
        switch (func.type) {
            .userFunc => {
                // Skip strictly const eval functions.
                if (func.info.const_eval_only) {
                    continue;
                }

                // Skip already emitted functions such as `@init`.
                if (func.info.emitted) {
                    continue;
                }
                log.tracev("sema func: {s}", .{func.name()});
                // A template instance whose body does not compile is not handed out or carried again.
                errdefer if (ownerInstance(func)) |inst| {
                    inst.failed = true;
                };
                if (func.isMethod()) {
                    try sema.semaMethodBody(c, func);
                } else {
                    try sema.semaFuncBody(c, func);
                }
            },
            .extern_ => {
                if (!func.data.extern_.has_impl) {
                    continue;
                }
                if (func.info.emitted) {
                    continue;
                }
                try sema.semaFuncBody(c, func);
            },
            else => {},
        }
    }
}

/// `semaChunkFuncs` with error recovery: a function that fails is skipped and the next one is checked.
fn semaChunkFuncsRecover(c: *cy.Chunk) !void {
    const self = c.compiler;
    var i: u32 = 0;
    while (i < c.funcs.items.len) : (i += 1) {
        const func = c.funcs.items[i];
        const has_body = switch (func.type) {
            .userFunc => !func.info.const_eval_only,
            .extern_ => func.data.extern_.has_impl,
            else => false,
        };
        if (!has_body or func.info.emitted) {
            continue;
        }
        // An instance of a function template whose signature failed to resolve. The error is reported already.
        if (!func.isResolved()) {
            continue;
        }
        var marks = try RecoverMarks.take(self);
        defer marks.deinit(self);
        const res = if (func.type == .userFunc and func.isMethod())
            sema.semaMethodBody(c, func)
        else
            sema.semaFuncBody(c, func);
        res catch |err| {
            try recoverBody(self, c, &marks, err);
            // The body is not checked again when something else refers to the function.
            func.info.emitted = true;
        };
    }
}

fn emit_chunk_init_func(c: *cy.Chunk, init: *cy.Func) !void {
    log.tracev("emit @init.", .{});

    try sema.pushChunkResolveContext(c, null);
    defer sema.popResolveContext(c);

    _ = try sema.pushFuncProc(c, init);

    // Emit in correct dependency order.
    for (0..c.syms.items.len) |i| {
        const sym = c.syms.items[i];
        switch (sym.type) {
            .hostVar => {
                try sema.semaTraceNopFmt(c, "init {s}", .{sym.name()}, init.decl.?);
            },
            .userVar => {
                try sema.semaTraceNopFmt(c, "init {s}", .{sym.name()}, init.decl.?);
                const user_var = sym.cast(.userVar);
                try sema.semaUserVarInit(c, user_var, null);
            },
            else => {},
        }
    }

    try sema.procPrologue(c);
    try sema.popFuncBlock(c);
}

/// Invoke any chunk init functions.
/// Invoke @initBindLib if necessary.
fn emit_program_init_func(c: *cy.Chunk, start: *cy.Func) !void {
    try sema.pushChunkResolveContext(c, null);
    defer sema.popResolveContext(c);

    _ = try sema.pushFuncProc(c, start);

    // A chunk is initialized after the chunks that it imports (`global_init.initOrder`).
    var order: std.ArrayListUnmanaged(*cy.Chunk) = .empty;
    defer order.deinit(c.alloc);
    try cy.global_init.initOrder(c.compiler, &order);

    var has_extern_func = false;
    for (order.items) |chunk| {
        // Besides the chunks of this compile, a chunk compiled earlier by `VM.validate` is initialized here
        // if no program has run since (F-05). Its `@init` already exists and has bytecode.
        const pending = chunk.id < c.compiler.chunk_start;
        if (chunk.has_extern_func) {
            has_extern_func = true;
        }
        if (!chunk.has_static_init) {
            continue;
        }

        const init = if (pending)
            chunk.sym.getMod().getSym("@init").?.cast(.func).first
        else
            try reserve_hidden_func(chunk, "@init");

        const call = try sema.sema_call_ir(c, init, &.{}, c.ast.null_node);
        try sema.sema_discard(c, call, c.ast.null_node);
    }

    if (has_extern_func) {
        const init_bind_lib = (try c.get_chunk_by_uri("c")).?.sym.getMod().getSym("@initBindLib").?.cast(.func).first;
        const expr = try sema.sema_call_ir(c, init_bind_lib, &.{}, c.ast.null_node);
        try sema.sema_discard(c, expr, c.ast.null_node);
    }

    try sema.procPrologue(c);
    try sema.popFuncBlock(c);
}

fn reserve_hidden_func(c: *cy.Chunk, name: []const u8) !*cy.Func {
    const name_n = try c.parser.ast.genIdentNode(c.alloc, name);
    const decl = try c.parser.ast.newNode(.funcDecl, .{
        .name = @ptrCast(name_n),
        .parent = null,
        .attrs = .{ .ptr = undefined, .len = 0 },
        .with = null,
        .params = .{ .ptr = undefined, .len = 0 },
        .ret = null,
        .stmts = .{ .ptr = undefined, .len = 0 },
        .pos = cy.NullId,
        .sig_t = .func,
        .hidden = true,
        .generator = false,
        .scope_ret = false,
    });
    c.updateAstView(c.parser.ast.view());

    const config = cy.sym.FuncConfig{
        .is_method = false,
        .extern_ = false,
    };
    const func = try c.reserveUserFunc(@ptrCast(c.sym), name, config, decl);

    const sig_id = try c.sema.ensureFuncSig(&.{}, c.sema.void_t);
    try c.resolveUserFunc(func, sig_id);

    // Mark as emitted so `performChunkSema` doesn't try to emit the body.
    func.info.emitted = true;
    
    return func;
}

// Chunk destructor.
fn emit_chunk_deinit_func(c: *cy.Chunk, deinit_fn: *cy.Func) !void {
    try sema.pushChunkResolveContext(c, null);
    defer sema.popResolveContext(c);

    _ = try sema.pushFuncProc(c, deinit_fn);

    for (0..c.syms.items.len) |i| {
        const sym = c.syms.items[i];
        switch (sym.type) {
            .hostVar => {
                // Binded globals are managed by the host. No destruction needed.
                const host_var = sym.cast(.hostVar);
                const node: *ast.Node = @ptrCast(host_var.decl.?);
                try sema.semaTraceNopFmt(c, "deinit global {s} -- skip", .{host_var.head.name()}, node);
            },
            .userVar => {
                const user_var = sym.cast(.userVar);
                if (!user_var.type.isManaged()) {
                    continue;
                }

                const node: *ast.Node = @ptrCast(user_var.decl.?);
                try sema.semaNopFmt(c, "deinit global {s}", .{user_var.head.name()}, node);
                const static = try sema.symbol(c, sym, false, node);
                const ptr_t = try sema.getPtrType(c, user_var.type);
                const addr = try sema.semaAddressOf(c, static, ptr_t, node);
                const move_ir = try c.ir.newExpr(.deref, user_var.type, node, .{
                    .expr = addr.ir,
                });
                const move = sema.ExprResult.init2(move_ir);
                const temp_local = try sema.declareHiddenLocal(c, "_temp", user_var.type, move, node);
                const temp = &c.varStack.items[temp_local.id];
                try sema.semaDestructLocal(c, temp, node);
                c.varStack.items[temp_local.id].type = .dead;
            },
            else => {},
        }
    }

    try sema.procPrologue(c);
    try sema.popFuncBlock(c);
}

fn emit_program_deinit_func(c: *cy.Chunk, end_fn: *cy.Func) !void {
    try sema.pushChunkResolveContext(c, null);
    defer sema.popResolveContext(c);

    _ = try sema.pushFuncProc(c, end_fn);
    // Same chunks as `emit_program_init_func`, in the reverse order: a chunk is deinitialized before the
    // chunks that it imports.
    var order: std.ArrayListUnmanaged(*cy.Chunk) = .empty;
    defer order.deinit(c.alloc);
    try cy.global_init.initOrder(c.compiler, &order);

    var i = order.items.len;
    while (i > 0) {
        i -= 1;
        const chunk = order.items[i];
        const pending = chunk.id < c.compiler.chunk_start;
        if (!chunk.has_static_init) {
            continue;
        }

        const deinit = if (pending)
            chunk.sym.getMod().getSym("@deinit").?.cast(.func).first
        else
            try reserve_hidden_func(chunk, "@deinit");

        // Invoke chunk destructor.
        const call = try sema.sema_call_ir(c, deinit, &.{}, c.ast.null_node);
        try sema.sema_discard(c, call, c.ast.null_node);
    }
    
    try sema.procPrologue(c);
    try sema.popFuncBlock(c);
}

fn resolveTypeSym(c: *cy.Chunk, mod: *cy.Module, name: []const u8) !*cy.Type {
    const sym = mod.getSym(name).?;
    try resolveSym(c, sym);
    return sym.cast(.type).type;
}

fn resolveFirstFunc(c: *cy.Chunk, mod: *cy.Module, name: []const u8) !*cy.Func {
    var sym = mod.getSym(name).?;
    if (sym.type == .use_alias) {
        const alias = sym.cast(.use_alias);
        if (!alias.resolved) {
            try sema.resolveUseAlias(c, alias);
        }
        sym = alias.sym;
    }
    const func = sym.cast(.func).first;
    try sema.ensure_resolved_func(c, func, false, null);
    return func;
}

fn loadBuiltinChunk(c: *cy.Chunk) !void {
    const core_sym = c.sym;

    try loadChunk(c);

    // Extract special syms. Assumes chunks[0] is the builtins chunk.
    const core = c.sym.getMod();
    c.sema.generator_tmpl = core.getSym("Generator").?.cast(.template);
    c.sema.future_tmpl = core.getSym("Future").?.cast(.template);
    c.sema.va_list_tmpl = core.getSym("VaList").?.cast(.template);
    c.sema.option_tmpl = core.getSym("Option").?.cast(.template);
    c.sema.int_tmpl = core.getSym("Int").?.cast(.template);
    c.sema.float_tmpl = core.getSym("Float").?.cast(.template);
    c.sema.fn_tuple_tmpl = core.getSym("FnTuple").?.cast(.template);
    c.sema.result_tmpl = core.getSym("Result").?.cast(.template);
    c.sema.vector_tmpl = core.getSym("Vector").?.cast(.template);
    c.sema.generic_vector_tmpl = core.getSym("GenericVector").?.cast(.template);
    c.sema.partial_vector_tmpl = core.getSym("PartialVector").?.cast(.template);
    c.sema.ptr_tmpl = core.getSym("Ptr").?.cast(.template);
    c.sema.ref_tmpl = core.getSym("Ref").?.cast(.template);
    c.sema.borrow_tmpl = core.getSym("Borrow").?.cast(.template);
    c.sema.ex_borrow_tmpl = core.getSym("ExBorrow").?.cast(.template);
    c.sema.slice_tmpl = core.getSym("Slice").?.cast(.template);
    c.sema.span_tmpl = core.getSym("Span").?.cast(.template);
    c.sema.as_span_tmpl = core.getSym("AsSpan").?.cast(.template);
    c.sema.array_tmpl = core.getSym("Array").?.cast(.template);
    c.sema.map_tmpl = core.getSym("Map").?.cast(.template);
    c.sema.hash_map_tmpl = core.getSym("HashMap").?.cast(.template);
    c.sema.ptr_span_tmpl = core.getSym("PtrSpan").?.cast(.template);
    c.sema.ref_child_tmpl = core.getSym("RefChild").?.cast(.template);
    c.sema.func_sym_tmpl = core.getSym("funcsym_t").?.cast(.template);
    c.sema.func_ptr_tmpl = core.getSym("funcptr_t").?.cast(.template);
    c.sema.func_tmpl = core.getSym("Func").?.cast(.template);
    c.sema.opaque_func_tmpl = core.getSym("OpaqueFunc").?.cast(.template);
    c.sema.raw_buffer_tmpl = core.getSym("RawBuffer").?.cast(.template);
    c.sema.buffer_tmpl = core.getSym("Buffer").?.cast(.template);
    c.sema.eval_buffer_tmpl = core.getSym("EvalBuffer").?.cast(.template);
    c.sema.panic_fn = core.getSym("panic").?.cast(.func).first;
    c.sema.panic_unwrap_error_fn = core.getSym("panic_unwrap_error").?.cast(.func).first;
    c.sema.scope_new_fn = core.getSym("@scope_new").?.cast(.func).first;
    c.sema.scope_abort_fn = core.getSym("@scope_abort").?.cast(.func).first;
    c.sema.scope_join_fn = core.getSym("@scope_join").?.cast(.func).first;
    c.sema.scope_start_sym = core.getSym("Scope").?.getMod().?.getSym("start").?.cast(.func);
    c.sema.spawn_sym = core.getSym("spawn").?.cast(.func);
    c.sema.print_syms = .{
        core.getSym("print").?.cast(.func),
        core.getSym("prints").?.cast(.func),
        core.getSym("eprint").?.cast(.func),
        core.getSym("eprints").?.cast(.func),
        core.getSym("log").?.cast(.func),
        core.getSym("to_print_string").?.cast(.func),
    };
    c.sema.track_main_local_fn = core.getSym("@trackMainLocal").?.cast(.func).first;
    c.sema.main_result_fn = core.getSym("@mainResult").?.cast(.func).first;

    const float_tmpl = c.sema.float_tmpl;
    const raw_tmpl = core.getSym("Raw").?.cast(.template);

    // Resolve core builtin types first, since they are needed by sema.
    const mod = core_sym.getMod();
    var sym = core.getSym("type").?;
    try resolveSym(c, sym);
    c.sema.type_t = sym.cast(.type_alias).sym.type;
    sym = core.getSym("PartialStructLayout").?;
    try resolveSym(c, sym);
    c.sema.partial_struct_layout_t = sym.cast(.type_alias).sym.type;
    sym = core.getSym("Code").?;
    try resolveSym(c, sym);
    c.sema.code_t = sym.cast(.type_alias).sym.type;
    _ = try resolveTypeSym(c, mod, "NoCopy");
    c.sema.any_t = try resolveTypeSym(c, mod, "Any");
    c.sema.dependent_t = try resolveTypeSym(c, mod, "dependent");
    c.sema.infer_t = try resolveTypeSym(c, mod, "Infer");
    c.sema.eval_int_t = try resolveTypeSym(c, mod, "EvalInt");
    c.sema.eval_str_t = try resolveTypeSym(c, mod, "EvalStr");
    c.sema.str_t = try resolveTypeSym(c, mod, "str");
    c.sema.str_buffer_t = try resolveTypeSym(c, mod, "StrBuffer");
    c.sema.mut_str_t = try resolveTypeSym(c, mod, "Str");
    c.sema.error_t = try resolveTypeSym(c, mod, "error");
    c.sema.object_t = try resolveTypeSym(c, mod, "Object");
    c.sema.table_t = try resolveTypeSym(c, mod, "Table");
    c.sema.range_t = try resolveTypeSym(c, mod, "Range");
    try resolveSym(c, mod.getSym("bool").?);
    c.sema.symbol_t = try resolveTypeSym(c, mod, "symbol");
    try resolveSym(c, mod.getSym("StrBuffer").?);
    // try resolveSym(c, mod.getSym("placeholder1").?);
    try resolveSym(c, mod.getSym("Table").?);
    try resolveSym(c, mod.getSym("Any").?);
    try resolveSym(c, mod.getSym("Code").?);
    c.sema.funcsig_t = try resolveTypeSym(c, mod, "FuncSig");
    // try resolveSym(c, mod.getSym("Table").?);
    try resolveSym(c, @ptrCast(c.sema.option_tmpl));
    try resolveSym(c, @ptrCast(c.sema.ptr_tmpl));
    try resolveSym(c, @ptrCast(c.sema.ptr_span_tmpl));

    c.sema.copy_fn = try resolveFirstFunc(c, mod, "@copy");
    c.sema.dtor_fn = try resolveFirstFunc(c, mod, "@destruct");
    c.sema.partial_dtor_fn = try resolveFirstFunc(c, mod, "@partial_destruct");
    c.sema.deinit_obj_tmpl = core.getSym("@deinitObject").?.cast(.func_template);
    c.sema.to_print_string_fn = try resolveFirstFunc(c, mod, "to_print_string");
    c.sema.eq_fn = try resolveFirstFunc(c, mod, "@eq");

    const meta_c = (try c.get_chunk_by_uri("meta")).?;
    try reserveChunkSyms(meta_c);
    const meta_mod2 = meta_c.sym.getMod();
    c.sema.access_fn = try resolveFirstFunc(c, meta_mod2, "access");

    // int, i32, i16, i8
    var bits = cy.Value.init_eval_int(64);
    const int_tmpl = c.sema.int_tmpl;
    c.sema.i64_t = try c.vm.expandTypeTemplate(int_tmpl, &.{c.sema.eval_int_t}, &.{ bits });
    bits = cy.Value.init_eval_int(32);
    c.sema.i32_t = try c.vm.expandTypeTemplate(int_tmpl, &.{c.sema.eval_int_t}, &.{ bits });
    bits = cy.Value.init_eval_int(16);
    c.sema.i16_t = try c.vm.expandTypeTemplate(int_tmpl, &.{c.sema.eval_int_t}, &.{ bits });
    bits = cy.Value.init_eval_int(8);
    c.sema.i8_t = try c.vm.expandTypeTemplate(int_tmpl, &.{c.sema.eval_int_t}, &.{ bits });

    // r8, r16, r32, r64, rsize
    bits = cy.Value.init_eval_int(8);
    c.sema.r8_t = try c.vm.expandTypeTemplate(raw_tmpl, &.{c.sema.eval_int_t}, &.{ bits });
    bits = cy.Value.init_eval_int(16);
    c.sema.r16_t = try c.vm.expandTypeTemplate(raw_tmpl, &.{c.sema.eval_int_t}, &.{ bits });
    bits = cy.Value.init_eval_int(32);
    c.sema.r32_t = try c.vm.expandTypeTemplate(raw_tmpl, &.{c.sema.eval_int_t}, &.{ bits });
    bits = cy.Value.init_eval_int(64);
    c.sema.r64_t = try c.vm.expandTypeTemplate(raw_tmpl, &.{c.sema.eval_int_t}, &.{ bits });
    sym = core.getSym("rsize").?;
    try resolveSym(c, sym);
    c.sema.rsize_t = sym.cast(.type_alias).sym.type;

    // float, f32
    bits = cy.Value.init_eval_int(64);
    c.sema.f64_t = try c.vm.expandTypeTemplate(float_tmpl, &.{c.sema.eval_int_t}, &.{ bits });
    bits = cy.Value.init_eval_int(32);
    c.sema.f32_t = try c.vm.expandTypeTemplate(float_tmpl, &.{c.sema.eval_int_t}, &.{ bits });

    const int_t = cy.Value.initType(c.sema.i64_t);
    c.sema.option_int_t = try c.vm.expandTypeTemplate(c.sema.option_tmpl, &.{c.sema.type_t}, &.{ int_t });
    c.sema.ptr_int_t = try c.vm.expandTypeTemplate(c.sema.ptr_tmpl, &.{c.sema.type_t}, &.{ int_t });

    const r8_t = cy.Value.initType(c.sema.r8_t);
    c.sema.ptr_span_byte_t = try c.vm.expandTypeTemplate(c.sema.ptr_span_tmpl, &.{c.sema.type_t}, &.{ r8_t });

    const void_t = cy.Value.initType(c.sema.void_t);
    c.sema.ptr_void_t = (try c.vm.expandTypeTemplate(c.sema.ptr_tmpl, &.{c.sema.type_t}, &.{ void_t }));

    c.sema.raw_buffer_byte_t = (try c.vm.expandTypeTemplate(c.sema.raw_buffer_tmpl, &.{c.sema.type_t}, &.{r8_t}));

    // // Verify all builtin types have loaded.
    for (1..cy.types.BuiltinEnd) |i| {
        if (c.sema.types.items[i].kind() == .null) {
            std.debug.panic("Builtin type {} was not initialized.", .{i});
        }
    }

    // Verify builtin types were binded to the state.
    std.debug.assert(c.sema.object_t.id() == bt.Object);
    // std.debug.assert(self.sema.table_t.id() == bt.Table);
    std.debug.assert(c.sema.bool_t.id() == bt.Bool);
    std.debug.assert(c.sema.i8_t.id() == bt.I8);
    std.debug.assert(c.sema.i16_t.id() == bt.I16);
    std.debug.assert(c.sema.i32_t.id() == bt.I32);
    std.debug.assert(c.sema.i64_t.id() == bt.I64);
    std.debug.assert(c.sema.r8_t.id() == bt.R8);
    std.debug.assert(c.sema.r16_t.id() == bt.R16);
    std.debug.assert(c.sema.r32_t.id() == bt.R32);
    std.debug.assert(c.sema.r64_t.id() == bt.R64);
    std.debug.assert(c.sema.f64_t.id() == bt.F64);
    std.debug.assert(c.sema.f32_t.id() == bt.F32);
    std.debug.assert(c.sema.str_t.id() == bt.Str);
    std.debug.assert(c.sema.eval_str_t.id() == bt.EvalStr);
    std.debug.assert(c.sema.str_buffer_t.id() == bt.StrBuffer);
    std.debug.assert(c.sema.void_t.id() == bt.Void);
    std.debug.assert(c.sema.never_t.id() == bt.Never);
    std.debug.assert(c.sema.type_t.id() == bt.Type);
    std.debug.assert(c.sema.error_t.id() == bt.Error);
    std.debug.assert(c.sema.symbol_t.id() == bt.Symbol);
    std.debug.assert(c.sema.range_t.id() == bt.Range);
    std.debug.assert(c.sema.funcsig_t.id() == bt.FuncSig);
    std.debug.assert(c.sema.dependent_t.id() == bt.Dependent);
    std.debug.assert(c.sema.infer_t.id() == bt.Infer);
    std.debug.assert(c.sema.any_t.id() == bt.Any);
    std.debug.assert(c.sema.code_t.id() == bt.Code);
    std.debug.assert(c.sema.mut_str_t.id() == bt.MutStr);
}

pub fn loadChunk(c: *cy.Chunk) !void {
    if (c.loaded) {
        return;
    }
    if (c.pending_load_src) {
        // Initialize defaults.
        c.compiler.hasApiError = false;
        log.tracev("Invoke module loader: {s}", .{c.srcUri});

        var res = C.LoaderResult{
            .src = C.to_bytes(""),
            .manage_src = false,
        };
        if (!c.compiler.loader.?(@ptrCast(c.vm), @ptrCast(c.sym), C.to_bytes(c.srcUri), &res)) {
            if (c.importer) |node| {
                const from = c.compiler.chunks.items[node.src()];
                if (c.compiler.hasApiError) {
                    return from.reportErrorFmt(c.compiler.apiError, &.{}, node);
                } else {
                    return from.reportErrorFmt("Failed to load module: {}", &.{v(c.srcUri)}, node);
                }
            } else {
                if (c.compiler.hasApiError) {
                    return c.reportError(c.compiler.apiError, null);
                } else {
                    return c.reportErrorFmt("Failed to load module: {}", &.{v(c.srcUri)}, null);
                }
            }
        }
        c.src = C.from_bytes(res.src);
        c.manage_src = res.manage_src;
        c.pending_load_src = false;
        // A binding the loader could not add (`cl_mod_add_*`).
        if (c.compiler.host_error) |err| return err;
    }

    log.tracev("chunk parse: {}", .{c.id});
    try performChunkParse(c.compiler, c);
    c.has_pending_ct_stmts = c.parser.has_top_ct_stmt;

    try reserveChunkSyms(c);

    if (c.compiler.importCore) {
        // Add builtins as fallback search module.
        const core_sym = c.compiler.builtins_chunk.sym;
        try c.fallback_modules.append(c.alloc, core_sym.sym());
    }
    c.loaded = true;
}

fn createModuleUnmanaged(self: *Compiler, r_uri: []const u8, src: []const u8) !*cy.Chunk {
    const src_dupe = try self.alloc.dupe(u8, src);
    const r_uri_dupe = try self.alloc.dupe(u8, r_uri);

    const chunk = try self.alloc.create(cy.Chunk);
    try chunk.init(self, cy.NullId, r_uri_dupe, src_dupe);
    chunk.sym = try chunk.createChunkSym(r_uri_dupe);
    return chunk;
}

pub fn ensureModule(self: *Compiler, r_uri: []const u8) !*cy.Chunk {
    return ensureModule2(self, r_uri, null);
}

pub fn ensureModule2(self: *Compiler, r_uri: []const u8, src: ?[]const u8) !*cy.Chunk {
    // Check cache first.
    const cache = try self.chunk_map.getOrPut(self.alloc, r_uri);
    if (cache.found_existing) {
        return cache.value_ptr.*;
    }

    // The new entry's key is still the caller's buffer. It leaves the map again unless the chunk is registered.
    errdefer self.chunk_map.removeByPtr(cache.key_ptr);
    try self.chunks.ensureUnusedCapacity(self.alloc, 1);

    const r_uri_dupe = try self.alloc.dupe(u8, r_uri);
    const chunk_id: u32 = @intCast(self.chunks.items.len);
    const chunk = self.alloc.create(cy.Chunk) catch |err| {
        self.alloc.free(r_uri_dupe);
        return err;
    };
    errdefer self.alloc.destroy(chunk);
    chunk.init(self, chunk_id, r_uri_dupe, src) catch |err| {
        self.alloc.free(r_uri_dupe);
        return err;
    };
    // Frees `r_uri_dupe` as the chunk's uri. `src` stays with the caller.
    errdefer chunk.deinit();

    var name = std.Io.Dir.path.basename(r_uri_dupe);
    if (std.mem.findScalarLast(u8, name, '.')) |idx| {
        name = name[0..idx];
    }

    chunk.sym = try chunk.createChunkSym(name);
    self.chunks.appendAssumeCapacity(chunk);
    cache.key_ptr.* = r_uri_dupe;
    cache.value_ptr.* = chunk;
    return chunk;
}

// /// `src` is consumed.
// pub fn createModule(self: *Compiler, r_uri: []const u8, src: ?[]const u8) !*cy.Chunk {
//     const chunk_id: u32 = @intCast(self.chunks.items.len);
//     const chunk = try self.alloc.create(cy.Chunk);
//     try chunk.init(self, chunk_id, r_uri_dupe, src);
//     chunk.sym = try chunk.createChunkSym(r_uri_dupe);
//     try self.chunks.append(self.alloc, chunk);
//     return chunk;
// }

fn reserveChunkSyms(c: *cy.Chunk) anyerror!void {
    if (c.reserved_syms) {
        return;
    }

    try sema.pushChunkResolveContext(c, null);
    defer sema.popResolveContext(c);

    // Process static declarations.
    for (c.ast.root.?.stmts.slice()) |stmt| {
        switch (stmt.type()) {
            .import_stmt => {
                try sema.declareUseImport(c, stmt.cast(.import_stmt));
            },
            .type_alias_decl => {
                _ = try sema_type.reserve_type_alias(c, stmt.cast(.type_alias_decl));
            },
            .type_const_decl => {
                _ = try sema_type.reserve_type_const(c, stmt.cast(.type_const_decl));
            },
            .use_alias => {
                _ = try sema.reserveUseAlias(c, stmt.cast(.use_alias));
            },
            .cstruct_decl => {
                const decl = stmt.cast(.cstruct_decl);
                _ = try sema_type.reserveStruct(c, decl, true);
            },
            .cunion_decl => {
                const decl = stmt.cast(.cunion_decl);
                _ = try sema_type.reserveCUnion(c, decl);
            },
            .struct_decl => {
                const decl = stmt.cast(.struct_decl);
                _ = try sema_type.reserveStruct(c, decl, false);
            },
            .trait_decl => {
                const decl = stmt.cast(.trait_decl);
                _ = try sema_type.reserve_trait_type(c, decl);
            },
            .enumDecl => {
                const decl = stmt.cast(.enumDecl);
                if (decl.isChoiceType) {
                    _ = try sema_type.reserve_choice(c, stmt.cast(.enumDecl));
                } else {
                    _ = try sema_type.reserve_enum(c, stmt.cast(.enumDecl));
                }
            },
            .custom_type_decl => {
                const decl = stmt.cast(.custom_type_decl);
                const sym = try sema_type.resolve_custom_type(c, decl, null);
                sym.getMetadata().private = decl.hidden;
                _ = try cy.module.addUniqueSym(c, sym.parent.?.getMod().?, sym.name(), sym, @ptrCast(decl));
            },
            .template => {
                const decl = stmt.cast(.template);
                if (decl.child_decl.type() == .funcDecl) {
                    const func_decl = decl.child_decl.cast(.funcDecl);
                    const decl_path = try sema.ensureDeclNamePath(c, @ptrCast(c.sym), func_decl.parent, func_decl.name);
                    _ = try sema.reserveFuncTemplateSym(c, decl_path.parent, decl_path.name.name, decl);
                } else {
                    _ = try sema.reserveTemplate(c, decl);
                }
            },
            .const_decl => {
                const decl = stmt.cast(.const_decl);
                const decl_path = try sema.ensureDeclNamePath(c, @ptrCast(c.sym), decl.parent, decl.name);
                if (decl_path.variant) {
                    _ = try c.reserveVariantMember(decl_path.parent, decl_path.name.name, @ptrCast(decl));
                    continue;
                }

                _ = try sema.reserveConst(c, decl_path.parent, decl_path.name.name, stmt.cast(.const_decl));
            },
            .global_decl => {
                _ = try sema.reserveGlobal(c, stmt.cast(.global_decl));
                c.has_static_init = true;
            },
            .funcDecl => {
                const decl = stmt.cast(.funcDecl);
                var parent = decl.parent;
                if (parent == null and decl.sig_t == .method) {
                    parent = decl.params.ptr[0].type;
                }
                const decl_path = try sema.ensureDeclNamePath(c, @ptrCast(c.sym), parent, decl.name);
                if (decl_path.variant) {
                    _ = try c.reserveVariantFunc(decl_path.parent, decl_path.name.name, decl);
                    continue;
                } else {
                    _ = try c.reserveFunc(decl_path.parent, decl_path.name.name, decl);
                }
            },
            .ct_stmt => {},
            else => {
                if (c != c.compiler.main_chunk) {
                    return c.reportError("Top level statement is not allowed from imported module.", @ptrCast(stmt));
                }
            },
        }
    }

    c.reserved_syms = true;
}

/// Since core types are declared in the same builtins.cy,
/// Reserve them upfront so that other types do not occupy them first.
fn reserveCoreTypes(self: *Compiler) !void {
    self.vm.log_tracev("Reserve core types", .{});

    const type_ids = &[_]cy.TypeId{
        bt.Void,
        bt.Bool,
        bt.I8,
        bt.I16,
        bt.I32,
        bt.I64,
        bt.EvalInt,
        bt.R8,
        bt.R16,
        bt.R32,
        bt.R64,
        bt.F32,
        bt.F64,
        bt.Error,
        bt.Symbol,
        bt.Object,
        bt.Any,
        bt.Type,
        bt.Thread,
        bt.Code,
        bt.FuncSig,
        bt.PartialStructLayout,
        bt.Str,
        bt.StrBuffer,
        bt.EvalStr,
        bt.Never,
        bt.Infer,
        bt.Dependent,
        bt.TccState,
        bt.Range,
        bt.Table,
        bt.NoCopy,
        bt.MutStr,
    };

    for (type_ids) |type_id| {
        const id = try self.sema.reserveType();
        std.debug.assert(id == type_id);
    }

    std.debug.assert(self.sema.types.items.len == cy.types.BuiltinEnd);
}

fn resolveSym(c: *cy.Chunk, sym: *cy.Sym) !void {
    log.tracev("resolve: {s} {}", .{sym.name(), sym.type});
    switch (sym.type) {
        .extern_var => {
            try sema.resolveExternVar(c, sym.cast(.extern_var));
        },
        .hostVar => {
            try sema.resolveHostVar(c, sym.cast(.hostVar));
        },
        .userVar => {
            try sema.resolveUserVar(c, sym.cast(.userVar));
        },
        .const_ => {
            try sema.resolveConst(c, sym.cast(.const_));
        },
        .func => {},
        .type => {
            const type_sym = sym.cast(.type);
            try sema_type.ensure_resolved_type(c, type_sym.type, type_sym.decl.?);
        },
        .use_alias => {
            try sema.resolveUseAlias(c, @ptrCast(sym));
        },
        .type_alias => {
            try sema_type.resolve_type_alias(c, @ptrCast(sym));
        },
        .type_const => {
            try sema_type.resolve_type_const(c, @ptrCast(sym));
        },
        .template => {
            try sema.ensureResolvedTemplate(c, @ptrCast(sym));
        },
        .func_template => {
            try sema.ensureResolvedFuncTemplate(c, @ptrCast(sym));
        },
        else => {},
    }
}

// Resolves symbol signatures:
// - Variable types are resolved.
// - Function signatures are resolved.
// - Type fields are resolved.
fn resolveChunkSyms(c: *cy.Chunk) !void {
    log.tracev("resolve chunk syms: {s}", .{c.srcUri});

    // Evaluate any top level ct stmts.
    try sema.semaChunkTopCtStmts(c, null);

    var cur_sym: usize = 0;
    var cur_func: usize = 0;
    while (true) {
        // _ = try sema.pushProc(chunk, null);

        // Iterate with explicit index since unnamed types could be appended.
        while (cur_sym < c.syms.items.len) : (cur_sym += 1) {
            const sym = c.syms.items[cur_sym];
            try resolveSym(c, sym);
        }

        // _ = try sema.popProc(chunk);

        while (cur_func < c.funcs.items.len) : (cur_func += 1) {
            const func = c.funcs.items[cur_func];
            log.tracev("resolve: {s}", .{func.name()});
            try sema.ensure_resolved_func(c, func, false, null);
        }

        if (cur_sym == c.syms.items.len) {
            break;
        }
    }

    if (c.on_load) |onLoad| {
        onLoad(@ptrCast(c.vm), @ptrCast(c.sym));
        // The callback cannot return an error. A failed one leaves the module half loaded, and the rest of the
        // compile would read what it did not set.
        if (c.compiler.host_error) |err| return err;
    }
}

/// For a builtin type creator (`C.CreateTypeFn`), which can only return null: the compile fails with `err`.
pub fn failCreateType(c: *cy.Chunk, err: anyerror) ?*C.Type {
    c.compiler.host_error = err;
    return null;
}

pub const CompileResult = union {
    vm: *cy.ByteCodeBuffer,
    aot: AotCompileResult,
};

const VarInfo = struct {
    hasStaticType: bool,
};

const Load = struct {
    pc: u32,
    tempOffset: u8,
};

const unexpected = cy.fatal;

pub fn default_dl_resolver(vm: ?*C.VM, uri: C.Bytes, out: [*c]C.Bytes) callconv(.c) bool {
    const final_uri = C.vm_allocb(vm.?, uri.len);
    @memcpy(final_uri, C.from_bytes(uri));
    out[0] = C.to_bytes(final_uri);
    return true;
}

pub fn default_resolver(_: ?*C.VM, params: C.ResolverParams, res_uri_len: ?*usize) callconv(.c) bool {
    @memcpy(params.buf[0..params.uri.len], params.uri.ptr[0..params.uri.len]);
    res_uri_len.?.* = params.uri.len;
    return true;
}

const ModuleEntry = struct {
    bind: *const fn(*C.VM, *C.Sym) callconv(.c) C.Bytes,
};

const mods = std.StaticStringMap(ModuleEntry).initComptime(.{
    .{"core", ModuleEntry{.bind = &core_mod.bind}},
    .{"meta", ModuleEntry{.bind = &meta_mod.bind}},
    .{"math", ModuleEntry{.bind = &math_mod.bind}},
    .{"cy",   ModuleEntry{.bind = &cy_mod.bind}},
    .{"c",    ModuleEntry{.bind = &c_mod.bind}},
    .{"io",   ModuleEntry{.bind = &io_mod.bind}},
    .{"test", ModuleEntry{.bind = &test_mod.bind}},
});

/// Whether `uri` names a standard module (`core`, `meta`, ...). `deny_raw_ptrs` exempts these chunks: the core
/// library implements `Span`, `Map` and friends with raw pointers.
pub fn is_std_module_uri(uri: []const u8) bool {
    return mods.has(uri);
}

pub fn default_loader(vm_: ?*C.VM, mod_: ?*C.Sym, spec: C.Bytes, res: [*c]C.LoaderResult) callconv(.c) bool {
    const name = C.from_bytes(spec);
    if (mods.get(name)) |entry| {
        res[0] = .{
            .src = entry.bind(vm_.?, mod_.?),
            .manage_src = false,
        };
        return true;
    } else {
        return false;
    }
}

pub fn resolveModuleUriFrom(self: *cy.Chunk, buf: []u8, uri: []const u8, node: ?*ast.Node) ![]const u8 {
    self.compiler.hasApiError = false;

    const params: C.ResolverParams = .{
        .chunkId = self.id,
        .curUri = C.to_bytes(self.srcUri),
        .uri = C.to_bytes(uri),
        .buf = buf.ptr,
        .bufLen = buf.len,
    };
    var res_uri_len: usize = undefined;
    if (!self.compiler.resolver.?(@ptrCast(self.compiler.vm), params, &res_uri_len)) {
        if (self.compiler.hasApiError) {
            return self.reportErrorFmt(self.compiler.apiError, &.{}, node);
        } else {
            return self.reportErrorFmt("Failed to resolve module.", &.{}, node);
        }
    }
    return buf[0..res_uri_len];
}

pub fn resolveModuleUri(self: *cy.Compiler, buf: []u8, uri: []const u8) ![]const u8 {
    self.hasApiError = false;

    const params: C.ResolverParams = .{
        .chunkId = cy.NullId,
        .curUri = C.NullStr,
        .uri = C.to_bytes(uri),
        .buf = buf.ptr,
        .bufLen = buf.len,
    };
    var res_uri_len: usize = undefined;
    if (!self.resolver.?(@ptrCast(self.vm), params, &res_uri_len)) {
        if (self.hasApiError) {
            _ = try self.addReport(.compile_err, self.apiError, null, 0);
            return error.CompileError;
        } else {
            _ = try self.addReport(.compile_err, "Failed to resolve module.", null, 0);
            return error.CompileError;
        }
    }
    return params.buf[0..res_uri_len];
}

test "vm compiler internals." {
}
/// A function that a failed compile made and that a later compile can reach (`Compiler.carryFailedCompile`).
fn carryFunc(func: *cy.Func, start: u32, type_start: u32) bool {
    switch (func.type) {
        .userFunc, .extern_, .hostFunc => {},
        // A lambda is made again with the body that holds it.
        else => return false,
    }
    if (func.instance) |inst| {
        if (!instanceSurvives(inst, start, type_start, 0)) return false;
    }
    if (func.decl) |decl| {
        if (decl.src() >= start) return false;
    }
    return survives(func.parent, start, type_start, 0);
}

/// Whether `sym` and the symbols that it belongs to were declared in chunks from before the compile that
/// started at chunk `start`, and every template instance among them has arguments that survive as well.
fn survives(sym: *cy.Sym, start: u32, type_start: u32, depth: u32) bool {
    if (depth > 32) return false;
    var cur: ?*cy.Sym = sym;
    while (cur) |s| : (cur = s.parent) {
        if (s.type == .chunk) {
            return s.cast(.chunk).chunk.id < start;
        }
        if (s.instance()) |inst| {
            if (!instanceSurvives(inst, start, type_start, depth + 1)) return false;
        }
        if (s.declNodeOrNull()) |decl| {
            if (decl.src() >= start) return false;
        }
    }
    return true;
}

fn instanceSurvives(inst: *cy.Instance, start: u32, type_start: u32, depth: u32) bool {
    if (inst.failed) return false;
    for (inst.param_types, inst.params) |param_t, param| {
        if (param_t.id() == bt.Type) {
            if (!typeSurvives(param.asPtr(*cy.Type), start, type_start, depth + 1)) return false;
        }
    }
    return true;
}

fn typeSurvives(type_: *cy.Type, start: u32, type_start: u32, depth: u32) bool {
    if (type_.id() < type_start) return true;
    if (depth > 32) return false;
    switch (type_.kind()) {
        .null => return true,
        .func_ptr, .func, .func_sym => {
            const sig = switch (type_.kind()) {
                .func_ptr => type_.cast(.func_ptr).sig,
                .func => type_.cast(.func).sig,
                else => type_.cast(.func_sym).sig,
            };
            for (sig.params()) |param| {
                if (!typeSurvives(param.get_type(), start, type_start, depth + 1)) return false;
            }
            return typeSurvives(sig.ret, start, type_start, depth + 1);
        },
        else => return survives(@ptrCast(type_.sym()), start, type_start, depth + 1),
    }
}

/// The functions of a type that implement each of its traits.
fn resolveImplFuncs(self: *Compiler, type_: *cy.Type) !void {
    if (type_.kind() != .struct_t) return;
    const struct_t = type_.cast(.struct_t);
    const impls = struct_t.impls();
    if (impls.len == 0) return;
    const chunk = self.getSymChunk(&type_.sym().head);
    const sym = type_.sym();

    try sema.pushSymResolveContext(chunk, &sym.head, sym.decl.?);
    defer sema.popResolveContext(chunk);

    for (impls, 0..) |*impl, j| {
        const trait_members = impl.trait.members();
        const funcs = try self.alloc.alloc(*cy.Func, trait_members.len);
        errdefer self.alloc.free(funcs);

        for (trait_members, 0..) |member, i| {
            const func = type_.get_trait_method_impl(member) orelse {
                const sig_str = try self.sema.allocFuncSigStr(member.func.sig, true, chunk);
                defer self.alloc.free(sig_str);
                const type_name = try self.sema.allocTypeName(type_);
                defer self.alloc.free(type_name);
                return chunk.reportErrorFmt("`{}` does not implement `fn {}{}` from `{}`.", &.{
                    v(type_name), v(member.func.name()), v(sig_str), 
                    v(impl.trait.base.name()) }, @ptrCast(sym.decl.?.cast(.struct_decl).impls.ptr[j].trait));
            };
            funcs[i] = func;
        }

        // A carried type can have them from the compile that failed.
        self.alloc.free(impl.funcs);
        impl.funcs = funcs;
    }
}

/// Checks the bodies that a failed compile left unchecked or without code (`Compiler.carry_funcs`) in the
/// main chunk of this compile, so that their code is generated with it.
fn semaCarriedFuncs(self: *Compiler, main: *cy.Chunk) !void {
    for (self.carry_funcs.items) |func| {
        const has_body = switch (func.type) {
            .userFunc => !func.info.const_eval_only,
            .extern_ => func.data.extern_.has_impl,
            else => false,
        };
        if (!has_body or func.info.emitted or !func.isResolved()) {
            continue;
        }
        const res = if (func.type == .userFunc and func.isMethod())
            sema.semaMethodBody(main, func)
        else
            sema.semaFuncBody(main, func);
        res catch |err| {
            // The instance is not handed out or carried again, and the compile starts over (`Compiler.compile`).
            if (ownerInstance(func)) |inst| inst.failed = true;
            if (err == error.CompileError) self.carried_failed = true;
            return err;
        };
    }
}

fn ownerInstance(func: *cy.Func) ?*cy.Instance {
    if (func.instance) |inst| return inst;
    var cur: ?*cy.Sym = func.parent;
    while (cur) |s| : (cur = s.parent) {
        if (s.instance()) |inst| return inst;
    }
    return null;
}

/// A `use` alias of a module that a failed compile loaded first and that left the module cache.
fn aliasesEvicted(alias: *cy.sym.UseAlias) bool {
    var cur: ?*cy.Sym = alias.sym;
    while (cur) |s| : (cur = s.parent) {
        if (s.type == .chunk) return s.cast(.chunk).chunk.evicted;
    }
    return false;
}
