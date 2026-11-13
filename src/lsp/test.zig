//! Sessions with the server, message by message.

const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const cli = @import("../cli.zig");
const lsp = @import("server.zig");

const Value = std.json.Value;

const Session = struct {
    server: lsp.Server,
    arena: std.heap.ArenaAllocator,

    /// `self` must not move after this.
    fn init(self: *Session) !void {
        self.arena = .init(t.allocator);
        try self.server.init(cli.getAllocator());
    }

    fn deinit(self: *Session) void {
        self.server.deinit();
        self.arena.deinit();
    }

    /// Sends one message and returns what the server queued, parsed. The values live as long as the session.
    fn send(self: *Session, body: []const u8) ![]Value {
        try self.server.handle(body);
        return self.take();
    }

    /// Lets the server check the changed documents, like after a pause of the client.
    fn flush(self: *Session) ![]Value {
        try self.server.flush();
        return self.take();
    }

    fn take(self: *Session) ![]Value {
        const arena = self.arena.allocator();
        const out = try arena.alloc(Value, self.server.out.items.len);
        for (self.server.out.items, 0..) |body, i| {
            defer self.server.alloc.free(body);
            out[i] = try std.json.parseFromSliceLeaky(Value, arena, try arena.dupe(u8, body), .{});
        }
        self.server.out.clearRetainingCapacity();
        return out;
    }

    fn initialize(self: *Session, encodings: []const u8) !void {
        const body = try std.fmt.allocPrint(self.arena.allocator(),
            \\{{"jsonrpc":"2.0","id":0,"method":"initialize","params":{{"capabilities":{{
            \\"general":{{"positionEncodings":{s}}},
            \\"textDocument":{{"publishDiagnostics":{{"relatedInformation":true}}}}}}}}}}
        , .{encodings});
        _ = try self.send(body);
        _ = try self.send(
            \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        );
    }

    fn open(self: *Session, uri: []const u8, version: i64, text: []const u8) !void {
        try self.textMessage("textDocument/didOpen", uri, version, text, false);
    }

    fn change(self: *Session, uri: []const u8, version: i64, text: []const u8) !void {
        try self.textMessage("textDocument/didChange", uri, version, text, true);
    }

    /// Opens a document whose path another open document already has. The server answers at once: the
    /// diagnostics of the document that it replaces are cleared.
    fn openReplacing(self: *Session, uri: []const u8, version: i64, text: []const u8) ![]Value {
        const arena = self.arena.allocator();
        const body = try std.fmt.allocPrint(arena,
            \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"cyber",
            \\"version":{},"text":{s}}}}}}}
        , .{ uri, version, try std.json.Stringify.valueAlloc(arena, text, .{}) });
        return self.send(body);
    }

    fn textMessage(self: *Session, method: []const u8, uri: []const u8, version: i64, text: []const u8, change_: bool) !void {
        const arena = self.arena.allocator();
        const quoted = try std.json.Stringify.valueAlloc(arena, text, .{});
        const body = if (change_)
            try std.fmt.allocPrint(arena,
                \\{{"jsonrpc":"2.0","method":"{s}","params":{{"textDocument":{{"uri":"{s}","version":{}}},
                \\"contentChanges":[{{"text":{s}}}]}}}}
            , .{ method, uri, version, quoted })
        else
            try std.fmt.allocPrint(arena,
                \\{{"jsonrpc":"2.0","method":"{s}","params":{{"textDocument":{{"uri":"{s}","languageId":"cyber",
                \\"version":{},"text":{s}}}}}}}
            , .{ method, uri, version, quoted });
        const out = try self.send(body);
        // A change is only recorded. The check waits for `flush`.
        try t.expectEqual(@as(usize, 0), out.len);
        try t.expect(self.server.hasPending());
    }

    fn requestAt(self: *Session, method: []const u8, uri: []const u8, line: u32, character: u32) !Value {
        const body = try std.fmt.allocPrint(self.arena.allocator(),
            \\{{"jsonrpc":"2.0","id":8,"method":"{s}","params":{{"textDocument":{{"uri":"{s}"}},
            \\"position":{{"line":{},"character":{}}}}}}}
        , .{ method, uri, line, character });
        const out = try self.send(body);
        try t.expectEqual(@as(usize, 1), out.len);
        try t.expectEqual(@as(i64, 8), get(out[0], &.{"id"}).?.integer);
        return out[0];
    }

    /// A request at a position with more members of `params`, given as JSON that starts with a comma.
    fn requestWith(self: *Session, method: []const u8, uri: []const u8, line: u32, character: u32, more: []const u8) !Value {
        const body = try std.fmt.allocPrint(self.arena.allocator(),
            \\{{"jsonrpc":"2.0","id":9,"method":"{s}","params":{{"textDocument":{{"uri":"{s}"}},
            \\"position":{{"line":{},"character":{}}}{s}}}}}
        , .{ method, uri, line, character, more });
        const out = try self.send(body);
        try t.expectEqual(@as(usize, 1), out.len);
        return out[0];
    }

    fn request(self: *Session, method: []const u8, uri: []const u8) !Value {
        const body = try std.fmt.allocPrint(self.arena.allocator(),
            \\{{"jsonrpc":"2.0","id":7,"method":"{s}","params":{{"textDocument":{{"uri":"{s}"}}}}}}
        , .{ method, uri });
        const out = try self.send(body);
        try t.expectEqual(@as(usize, 1), out.len);
        try t.expectEqual(@as(i64, 7), get(out[0], &.{"id"}).?.integer);
        return out[0];
    }
};

fn get(v: Value, path: []const []const u8) ?Value {
    return lsp.getPath(v, path);
}

fn str(v: Value, path: []const []const u8) []const u8 {
    return get(v, path).?.string;
}

fn int(v: Value, path: []const []const u8) i64 {
    return get(v, path).?.integer;
}

fn items(v: Value, path: []const []const u8) []Value {
    return get(v, path).?.array.items;
}

fn expectRange(v: Value, start_line: i64, start_char: i64, end_line: i64, end_char: i64) !void {
    try t.expectEqual(start_line, int(v, &.{ "start", "line" }));
    try t.expectEqual(start_char, int(v, &.{ "start", "character" }));
    try t.expectEqual(end_line, int(v, &.{ "end", "line" }));
    try t.expectEqual(end_char, int(v, &.{ "end", "character" }));
}

const main_uri = "file:///cyber-lsp-test/main.cy";

