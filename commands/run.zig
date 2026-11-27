const std = @import("std");
const Io = std.Io;
const config = @import("../config.zig");

pub const Options = struct {
    once: bool = false,
    case: ?[]const u8 = null,
    kernel: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

pub fn parseOptions(args: []const [:0]const u8, stderr: *Io.Writer) !Options {
    var options: Options = .{};
    var remaining = args;
    while (remaining.len > 0) {
        const arg = remaining[0];
        remaining = remaining[1..];

        if (std.mem.eql(u8, arg, "--once")) {
            options.once = true;
        } else if (std.mem.eql(u8, arg, "--case")) {
            const name = try takeValue(&remaining, arg, stderr);
            for (config.cases) |tc| {
                if (std.mem.eql(u8, tc.name, name)) break;
            } else {
                try stderr.print("unknown test case: {s}\navailable test cases:", .{name});
                for (config.cases) |tc| try stderr.print(" {s}", .{tc.name});
                try stderr.writeByte('\n');
                return error.InvalidArgument;
            }
            options.case = name;
        } else if (std.mem.eql(u8, arg, "--kernel")) {
            const name = try takeValue(&remaining, arg, stderr);
            for (config.kernels) |kernel| {
                if (std.mem.eql(u8, kernel.name, name)) break;
            } else {
                try stderr.print("unknown kernel: {s}\navailable kernels:", .{name});
                if (config.kernels.len == 0) try stderr.writeAll(" none");
                for (config.kernels) |kernel| try stderr.print(" {s}", .{kernel.name});
                try stderr.writeByte('\n');
                return error.InvalidArgument;
            }
            options.kernel = name;
        } else if (std.mem.eql(u8, arg, "--output")) {
            options.output = try takeValue(&remaining, arg, stderr);
        } else {
            try stderr.print("unknown option: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }
    return options;
}

fn takeValue(remaining: *[]const [:0]const u8, flag: []const u8, stderr: *Io.Writer) ![]const u8 {
    if (remaining.len == 0 or remaining.*[0].len == 0 or std.mem.startsWith(u8, remaining.*[0], "--")) {
        try stderr.print("{s} requires a value\n", .{flag});
        return error.InvalidArgument;
    }
    const value = remaining.*[0];
    remaining.* = remaining.*[1..];
    return value;
}

pub fn execute(io: Io, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    if (config.kernels.len == 0) {
        try stderr.writeAll("bench: no benchmark kernels configured\n");
        return error.NoKernels;
    }

    const allocator = std.heap.page_allocator;
    var table: Io.Writer.Allocating = .init(allocator);
    defer table.deinit();
    try table.writer.writeAll("case             kernel            M      N      K    time (ms)    GFLOP/s    speedup\n");

    var csv: ?Io.Writer.Allocating = null;
    defer if (csv) |*buffer| buffer.deinit();
    if (options.output != null) {
        csv = .init(allocator);
        try csv.?.writer.writeAll("case,kernel,M,N,K,ms,gflops\n");
    }
    try run(io, options, allocator, &table.writer, if (csv != null) &csv.?.writer else null, stderr);

    if (options.output) |path| {
        const file = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            try stderr.print("cannot open '{s}': {s}\n", .{ path, @errorName(err) });
            return error.InvalidArgument;
        };
        defer file.close(io);
        try file.writeStreamingAll(io, csv.?.written());
    } else {
        try stdout.writeAll(table.written());
    }
}

fn run(io: Io, options: Options, allocator: std.mem.Allocator, table: *Io.Writer, csv: ?*Io.Writer, stderr: *Io.Writer) !void {
    const total = if (options.case == null) config.cases.len else 1;
    var index: usize = 0;
    for (config.cases) |tc| {
        if (options.case) |name| {
            if (!std.mem.eql(u8, tc.name, name)) continue;
        }
        index += 1;
        try stderr.print("[{d}/{d}] {s} ({d}x{d}x{d})\n", .{ index, total, tc.name, tc.m, tc.n, tc.k });
        try runCase(io, tc, options, allocator, table, csv, stderr);
    }
}

fn runCase(io: Io, tc: config.Case, options: Options, allocator: std.mem.Allocator, table: *Io.Writer, csv: ?*Io.Writer, stderr: *Io.Writer) !void {
    const a = try allocator.alloc(f32, try std.math.mul(usize, tc.m, tc.k));
    defer allocator.free(a);
    const b = try allocator.alloc(f32, try std.math.mul(usize, tc.k, tc.n));
    defer allocator.free(b);
    const c = try allocator.alloc(f32, try std.math.mul(usize, tc.m, tc.n));
    defer allocator.free(c);
    const reference = try allocator.alloc(f32, c.len);
    defer allocator.free(reference);

    // Reset per case so filtering does not change its inputs.
    var seed: u32 = 0x12345678;
    fillRandom(a, &seed);
    fillRandom(b, &seed);
    computeReference(tc, a, b, reference);

    const progress = if (!options.once and (Io.File.stderr().isTty(io) catch false)) stderr else null;
    var baseline: f64 = 0;
    var is_first = true;
    for (config.kernels) |kernel| {
        if (options.kernel) |name| {
            if (!std.mem.eql(u8, kernel.name, name)) continue;
        }

        @memset(c, std.math.nan(f32));
        kernel.run(tc.m, tc.n, tc.k, a.ptr, b.ptr, c.ptr);
        for (c, reference, 0..) |actual, expected, i| {
            const tolerance = 1e-3 + 1e-3 * @abs(expected);
            if (!std.math.isFinite(actual) or @abs(actual - expected) > tolerance) {
                try stderr.print("{s}/{s}: mismatch at {d}, got {d}, expected {d}\n", .{
                    tc.name, kernel.name, i, actual, expected,
                });
                return error.IncorrectResult;
            }
        }

        const ns = try measure(io, kernel, tc, a, b, c, options.once, progress);
        const operations = 2.0 * asFloat(tc.m) * asFloat(tc.n) * asFloat(tc.k);
        const ms = ns / 1e6;
        const gflops = operations / ns;
        const first_result = is_first;
        if (is_first) {
            baseline = ns;
            is_first = false;
        }
        if (csv) |writer| try writer.print("{s},{s},{d},{d},{d},{d:.6},{d:.6}\n", .{
            tc.name, kernel.name, tc.m, tc.n, tc.k, ms, gflops,
        });
        if (first_result) {
            try table.print("{s: <16} {s: <16} {d: >4} {d: >6} {d: >6} {d: >12.4} {d: >11.3} {s: >10}\n", .{
                tc.name, kernel.name, tc.m, tc.n, tc.k, ms, gflops, "-",
            });
        } else {
            try table.print("{s: <16} {s: <16} {d: >4} {d: >6} {d: >6} {d: >12.4} {d: >11.3} ({d:.2}x)\n", .{
                tc.name, kernel.name, tc.m, tc.n, tc.k, ms, gflops, baseline / ns,
            });
        }
    }
}

fn fillRandom(matrix: []f32, seed: *u32) void {
    for (matrix) |*value| {
        seed.* = seed.* *% 1664525 +% 1013904223;
        const bits: f32 = @floatFromInt(seed.* >> 8);
        value.* = bits / 16777216.0 - 0.5;
    }
}

fn computeReference(tc: config.Case, a: []const f32, b: []const f32, reference: []f32) void {
    for (0..tc.m) |i| {
        for (0..tc.n) |j| {
            var sum: f64 = 0;
            for (0..tc.k) |p| {
                sum += @as(f64, a[i * tc.k + p]) * @as(f64, b[p * tc.n + j]);
            }
            reference[i * tc.n + j] = @floatCast(sum);
        }
    }
}

fn measure(io: Io, kernel: config.Kernel, tc: config.Case, a: []const f32, b: []const f32, c: []f32, once: bool, progress: ?*Io.Writer) !f64 {
    if (once) {
        const ns = runBatch(io, kernel.run, tc, a, b, c, 1);
        if (ns == 0) return error.InsufficientClockResolution;
        return asFloat(ns);
    }

    for (0..2) |_| kernel.run(tc.m, tc.n, tc.k, a.ptr, b.ptr, c.ptr);

    var iterations: usize = 1;
    while (true) : (iterations *= 2) {
        const elapsed = runBatch(io, kernel.run, tc, a, b, c, iterations);
        if (elapsed >= config.target_ns or iterations >= config.max_iterations) break;
    }

    var samples: [config.samples]f64 = undefined;
    if (progress) |writer| try printProgress(writer, kernel.name, 0);
    for (&samples, 1..) |*sample, completed| {
        const ns = runBatch(io, kernel.run, tc, a, b, c, iterations);
        sample.* = asFloat(ns) / asFloat(iterations);
        if (progress) |writer| try printProgress(writer, kernel.name, completed);
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    const median = samples[samples.len / 2];
    if (median == 0) return error.InsufficientClockResolution;
    return median;
}

fn printProgress(writer: *Io.Writer, name: []const u8, completed: usize) !void {
    try writer.print("\r  {s} [", .{name});
    for (0..config.samples) |i| {
        try writer.writeAll(if (i < completed) "█" else "░");
    }
    try writer.print("] {d}/{d}", .{ completed, config.samples });
    if (completed == config.samples) try writer.writeByte('\n');
    try writer.flush();
}

fn runBatch(io: Io, kernel: config.KernelFn, tc: config.Case, a: []const f32, b: []const f32, c: []f32, iterations: usize) i96 {
    const start = Io.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        kernel(tc.m, tc.n, tc.k, a.ptr, b.ptr, c.ptr);
        asm volatile ("" ::: .{ .memory = true });
    }
    return start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
}

fn asFloat(value: anytype) f64 {
    return @floatFromInt(value);
}
