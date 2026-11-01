import time


def main() -> None:
    s = "abcdefghijklmnopqrstuvwxyz123456" * 1_000_000 + "waldo"

    start = time.perf_counter()
    idx = 0
    for _ in range(50):
        idx = s.index("waldo")

    print(f"time: {(time.perf_counter() - start) * 1000}")
    print(idx)


if __name__ == "__main__":
    main()
