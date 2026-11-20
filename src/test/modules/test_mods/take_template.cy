-- The body of this template is checked with the chunk of the module that uses it. The comment lines keep the body
-- past the end of a short source that imports it, where the compiler once sliced the wrong source.
-- ....................................................................................................................
-- ....................................................................................................................
-- ....................................................................................................................
-- ....................................................................................................................
global store []int = {}

fn push_all[T Any](p Ptr[[]T], a T, b T):
    p.*.append(a)
    p.*.append(b)
    store.append(store.len())
    store.append(p.*.len())

fn total() -> int:
    return store.len()
