use os

ok := os.fileExists('a')

--cytest: error
--CompileError: Can not find the symbol `fileExists` in `os`. Did you mean `file_exists`?
--
--@MainPath():3:10:
--ok := os.fileExists('a')
--         ^~~~~~~~~~
--
