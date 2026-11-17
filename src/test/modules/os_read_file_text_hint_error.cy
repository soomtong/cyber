use os

var s str = os.read_file_bytes('a.txt')!

--cytest: error
--CompileError: Expected type `str`, got `[]byte`. `os.read_file_bytes` returns `[]byte`. Read text with `os.read_file`.
--
--@MainPath():3:13:
--var s str = os.read_file_bytes('a.txt')!
--            ^~~~~~~~~~~~~~~~~~~~~~~~~~~~
--