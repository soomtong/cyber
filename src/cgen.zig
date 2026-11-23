const std = @import("std");
const stdx = @import("stdx");
const builtin = @import("builtin");
const cy = @import("cyber.zig");
const ast = cy.ast;
const bt = cy.types.BuiltinTypes;
const log = cy.log.scoped(.cgen);
const v = cy.fmt.v;
const vmc = @import("vmc");

pub const DumpCGen = builtin.mode == .debug and false;

pub const Compiler = struct {
    alloc: std.mem.Allocator,
    base: *cy.Compiler,

    /// Can be cy.Sym or cy.Func.
    syms: std.AutoHashMapUnmanaged(*anyopaque, Sym),

    /// Cyber name to normalized C name's next unique suffix.
    c_names: std.StringHashMapUnmanaged(u32),

    pub fn deinit(c: *Compiler) void {
        {
            var iter = c.syms.valueIterator();
            while (iter.next()) |val| {
                c.alloc.free(val.name());
            }
            c.syms.deinit(c.alloc);
        }

        c.c_names.deinit(c.alloc);
    }

    /// This is useful to include only relevant syms for `@initBindLib`.
    pub fn ensureSym(c: *Compiler, sym: *cy.Sym) !void {
        const res = try c.syms.getOrPut(c.alloc, sym);
        if (res.found_existing) {
            return;
        }
        try c.createSym2(sym.name(), res.value_ptr);

        // Ensure child symbols.
        if (sym.type == .type) {
            const type_ = sym.cast(.type).type;
            switch (type_.kind()) {
                .pointer => {
                    const pointer = type_.cast(.pointer);
                    try c.ensureSym(&pointer.child_t.sym().head);
                },
                .struct_t => {
                    const struct_t = type_.cast(.struct_t);
                    for (struct_t.fields()) |field| {
                        try c.ensureSym(&field.type.sym().head);
                    }
                },
                else => {
                },
            }
        }
    }

    pub fn createSym(c: *Compiler, sym_ptr: *anyopaque, sym_name_opt: ?[]const u8) !void {
        var new: Sym = undefined;
        try c.createSym2(sym_name_opt, &new);
        try c.syms.putNoClobber(c.alloc, sym_ptr, new);
    }

    /// Creates a mapping between sema sym and the gen sym.
    pub fn createSym2(c: *Compiler, sym_name_opt: ?[]const u8, dst: *Sym) !void {
        const sym_name = sym_name_opt orelse {
            const name = "";
            dst.* = .{
                .name_ptr = name.ptr,
                .name_len = @intCast(name.len),
                .declared = false,
                .forward_declared = false,
            };
            return;
        };
        var buf: [1024]u8 = undefined;
        const name_n = try normalizeSymName(&buf, sym_name);

        var new_name: []const u8 = undefined;
        const res = try c.c_names.getOrPut(c.alloc, sym_name);
        if (res.found_existing) {
            new_name = try c.alloc.print("{s}_{}", .{ name_n, res.value_ptr.* });
            res.value_ptr.* += 1;
        } else {
            new_name = try c.alloc.print("{s}_0", .{name_n});
            res.value_ptr.* = 1;
        }
        dst.* = .{
            .name_ptr = new_name.ptr,
            .name_len = @intCast(new_name.len),
            .declared = false,
            .forward_declared = false,
        };
    }

    pub fn createPredefinedSym(c: *Compiler, sym_ptr: *anyopaque, sym_name: []const u8) !void {
        return c.createSymExact(sym_ptr, sym_name, true);
    }

    pub fn createSymExact(c: *Compiler, sym_ptr: *anyopaque, sym_name: []const u8, declared: bool) !void {
        const dupe = try c.alloc.dupe(u8, sym_name);
        try c.syms.putNoClobber(c.alloc, sym_ptr, .{
            .name_ptr = dupe.ptr,
            .name_len = @intCast(dupe.len),
            .declared = declared,
            .forward_declared = false,
        });
    }
};

fn normalizeSymName(buf: []u8, name: []const u8) ![]const u8 {
    const ReplaceChars = "&|%^*/+-<>=~";
    if (std.mem.findAny(u8, name, ReplaceChars)) |idx| {
        // Normalize to C name.
        var w: std.Io.Writer = .fixed(buf);
        try w.print("{s}{s}", .{ name[0..idx], normalizeChar(name[idx]) });

        var rest = name[idx + 1 ..];
        while (std.mem.findAny(u8, rest, ReplaceChars)) |idx2| {
            try w.print("{s}{s}", .{ rest[0..idx2], normalizeChar(rest[idx2]) });
            rest = rest[idx2 + 1 ..];
        }
        try w.writeAll(rest);
        return w.buffered();
    } else {
        return name;
    }
}

