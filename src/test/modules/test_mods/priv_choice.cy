-- A private choice with a managed payload: copying and destructing it expands core templates that read `T.Tag`.
-type Shape enum:
    case none
    case name  str
    case items []Shape

-type Holder:
    shapes []Shape

fn count_names() -> int:
    var h Holder = {shapes={Shape.name('a'), Shape.items({Shape.name('b'), Shape.none})}}
    copy := h
    var n int = 0
    for copy.shapes |s|:
        switch s:
            case .name: n += 1
            case .items |xs|: n += xs.len()
            else: pass
    return n
