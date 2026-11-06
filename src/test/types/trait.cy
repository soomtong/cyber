use test

type Shape trait:
    fn area() -> float

type Circle:
    with Shape
    radius float

fn (&Circle) area() -> float:
    return 3.14 * self.radius**2

type Rectangle:
    with Shape
    width  float
    height float

fn (&Rectangle) area() -> float:
    return self.width * self.height

var s ^Dyn[Shape] = ^Circle{radius=2}
test.eqNear(s.area(), 12.56)

s = ^Rectangle{width=4, height=5}
test.eq(s.area(), 20)

-- `^Dyn[Trait]` values in containers. The copy retains the impl object (F-74).
shapes := []^Dyn[Shape]{^Circle{radius=1}, ^Rectangle{width=2, height=3}}
shapes += ^Circle{radius=2}
var held ^Dyn[Shape] = ^Rectangle{width=1, height=5}
shapes += held
test.eq(4, shapes.len())
sum := 0.0
for shapes |shape|:
    sum += shape.area()
test.eqNear(3.14 + 6 + 12.56 + 5, sum)
test.eq(5.0, shapes[3].area())
test.eq(5.0, held.area())
arr := Array[^Dyn[Shape]]{}
arr.append(held)
arr.append(^Circle{radius=3})
test.eq(5.0, arr[0].area())
test.eqNear(28.26, arr[1].area())
held2 := held
test.eq(5.0, held2.area())

--cytest: pass