fn normalizeChar(char: u8) []const u8 {
    return switch (char) {
        '&' => "_and",
        '|' => "_or",
        '^' => "_pow",
        '%' => "_mod",
        '*' => "_mul",
        '/' => "_div",
        '-' => "_sub",
        '+' => "_add",
        '<' => "_lt",
        '>' => "_gt",
        '=' => "_eq",
        '~' => "_not",
        else => &.{char},
    };
}

const Sym = struct {
    name_ptr: [*]const u8,
    name_len: u16,

    // Track whether a type was declared.
    declared: bool,

    // For base types. Pointer types check for this.
    forward_declared: bool,

    pub fn name(self: Sym) []const u8 {
        return self.name_ptr[0..self.name_len];
    }
};

pub const Chunk = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayList(u8),
    outw: stdx.ListWriter(std.ArrayList(u8)),

    /// Alias for `compiler.syms`. Assumes all needed syms are registered by compiler.
    syms: *const std.AutoHashMapUnmanaged(*anyopaque, Sym),

    compiler: *Compiler,
    base: *cy.Chunk,
    vm: *cy.VM,
    sema: *cy.Sema,
    ast: cy.ast.AstView,
    srcUri: []const u8,

    pub fn init(compiler: *Compiler, c: *cy.Chunk) Chunk {
        const alloc = compiler.alloc;
        var new = Chunk{
            .alloc = alloc,
            .out = .empty,
            .outw = undefined,
            .syms = &compiler.syms,
            .base = c,
            .vm = c.vm,
            .sema = c.sema,
            .compiler = compiler,
            .ast = c.ast,
            .srcUri = c.srcUri,
        };
        new.outw = stdx.listWriter(&new.out, alloc);
        return new;
    }

    fn deinit(c: *Chunk) void {
        c.out.deinit(c.alloc);
    }

    fn cFuncName(c: *Chunk, func: *cy.Func) []const u8 {
        if (c.syms.get(@ptrCast(func))) |csym| {
            return csym.name();
        }
        std.debug.panic("Missing csym: {s}", .{func.name()});
    }

    fn cSymName(c: *Chunk, sym: *cy.Sym) []const u8 {
        if (c.syms.get(sym)) |csym| {
            return csym.name();
        }
        const name = c.sema.allocSymName(sym) catch @panic("");
        defer c.alloc.free(name);
        std.debug.panic("Missing csym: {s}", .{name});
    }

    fn typeName(c: *Chunk, type_: *cy.Type) TypeName {
        return TypeName.init(c, type_);
    }

    fn typeNameRet(c: *Chunk, type_: *cy.Type) TypeName {
        var new = TypeName.init(c, type_);
        new.ret = true;
        return new;
    }

    fn fieldName(c: *Chunk, field: *cy.types.Field) []const u8 {
        _ = c;
        const name = field.sym.head.name();
        return field_rewrite.get(name) orelse return name;
    }

    fn caseName(c: *Chunk, name: []const u8) []const u8 {
        _ = c;
        return field_rewrite.get(name) orelse return name;
    }
};

const field_rewrite = std.StaticStringMap([]const u8).initComptime(.{
    .{ "float", "float_" },
    .{ "enum", "enum_" },
    .{ "void", "void_" },
    .{ "int", "int_" },
    .{ "bool", "bool_" },
    .{ "struct", "struct_" },
});

