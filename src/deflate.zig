const std = @import("std");
const io = std.io;
const assert = std.debug.assert;
const testing = std.testing;
const expect = testing.expect;
const print = std.debug.print;

const Token = @import("Token.zig");
const consts = @import("consts.zig");
const BlockWriter = @import("block_writer.zig").BlockWriter;
const Container = @import("container.zig").Container;
const SlidingWindow = @import("SlidingWindow.zig");
const Lookup = @import("Lookup.zig");

pub const Level = enum(u4) {
    // zig fmt: off
    fast = 0xb,         level_4 = 4,
                        level_5 = 5,
    default = 0xc,      level_6 = 6,
                        level_7 = 7,
                        level_8 = 8,
    best = 0xd,         level_9 = 9,
    // zig fmt: on
};

const LevelArgs = struct {
    good: u16, // do less lookups if we already have match of this length
    nice: u16, // stop looking for better match if we found match with at least this length
    lazy: u16, // don't do lazy match find if got match with at least this length
    chain: u16, // how many lookups for previous match to perform

    pub fn get(level: Level) LevelArgs {
        // zig fmt: off
        return switch (level) {
            .fast,    .level_4 => .{ .good =  4, .lazy =   4, .nice =  16, .chain =   16 },
                      .level_5 => .{ .good =  8, .lazy =  16, .nice =  32, .chain =   32 },
            .default, .level_6 => .{ .good =  8, .lazy =  16, .nice = 128, .chain =  128 },
                      .level_7 => .{ .good =  8, .lazy =  32, .nice = 128, .chain =  256 },
                      .level_8 => .{ .good = 32, .lazy = 128, .nice = 258, .chain = 1024 },
            .best,    .level_9 => .{ .good = 32, .lazy = 258, .nice = 258, .chain = 4096 },
        };
        // zig fmt: on
    }
};

pub fn compress(comptime container: Container, reader: anytype, writer: anytype, level: Level) !void {
    var c = try compressor(container, writer, level);
    try c.compress(reader);
    try c.close();
}

pub fn compressor(comptime container: Container, writer: anytype, level: Level) !Compressor(
    container,
    @TypeOf(writer),
) {
    return try Compressor(container, @TypeOf(writer)).init(writer, level);
}

pub fn Compressor(comptime container: Container, comptime WriterType: type) type {
    const TokenWriterType = BlockWriter(WriterType);
    return Deflate(container, WriterType, TokenWriterType);
}