test "The server follows the lifecycle of the protocol." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();

    // What is not JSON gets an error without an id.
    var out = try s.send("{nope");
    try t.expectEqual(@as(usize, 1), out.len);
    try t.expectEqual(@as(i64, -32700), int(out[0], &.{ "error", "code" }));
    try t.expect(get(out[0], &.{"id"}).? == .null);

    // Before `initialize` a request is refused and a notification is dropped.
    out = try s.send(
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"x"}}}
    );
    try t.expectEqual(@as(i64, -32002), int(out[0], &.{ "error", "code" }));
    out = try s.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"x","version":1,"text":""}}}
    );
    try t.expectEqual(@as(usize, 0), out.len);
    try t.expect(!s.server.hasPending());

    // Positions are UTF-16 code units unless the client offers `utf-8`.
    out = try s.send(
        \\{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"capabilities":{}}}
    );
    try t.expectEqualStrings("a", str(out[0], &.{"id"}));
    try t.expectEqualStrings("utf-16", str(out[0], &.{ "result", "capabilities", "positionEncoding" }));
    try t.expectEqual(@as(i64, 1), int(out[0], &.{ "result", "capabilities", "textDocumentSync", "change" }));
    try t.expect(get(out[0], &.{ "result", "capabilities", "documentFormattingProvider" }).?.bool);
    try t.expect(get(out[0], &.{ "result", "capabilities", "documentSymbolProvider" }).?.bool);
    try t.expect(get(out[0], &.{ "result", "capabilities", "foldingRangeProvider" }).?.bool);
    try t.expect(get(out[0], &.{ "result", "capabilities", "hoverProvider" }).?.bool);
    try t.expect(get(out[0], &.{ "result", "capabilities", "definitionProvider" }).?.bool);
    try t.expect(get(out[0], &.{ "result", "capabilities", "referencesProvider" }).?.bool);
    try t.expect(get(out[0], &.{ "result", "capabilities", "documentHighlightProvider" }).?.bool);
    try t.expect(get(out[0], &.{ "result", "capabilities", "renameProvider", "prepareProvider" }).?.bool);
    try t.expectEqualStrings(".", items(out[0], &.{ "result", "capabilities", "completionProvider", "triggerCharacters" })[0].string);
    try t.expect(get(out[0], &.{ "result", "capabilities", "workspaceSymbolProvider" }).?.bool);
    try t.expect(get(out[0], &.{ "result", "capabilities", "semanticTokensProvider", "full" }).?.bool);
    try t.expectEqualStrings("namespace", items(out[0], &.{ "result", "capabilities", "semanticTokensProvider", "legend", "tokenTypes" })[0].string);
    try t.expectEqual(@as(usize, 2), items(out[0], &.{ "result", "capabilities", "signatureHelpProvider", "triggerCharacters" }).len);
    try t.expectEqualStrings("cyber-lsp", str(out[0], &.{ "result", "serverInfo", "name" }));

    out = try s.send(
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-16","utf-8"]}}}}
    );
    try t.expectEqualStrings("utf-8", str(out[0], &.{ "result", "capabilities", "positionEncoding" }));

    // A request that the server does not know gets an error, a notification is skipped, a reply is ignored.
    out = try s.send(
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/typeDefinition","params":{}}
    );
    try t.expectEqual(@as(i64, -32601), int(out[0], &.{ "error", "code" }));
    out = try s.send(
        \\{"jsonrpc":"2.0","method":"$/setTrace","params":{"value":"off"}}
    );
    try t.expectEqual(@as(usize, 0), out.len);
    out = try s.send(
        \\{"jsonrpc":"2.0","id":9,"result":null}
    );
    try t.expectEqual(@as(usize, 0), out.len);

    // A request for a document that is not open has invalid parameters.
    out = try s.send(
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///none.cy"}}}
    );
    try t.expectEqual(@as(i64, -32602), int(out[0], &.{ "error", "code" }));

    out = try s.send(
        \\{"jsonrpc":"2.0","id":5,"method":"shutdown"}
    );
    try t.expect(get(out[0], &.{"result"}).? == .null);
    out = try s.send(
        \\{"jsonrpc":"2.0","id":6,"method":"textDocument/formatting","params":{"textDocument":{"uri":"x"}}}
    );
    try t.expectEqual(@as(i64, -32600), int(out[0], &.{ "error", "code" }));
    try t.expect(!s.server.exit);
    _ = try s.send(
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    try t.expect(s.server.exit and s.server.shutdown);
}

test "Compile errors are published as diagnostics." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");

    // The document does not have to exist on disk. Columns are UTF-16 code units: `한글` is two of them.
    try s.open(main_uri, 1, "x := '한글' + nope\n");
    var out = try s.flush();
    try t.expect(!s.server.hasPending());
    try t.expectEqual(@as(usize, 1), out.len);
    try t.expectEqualStrings("textDocument/publishDiagnostics", str(out[0], &.{"method"}));
    try t.expectEqualStrings(main_uri, str(out[0], &.{ "params", "uri" }));
    try t.expectEqual(@as(i64, 1), int(out[0], &.{ "params", "version" }));
    var diags = items(out[0], &.{ "params", "diagnostics" });
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expectEqualStrings("Undeclared variable `nope`.", str(diags[0], &.{"message"}));
    try t.expectEqualStrings("cyber", str(diags[0], &.{"source"}));
    try t.expectEqual(@as(i64, 1), int(diags[0], &.{"severity"}));
    try expectRange(get(diags[0], &.{"range"}).?, 0, 12, 0, 16);
    try t.expect(get(diags[0], &.{"relatedInformation"}) == null);

    // Nothing changed, nothing to check.
    out = try s.flush();
    try t.expectEqual(@as(usize, 0), out.len);

    // A context note is related information. The range of the error covers the declaration.
    try s.change(main_uri, 2, "type A:\n  a int\n\ntype A:\n  b int\n");
    out = try s.flush();
    diags = items(out[0], &.{ "params", "diagnostics" });
    try t.expectEqual(@as(usize, 1), diags.len);
    try expectRange(get(diags[0], &.{"range"}).?, 3, 0, 4, 7);
    var related = items(diags[0], &.{"relatedInformation"});
    try t.expectEqual(@as(usize, 1), related.len);
    try t.expectEqualStrings("First declared at:", str(related[0], &.{"message"}));
    try t.expectEqualStrings(main_uri, str(related[0], &.{ "location", "uri" }));
    try expectRange(get(related[0], &.{ "location", "range" }).?, 0, 0, 1, 7);

    // The call that expanded a template has no message of its own.
    try s.change(main_uri, 3, "type Foo[T Any]:\n  a T.nope\n\nfn main():\n  f := Foo[int]{a = 1}\n");
    out = try s.flush();
    diags = items(out[0], &.{ "params", "diagnostics" });
    try expectRange(get(diags[0], &.{"range"}).?, 1, 6, 1, 10);
    related = items(diags[0], &.{"relatedInformation"});
    try t.expectEqualStrings("Template expanded here.", str(related[0], &.{"message"}));
    try expectRange(get(related[0], &.{ "location", "range" }).?, 4, 7, 4, 15);

    // A syntax error, and then a source without errors: the diagnostics are replaced by an empty list.
    try s.change(main_uri, 4, "a := 1\nb := a +\n");
    out = try s.flush();
    diags = items(out[0], &.{ "params", "diagnostics" });
    try t.expectEqualStrings("Expected right operand.", str(diags[0], &.{"message"}));
    try expectRange(get(diags[0], &.{"range"}).?, 2, 0, 2, 0);

    try s.change(main_uri, 5, "use os\na := 1\nprint(a)\n");
    out = try s.flush();
    try t.expectEqual(@as(usize, 1), out.len);
    try t.expectEqual(@as(i64, 5), int(out[0], &.{ "params", "version" }));
    try t.expectEqual(@as(usize, 0), items(out[0], &.{ "params", "diagnostics" }).len);

    // Several changes before the pause are one check, of the last text.
    try s.change(main_uri, 6, "print(a)\n");
    try s.change(main_uri, 7, "print(b)\n");
    out = try s.flush();
    try t.expectEqual(@as(usize, 1), out.len);
    try t.expectEqual(@as(i64, 7), int(out[0], &.{ "params", "version" }));
    try t.expectEqualStrings("Undeclared variable `b`.", str(items(out[0], &.{ "params", "diagnostics" })[0], &.{"message"}));

    // Closing the document takes its diagnostics away.
    out = try s.send("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didClose\",\"params\":{\"textDocument\":{\"uri\":\"" ++ main_uri ++ "\"}}}");
    try t.expectEqual(@as(usize, 1), out.len);
    try t.expectEqualStrings(main_uri, str(out[0], &.{ "params", "uri" }));
    try t.expect(get(out[0], &.{ "params", "version" }) == null);
    try t.expectEqual(@as(usize, 0), items(out[0], &.{ "params", "diagnostics" }).len);
    try t.expect(!s.server.hasPending());
}

test "A document that the compiler used to abort on is a diagnostic." {
    // F-112: this document ended the server process.
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");

    try s.open(main_uri, 1, "#print('hello')\nprint(1)\n");
    var out = try s.flush();
    const diags = items(out[0], &.{ "params", "diagnostics" });
    try t.expectEqual(@as(usize, 1), diags.len);
    // The error is inside `core`, which has no document. The diagnostic is at the call in the document.
    try t.expectEqualStrings("In `core`: `type.info` does not support the type `EvalStr`.", str(diags[0], &.{"message"}));
    try expectRange(get(diags[0], &.{"range"}).?, 0, 1, 0, 15);
    for (items(diags[0], &.{"relatedInformation"})) |info| {
        try t.expectEqualStrings(main_uri, str(info, &.{ "location", "uri" }));
    }
    try t.expectEqual(@as(usize, 1), out.len);

    // The server goes on.
    try s.change(main_uri, 2, "print(1)\n");
    out = try s.flush();
    try t.expectEqual(@as(usize, 0), items(out[0], &.{ "params", "diagnostics" }).len);
}

