const std = @import("std");
const stdx = @import("stdx");
const cy = @import("../cyber.zig");
const C = @import("../capi.zig");
const zt = stdx.testing;
const format = cy.format;

/// Formats `src`, compares with `exp` and checks that formatting the result again changes nothing.
fn eqFormat(exp: []const u8, src: []const u8) !void {
    const alloc = std.testing.allocator;
    var diag: format.Diagnostic = .{};
    defer diag.deinit(alloc);
    const out = format.format(alloc, src, &diag) catch |err| {
        std.debug.print("format failed at {}:{}: {s}\n", .{ diag.line + 1, diag.col + 1, diag.msg });
        return err;
    };
    defer alloc.free(out);
    try std.testing.expectEqualStrings(exp, out);

    const again = try format.format(alloc, out, &diag);
    defer alloc.free(again);
    try std.testing.expectEqualStrings(out, again);
}

test "fmt: spacing between tokens." {
    try eqFormat(
        \\use math
        \\nouns := []str{'World', 'mundo'}
        \\x := 1 + 2 * -3
        \\x += 1
        \\x = foo(1, 2)
        \\if n == 'x' and !done:
        \\    pass
        \\
    ,
        \\use   math
        \\nouns:=[]str{ 'World','mundo' }
        \\x:=1+2*-3
        \\x+=1
        \\x=foo( 1 ,2 )
        \\if n=='x' and ! done :
        \\    pass
        \\
    );
}

test "fmt: `=` of a literal field has a space on each side, `=` of an attribute is kept as written." {
    try eqFormat(
        \\a := Vec2{x = 1, y = 2}
        \\b := foo({x = a.x * 2, inner = Vec2{x = 1, y = 2}}, [2]int{1, 2})
        \\foo(1, name: 2)
        \\#[extern='puts']
        \\fn puts(s Ptr[byte]) -> int
        \\#[cond = type.is_copyable(T)]
        \\fn copy(a T) -> T
        \\
    ,
        \\a := Vec2{x=1,y  =  2}
        \\b := foo({x=a.x*2, inner= Vec2{x =1, y=2}}, [2]int{1, 2})
        \\foo(1,name:2)
        \\#[extern='puts']
        \\fn puts(s Ptr[byte])->int
        \\#[cond = type.is_copyable( T )]
        \\fn copy(a T) -> T
        \\
    );
}

test "fmt: operators in a range bound are kept as written." {
    try eqFormat(
        \\a := b[i..i+n]
        \\for 0..n-1 |i|:
        \\    pass
        \\c := n - 1
        \\
    ,
        \\a := b[i..i+n]
        \\for 0..n-1 |i|:
        \\    pass
        \\c := n-1
        \\
    );
}

test "fmt: a removed space never joins two tokens." {
    // `--` starts a comment.
    try eqFormat(
        \\a := - -b
        \\c := a - -b
        \\
    ,
        \\a := - -b
        \\c := a- -b
        \\
    );
}

test "fmt: whitespace before `[` after an operand is kept." {
    try eqFormat(
        \\a := b[1]
        \\c := foo(a, []int{1})
        \\
    ,
        \\a := b[ 1 ]
        \\c := foo(a,[]int{1})
        \\
    );
}

test "fmt: blocks are indented by 4 spaces." {
    try eqFormat(
        \\fn foo(a int) -> int:
        \\    if a == 1:
        \\        return 1
        \\    else:
        \\        return 2
        \\
        \\type T:
        \\    x int
        \\    y float
        \\
        \\switch foo(1):
        \\    case 1:
        \\        pass
        \\    case 2: pass
        \\    else:
        \\        pass
        \\
    ,
        "fn foo(a int) -> int:\n" ++
            "  if a == 1:\n" ++
            "       return 1\n" ++
            "  else:\n" ++
            "   return 2\n" ++
            "\n" ++
            "type T:\n" ++
            "\tx int\n" ++
            "\ty   float\n" ++
            "\n" ++
            "switch foo(1):\n" ++
            "  case 1:\n" ++
            "    pass\n" ++
            "  case 2: pass\n" ++
            "  else:\n" ++
            "    pass\n",
    );
}

test "fmt: lines inside brackets follow the line that opened the bracket." {
    try eqFormat(
        \\fn main():
        \\    r := foo(1,
        \\        2)
        \\    foo(1,
        \\        fn():
        \\            bar()
        \\    )
        \\    x := []int{
        \\        1,
        \\        2,
        \\    }
        \\
    ,
        \\fn main():
        \\  r := foo(1,
        \\           2)
        \\  foo(1,
        \\       fn():
        \\         bar()
        \\   )
        \\  x := []int{
        \\    1,
        \\    2,
        \\  }
        \\
    );
}

test "fmt: a line after a nested block does not join the block." {
    // The last line continues the call. At the indentation of `return 1` it would parse as a statement of the lambda.
    try eqFormat(
        \\x := foo(a, {f = fn():
        \\    return 1
        \\        , g = 2})
        \\
    ,
        \\x := foo(a, {f = fn():
        \\  return 1
        \\      , g = 2})
        \\
    );
}

