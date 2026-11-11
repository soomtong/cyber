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

test "fmt: `=` inside brackets is kept as written." {
    try eqFormat(
        \\a := Vec2{x=1, y = 2}
        \\foo(1, name: 2)
        \\#[extern='puts']
        \\fn puts(s Ptr[byte]) -> int
        \\
    ,
        \\a := Vec2{x=1,y = 2}
        \\foo(1,name:2)
        \\#[extern='puts']
        \\fn puts(s Ptr[byte])->int
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
    try zt.eq(true, C.c.cl_vm_format(vm, C.to_bytes("a:=1"), &out));
    try std.testing.expectEqualStrings("a := 1\n", C.from_bytes(out));
    C.vm_freeb(vm, C.from_bytes(out));

    C.setSilent(true);
    defer C.setSilent(false);
    try zt.eq(false, C.c.cl_vm_format(vm, C.to_bytes("a := (1"), &out));
    try std.testing.expect(std.mem.startsWith(u8, C.from_bytes(out), "1:"));
    C.vm_freeb(vm, C.from_bytes(out));
}