test "Every body with an error gets a diagnostic." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");

    try s.open(main_uri, 1,
        \\fn a() -> int:
        \\    return nope1
        \\
        \\fn b() -> int:
        \\    return nope2
        \\
        \\print(a() + nope3)
        \\
    );
    var out = try s.flush();
    try t.expectEqual(@as(usize, 1), out.len);
    const diags = items(out[0], &.{ "params", "diagnostics" });
    try t.expectEqual(@as(usize, 3), diags.len);
    try t.expectEqualStrings("Undeclared variable `nope3`.", str(diags[0], &.{"message"}));
    try expectRange(get(diags[0], &.{"range"}).?, 6, 12, 6, 17);
    try t.expectEqualStrings("Undeclared variable `nope1`.", str(diags[1], &.{"message"}));
    try expectRange(get(diags[1], &.{"range"}).?, 1, 11, 1, 16);
    try t.expectEqualStrings("Undeclared variable `nope2`.", str(diags[2], &.{"message"}));
    try expectRange(get(diags[2], &.{"range"}).?, 4, 11, 4, 16);

    // Fixing one of them leaves the others.
    try s.change(main_uri, 2,
        \\fn a() -> int:
        \\    return 1
        \\
        \\fn b() -> int:
        \\    return nope2
        \\
        \\print(a())
        \\
    );
    out = try s.flush();
    try t.expectEqual(@as(usize, 1), items(out[0], &.{ "params", "diagnostics" }).len);
}

test "Positions are bytes for a client that offers utf-8." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[\"utf-8\",\"utf-16\"]");

    try s.open(main_uri, 1, "x := '한글' + nope\n");
    const out = try s.flush();
    const diags = items(out[0], &.{ "params", "diagnostics" });
    try expectRange(get(diags[0], &.{"range"}).?, 0, 16, 0, 20);
}

test "Formatting returns one edit for the whole document." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");

    const src = "-- 한글\nfn add(a int,b int)->int:\n  return a+b";
    try s.open(main_uri, 1, src);
    var reply = try s.request("textDocument/formatting", main_uri);
    const edits = items(reply, &.{"result"});
    try t.expectEqual(@as(usize, 1), edits.len);
    // The end of the last line, in UTF-16 code units.
    try expectRange(get(edits[0], &.{"range"}).?, 0, 0, 2, 12);
    const formatted = "-- 한글\nfn add(a int, b int) -> int:\n    return a + b\n";
    try t.expectEqualStrings(formatted, str(edits[0], &.{"newText"}));

    // A formatted document has no edits.
    try s.change(main_uri, 2, formatted);
    reply = try s.request("textDocument/formatting", main_uri);
    try t.expectEqual(@as(usize, 0), items(reply, &.{"result"}).len);

    // A document with a syntax error is not touched.
    try s.change(main_uri, 3, "fn add(a int:\n");
    reply = try s.request("textDocument/formatting", main_uri);
    try t.expect(get(reply, &.{"result"}).? == .null);
}

test "The outline and the folding ranges of a document." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");

    try s.open(main_uri, 1,
        \\type Vec2:
        \\    x float
        \\    y float
        \\
        \\fn (&Vec2) sum() -> float:
        \\    return self.x + self.y
        \\
        \\fn add(a int, b int) -> int: -- 한글
        \\    return a + b
        \\
    );
    var reply = try s.request("textDocument/documentSymbol", main_uri);
    const syms = items(reply, &.{"result"});
    try t.expectEqual(@as(usize, 3), syms.len);
    try t.expectEqualStrings("Vec2", str(syms[0], &.{"name"}));
    try t.expectEqual(@as(i64, 23), int(syms[0], &.{"kind"}));
    try expectRange(get(syms[0], &.{"range"}).?, 0, 0, 2, 11);
    try expectRange(get(syms[0], &.{"selectionRange"}).?, 0, 5, 0, 9);
    const fields = items(syms[0], &.{"children"});
    try t.expectEqual(@as(usize, 2), fields.len);
    try t.expectEqualStrings("y", str(fields[1], &.{"name"}));
    try t.expectEqual(@as(i64, 8), int(fields[1], &.{"kind"}));
    try t.expectEqualStrings("Vec2.sum", str(syms[1], &.{"name"}));
    try t.expectEqual(@as(i64, 6), int(syms[1], &.{"kind"}));
    try t.expectEqualStrings("add", str(syms[2], &.{"name"}));
    try t.expectEqual(@as(i64, 12), int(syms[2], &.{"kind"}));
    try expectRange(get(syms[2], &.{"range"}).?, 7, 0, 8, 16);
    try expectRange(get(syms[2], &.{"selectionRange"}).?, 7, 3, 7, 6);

    reply = try s.request("textDocument/foldingRange", main_uri);
    const folds = items(reply, &.{"result"});
    try t.expectEqual(@as(usize, 3), folds.len);
    try t.expectEqual(@as(i64, 0), int(folds[0], &.{"startLine"}));
    try t.expectEqual(@as(i64, 2), int(folds[0], &.{"endLine"}));
    try t.expectEqual(@as(i64, 7), int(folds[2], &.{"startLine"}));
    try t.expectEqual(@as(i64, 8), int(folds[2], &.{"endLine"}));

    // A document that does not parse has no outline. Folding does not need the parser.
    try s.change(main_uri, 2, "fn add(a int:\n    return a\n");
    reply = try s.request("textDocument/documentSymbol", main_uri);
    try t.expectEqual(@as(usize, 0), items(reply, &.{"result"}).len);
    reply = try s.request("textDocument/foldingRange", main_uri);
    try t.expectEqual(@as(usize, 1), items(reply, &.{"result"}).len);
}

