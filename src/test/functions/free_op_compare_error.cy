type Cents:
    n int

fn `<`(a Cents, b Cents) -> bool:
    return a.n < b.n

--cytest: error
--CompileError: Declare `<` as a method of the left operand type. A comparison operator is not looked up in the module of its operands.
--
--@MainPath():4:1:
--fn `<`(a Cents, b Cents) -> bool:
--^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--