// Default compression algorithm. Has two steps: tokenization and token
// encoding.
//
// Tokenization takes uncompressed input stream and produces list of tokens.
// Each token can be literal (byte of data) or match (backrefernce to previous
// data with length and distance). Tokenization acumulates `const.block.tokens`
// number of tokens, when full or `flush` is called tokens are passed to the
// `token_writer`. Level defines how hard (how slow) it tries to find match.
//
// Token writer will decide which type of deflate block to write (stored, fixed,
// dynamic) and encode tokens to the output byte stream. Client has to call
// `close` to write block with the final bit set.
//
// Container defines type of header and footer which can be gzip, zlib or raw.
// They all share same deflate body. Raw has no header or footer just deflate
// body.
//
fn Deflate(comptime container: Container, comptime WriterType: type, comptime BlockWriterType: type) type {
    return struct {
        lookup: Lookup = .{},
        win: SlidingWindow = .{},
        tokens: Tokens = .{},
        wrt: WriterType,
        block_writer: BlockWriterType,
        level: LevelArgs,
        hasher: container.Hasher() = .{},

        // Match and literal at the previous position.
        // Used for lazy match finding in processWindow.
        prev_match: ?Token = null,
        prev_literal: ?u8 = null,

        const Self = @This();
        pub fn init(wrt: WriterType, level: Level) !Self {
            const self = Self{
                .wrt = wrt,
                .block_writer = BlockWriterType.init(wrt),
                .level = LevelArgs.get(level),
            };
            try container.writeHeader(self.wrt);
            return self;
        }

        const TokenizeOption = enum { none, flush, final };

        // Process data in window and create tokens. If token buffer is full
        // flush tokens to the token writer. In the case of `flush` or `final`
        // option it will process all data from the window. In the `none` case
        // it will preserve some data for the next match.
        fn tokenize(self: *Self, opt: TokenizeOption) !void {
            // flush - process all data from window
            const should_flush = (opt != .none);

            // While there is data in active lookahead buffer.
            while (self.win.activeLookahead(should_flush)) |lh| {
                var step: u16 = 1; // 1 in the case of literal, match length otherwise
                const pos: u16 = self.win.pos();
                const literal = lh[0]; // literal at current position
                const min_len: u16 = if (self.prev_match) |m| m.length() else 0;

                // Try to find match at least min_len long.
                if (self.findMatch(pos, lh, min_len)) |match| {
                    // Found better match than previous.
                    try self.addPrevLiteral();

                    // Is found match length good enough?
                    if (match.length() >= self.level.lazy) {
                        // Don't try to lazy find better match, use this.
                        step = try self.addMatch(match);
                    } else {
                        // Store this match.
                        self.prev_literal = literal;
                        self.prev_match = match;
                    }
                } else {
                    // There is no better match at current pos then it was previous.
                    // Write previous match or literal.
                    if (self.prev_match) |m| {
                        // Write match from previous position.
                        step = try self.addMatch(m) - 1; // we already advanced 1 from previous position
                    } else {
                        // No match at previous postition.
                        // Write previous literal if any, and remember this literal.
                        try self.addPrevLiteral();
                        self.prev_literal = literal;
                    }
                }
                // Advance window and add hashes.
                self.windowAdvance(step, lh, pos);
            }

            if (should_flush) {
                // In the case of flushing, last few lookahead buffers were smaller then min match len.
                // So only last literal can be unwritten.
                assert(self.prev_match == null);
                try self.addPrevLiteral();
                self.prev_literal = null;

                try self.flushTokens(opt == .final);
            }
        }

        inline fn windowAdvance(self: *Self, step: u16, lh: []const u8, pos: u16) void {
            // current position is already added in findMatch
            self.lookup.bulkAdd(lh[1..], step - 1, pos + 1);
            self.win.advance(step);
        }

        // Add previous literal (if any) to the tokens list.
        inline fn addPrevLiteral(self: *Self) !void {
            if (self.prev_literal) |l| try self.addToken(Token.initLiteral(l));
        }

        // Add match to the tokens list, reset prev pointers.
        // Returns length of the added match.
        inline fn addMatch(self: *Self, m: Token) !u16 {
            try self.addToken(m);
            self.prev_literal = null;
            self.prev_match = null;
            return m.length();
        }

        inline fn addToken(self: *Self, token: Token) !void {
            self.tokens.add(token);
            if (self.tokens.full()) try self.flushTokens(false);
        }

        // Finds largest match in the history window with the data at current pos.
        fn findMatch(self: *Self, pos: u16, lh: []const u8, min_len: u16) ?Token {
            var len: u16 = min_len;
            // Previous location with the same hash (same 4 bytes).
            var prev_pos = self.lookup.add(lh, pos);
            // Last found match.
            var match: ?Token = null;

            // How much back-references to try, performance knob.
            var chain: usize = self.level.chain;
            if (len >= self.level.good) {
                // If we've got a match that's good enough, only look in 1/4 the chain.
                chain >>= 2;
            }

            while (prev_pos > 0 and chain > 0) : (chain -= 1) {
                const distance = pos - prev_pos;
                if (distance > consts.match.max_distance)
                    break;

                const new_len = self.win.match(prev_pos, pos, len);
                if (new_len > len) {
                    match = Token.initMatch(@intCast(distance), new_len);
                    if (new_len >= self.level.nice) {
                        // The match is good enough that we don't try to find a better one.
                        return match;
                    }
                    len = new_len;
                }
                prev_pos = self.lookup.prev(prev_pos);
            }

            return match;
        }

        fn flushTokens(self: *Self, final: bool) !void {
            try self.block_writer.writeBlock(self.tokens.tokens(), final, self.win.tokensBuffer());
            try self.block_writer.flush();
            self.tokens.reset();
            self.win.flushed();
        }

        // Flush internal buffers to the output writer. Writes deflate block to
        // the writer. Internal tokens buffer is empty after this.
        pub fn flush(self: *Self) !void {
            try self.tokenize(.flush);
        }

        // Slide win and if needed lookup tables.
        inline fn slide(self: *Self) void {
            const n = self.win.slide();
            self.lookup.slide(n);
        }

        // Flush internal buffers and write deflate final block.
        pub fn close(self: *Self) !void {
            try self.tokenize(.final);
            try container.writeFooter(&self.hasher, self.wrt);
        }

        pub fn setWriter(self: *Self, new_writer: WriterType) void {
            self.block_writer.setWriter(new_writer);
            self.wrt = new_writer;
        }

        // Writes all data from the input reader of uncompressed data.
        // It is up to the caller to call flush or close if there is need to
        // output compressed blocks.
        pub fn compress(self: *Self, reader: anytype) !void {
            while (true) {
                // read from rdr into win
                const buf = self.win.writable();
                if (buf.len == 0) {
                    try self.tokenize(.none);
                    self.slide();
                    continue;
                }
                const n = try reader.readAll(buf);
                self.hasher.update(buf[0..n]);
                self.win.written(n);
                // process win
                try self.tokenize(.none);
                // no more data in reader
                if (n < buf.len) break;
            }
        }

        // Writer interface

        pub const Writer = io.Writer(*Self, Error, write);
        pub const Error = BlockWriterType.Error;

        // Write `input` of uncompressed data.
        pub fn write(self: *Self, input: []const u8) !usize {
            var fbs = io.fixedBufferStream(input);
            try self.compress(fbs.reader());
            return input.len;
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }
    };
}

