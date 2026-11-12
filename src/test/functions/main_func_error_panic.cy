fn main() -> !int:
    return error.Boom

--cytest: panic
--panic: Unwrapped error `error.Boom`.
--
--[trace]
--@MainPath():1:1 main:
--fn main() -> !int:
--^
--