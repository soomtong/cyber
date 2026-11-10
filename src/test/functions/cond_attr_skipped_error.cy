#[cond=false]
fn foo() -> int:
    return 1

print(foo())

--cytest: error
--CompileError: Undeclared variable `foo`.
--
--@MainPath():5:7:
--print(foo())
--      ^~~
--
