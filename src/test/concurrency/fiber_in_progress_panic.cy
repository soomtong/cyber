-- A fiber that is suspended in a destructor is cancelled when it is destructed. The cancel destructs the other
-- values of the frame. A destructor that suspends again panics.
type Res:
    id int

fn (&Res) @deinit():
    suspend

fn work():
    a := ^Res{id = 1}
    b := ^Res{id = 2}

fn start():
    f := fiber work()
    _ = f.resume()

start()

--cytest: panic
--panic: A fiber was suspended while it was cancelled.
--
--[trace]
--@MainPath():17:1 main:
--start()
--^
--