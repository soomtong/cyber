use test

-- A generic function can take an exclusive borrow next to borrows of other locals.

fn read_after_grow(%T type, r &T, b &&Array[T]) -> T:
    b << r.*
    return r.*

fn sum(%T type, r &T, b &Array[T]) -> int:
    return b.len()

fn run(k int):
    a := Array[int]{1, 2, 3}
    b := Array[int]{9}
    y := 7

    test.eq(9, read_after_grow(int, &b[0], &&a))
    test.eq(4, a.len())
    test.eq(7, read_after_grow(int, if (k == 2) &y else &b[0], &&a))
    test.eq(5, a.len())
    -- Shared borrows of the same local can be passed together.
    test.eq(5, sum(int, &a[0], &a))

run(2)

--cytest: pass
