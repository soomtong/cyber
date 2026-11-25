for {1, 2} |x|:
    print(x)
else |err|:
    print(err)

--cytest: error
--CompileError: An `else` block of `for` handles the error of an iterator that can fail, and `next` returns `?int`. Remove the `else` block.
--
--@MainPath():3:1:
--else |err|:
--^~~~~~~~~~~
--