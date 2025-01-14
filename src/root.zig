/// Deflate is a lossless data compression file format that uses a combination
/// of LZ77 and Huffman coding.
pub const deflate = @import("deflate.zig");

/// Inflate is the decoding process that takes a Deflate bitstream for
/// decompression and correctly produces the original full-size data or file.
pub const inflate = @import("inflate.zig");

/// Container defines header/footer arround deflate bit stream. Gzip and zlib
/// compression algorithms are containers arround deflate bit stream body.
const Container = @import("container.zig").Container;

fn byContainer(comptime container: Container) type {
    return struct {
        /// Decompress compressed data from reader and write plain data to the writer.
        pub fn decompress(reader: anytype, writer: anytype) !void {
            try inflate.decompress(container, reader, writer);
        }

        /// Decompressor type
        pub fn Decompressor(comptime ReaderType: type) type {
            return inflate.Inflate(container, ReaderType);
        }

        /// Create Decompressor which will read compressed data from reader.
        pub fn decompressor(reader: anytype) Decompressor(@TypeOf(reader)) {
            return inflate.decompressor(container, reader);
        }

        /// Compression level, trades between speed and compression size.
        pub const Level = deflate.Level;

        /// Compress plain data from reader and write compressed data to the writer.
        pub fn compress(reader: anytype, writer: anytype, level: Level) !void {
            try deflate.compress(container, reader, writer, level);
        }

        /// Compressor type
        pub fn Compressor(comptime WriterType: type) type {
            return deflate.Compressor(container, WriterType);
        }

        /// Create Compressor which outputs compressed data to the writer.
        pub fn compressor(writer: anytype, level: Level) !Compressor(@TypeOf(writer)) {
            return try deflate.compressor(container, writer, level);
        }

        pub fn HuffmanOnlyCompressor(comptime WriterType: type) type {
            return deflate.HuffmanOnlyCompressor(container, WriterType);
        }

        /// Disables Lempel-Ziv match searching and only performs Huffman
        /// entropy encoding. Results in faster compression, much less memory
        /// requirements during compression but bigger compressed sizes.
        pub fn huffmanOnlyCompressor(writer: anytype) !HuffmanOnlyCompressor(@TypeOf(writer)) {
            return deflate.huffmanOnlyCompressor(container, writer);
        }

        /// Compress plain data from reader and write them to the writer using
        /// huffman only compression algorithm.
        pub fn compressHuffmanOnly(reader: anytype, writer: anytype) !void {
            var cmp = try huffmanOnlyCompressor(writer);
            var buf: [1024 * 64]u8 = undefined;
            while (true) {
                const n = try reader.readAll(&buf);
                if (n == 0) break;
                try cmp.writeBlock(buf[0..n]);
                if (n < buf.len) break;
            }
            try cmp.close();
        }
    };
}

pub const raw = byContainer(.raw);
pub const gzip = byContainer(.gzip);
pub const zlib = byContainer(.zlib);

test {
    _ = @import("deflate.zig");
    _ = @import("inflate.zig");
}

const std = @import("std");
const testing = std.testing;

test "decompress" {
    const deflate_block = [_]u8{
        0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff, // deflate fixed buffer header len, nlen
        'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a, // non compressed data
    };
    const gzip_block =
        [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 } ++ // gzip header (10 bytes)
        deflate_block ++
        [_]u8{ 0xd5, 0xe0, 0x39, 0xb7, 0x0c, 0x00, 0x00, 0x00 }; // gzip footer checksum (4 byte), size (4 bytes)
    const zlib_block = [_]u8{ 0x78, 0b10_0_11100 } ++ // zlib header (2 bytes)}
        deflate_block ++
        [_]u8{ 0x1c, 0xf2, 0x04, 0x47 }; // zlib footer: checksum

    const expected = "Hello world\n";

    var raw_in = std.io.fixedBufferStream(&deflate_block);
    var gzip_in = std.io.fixedBufferStream(&gzip_block);
    var zlib_in = std.io.fixedBufferStream(&zlib_block);

    // raw deflate
    {
        var out = std.ArrayList(u8).init(testing.allocator);
        defer out.deinit();

        try raw.decompress(raw_in.reader(), out.writer());
        try testing.expectEqualStrings(expected, out.items);
    }
    // gzip
    {
        var out = std.ArrayList(u8).init(testing.allocator);
        defer out.deinit();

        try gzip.decompress(gzip_in.reader(), out.writer());
        try testing.expectEqualStrings(expected, out.items);
    }
    // zlib
    {
        var out = std.ArrayList(u8).init(testing.allocator);
        defer out.deinit();

        try zlib.decompress(zlib_in.reader(), out.writer());
        try testing.expectEqualStrings(expected, out.items);
    }

    // raw with decompressor interface
    {
        raw_in.reset();
        var cmp = raw.decompressor(raw_in.reader());
        try testing.expectEqualStrings(expected, (try cmp.next()).?);
        try testing.expect((try cmp.next()) == null);
    }
    var buf: [128]u8 = undefined;
    // raw with decompressor reader interface
    {
        raw_in.reset();
        var cmp = raw.decompressor(raw_in.reader());
        var rdr = cmp.reader();
        const n = try rdr.readAll(&buf);
        try testing.expectEqualStrings(expected, buf[0..n]);
    }
    // gzip decompressor
    {
        gzip_in.reset();
        var cmp = gzip.decompressor(gzip_in.reader());
        var rdr = cmp.reader();
        const n = try rdr.readAll(&buf);
        try testing.expectEqualStrings(expected, buf[0..n]);
    }
    // zlib decompressor
    {
        zlib_in.reset();
        var cmp = zlib.decompressor(zlib_in.reader());
        var rdr = cmp.reader();
        const n = try rdr.readAll(&buf);
        try testing.expectEqualStrings(expected, buf[0..n]);
    }
}

