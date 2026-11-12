-- A fiber that is suspended in the destructor of a reference can not be cancelled.
type Res:
    id int

fn (&Res) @deinit():
    suspend

fn work():
    r := ^Res{id = 1}

fn start():
    f := fiber work()
    _ = f.resume()

start()

--cytest: panic
--panic: Fiber is still in progress.
--
--[trace]
--@MainPath():15:1 main:
--start()
--^
--