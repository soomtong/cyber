//! Source formatter behind `cyber fmt`.
//!
//! The formatter re-emits the token stream of the source and never prints from the AST, so it cannot drop
//! or reorder a token. The AST is used for three things only:
//!
//!   1. Block structure. Statement lines are re-indented to 4 spaces per block level.
//!   2. Telling binary operators from unary ones.
//!   3. Verification. The output is parsed again and must produce the same AST and the same comments,
//!      otherwise formatting fails and nothing is returned.
//!
//! Line breaks belong to the author. Lines are never joined or split, and continuation lines keep their
//! indentation relative to the statement they belong to. There are no options.
//!
//! This file depends on the tokenizer, the parser and the AST only. It does not need a VM.

const std = @import("std");
const cy = @import("cyber.zig");
const ast = cy.ast;
const Node = ast.Node;
const NodeType = ast.NodeType;
const TokenType = cy.TokenType;

pub const indent_width = 4;

pub const ErrorKind = enum {
    none,
    /// The source does not tokenize or parse. `pos` is the byte offset reported by the parser.
    parse,
    /// The formatted output did not parse back to the same AST. This is a formatter bug.
    verify,
};

/// Describes why `format` failed.
pub const Diagnostic = struct {
    kind: ErrorKind = .none,
    /// Byte offset into the source for `parse`.
    pos: u32 = 0,
    /// 0-based.
    line: u32 = 0,
    col: u32 = 0,
    /// Owned by the diagnostic.
    msg: []const u8 = "",

    pub fn deinit(self: *Diagnostic, alloc: std.mem.Allocator) void {
        alloc.free(self.msg);
        self.* = .{};
    }
};

pub const Error = error{ ParseError, VerifyError, OutOfMemory };

/// Formats `src` and returns the result, owned by the caller.
/// On `ParseError` and `VerifyError`, `diag` describes the failure and owns its message.
pub fn format(alloc: std.mem.Allocator, src: []const u8, diag: *Diagnostic) Error![]u8 {
    diag.* = .{};
    if (src.len >= (1 << 24)) {
        // Token positions are 24 bits.
        return fail(alloc, diag, .parse, src, 0, "Source is too large.");
    }

    var input: Parsed = undefined;
    try input.init(alloc, src, diag);
    defer input.deinit();

    var f = Formatter{
        .alloc = alloc,
        .src = src,
    };
    defer f.deinit();
    f.run(input.root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => return fail(alloc, diag, .verify, src, 0, "Unexpected token stream."),
    };

    const out = try f.out.toOwnedSlice(alloc);
    errdefer alloc.free(out);

    var check_diag: Diagnostic = .{};
    var output: Parsed = undefined;
    output.init(alloc, out, &check_diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            defer check_diag.deinit(alloc);
            const msg = try std.fmt.allocPrint(alloc, "Formatted output does not parse at {}:{}: {s}\n    {s}", .{
                check_diag.line + 1, check_diag.col + 1, check_diag.msg, lineText(out, check_diag.pos),
            });
            diag.* = .{ .kind = .verify, .msg = msg };
            return error.VerifyError;
        },
    };
    defer output.deinit();

    var cmp = Comparer{ .a_src = src, .b_src = out };
    if (!cmp.eqNode(@ptrCast(input.root), @ptrCast(output.root))) {
        return fail(alloc, diag, .verify, src, cmp.a_pos, "Formatted output parses to a different syntax tree.");
    }
    if (!eqComments(src, input.comments(), out, output.comments())) {
        return fail(alloc, diag, .verify, src, 0, "Formatted output has different comments.");
    }
    return out;
}

fn fail(alloc: std.mem.Allocator, diag: *Diagnostic, kind: ErrorKind, src: []const u8, pos: u32, msg: []const u8) Error {
    var line: u32 = 0;
    var col: u32 = 0;
    computeLineCol(src, pos, &line, &col);
    diag.* = .{
        .kind = kind,
        .pos = pos,
        .line = line,
        .col = col,
        .msg = try alloc.dupe(u8, msg),
    };
    return if (kind == .parse) error.ParseError else error.VerifyError;
}

/// The source line that contains `pos`, without indentation.
fn lineText(src: []const u8, pos: u32) []const u8 {
    const at = @min(pos, src.len);
    const start = if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |idx| idx + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, src, at, '\n') orelse src.len;
    return std.mem.trim(u8, src[start..end], " \t\r");
}

fn computeLineCol(src: []const u8, pos: u32, out_line: *u32, out_col: *u32) void {
    var line: u32 = 0;
    var line_start: u32 = 0;
    const end = @min(pos, src.len);
    for (src[0..end], 0..) |ch, i| {
        if (ch == '\n') {
            line += 1;
            line_start = @intCast(i + 1);
        }
    }
    out_line.* = line;
    out_col.* = @as(u32, @intCast(end)) - line_start;
}

