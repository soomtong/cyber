generator fn numbers() -> int:
    yield 1
    suspend
    yield 2

fn consume():
    for numbers() |n|:
        pass

fn start():
    f := fiber consume()
    _ = f.resume()

start()

--cytest: panic
--panic: Fiber is still in progress.
--
--[trace]
--@MainPath():14:1 main:
--start()
--^
--