test "Hover describes a name and go to definition finds its declaration." {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.cy", .data = "-- 한글\nfn twice(a int) -> int:\n    return a * 2\n" });
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);

    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");
    const arena = s.arena.allocator();
    const sep = std.Io.Dir.path.sep_str;
    const a_uri = try lsp.pathToUri(arena, try std.fmt.allocPrint(arena, "{s}" ++ sep ++ "a.cy", .{dir}));
    const b_uri = try lsp.pathToUri(arena, try std.fmt.allocPrint(arena, "{s}" ++ sep ++ "b.cy", .{dir}));

    try s.open(a_uri, 1,
        \\use b './b.cy'
        \\
        \\fn add(a int, b_ int) -> int:
        \\    return a + b_
        \\
        \\n := add(1, 2)
        \\print('한글' + str(add(n, 2)))
        \\print(b.twice(n))
        \\print(n + nope)
        \\
    );
    // The request comes before the pause in which the document is checked: the server compiles for it.
    var reply = try s.requestAt("textDocument/hover", a_uri, 5, 0);
    try t.expectEqualStrings("markdown", str(reply, &.{ "result", "contents", "kind" }));
    try t.expectEqualStrings("```cyber\nn int\n```", str(reply, &.{ "result", "contents", "value" }));
    try expectRange(get(reply, &.{ "result", "range" }).?, 5, 0, 5, 1);

    // Columns are UTF-16 code units: the two Korean characters before `add` are two of them.
    reply = try s.requestAt("textDocument/hover", a_uri, 6, 18);
    try t.expectEqualStrings("```cyber\nfn add(a int, b_ int) -> int\n```", str(reply, &.{ "result", "contents", "value" }));
    try expectRange(get(reply, &.{ "result", "range" }).?, 6, 17, 6, 20);

    // A function of this document, a local, and a function of a module on disk.
    reply = try s.requestAt("textDocument/definition", a_uri, 6, 18);
    try t.expectEqualStrings(a_uri, str(reply, &.{ "result", "uri" }));
    try expectRange(get(reply, &.{ "result", "range" }).?, 2, 0, 3, 17);

    reply = try s.requestAt("textDocument/definition", a_uri, 7, 14);
    try t.expectEqualStrings(a_uri, str(reply, &.{ "result", "uri" }));
    try expectRange(get(reply, &.{ "result", "range" }).?, 5, 0, 5, 1);

    reply = try s.requestAt("textDocument/hover", a_uri, 7, 9);
    try t.expectEqualStrings("```cyber\nfn twice(a int) -> int\n```", str(reply, &.{ "result", "contents", "value" }));
    reply = try s.requestAt("textDocument/definition", a_uri, 7, 9);
    try t.expectEqualStrings(b_uri, str(reply, &.{ "result", "uri" }));
    try expectRange(get(reply, &.{ "result", "range" }).?, 1, 0, 2, 16);

    // A function of a standard module is described, but there is no document to go to.
    reply = try s.requestAt("textDocument/hover", a_uri, 7, 1);
    try t.expectEqualStrings("```cyber\nfn print(x %T)\n```", str(reply, &.{ "result", "contents", "value" }));
    reply = try s.requestAt("textDocument/definition", a_uri, 7, 1);
    try t.expect(get(reply, &.{"result"}).? == .null);

    // Nothing at a keyword, and nothing at the name that does not resolve. The rest of the line still answers.
    reply = try s.requestAt("textDocument/hover", a_uri, 2, 0);
    try t.expect(get(reply, &.{"result"}).? == .null);
    reply = try s.requestAt("textDocument/hover", a_uri, 8, 11);
    try t.expect(get(reply, &.{"result"}).? == .null);
    reply = try s.requestAt("textDocument/hover", a_uri, 8, 6);
    try t.expectEqualStrings("```cyber\nn int\n```", str(reply, &.{ "result", "contents", "value" }));

    // The diagnostics are still published after the pause, and a request after a change sees the new text.
    var out = try s.flush();
    try t.expectEqualStrings("Undeclared variable `nope`.", str(items(out[0], &.{ "params", "diagnostics" })[0], &.{"message"}));
    try s.change(a_uri, 2, "x := 1.5\nprint(x)\n");
    reply = try s.requestAt("textDocument/hover", a_uri, 1, 6);
    try t.expectEqualStrings("```cyber\nx float\n```", str(reply, &.{ "result", "contents", "value" }));
    out = try s.flush();
    try t.expectEqual(@as(usize, 0), items(out[0], &.{ "params", "diagnostics" }).len);

    // A position is required.
    const bad = try s.request("textDocument/hover", a_uri);
    try t.expectEqual(@as(i64, -32602), int(bad, &.{ "error", "code" }));
}

test "References, highlights and the rename of a local." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");

    try s.open(main_uri, 1,
        \\fn add(a int, b int) -> int:
        \\    total := a + b
        \\    return total + a
        \\
        \\print('한글' + str(add(1, 2)))
        \\print(add(3, 4))
        \\
    );

    // The calls and the name in the declaration, asked at a call.
    var reply = try s.requestWith("textDocument/references", main_uri, 5, 7, ",\"context\":{\"includeDeclaration\":true}");
    var locs = items(reply, &.{"result"});
    try t.expectEqual(@as(usize, 3), locs.len);
    try t.expectEqualStrings(main_uri, str(locs[0], &.{"uri"}));
    try expectRange(get(locs[0], &.{"range"}).?, 0, 3, 0, 6);
    // After two Korean characters: UTF-16 code units.
    try expectRange(get(locs[1], &.{"range"}).?, 4, 17, 4, 20);
    try expectRange(get(locs[2], &.{"range"}).?, 5, 6, 5, 9);

    // Without the declaration.
    reply = try s.requestWith("textDocument/references", main_uri, 5, 7, ",\"context\":{\"includeDeclaration\":false}");
    locs = items(reply, &.{"result"});
    try t.expectEqual(@as(usize, 2), locs.len);
    try expectRange(get(locs[0], &.{"range"}).?, 4, 17, 4, 20);

    // The highlights of a parameter: the declaration and two uses.
    reply = try s.requestAt("textDocument/documentHighlight", main_uri, 1, 13);
    locs = items(reply, &.{"result"});
    try t.expectEqual(@as(usize, 3), locs.len);
    try expectRange(get(locs[0], &.{"range"}).?, 0, 7, 0, 8);
    try expectRange(get(locs[1], &.{"range"}).?, 1, 13, 1, 14);
    try expectRange(get(locs[2], &.{"range"}).?, 2, 19, 2, 20);
    // A literal has no highlights.
    reply = try s.requestAt("textDocument/documentHighlight", main_uri, 5, 10);
    try t.expectEqual(@as(usize, 0), items(reply, &.{"result"}).len);

    // A local can be renamed. The edits are all in this document.
    reply = try s.requestAt("textDocument/prepareRename", main_uri, 2, 12);
    try expectRange(get(reply, &.{"result"}).?, 2, 11, 2, 16);
    reply = try s.requestWith("textDocument/rename", main_uri, 2, 12, ",\"newName\":\"sum_\"");
    const edits = items(reply, &.{ "result", "changes", main_uri });
    try t.expectEqual(@as(usize, 2), edits.len);
    try expectRange(get(edits[0], &.{"range"}).?, 1, 4, 1, 9);
    try expectRange(get(edits[1], &.{"range"}).?, 2, 11, 2, 16);
    try t.expectEqualStrings("sum_", str(edits[1], &.{"newText"}));

    // A function is not renamed: a module that uses it is not seen from here.
    reply = try s.requestAt("textDocument/prepareRename", main_uri, 5, 7);
    try t.expect(get(reply, &.{"result"}).? == .null);
    reply = try s.requestWith("textDocument/rename", main_uri, 5, 7, ",\"newName\":\"plus\"");
    try t.expectEqual(@as(i64, -32803), int(reply, &.{ "error", "code" }));
    try t.expectEqualStrings("Only a local variable or a parameter can be renamed.", str(reply, &.{ "error", "message" }));

    // A new name has to be an identifier, and there has to be something to rename.
    reply = try s.requestWith("textDocument/rename", main_uri, 2, 12, ",\"newName\":\"my total\"");
    try t.expectEqualStrings("The new name is not an identifier.", str(reply, &.{ "error", "message" }));
    reply = try s.requestWith("textDocument/rename", main_uri, 3, 0, ",\"newName\":\"x\"");
    try t.expectEqualStrings("There is nothing to rename here.", str(reply, &.{ "error", "message" }));
    reply = try s.requestAt("textDocument/rename", main_uri, 2, 12);
    try t.expectEqual(@as(i64, -32602), int(reply, &.{ "error", "code" }));
}

fn findItem(list: []Value, label: []const u8) ?Value {
    for (list) |item| {
        if (std.mem.eql(u8, str(item, &.{"label"}), label)) return item;
    }
    return null;
}

