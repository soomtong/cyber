use os

d := os.dirname('a/b')

--cytest: error
--CompileError: Can not find the symbol `dirname` in `os`. Use `path.dir` from `use path`.
--
--@MainPath():3:9:
--d := os.dirname('a/b')
--        ^~~~~~~
--
