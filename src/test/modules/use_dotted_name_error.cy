use os
use os.read_file

--cytest: error
--CompileError: Expected a module name. A symbol of a module is used through an alias: `use read_file = os.read_file`.
--
--@MainPath():2:1:
--use os.read_file
--^~~~~~~~~~~~~~~~
--
