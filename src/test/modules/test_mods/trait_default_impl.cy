-- Types that get the default overloads of a trait that another module declares.
use td './trait_default.cy'

type Far:
    with td.Show
    n int

fn (&Far) show(indent int) -> str:
    return 'far%{self.n}@%{indent}'

-- Declares one of the default overloads itself. The other default reaches it.
type FarTag:
    with td.Tag

fn (&FarTag) tag(n int) -> str:
    return 'far-tag%{n}'

type FarBoth:
    with td.Show
    with td.Tag

fn (&FarBoth) show(indent int) -> str:
    return 'both@%{indent}'

fn far_dyn(n int) -> ^Dyn[td.Show]:
    return ^Far{n=n}
