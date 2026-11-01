import time


def main() -> None:
    start = time.perf_counter()

    arr: list[int] = []
    for i in range(1_000_000):
        arr.append(i)

    total = 0
    for i in arr:
        total += i

    print(f"time: {(time.perf_counter() - start) * 1000}")
    print(total)


if __name__ == "__main__":
    main()
