use os

b := []byte{104, 105}
os.write_file('a.txt', b)!

--cytest: error
--CompileError: Expected argument `str`, found `[]byte`, when calling `fn write_file(str, str) -> !void`. Write bytes with `os.write_file_bytes`.
--
--@MainPath():4:24:
--os.write_file('a.txt', b)!
--                       ^
--