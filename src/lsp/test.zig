//! Sessions with the server, message by message.

const std = @import("std");
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
    try t.expectEqualStrings("cyber-lsp", str(out[0], &.{ "result", "serverInfo", "name" }));

    out = try s.send(
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-16","utf-8"]}}}}
    );
    try t.expectEqualStrings("utf-8", str(out[0], &.{ "result", "capabilities", "positionEncoding" }));

    // A request that the server does not know gets an error, a notification is skipped, a reply is ignored.
    out = try s.send(
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/completion","params":{}}
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
