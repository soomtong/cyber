global last_id int = 100
global name str = 'lib'.upper()

fn next_id() -> int:
    last_id += 1
    return last_id

fn label() -> str:
    return name + '!'