test "Completion lists members and names for source that is being typed." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");

    const head =
        \\use math
        \\
        \\type Vec2:
        \\    x float
        \\    y float
        \\
        \\fn (&Vec2) scale(by float) -> Vec2:
        \\    return Vec2{x = self.x * by, y = self.y * by}
        \\
        \\fn add(first int, second int) -> int:
        \\    total := first + second
        \\    return total
        \\
        \\v := Vec2{x = 1.0, y = 2.0}
        \\
    ;
    const S = struct {
        /// Opens `head` plus `last` as the document and asks for completions at the end of `last`.
        fn complete(session: *Session, version: i64, comptime last: []const u8) ![]Value {
            try session.change(main_uri, version, head ++ last);
            const line: u32 = @intCast(std.mem.count(u8, head ++ last, "\n"));
            const col: u32 = @intCast(last.len - (if (std.mem.findScalarLast(u8, last, '\n')) |nl| nl + 1 else 0));
            const reply = try session.requestAt("textDocument/completion", main_uri, line, col);
            try t.expect(!get(reply, &.{ "result", "isIncomplete" }).?.bool);
            return items(reply, &.{ "result", "items" });
        }
    };
    try s.open(main_uri, 1, head);

    // The members of a value, while the line ends in the `.`: the document does not parse as it is.
    var list = try S.complete(&s, 2, "w := v.");
    try t.expectEqualStrings("x float", str(findItem(list, "x").?, &.{"detail"}));
    try t.expectEqual(@as(i64, 5), int(findItem(list, "x").?, &.{"kind"}));
    try t.expectEqualStrings("fn (&Vec2) scale(by float) -> Vec2", str(findItem(list, "scale").?, &.{"detail"}));
    try t.expectEqual(@as(i64, 2), int(findItem(list, "scale").?, &.{"kind"}));
    try t.expect(findItem(list, "add") == null);

    // With a part of the member typed, the whole list is still sent: the client filters.
    list = try S.complete(&s, 3, "w := v.sc");
    try t.expect(findItem(list, "scale") != null);
    try t.expect(findItem(list, "x") != null);

    // Inside a call that is not closed, and after a call.
    list = try S.complete(&s, 4, "print(add(1, 2) + v.");
    try t.expect(findItem(list, "y") != null);
    list = try S.complete(&s, 5, "w := v.scale(2.0).");
    try t.expect(findItem(list, "scale") != null);

    // In the header of a block, which never parses without its body.
    list = try S.complete(&s, 6, "if v.");
    try t.expect(findItem(list, "x") != null);

    // A module and a type.
    list = try S.complete(&s, 7, "w := math.");
    try t.expectEqualStrings("fn sqrt(a float) -> float", str(findItem(list, "sqrt").?, &.{"detail"}));
    try t.expectEqual(@as(i64, 3), int(findItem(list, "sqrt").?, &.{"kind"}));
    try t.expect(findItem(list, "x") == null);

    // The names in scope: locals of the main block, declarations, the module and builtins.
    list = try S.complete(&s, 8, "w := ");
    try t.expectEqualStrings("v Vec2", str(findItem(list, "v").?, &.{"detail"}));
    try t.expectEqual(@as(i64, 6), int(findItem(list, "v").?, &.{"kind"}));
    try t.expectEqualStrings("fn add(first int, second int) -> int", str(findItem(list, "add").?, &.{"detail"}));
    try t.expectEqual(@as(i64, 22), int(findItem(list, "Vec2").?, &.{"kind"}));
    try t.expectEqual(@as(i64, 9), int(findItem(list, "math").?, &.{"kind"}));
    try t.expect(findItem(list, "print") != null);
    try t.expect(findItem(list, "total") == null);
    try t.expect(findItem(list, "cy_lsp_placeholder_") == null);
    list = try S.complete(&s, 9, "print(ad");
    try t.expect(findItem(list, "add") != null);

    // Inside a function: its parameters and locals.
    list = try S.complete(&s, 10, "fn more(count int) -> int:\n    step := 2\n    return ");
    try t.expectEqualStrings("count int", str(findItem(list, "count").?, &.{"detail"}));
    try t.expectEqualStrings("step int", str(findItem(list, "step").?, &.{"detail"}));
    try t.expect(findItem(list, "v") == null);
    try t.expect(findItem(list, "add") != null);

    // Nothing after a number. The reply is an empty list.
    list = try S.complete(&s, 11, "w := 12");
    try t.expectEqual(@as(usize, 0), list.len);

    // The patched source is not the document: the diagnostics are those of the text as it is.
    const out = try s.flush();
    const diags = items(out[0], &.{ "params", "diagnostics" });
    try t.expectEqual(@as(usize, 0), diags.len);
}

test "Signature help shows the function that is being called." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");

    const head =
        \\type Vec2:
        \\    x float
        \\
        \\fn (&Vec2) scale(by float, times int) -> float:
        \\    return self.x * by
        \\
        \\fn add(first int, second int) -> int:
        \\    return first + second
        \\
        \\v := Vec2{x = 1.0}
        \\
    ;
    const S = struct {
        fn help(session: *Session, version: i64, comptime last: []const u8) !Value {
            try session.change(main_uri, version, head ++ last);
            const line: u32 = @intCast(std.mem.count(u8, head, "\n"));
            return session.requestAt("textDocument/signatureHelp", main_uri, line, @intCast(last.len));
        }
    };
    try s.open(main_uri, 1, head);

    // Right after the bracket, and after a comma: neither parses as it is.
    var reply = try S.help(&s, 2, "n := add(");
    var sigs = items(reply, &.{ "result", "signatures" });
    try t.expectEqual(@as(usize, 1), sigs.len);
    try t.expectEqualStrings("fn add(first int, second int) -> int", str(sigs[0], &.{"label"}));
    var sig_params = items(sigs[0], &.{"parameters"});
    try t.expectEqual(@as(usize, 2), sig_params.len);
    try t.expectEqualStrings("first int", str(sig_params[0], &.{"label"}));
    try t.expectEqualStrings("second int", str(sig_params[1], &.{"label"}));
    try t.expectEqual(@as(i64, 0), int(reply, &.{ "result", "activeParameter" }));

    reply = try S.help(&s, 3, "n := add(1, ");
    try t.expectEqual(@as(i64, 1), int(reply, &.{ "result", "activeParameter" }));
    try t.expectEqualStrings("fn add(first int, second int) -> int", str(items(reply, &.{ "result", "signatures" })[0], &.{"label"}));

    // A call that is complete, with the cursor in its second argument.
    reply = try S.help(&s, 4, "n := add(1, 2");
    try t.expectEqual(@as(i64, 1), int(reply, &.{ "result", "activeParameter" }));

    // A method: the receiver is not one of the arguments.
    reply = try S.help(&s, 5, "f := v.scale(2.0, ");
    sigs = items(reply, &.{ "result", "signatures" });
    try t.expectEqualStrings("fn (&Vec2) scale(by float, times int) -> float", str(sigs[0], &.{"label"}));
    sig_params = items(sigs[0], &.{"parameters"});
    try t.expectEqual(@as(usize, 2), sig_params.len);
    try t.expectEqualStrings("times int", str(sig_params[1], &.{"label"}));
    try t.expectEqual(@as(i64, 1), int(reply, &.{ "result", "activeParameter" }));

    // The inner call of a nested one.
    reply = try S.help(&s, 6, "n := add(1, add(");
    try t.expectEqual(@as(i64, 0), int(reply, &.{ "result", "activeParameter" }));

    // Not in a call, and a call of something that is not a function of a source.
    reply = try S.help(&s, 7, "n := 1 + ");
    try t.expect(get(reply, &.{"result"}).? == .null);
    reply = try S.help(&s, 8, "n := nope(");
    try t.expect(get(reply, &.{"result"}).? == .null);
}

