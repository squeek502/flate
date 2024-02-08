const std = @import("std");
const flate = @import("flate");

pub export fn main() void {
    zigMain() catch unreachable;
}

pub fn zigMain() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Read the data from stdin
    const stdin = std.io.getStdIn();
    const data = try stdin.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(data);

    var fbs = std.io.fixedBufferStream(data);
    const reader = fbs.reader();

    // Compress the data
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    // TODO: vary the level
    try flate.raw.compress(reader, buf.writer(), .default);

    // Now try to decompress it
    var buf_fbs = std.io.fixedBufferStream(buf.items);
    var inflate = flate.raw.decompressor(buf_fbs.reader());
    const inflated = inflate.reader().readAllAlloc(allocator, std.math.maxInt(usize)) catch {
        return;
    };
    defer allocator.free(inflated);

    try std.testing.expectEqualSlices(u8, data, inflated);
}
