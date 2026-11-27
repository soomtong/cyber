use test

-- A `?T` target infers `.case` from `T`.
type Mode enum:
    case payment
    case payoff

fn parse(text str) -> ?Mode:
    if text == 'payment':
        return .payment
    if text == 'payoff':
        return .payoff
    return none

test.eq(parse('payment').?, Mode.payment)
test.eq(parse('payoff').?, Mode.payoff)
test.assert(parse('x') == none)
var m ?Mode = .payoff
test.eq(m.?, Mode.payoff)
m = .payment
test.eq(m.?, Mode.payment)

--cytest: pass