test "Workspace symbols and references across the sources of the workspace." {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "lib.cy", .data = "type Point:\n    x int\n\nfn twice(a int) -> int:\n    return a * 2\n\nfn unused() -> int:\n    return twice(1)\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "other.cy", .data = "use lib './lib.cy'\n\nfn twice_more(a int) -> int:\n    return lib.twice(lib.twice(a))\n" });
    // Has the word but another function of that name, and a source that does not compile.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "own.cy", .data = "fn twice(a int) -> int:\n    return a + a\nprint(twice(2))\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "broken.cy", .data = "fn twice(a int -> int:\n" });
    // A module that declares a function and does not use it itself.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "util.cy", .data = "fn helper(a int) -> int:\n    return a + 1\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "use_util.cy", .data = "use util './util.cy'\nprint(util.helper(1))\n" });
    try tmp.dir.createDirPath(t.io, "sub");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sub/deep.cy", .data = "use lib '../lib.cy'\nprint(lib.twice(3))\n" });
    try tmp.dir.createDirPath(t.io, ".hidden");
    try tmp.dir.writeFile(t.io, .{ .sub_path = ".hidden/skipped.cy", .data = "fn twice_hidden() -> int:\n    return 1\n" });
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);

    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    const arena = s.arena.allocator();
    const sep = std.Io.Dir.path.sep_str;
    const uriOf = struct {
        fn f(a: std.mem.Allocator, d: []const u8, comptime rel: []const u8) ![]u8 {
            return lsp.pathToUri(a, try std.fmt.allocPrint(a, "{s}" ++ sep ++ rel, .{d}));
        }
    }.f;
    const root_uri = try lsp.pathToUri(arena, dir);
    const a_uri = try uriOf(arena, dir, "a.cy");
    const lib_uri = try uriOf(arena, dir, "lib.cy");
    const other_uri = try uriOf(arena, dir, "other.cy");
    const deep_uri = try uriOf(arena, dir, "sub" ++ sep ++ "deep.cy");

    _ = try s.send(try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":0,"method":"initialize","params":{{"capabilities":{{}},
        \\"workspaceFolders":[{{"uri":"{s}","name":"ws"}}]}}}}
    , .{root_uri}));

    // `a.cy` only exists in the editor. It is part of the workspace like the files.
    try s.open(a_uri, 1, "use lib './lib.cy'\n\nfn local_fn() -> int:\n    return lib.twice(4)\n");

    // Symbols: the query matches letters in order, without regard to case. Hidden directories are skipped,
    // a source that does not parse has no symbols, and the locals of main blocks are left out.
    var out = try s.send(
        \\{"jsonrpc":"2.0","id":1,"method":"workspace/symbol","params":{"query":"twi"}}
    );
    var found = items(out[0], &.{"result"});
    var names: std.ArrayList([]const u8) = .empty;
    for (found) |sym| {
        try names.append(arena, try std.fmt.allocPrint(arena, "{s}@{s}", .{ str(sym, &.{"name"}), std.Io.Dir.path.basename(str(sym, &.{ "location", "uri" })) }));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lessThan);
    try t.expectEqual(@as(usize, 3), names.items.len);
    try t.expectEqualStrings("twice@lib.cy", names.items[0]);
    try t.expectEqualStrings("twice@own.cy", names.items[1]);
    try t.expectEqualStrings("twice_more@other.cy", names.items[2]);

    out = try s.send(
        \\{"jsonrpc":"2.0","id":2,"method":"workspace/symbol","params":{"query":"LOCAL"}}
    );
    found = items(out[0], &.{"result"});
    try t.expectEqual(@as(usize, 1), found.len);
    try t.expectEqualStrings("local_fn", str(found[0], &.{"name"}));
    try t.expectEqualStrings(a_uri, str(found[0], &.{ "location", "uri" }));
    try t.expectEqual(@as(i64, 12), int(found[0], &.{"kind"}));
    try expectRange(get(found[0], &.{ "location", "range" }).?, 2, 3, 2, 11);

    // A field has its type as the container.
    out = try s.send(
        \\{"jsonrpc":"2.0","id":3,"method":"workspace/symbol","params":{"query":"x"}}
    );
    found = items(out[0], &.{"result"});
    try t.expectEqual(@as(usize, 1), found.len);
    try t.expectEqualStrings("Point", str(found[0], &.{"containerName"}));

    // References of `lib.twice`, asked at a call in the open document: the call here, the declaration and
    // the call in `lib.cy`, the calls in the files that use the module. Not the `twice` of `own.cy`.
    var reply = try s.requestWith("textDocument/references", a_uri, 3, 16, ",\"context\":{\"includeDeclaration\":true}");
    var locs = items(reply, &.{"result"});
    var counts = std.StringHashMap(usize).init(arena);
    for (locs) |loc| {
        const entry = try counts.getOrPutValue(str(loc, &.{"uri"}), 0);
        entry.value_ptr.* += 1;
    }
    try t.expectEqual(@as(usize, 6), locs.len);
    try t.expectEqual(@as(usize, 1), counts.get(a_uri).?);
    try t.expectEqual(@as(usize, 2), counts.get(lib_uri).?);
    try t.expectEqual(@as(usize, 2), counts.get(other_uri).?);
    try t.expectEqual(@as(usize, 1), counts.get(deep_uri).?);
    try t.expectEqual(@as(usize, 4), counts.count());
    // The document that was asked comes first.
    try t.expectEqualStrings(a_uri, str(locs[0], &.{"uri"}));
    try expectRange(get(locs[0], &.{"range"}).?, 3, 15, 3, 20);
    for (locs) |loc| {
        if (!std.mem.eql(u8, str(loc, &.{"uri"}), lib_uri)) continue;
        // The name in the declaration, then the call in `unused`.
        try expectRange(get(loc, &.{"range"}).?, 3, 3, 3, 8);
        break;
    }

    // Without the declaration.
    reply = try s.requestWith("textDocument/references", a_uri, 3, 16, ",\"context\":{\"includeDeclaration\":false}");
    locs = items(reply, &.{"result"});
    try t.expectEqual(@as(usize, 5), locs.len);
    for (locs) |loc| {
        if (!std.mem.eql(u8, str(loc, &.{"uri"}), lib_uri)) continue;
        try expectRange(get(loc, &.{"range"}).?, 7, 11, 7, 16);
    }

    // A source that is open is searched as it is in the editor, not as it is on disk.
    try s.open(other_uri, 1, "use lib './lib.cy'\nprint(lib.twice(1))\n");
    reply = try s.requestWith("textDocument/references", a_uri, 3, 16, ",\"context\":{\"includeDeclaration\":false}");
    locs = items(reply, &.{"result"});
    try t.expectEqual(@as(usize, 4), locs.len);

    // Asked at the declaration itself, in the document that declares it.
    try s.open(lib_uri, 1, "type Point:\n    x int\n\nfn twice(a int) -> int:\n    return a * 2\n\nfn unused() -> int:\n    return twice(1)\n");
    reply = try s.requestWith("textDocument/references", lib_uri, 3, 5, ",\"context\":{\"includeDeclaration\":true}");
    locs = items(reply, &.{"result"});
    try t.expectEqual(@as(usize, 5), locs.len);
    try t.expectEqualStrings(lib_uri, str(locs[0], &.{"uri"}));
    try expectRange(get(locs[0], &.{"range"}).?, 3, 3, 3, 8);
    reply = try s.requestAt("textDocument/hover", lib_uri, 3, 5);
    try t.expectEqualStrings("```cyber\nfn twice(a int) -> int\n```", str(reply, &.{ "result", "contents", "value" }));

    // The declaration is found in a source that only declares the function.
    const use_util_uri = try uriOf(arena, dir, "use_util.cy");
    try s.open(use_util_uri, 1, "use util './util.cy'\nprint(util.helper(1))\n");
    reply = try s.requestWith("textDocument/references", use_util_uri, 1, 12, ",\"context\":{\"includeDeclaration\":true}");
    locs = items(reply, &.{"result"});
    try t.expectEqual(@as(usize, 2), locs.len);
    try t.expectEqualStrings(use_util_uri, str(locs[0], &.{"uri"}));
    try t.expectEqualStrings(try uriOf(arena, dir, "util.cy"), str(locs[1], &.{"uri"}));
    try expectRange(get(locs[1], &.{"range"}).?, 0, 3, 0, 9);
    reply = try s.requestWith("textDocument/references", use_util_uri, 1, 12, ",\"context\":{\"includeDeclaration\":false}");
    try t.expectEqual(@as(usize, 1), items(reply, &.{"result"}).len);

    // A parameter stays in its document. The requests do not disturb the diagnostics that follow.
    reply = try s.requestWith("textDocument/references", lib_uri, 4, 11, ",\"context\":{\"includeDeclaration\":true}");
    try t.expectEqual(@as(usize, 2), items(reply, &.{"result"}).len);
    out = try s.flush();
    for (out) |msg| {
        try t.expectEqual(@as(usize, 0), items(msg, &.{ "params", "diagnostics" }).len);
    }
}

const SemanticToken = struct {
    line: i64,
    char: i64,
    len: i64,
    type: i64,
    modifiers: i64,
};

/// The tokens of a `semanticTokens/full` reply with absolute positions.
fn decodeTokens(arena: std.mem.Allocator, reply: Value) ![]SemanticToken {
    const data = items(reply, &.{ "result", "data" });
    try t.expectEqual(@as(usize, 0), data.len % 5);
    const out = try arena.alloc(SemanticToken, data.len / 5);
    var line: i64 = 0;
    var char: i64 = 0;
    for (out, 0..) |*token, i| {
        const d = data[i * 5 ..][0..5];
        if (d[0].integer != 0) char = 0;
        line += d[0].integer;
        char += d[1].integer;
        token.* = .{ .line = line, .char = char, .len = d[2].integer, .type = d[3].integer, .modifiers = d[4].integer };
    }
    return out;
}