/// A parsed source. Keeps the parser alive because the AST points into it.
const Parsed = struct {
    alloc: std.mem.Allocator,
    parser: cy.Parser,
    root: *ast.Root,
    diag: *Diagnostic,
    src: []const u8,

    /// `self` must not move after this, the parser reports errors through a pointer to it.
    fn init(self: *Parsed, alloc: std.mem.Allocator, src: []const u8, diag: *Diagnostic) Error!void {
        self.* = .{
            .alloc = alloc,
            .parser = undefined,
            .root = undefined,
            .diag = diag,
            .src = src,
        };
        try self.parser.init(alloc);
        errdefer self.parser.deinit();
        self.parser.reportFn = parserReport;
        self.parser.tokenizerReportFn = tokenizerReport;
        self.parser.ctx = self;

        const res = self.parser.parse(src, 0, .{ .parseComments = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.parseFailed(),
        };
        if (res.has_error or res.root == null) {
            return self.parseFailed();
        }
        self.root = res.root.?;
    }

    fn deinit(self: *Parsed) void {
        self.parser.deinit();
    }

    fn comments(self: *Parsed) []const cy.IndexSlice(u32) {
        return self.parser.ast.comments.items;
    }

    fn parseFailed(self: *Parsed) Error {
        if (self.diag.kind == .none) {
            return fail(self.alloc, self.diag, .parse, self.src, 0, "Parse error.");
        }
        return error.ParseError;
    }

    fn report(self: *Parsed, fmt_str: []const u8, args: []const cy.fmt.FmtValue, pos: u32) void {
        if (self.diag.kind != .none) {
            return;
        }
        const msg = cy.fmt.allocFormat(self.alloc, fmt_str, args) catch return;
        var line: u32 = 0;
        var col: u32 = 0;
        computeLineCol(self.src, pos, &line, &col);
        self.diag.* = .{ .kind = .parse, .pos = pos, .line = line, .col = col, .msg = msg };
    }

    fn parserReport(p: *cy.Parser, fmt_str: []const u8, args: []const cy.fmt.FmtValue, pos: u32) anyerror {
        const self: *Parsed = @ptrCast(@alignCast(p.ctx));
        self.report(fmt_str, args, pos);
        return error.ParseError;
    }

    fn tokenizerReport(ctx: *anyopaque, fmt_str: []const u8, args: []const cy.fmt.FmtValue, pos: u32) anyerror!void {
        const self: *Parsed = @ptrCast(@alignCast(ctx));
        self.report(fmt_str, args, pos);
        return error.TokenError;
    }
};

// ---------------------------------------------------------------------------------------------------------
// Generic access to AST node fields.
// ---------------------------------------------------------------------------------------------------------

/// Whether `T` is the payload type of some AST node.
fn isNodeData(comptime T: type) bool {
    if (T == Node) {
        return true;
    }
    inline for (comptime std.enums.values(NodeType)) |t| {
        if (ast.NodeData(t) == T) {
            return true;
        }
    }
    return false;
}

const FieldKind = enum {
    /// `*T` where `T` is a node payload.
    node,
    /// `?*T`.
    opt_node,
    /// `[]*T`, `[]const *T`, `ast.Slice(*T)` or `ast.ConstSlice(*T)`.
    nodes,
    /// `ast.ConstSlice(u8)` or `[]const u8`.
    bytes,
    /// `bool` or an enum.
    scalar,
    /// Positions, unions and anything else that does not take part in the tree shape.
    other,
};

fn isNodePtr(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .pointer and info.pointer.size == .one and @typeInfo(info.pointer.child) == .@"struct" and
        isNodeData(info.pointer.child);
}

/// Returns the element type if `T` is one of the slice shapes used by the AST.
fn sliceElem(comptime T: type) ?type {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice) {
        return info.pointer.child;
    }
    if (info == .@"struct" and @hasField(T, "ptr") and @hasField(T, "len") and @typeInfo(T).@"struct".field_names.len == 2) {
        const ptr_info = @typeInfo(@FieldType(T, "ptr"));
        if (ptr_info == .pointer and ptr_info.pointer.size == .many) {
            return ptr_info.pointer.child;
        }
    }
    return null;
}

fn fieldKind(comptime T: type) FieldKind {
    if (isNodePtr(T)) {
        return .node;
    }
    const info = @typeInfo(T);
    if (info == .optional and isNodePtr(info.optional.child)) {
        return .opt_node;
    }
    if (sliceElem(T)) |Elem| {
        if (Elem == u8) {
            return .bytes;
        }
        if (isNodePtr(Elem)) {
            return .nodes;
        }
        return .other;
    }
    if (info == .bool or info == .@"enum") {
        return .scalar;
    }
    return .other;
}

