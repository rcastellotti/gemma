const std = @import("std");
const Io = std.Io;

const help =
    \\GEMMA3 benchmark - by rcastellotti.dev
    \\usage: bench
    \\       bench <help|list>
    \\
    \\commands:
    \\  help             show this help
    \\  list             list test cases
    \\
;

pub fn execute(writer: *Io.Writer) !void {
    try writer.writeAll(help);
}
