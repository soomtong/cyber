#switch 1:
    #case 1:
        print('one')
    #else:
        print('other')

--cytest: error
--CompileError: Only compile-time statements are allowed in this context.
--
--@MainPath():3:9:
--        print('one')
--        ^~~~~~~~~~~~
--