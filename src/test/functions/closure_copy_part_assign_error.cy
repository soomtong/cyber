type Point:
    x int
    y int

p := Point{x=1, y=2}
move_x := fn():
    p.x = 3

--cytest: error
--CompileError: Cannot assign to a part of `p` in the lambda. The lambda keeps a copy of it from when it was created; declare it with `^T` to share it with the lambda.
--
--@MainPath():7:5:
--    p.x = 3
--    ^~~
--
