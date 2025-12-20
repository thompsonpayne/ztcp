const std = @import("std");

pub fn main() my_error!void {
    // u8, u16, u32, u64,
    // i8, i16, i32, i64,
    // usize, isize
    const str = "Hello";
    std.debug.print("str: {s}\n", .{str});
    return error.NotFound;
}

const my_error = error{
    NotFound,
    Internal,
};
