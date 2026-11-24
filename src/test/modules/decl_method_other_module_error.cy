use p 'test_mods/priv.cy'
use Info = p.Info

fn (&Info) twice() -> int:
    return self.a * 2

--cytest: error
--CompileError: Can not declare `twice` for `Info`: `Info` belongs to another module. A method or a member of a type is declared in the module that declares the type.
--
--@MainPath():4:6:
--fn (&Info) twice() -> int:
--     ^~~~
--