pub fn genFuncForwardDecl(c: *Chunk, w: anytype, func: *cy.Func) !void {
    const c_sym = c.syms.getPtr(func).?;
    if (c_sym.forward_declared) {
        return;
    }

    // Declare dependencies.
    const params = func.sig.params();
    for (params) |param| {
        try declareType(c, param.get_type(), w);
    }
    try declareType(c, func.sig.ret, w);

    c_sym.forward_declared = true;
    switch (func.type) {
        .userLambda => {
            try w.print("{f} {s}(CB_Thread*", .{
                c.typeNameRet(func.sig.ret), c.cFuncName(func),
            });
            if (func.data.userLambda.is_closure) {
                try w.writeAll(", CB_FuncUnion*");
            }
            for (params) |param| {
                try w.print(", {f}", .{ c.typeName(param.get_type()) });
            }
            try w.writeAll(");\n");
        },
        .hostFunc => {
            try w.print("{f} {s}(CB_Thread*", .{
                c.typeNameRet(func.sig.ret), c.cFuncName(func),
            });
            for (params) |param| {
                try w.print(", {f}", .{ c.typeName(param.get_type()) });
            }
            try w.writeAll(");\n");
        },
        .userFunc => {
            try w.print("{f} {s}(CB_Thread*", .{
                c.typeNameRet(func.sig.ret), c.cFuncName(func),
            });
            for (params) |param| {
                try w.print(", {f}", .{ c.typeName(param.get_type()) });
            }
            try w.writeAll(");\n");
        },
        .extern_ => {
            try w.print("extern {f} {s}(", .{
                c.typeNameRet(func.sig.ret), c.cFuncName(func),
            });
            if (params.len > 0) {
                try w.print("{f}", .{ c.typeName(params[0].get_type()) });
                for (params[1..]) |param| {
                    try w.print(", {f}", .{ c.typeName(param.get_type()) });
                }
            }
            try w.writeAll(");\n");
        },
        else => {},
    }
}

pub fn genVmHeaders(w: anytype) !void {
    try w.print(
        \\#define bool _Bool
        \\#define i64 long long
        \\#define u64 unsigned long long
        \\#define Value u64
        // TODO: Check for 32bit addressing.
        \\#define size_t u64
        \\#define i8 signed char
        \\#define u8 unsigned char
        \\#define byte unsigned char
        \\#define i16 short
        \\#define u16 unsigned short
        \\#define i32 int
        \\#define u32 unsigned int
        \\#define usize size_t
        \\#define f64 double
        \\#define f32 float
        \\
        \\typedef bool CB_bool;
        \\typedef i8  CB_i8;
        \\typedef i16 CB_i16;
        \\typedef i32 CB_i32;
        \\typedef i64 CB_int;
        \\typedef u8  CB_byte;
        \\typedef u16 CB_r16;
        \\typedef u32 CB_r32;
        \\typedef u64 CB_r64;
        \\typedef u8 Ret;
        \\
        \\#define PointerMask 0xFFFE000000000000
        \\typedef struct ZAllocator {{
        \\    void* ptr;
        \\    void* vtable;
        \\}} ZAllocator;
        \\typedef struct Thread {{
        \\    size_t id;
        \\    void* vm;
        \\    u16* pc;
        \\    u64* fp;
        \\    u64* fp_end;
        \\    Value* stack_ptr;
        \\    size_t stack_len;
        \\    Value* stack_end;
        \\}} Thread;
        \\typedef struct ZThread {{
        \\    u8 padding[16];
        \\    Thread c;
        \\}} ZThread;
        // \\typedef struct ZVM {{
        // \\    ZAllocator alloc;
        // \\    VMC c;
        // \\}} VM;
        \\extern u64 icyAllocObject(ZThread*, u32);
        \\extern Value host_new_obj_init(ZThread*, u32, u8*, usize);
        \\extern void* host_call_func(ZThread*, usize, usize);
        \\extern ZThread* host_ensure_thread();
        //\\extern int printf(char* fmt, ...);
        \\#define CALL_ARG_START 5
        \\void* thread_ret(ZThread* t, size_t reg_size) {{
        \\    t->c.fp_end = t->c.fp + 4;
        \\    return t->c.fp - reg_size;
        \\}}
        \\void* thread_param(ZThread* t, size_t reg_size) {{
        \\    void* res = t->c.fp_end;
        \\    t->c.fp_end = t->c.fp_end + reg_size;
        \\    return res;
        \\}} 
        // \\extern void exit(int code);
        \\
    , .{});
}

