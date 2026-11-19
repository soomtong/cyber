use math

--| Halves a number.
fn halve(n int) -> int:
    return n / 2

fn step(n int):
    suspend

fn work() -> !int:
    scope |s|:
        s.start(step, {1})
        return 1
    return 0

spare := halve(4)
total := halve(2) + 1
print(total)
