-- Copies of a slice share one buffer, so a slice cannot be a const.
const names = []str{'a', 'b'}

--cytest: error
--CompileError: A slice cannot be a constant: its copies share one buffer. Use a fixed array `[2]str`, or `global` for a value that changes.
--
--@MainPath():2:15:
--const names = []str{'a', 'b'}
--              ^~~~~~~~~~~~~~~
--