/// DFS declaration to ensure type dependencies are declared first.
fn declareType(c: *Chunk, type_: *cy.Type, w: anytype) !void {
    try c.compiler.ensureSym(&type_.sym().head);
    const c_sym = c.syms.getPtr(type_.sym()).?;
    if (c_sym.declared) {
        return;
    }
    c_sym.declared = true;

    switch (type_.kind()) {
        .func_ptr => {
            // Extract name since `c_sym` can be invalidated.
            const name = c_sym.name();

            const func_ptr = type_.cast(.func_ptr);
            const params = func_ptr.sig.params();
            for (params) |param| {
                try declareType(c, param.get_type(), w);
            }
            try declareType(c, func_ptr.sig.ret, w);

            try w.writeAll("typedef ");
            try writeFuncPtrType(c, w, name, func_ptr.sig);
            try w.writeAll(";\n");
        },
        .func => {
            const func_union = type_.cast(.func);
            try w.print("typedef CB_FuncUnion* {f};\n", .{ c.typeName(type_) });

            // Generate the dispatch function.
            try w.print("{f} cb_dispatch_{f}(CB_Thread* ctx, {f} func", .{ c.typeName(func_union.sig.ret), c.typeName(type_), c.typeName(type_) });
            const params = func_union.sig.params();
            for (params, 0..) |param, i| {
                try w.print(", {f} arg{}", .{c.typeName(param.get_type()), i});
            }
            try w.writeAll(") {\n");
            try w.writeAll("    if (func->kind == 2) {\n");
            try w.print("        {f} (*func_ptr)(CB_Thread*, {f}", .{c.typeName(func_union.sig.ret), c.typeName(type_)});
            for (params) |param| {
                try w.print(", {f}", .{c.typeName(param.get_type())});
            }
            try w.writeAll(") = func->ptr;\n");
            try w.writeAll("        return func_ptr(ctx, func");
            for (0..params.len) |i| {
                try w.print(", arg{}", .{i});
            }
            try w.writeAll(");\n");
            try w.writeAll("    } else {\n");
            try w.print("        {f} (*func_ptr)(CB_Thread*", .{c.typeName(func_union.sig.ret)});
            for (params) |param| {
                try w.print(", {f}", .{c.typeName(param.get_type())});
            }
            try w.writeAll(") = func->ptr;\n");
            try w.writeAll("        return func_ptr(ctx");
            for (0..params.len) |i| {
                try w.print(", arg{}", .{i});
            }
            try w.writeAll(");\n");
            try w.writeAll("    }\n");
            try w.writeAll("}\n");
        },
        .bool => {
            try w.print("typedef bool {f};\n", .{ c.typeName(type_) });
        },
        .float => {
            const float_t = type_.cast(.float);
            switch (float_t.bits) {
                32 => {
                    try w.print("typedef float {f};\n", .{ c.typeName(type_) });
                },
                64 => {
                    try w.print("typedef double {f};\n", .{ c.typeName(type_) });
                },
                else => {
                    std.debug.panic("TODO: {}", .{float_t.bits});
                },
            }
        },
        .raw => {
            const raw_t = type_.cast(.raw);
            switch (raw_t.bits) {
                8 => {
                    try w.print("typedef u8 {f};\n", .{ c.typeName(type_) });
                },
                16 => {
                    try w.print("typedef u16 {f};\n", .{ c.typeName(type_) });
                },
                32 => {
                    try w.print("typedef u32 {f};\n", .{ c.typeName(type_) });
                },
                64 => {
                    try w.print("typedef u64 {f};\n", .{ c.typeName(type_) });
                },
                else => {
                    @panic("unexpected");
                },
            }
        },
        .int => {
            const int_t = type_.cast(.int);
            switch (int_t.bits) {
                8 => {
                    try w.print("typedef i8 {f};\n", .{ c.typeName(type_) });
                },
                16 => {
                    try w.print("typedef i16 {f};\n", .{ c.typeName(type_) });
                },
                32 => {
                    try w.print("typedef i32 {f};\n", .{ c.typeName(type_) });
                },
                64 => {
                    try w.print("typedef i64 {f};\n", .{ c.typeName(type_) });
                },
                else => {
                    @panic("unexpected");
                },
            }
        },
        .vector => {
            const vector_t = type_.cast(.vector);
            try declareType(c, vector_t.elem_t, w);

            try w.print("typedef struct {f} {{\n", .{c.typeName(type_)});
            try w.print("    {f} arr[{}];\n", .{ c.typeName(vector_t.elem_t), vector_t.n });
            try w.print("}} {f};\n", .{ c.typeName(type_) });
        },
        .pointer => {
            const base_t = type_.getBaseType();
            const base_info = c.syms.getPtr(@ptrCast(base_t.sym())).?;
            if (!base_info.declared and !base_info.forward_declared) {
                if (base_t.isCStruct()) {
                    // Forward declare type for pointer type.
                    try w.print("typedef struct {f} {f};\n", .{ c.typeName(base_t), c.typeName(base_t) });
                    base_info.forward_declared = true;
                } else {
                    try declareType(c, base_t, w);
                }
            }
        },
        .borrow => {
            const base_t = type_.getBaseType();
            const base_info = c.syms.getPtr(@ptrCast(base_t.sym())).?;
            if (!base_info.declared and !base_info.forward_declared) {
                try w.print("typedef struct {f} {f};\n", .{ c.typeName(base_t), c.typeName(base_t) });
                base_info.forward_declared = true;
            }
        },
        .generic_trait => {
            const trait_t = type_.cast(.generic_trait);
            for (trait_t.members()) |member| {
                try declareType(c, member.func.sig.ret, w);
                for (member.func.sig.params()[1..]) |param| {
                    try declareType(c, param.get_type(), w);
                }
            }

            try w.print("typedef struct {f}Table {{\n", .{ c.typeName(type_) });
            for (trait_t.members()) |member| {
                try w.writeAll("\t");

                try writeTraitFuncType(c, w, member.func.name(), member.func.sig);
                try w.writeAll(";\n");
            }
            try w.print("}} {f}Table;\n", .{ c.typeName(type_)});

            try w.print("typedef struct {f}Ptr {{\n", .{ c.typeName(type_) });
            try w.print("\tvoid* ptr;\n", .{});
            try w.print("\t{f}Table* vtable;\n", .{ c.typeName(type_) });
            try w.print("}} {f}Ptr;\n", .{ c.typeName(type_) });
            try w.print("typedef void* {f};\n", .{ c.typeName(type_) });
        },
        .ref_trait => {
            const trait_ref = type_.cast(.ref_trait);
            try w.print("typedef {f}Ptr {f};\n", .{ c.typeName(&trait_ref.generic.base), c.typeName(type_) });
        },
        .borrow_trait => {
            const borrow_trait = type_.cast(.borrow_trait);
            try w.print("typedef {f}Ptr {f};\n", .{ c.typeName(&borrow_trait.generic.base), c.typeName(type_) });
        },
        .struct_t => {
            const struct_t = type_.cast(.struct_t);
            for (struct_t.fields()) |field| {
                try declareType(c, field.type, w);
            }

            try w.print("typedef struct {f} {{\n", .{ c.typeName(type_) });
            for (struct_t.fields()) |*field| {
                if (field.type.id() == bt.Void) {
                    try w.print("   u64 {s};\n", .{ c.fieldName(field) });
                } else {
                    try w.print("   {f} {s};\n", .{ c.typeName(field.type), c.fieldName(field) });
                }
            }
            try w.print("}} {f};\n", .{ c.typeName(type_) });
        },
        .c_union => {
            const c_union = type_.cast(.c_union);
            for (c_union.cases()) |case| {
                try declareType(c, case.payload_t, w);
            }

            try w.print("typedef union {f} {{\n", .{ c.typeName(type_) });
            for (c_union.cases()) |*case| {
                try w.print("   {f} {s};\n", .{ c.typeName(case.payload_t), c.caseName(case.name()) });
            }
            try w.print("}} {f};\n", .{ c.typeName(type_) });
        },
        .option => {
            const option_t = type_.cast(.option);
            try declareType(c, option_t.child_t, w);
            if (option_t.zero_union) {
                try w.print("typedef {f} {f};\n", .{ c.typeName(option_t.child_t), c.typeName(type_) });
            } else {
                try w.print(
                    \\typedef struct {f} {{
                    \\    u64 tag;
                    \\    {f} payload;
                    \\}} {f};
                    \\
                , .{ c.typeName(type_), c.typeName(option_t.child_t), c.typeName(type_) });
            }
        },
        .result => {
            const result_t = type_.cast(.result);
            try declareType(c, result_t.child_t, w);

            try w.print("typedef struct {f} {{\n", .{ c.typeName(type_) });
            try w.writeAll("\tu64 tag;\n");
            try w.writeAll("\tunion {\n");
            try w.print("\t\t{f} result;\n", .{ c.typeName(result_t.child_t) });
            try w.print("\t\t{f} error;\n", .{ c.typeName(c.sema.error_t) });
            try w.writeAll("\t} payload;\n");
            try w.print("}} {f};\n", .{ c.typeName(type_) });
        },
        .never,
        .void => {
            try w.print("typedef i64 {f};\n", .{ c.typeName(type_) });
        },
        .enum_t => {
            try w.print("typedef i64 {f};\n", .{ c.typeName(type_) });
        },
        .choice => {
            const choice_t = type_.cast(.choice);
            for (choice_t.cases()) |case| {
                try declareType(c, case.payload_t, w);
            }
            try w.print("typedef struct {f} {{\n", .{ c.typeName(type_) });
            try w.writeAll("    u64 tag;\n");
            try w.writeAll("    union {\n");
            for (choice_t.cases()) |*case| {
                try w.print("        {f} {s};\n", .{ c.typeName(case.payload_t), c.caseName(case.name()) });
            }
            try w.writeAll("    } payload;\n");
            try w.print("}} {f};\n", .{ c.typeName(type_) });
        },
        else => {
            const name = try c.sema.allocTypeName(type_);
            std.debug.panic("Unsupported: {s}", .{name});
        },
    }
}

