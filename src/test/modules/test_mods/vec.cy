type Vec2:
    x float
    y float

fn (&Vec2) `*`(s float) -> Vec2:
    return {x=self.x * s, y=self.y * s}

fn `*`(s float, v Vec2) -> Vec2:
    return {x=s * v.x, y=s * v.y}

-- The left operand is of a type of another module: found from the type of the right operand.
fn `*`(s str, v Vec2) -> Vec2:
    return {x=v.x * float(s.len()), y=v.y * float(s.len())}
