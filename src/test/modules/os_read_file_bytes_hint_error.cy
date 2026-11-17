use os

fn copy(src str, dst str) -> !void:
    data := os.read_file(src)!
    os.write_file_bytes(dst, data)!

copy('a.txt', 'b.txt')!

--cytest: error
--CompileError: Expected argument `[]byte`, found `str`, when calling `fn write_file_bytes(str, []byte) -> !void`. `os.read_file` returns `str`. Read bytes with `os.read_file_bytes`.
--
--@MainPath():5:30:
--    os.write_file_bytes(dst, data)!
--                             ^~~~
--