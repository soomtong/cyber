//! The language server. A host of libcyber: a document is checked by compiling it as a whole program without
//! running it, and the compile reports become diagnostics. See docs/specs/2026-11-12-lsp-design.md.
//!
//! The server is single threaded. `handle` takes one message and queues the replies in `out`. A changed document
//! is only marked, and `flush` checks the marked documents once the client has been quiet for a moment.

const std = @import("std");
const builtin = @import("builtin");
const stdx = @import("stdx");
const c = @import("../capi.zig");
const cli = @import("../cli.zig");
const position = @import("position.zig");
const symbols = @import("symbols.zig");
const complete = @import("complete.zig");
const workspace = @import("workspace.zig");

const Value = std.json.Value;
const Encoding = position.Encoding;

pub const name = "cyber-lsp";

const ErrorCode = struct {
    const parse_error = -32700;
    const invalid_request = -32600;
    const method_not_found = -32601;
    const invalid_params = -32602;
    const internal_error = -32603;
    const server_not_initialized = -32002;
    const request_failed = -32803;
};

const Document = struct {
    /// The key of the document for the client.
    uri: []const u8,
    /// The name of the document for the compiler: the file path of a `file:` uri, otherwise the uri.
    path: []const u8,
    text: []const u8,
    version: ?i64,
    /// Changed since it was checked.
    dirty: bool = true,
    /// Other documents that the last check of this one published diagnostics for.
    related: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Document, alloc: std.mem.Allocator) void {
        for (self.related.items) |uri| alloc.free(uri);
        self.related.deinit(alloc);
        alloc.free(self.uri);
        alloc.free(self.path);
        alloc.free(self.text);
    }
};

const Range = struct {
    start: position.Position,
    end: position.Position,

    const zero: Range = .{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 0 } };
};

const Note = struct {
    uri: []const u8,
    range: Range,
    msg: []const u8,
};

const Diagnostic = struct {
    range: Range,
    msg: []const u8,
    notes: []const Note = &.{},
};

const Group = struct {
    uri: []const u8,
    diags: std.ArrayList(Diagnostic) = .empty,
};

/// The callbacks of the VM have no context of their own and the user data of the VM belongs to `cli.zig`.
var active: ?*Server = null;

