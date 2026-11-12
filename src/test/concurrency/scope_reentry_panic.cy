fn child(s ^Scope) -> !void:
    s.join()!

s := ^Scope.new()
s.start(child, {s})
s.join()!

--cytest: panic
--panic: The scope is already running its fibers.
--
--[trace]
--@MainPath():6:1 main:
--s.join()!
--^
--