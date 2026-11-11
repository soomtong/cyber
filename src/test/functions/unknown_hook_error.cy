type Foo:
    a int

fn (&Foo) @whatever() -> int:
    return 1

--cytest: error
--CompileError: Unknown hook `@whatever`. A function name can start with `@` only when it is a hook that the compiler calls, such as `@init` or `@deinit`.
--
--@MainPath():4:11:
--fn (&Foo) @whatever() -> int:
--          ^~~~~~~~~
--
