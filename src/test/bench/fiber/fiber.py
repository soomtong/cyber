import time
from collections.abc import Iterator


def main() -> None:
    start = time.perf_counter()
    count = 0

    def inc() -> Iterator[None]:
        nonlocal count
        count += 1
        yield
        count += 1

    gens: list[Iterator[None]] = []
    for _ in range(100_000):
        g = inc()
        next(g)
        gens.append(g)

    for g in gens:
        next(g, None)

    print(f"time: {(time.perf_counter() - start) * 1000}")
    print(count)


if __name__ == "__main__":
    main()
