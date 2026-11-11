type Box:
    f ?Fiber

fn entry(b ^Box):
    _ = b.f.?.resume()

b := ^Box{f=none}
b.f = fiber entry(b)
_ = b.f.?.resume()

--cytest: panic
--panic: Fiber is already running.
--
--[trace]
--@MainPath():9:5 main:
--_ = b.f.?.resume()
--    ^
--