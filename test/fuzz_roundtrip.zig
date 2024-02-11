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

    // Choose a pseudo-random level using the hash of the data
    const hash = std.hash.Wyhash.hash(0, data);
    const levels = [_]flate.raw.Level{ .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };
    const level_index: usize = @intCast(hash % levels.len);
    const level = levels[level_index];
    std.debug.print("{}\n", .{level});

    // Compress the data
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try flate.raw.compress(reader, buf.writer(), level);

    // Now try to decompress it
    var buf_fbs = std.io.fixedBufferStream(buf.items);
    var inflate = flate.raw.decompressor(buf_fbs.reader());
    const inflated = inflate.reader().readAllAlloc(allocator, std.math.maxInt(usize)) catch {
        return;
    };
    defer allocator.free(inflated);

    try std.testing.expectEqualSlices(u8, data, inflated);
}
