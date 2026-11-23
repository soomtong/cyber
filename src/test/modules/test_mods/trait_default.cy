-- A trait whose default methods are overloads of one name. `Show` leaves one overload to the type.
type Show trait:
    fn show() -> str:
        return self.show(0)
    fn show(indent int) -> str
    fn show(a int, b int) -> str:
        return self.show(a + b)

-- Every overload is a default method.
type Tag trait:
    fn tag() -> str:
        return self.tag(1)
    fn tag(n int) -> str:
        return 'tag%{n}'

-- A type of this module that gets the default overloads.
type Local:
    with Show
    n int

fn (&Local) show(indent int) -> str:
    return 'local%{self.n}@%{indent}'

fn via(s &Dyn[Show]) -> str:
    return s.show() + '|' + s.show(1, 2)
