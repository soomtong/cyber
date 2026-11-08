use test

-- `const` template parameters of type `bool`, `EvalStr` and enum (F-28).
-- Before the fix, `Flag[true]` panicked the compiler in the instance cache hash,
-- `Tag['a']` and `ByLvl[.high]` panicked when the type name was printed, and the
-- `EvalStr` argument was released twice.

type Lvl enum:
    case low
    case high

type Flag[const B bool]:
    v int

fn (&Flag[]) pick(a int, b int) -> int:
    #if B:
        return a
    #else:
        return b

type Tag[const S EvalStr]:
    v int

fn (&Tag[]) name() -> str:
    return S

type ByLvl[const L Lvl]:
    v int

fn (&ByLvl[]) high() -> bool:
    #if L == .high:
        return true
    #else:
        return false

type Small[const N byte]:
    v int

fn g[const S EvalStr]() -> str:
    return S

fn h[const B bool]() -> int:
    #if B:
        return 1
    #else:
        return 0

fn k[const L Lvl]() -> str:
    #if L == Lvl.low:
        return 'low'
    #else:
        return 'high'

-- bool
f := Flag[true]{v=1}
test.eq(1, f.pick(1, 2))
f2 := Flag[false]{v=1}
test.eq(2, f2.pick(1, 2))
test.eq('Flag[true]', type.name(Flag[true]))
test.eq('Flag[false]', type.name(Flag[false]))
test.eq(false, #{Flag[true] == Flag[false]})
test.eq(true, #{Flag[true] == Flag[true]})

-- EvalStr
t := Tag['abc']{v=2}
test.eq('abc', t.name())
test.eq("Tag['abc']", type.name(Tag['abc']))
test.eq(false, #{Tag['a'] == Tag['b']})
test.eq(true, #{Tag['a'] == Tag['a']})

-- enum
b := ByLvl[.high]{v=3}
test.eq(true, b.high())
b2 := ByLvl[Lvl.low]{v=3}
test.eq(false, b2.high())
test.eq('ByLvl[Lvl.high]', type.name(ByLvl[.high]))
test.eq(false, #{ByLvl[.high] == ByLvl[.low]})
test.eq(true, #{ByLvl[.high] == ByLvl[Lvl.high]})

-- Narrow integers.
test.eq('Small[3]', type.name(Small[3]))
test.eq(false, #{Small[3] == Small[4]})

-- Function templates take the same parameter kinds.
test.eq('xy', g['xy']())
test.eq(1, h[true]())
test.eq(0, h[false]())
test.eq('low', k[.low]())
test.eq('high', k[Lvl.high]())

--cytest: pass
