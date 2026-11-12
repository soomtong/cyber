use test

-- A `main` that returns a result without an error ends the program normally.
fn main() -> !void:
    test.eq(try_add(1, 2)!, 3)

fn try_add(a int, b int) -> !int:
    return a + b

--cytest: pass