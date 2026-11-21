-- A name from another language is mapped to the module's name.
use path
print(path.basename('a/b.py'))

--cytest: error
--CompileError: Can not find the symbol `basename` in `path`. Did you mean `base`?
--
--@MainPath():3:12:
--print(path.basename('a/b.py'))
--           ^~~~~~~~
--