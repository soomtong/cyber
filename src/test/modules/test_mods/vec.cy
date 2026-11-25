type Vec2:
    x float
    y float

fn (&Vec2) `*`(s float) -> Vec2:
    return {x=self.x * s, y=self.y * s}

fn `*`(s float, v Vec2) -> Vec2:
    return {x=s * v.x, y=s * v.y}