/// Views a `nodes` field as a slice of untyped nodes.
fn nodeSlice(value: anytype) []const *Node {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .pointer) {
        const ptr: [*]const *Node = @ptrCast(value.ptr);
        return ptr[0..value.len];
    } else {
        if (value.len == 0) {
            return &.{};
        }
        const ptr: [*]const *Node = @ptrCast(value.ptr);
        return ptr[0..value.len];
    }
}

fn byteSlice(value: anytype) []const u8 {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .pointer) {
        return value;
    } else {
        if (value.len == 0) {
            return "";
        }
        return value.ptr[0..value.len];
    }
}

fn nameIs(comptime name: []const u8, comptime options: []const []const u8) bool {
    inline for (options) |opt| {
        if (comptime std.mem.eql(u8, name, opt)) {
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------------------------------------
// Formatter.
// ---------------------------------------------------------------------------------------------------------

/// A token, a comment, or a whole string template. Templates are opaque, their text is copied as is.
const Atom = struct {
    pos: u32,
    end: u32,
    tag: TokenType,
    is_comment: bool = false,

    /// First atom on its source line.
    line_start: bool = false,
    /// At least one blank line precedes this line. Only for `line_start`.
    blank_before: bool = false,
    /// Number of whitespace bytes that separate this atom from the previous one on the same line.
    gap: u32 = 0,
    /// Index into `Formatter.lines`.
    line: u32 = 0,

    mark: Mark = .none,
    /// Inside brackets that were opened by the statement this atom belongs to.
    in_brackets: bool = false,
};

const Mark = enum(u8) {
    none,
    /// Operator of a binary expression.
    binary,
    /// Operator of a unary expression.
    unary,
    /// Operator of an op assignment such as `+` in `+=`.
    assign_op,
    /// Binary operator inside a range bound such as `-` in `0..n-1`. Its spacing is kept as written.
    keep,
};

const RoleKind = enum(u8) {
    /// Not assigned. Resolved as a continuation of the closest statement above.
    none,
    /// Top level statement.
    root,
    /// First line of a statement or member in a block. `ref` is the line that opens the block.
    child,
    /// Starts on its own line but sits at the level of the line `ref`. For example `else`.
    same,
    /// Continuation line of the statement that starts on the line `ref`.
    cont,
};

const Line = struct {
    /// First atom.
    head: u32,
    /// Width of the original indentation. A tab counts as `indent_width`.
    width: u32,
    role: RoleKind = .none,
    ref: u32 = 0,
    new_width: u32 = 0,
    is_comment: bool = false,
};

const Formatter = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    atoms: std.ArrayList(Atom) = .empty,
    lines: std.ArrayList(Line) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// Bytes before the first token: UTF-8 BOM and shebang line.
    prefix_end: u32 = 0,

    const RunError = error{ OutOfMemory, Malformed };

    fn deinit(self: *Formatter) void {
        self.atoms.deinit(self.alloc);
        self.lines.deinit(self.alloc);
        self.out.deinit(self.alloc);
    }

    fn run(self: *Formatter, root: *ast.Root) RunError!void {
        try self.collectAtoms();
        try self.splitLines();
        if (self.atoms.items.len > 0) {
            _ = self.walk(@ptrCast(root));
            try self.resolveIndents();
        }
        try self.emit();
    }

    /// Tokenizes the source again and merges tokens and comments into one list ordered by position.
    fn collectAtoms(self: *Formatter) RunError!void {
        var tokenizer = cy.Tokenizer.init(self.alloc, self.src);
        defer tokenizer.deinit();
        tokenizer.parseComments = true;
        tokenizer.tokenize() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The parser already accepted this source.
            else => return error.Malformed,
        };

        self.prefix_end = prefixEnd(self.src);

        const tokens = tokenizer.tokens.items;
        const comments = tokenizer.comments.items;
        var ci: usize = 0;
        var i: usize = 0;
        while (i < tokens.len) {
            const token = tokens[i];
            const tag = token.tag();
            if (tag == .new_line or tag == .indent) {
                i += 1;
                continue;
            }
            var atom = Atom{ .pos = token.pos(), .end = token.data.end, .tag = tag };
            if (tag == .stringt or tag == .stringt_multi) {
                // The opening delimiter. Skip to the closing one, which has the same tag.
                var j = i + 1;
                while (j < tokens.len and tokens[j].tag() != tag) {
                    j += 1;
                }
                if (j == tokens.len) {
                    return error.Malformed;
                }
                atom.end = tokens[j].data.end;
                i = j;
            }
            i += 1;

            while (ci < comments.len and comments[ci].start < atom.pos) : (ci += 1) {
                try self.pushComment(comments[ci]);
            }
            // Comments inside a template expression are part of the template.
            while (ci < comments.len and comments[ci].start < atom.end) {
                ci += 1;
            }
            if (atom.end <= atom.pos or atom.end > self.src.len) {
                return error.Malformed;
            }
            try self.atoms.append(self.alloc, atom);
        }
        while (ci < comments.len) : (ci += 1) {
            try self.pushComment(comments[ci]);
        }
    }

    fn pushComment(self: *Formatter, comment: cy.IndexSlice(u32)) !void {
        // Drop trailing whitespace, including the `\r` of a CRLF line end.
        const text = std.mem.trimEnd(u8, self.src[comment.start..comment.end], " \t\r");
        try self.atoms.append(self.alloc, .{
            .pos = comment.start,
            .end = comment.start + @as(u32, @intCast(text.len)),
            .tag = .null,
            .is_comment = true,
        });
    }

    fn splitLines(self: *Formatter) !void {
        var prev_end: u32 = self.prefix_end;
        for (self.atoms.items, 0..) |*atom, i| {
            const between = self.src[prev_end..atom.pos];
            const num_new_lines = std.mem.count(u8, between, "\n");
            if (i == 0 or num_new_lines > 0) {
                atom.line_start = true;
                atom.blank_before = i > 0 and num_new_lines > 1;
                var width: u32 = 0;
                var j = atom.pos;
                while (j > 0) {
                    switch (self.src[j - 1]) {
                        ' ' => width += 1,
                        '\t' => width += indent_width,
                        else => break,
                    }
                    j -= 1;
                }
                try self.lines.append(self.alloc, .{
                    .head = @intCast(i),
                    .width = width,
                    .is_comment = atom.is_comment,
                });
            } else {
                atom.gap = @intCast(between.len);
            }
            atom.line = @intCast(self.lines.items.len - 1);
            prev_end = atom.end;
        }
    }

    /// Index of the atom that covers the source position.
    fn atomAt(self: *Formatter, pos: u32) u32 {
        const atoms = self.atoms.items;
        var lo: usize = 0;
        var hi: usize = atoms.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (atoms[mid].pos <= pos) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return @intCast(if (lo == 0) 0 else lo - 1);
    }

    fn lineAt(self: *Formatter, pos: u32) u32 {
        return self.atoms.items[self.atomAt(pos)].line;
    }

    fn validPos(self: *Formatter, pos: u32) bool {
        return pos != cy.NullId and pos < self.src.len;
    }

    fn markAt(self: *Formatter, pos: u32, mark: Mark, comptime tags: []const TokenType) void {
        if (!self.validPos(pos)) {
            return;
        }
        const atom = &self.atoms.items[self.atomAt(pos)];
        if (atom.pos != pos or atom.is_comment or atom.mark == .keep) {
            return;
        }
        inline for (tags) |tag| {
            if (atom.tag == tag) {
                atom.mark = mark;
                return;
            }
        }
    }

    const binary_tags = [_]TokenType{
        .plus,               .minus,            .star,            .double_star,      .slash,
        .percent,            .double_ampersand, .double_vert_bar, .tilde,            .double_left_angle,
        .double_right_angle, .bang_equal,       .left_angle,      .left_angle_equal, .right_angle,
        .right_angle_equal,  .equal_equal,      .and_k,           .or_k,
    };
    const unary_tags = [_]TokenType{ .minus, .bang, .tilde };
    const assign_op_tags = [_]TokenType{
        .plus,               .minus,            .star,            .double_star, .slash,
        .percent,            .double_ampersand, .double_vert_bar, .tilde,       .double_left_angle,
        .double_right_angle,
    };

    /// Visits the node and its children. Records operator marks and line roles.
    /// Returns the index of the last atom that belongs to the node.
    fn walk(self: *Formatter, node: *Node) u32 {
        switch (node.type()) {
            .null, .label_decl => return 0,
            inline else => |t| return self.walkData(t, node, node.cast(t)),
        }
    }

    fn walkData(self: *Formatter, comptime t: NodeType, node: *Node, data: *ast.NodeData(t)) u32 {
        var last: u32 = 0;
        const pos = node.pos();
        if (self.validPos(pos)) {
            last = self.atomAt(pos);
        }

        switch (t) {
            .binExpr => {
                if (data.op == .range or data.op == .reverse_range) {
                    self.keepBinary(data.left);
                    self.keepBinary(data.right);
                } else {
                    self.markAt(data.op_pos, .binary, &binary_tags);
                }
            },
            .for_range_stmt => {
                self.keepBinary(data.start);
                self.keepBinary(data.end);
            },
            .range => {
                if (data.start) |start| {
                    self.keepBinary(start);
                }
                if (data.end) |end| {
                    self.keepBinary(end);
                }
            },
            .unary_expr => self.markAt(data.pos, .unary, &unary_tags),
            .op_assign_stmt => self.markAt(data.assign_pos, .assign_op, &assign_op_tags),
            .root => {
                for (nodeSlice(data.stmts)) |stmt| {
                    const stmt_pos = stmt.pos();
                    if (self.validPos(stmt_pos)) {
                        const line = &self.lines.items[self.lineAt(stmt_pos)];
                        if (line.role == .none) {
                            line.role = .root;
                        }
                    }
                    last = @max(last, self.walkStmt(stmt));
                }
                return last;
            },
            .case_stmt => {
                if (data.kind == .case) {
                    for (nodeSlice(data.data.case.conds)) |cond| {
                        last = @max(last, self.walk(cond));
                    }
                    if (data.data.case.capture) |capture| {
                        last = @max(last, self.walk(capture));
                    }
                }
                switch (data.body_kind) {
                    .block => last = @max(last, self.walkBlock(node, nodeSlice(data.body_data.block))),
                    .expr => last = @max(last, self.walk(data.body_data.expr)),
                    .fallthrough => {},
                }
                return last;
            },
            else => {},
        }

        const info = @typeInfo(@TypeOf(data.*)).@"struct";
        inline for (info.field_names, info.field_types) |field_name, FieldT| {
            const value = @field(data, field_name);
            switch (comptime fieldKind(FieldT)) {
                .node => {
                    const child: *Node = @ptrCast(value);
                    if (comptime nameIs(field_name, &.{"catchStmt"})) {
                        self.markSame(node, child);
                    }
                    last = @max(last, self.walk(child));
                },
                .opt_node => {
                    if (value) |ptr| {
                        const child: *Node = @ptrCast(ptr);
                        if (comptime nameIs(field_name, &.{"with"})) {
                            self.markSame(node, child);
                        }
                        last = @max(last, self.walk(child));
                    }
                },
                .nodes => {
                    const children = nodeSlice(value);
                    if (comptime nameIs(field_name, &.{ "stmts", "else_stmts", "cases", "fields", "members", "funcs", "impls" })) {
                        last = @max(last, self.walkBlock(node, children));
                    } else {
                        const same = comptime nameIs(field_name, &.{ "else_blocks", "attrs" });
                        for (children) |child| {
                            if (same) {
                                self.markSame(node, child);
                            }
                            last = @max(last, self.walk(child));
                        }
                    }
                },
                .bytes, .scalar => {},
                .other => {
                    // Closing positions such as the `)` of a call.
                    if (FieldT == u32 and comptime nameIs(field_name, &.{ "end", "sig_end", "op_end" })) {
                        if (value > 0 and value != cy.NullId and value <= self.src.len) {
                            last = @max(last, self.atomAt(value - 1));
                        }
                    }
                },
            }
        }
        return last;
    }

    /// Spacing a range bound would read as if the range bound tighter: `0..n - 1`.
    fn keepBinary(self: *Formatter, node: *Node) void {
        if (node.type() != .binExpr) {
            return;
        }
        const expr = node.cast(.binExpr);
        self.markAt(expr.op_pos, .keep, &binary_tags);
        self.keepBinary(expr.left);
        self.keepBinary(expr.right);
    }

    /// `children` are the statements or members of a block opened by `owner`.
    fn walkBlock(self: *Formatter, owner: *Node, children: []const *Node) u32 {
        var last: u32 = 0;
        const owner_pos = owner.pos();
        const anchor: ?u32 = if (self.validPos(owner_pos)) self.lineAt(owner_pos) else null;
        for (children) |child| {
            const child_pos = child.pos();
            if (anchor != null and self.validPos(child_pos)) {
                const line_idx = self.lineAt(child_pos);
                const line = &self.lines.items[line_idx];
                if (line_idx > anchor.? and line.role == .none) {
                    line.role = .child;
                    line.ref = anchor.?;
                }
            }
            last = @max(last, self.walkStmt(child));
        }
        return last;
    }

    /// Walks a statement, then claims the lines it spans that no nested statement has claimed.
    fn walkStmt(self: *Formatter, stmt: *Node) u32 {
        const last = self.walk(stmt);
        const pos = stmt.pos();
        if (!self.validPos(pos)) {
            return last;
        }
        const first_line = self.lineAt(pos);
        const last_line = self.atoms.items[last].line;
        var i = first_line + 1;
        while (i <= last_line) : (i += 1) {
            const line = &self.lines.items[i];
            if (line.role == .none) {
                line.role = .cont;
                line.ref = first_line;
            }
        }
        return last;
    }

    /// `node` starts a line of its own that belongs at the level of `owner`.
    fn markSame(self: *Formatter, owner: *Node, node: *Node) void {
        const owner_pos = owner.pos();
        const pos = node.pos();
        if (!self.validPos(owner_pos) or !self.validPos(pos)) {
            return;
        }
        const owner_line = self.lineAt(owner_pos);
        const line_idx = self.lineAt(pos);
        const line = &self.lines.items[line_idx];
        if (line_idx > owner_line and line.role == .none) {
            line.role = .same;
            line.ref = owner_line;
        }
    }

    const OpenBracket = struct {
        /// Line of the bracket.
        line: u32,
        /// First line of the statement that the bracket belongs to.
        stmt: u32,
    };

    fn resolveIndents(self: *Formatter) !void {
        const lines = self.lines.items;
        const atoms = self.atoms.items;

        // Brackets that are open at the current position. A statement closes all of its brackets, so the
        // top of the stack belongs to the current statement or to one that encloses it.
        var open: std.ArrayList(OpenBracket) = .empty;
        defer open.deinit(self.alloc);

        // Code lines. A line only refers to lines above it.
        var prev_code: ?u32 = null;
        for (lines, 0..) |*line, i| {
            if (line.is_comment) {
                continue;
            }
            if (line.role == .none) {
                // Not reached by the AST walk. Treat as a continuation of the statement above.
                if (prev_code) |prev| {
                    line.role = .cont;
                    line.ref = if (lines[prev].role == .cont) lines[prev].ref else prev;
                } else {
                    line.role = .root;
                }
            }
            const stmt: u32 = if (line.role == .cont) line.ref else @intCast(i);
            switch (line.role) {
                .none => unreachable,
                .root => line.new_width = 0,
                .child => line.new_width = lines[line.ref].new_width + indent_width,
                .same => line.new_width = lines[line.ref].new_width,
                .cont => {
                    const owner = lines[line.ref];
                    var width: u32 = undefined;
                    const top: ?OpenBracket = if (open.items.len > 0) open.items[open.items.len - 1] else null;
                    if (top != null and top.?.stmt == stmt) {
                        // Inside brackets. A closing bracket lines up with the line that opened it.
                        width = lines[top.?.line].new_width;
                        if (!isClose(atoms[line.head].tag)) {
                            width += indent_width;
                        }
                    } else {
                        // For example the right side of a binary operator. Keep it as written.
                        width = owner.new_width + (line.width -| owner.width);
                    }

                    // The line above can be the end of a block that is nested in this statement, such as
                    // the body of a lambda. This line must not look like one more statement of that block.
                    const prev = prev_code.?;
                    const prev_stmt = if (lines[prev].role == .cont) lines[prev].ref else prev;
                    if (prev_stmt != stmt and width == lines[prev_stmt].new_width) {
                        if (line.width < lines[prev_stmt].width) {
                            width -|= indent_width;
                        } else {
                            width += indent_width;
                        }
                    }
                    line.new_width = width;
                },
            }

            // Track the brackets on this line.
            const end = if (i + 1 < lines.len) lines[i + 1].head else atoms.len;
            for (atoms[line.head..end]) |*atom| {
                if (atom.is_comment) {
                    continue;
                }
                const num_open = open.items.len;
                atom.in_brackets = num_open > 0 and open.items[num_open - 1].stmt == stmt;
                if (isOpen(atom.tag)) {
                    try open.append(self.alloc, .{ .line = @intCast(i), .stmt = stmt });
                } else if (isClose(atom.tag) and atom.in_brackets) {
                    _ = open.pop();
                }
            }
            prev_code = @intCast(i);
        }

        // Comment lines follow the code around them.
        for (lines, 0..) |*line, i| {
            if (!line.is_comment) {
                continue;
            }
            line.new_width = self.commentIndent(i);
        }
    }

    fn commentIndent(self: *Formatter, idx: usize) u32 {
        const lines = self.lines.items;
        const width = lines[idx].width;

        var next: ?usize = null;
        var i = idx + 1;
        while (i < lines.len) : (i += 1) {
            if (!lines[i].is_comment) {
                next = i;
                break;
            }
        }
        if (next) |n| {
            if (lines[n].width == width) {
                return lines[n].new_width;
            }
        }

        // Closest code line above with the same indentation, unless a shallower statement is in between.
        var prev: ?usize = null;
        i = idx;
        while (i > 0) {
            i -= 1;
            const line = lines[i];
            if (line.is_comment) {
                continue;
            }
            if (prev == null) {
                prev = i;
            }
            if (line.width == width) {
                return line.new_width;
            }
            if (line.width < width and line.role != .cont) {
                break;
            }
        }

        if (next) |n| {
            return lines[n].new_width + (width -| lines[n].width);
        }
        if (prev) |p| {
            return lines[p].new_width + (width -| lines[p].width);
        }
        // A file of comments only.
        return 0;
    }

    fn emit(self: *Formatter) !void {
        const atoms = self.atoms.items;
        try self.out.ensureTotalCapacity(self.alloc, self.src.len + self.src.len / 8 + 16);
        // BOM and shebang line. The shebang line loses trailing whitespace like any other line.
        const prefix = self.src[0..self.prefix_end];
        if (std.mem.endsWith(u8, prefix, "\n")) {
            try self.out.appendSlice(self.alloc, std.mem.trimEnd(u8, prefix, " \t\r\n"));
            try self.out.append(self.alloc, '\n');
        } else {
            try self.out.appendSlice(self.alloc, prefix);
        }

        for (atoms, 0..) |atom, i| {
            if (atom.line_start) {
                const line = self.lines.items[atom.line];
                if (i > 0) {
                    try self.out.append(self.alloc, '\n');
                    if (atom.blank_before) {
                        try self.out.append(self.alloc, '\n');
                    }
                }
                try self.out.appendNTimes(self.alloc, ' ', line.new_width);
            } else {
                const prev = atoms[i - 1];
                const prev_prev: ?Atom = if (i >= 2 and !prev.line_start) atoms[i - 2] else null;
                const num_spaces = self.spacing(prev_prev, prev, atom);
                try self.out.appendNTimes(self.alloc, ' ', num_spaces);
            }
            try self.out.appendSlice(self.alloc, self.src[atom.pos..atom.end]);
        }
        if (atoms.len > 0) {
            try self.out.append(self.alloc, '\n');
        }
    }

    /// Number of spaces between two atoms on the same line.
    fn spacing(self: *Formatter, prev_prev: ?Atom, a: Atom, b: Atom) u32 {
        const had_space = b.gap > 0;
        const keep: u32 = if (had_space) 1 else 0;

        if (b.is_comment) {
            // Keep the column of a trailing comment, they are often aligned by hand.
            return @max(b.gap, 1);
        }

        var want: u32 = keep;
        if ((b.tag == .left_bracket or b.tag == .space_left_bracket) and !startsTerm(a)) {
            // After an operand, whitespace before `[` decides between indexing and a new term.
            return keep;
        } else if (isOpen(a.tag)) {
            want = 0;
        } else if (isClose(b.tag)) {
            want = 0;
        } else if (b.tag == .comma) {
            want = 0;
        } else if (a.tag == .comma) {
            want = 1;
        } else if (a.mark == .assign_op) {
            // `+=`
            want = 0;
        } else if (b.mark == .assign_op) {
            want = 1;
        } else if (prev_prev != null and prev_prev.?.mark == .assign_op and a.tag == .equal) {
            want = 1;
        } else if (b.tag == .colon) {
            want = 0;
        } else if (a.tag == .colon) {
            want = 1;
        } else if (a.mark == .binary or b.mark == .binary) {
            want = 1;
        } else if (a.mark == .unary) {
            want = 0;
        } else if (isSpacedOp(a.tag) or isSpacedOp(b.tag)) {
            want = 1;
        } else if (a.tag == .equal and !a.in_brackets) {
            want = 1;
        } else if (b.tag == .equal and !b.in_brackets) {
            want = 1;
        }

        if (want == 0 and had_space and !self.canJoin(a, b)) {
            return 1;
        }
        return want;
    }

    /// Whether removing the space between two atoms keeps them apart as tokens.
    fn canJoin(self: *Formatter, a: Atom, b: Atom) bool {
        const left = self.src[a.end - 1];
        const right = self.src[b.pos];
        if (isWordChar(left) and isWordChar(right)) {
            return false;
        }
        if (isOperatorChar(left) and isOperatorChar(right)) {
            return false;
        }
        // `1 .5` and `1. 5`
        if ((left == '.' and isWordChar(right)) or (isWordChar(left) and right == '.')) {
            return false;
        }
        return true;
    }
};

/// Whether the atom is followed by the start of a new term, never by a postfix operator.
fn startsTerm(a: Atom) bool {
    return isOpen(a.tag) or a.tag == .comma or a.tag == .colon or a.tag == .equal or isSpacedOp(a.tag) or
        a.mark == .binary;
}

fn isOpen(tag: TokenType) bool {
    return tag == .left_paren or tag == .left_bracket or tag == .space_left_bracket or tag == .left_brace;
}

fn isClose(tag: TokenType) bool {
    return tag == .right_paren or tag == .right_bracket or tag == .right_brace;
}

/// Operators that always take a space on both sides.
fn isSpacedOp(tag: TokenType) bool {
    return tag == .colon_equal or tag == .minus_right_angle or tag == .equal_right_angle;
}

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80;
}

