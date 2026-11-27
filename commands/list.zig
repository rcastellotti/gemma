const std = @import("std");
const Io = std.Io;
const config = @import("../config.zig");

pub fn execute(writer: *Io.Writer) !void {
    try writer.writeAll("test cases (M x N x K):\n");
    for (config.cases) |tc| {
        try writer.print("  {s}: {d} x {d} x {d}\n", .{ tc.name, tc.m, tc.n, tc.k });
    }
}