pub const Server = struct {
    alloc: std.mem.Allocator,
    vm: *c.VM,
    cli_resolver: c.ResolverFn,

    docs: std.StringHashMapUnmanaged(*Document) = .empty,

    /// The folders of the workspace, as paths. Searched for requests that go beyond the open documents.
    roots: std.ArrayList([]const u8) = .empty,

    /// The `.cy` files of the workspace folders, listed on the first request that needs them and again after
    /// a document was opened, saved or closed. Walking the folders for every keystroke in a symbol search is
    /// too slow for a large workspace. A file that another program creates is seen after the next such event.
    files: std.ArrayList([]const u8) = .empty,
    files_arena: ?std.heap.ArenaAllocator = null,
    files_listed: bool = false,

    /// The document that the VM compiled last, while no document changed since. Its symbol info can be asked.
    compiled: ?*Document = null,

    /// Bodies of the messages to send, in order. Owned by the server until `takeOutput`.
    out: std.ArrayList([]u8) = .empty,

    encoding: Encoding = .utf16,
    related_information: bool = false,
    initialized: bool = false,
    shutdown: bool = false,
    exit: bool = false,

    /// `self` must not move after this.
    pub fn init(self: *Server, alloc: std.mem.Allocator) !void {
        const vm = c.vm_initx(alloc);
        errdefer c.vm_deinit(vm);
        try cli.init_cli(vm, alloc);
        self.* = .{
            .alloc = alloc,
            .vm = vm,
            .cli_resolver = c.c.cl_vm_resolver(vm),
        };
        // stdout carries the protocol. Nothing that a compile prints may reach it.
        c.vm_set_printer(vm, dropPrint);
        c.vm_set_eprinter(vm, dropPrint);
        c.vm_set_logger(vm, dropLog);
        // One diagnostic per body that has an error, not one per document.
        c.vm_set_error_recovery(vm, true);
        // Hover and go to definition ask the compiler what a name refers to.
        c.vm_set_symbol_info(vm, true);
        c.vm_set_resolver(vm, resolver);
        c.vm_set_loader(vm, loader);
        active = self;
    }

    pub fn deinit(self: *Server) void {
        if (active == self) active = null;
        var iter = self.docs.valueIterator();
        while (iter.next()) |doc| {
            doc.*.deinit(self.alloc);
            self.alloc.destroy(doc.*);
        }
        self.docs.deinit(self.alloc);
        for (self.roots.items) |root| self.alloc.free(root);
        self.roots.deinit(self.alloc);
        if (self.files_arena) |*arena| arena.deinit();
        for (self.out.items) |msg| self.alloc.free(msg);
        self.out.deinit(self.alloc);
        cli.deinit_cli(self.vm);
        c.vm_deinit(self.vm);
    }

    /// Whether `flush` has work to do.
    pub fn hasPending(self: *Server) bool {
        var iter = self.docs.valueIterator();
        while (iter.next()) |doc| {
            if (doc.*.dirty) return true;
        }
        return false;
    }

    /// Checks the documents that changed and queues their diagnostics.
    pub fn flush(self: *Server) !void {
        var iter = self.docs.valueIterator();
        while (iter.next()) |doc| {
            if (doc.*.dirty) try self.analyze(doc.*);
        }
    }

    /// Takes one message of the client. Replies are appended to `out`.
    pub fn handle(self: *Server, body: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const root = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.replyError(null, ErrorCode.parse_error, "The message is not JSON."),
        };
        if (root != .object) {
            return self.replyError(null, ErrorCode.invalid_request, "The message is not an object.");
        }
        const id: ?Value = root.object.get("id");
        // An id is a number or a string. It is echoed in the reply, so anything else is refused here
        // (a deeply nested array as the id would otherwise be written back as it came).
        if (id) |v| {
            if (v != .integer and v != .string and v != .float and v != .number_string) {
                return self.replyError(null, ErrorCode.invalid_request, "The id of a request is a number or a string.");
            }
        }
        // A message without a method is the reply to a request. The server sends none.
        const method = getStr(root, "method") orelse return;
        const params: Value = root.object.get("params") orelse .null;
        // A request has an id. Without one there is nobody to reply to: what is not a notification is dropped.
        if (id == null and !isNotification(method)) return;

        self.dispatch(arena, method, id, params) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidParams => if (id != null) {
                try self.replyError(id, ErrorCode.invalid_params, "Invalid parameters.");
            },
            else => if (id != null) {
                try self.replyError(id, ErrorCode.internal_error, @errorName(err));
            },
        };
    }

    fn dispatch(self: *Server, arena: std.mem.Allocator, method: []const u8, id: ?Value, params: Value) !void {
        if (std.mem.eql(u8, method, "exit")) {
            self.exit = true;
            return;
        }
        if (std.mem.eql(u8, method, "initialize")) {
            return self.onInitialize(id, params);
        }
        if (!self.initialized) {
            // Requests before `initialize` are refused and notifications are dropped.
            if (id != null) try self.replyError(id, ErrorCode.server_not_initialized, "The server is not initialized.");
            return;
        }
        if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown = true;
            return self.replyNull(id);
        }
        if (self.shutdown) {
            if (id != null) try self.replyError(id, ErrorCode.invalid_request, "The server is shut down.");
            return;
        }

        if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.onDidOpen(params);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.onDidChange(params);
        } else if (std.mem.eql(u8, method, "textDocument/didSave")) {
            // A saved file can be a module of any open document.
            var iter = self.docs.valueIterator();
            while (iter.next()) |doc| doc.*.dirty = true;
            self.files_listed = false;
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.onDidClose(params);
        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            try self.onFormatting(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try self.onDocumentSymbol(arena, id, params);
        } else if (std.mem.eql(u8, method, "textDocument/foldingRange")) {
            try self.onFoldingRange(arena, id, params);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.onHover(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try self.onDefinition(arena, id, params);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.onCompletion(arena, id, params);
        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            try self.onSignatureHelp(arena, id, params);
        } else if (std.mem.eql(u8, method, "workspace/symbol")) {
            try self.onWorkspaceSymbol(arena, id, params);
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            try self.onSemanticTokens(arena, id, params);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            try self.onReferences(arena, id, params);
        } else if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
            try self.onDocumentHighlight(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/prepareRename")) {
            try self.onPrepareRename(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/rename")) {
            try self.onRename(id, params);
        } else if (id != null) {
            try self.replyError(id, ErrorCode.method_not_found, "The method is not supported.");
        }
        // Other notifications (`initialized`, `$/cancelRequest`, `$/setTrace`, ...) need no action.
    }

    // -----------------------------------
    // [ Lifecycle ]
    // -----------------------------------

    fn onInitialize(self: *Server, id: ?Value, params: Value) !void {
        // Positions are bytes if the client can count that way, which saves the conversion on both sides.
        self.encoding = .utf16;
        if (getPath(params, &.{ "capabilities", "general", "positionEncodings" })) |encodings| {
            if (encodings == .array) {
                for (encodings.array.items) |enc| {
                    if (enc == .string and std.mem.eql(u8, enc.string, "utf-8")) self.encoding = .utf8;
                }
            }
        }
        self.related_information = false;
        if (getPath(params, &.{ "capabilities", "textDocument", "publishDiagnostics", "relatedInformation" })) |v| {
            self.related_information = v == .bool and v.bool;
        }
        for (self.roots.items) |root| self.alloc.free(root);
        self.roots.clearRetainingCapacity();
        if (getPath(params, &.{"workspaceFolders"})) |folders| {
            if (folders == .array) {
                for (folders.array.items) |folder| {
                    if (getStr(folder, "uri")) |uri| try self.addRoot(uri);
                }
            }
        }
        // Clients from before workspace folders name one root.
        if (self.roots.items.len == 0) {
            if (getStr(params, "rootUri")) |uri| try self.addRoot(uri);
        }
        self.initialized = true;

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginObject();
        {
            try jw.objectField("capabilities");
            try jw.beginObject();
            try jw.objectField("positionEncoding");
            try jw.write(self.encoding.name());
            try jw.objectField("textDocumentSync");
            try jw.beginObject();
            try jw.objectField("openClose");
            try jw.write(true);
            // Full sync: every change carries the whole text.
            try jw.objectField("change");
            try jw.write(1);
            try jw.objectField("save");
            try jw.write(true);
            try jw.endObject();
            try jw.objectField("documentFormattingProvider");
            try jw.write(true);
            try jw.objectField("documentSymbolProvider");
            try jw.write(true);
            try jw.objectField("foldingRangeProvider");
            try jw.write(true);
            try jw.objectField("hoverProvider");
            try jw.write(true);
            try jw.objectField("definitionProvider");
            try jw.write(true);
            try jw.objectField("referencesProvider");
            try jw.write(true);
            try jw.objectField("workspaceSymbolProvider");
            try jw.write(true);
            try jw.objectField("semanticTokensProvider");
            try jw.beginObject();
            try jw.objectField("legend");
            try jw.beginObject();
            try jw.objectField("tokenTypes");
            try jw.beginArray();
            for (semantic_types) |name_| try jw.write(name_);
            try jw.endArray();
            try jw.objectField("tokenModifiers");
            try jw.beginArray();
            try jw.write("readonly");
            try jw.endArray();
            try jw.endObject();
            try jw.objectField("full");
            try jw.write(true);
            try jw.endObject();
            try jw.objectField("completionProvider");
            try jw.beginObject();
            try jw.objectField("triggerCharacters");
            try jw.beginArray();
            try jw.write(".");
            try jw.endArray();
            try jw.endObject();
            try jw.objectField("signatureHelpProvider");
            try jw.beginObject();
            try jw.objectField("triggerCharacters");
            try jw.beginArray();
            try jw.write("(");
            try jw.write(",");
            try jw.endArray();
            try jw.endObject();
            try jw.objectField("documentHighlightProvider");
            try jw.write(true);
            try jw.objectField("renameProvider");
            try jw.beginObject();
            try jw.objectField("prepareProvider");
            try jw.write(true);
            try jw.endObject();
            try jw.endObject();

            try jw.objectField("serverInfo");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(name);
            try jw.objectField("version");
            try jw.write(c.version());
            try jw.endObject();
        }
        try jw.endObject();
        try jw.endObject();
        try self.send(&b);
    }

    // -----------------------------------
    // [ Documents ]
    // -----------------------------------

    fn onDidOpen(self: *Server, params: Value) !void {
        const item = getPath(params, &.{"textDocument"}) orelse return error.InvalidParams;
        const uri = getStr(item, "uri") orelse return error.InvalidParams;
        const text = getStr(item, "text") orelse return error.InvalidParams;
        try self.setDocument(uri, text, getInt(item, "version"));
    }

    fn onDidChange(self: *Server, params: Value) !void {
        const item = getPath(params, &.{"textDocument"}) orelse return error.InvalidParams;
        const uri = getStr(item, "uri") orelse return error.InvalidParams;
        const changes = getPath(params, &.{"contentChanges"}) orelse return error.InvalidParams;
        if (changes != .array or changes.array.items.len == 0) return error.InvalidParams;
        // With full sync the last change is the text.
        const last = changes.array.items[changes.array.items.len - 1];
        if (last == .object and last.object.get("range") != null) return error.InvalidParams;
        const text = getStr(last, "text") orelse return error.InvalidParams;
        try self.setDocument(uri, text, getInt(item, "version"));
    }

    fn setDocument(self: *Server, uri: []const u8, text: []const u8, version: ?i64) !void {
        // Any open document can use this one as a module. The server does not track who uses what,
        // so all of them are checked again.
        var iter = self.docs.valueIterator();
        while (iter.next()) |other| other.*.dirty = true;

        self.compiled = null;
        if (self.docs.get(uri)) |doc| {
            const new_text = try self.alloc.dupe(u8, text);
            self.alloc.free(doc.text);
            doc.text = new_text;
            doc.version = version;
            doc.dirty = true;
            return;
        }
        const path = try documentPath(self.alloc, uri);
        errdefer self.alloc.free(path);
        // Two uris can name one file (`a%2Ecy` and `a.cy`, or a path through a symbolic link). The compiler
        // knows a source by its path, so there is one document per path: the new one takes the place.
        if (self.docByPath(path)) |other| {
            try self.closeDocument(other);
        }
        const doc = try self.alloc.create(Document);
        errdefer self.alloc.destroy(doc);
        const uri_dup = try self.alloc.dupe(u8, uri);
        errdefer self.alloc.free(uri_dup);
        const text_dup = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(text_dup);
        doc.* = .{ .uri = uri_dup, .path = path, .text = text_dup, .version = version };
        try self.docs.put(self.alloc, uri_dup, doc);
        self.files_listed = false;
    }

    fn onDidClose(self: *Server, params: Value) !void {
        const uri = getStr(getPath(params, &.{"textDocument"}) orelse return error.InvalidParams, "uri") orelse return error.InvalidParams;
        const doc = self.docs.get(uri) orelse return;
        try self.closeDocument(doc);
    }

    fn closeDocument(self: *Server, doc: *Document) !void {
        _ = self.docs.remove(doc.uri);
        self.compiled = null;
        self.files_listed = false;
        defer {
            doc.deinit(self.alloc);
            self.alloc.destroy(doc);
        }
        // A document that used this one as a module now reads the file on disk instead of the editor's text.
        var iter = self.docs.valueIterator();
        while (iter.next()) |other| other.*.dirty = true;
        // The diagnostics of a closed document go away with it.
        try self.publish(doc.uri, null, &.{});
        for (doc.related.items) |related| {
            try self.publish(related, null, &.{});
        }
    }

    fn docOf(self: *Server, params: Value) !*Document {
        const uri = getStr(getPath(params, &.{"textDocument"}) orelse return error.InvalidParams, "uri") orelse return error.InvalidParams;
        return self.docs.get(uri) orelse error.InvalidParams;
    }

    fn docByPath(self: *Server, path: []const u8) ?*Document {
        var iter = self.docs.valueIterator();
        while (iter.next()) |doc| {
            if (std.mem.eql(u8, doc.*.path, path)) return doc.*;
        }
        return null;
    }

    // -----------------------------------
    // [ Diagnostics ]
    // -----------------------------------

    fn analyze(self: *Server, doc: *Document) !void {
        doc.dirty = false;

        var arena_state: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // The document is checked as a program of its own. The VM is reset first, so one check leaves
        // nothing behind for the next. Nothing is run and no code is generated.
        const code = self.compile(doc);

        var groups: std.ArrayList(Group) = .empty;
        try groups.append(arena, .{ .uri = doc.uri });

        if (code == c.ErrorCompile) {
            const count = c.vm_compile_report_count(self.vm);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                var rep: c.Report = undefined;
                if (!c.vm_compile_report(self.vm, i, &rep)) break;
                const msg = try validText(arena, c.from_bytes(rep.msg));

                var notes: std.ArrayList(Note) = .empty;
                var note: c.Report = undefined;
                var j: usize = 0;
                while (c.vm_compile_report_note(self.vm, i, j, &note)) : (j += 1) {
                    // A note without a place has nothing to point at.
                    if (!note.has_loc) continue;
                    // Nor has a note inside a standard module, which has no document.
                    if (!self.hasDocument(doc, note)) continue;
                    const note_msg = c.from_bytes(note.msg);
                    try notes.append(arena, .{
                        .uri = try self.uriOfReport(arena, doc, note),
                        .range = try self.rangeOfReport(arena, doc, note),
                        // The call that expanded the template that the error is in has no message.
                        .msg = if (note_msg.len > 0) try validText(arena, note_msg) else "Template expanded here.",
                    });
                }

                const uri = try self.uriOfReport(arena, doc, rep);
                const range = try self.rangeOfReport(arena, doc, rep);
                if (std.mem.eql(u8, uri, doc.uri)) {
                    try groups.items[0].diags.append(arena, .{ .range = range, .msg = msg, .notes = notes.items });
                    continue;
                }

                // The error is in a module that the document uses. A module with a file gets the diagnostic.
                // A standard module (`core`) is embedded in the server and has no document to show it in.
                const has_document = self.hasDocument(doc, rep);
                if (has_document) {
                    const group = try groupOf(arena, &groups, uri);
                    try group.diags.append(arena, .{ .range = range, .msg = msg, .notes = notes.items });
                }
                // The document gets a diagnostic that points to it: at the place in the document that led there
                // (the outermost call that expanded a template), or at its start.
                var at = Range.zero;
                for (notes.items) |n| {
                    if (std.mem.eql(u8, n.uri, doc.uri)) at = n.range;
                }
                var origin: []const Note = notes.items;
                if (has_document) {
                    const one = try arena.alloc(Note, 1);
                    one[0] = .{ .uri = uri, .range = range, .msg = msg };
                    origin = one;
                }
                try groups.items[0].diags.append(arena, .{
                    .range = at,
                    .msg = try std.fmt.allocPrint(arena, "In `{s}`: {s}", .{ try validText(arena, c.from_bytes(rep.uri)), msg }),
                    .notes = origin,
                });
            }
        } else if (code != c.Success) {
            try groups.items[0].diags.append(arena, .{
                .range = Range.zero,
                .msg = try std.fmt.allocPrint(arena, "The document could not be checked (result {}).", .{code}),
            });
        }

        // The diagnostics of another open document come from its own check. Two checks that publish for the
        // same document would replace each other's result.
        var i: usize = 1;
        while (i < groups.items.len) {
            if (self.docs.contains(groups.items[i].uri)) {
                _ = groups.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        for (groups.items, 0..) |group, group_i| {
            try self.publish(group.uri, if (group_i == 0) doc.version else null, group.diags.items);
        }

        // A module that had an error in the last check and has none now is cleared.
        for (doc.related.items) |old| {
            var still = false;
            for (groups.items[1..]) |group| {
                if (std.mem.eql(u8, group.uri, old)) still = true;
            }
            if (!still) try self.publish(old, null, &.{});
        }
        for (doc.related.items) |old| self.alloc.free(old);
        doc.related.clearRetainingCapacity();
        for (groups.items[1..]) |group| {
            const dup = try self.alloc.dupe(u8, group.uri);
            errdefer self.alloc.free(dup);
            try doc.related.append(self.alloc, dup);
        }
    }

    fn compile(self: *Server, doc: *Document) c.ResultCode {
        var config = c.defaultCompileConfig();
        config.skip_codegen = true;
        const code = c.vm_compile(self.vm, doc.path, doc.text, config);
        self.compiled = doc;
        return code;
    }

    /// What is at a position of a document, from the compiler. The VM holds one compile: if it is not the one
    /// of this document, the document is compiled again first.
    fn symbolAt(self: *Server, params: Value, out: *c.SymbolInfo) !?*Document {
        const doc = try self.docOf(params);
        const pos_v = getPath(params, &.{"position"}) orelse return error.InvalidParams;
        const line = getInt(pos_v, "line") orelse return error.InvalidParams;
        const character = getInt(pos_v, "character") orelse return error.InvalidParams;
        if (line < 0 or character < 0) return error.InvalidParams;
        const offset = position.toOffset(doc.text, .{
            .line = std.math.cast(u32, line) orelse return error.InvalidParams,
            .character = std.math.cast(u32, character) orelse return error.InvalidParams,
        }, self.encoding);

        if (self.compiled != doc) {
            _ = self.compile(doc);
        }
        if (!c.vm_symbol_at(self.vm, @intCast(offset), out)) return null;
        return doc;
    }

    /// The text of a source that the compiler names `path`, to convert offsets in it. Null if it can not be read.
    fn sourceOf(self: *Server, arena: std.mem.Allocator, doc: *Document, path: []const u8) ?[]const u8 {
        if (path.len == 0 or std.mem.eql(u8, path, doc.path)) return doc.text;
        if (self.docByPath(path)) |other| return other.text;
        if (!std.Io.Dir.path.isAbsolute(path)) return null;
        return std.Io.Dir.cwd().readFileAlloc(stdx.io(), path, arena, .limited(1 << 26)) catch null;
    }

    fn onHover(self: *Server, id: ?Value, params: Value) !void {
        var info: c.SymbolInfo = undefined;
        const doc = (try self.symbolAt(params, &info)) orelse return self.replyNull(id);

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginObject();
        try jw.objectField("contents");
        try jw.beginObject();
        try jw.objectField("kind");
        try jw.write("markdown");
        try jw.objectField("value");
        const value = try std.fmt.allocPrint(self.alloc, "```cyber\n{s}\n```", .{c.from_bytes(info.detail)});
        defer self.alloc.free(value);
        try jw.write(value);
        try jw.endObject();
        try jw.objectField("range");
        try writeRange(jw, .{
            .start = position.fromOffset(doc.text, info.pos, self.encoding),
            .end = position.fromOffset(doc.text, info.end_pos, self.encoding),
        });
        try jw.endObject();
        try jw.endObject();
        try self.send(&b);
    }

    fn onDefinition(self: *Server, arena: std.mem.Allocator, id: ?Value, params: Value) !void {
        var info: c.SymbolInfo = undefined;
        const doc = (try self.symbolAt(params, &info)) orelse return self.replyNull(id);
        if (!info.has_def) return self.replyNull(id);
        // A declaration in a standard module has no document to go to.
        const path = c.from_bytes(info.def_uri);
        const src = self.sourceOf(arena, doc, path) orelse return self.replyNull(id);
        if (info.def_end_pos > src.len) return self.replyNull(id);
        const uri = if (std.mem.eql(u8, path, doc.path))
            doc.uri
        else if (self.docByPath(path)) |other|
            other.uri
        else
            try pathToUri(arena, path);

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginObject();
        try jw.objectField("uri");
        try jw.write(uri);
        try jw.objectField("range");
        try writeRange(jw, .{
            .start = position.fromOffset(src, info.def_pos, self.encoding),
            .end = position.fromOffset(src, info.def_end_pos, self.encoding),
        });
        try jw.endObject();
        try jw.endObject();
        try self.send(&b);
    }

    fn offsetOf(self: *Server, doc: *Document, params: Value) !usize {
        const pos_v = getPath(params, &.{"position"}) orelse return error.InvalidParams;
        const line = getInt(pos_v, "line") orelse return error.InvalidParams;
        const character = getInt(pos_v, "character") orelse return error.InvalidParams;
        return position.toOffset(doc.text, .{
            .line = std.math.cast(u32, line) orelse return error.InvalidParams,
            .character = std.math.cast(u32, character) orelse return error.InvalidParams,
        }, self.encoding);
    }

    /// Compiles `text` in place of the document. Returns whether it got past the parser: after a syntax error
    /// the compiler has resolved nothing that could be asked about.
    fn compilePatched(self: *Server, doc: *Document, text: []const u8) bool {
        var config = c.defaultCompileConfig();
        config.skip_codegen = true;
        const code = c.vm_compile(self.vm, doc.path, text, config);
        // What the VM holds now is not the document.
        self.compiled = null;
        if (code != c.ErrorCompile) return code == c.Success;
        var rep: c.Report = undefined;
        if (!c.vm_compile_report(self.vm, 0, &rep)) return false;
        return rep.kind == c.ReportCompileError;
    }

    /// The source around the cursor is patched until it parses (`complete.zig`), and the compiler lists the
    /// members of the receiver or the names in scope. The client filters the list by what is typed.
    fn onCompletion(self: *Server, arena: std.mem.Allocator, id: ?Value, params: Value) !void {
        const doc = try self.docOf(params);
        const offset = try self.offsetOf(doc, params);

        var items: []const c.Item = &.{};
        var attempt: usize = 0;
        while (attempt < complete.num_attempts) : (attempt += 1) {
            const patch = (try complete.patchCompletion(arena, doc.text, offset, attempt)) orelse continue;
            if (!self.compilePatched(doc, patch.text)) continue;
            var ptr: [*c]const c.Item = null;
            const len = switch (patch.kind) {
                .member => c.vm_members_at(self.vm, @intCast(patch.pos), &ptr),
                .scope => c.vm_names_at(self.vm, @intCast(patch.pos), &ptr),
            };
            if (len == 0 or ptr == null) continue;
            items = ptr[0..len];
            break;
        }

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginObject();
        try jw.objectField("isIncomplete");
        try jw.write(false);
        try jw.objectField("items");
        try jw.beginArray();
        for (items) |item| {
            try jw.beginObject();
            try jw.objectField("label");
            try jw.write(c.from_bytes(item.name));
            try jw.objectField("kind");
            try jw.write(completionKind(item));
            try jw.objectField("detail");
            try jw.write(c.from_bytes(item.detail));
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
        try jw.endObject();
        try self.send(&b);
    }

    /// `CompletionItemKind` of the protocol.
    fn completionKind(item: c.Item) u8 {
        return switch (item.kind) {
            c.ItemLocal, c.ItemGlobal => 6,
            c.ItemMethod => 2,
            c.ItemFunction => 3,
            c.ItemType => 22,
            c.ItemField => 5,
            c.ItemCase => 20,
            c.ItemConstant => 21,
            c.ItemModule => 9,
            else => 1,
        };
    }

    /// The header of the function whose call the cursor is in, and the argument it is at.
    fn onSignatureHelp(self: *Server, arena: std.mem.Allocator, id: ?Value, params: Value) !void {
        const doc = try self.docOf(params);
        const offset = try self.offsetOf(doc, params);
        const call = complete.enclosingCall(doc.text, offset) orelse return self.replyNull(id);

        var label: []const u8 = "";
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            const text = (try complete.patchCall(arena, doc.text, offset, call, attempt)) orelse continue;
            if (!self.compilePatched(doc, text)) continue;
            var info: c.SymbolInfo = undefined;
            // The name that is called ends where the arguments begin. Its place is the same in the patch.
            if (!c.vm_symbol_at(self.vm, @intCast(call.callee_end), &info)) continue;
            if (info.kind != c.SymbolDecl or info.end_pos != call.callee_end) continue;
            const detail = c.from_bytes(info.detail);
            if (!std.mem.startsWith(u8, detail, "fn ")) continue;
            label = try arena.dupe(u8, detail);
            break;
        }
        if (label.len == 0) return self.replyNull(id);
        // `fn add(a int) -> int (+1 overloads)`: the note is not part of the header.
        if (std.mem.find(u8, label, " (+")) |note| label = label[0..note];
        const sig_params = try complete.signatureParams(arena, label);

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginObject();
        try jw.objectField("signatures");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("label");
        try jw.write(label);
        try jw.objectField("parameters");
        try jw.beginArray();
        for (sig_params) |param| {
            try jw.beginObject();
            try jw.objectField("label");
            try jw.write(label[param.start..param.end]);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
        try jw.endArray();
        try jw.objectField("activeSignature");
        try jw.write(0);
        try jw.objectField("activeParameter");
        try jw.write(call.arg);
        try jw.endObject();
        try jw.endObject();
        try self.send(&b);
    }

    /// The places in the document that name what `info` describes. Owned by the VM until its next call.
    fn rangesOf(self: *Server, info: c.SymbolInfo) []const c.Range {
        var ptr: [*c]const c.Range = null;
        const len = c.vm_symbol_refs(self.vm, info.pos, &ptr);
        if (len == 0 or ptr == null) return &.{};
        return ptr[0..len];
    }

    fn rangeIn(self: *Server, doc: *Document, range: c.Range) Range {
        return .{
            .start = position.fromOffset(doc.text, range.pos, self.encoding),
            .end = position.fromOffset(doc.text, range.end_pos, self.encoding),
        };
    }

    fn addRoot(self: *Server, uri: []const u8) !void {
        // The canonical path, like the paths of the documents and of the modules that the compiler resolves.
        const path = try documentPath(self.alloc, uri);
        errdefer self.alloc.free(path);
        self.files_listed = false;
        // Only a folder on disk can be listed.
        if (!std.Io.Dir.path.isAbsolute(path)) {
            self.alloc.free(path);
            return;
        }
        try self.roots.append(self.alloc, path);
    }

    const Source = struct {
        path: []const u8,
        uri: []const u8,
        text: []const u8,
    };

    /// The sources of the workspace: the open documents with the text of the editor, and the `.cy` files of the
    /// workspace folders that are not open, with their paths only (`text` is empty until `load`).
    fn sources(self: *Server, arena: std.mem.Allocator) ![]Source {
        var out: std.ArrayList(Source) = .empty;
        var iter = self.docs.valueIterator();
        while (iter.next()) |doc| {
            try out.append(arena, .{ .path = doc.*.path, .uri = doc.*.uri, .text = doc.*.text });
        }
        const num_open = out.items.len;
        if (!self.files_listed) {
            if (self.files_arena) |*files_arena| files_arena.deinit();
            self.files_arena = std.heap.ArenaAllocator.init(self.alloc);
            self.files = .empty;
            const files_alloc = self.files_arena.?.allocator();
            var budget: workspace.Budget = .{};
            for (self.roots.items) |root| {
                try workspace.collectFiles(files_alloc, root, &self.files, &budget, 0);
            }
            self.files_listed = true;
        }
        for (self.files.items) |path| {
            if (self.docByPath(path) != null) continue;
            try out.append(arena, .{ .path = path, .uri = "", .text = "" });
        }
        // The open documents in a fixed order too: the map has none.
        std.mem.sort(Source, out.items[0..num_open], {}, struct {
            fn lessThan(_: void, x: Source, y: Source) bool {
                return std.mem.order(u8, x.path, y.path) == .lt;
            }
        }.lessThan);
        return out.items;
    }

    /// Reads a source that `sources` listed by path. False if it can not be read.
    fn load(arena: std.mem.Allocator, src: *Source) !bool {
        if (src.uri.len > 0) return true;
        src.text = workspace.readFile(arena, src.path) orelse return false;
        src.uri = try pathToUri(arena, src.path);
        return true;
    }

    /// The uses of a name. A local is only used in its function. Anything else can be used by every source of
    /// the workspace: each one that has the name in its text is compiled as a program of its own, and the
    /// compiler is asked for the places that name the same declaration.
    fn onReferences(self: *Server, arena: std.mem.Allocator, id: ?Value, params: Value) !void {
        var info: c.SymbolInfo = undefined;
        const doc = (try self.symbolAt(params, &info)) orelse return self.replyNull(id);
        var include_decl = true;
        if (getPath(params, &.{ "context", "includeDeclaration" })) |v| {
            include_decl = !(v == .bool and !v.bool);
        }
        // What the VM owns is copied: it compiles other sources below.
        const def_path = try arena.dupe(u8, c.from_bytes(info.def_uri));
        const name_ = try arena.dupe(u8, doc.text[info.pos..info.end_pos]);
        const decl_here = info.has_def and std.mem.eql(u8, def_path, doc.path);

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginArray();
        try self.writeLocations(jw, doc.uri, doc.text, self.rangesOf(info), if (!include_decl and decl_here) info.def_pos else null);

        // A declaration in a standard module has no place that other sources could be matched against.
        const everywhere = info.kind == c.SymbolDecl and info.has_def and
            (decl_here or std.Io.Dir.path.isAbsolute(def_path) or self.docByPath(def_path) != null);
        if (everywhere) {
            var compiled: usize = 0;
            for (try self.sources(arena)) |*src| {
                if (std.mem.eql(u8, src.path, doc.path)) continue;
                if (compiled >= max_reference_compiles) break;
                if (!try load(arena, src)) continue;
                if (!workspace.hasWord(src.text, name_)) continue;
                var config = c.defaultCompileConfig();
                config.skip_codegen = true;
                _ = c.vm_compile(self.vm, src.path, src.text, config);
                self.compiled = null;
                compiled += 1;
                var ptr: [*c]const c.Range = null;
                const len = c.vm_symbol_refs_to(self.vm, c.to_bytes(def_path), info.def_pos, &ptr);
                if (len == 0 or ptr == null) continue;
                const declares = std.mem.eql(u8, src.path, def_path);
                try self.writeLocations(jw, src.uri, src.text, ptr[0..len], if (!include_decl and declares) info.def_pos else null);
            }
        }
        try jw.endArray();
        try jw.endObject();
        try self.send(&b);
    }

    /// With `skip_decl_at`, the first range at or after that offset is left out: the name in the declaration.
    fn writeLocations(self: *Server, jw: *std.json.Stringify, uri: []const u8, text: []const u8, ranges: []const c.Range, skip_decl_at: ?u32) !void {
        var skipped = skip_decl_at == null;
        for (ranges) |range| {
            if (range.end_pos > text.len) continue;
            if (!skipped and range.pos >= skip_decl_at.?) {
                skipped = true;
                continue;
            }
            try jw.beginObject();
            try jw.objectField("uri");
            try jw.write(uri);
            try jw.objectField("range");
            try writeRange(jw, .{
                .start = position.fromOffset(text, range.pos, self.encoding),
                .end = position.fromOffset(text, range.end_pos, self.encoding),
            });
            try jw.endObject();
        }
    }

    /// The declarations of every source of the workspace whose name matches the query. Only the parser runs.
    fn onWorkspaceSymbol(self: *Server, arena: std.mem.Allocator, id: ?Value, params: Value) !void {
        const query = getStr(params, "query") orelse "";

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginArray();
        var count: usize = 0;
        for (try self.sources(arena)) |*src| {
            if (count >= max_workspace_symbols) break;
            if (!try load(arena, src)) continue;
            const syms = (try symbols.documentSymbols(arena, src.text)) orelse continue;
            try self.writeWorkspaceSymbols(jw, src.*, syms, "", query, &count);
        }
        try jw.endArray();
        try jw.endObject();
        try self.send(&b);
    }

    fn writeWorkspaceSymbols(self: *Server, jw: *std.json.Stringify, src: Source, syms: []const symbols.Symbol, container: []const u8, query: []const u8, count: *usize) !void {
        for (syms) |sym| {
            if (count.* >= max_workspace_symbols) return;
            // The locals of a main block are not what a search across files is for.
            if (container.len == 0 and sym.kind == .variable) continue;
            if (workspace.matches(sym.name, query)) {
                count.* += 1;
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(sym.name);
                try jw.objectField("kind");
                try jw.write(@intFromEnum(sym.kind));
                if (container.len > 0) {
                    try jw.objectField("containerName");
                    try jw.write(container);
                }
                try jw.objectField("location");
                try jw.beginObject();
                try jw.objectField("uri");
                try jw.write(src.uri);
                try jw.objectField("range");
                try writeRange(jw, .{
                    .start = position.fromOffset(src.text, sym.name_pos, self.encoding),
                    .end = position.fromOffset(src.text, sym.name_end, self.encoding),
                });
                try jw.endObject();
                try jw.endObject();
            }
            try self.writeWorkspaceSymbols(jw, src, sym.children, sym.name, query, count);
        }
    }

    /// The names that the compiler resolved, by what they are. A name that the compiler did not reach (after
    /// the first error of its body) has no token and keeps the color of the grammar.
    fn onSemanticTokens(self: *Server, arena: std.mem.Allocator, id: ?Value, params: Value) !void {
        const doc = try self.docOf(params);
        if (self.compiled != doc) {
            _ = self.compile(doc);
        }
        var ptr: [*c]const c.Token = null;
        const len = c.vm_symbol_tokens(self.vm, &ptr);
        const tokens: []const c.Token = if (len == 0 or ptr == null) &.{} else ptr[0..len];

        // Five numbers per token: the line and the start relative to the token before, the length, the type
        // and the modifiers. The tokens come sorted, so the text is walked once.
        var data: std.ArrayList(u32) = .empty;
        var offset: usize = 0;
        var line: u32 = 0;
        var line_start: usize = 0;
        var prev_line: u32 = 0;
        var prev_char: u32 = 0;
        for (tokens) |token| {
            if (token.end_pos > doc.text.len or token.pos < offset) continue;
            const semantic = semanticType(token.kind) orelse continue;
            while (offset < token.pos) : (offset += 1) {
                if (doc.text[offset] == '\n') {
                    line += 1;
                    line_start = offset + 1;
                }
            }
            const char = position.units(doc.text[line_start..token.pos], self.encoding);
            try data.appendSlice(arena, &.{
                line - prev_line,
                if (line == prev_line) char - prev_char else char,
                position.units(doc.text[token.pos..token.end_pos], self.encoding),
                semantic.type,
                semantic.modifiers,
            });
            prev_line = line;
            prev_char = char;
        }

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginObject();
        try jw.objectField("data");
        try jw.beginArray();
        for (data.items) |n| try jw.write(n);
        try jw.endArray();
        try jw.endObject();
        try jw.endObject();
        try self.send(&b);
    }

    fn onDocumentHighlight(self: *Server, id: ?Value, params: Value) !void {
        var info: c.SymbolInfo = undefined;
        const doc = (try self.symbolAt(params, &info)) orelse return self.replyNull(id);

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginArray();
        for (self.rangesOf(info)) |range| {
            try jw.beginObject();
            try jw.objectField("range");
            try writeRange(jw, self.rangeIn(doc, range));
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
        try self.send(&b);
    }

    /// Only a local or a parameter that is declared in the document is renamed. All of its uses are in the
    /// function that declares it. A function or a type can be used by modules that the server does not see
    /// from here, and renaming it in one document would break them.
    fn canRename(info: c.SymbolInfo) bool {
        return info.kind == c.SymbolLocal and info.has_def;
    }

    fn onPrepareRename(self: *Server, id: ?Value, params: Value) !void {
        var info: c.SymbolInfo = undefined;
        const doc = (try self.symbolAt(params, &info)) orelse return self.replyNull(id);
        if (!canRename(info)) return self.replyNull(id);

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        try beginReply(&b.jw, id);
        try b.jw.objectField("result");
        try writeRange(&b.jw, self.rangeIn(doc, .{ .pos = info.pos, .end_pos = info.end_pos }));
        try b.jw.endObject();
        try self.send(&b);
    }

    fn onRename(self: *Server, id: ?Value, params: Value) !void {
        const new_name = getStr(params, "newName") orelse return error.InvalidParams;
        var info: c.SymbolInfo = undefined;
        const doc = (try self.symbolAt(params, &info)) orelse {
            return self.replyError(id, ErrorCode.request_failed, "There is nothing to rename here.");
        };
        if (!canRename(info)) {
            return self.replyError(id, ErrorCode.request_failed, "Only a local variable or a parameter can be renamed.");
        }
        if (!isIdentifier(new_name)) {
            return self.replyError(id, ErrorCode.request_failed, "The new name is not an identifier.");
        }

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginObject();
        try jw.objectField("changes");
        try jw.beginObject();
        try jw.objectField(doc.uri);
        try jw.beginArray();
        for (self.rangesOf(info)) |range| {
            try jw.beginObject();
            try jw.objectField("range");
            try writeRange(jw, self.rangeIn(doc, range));
            try jw.objectField("newText");
            try jw.write(new_name);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
        try jw.endObject();
        try jw.endObject();
        try self.send(&b);
    }

    fn groupOf(arena: std.mem.Allocator, groups: *std.ArrayList(Group), uri: []const u8) !*Group {
        for (groups.items) |*group| {
            if (std.mem.eql(u8, group.uri, uri)) return group;
        }
        try groups.append(arena, .{ .uri = uri });
        return &groups.items[groups.items.len - 1];
    }

    /// Whether the source of a report is something a client can open: the checked document, another open
    /// document or a file. The standard modules are embedded in the server and named `core`, `os`, ...
    fn hasDocument(self: *Server, doc: *Document, rep: c.Report) bool {
        const path = c.from_bytes(rep.uri);
        if (path.len == 0 or std.mem.eql(u8, path, doc.path)) return true;
        if (self.docByPath(path) != null) return true;
        return std.Io.Dir.path.isAbsolute(path);
    }

    /// The document that a report belongs to. A report without a source belongs to the checked document.
    fn uriOfReport(self: *Server, arena: std.mem.Allocator, doc: *Document, rep: c.Report) ![]const u8 {
        const path = c.from_bytes(rep.uri);
        if (path.len == 0 or std.mem.eql(u8, path, doc.path)) return doc.uri;
        if (self.docByPath(path)) |other| return other.uri;
        return pathToUri(arena, path);
    }

    fn rangeOfReport(self: *Server, arena: std.mem.Allocator, doc: *Document, rep: c.Report) !Range {
        if (!rep.has_loc) return Range.zero;
        const bytes: Range = .{
            .start = .{ .line = rep.line, .character = rep.col },
            .end = .{ .line = rep.end_line, .character = rep.end_col },
        };
        if (self.encoding == .utf8) return bytes;

        // Columns in UTF-16 units need the text of the lines.
        const path = c.from_bytes(rep.uri);
        var src: []const u8 = undefined;
        if (path.len == 0 or std.mem.eql(u8, path, doc.path)) {
            src = doc.text;
        } else if (self.docByPath(path)) |other| {
            src = other.text;
        } else {
            src = std.Io.Dir.cwd().readFileAlloc(stdx.io(), path, arena, .limited(1 << 26)) catch return bytes;
        }
        if (rep.end_pos > src.len) return bytes;
        return .{
            .start = position.fromOffset(src, rep.pos, .utf16),
            .end = position.fromOffset(src, rep.end_pos, .utf16),
        };
    }

    fn publish(self: *Server, uri: []const u8, version: ?i64, diags: []const Diagnostic) !void {
        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try jw.beginObject();
        try jw.objectField("jsonrpc");
        try jw.write("2.0");
        try jw.objectField("method");
        try jw.write("textDocument/publishDiagnostics");
        try jw.objectField("params");
        try jw.beginObject();
        try jw.objectField("uri");
        try jw.write(uri);
        if (version) |v| {
            try jw.objectField("version");
            try jw.write(v);
        }
        try jw.objectField("diagnostics");
        try jw.beginArray();
        for (diags) |diag| {
            try jw.beginObject();
            try jw.objectField("range");
            try writeRange(jw, diag.range);
            // The compiler only reports errors.
            try jw.objectField("severity");
            try jw.write(1);
            try jw.objectField("source");
            try jw.write("cyber");
            try jw.objectField("message");
            try jw.write(diag.msg);
            if (self.related_information and diag.notes.len > 0) {
                try jw.objectField("relatedInformation");
                try jw.beginArray();
                for (diag.notes) |note| {
                    try jw.beginObject();
                    try jw.objectField("location");
                    try jw.beginObject();
                    try jw.objectField("uri");
                    try jw.write(note.uri);
                    try jw.objectField("range");
                    try writeRange(jw, note.range);
                    try jw.endObject();
                    try jw.objectField("message");
                    try jw.write(note.msg);
                    try jw.endObject();
                }
                try jw.endArray();
            }
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
        try jw.endObject();
        try self.send(&b);
    }

    // -----------------------------------
    // [ Requests ]
    // -----------------------------------

    fn onFormatting(self: *Server, id: ?Value, params: Value) !void {
        const doc = try self.docOf(params);
        var out: c.Bytes = c.NullStr;
        const res = c.c.cl_vm_format(self.vm, c.to_bytes(doc.text), &out);
        defer if (out.ptr != null) c.vm_freeb(self.vm, c.from_bytes(out));
        // A source with a syntax error is left as it is. The diagnostics already say why.
        if (res != c.FormatOk) return self.replyNull(id);
        const text = c.from_bytes(out);

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginArray();
        if (!std.mem.eql(u8, text, doc.text)) {
            // One edit that replaces the whole text. The formatter keeps every token, so a client that wants
            // smaller edits can diff the two.
            try jw.beginObject();
            try jw.objectField("range");
            try writeRange(jw, .{
                .start = .{ .line = 0, .character = 0 },
                .end = position.fromOffset(doc.text, doc.text.len, self.encoding),
            });
            try jw.objectField("newText");
            try jw.write(text);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
        try self.send(&b);
    }

    fn onDocumentSymbol(self: *Server, arena: std.mem.Allocator, id: ?Value, params: Value) !void {
        const doc = try self.docOf(params);
        const syms = (try symbols.documentSymbols(arena, doc.text)) orelse &.{};

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try self.writeSymbols(jw, doc.text, syms);
        try jw.endObject();
        try self.send(&b);
    }

    fn writeSymbols(self: *Server, jw: *std.json.Stringify, src: []const u8, syms: []const symbols.Symbol) !void {
        try jw.beginArray();
        for (syms) |sym| {
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(sym.name);
            if (sym.detail.len > 0) {
                try jw.objectField("detail");
                try jw.write(sym.detail);
            }
            try jw.objectField("kind");
            try jw.write(@intFromEnum(sym.kind));
            try jw.objectField("range");
            try writeRange(jw, .{
                .start = position.fromOffset(src, sym.pos, self.encoding),
                .end = position.fromOffset(src, sym.end, self.encoding),
            });
            try jw.objectField("selectionRange");
            try writeRange(jw, .{
                .start = position.fromOffset(src, sym.name_pos, self.encoding),
                .end = position.fromOffset(src, sym.name_end, self.encoding),
            });
            if (sym.children.len > 0) {
                try jw.objectField("children");
                try self.writeSymbols(jw, src, sym.children);
            }
            try jw.endObject();
        }
        try jw.endArray();
    }

    fn onFoldingRange(self: *Server, arena: std.mem.Allocator, id: ?Value, params: Value) !void {
        const doc = try self.docOf(params);
        const folds = try symbols.foldingRanges(arena, doc.text);

        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("result");
        try jw.beginArray();
        for (folds) |fold| {
            try jw.beginObject();
            try jw.objectField("startLine");
            try jw.write(fold.start_line);
            try jw.objectField("endLine");
            try jw.write(fold.end_line);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
        try self.send(&b);
    }

    // -----------------------------------
    // [ Output ]
    // -----------------------------------

    fn send(self: *Server, b: *Builder) !void {
        const body = try b.aw.toOwnedSlice();
        errdefer self.alloc.free(body);
        try self.out.append(self.alloc, body);
    }

    fn replyNull(self: *Server, id: ?Value) !void {
        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        try beginReply(&b.jw, id);
        try b.jw.objectField("result");
        try b.jw.write(null);
        try b.jw.endObject();
        try self.send(&b);
    }

    fn replyError(self: *Server, id: ?Value, code: i32, msg: []const u8) !void {
        var b: Builder = undefined;
        b.init(self.alloc);
        defer b.deinit();
        const jw = &b.jw;
        try beginReply(jw, id);
        try jw.objectField("error");
        try jw.beginObject();
        try jw.objectField("code");
        try jw.write(code);
        try jw.objectField("message");
        try jw.write(msg);
        try jw.endObject();
        try jw.endObject();
        try self.send(&b);
    }
};

const Builder = struct {
    aw: std.Io.Writer.Allocating,
    jw: std.json.Stringify,

    /// `self` must not move after this: the JSON writer points at the buffer.
    fn init(self: *Builder, alloc: std.mem.Allocator) void {
        self.aw = .init(alloc);
        self.jw = .{ .writer = &self.aw.writer, .options = .{} };
    }

    fn deinit(self: *Builder) void {
        self.aw.deinit();
    }
};

/// A copy of `bytes` that is valid UTF-8, which a JSON string has to be. A message can quote bytes of the source.
fn validText(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, bytes);
    if (std.unicode.utf8ValidateSlice(out)) return out;
    var i: usize = 0;
    while (i < out.len) {
        const len = std.unicode.utf8ByteSequenceLength(out[i]) catch 0;
        if (len > 0 and i + len <= out.len and std.unicode.utf8ValidateSlice(out[i .. i + len])) {
            i += len;
        } else {
            out[i] = '?';
            i += 1;
        }
    }
    return out;
}

/// Sources that one references request compiles at most. Each takes a few milliseconds.
const max_reference_compiles = 300;

const max_workspace_symbols = 1000;

/// The token types of the legend, by index.
const semantic_types = [_][]const u8{ "namespace", "type", "enumMember", "function", "method", "property", "variable" };

const SemanticType = struct {
    type: u32,
    /// Bit 0 is `readonly`.
    modifiers: u32 = 0,
};

fn semanticType(kind: u32) ?SemanticType {
    return switch (kind) {
        c.ItemModule => .{ .type = 0 },
        c.ItemType => .{ .type = 1 },
        c.ItemCase => .{ .type = 2 },
        c.ItemFunction => .{ .type = 3 },
        c.ItemMethod => .{ .type = 4 },
        c.ItemField => .{ .type = 5 },
        c.ItemLocal, c.ItemGlobal => .{ .type = 6 },
        c.ItemConstant => .{ .type = 6, .modifiers = 1 },
        else => null,
    };
}

/// The notifications that the server acts on. Every other method is a request and needs an id.
fn isNotification(method: []const u8) bool {
    const known = [_][]const u8{
        "exit",
        "initialized",
        "textDocument/didOpen",
        "textDocument/didChange",
        "textDocument/didSave",
        "textDocument/didClose",
    };
    for (known) |name_| {
        if (std.mem.eql(u8, method, name_)) return true;
    }
    return false;
}

/// The tokenizer takes ASCII letters, digits and `_` in a name.
fn isIdentifier(text: []const u8) bool {
    if (text.len == 0 or std.ascii.isDigit(text[0])) return false;
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

/// Opens the object of a reply. The caller writes `result` or `error` and closes it.
fn beginReply(jw: *std.json.Stringify, id: ?Value) !void {
    try jw.beginObject();
    try jw.objectField("jsonrpc");
    try jw.write("2.0");
    try jw.objectField("id");
    if (id) |v| try jw.write(v) else try jw.write(null);
}

fn writeRange(jw: *std.json.Stringify, range: Range) !void {
    try jw.beginObject();
    try jw.objectField("start");
    try writePosition(jw, range.start);
    try jw.objectField("end");
    try writePosition(jw, range.end);
    try jw.endObject();
}

fn writePosition(jw: *std.json.Stringify, pos: position.Position) !void {
    try jw.beginObject();
    try jw.objectField("line");
    try jw.write(pos.line);
    try jw.objectField("character");
    try jw.write(pos.character);
    try jw.endObject();
}

pub fn getPath(root: Value, path: []const []const u8) ?Value {
    var cur = root;
    for (path) |key| {
        if (cur != .object) return null;
        cur = cur.object.get(key) orelse return null;
    }
    return cur;
}

fn getStr(obj: Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getInt(obj: Value, key: []const u8) ?i64 {
    if (obj != .object) return null;
    const v = obj.object.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

// -----------------------------------
// [ VM callbacks ]
// -----------------------------------

fn dropPrint(_: ?*c.Thread, _: c.Bytes) callconv(.c) void {}

fn dropLog(_: ?*c.VM, _: c.Bytes) callconv(.c) void {}

/// An open document resolves to itself, so that a document that was never saved can be checked.
/// Everything else resolves like in the CLI.
fn resolver(vm: ?*c.VM, params: c.ResolverParams, res_uri_len: ?*usize) callconv(.c) bool {
    const self = active.?;
    const spec = c.from_bytes(params.uri);
    // The path of a document is absolute or has a scheme (`documentPath`), so it is never the name of a
    // standard module.
    if (self.docByPath(spec) != null and spec.len <= params.bufLen) {
        @memcpy(params.buf[0..spec.len], spec);
        res_uri_len.?.* = spec.len;
        return true;
    }
    return self.cli_resolver.?(vm, params, res_uri_len);
}

/// A module that is open in the editor is read from the editor, not from the disk.
fn loader(vm: ?*c.VM, mod: ?*c.Sym, spec: c.Bytes, res: [*c]c.LoaderResult) callconv(.c) bool {
    const self = active.?;
    if (self.docByPath(c.from_bytes(spec))) |doc| {
        res[0] = .{ .src = c.to_bytes(doc.text), .manage_src = false };
        return true;
    }
    return cli.loader(vm, mod, spec, res);
}

// -----------------------------------
// [ URIs ]
// -----------------------------------

/// The name of a document for the compiler. A file is known by its canonical path, the way the compiler names
/// a module that it resolves: a document reached through a symbolic link is then the same source as the file
/// it links to. A file that does not exist yet keeps its path, with the directory made canonical if there is
/// one. A uri that is not a file keeps its scheme, and a bare name gets one, so that no document is taken for
/// a standard module (`core`).
pub fn documentPath(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    const path = try uriToPath(alloc, uri);
    errdefer alloc.free(path);
    if (!std.Io.Dir.path.isAbsolute(path)) {
        if (std.mem.findScalar(u8, path, ':') != null) return path;
        const named = try std.fmt.allocPrint(alloc, "untitled:{s}", .{path});
        alloc.free(path);
        return named;
    }
    const io = stdx.io();
    const cwd = std.Io.Dir.cwd();
    if (cwd.realPathFileAlloc(io, path, alloc)) |real| {
        defer alloc.free(real);
        const copy = try alloc.dupe(u8, real);
        alloc.free(path);
        return copy;
    } else |_| {}
    const dir = std.Io.Dir.path.dirname(path) orelse return path;
    if (cwd.realPathFileAlloc(io, dir, alloc)) |real_dir| {
        defer alloc.free(real_dir);
        const joined = try std.Io.Dir.path.join(alloc, &.{ real_dir, std.Io.Dir.path.basename(path) });
        alloc.free(path);
        return joined;
    } else |_| {}
    return path;
}

/// The file path of a `file:` uri. Any other uri is its own name.
pub fn uriToPath(alloc: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return alloc.dupe(u8, uri);
    var rest = uri[prefix.len..];
    // Skip the authority (`file://localhost/...`).
    if (std.mem.findScalar(u8, rest, '/')) |slash| rest = rest[slash..];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |byte| {
                try out.append(alloc, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(alloc, rest[i]);
    }
    // `/C:/dir/file.cy` is `C:/dir/file.cy`.
    if (out.items.len >= 3 and out.items[0] == '/' and std.ascii.isAlphabetic(out.items[1]) and out.items[2] == ':') {
        _ = out.orderedRemove(0);
    }
    if (builtin.os.tag == .windows) {
        // The compiler names a module by its canonical path, which has backslashes.
        std.mem.replaceScalar(u8, out.items, '/', '\\');
    }
    return out.toOwnedSlice(alloc);
}

pub fn pathToUri(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    // A name that is already a uri (`untitled:Untitled-1`, `https://...`) stays.
    if (std.mem.find(u8, path, "://") != null) return alloc.dupe(u8, path);
    if (!std.Io.Dir.path.isAbsolute(path)) return alloc.dupe(u8, path);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    if (path.len > 0 and path[0] != '/') try out.append(alloc, '/');
    for (path) |ch| {
        const keep = std.ascii.isAlphanumeric(ch) or switch (ch) {
            '-', '.', '_', '~', '/' => true,
            else => false,
        };
        if (keep) {
            try out.append(alloc, ch);
        } else if (ch == '\\') {
            try out.append(alloc, '/');
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(alloc, &.{ '%', hex[ch >> 4], hex[ch & 15] });
        }
    }
    return out.toOwnedSlice(alloc);
}

test "File uris and paths convert both ways." {
    const t = std.testing;
    if (builtin.os.tag != .windows) {
        const path = try uriToPath(t.allocator, "file:///home/me/a%20b/%ED%95%9C.cy");
        defer t.allocator.free(path);
        try t.expectEqualStrings("/home/me/a b/한.cy", path);
        const uri = try pathToUri(t.allocator, path);
        defer t.allocator.free(uri);
        try t.expectEqualStrings("file:///home/me/a%20b/%ED%95%9C.cy", uri);
    }

    const win = try uriToPath(t.allocator, "file:///C:/dir/x.cy");
    defer t.allocator.free(win);
    try t.expectEqualStrings(if (builtin.os.tag == .windows) "C:\\dir\\x.cy" else "C:/dir/x.cy", win);

    const other = try uriToPath(t.allocator, "untitled:Untitled-1");
    defer t.allocator.free(other);
    try t.expectEqualStrings("untitled:Untitled-1", other);
    const back = try pathToUri(t.allocator, "untitled:Untitled-1");
    defer t.allocator.free(back);
    try t.expectEqualStrings("untitled:Untitled-1", back);
}
