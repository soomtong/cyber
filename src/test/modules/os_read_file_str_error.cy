use os

s := os.read_file_str('a.txt')!

--cytest: error
--CompileError: Can not find the symbol `read_file_str` in `os`. Use `os.read_file`. It returns `str`.
--
--@MainPath():3:9:
--s := os.read_file_str('a.txt')!
--        ^~~~~~~~~~~~~
--