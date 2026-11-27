const std = @import("std");
const Io = std.Io;

const help =
    \\GEMMA3 benchmark - by rcastellotti.dev
    \\usage: bench
    \\       bench <help|list>
    \\       bench run [OPTIONS]
    \\
    \\commands:
    \\  help             show this help
    \\  list             list test cases and kernels
    \\  run              run the benchmark
    \\
    \\run options:
    \\  --output <FILE>  write results as CSV to FILE
    \\  --case <NAME>    run only the named test case
    \\  --kernel <NAME>  run only the named kernel
    \\
;

pub fn execute(writer: *Io.Writer) !void {
    try writer.writeAll(help);
}
