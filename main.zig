const std = @import("std");
const Io = std.Io;

const help = @import("commands/help.zig");
const list = @import("commands/list.zig");
const run = @import("commands/run.zig");

const Command = union(enum) {
    help,
    list,
    run: run.Options,
};

pub fn main(init: std.process.Init) void {
    var stdout = Io.File.stdout().writerStreaming(init.io, &.{});
    var stderr = Io.File.stderr().writerStreaming(init.io, &.{});
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err| exitWithError(&stderr.interface, err);
    const command = parseArgs(args[1..], &stderr.interface) catch |err| exitWithError(&stderr.interface, err);
    const result = switch (command) {
        .help => help.execute(&stdout.interface),
        .list => list.execute(&stdout.interface),
        .run => |options| run.execute(init.io, options, &stdout.interface, &stderr.interface),
    };
    result catch |err| exitWithError(&stderr.interface, err);
}

fn exitWithError(stderr: *Io.Writer, err: anyerror) noreturn {
    if (err != error.InvalidArgument and err != error.NoKernels) {
        stderr.print("bench: {s}\n", .{@errorName(err)}) catch {};
    }
    std.process.exit(1);
}

fn parseArgs(args: []const [:0]const u8, stderr: *Io.Writer) !Command {
    if (args.len == 0) return .help;

    const name = args[0];
    if (std.mem.eql(u8, name, "run")) {
        return .{ .run = try run.parseOptions(args[1..], stderr) };
    }
    const command: Command = if (std.mem.eql(u8, name, "help"))
        .help
    else if (std.mem.eql(u8, name, "list"))
        .list
    else {
        try stderr.print("unknown command: {s}\n", .{name});
        return error.InvalidArgument;
    };
    if (args.len > 1) {
        try stderr.print("{s} does not accept arguments\n", .{name});
        return error.InvalidArgument;
    }
    return command;
}
