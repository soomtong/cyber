type Info:
    a int
    -b int = 0

fn (&Info) sum() -> int:
    return self.a + self.b

-fn (&Info) hidden_sum() -> int:
    return self.a * self.b

-type Hidden:
    v int

-type HiddenT[T Any]:
    v T

type Box[T Any]:
    v T
    -tag int = 0

fn (&Box[]) tag_of() -> int:
    return self.tag

-fn (&Box[]) peek() -> T:
    return self.v

-global counter int = 1

-const LIMIT = 3

-fn secret() -> int:
    return 7

fn reveal() -> int:
    i := Info{a=1, b=2}
    h := Hidden{v=counter}
    ht := HiddenT[int]{v=1}
    b := Box[int]{v=5, tag=1}
    return secret() + i.b + i.hidden_sum() + h.v + ht.v + LIMIT + b.tag + b.peek()
