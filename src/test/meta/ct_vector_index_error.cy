fn h() -> int:
    v := [3]int(1)
    v[3] += 1
    return v[0]

const z = h()

--cytest: error
--CompileError: Index out of bounds. Index `3` is not in range `0..3`.
--
--@MainPath():3:7:
--    v[3] += 1
--      ^
--@MainPath():6:11:
--const z = h()
--          ^~~
--