// Tokens store
const Tokens = struct {
    list: [consts.deflate.tokens]Token = undefined,
    pos: usize = 0,

    fn add(self: *Tokens, t: Token) void {
        self.list[self.pos] = t;
        self.pos += 1;
    }

    fn full(self: *Tokens) bool {
        return self.pos == self.list.len;
    }

    fn reset(self: *Tokens) void {
        self.pos = 0;
    }

    fn tokens(self: *Tokens) []const Token {
        return self.list[0..self.pos];
    }
};

pub fn huffmanOnlyCompressor(comptime container: Container, writer: anytype) !HuffmanOnlyCompressor(
    container,
    @TypeOf(writer),
) {
    return try HuffmanOnlyCompressor(container, @TypeOf(writer)).init(writer);
}

// Creates huffman only deflate blocks. Disables Lempel-Ziv match searching and
// only performs Huffman entropy encoding.
pub fn HuffmanOnlyCompressor(comptime container: Container, comptime WriterType: type) type {
    const BlockWriterType = BlockWriter(WriterType);
    return struct {
        wrt: WriterType,
        block_writer: BlockWriterType,
        hasher: container.Hasher() = .{},

        const Self = @This();

        pub fn init(wrt: WriterType) !Self {
            const self = Self{
                .wrt = wrt,
                .block_writer = BlockWriterType.init(wrt),
            };
            try container.writeHeader(self.wrt);
            return self;
        }

        pub fn close(self: *Self) !void {
            try self.block_writer.writeBlockStored("", true);
            try self.block_writer.flush();
            try container.writeFooter(&self.hasher, self.wrt);
        }

        pub fn writeBlock(self: *Self, input: []const u8) !void {
            self.hasher.update(input);
            try self.block_writer.writeBlockHuff(false, input);
        }
    };
}

test "deflate: tokenization" {
    const L = Token.initLiteral;
    const M = Token.initMatch;

    const cases = [_]struct {
        data: []const u8,
        tokens: []const Token,
    }{
        .{
            .data = "Blah blah blah blah blah!",
            .tokens = &[_]Token{ L('B'), L('l'), L('a'), L('h'), L(' '), L('b'), M(5, 18), L('!') },
        },
        .{
            .data = "ABCDEABCD ABCDEABCD",
            .tokens = &[_]Token{
                L('A'), L('B'),   L('C'), L('D'), L('E'), L('A'), L('B'), L('C'), L('D'), L(' '),
                L('A'), M(10, 8),
            },
        },
    };

    for (cases) |c| {
        inline for (Container.list) |container| { // for each wrapping
            var cw = io.countingWriter(io.null_writer);
            const cww = cw.writer();
            var df = try Deflate(container, @TypeOf(cww), TestTokenWriter).init(cww, .default);

            _ = try df.write(c.data);
            try df.flush();

            // df.token_writer.show();
            try expect(df.block_writer.pos == c.tokens.len); // number of tokens written
            try testing.expectEqualSlices(Token, df.block_writer.get(), c.tokens); // tokens match

            try testing.expectEqual(container.headerSize(), cw.bytes_written);
            try df.close();
            try testing.expectEqual(container.size(), cw.bytes_written);
        }
    }
}

// Tests that tokens writen are equal to expected token list.
const TestTokenWriter = struct {
    const Self = @This();
    //expected: []const Token,
    pos: usize = 0,
    actual: [1024]Token = undefined,

    pub fn init(_: anytype) Self {
        return .{};
    }
    pub fn writeBlock(self: *Self, tokens: []const Token, _: bool, _: ?[]const u8) !void {
        for (tokens) |t| {
            self.actual[self.pos] = t;
            self.pos += 1;
        }
    }

    pub fn get(self: *Self) []Token {
        return self.actual[0..self.pos];
    }

    pub fn show(self: *Self) void {
        print("\n", .{});
        for (self.get()) |t| {
            t.show();
        }
    }

    pub fn flush(_: *Self) !void {}
};