test "fmt: other continuation lines keep their relative indentation." {
    try eqFormat(
        \\fn main():
        \\    x := a +
        \\      b
        \\
    ,
        \\fn main():
        \\  x := a +
        \\    b
        \\
    );
}

test "fmt: comments." {
    try eqFormat(
        \\-- leading
        \\fn main():
        \\    -- first
        \\    a := 1  -- trailing keeps its gap
        \\    if a == 1:
        \\        pass
        \\        -- end of block
        \\    -- end of function
        \\-- top level
        \\main()
        \\
    ,
        "-- leading   \n" ++
            "fn main():\n" ++
            "  -- first\n" ++
            "  a := 1  -- trailing keeps its gap\n" ++
            "  if a == 1:\n" ++
            "    pass\n" ++
            "    -- end of block\n" ++
            "  -- end of function\n" ++
            "-- top level\n" ++
            "main()\n",
    );
}

test "fmt: blank lines, line ends and the end of the file." {
    try eqFormat("a := 1\n\nb := 2\n", "\n\na := 1   \n\n\n\nb := 2\n\n\n");
    try eqFormat("a := 1\n", "a := 1");
    try eqFormat("a := 1\nb := 2\n", "a := 1\r\nb := 2\r\n");
    try eqFormat("", "");
    try eqFormat("", "\n\n");
    try eqFormat("-- only\n-- comments\n", "-- only\n   -- comments  \n");
}

test "fmt: shebang line and byte order mark." {
    try eqFormat("#!/usr/bin/env cyber\na := 1\n", "#!/usr/bin/env cyber\r\na:=1\n");
    try eqFormat("\xEF\xBB\xBFa := 1\n", "\xEF\xBB\xBFa:=1\n");
    // Blank lines after the shebang line become one, like anywhere else.
    try eqFormat("#!/usr/bin/env cyber\n\nuse os\n", "#!/usr/bin/env cyber\n\nuse os\n");
    try eqFormat("#!/usr/bin/env cyber\n\nuse os\n", "#!/usr/bin/env cyber  \n\n\n\nuse os\n");
    try eqFormat("#!/usr/bin/env cyber\n\n-- note\nuse os\n", "#!/usr/bin/env cyber\n\n-- note\nuse os\n");
    // Blank lines after a byte order mark alone are leading blank lines.
    try eqFormat("\xEF\xBB\xBFa := 1\n", "\xEF\xBB\xBF\n\na:=1\n");
}

/// Expects a syntax error, not a crash and not an internal error.
fn expectParseError(src: []const u8) !void {
    const alloc = std.testing.allocator;
    var diag: format.Diagnostic = .{};
    defer diag.deinit(alloc);
    try std.testing.expectError(error.ParseError, format.format(alloc, src, &diag));
    try zt.eq(format.ErrorKind.parse, diag.kind);
}

test "fmt: source that ends in the middle of a token." {
    C.setSilent(true);
    defer C.setSilent(false);
    // The tokenizer looked at the character after these without checking for the end of the source.
    for ([_][]const u8{ "x := a.", "x := 1 <", "x >", "a -", "a &", "a |", "a *", "a _", "1.", "1_", "a:" }) |src| {
        try expectParseError(src);
    }
}

test "fmt: malformed number and dot literals are syntax errors." {
    C.setSilent(true);
    defer C.setSilent(false);
    try expectParseError("a := 1e_5\n");
    try expectParseError("a := 1e-_5\n");
    try expectParseError("a := 0o7_8\n");
    // The text of a dot literal includes the whitespace, so squeezing it would change the syntax tree.
    try expectParseError("var x E = .  a\n");
    try eqFormat("var x E = .a\n", "var x E   =   .a\n");
}

test "fmt: operator precedence is kept." {
    // `2 * 3 + 4 * 5` after a lower operator: the verification compares the trees of both sides.
    try eqFormat("x := 26 == 2 * 3 + 4 * 5\n", "x := 26==2*3+4*5\n");
}

test "fmt: string contents are never touched." {
    try eqFormat(
        "a := 'x  ,y'\n" ++
            "b := \"n=%{ n+1 }  !\"\n" ++
            "c := \"\"\"\n" ++
            "  keep   \n" ++
            "\t%{n}\n" ++
            "\"\"\"\n" ++
            "d := `raw  ,`\n",
        "a:='x  ,y'\n" ++
            "b:=\"n=%{ n+1 }  !\"\n" ++
            "c:=\"\"\"\n" ++
            "  keep   \n" ++
            "\t%{n}\n" ++
            "\"\"\"\n" ++
            "d:=`raw  ,`\n",
    );
}