fn tokenAt(tokens: []SemanticToken, line: i64, char: i64) ?SemanticToken {
    for (tokens) |token| {
        if (token.line == line and token.char == char) return token;
    }
    return null;
}

test "Semantic tokens name what the compiler resolved." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");
    const arena = s.arena.allocator();

    try s.open(main_uri, 1,
        \\use math
        \\
        \\type Vec2:
        \\    x float
        \\
        \\fn (&Vec2) len() -> float:
        \\    return math.sqrt(self.x)
        \\
        \\const limit = 10
        \\
        \\v := Vec2{x = 1.0}
        \\print('한글' + str(v.len() + float(limit)))
        \\
    );
    var reply = try s.request("textDocument/semanticTokens/full", main_uri);
    var tokens = try decodeTokens(arena, reply);
    // The legend: namespace 0, type 1, enumMember 2, function 3, method 4, property 5, variable 6. Modifier 1 is readonly.
    const expected = [_]SemanticToken{
        .{ .line = 6, .char = 11, .len = 4, .type = 0, .modifiers = 0 }, // math
        .{ .line = 6, .char = 16, .len = 4, .type = 3, .modifiers = 0 }, // sqrt
        .{ .line = 6, .char = 21, .len = 4, .type = 6, .modifiers = 0 }, // self
        .{ .line = 6, .char = 26, .len = 1, .type = 5, .modifiers = 0 }, // x
        .{ .line = 10, .char = 0, .len = 1, .type = 6, .modifiers = 0 }, // v
        .{ .line = 10, .char = 5, .len = 4, .type = 1, .modifiers = 0 }, // Vec2
        .{ .line = 11, .char = 0, .len = 5, .type = 3, .modifiers = 0 }, // print
        // After two Korean characters: UTF-16 code units.
        .{ .line = 11, .char = 17, .len = 1, .type = 6, .modifiers = 0 }, // v
        .{ .line = 11, .char = 19, .len = 3, .type = 4, .modifiers = 0 }, // len
        .{ .line = 11, .char = 27, .len = 5, .type = 1, .modifiers = 0 }, // float
        .{ .line = 11, .char = 33, .len = 5, .type = 6, .modifiers = 1 }, // limit
    };
    for (expected) |exp| {
        const token = tokenAt(tokens, exp.line, exp.char) orelse {
            std.debug.print("no token at {}:{}\n", .{ exp.line, exp.char });
            return error.TestExpectedEqual;
        };
        try t.expectEqual(exp, token);
    }
    // Sorted, no overlaps, and nothing for keywords and literals.
    for (tokens[1..], 0..) |token, i| {
        const prev = tokens[i];
        try t.expect(token.line > prev.line or (token.line == prev.line and token.char >= prev.char + prev.len));
    }
    try t.expect(tokenAt(tokens, 0, 0) == null);
    try t.expect(tokenAt(tokens, 10, 14) == null);

    // A name after the first error of its body was not reached and has no token. What came before has.
    try s.change(main_uri, 2, "a := 1\nb := a + nope\nc := a\n");
    reply = try s.request("textDocument/semanticTokens/full", main_uri);
    tokens = try decodeTokens(arena, reply);
    try t.expect(tokenAt(tokens, 0, 0) != null);
    try t.expect(tokenAt(tokens, 1, 5) != null);
    try t.expect(tokenAt(tokens, 2, 5) == null);

    // A document that does not parse has none.
    try s.change(main_uri, 3, "a := (1\n");
    reply = try s.request("textDocument/semanticTokens/full", main_uri);
    try t.expectEqual(@as(usize, 0), items(reply, &.{ "result", "data" }).len);
}

test "Messages that are not well formed do not crash the server or get a stray reply." {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");

    // An id is a number or a string. Anything else is not echoed back.
    var nested: std.ArrayList(u8) = .empty;
    defer nested.deinit(t.allocator);
    try nested.appendSlice(t.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
    try nested.appendNTimes(t.allocator, '[', 300);
    try nested.appendNTimes(t.allocator, ']', 300);
    try nested.appendSlice(t.allocator, ",\"method\":\"textDocument/hover\",\"params\":{}}");
    var out = try s.send(nested.items);
    try t.expectEqual(@as(usize, 1), out.len);
    try t.expectEqual(@as(i64, -32600), int(out[0], &.{ "error", "code" }));
    try t.expect(get(out[0], &.{"id"}).? == .null);
    out = try s.send(
        \\{"jsonrpc":"2.0","id":{"a":1},"method":"shutdown"}
    );
    try t.expectEqual(@as(i64, -32600), int(out[0], &.{ "error", "code" }));
    try t.expect(!s.server.shutdown);

    // A request without an id has nobody to reply to.
    out = try s.send(
        \\{"jsonrpc":"2.0","method":"textDocument/hover","params":{"textDocument":{"uri":"x"},"position":{"line":0,"character":0}}}
    );
    try t.expectEqual(@as(usize, 0), out.len);
    out = try s.send(
        \\{"jsonrpc":"2.0","method":"workspace/symbol","params":{"query":""}}
    );
    try t.expectEqual(@as(usize, 0), out.len);

    // A document can not take the place of a standard module by calling itself `core`.
    try s.open("core", 1, "x := nope\n");
    out = try s.flush();
    try t.expectEqual(@as(usize, 1), out.len);
    try t.expectEqualStrings("core", str(out[0], &.{ "params", "uri" }));
    try t.expectEqualStrings("Undeclared variable `nope`.", str(items(out[0], &.{ "params", "diagnostics" })[0], &.{"message"}));
    try s.open(main_uri, 1, "print(1)\n");
    out = try s.flush();
    for (out) |msg| {
        if (std.mem.eql(u8, str(msg, &.{ "params", "uri" }), main_uri)) {
            try t.expectEqual(@as(usize, 0), items(msg, &.{ "params", "diagnostics" }).len);
        }
    }

    // Two uris for one path are one document: the later one takes the place, and the earlier one is cleared.
    const other_uri = "file:///cyber-lsp-test/main%2Ecy";
    out = try s.openReplacing(other_uri, 1, "print(nope)\n");
    try t.expectEqual(@as(usize, 1), out.len);
    try t.expectEqualStrings(main_uri, str(out[0], &.{ "params", "uri" }));
    try t.expectEqual(@as(usize, 0), items(out[0], &.{ "params", "diagnostics" }).len);
    try t.expect(s.server.docs.get(main_uri) == null);
    try t.expect(s.server.docs.get(other_uri) != null);
    try t.expectEqual(@as(u32, 2), s.server.docs.count());
}

test "Half-typed source never crashes the server." {
    // Every prefix of a source is what the server sees while the source is typed (final review, 2026-11-13:
    // `fn f(a` and `return ,` crashed the parser).
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");

    const src =
        \\use math
        \\
        \\type Vec2:
        \\    x float
        \\    -y float = 0.0
        \\
        \\fn (&Vec2) len() -> float:
        \\    return math.sqrt(self.x * self.x)
        \\
        \\type Color enum:
        \\    case red
        \\
        \\fn add[T Any](a T, b T) -> T:
        \\    if a == b:
        \\        return a
        \\    for 0..3 |i|:
        \\        print('%{i}')
        \\    return a + b
        \\
        \\v := Vec2{x = 1.0}
        \\f := fn(n int) => n + 1
        \\print(v.len() + float(add[int](1, f(2))))
        \\
    ;
    try s.open(main_uri, 0, "");
    _ = try s.flush();
    var version: i64 = 0;
    var i: usize = 1;
    while (i <= src.len) : (i += 1) {
        version += 1;
        try s.server.handle(try std.fmt.allocPrint(s.arena.allocator(),
            \\{{"jsonrpc":"2.0","method":"textDocument/didChange","params":{{"textDocument":{{"uri":"{s}","version":{}}},
            \\"contentChanges":[{{"text":{s}}}]}}}}
        , .{ main_uri, version, try std.json.Stringify.valueAlloc(s.arena.allocator(), src[0..i], .{}) }));
        // The outline parses every prefix. Compiling is slower: every sixth prefix and every end of a line.
        _ = try s.request("textDocument/documentSymbol", main_uri);
        if (i % 6 == 0 or src[i - 1] == '\n') {
            _ = try s.flush();
            const line: u32 = @intCast(std.mem.count(u8, src[0..i], "\n"));
            const col: u32 = @intCast(i - (if (std.mem.findScalarLast(u8, src[0..i], '\n')) |nl| nl + 1 else 0));
            // A completion compiles up to three patched copies.
            if (i % 12 == 0) _ = try s.requestAt("textDocument/completion", main_uri, line, col);
        }
    }
    // The whole source has no errors.
    const out = try s.flush();
    _ = out;
    const reply = try s.request("textDocument/documentSymbol", main_uri);
    try t.expectEqual(@as(usize, 6), items(reply, &.{"result"}).len);
}

test "Closing a module rechecks the documents that use it, and a link names the same document as its file." {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "real");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "real/lib.cy", .data = "fn twice(a int) -> int:\n    return a * nope\n" });
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);

    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");
    const arena = s.arena.allocator();
    const sep = std.Io.Dir.path.sep_str;
    const main_real = try lsp.pathToUri(arena, try std.fmt.allocPrint(arena, "{s}" ++ sep ++ "real" ++ sep ++ "main.cy", .{dir}));
    const lib_real = try lsp.pathToUri(arena, try std.fmt.allocPrint(arena, "{s}" ++ sep ++ "real" ++ sep ++ "lib.cy", .{dir}));

    // The module on disk has an error. In the editor it is fixed.
    try s.open(main_real, 1, "use lib './lib.cy'\nprint(lib.twice(2))\n");
    try s.open(lib_real, 1, "fn twice(a int) -> int:\n    return a * 2\n");
    var out = try s.flush();
    for (out) |msg| {
        try t.expectEqual(@as(usize, 0), items(msg, &.{ "params", "diagnostics" }).len);
    }

    // Closing the module discards the editor's text. The document that uses it reads the file again.
    out = try s.send(try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","method":"textDocument/didClose","params":{{"textDocument":{{"uri":"{s}"}}}}}}
    , .{lib_real}));
    try t.expect(s.server.hasPending());
    out = try s.flush();
    var main_has_error = false;
    for (out) |msg| {
        if (std.mem.eql(u8, str(msg, &.{ "params", "uri" }), main_real)) {
            main_has_error = items(msg, &.{ "params", "diagnostics" }).len == 1;
        }
    }
    try t.expect(main_has_error);

    if (builtin.os.tag == .windows) return;
    // The same files through a symbolic link to their directory: the compiler resolves the module to the real
    // file, and the document opened through the link is that file.
    try tmp.dir.symLink(t.io, "real", "link", .{ .is_directory = true });
    const main_link = try lsp.pathToUri(arena, try std.fmt.allocPrint(arena, "{s}" ++ sep ++ "link" ++ sep ++ "main.cy", .{dir}));
    const lib_link = try lsp.pathToUri(arena, try std.fmt.allocPrint(arena, "{s}" ++ sep ++ "link" ++ sep ++ "lib.cy", .{dir}));
    try s.open(lib_link, 1, "fn twice(a int) -> int:\n    return a * 2\n");
    out = try s.flush();
    for (out) |msg| {
        try t.expectEqual(@as(usize, 0), items(msg, &.{ "params", "diagnostics" }).len);
    }
    // Go to definition answers with the uri that the editor knows the module by.
    const reply = try s.requestAt("textDocument/definition", main_real, 1, 11);
    try t.expectEqualStrings(lib_link, str(reply, &.{ "result", "uri" }));
    // Opening the main document through the link replaces the one opened by its real path.
    out = try s.openReplacing(main_link, 1, "use lib './lib.cy'\nprint(lib.twice(3))\n");
    try t.expectEqualStrings(main_real, str(out[0], &.{ "params", "uri" }));
    try t.expect(s.server.docs.get(main_real) == null);
    out = try s.flush();
    for (out) |msg| {
        try t.expectEqual(@as(usize, 0), items(msg, &.{ "params", "diagnostics" }).len);
    }
}

