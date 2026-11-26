const k = int.max + 1
print(k)

--cytest: error
--CompileError: Integer overflow.
--
--@MainPath():1:11:
--const k = int.max + 1
--          ^~~~~~~~~~~
--