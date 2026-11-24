use t 'test'
use c

-- A variadic extern function takes the arguments of every type that maps to C (F-204). An `int` argument ended
-- the host with `'Int_0' undeclared` and 'Failed to compile c source.': the C glue of the variant did not declare
-- the types of its arguments.
#c.bind_lib(none)

#[extern]
fn snprintf(buf Ptr[byte], size r64, format Ptr[byte], args c.variadic) -> i32

buf := c.to_strz('________________________________')

t.eq(2, snprintf(buf, 32, c.to_strz('%lld'), 42))
t.eq('42', c.from_strz(buf))

-- Every width of `int`, `float`, `raw`, `bool`, mixed in one call.
_ = snprintf(buf, 32, c.to_strz('%lld %d %d %d'), -3, i8(-2), i16(300), i32(7))
t.eq('-3 -2 300 7', c.from_strz(buf))
_ = snprintf(buf, 32, c.to_strz('%.1f %.2f'), 2.5, f32(1.25))
t.eq('2.5 1.25', c.from_strz(buf))
_ = snprintf(buf, 32, c.to_strz('%llu %u %u %d'), r64(9), r32(8), r16(6), true)
t.eq('9 8 6 1', c.from_strz(buf))

-- A pointer argument.
_ = snprintf(buf, 32, c.to_strz('<%s>'), c.to_strz('ok'))
t.eq('<ok>', c.from_strz(buf))

--cytest: pass