pub fn genExternToVmFunc(c: *Chunk, w: anytype, func: *cy.Func, node: *ast.Node) !void {
    _ = node;
    const params = func.sig.params();
    try w.print("{f} {s}(", .{c.typeName(func.sig.ret), c.cFuncName(func)});

    if (params.len > 0) {
        try w.print("{f} p0", .{c.typeName(params[0].get_type())});
        for (params[1..], 1..) |param, i| {
            try w.print(", {f} p{}", .{c.typeName(param.get_type()), i});
        }
    }
    try w.print(") {{\n", .{});

    var reg_size: usize = 0;
    for (func.sig.params()) |param| {
        reg_size += param.get_type().reg_size();
    }
    // TODO: check stack size.

    try w.print("  ZThread* t = host_ensure_thread();\n", .{});

    // Set args for calling back to VM.
    var reg: usize = func.sig.ret.reg_size() + 4;
    for (params, 0..) |param, i| {
        try w.print("  *({f}*)&t->c.fp_end[{}] = p{};\n", .{c.typeName(param.get_type()), reg, i});
        reg += param.get_type().reg_size();
    }

    try w.print("  return *({f}*)host_call_func(t, {}, {});\n", .{
        c.typeName(func.sig.ret),
        func.sig.ret.reg_size(),
        c.compiler.base.genSymMap.get(func).?.extern_func.vm_id,
    });
    try w.print("}}\n", .{});
}

