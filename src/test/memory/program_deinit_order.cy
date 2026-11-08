-- At the end of main, the main locals are destructed before the globals (`@program_deinit`),
-- so a local's `@deinit` can still read the globals. See `docs/decisions/project_program_deinit_order.md`.

global order int = 0
global log Log = Log{n=0}

type Local:
    n int
fn (&Local) @deinit():
    if order == 2:
        panic('Local destructed after the globals.')
    order = 1

type Log:
    n int
fn (&Log) @deinit():
    if order != 1:
        panic('Global destructed before the main locals.')
    order = 2

a := Local{n=1}
b := Local{n=2}

--cytest: pass
