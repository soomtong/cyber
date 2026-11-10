use t 'test'

type Animal enum:
    case bear
    case tiger

-- enum to int.
n := Animal.tiger
t.eq(1, as n)

-- Using enum declared afterwards.
n2 := Animal2.tiger
t.eq(1, as n2)

-- Reassign using symbol literal.
n2 = Animal2.tiger
n2 = .dragon
t.eq(2, as n2)

type Animal2 enum:
    case bear
    case tiger
    case dragon

-- An enum converts to an int with the value of its case.
type Fruit enum:
    case apple
    case orange
    case banana
    case kiwi
fruit := Fruit.kiwi
t.eq(3, int(fruit))
t.eq(0, int(Fruit.apple))
t.eq(i8(2), i8(Fruit.banana))
t.eq(i32(3), i32(fruit))
t.eq(4, int(fruit) + 1)

--cytest: pass