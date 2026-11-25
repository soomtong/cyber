fn tag(x ?str) -> str:
    return 'str'
fn tag(x ?int) -> str:
    return 'option int'

print(tag(none))

--cytest: error
--CompileError: The call is ambiguous: both `fn tag(?str) -> str` and `fn tag(?int) -> str` match, and neither is more specific. Write `tag(?str(none))` or `tag(?int(none))`.
--
--@MainPath():6:7:
--print(tag(none))
--      ^~~~~~~~~
--