test "fmt: the lines between `-- fmt: off` and `-- fmt: on` are kept as written." {
    try eqFormat(
        \\fn main():
        \\    -- fmt: off
        \\    m := []int{
        \\        1,  0,  0,
        \\        0,  1,  0,
        \\    }
        \\
        \\
        \\    x:=1
        \\    -- fmt: on
        \\    y := 2
        \\
    ,
        // The region moves with the `-- fmt: off` line from 2 to 4 spaces and keeps its relative indentation.
        // Its trailing whitespace is dropped.
        "fn main():\n" ++
            "  -- fmt: off   \n" ++
            "  m := []int{\n" ++
            "      1,  0,  0,   \n" ++
            "      0,  1,  0,\n" ++
            "  }\n" ++
            "\n" ++
            "\n" ++
            "  x:=1\n" ++
            "  -- fmt: on\n" ++
            "  y:=2\n",
    );
    // Without `-- fmt: on` the region ends with the file. Line ends become `\n`, tabs of an indentation spaces.
    try eqFormat("-- fmt: off\nm := {1,  2}\n\n\nn:={3}\n", "-- fmt: off\r\nm := {1,  2}\r\n\r\n\r\nn:={3}\r\n");
    try eqFormat("if true:\n    -- fmt: off\n    m := {1,  2}\n    -- fmt: on\n    a := 1\n", "if true:\n\t-- fmt: off\n\tm := {1,  2}\n\t-- fmt: on\n\ta:=1\n");
    // Blank lines before `-- fmt: on` are outside the region. An empty region.
    try eqFormat("-- fmt: off\na:=1\n\n-- fmt: on\nb := 2\n", "-- fmt: off\na:=1\n\n\n-- fmt: on\nb:=2\n");
    try eqFormat("-- fmt: off\n-- fmt: on\na := 1\n", "-- fmt: off\n-- fmt: on\na:=1\n");
    // A space after `--` is optional. A trailing `-- fmt: off` and other words are ordinary comments.
    try eqFormat("--fmt: off\na:=1\n--   fmt: on\nb := 2\n", "--fmt: off\na:=1\n--   fmt: on   \nb:=2\n");
    try eqFormat("a := 1 -- fmt: off\nb := 2\n", "a:=1 -- fmt: off\nb:=2\n");
    try eqFormat("-- fmt: off now\na := 1\n", "-- fmt: off now\na:=1\n");
}

test "fmt: a line that ends with `-- fmt: skip` keeps its spacing." {
    try eqFormat(
        \\if true:
        \\    z  :=  3  --  fmt: skip
        \\    s:='a%{1+2}b'  -- fmt: skip
        \\    t := 1
        \\
    ,
        // The indentation still follows the block.
        \\if true:
        \\  z  :=  3  --  fmt: skip
        \\  s:='a%{1+2}b'  -- fmt: skip
        \\  t:=1
        \\
    );
    // A `-- fmt: skip` on its own line skips nothing.
    try eqFormat("-- fmt: skip\na := 1\n", "-- fmt: skip\na:=1\n");
}

test "fmt: a `-- fmt: off` region that does not fit its block is a verification error." {
    C.setSilent(true);
    defer C.setSilent(false);

    const alloc = std.testing.allocator;
    var diag: format.Diagnostic = .{};
    defer diag.deinit(alloc);
    // The region starts in the inner block and moves by its shift, which is too much for `b`.
    const src = "if true:\n  if true:\n    -- fmt: off\n    a:=1\n  b:=2\n  -- fmt: on\n";
    try std.testing.expectError(error.VerifyError, format.format(alloc, src, &diag));
    try zt.eq(format.ErrorKind.verify, diag.kind);
    try std.testing.expect(std.mem.indexOf(u8, diag.msg, "`-- fmt: off` region") != null);
}

test "fmt: a syntax error is reported with its position." {
    // The parser prints an error trace in debug builds unless silenced.
    C.setSilent(true);
    defer C.setSilent(false);

    const alloc = std.testing.allocator;
    var diag: format.Diagnostic = .{};
    defer diag.deinit(alloc);
    try std.testing.expectError(error.ParseError, format.format(alloc, "a := 1\nb := (2\n", &diag));
    try zt.eq(format.ErrorKind.parse, diag.kind);
    try zt.eq(@as(u32, 1), diag.line);
    try std.testing.expect(diag.msg.len > 0);
}

test "cl_vm_format()" {
    const vm = C.vm_init();
    defer C.vm_deinit(vm);

    var out: C.Bytes = undefined;
    try zt.eq(C.FormatOk, C.c.cl_vm_format(vm, C.to_bytes("a:=1"), &out));
    try std.testing.expectEqualStrings("a := 1\n", C.from_bytes(out));
    C.vm_freeb(vm, C.from_bytes(out));

    C.setSilent(true);
    defer C.setSilent(false);
    try zt.eq(C.FormatSyntaxError, C.c.cl_vm_format(vm, C.to_bytes("a := (1"), &out));
    try std.testing.expect(std.mem.startsWith(u8, C.from_bytes(out), "1:"));
    C.vm_freeb(vm, C.from_bytes(out));
}
