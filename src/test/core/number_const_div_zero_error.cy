const k = 7
const z = k % (k - 7)
print(z)

--cytest: error
--CompileError: Division by zero.
--
--@MainPath():2:11:
--const z = k % (k - 7)
--          ^~~~~~~~~~~
--