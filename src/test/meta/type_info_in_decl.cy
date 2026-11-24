use t 'test'

-- `type.info` in a template that a declaration names (the type of a field) runs before the declarations of the
-- `meta` module are resolved. It ended the host with panic 'No such field `name`.': the info types of `meta`
-- (`StructField`, `EnumCase`, ...) were found but not resolved.
type P:
    a int
    b str

type E enum:
    case one
    case two
    case three

type Ch enum:
    case n int
    case s str

type StructOf[T Any] const:
    if type.info(T).!struct.fields.len() == 2:
        return int
    return str

type EnumOf[T Any] const:
    if type.info(T).!enum.cases.len() == 3:
        return float
    return str

type ChoiceOf[T Any] const:
    if type.info(T).!choice.cases.len() == 2:
        return bool
    return str

type H:
    s StructOf[P]
    e EnumOf[E]
    c ChoiceOf[Ch]

h := H{s=3, e=2.5, c=true}
t.eq(3, h.s)
t.eq(2.5, h.e)
t.eq(true, h.c)

--cytest: pass
