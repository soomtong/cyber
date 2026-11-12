type Job:
    n int

fn (&Job) peek():
    suspend

job := Job{n=1}
f := fiber Job.peek(&job)

--cytest: error
--CompileError: Cannot borrow a stack value across fibers. The parameter type is `&Job`. Use `^T`.
--
--@MainPath():8:6:
--f := fiber Job.peek(&job)
--     ^~~~~~~~~~~~~~~~~~~~
--