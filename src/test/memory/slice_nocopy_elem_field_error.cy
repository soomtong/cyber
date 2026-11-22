type Tree:
    with NoCopy
    kids []Tree

--cytest: error
--CompileError: A slice `[]Tree` copies its elements, so the element type `Tree` can not be `NoCopy`. Use `Array[Tree]`, which moves them.
--
--@MainPath():3:10:
--    kids []Tree
--         ^~~~~~
--@MainPath():1:1:
--type Tree:
--^~~~~~~~~~
--
