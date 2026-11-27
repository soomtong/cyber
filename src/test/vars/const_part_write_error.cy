-- A const is copied at each use: writing to an element would change only the copy.
const nums = [2]int{1, 2}

nums[0] = 5

--cytest: error
--CompileError: Cannot assign to a part of the constant `nums`. It is copied at each use; declare it with `global` to change it.
--
--@MainPath():4:1:
--nums[0] = 5
--^~~~~~~
--
