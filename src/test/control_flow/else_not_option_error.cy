text := 'a'
print(text.ends_with('a') ?else false)

--cytest: error
--CompileError: Expected type instance of `Option`, found `bool`. This value is `bool`, not an option. Remove `?else false`.
--
--@MainPath():2:7:
--print(text.ends_with('a') ?else false)
--      ^~~~~~~~~~~~~~~~~~~
--