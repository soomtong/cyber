type Job:
    n int

fn (^Job) work():
    suspend

job := ^Job{n=0}
f := fiber job.work()

--cytest: error
--CompileError: A fiber entry cannot be a method call on a value. Pass the receiver as the first argument: `fiber T.work(obj)`.
--
--@MainPath():8:6:
--f := fiber job.work()
--     ^~~~~~~~~~~~~~~~
--