test "compress/decompress" {
    const fixedBufferStream = std.io.fixedBufferStream;

    var cmp_buf: [32 * 1024]u8 = undefined; // compressed data buffer
    var dcm_buf: [64 * 1024]u8 = undefined; // decompressed data buffer

    const levels = [_]deflate.Level{ .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };
    const cases = [_]struct {
        data: []const u8, // uncompressed content
        gzip_sizes: [levels.len]usize, // compressed data sizes per level 4-9
        huffman_only_size: usize,
    }{
        .{
            .data = @embedFile("testdata/rfc1951.txt"),
            .gzip_sizes = [_]usize{ 11513, 11217, 11139, 11126, 11122, 11119 },
            .huffman_only_size = 20291,
        },
    };

    // helper for printing sizes
    // for (cases, 0..) |case, i| {
    //     const data = case.data;
    //     std.debug.print("\ncase[{d}]: ", .{i});
    //     for (4..10) |ilevel| {
    //         var original = fixedBufferStream(data);
    //         var compressed = fixedBufferStream(&cmp_buf);
    //         try compress(.gzip, original.reader(), compressed.writer(), .{ .level = @enumFromInt(ilevel) });
    //         std.debug.print("{d}, ", .{compressed.pos});
    //     }
    // }
    // std.debug.print("\n", .{});

    for (cases) |case| { // for each case
        const data = case.data;

        for (levels, 0..) |level, i| { // for each compression level
            const gzip_size = case.gzip_sizes[i];

            inline for (Container.list) |container| { // for each wrapping
                const compressed_size = gzip_size - Container.gzip.size() + container.size();

                // compress original stream to compressed stream
                {
                    var original = fixedBufferStream(data);
                    var compressed = fixedBufferStream(&cmp_buf);
                    try deflate.compress(container, original.reader(), compressed.writer(), level);
                    try testing.expectEqual(compressed_size, compressed.pos);
                }
                // decompress compressed stream to decompressed stream
                {
                    var compressed = fixedBufferStream(cmp_buf[0..compressed_size]);
                    var decompressed = fixedBufferStream(&dcm_buf);
                    try inflate.decompress(container, compressed.reader(), decompressed.writer());
                    try testing.expectEqualSlices(u8, data, decompressed.getWritten());
                }

                // compressor writer interface
                {
                    var compressed = fixedBufferStream(&cmp_buf);
                    var cmp = try deflate.compressor(container, compressed.writer(), level);
                    var cmp_wrt = cmp.writer();
                    try cmp_wrt.writeAll(data);
                    try cmp.close();

                    try testing.expectEqual(compressed_size, compressed.pos);
                }
                // decompressor reader interface
                {
                    var compressed = fixedBufferStream(cmp_buf[0..compressed_size]);
                    var dcm = inflate.decompressor(container, compressed.reader());
                    var dcm_rdr = dcm.reader();
                    const n = try dcm_rdr.readAll(&dcm_buf);
                    try testing.expectEqual(data.len, n);
                    try testing.expectEqualSlices(u8, data, dcm_buf[0..n]);
                }
            }
        }
        // huffman only compression
        {
            const gzip_size = case.huffman_only_size;

            inline for (Container.list) |container| { // for each wrapping
                const compressed_size = gzip_size - Container.gzip.size() + container.size();

                // compress original stream to compressed stream
                {
                    var compressed = fixedBufferStream(&cmp_buf);
                    var cmp = try deflate.huffmanOnlyCompressor(container, compressed.writer());
                    try cmp.writeBlock(case.data);
                    try cmp.close();
                    try testing.expectEqual(compressed_size, compressed.pos);
                }
                // decompress compressed stream to decompressed stream
                {
                    var compressed = fixedBufferStream(cmp_buf[0..compressed_size]);
                    var decompressed = fixedBufferStream(&dcm_buf);
                    try inflate.decompress(container, compressed.reader(), decompressed.writer());
                    try testing.expectEqualSlices(u8, data, decompressed.getWritten());
                }
            }
        }
    }
}