test "A module is read from the editor when it is open, otherwise from the disk." {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b.cy", .data = "fn twice(a int) -> int:\n  return a * nope\n" });
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);

    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.initialize("[]");
    const arena = s.arena.allocator();
    const sep = std.Io.Dir.path.sep_str;
    const a_uri = try lsp.pathToUri(arena, try std.fmt.allocPrint(arena, "{s}" ++ sep ++ "a.cy", .{dir}));
    const b_uri = try lsp.pathToUri(arena, try std.fmt.allocPrint(arena, "{s}" ++ sep ++ "b.cy", .{dir}));

    // `a.cy` only exists in the editor. The error is in the module on disk: the module gets the diagnostic and
    // the document one that points to it.
    try s.open(a_uri, 1, "use b './b.cy'\nprint(b.twice(2))\n");
    var out = try s.flush();
    try t.expectEqual(@as(usize, 2), out.len);
    try t.expectEqualStrings(a_uri, str(out[0], &.{ "params", "uri" }));
    var diags = items(out[0], &.{ "params", "diagnostics" });
    try t.expectEqual(@as(usize, 1), diags.len);
    try t.expect(std.mem.endsWith(u8, str(diags[0], &.{"message"}), "b.cy`: Undeclared variable `nope`."));
    try expectRange(get(diags[0], &.{"range"}).?, 0, 0, 0, 0);
    const related = items(diags[0], &.{"relatedInformation"});
    try t.expectEqualStrings(b_uri, str(related[0], &.{ "location", "uri" }));
    try expectRange(get(related[0], &.{ "location", "range" }).?, 1, 13, 1, 17);
    try t.expectEqualStrings(b_uri, str(out[1], &.{ "params", "uri" }));
    try t.expect(get(out[1], &.{ "params", "version" }) == null);
    diags = items(out[1], &.{ "params", "diagnostics" });
    try t.expectEqualStrings("Undeclared variable `nope`.", str(diags[0], &.{"message"}));
    try expectRange(get(diags[0], &.{"range"}).?, 1, 13, 1, 17);

    // The module is opened and fixed in the editor, not on disk. Both documents are checked again, and each
    // gets its diagnostics from its own check.
    try s.open(b_uri, 1, "fn twice(a int) -> int:\n  return a * 2\n");
    out = try s.flush();
    var a_clean = false;
    var b_clean = false;
    for (out) |msg| {
        try t.expectEqual(@as(usize, 0), items(msg, &.{ "params", "diagnostics" }).len);
        if (std.mem.eql(u8, str(msg, &.{ "params", "uri" }), a_uri)) a_clean = true;
        if (std.mem.eql(u8, str(msg, &.{ "params", "uri" }), b_uri)) b_clean = true;
    }
    try t.expect(a_clean and b_clean);

    // An error in the open module shows in the module, and in the document as a pointer only.
    try s.change(b_uri, 2, "fn twice(a int) -> int:\n  return a * zip\n");
    out = try s.flush();
    try t.expectEqual(@as(usize, 2), out.len);
    for (out) |msg| {
        diags = items(msg, &.{ "params", "diagnostics" });
        try t.expectEqual(@as(usize, 1), diags.len);
        if (std.mem.eql(u8, str(msg, &.{ "params", "uri" }), b_uri)) {
            try t.expectEqual(@as(i64, 2), int(msg, &.{ "params", "version" }));
            try t.expectEqualStrings("Undeclared variable `zip`.", str(diags[0], &.{"message"}));
        } else {
            try t.expect(std.mem.endsWith(u8, str(diags[0], &.{"message"}), "b.cy`: Undeclared variable `zip`."));
        }
    }

    // A module that does not exist is an error of the `use`.
    try s.change(a_uri, 2, "use c './missing.cy'\n");
    out = try s.flush();
    for (out) |msg| {
        if (!std.mem.eql(u8, str(msg, &.{ "params", "uri" }), a_uri)) continue;
        diags = items(msg, &.{ "params", "diagnostics" });
        try t.expect(std.mem.startsWith(u8, str(diags[0], &.{"message"}), "Import path does not exist:"));
        // The range is the path of the `use`.
        try expectRange(get(diags[0], &.{"range"}).?, 0, 6, 0, 20);
    }
}