pub extern fn memmove(dst: *anyopaque, src: *anyopaque, num: usize) *anyopaque;

pub fn host_new_obj_init(t: *cy.Thread, id: cy.TypeId, src: [*]u8, size: usize) callconv(.c) cy.Value {
    const obj = t.heap.new_object_undef(id, size) catch cy.fatal();
    const dst: [*]u8 = @ptrCast(obj);
    @memcpy(dst[0..size], src[0..size]);
    return cy.Value.initPtr(obj);
}

pub fn host_ensure_thread() callconv(.c) *cy.Thread {
    const ptr = vmc.cur_thread orelse {
        std.debug.panic("expected existing thread.", .{});
    };
    return @ptrCast(ptr);
}

pub fn host_call_func(t: *cy.Thread, ret_size: usize, func: cy.Value) callconv(.c) ?*anyopaque {
    const func_id: usize = @intCast(func.val);
    const func_ptr = t.c.vm.funcSyms.items[func_id].to_vm_ptr();
    const ret = t.c.fp_end orelse @panic("expected frame end marker");

    return t.callFunc2(ret, @intCast(ret_size), func_ptr) catch |err| {
        // For now, force an exit since the host may decide to ignore a panic.
        // TODO: A better approach might be returning the error but disable the thread until
        //       the error has been acknowledged by the host.
        if (err == error.Panic) {
            t.handleExecResult(vmc.RES_PANIC) catch {};
            const summary = cy.debug.allocLastUserPanicError(t) catch @panic("");
            defer t.alloc.free(summary);
            std.debug.print("{s}", .{summary});
        }
        std.debug.panic("`host_call_func`: {}.", .{err});
    };
}

pub fn gen_extern_func_ptr_wrapper(c: *Chunk, w: anytype, func_ptr: *cy.types.FuncPtr) !void {
    try declareType(c, &func_ptr.base, w);

    // Emit extern wrapper function that calls extern function.
    try w.print("Ret cb_func_ptr{}(ZThread* t) {{\n", .{func_ptr.sig.id});

    if (func_ptr.sig.ret.id() == bt.Void) {
        try w.print("  thread_ret(t, 0);\n", .{});
    } else {
        try w.print("  {f}* ret = thread_ret(t, {});\n", .{c.typeName(func_ptr.sig.ret), func_ptr.sig.ret.reg_size()});
    }

    // Temps.
    try w.print("  {f} ptr = *({f}*)thread_param(t, 1);\n", .{c.typeName(&func_ptr.base), c.typeName(&func_ptr.base)});
    const params = func_ptr.sig.params();
    for (params, 1..) |param, i| {
        const param_t = param.get_type();
        switch (param_t.kind()) {
            else => {
                try w.print("  {f} arg_{} = *({f}*)thread_param(t, {});\n", .{
                    c.typeName(param.get_type()), i,
                    c.typeName(param.get_type()), param.get_type().reg_size()});
            },
        }
    }

    // Gen call.
    try w.print("  ", .{});
    if (func_ptr.sig.ret.id() == bt.Void or func_ptr.sig.ret.id() == bt.Never) {
        try w.print("ptr(", .{});
    } else {
        try w.print("*ret = ptr(", .{});
    }

    // Gen args.
    if (params.len > 0) {
        try w.print("arg_1", .{});
        for (params[1..], 2..) |param, i| {
            _ = param;
            try w.print(", arg_{}", .{i});
        }
    }
    // End of args.
    try w.print(");\n", .{});

    // Gen return.
    try w.print("  return 0;\n", .{});
    try w.print("}}\n", .{});
}

