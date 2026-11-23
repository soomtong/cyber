-- `T` is `bool` from the first argument. A compile-time call reports the mismatch like a runtime call.
fn size(x %T, v [%N]T) -> int:
    return N

const n = size(true, [3]int{1, 2, 3})
print(n)

--cytest: error
--CompileError: Expected type `[3]bool`. Found `[3]int`.
--
--@MainPath():5:22:
--const n = size(true, [3]int{1, 2, 3})
--                     ^~~~~~~~~~~~~~~
--