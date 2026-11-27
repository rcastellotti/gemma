pub const Case = struct {
    name: []const u8,
    m: usize,
    n: usize,
    k: usize,
};

pub const cases = [_]Case{
    .{ .name = "tiny", .m = 16, .n = 16, .k = 16 },
    .{ .name = "small", .m = 64, .n = 64, .k = 64 },
    // .{ .name = "medium", .m = 128, .n = 128, .k = 128 },
    // .{ .name = "large", .m = 256, .n = 256, .k = 256 },
    // .{ .name = "xlarge", .m = 512, .n = 512, .k = 512 },
    // Non-square matrices and awkward SIMD/tile tails.
    // .{ .name = "tall", .m = 512, .n = 64, .k = 256 },
    // .{ .name = "wide", .m = 64, .n = 256, .k = 512 },
    // .{ .name = "irregular", .m = 127, .n = 131, .k = 129 },
};

pub const KernelFn = *const fn (usize, usize, usize, [*]const f32, [*]const f32, [*]f32) callconv(.c) void;

extern fn gemm_ijk(usize, usize, usize, [*]const f32, [*]const f32, [*]f32) void;

pub const Kernel = struct { name: []const u8, run: KernelFn };
pub const kernels = [_]Kernel{
    .{ .name = "ijk", .run = &gemm_ijk },
};
