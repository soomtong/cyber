// Copyright (c) 2023 Cyber (See LICENSE)

pub fn load(comptime Size: usize, comptime T: type, buf: []const T) @Vector(Size, T) {
    var arr: [Size]T = @splat(0);
    for (buf, 0..) |it, i| {
        arr[i] = it;
    }
    return arr;
}

