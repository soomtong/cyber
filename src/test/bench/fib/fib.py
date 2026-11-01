import time


def fib(n: int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


def main() -> None:
    start = time.perf_counter()
    res = fib(30)
    print(f"time: {(time.perf_counter() - start) * 1000}")
    print(res)


if __name__ == "__main__":
    main()
