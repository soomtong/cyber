#[consteval]
fn GetType(a int) -> type:
    return bool

--cytest: error
--CompileError: The `#[consteval]` attribute is reserved for the builtin modules.
--
--@MainPath():1:3:
--#[consteval]
--  ^
--
