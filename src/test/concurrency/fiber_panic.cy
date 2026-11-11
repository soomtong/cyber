fn boom(x int):
    suspend
    panic('boom')

fn entry(x int):
    boom(x)

fn driver():
    f := fiber entry(7)
    _ = f.resume()
    _ = f.resume()

driver()

--cytest: panic
--panic: boom
--
--[trace]
--@MainPath():11:9 driver:
--    _ = f.resume()
--        ^
--@MainPath():13:1 main:
--driver()
--^
--