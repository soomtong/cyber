-- A fiber that is running can not be cancelled. Dropping the last reference to it inside its own function panics.
type Box:
    f ?Fiber

fn entry(b ^Box):
    b.f = none

b := ^Box{f=none}
b.f = fiber entry(b)
_ = b.f.?.resume()

--cytest: panic
--panic: Fiber is still in progress.
--
--[trace]
--@MainPath():10:5 main:
--_ = b.f.?.resume()
--    ^
--