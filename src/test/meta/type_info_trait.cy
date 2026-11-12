use test
use meta

type Shape trait:
    fn area() -> float

type Square:
    with Shape
    side float

fn (&Square) area() -> float:
    return self.side * self.side

-- `type.info` at the top level, before anything else used `TypeInfo`.
#shape_info := type.info(Shape)
#int_info := type.info(int)

fn kind(%T type) -> str:
    #switch type.info(T):
        #case .trait |trait_t|:
            return 'trait ' + #{trait_t.name}
        #case .struct |struct_t|:
            return 'struct'
        #else:
            return 'other'

fn trait_name() -> str:
    #info := type.info(Shape).!trait
    return #{info.name}

test.eq(kind(Shape), 'trait Shape')
test.eq(kind(Square), 'struct')
test.eq(kind(int), 'other')
test.eq(trait_name(), 'Shape')

--cytest: pass
