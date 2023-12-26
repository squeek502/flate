const std = @import("std");
const inflate = @import("inflate.zig").inflate;
const assert = std.debug.assert;

pub fn _main() !void {
    const argv = std.os.argv;
    if (argv.len == 1) return;

    const file_name = std.mem.span(argv[1]);
    var file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    var br = std.io.bufferedReader(file.reader());

    // const stdin = std.io.getStdIn();
    // var br = std.io.bufferedReader(stdin.reader());

    const stdout = std.io.getStdOut();
    var il = inflate(br.reader());
    while (true) {
        const buf = try il.read();
        if (buf.len == 0) return;
        try stdout.writeAll(buf);
    }
}

pub fn main() !void {
    const argv = std.os.argv;
    if (argv.len == 1) return;

    const file_name = std.mem.span(argv[1]);
    var file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    var br = std.io.bufferedReader(file.reader());

    // const stdin = std.io.getStdIn();
    // var br = std.io.bufferedReader(stdin.reader());

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut();
    var il = try std.compress.gzip.decompress(allocator, br.reader());
    var rdr = il.reader();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = rdr.readAll(&buf) catch |err| {
            if (err == error.EndOfStream) return;
            unreachable;
        };
        if (n == 0) return;
        try stdout.writeAll(buf[0..n]);
    }
}

const testing = std.testing;

test "BitReader" {
    var fbs = std.io.fixedBufferStream(&[_]u8{ 0xf3, 0x48, 0xcd, 0xc9, 0x00, 0x00 });
    var br = bitReader(fbs.reader());

    try testing.expectEqual(@as(u8, 32), br.eos);
    try testing.expectEqual(@as(u32, 0xc9cd48f3), br.bits);

    try testing.expect(try br.read(u1) == 0b0000_0001);
    try testing.expect(try br.read(u2) == 0b0000_0001);
    try testing.expectEqual(@as(u8, 32 - 3), br.eos);
    try testing.expectEqual(@as(u3, 5), br.align_bits);

    try testing.expect(try br.peek(u8) == 0b0001_1110);
    try testing.expect(try br.peek(u9) == 0b1_0001_1110);
    br.advance(9);
    try testing.expectEqual(@as(u8, 28), br.eos);
    try testing.expectEqual(@as(u3, 4), br.align_bits);

    try testing.expect(try br.read(u4) == 0b0100);
    try testing.expectEqual(@as(u8, 32), br.eos);
    try testing.expectEqual(@as(u3, 0), br.align_bits);

    br.advance(1);
    try testing.expectEqual(@as(u3, 7), br.align_bits);
    br.advance(1);
    try testing.expectEqual(@as(u3, 6), br.align_bits);
    br.alignToByte();
    try testing.expectEqual(@as(u3, 0), br.align_bits);
}

fn bitReader(reader: anytype) BitReader(@TypeOf(reader)) {
    return BitReader(@TypeOf(reader)).init(reader);
}

fn BitReader(comptime ReaderType: type) type {
    return struct {
        rdr: ReaderType,
        bits: u32 = 0, // buffer of 32 bits
        eos: u8 = 0, // end of stream position
        align_bits: u3 = 0, // number of bits to skip to byte alignment

        const Self = @This();

        pub fn init(rdr: ReaderType) Self {
            var self = Self{ .rdr = rdr };
            for (0..4) |byte| {
                const b = self.rdr.readByte() catch break;
                self.bits += @as(u32, b) << @as(u5, @intCast(byte * 8));
                self.eos += 8;
            }
            return self;
        }

        pub fn read(self: *Self, comptime U: type) !U {
            const u_bit_count: u4 = @bitSizeOf(U);
            if (u_bit_count > self.eos) return error.EndOfStream;
            const value: U = @truncate(self.bits);
            self.advance(u_bit_count);
            return value;
        }

        pub fn readByte(self: *Self) !u8 {
            const value: u8 = @truncate(self.bits);
            self.bits >> 8;
            self.moreBits();
            return value;
        }

        pub fn skipBytes(self: *Self, n: usize) !u8 {
            for (0..n) |_| {
                self.bits >> 8;
                self.moreBits();
            }
        }

        pub fn peek(self: *Self, comptime U: type) !U {
            const u_bit_count: u4 = @bitSizeOf(U);
            if (u_bit_count > self.eos) return error.EndOfStream;
            return @truncate(self.bits);
        }

        pub fn advance(self: *Self, bit_count: u4) void {
            assert(bit_count <= self.eos);
            for (0..bit_count) |_| {
                self.bits = self.bits >> 1;
                self.eos -= 1;
                if (self.eos == 24) { // refill upper byte
                    self.moreBits();
                }
                self.align_bits -%= 1;
            }
        }

        pub fn alignToByte(self: *Self) void {
            self.advance(self.align_bits);
            self.align_bits = 0;
        }

        fn moreBits(self: *Self) void {
            const b = self.rdr.readByte() catch return;
            self.bits += @as(u32, b) << 24;
            self.eos += 8;
        }
    };
}
