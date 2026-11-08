#[generator]
fn watch(p &int) -> int:
    yield p.*

--cytest: error
--CompileError: A `#[generator]` function can not take the borrow type `&int` as a parameter. The generator outlives the call, so pass an owned value or a `^T` pointer instead.
--
--@MainPath():2:10:
--fn watch(p &int) -> int:
--         ^~~~~~
--
