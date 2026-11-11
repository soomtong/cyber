type E enum:
    case a
var x E = .  a

--cytest: error
--ParseError: Expected the name right after `.`.
--
--@MainPath():3:11:
--var x E = .  a
--          ^
--