test "check struct sizes" {
    try expect(@sizeOf(Token) == 4);

    // list: (1 << 15) * 4 = 128k + pos: 8
    const tokens_size = 128 * 1024 + 8;
    try expect(@sizeOf(Tokens) == tokens_size);

    // head: (1 << 15) * 2 = 64k, chain: (32768 * 2) * 2  = 128k = 192k
    const lookup_size = 192 * 1024;
    try expect(@sizeOf(Lookup) == lookup_size);

    // buffer: (32k * 2), wp: 8, rp: 8, fp: 8
    const window_size = 64 * 1024 + 8 + 8 + 8;
    try expect(@sizeOf(SlidingWindow) == window_size);

    const Bw = BlockWriter(@TypeOf(io.null_writer));
    // huffman bit writer internal: 11480
    const hbw_size = 11472; // 11.2k
    try expect(@sizeOf(Bw) == hbw_size);

    //const D = Deflate(Hbw);
    // 404744, 395.26k
    // ?Token: 6, ?u8: 2, level: 8
    //try expect(@sizeOf(D) == tokens_size + lookup_size + window_size + hbw_size + 6 + 2 + 8);

    //print("Delfate size: {d} {d}\n", .{ @sizeOf(D), @sizeOf(LevelArgs) });

    // current std lib deflate allocation:
    // 797_901, 779.2k
    // measured with:
    // var la = std.heap.logToWriterAllocator(testing.allocator, io.getStdOut().writer());
    // const allocator = la.allocator();
    // var cmp = try std.compress.deflate.compressor(allocator, io.null_writer, .{});
    // defer cmp.deinit();
}

test "deflate file tokenization" {
    const levels = [_]Level{ .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };
    const cases = [_]struct {
        data: []const u8, // uncompressed content
        // expected number of tokens producet in deflate tokenization
        tokens_count: [levels.len]usize = .{0} ** levels.len,
    }{
        .{
            .data = @embedFile("testdata/rfc1951.txt"),
            .tokens_count = .{ 7675, 7672, 7599, 7594, 7598, 7599 },
        },

        .{
            .data = @embedFile("testdata/huffman-null-max.input"),
            .tokens_count = .{ 257, 257, 257, 257, 257, 257 },
        },
        .{
            .data = @embedFile("testdata/huffman-pi.input"),
            .tokens_count = .{ 2570, 2564, 2564, 2564, 2564, 2564 },
        },
        .{
            .data = @embedFile("testdata/huffman-text.input"),
            .tokens_count = .{ 235, 234, 234, 234, 234, 234 },
        },
    };

    for (cases) |case| { // for each case
        const data = case.data;

        for (levels, 0..) |level, i| { // for each compression level
            var original = io.fixedBufferStream(data);

            // buffer for decompressed data
            var al = std.ArrayList(u8).init(testing.allocator);
            defer al.deinit();
            const writer = al.writer();

            // create compressor
            const WriterType = @TypeOf(writer);
            const TokenWriter = TokenDecoder(@TypeOf(writer));
            var cmp = try Deflate(.raw, WriterType, TokenWriter).init(writer, level);

            // Stream uncompressed `orignal` data to the compressor. It will
            // produce tokens list and pass that list to the TokenDecoder. This
            // TokenDecoder uses CircularBuffer from inflate to convert list of
            // tokens back to the uncompressed stream.
            try cmp.compress(original.reader());
            try cmp.flush();
            const expected_count = case.tokens_count[i];
            const actual = cmp.block_writer.tokens_count;
            if (expected_count == 0) {
                print("actual token count {d}\n", .{actual});
            } else {
                try testing.expectEqual(expected_count, actual);
            }

            try testing.expectEqual(data.len, al.items.len);
            try testing.expectEqualSlices(u8, data, al.items);
        }
    }
}

fn TokenDecoder(comptime WriterType: type) type {
    return struct {
        const CircularBuffer = @import("CircularBuffer.zig");
        hist: CircularBuffer = .{},
        wrt: WriterType,
        tokens_count: usize = 0,

        const Self = @This();

        pub fn init(wrt: WriterType) Self {
            return .{ .wrt = wrt };
        }

        pub fn writeBlock(self: *Self, tokens: []const Token, _: bool, _: ?[]const u8) !void {
            self.tokens_count += tokens.len;
            for (tokens) |t| {
                switch (t.kind) {
                    .literal => self.hist.write(t.literal()),
                    .match => self.hist.writeMatch(t.length(), t.distance()),
                }
                if (self.hist.free() < 285) try self.flushWin();
            }
            try self.flushWin();
        }

        fn flushWin(self: *Self) !void {
            while (true) {
                const buf = self.hist.read();
                if (buf.len == 0) break;
                try self.wrt.writeAll(buf);
            }
        }

        pub fn flush(_: *Self) !void {}
    };
}
