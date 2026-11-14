out := ^[]str{}
out += 'x'

--cytest: error
--CompileError: Expected type `^[]str`, got `[]str`. To change the value that `out` points to, write `out.* += ...`.
--
--@MainPath():2:1:
--out += 'x'
--^~~~~~~~~~
--