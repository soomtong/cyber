type Cents:
    n int

fn `-`(a Cents) -> Cents:
    return {n=-a.n}

--cytest: error
--CompileError: A module-level operator function takes two parameters, the left and the right operand.
--
--@MainPath():4:1:
--fn `-`(a Cents) -> Cents:
--^~~~~~~~~~~~~~~~~~~~~~~~~
--