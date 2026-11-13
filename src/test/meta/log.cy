use t 'test'
use meta

-- `meta.log` with a string at the top level of a file. The string was released twice,
-- which ended the compiler with a double free.
#meta.log('top level')
#meta.log(123)

#name := 'ct var'
#meta.log(name)

fn inside() -> int:
    #meta.log('in a function')
    #meta.log(true)
    return 1

t.eq(1, inside())

--cytest: pass