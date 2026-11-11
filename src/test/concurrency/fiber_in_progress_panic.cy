fn forever():
    while true:
        suspend

fn start():
    f := fiber forever()
    _ = f.resume()

start()

--cytest: panic
--panic: Fiber is still in progress.
--
--[trace]
--@MainPath():9:1 main:
--start()
--^
--