count := 0
inc := fn():
    count += 1

--cytest: error
--CompileError: Cannot assign to `count` in the lambda. The lambda keeps a copy of it from when it was created; declare it with `^T` to share it with the lambda.
--
--@MainPath():3:5:
--    count += 1
--    ^~~~~
--