/// If `func` is an extern variant (for variadic), `call_func` is the extern function.
/// Otherwise, `func == call_func`.
pub fn genVmToExternFunc(c: *Chunk, w: anytype, func: *cy.Func, call_func: *cy.Func, node: *ast.Node) !void {
    _ = node;

    const params = func.sig.params();

    const variant = func != call_func;
    if (variant) {
        // Emit extern variant wrapper function that calls extern function.
        try w.print("Ret {s}(ZThread* t) {{\n", .{c.cFuncName(func)});
    } else {
        // Emit extern wrapper function that calls extern function.
        try w.print("Ret CB_{s}(ZThread* t) {{\n", .{c.cFuncName(func)});
    } 

    if (func.sig.ret.id() == bt.Void) {
        try w.print("  thread_ret(t, 0);\n", .{});
    } else {
        try w.print("  {f}* ret = thread_ret(t, {});\n", .{c.typeName(func.sig.ret), func.sig.ret.reg_size()});
    }

    // Temps.
    for (params, 0..) |param, i| {
        switch (param.get_type().kind()) {
            // .struct_t => |struct_t| {
            //     try w.print("  ", .{});
            //     const arg_name = try std.mem.print(&buf, "arg_{}", .{i});
            //     try writeNamedCType(w, param, arg_name);
            //     try w.print(";\n", .{});
            //     try w.print("  Value* src_{} = (Value*)(cy_get_value(vm, {}) & ~PointerMask) + 1;\n", .{i, i});
            //     try w.print("  arg_{} = toStruct{}(vm, src_{});\n", .{i, struct_t.id(), i});
            // },
            // .arr => |arr| {
            //     const elem = arr.child.*;
            //     const elemName = try fmtBaseTypeName(&cy.tempBuf, elem);

            //     try w.print("  ", .{});
            //     const arg_name = try std.mem.print(&buf, "arg_{}", .{i});
            //     try writeNamedCType(w, param, arg_name);
            //     try w.print(";\n", .{});

            //     try w.print("  Value* src_{} = (Value*)(cy_get_value(vm, {}) & ~PointerMask) + 1;\n", .{i, i});
            //     try w.print("  writeToArray{s}(vm, &arg_{}[0], src_{}, {});\n", .{elemName, i, i, arr.n});
            // },
            // .sym => {
            //     try w.print("  Value param_{} = cy_get_value(vm, {});\n", .{i, i});
            //     try w.print("  ", .{});
            //     try writeCType(w, param);
            //     try w.print(" arg_{} = ", .{i});
            //     const param_val = try std.mem.print(&buf, "param_{}", .{i});
            //     try writeToCValue(w, param_val, param, false);
            //     try w.print(";\n", .{});
            // },
            else => {
                try w.print("  {f} arg_{} = *({f}*)thread_param(t, {});\n", .{
                    c.typeName(param.get_type()), i,
                    c.typeName(param.get_type()), param.get_type().reg_size()});
            },
        }
    }

    // Gen call.
    try w.print("  ", .{});
    if (func.sig.ret.id() == bt.Void or func.sig.ret.id() == bt.Never) {
        try w.print("{s}(", .{c.cFuncName(func)});
    } else {
        try w.print("*ret = {s}(", .{c.cFuncName(call_func)});
    }

    // Gen args.
    if (params.len > 0) {
        try w.print("arg_0", .{});
        for (params[1..], 1..) |param, i| {
            _ = param;
            try w.print(", arg_{}", .{i});
        }
    }
    // End of args.
    try w.print(");\n", .{});

    // Gen return.
    try w.print("  return 0;\n", .{});
    try w.print("}}\n", .{});
}

