-- The same for a generic method whose exclusive receiver owns the argument.
type Bag:
    items Array[int]

fn (&&Bag) add_from(r %R) -> int:
    self.items << 4
    return r.*

b := Bag{items=Array[int]{1, 2, 3}}
print(b.add_from(&b.items[0]))

--cytest: error
--CompileError: Cannot pass an exclusive borrow of `b` with another argument that borrows `b`.
--
--@MainPath():10:7:
--print(b.add_from(&b.items[0]))
--      ^
--
