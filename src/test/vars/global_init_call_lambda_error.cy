global a int = smallest()
global bias int = 7

fn smallest() -> int:
    arr := []int{3, 1, 2}
    arr.sort(|x, y| x + bias < y + bias)
    return arr[0]

--cytest: error
--CompileError: The initializer of `a` can reach a lambda, which accesses the global `bias`. `bias` is initialized after `a`.
--
--@MainPath():1:16:
--global a int = smallest()
--               ^~~~~~~~~~
--