/// From `Value` to C value. 
fn writeToCValue(c: *Chunk, w: anytype, val: []const u8, type_: *cy.Type) !void {
    switch (type_.id()) {
        bt.Bool => {
            try w.print("*(bool*)&{s}", .{val});
        },
        bt.R8,
        bt.I8 => {
            try w.print("*(i8*)&{s}", .{val});
        },
        bt.R16,
        bt.I16 => {
            try w.print("*(i16*)&{s}", .{val});
        },
        bt.R32,
        bt.I32 => {
            try w.print("*(i32*)&{s}", .{val});
        },
        bt.R64,
        bt.I64 => {
            try w.print("*(i64*)&{s}", .{val});
        },
        bt.F32 => {
            try w.print("*(f32*)&{s}", .{val});
        },
        bt.F64 => {
            try w.print("*(f64*)&{s}", .{val});
        },
        else => {
            switch (type_.kind()) {
                .struct_t => {
                    try w.print("*({f}*){s}", .{c.typeName(type_), val});
                },
                // .sym => |sym| {
                //     try writeToCValueForSym(w, val, sym, unbox);
                // },
                .pointer => {
                    const pointer = type_.cast(.pointer);
                    std.debug.assert(!pointer.ref);
                    try w.print("({f}){s}", .{c.typeName(type_), val});
                },
                .func_ptr => {
                    try w.print("({f}){s}", .{c.typeName(type_), val});
                },
                .vector => {
                    const vector_t = type_.cast(.vector);
                    try w.print("*({f}*[{}]){s}", .{c.typeName(vector_t.elem_t), vector_t.n, val});
                },
                else => {
                    std.debug.print("Unsupported arg type: {s} {}\n", .{ type_.name(), type_.id() });
                    return error.InvalidArgument;
                }
            }
        },
    }
}

fn writeTraitFuncType(c: *Chunk, w: anytype, name: []const u8, sig: *cy.FuncSig) !void {
    try w.print("{f} (*{s})(CB_Thread*, void*", .{ c.typeNameRet(sig.ret), name });
    if (sig.params_len > 1) {
        for (sig.params()[1..]) |param| {
            try w.writeAll(", ");
            try writeTypeName(c, w, param.get_type());
        }
    }
    try w.writeAll(")");
}

fn writeFuncPtrType(c: *Chunk, w: anytype, name: []const u8, sig: *cy.FuncSig) !void {
    if (sig.extern_) {
        try w.print("{f} (*{s})(", .{ c.typeNameRet(sig.ret), name });
        if (sig.params_len > 0) {
            const params = sig.params();
            try writeTypeName(c, w, params[0].get_type());
            for (params[1..]) |param| {
                try w.writeAll(", ");
                try writeTypeName(c, w, param.get_type());
            }
        }
    } else {
        try w.print("{f} (*{s})(CB_Thread*", .{ c.typeNameRet(sig.ret), name });
        if (sig.params_len > 0) {
            for (sig.params()) |param| {
                try w.writeAll(", ");
                try writeTypeName(c, w, param.get_type());
            }
        }
    }
    try w.writeAll(")");
}

fn writeTypeName(c: *Chunk, w: anytype, type_: *cy.Type) !void {
    switch (type_.kind()) {
        .pointer => {
            const child_t = type_.cast(.pointer).child_t;
            if (child_t.id() == bt.Void) {
                try w.writeAll("void*");
            } else {
                try writeTypeName(c, w, type_.cast(.pointer).child_t);
                try w.writeByte('*');
            }
        },
        .borrow => {
            try writeTypeName(c, w, type_.cast(.borrow).child_t);
            try w.writeByte('*');
        },
        else => {
            const name = c.cSymName(@ptrCast(type_.sym()));
            try w.writeAll(name);
        }
    }
}

const TypeName = struct {
    c: *Chunk,
    type: *cy.Type,
    ret: bool = false,

    fn init(c: *Chunk, type_: *cy.Type) TypeName {
        return .{
            .c = c,
            .type = type_,
        };
    }

    pub fn format(self: TypeName, w: *std.Io.Writer) !void {
        if (self.ret) {
            switch (self.type.id()) {
                bt.Void, bt.Never => {
                    try w.writeAll("void");
                },
                else => {
                    try writeTypeName(self.c, w, self.type);
                },
            }
        } else {
            try writeTypeName(self.c, w, self.type);
        }
    }
};

pub fn dumpSource(src: []const u8) !void {
    var iter = std.mem.splitScalar(u8, src, '\n');
    var count: usize = 1;
    while (iter.next()) |line| {
        std.debug.print("{} {s}\n", .{count, line});
        count += 1;
    }
}