fn isOperatorChar(ch: u8) bool {
    return switch (ch) {
        '-', '+', '*', '/', '<', '>', '=', '!', '.', ':', '&', '|', '%', '^', '~', '?', '@', '#' => true,
        else => false,
    };
}

/// End of the bytes that the tokenizer skips before the first token.
fn prefixEnd(src: []const u8) u32 {
    var pos: usize = 0;
    if (src.len >= 3 and src[0] == 0xEF and src[1] == 0xBB and src[2] == 0xBF) {
        pos = 3;
    }
    if (src.len >= pos + 2 and src[pos] == '#' and src[pos + 1] == '!') {
        while (pos < src.len) {
            const ch = src[pos];
            pos += 1;
            if (ch == '\n') {
                break;
            }
        }
    }
    return @intCast(pos);
}

// ---------------------------------------------------------------------------------------------------------
// Verification.
// ---------------------------------------------------------------------------------------------------------

/// Compares two syntax trees and ignores source positions.
const Comparer = struct {
    a_src: []const u8,
    b_src: []const u8,
    /// Position in `a_src` of the first node that differs.
    a_pos: u32 = 0,

    fn eqNode(self: *Comparer, a: *Node, b: *Node) bool {
        if (a.type() != b.type()) {
            return self.differs(a);
        }
        switch (a.type()) {
            .null, .label_decl => return true,
            inline else => |t| {
                if (!self.eqData(t, a.cast(t), b.cast(t))) {
                    return self.differs(a);
                }
                return true;
            },
        }
    }

    fn differs(self: *Comparer, a: *Node) bool {
        if (self.a_pos == 0) {
            const pos = a.pos();
            if (pos != cy.NullId and pos < self.a_src.len) {
                self.a_pos = pos;
            }
        }
        return false;
    }

    fn eqNodes(self: *Comparer, a: []const *Node, b: []const *Node) bool {
        if (a.len != b.len) {
            return false;
        }
        for (a, b) |a_node, b_node| {
            if (!self.eqNode(a_node, b_node)) {
                return false;
            }
        }
        return true;
    }

    fn eqData(self: *Comparer, comptime t: NodeType, a: *ast.NodeData(t), b: *ast.NodeData(t)) bool {
        switch (t) {
            .namedArg => {
                const a_name = self.a_src[a.name_pos..][0..a.name_len];
                const b_name = self.b_src[b.name_pos..][0..b.name_len];
                if (!std.mem.eql(u8, a_name, b_name)) {
                    return false;
                }
            },
            .case_stmt => {
                if (a.kind != b.kind or a.body_kind != b.body_kind) {
                    return false;
                }
                if (a.kind == .case) {
                    if (!self.eqNodes(nodeSlice(a.data.case.conds), nodeSlice(b.data.case.conds))) {
                        return false;
                    }
                    const a_capture = a.data.case.capture;
                    const b_capture = b.data.case.capture;
                    if ((a_capture == null) != (b_capture == null)) {
                        return false;
                    }
                    if (a_capture != null and !self.eqNode(a_capture.?, b_capture.?)) {
                        return false;
                    }
                }
                return switch (a.body_kind) {
                    .block => self.eqNodes(nodeSlice(a.body_data.block), nodeSlice(b.body_data.block)),
                    .expr => self.eqNode(a.body_data.expr, b.body_data.expr),
                    .fallthrough => true,
                };
            },
            else => {},
        }

        const info = @typeInfo(@TypeOf(a.*)).@"struct";
        inline for (info.field_names, info.field_types) |field_name, FieldT| {
            const a_value = @field(a, field_name);
            const b_value = @field(b, field_name);
            switch (comptime fieldKind(FieldT)) {
                .node => {
                    if (!self.eqNode(@ptrCast(a_value), @ptrCast(b_value))) {
                        return false;
                    }
                },
                .opt_node => {
                    if ((a_value == null) != (b_value == null)) {
                        return false;
                    }
                    if (a_value != null and !self.eqNode(@ptrCast(a_value.?), @ptrCast(b_value.?))) {
                        return false;
                    }
                },
                .nodes => {
                    if (!self.eqNodes(nodeSlice(a_value), nodeSlice(b_value))) {
                        return false;
                    }
                },
                .bytes => {
                    if (!std.mem.eql(u8, byteSlice(a_value), byteSlice(b_value))) {
                        return false;
                    }
                },
                .scalar => {
                    if (a_value != b_value) {
                        return false;
                    }
                },
                .other => {},
            }
        }
        return true;
    }
};

fn eqComments(a_src: []const u8, a: []const cy.IndexSlice(u32), b_src: []const u8, b: []const cy.IndexSlice(u32)) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |a_comment, b_comment| {
        const a_text = std.mem.trimEnd(u8, a_src[a_comment.start..a_comment.end], " \t\r");
        const b_text = std.mem.trimEnd(u8, b_src[b_comment.start..b_comment.end], " \t\r");
        if (!std.mem.eql(u8, a_text, b_text)) {
            return false;
        }
    }
    return true;
}
