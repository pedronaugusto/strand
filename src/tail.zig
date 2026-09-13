//! Reading a JSON Lines file backwards: the last line first, and only the
//! bytes that takes.
//!
//! A log answers most questions from its end — what happened last, what the
//! last hundred events were, when the process stopped — and a file that has
//! grown for a week should not have to be read from the start to answer them.
//! `Tail` walks a seekable file from its end towards its beginning, reading
//! one block at a time and stopping as soon as the caller does.
//!
//! It is the same line layer as `Reader`, with the same borrow rule and the
//! same treatment of `\r\n`, blank lines, control bytes and byte-order marks.
//! What it cannot do is count: a backwards read never learns how many lines
//! came before the ones it read, so `Line.number` counts back from the end,
//! 1 being the last line of the file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const strand = @import("strand.zig");
const Line = strand.Line;
const ParseLineError = strand.ParseLineError;

/// A stream of `T` read from the end of a seekable file towards its start.
///
/// The reverse of `Reader`, and its mirror image in every way that matters:
/// one buffer holding the bytes of the current line, one arena holding what
/// parsing it allocated, both recycled by `prev`, and a value that must be
/// copied out (`keep`) to outlive the line it came from.
///
/// The buffer holds one block plus the line being assembled, so the cost of a
/// backwards read is the cost of the lines it actually returns — a `last(10)`
/// over a gigabyte reads one block.
pub fn Tail(comptime T: type) type {
    return struct {
        /// The file. Not owned: this reader never closes it. It seeks it, and
        /// leaves it wherever the last block read left it, so a caller that
        /// also reads the file forwards must seek it back itself.
        source: *std.Io.File.Reader,
        /// Read-only after `init`.
        options: Options,
        /// How many lines `prev` has returned or refused, blank and skipped
        /// lines included. Also the number of the line `prev` last returned,
        /// counting back from the end of the file: 1 is the last line.
        number: u64 = 0,
        /// The byte offset in the file of the first byte of the line `prev`
        /// last returned.
        offset: u64 = 0,
        /// How many records `prev` passed over under
        /// `on_malformed = .skip`. See `Reader.skipped`.
        skipped: u64 = 0,
        /// The number of the most recent failure, in the same backwards
        /// count; 0 if there has been none.
        last_error_line: u64 = 0,
        /// What `std.json` said about the line at `last_error_line`. `null`
        /// when it never reached `std.json`.
        last_error: ?ParseLineError = null,
        /// The 0-based offset within the line of the byte that tripped
        /// `error.ControlByte`; `null` for every other failure.
        last_error_offset: ?usize = null,

        /// Internal. The allocator behind `buf` and `arena`.
        allocator: Allocator,
        /// Internal. File bytes `[lo, lo + buf.items.len)`. The lines not yet
        /// returned end at `lo + end`; what is past `end` has been handed out
        /// already and is what the next `prev` overwrites.
        buf: std.ArrayList(u8) = .empty,
        /// Internal. See `buf`.
        lo: u64 = 0,
        /// Internal. See `buf`.
        end: usize = 0,
        /// Internal. Set when the line beginning at offset 0 has been
        /// returned: there is nothing before it.
        exhausted: bool = false,
        /// Internal. Set once the file's own last byte has been looked at,
        /// which is where a final newline is dropped.
        trimmed: bool = false,
        /// Internal. What parsing the current line allocated, reset per line.
        arena: std.heap.ArenaAllocator,

        const Self = @This();

        /// Reading and parsing policy, fixed at `init`.
        ///
        /// The same policy as `Reader.Options`, minus the two settings a
        /// backwards read cannot honour: `format`, because finding where a
        /// multi-line record begins means parsing forwards, and
        /// `require_terminator`, because a file being appended to is
        /// `Follower`'s job, not this one's.
        pub const Options = struct {
            /// See `ParseOptions.ignore_unknown_fields`.
            ignore_unknown_fields: bool = true,
            /// See `ParseOptions.duplicate_fields`.
            duplicate_fields: strand.DuplicateFields = .@"error",
            /// The longest line accepted, in bytes. A longer one is
            /// `error.LineTooLong`, and is discarded whole: `prev` continues
            /// with the line before it.
            max_line_bytes: usize = 1 << 20,
            /// When true, a line that is empty or all spaces and tabs is
            /// passed over. Its number is still counted.
            skip_blank: bool = true,
            /// See `Reader.Options.reject_control_bytes`.
            reject_control_bytes: bool = true,
            /// When true, a UTF-8 byte-order mark at the very start of the
            /// file is not part of the first line — which a backwards read
            /// only ever meets last.
            skip_bom: bool = true,
            /// See `Reader.Options.on_malformed`.
            on_malformed: enum { fail, skip } = .fail,
            /// How many bytes one read asks the file for. The buffer holds
            /// one of these plus the line being assembled, so this trades a
            /// syscall per block against the memory a `Tail` costs while it
            /// is open.
            block_bytes: usize = 4096,
        };

        /// What `init` can report: the file could not be measured. A stream
        /// with no size — a pipe, a socket — is `error.Streaming`, which is
        /// this package saying "there is no end to start from".
        pub const InitError = std.Io.File.Reader.SizeError;

        /// What `prev` can report.
        ///
        /// The first three are about a line, and none of them loses the
        /// reader its place: the offending line has been passed over whole
        /// and `prev` can be called again for the one before it. The rest are
        /// about the file or the allocator.
        ///
        /// | Error | Meaning |
        /// |---|---|
        /// | `MalformedLine` | This line is not a `T`; see `last_error`. |
        /// | `ControlByte` | This line holds a raw control byte; see `last_error_offset`. |
        /// | `LineTooLong` | This line ran past `max_line_bytes`. |
        /// | `ReadFailed` | The file refused a read; ask `source` for diagnostics. |
        /// | `SeekFailed` | The file refused a seek; ask `source.seek_err`. |
        /// | `Truncated` | The file is shorter than when `init` measured it. |
        /// | `OutOfMemory` | The allocator failed. |
        pub const NextError = error{
            MalformedLine,
            ControlByte,
            LineTooLong,
            ReadFailed,
            SeekFailed,
            Truncated,
            OutOfMemory,
        };

        /// A backwards reader over `source`, positioned at its end.
        ///
        /// Measures the file once, with `std.Io.File.Reader.getSize`, and
        /// works within that size for the rest of its life: a file that grows
        /// afterwards is not read, and a file that shrinks is
        /// `error.Truncated`. That is the contract that makes a backwards
        /// read meaningful at all — it is a view of the file as it was when
        /// the tail opened.
        pub fn init(allocator: Allocator, source: *std.Io.File.Reader, options: Options) InitError!Self {
            assert(options.block_bytes > 0);
            const size = try source.getSize();
            return .{
                .source = source,
                .options = options,
                .allocator = allocator,
                .arena = .init(allocator),
                .lo = size,
                .end = 0,
                // A file ending in a newline does not end in an empty line:
                // that byte is the terminator of the last line, not a line of
                // its own. An empty file has no lines at all.
                .exhausted = size == 0,
            };
        }

        /// Releases the block buffer and the arena. Every `Line` this reader
        /// returned, and every string borrowed from one, dangles afterwards.
        pub fn deinit(self: *Self) void {
            self.buf.deinit(self.allocator);
            self.arena.deinit();
            self.* = undefined;
        }

        /// The line before the last one returned, or `null` once the line at
        /// offset 0 has been given out.
        ///
        /// Ownership: exactly `Reader.next`'s. The returned `Line` borrows the
        /// reader's block buffer and its arena, and the next call to `prev`
        /// takes both back. `keep` is how a value outlives its line.
        pub fn prev(self: *Self) NextError!?Line(T) {
            while (true) {
                var raw = (try self.prevRaw()) orelse return null;
                const number = self.number;

                // The terminator is not part of the line, and neither is a
                // mark at the very start of the file.
                if (std.mem.endsWith(u8, raw, "\r")) raw = raw[0 .. raw.len - 1];
                const bom = "\xEF\xBB\xBF";
                if (self.options.skip_bom and self.offset == 0 and std.mem.startsWith(u8, raw, bom)) {
                    raw = raw[bom.len..];
                    // The mark is not part of the line, so it is not where
                    // the line begins either.
                    self.offset = bom.len;
                }

                if (self.options.skip_blank and isBlank(raw)) continue;
                if (self.options.reject_control_bytes) {
                    if (strand.indexOfControl(raw)) |at| {
                        self.last_error_line = number;
                        self.last_error = null;
                        self.last_error_offset = at;
                        switch (self.options.on_malformed) {
                            .fail => return error.ControlByte,
                            .skip => {
                                self.skipped += 1;
                                continue;
                            },
                        }
                    }
                }

                _ = self.arena.reset(.retain_capacity);
                const value = strand.parseLine(T, self.arena.allocator(), raw, .{
                    .ignore_unknown_fields = self.options.ignore_unknown_fields,
                    .duplicate_fields = self.options.duplicate_fields,
                    .copy_strings = false,
                }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => |parse_err| {
                        self.last_error_line = number;
                        self.last_error = parse_err;
                        self.last_error_offset = null;
                        switch (self.options.on_malformed) {
                            .fail => return error.MalformedLine,
                            .skip => {
                                self.skipped += 1;
                                continue;
                            },
                        }
                    },
                };
                return .{ .value = value, .line = raw, .number = number, .offset = self.offset };
            }
        }

        /// A copy of `line.value` that outlives the reader, allocated on
        /// `allocator`. See `Reader.keep`, whose contract this is.
        pub fn keep(self: *Self, allocator: Allocator, line: Line(T)) ParseLineError!T {
            return strand.parseLine(T, allocator, line.line, .{
                .ignore_unknown_fields = self.options.ignore_unknown_fields,
                .duplicate_fields = self.options.duplicate_fields,
                .copy_strings = true,
            });
        }

        /// The last `n` values of the file, in file order, allocated on
        /// `allocator`.
        ///
        /// Ownership: everything the result points at is on `allocator`, and
        /// none of it borrows the reader, so pass an arena and drop it whole.
        /// Fewer than `n` values means the file ran out; under
        /// `on_malformed = .skip` a skipped line is not one of the `n`.
        ///
        /// This is the whole reason to read a file backwards, so it is worth
        /// saying what it costs: one block read per block the last `n` lines
        /// span, and nothing at all for the rest of the file.
        pub fn last(self: *Self, allocator: Allocator, n: usize) (NextError || ParseLineError)![]T {
            var out: std.ArrayList(T) = .empty;
            errdefer out.deinit(allocator);
            try out.ensureTotalCapacity(allocator, @min(n, 1024));
            while (out.items.len < n) {
                const line = (try self.prev()) orelse break;
                try out.append(allocator, try self.keep(allocator, line));
            }
            std.mem.reverse(T, out.items);
            return out.toOwnedSlice(allocator);
        }

        /// The bytes of the line before the last one returned, terminator
        /// excluded, or `null` at the start of the file. Counts the line.
        fn prevRaw(self: *Self) NextError!?[]const u8 {
            if (self.exhausted) return null;
            var over = false;
            while (true) {
                if (std.mem.lastIndexOfScalar(u8, self.buf.items[0..self.end], '\n')) |i| {
                    const line = self.buf.items[i + 1 .. self.end];
                    self.offset = self.lo + i + 1;
                    // The newline at `i` terminates the line before this one.
                    self.end = i;
                    self.number += 1;
                    return self.emit(line, over);
                }
                if (self.lo == 0) {
                    const line = self.buf.items[0..self.end];
                    self.offset = 0;
                    self.end = 0;
                    self.exhausted = true;
                    self.number += 1;
                    return self.emit(line, over);
                }
                if (!over and self.end > self.options.max_line_bytes) {
                    // Longer than the bound allows to be held: drop what has
                    // been read of it and keep scanning back for where it
                    // began, so that the line before it is still reachable.
                    over = true;
                }
                if (over) {
                    self.end = 0;
                    self.buf.clearRetainingCapacity();
                }
                try self.fillBefore();
            }
        }

        /// Hands over a line, or refuses it for its length. `over` is set when
        /// the line was already too long to hold, in which case its bytes
        /// have been dropped and only its extent is known.
        fn emit(self: *Self, line: []const u8, over: bool) NextError!?[]const u8 {
            if (!over and line.len <= self.options.max_line_bytes) return line;
            self.last_error_line = self.number;
            self.last_error = null;
            self.last_error_offset = null;
            return error.LineTooLong;
        }

        /// Prepends the block of file bytes that ends where the buffer begins.
        fn fillBefore(self: *Self) NextError!void {
            assert(self.lo > 0);
            const take: usize = @intCast(@min(self.options.block_bytes, self.lo));
            const kept = self.end;

            self.buf.items.len = kept;
            self.buf.ensureTotalCapacity(self.allocator, kept + take) catch return error.OutOfMemory;
            self.buf.items.len = kept + take;
            // The two regions overlap, and the destination is the later one.
            std.mem.copyBackwards(u8, self.buf.items[take..], self.buf.items[0..kept]);

            self.source.seekTo(self.lo - take) catch return error.SeekFailed;
            self.source.interface.readSliceAll(self.buf.items[0..take]) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                // The file was this long when `init` measured it.
                error.EndOfStream => return error.Truncated,
            };
            self.lo -= take;
            self.end = kept + take;

            if (!self.trimmed) {
                self.trimmed = true;
                // A file ending in a newline ends with a terminator, not with
                // an empty line, so that byte is not part of any line.
                if (self.end > 0 and self.buf.items[self.end - 1] == '\n') {
                    self.end -= 1;
                    self.buf.items.len -= 1;
                }
            }
        }
    };
}

/// True for a line with nothing on it but spaces and tabs. The same rule
/// `Reader` applies, restated here rather than exported from there.
fn isBlank(line: []const u8) bool {
    return std.mem.indexOfNone(u8, line, " \t") == null;
}

//=========================================================================
// Tests. A file has to exist for any of this, so each one writes its bytes
// into a temporary directory and reads them back.
//=========================================================================

const testing = std.testing;

/// A file holding `bytes`, opened for reading, with a reader over it.
const Fixture = struct {
    tmp: testing.TmpDir,
    file: std.Io.File,
    reader: std.Io.File.Reader,
    buffer: []u8,

    fn init(bytes: []const u8, buffer_len: usize) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = bytes });
        const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
        errdefer file.close(testing.io);
        const buffer = try testing.allocator.alloc(u8, buffer_len);
        return .{
            .tmp = tmp,
            .file = file,
            .reader = file.reader(testing.io, buffer),
            .buffer = buffer,
        };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.buffer);
        self.file.close(testing.io);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

const Event = struct {
    kind: []const u8,
    at: u64 = 0,
};

/// Every line of `bytes` read backwards, as one string per line.
fn backwards(bytes: []const u8, options: Tail(Event).Options) ![][]const u8 {
    var fixture = try Fixture.init(bytes, 64);
    defer fixture.deinit();

    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, options);
    defer tail.deinit();

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |item| testing.allocator.free(item);
        out.deinit(testing.allocator);
    }
    while (try tail.prev()) |line| {
        try out.append(testing.allocator, try testing.allocator.dupe(u8, line.line));
    }
    return out.toOwnedSlice(testing.allocator);
}

fn freeAll(items: [][]const u8) void {
    for (items) |item| testing.allocator.free(item);
    testing.allocator.free(items);
}

test "a file read backwards is the same lines in the other order" {
    const cases: []const struct { bytes: []const u8, want: []const []const u8 } = &.{
        // A final newline is a terminator, not an empty last line.
        .{ .bytes = "{\"kind\":\"a\"}\n{\"kind\":\"b\"}\n", .want = &.{ "{\"kind\":\"b\"}", "{\"kind\":\"a\"}" } },
        // A file with no final newline still ends with a line.
        .{ .bytes = "{\"kind\":\"a\"}\n{\"kind\":\"b\"}", .want = &.{ "{\"kind\":\"b\"}", "{\"kind\":\"a\"}" } },
        // CRLF, both ways.
        .{ .bytes = "{\"kind\":\"a\"}\r\n{\"kind\":\"b\"}\r\n", .want = &.{ "{\"kind\":\"b\"}", "{\"kind\":\"a\"}" } },
        .{ .bytes = "{\"kind\":\"a\"}\r\n{\"kind\":\"b\"}", .want = &.{ "{\"kind\":\"b\"}", "{\"kind\":\"a\"}" } },
        // One line, no terminator.
        .{ .bytes = "{\"kind\":\"only\"}", .want = &.{"{\"kind\":\"only\"}"} },
        // A byte-order mark belongs to the file, not to its first line.
        .{ .bytes = "\xEF\xBB\xBF{\"kind\":\"a\"}\n", .want = &.{"{\"kind\":\"a\"}"} },
    };

    for (cases) |case| {
        const got = try backwards(case.bytes, .{});
        defer freeAll(got);
        try testing.expectEqual(case.want.len, got.len);
        for (case.want, got) |want, have| try testing.expectEqualStrings(want, have);
    }
}

test "an empty file has no last line" {
    const got = try backwards("", .{});
    defer freeAll(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "the block size does not change what is read" {
    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    var writer: strand.Writer(Event) = .init(&input.writer, .{});
    for (0..500) |i| try writer.write(.{ .kind = "tick", .at = i });

    for ([_]usize{ 1, 2, 7, 64, 4096, 1 << 20 }) |block| {
        var fixture = try Fixture.init(input.written(), 64);
        defer fixture.deinit();

        var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{ .block_bytes = block });
        defer tail.deinit();

        var expected: u64 = 500;
        while (try tail.prev()) |line| {
            expected -= 1;
            try testing.expectEqual(expected, line.value.at);
            try testing.expectEqual(500 - expected, line.number);
        }
        try testing.expectEqual(@as(u64, 0), expected);
    }
}

test "last(n) reads the end of the file and nothing else" {
    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    var writer: strand.Writer(Event) = .init(&input.writer, .{});
    for (0..10_000) |i| try writer.write(.{ .kind = "tick", .at = i });

    var fixture = try Fixture.init(input.written(), 64);
    defer fixture.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{ .block_bytes = 512 });
    defer tail.deinit();

    const got = try tail.last(arena.allocator(), 5);
    try testing.expectEqual(@as(usize, 5), got.len);
    // In file order, and the last five of them.
    for (got, 9995..) |event, at| {
        try testing.expectEqual(@as(u64, at), event.at);
        try testing.expectEqualStrings("tick", event.kind);
    }
    // Five lines of about thirty bytes: one block, not the whole file.
    try testing.expect(tail.lo > input.written().len - 4096);

    // Asking for more than there is gives what there is.
    var whole: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{});
    defer whole.deinit();
    const all = try whole.last(arena.allocator(), 20_000);
    try testing.expectEqual(@as(usize, 10_000), all.len);
}

test "a malformed line names itself and does not cost the reader its place" {
    const input =
        \\{"kind":"first"}
        \\not json at all
        \\{"kind":"third"}
        \\
    ;
    var fixture = try Fixture.init(input, 64);
    defer fixture.deinit();

    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{});
    defer tail.deinit();

    try testing.expectEqualStrings("third", (try tail.prev()).?.value.kind);
    try testing.expectError(error.MalformedLine, tail.prev());
    // Numbered from the end: the bad line is the second from last.
    try testing.expectEqual(@as(u64, 2), tail.last_error_line);
    try testing.expectEqual(error.SyntaxError, tail.last_error.?);
    try testing.expectEqualStrings("first", (try tail.prev()).?.value.kind);
    try testing.expectEqual(@as(?Line(Event), null), try tail.prev());
}

test "a control byte is reported with the line and the offset" {
    var fixture = try Fixture.init("{\"kind\":\"a\"}\n{\"kind\":\"b\x00\"}\n", 64);
    defer fixture.deinit();

    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{});
    defer tail.deinit();

    try testing.expectError(error.ControlByte, tail.prev());
    try testing.expectEqual(@as(u64, 1), tail.last_error_line);
    try testing.expectEqual(@as(?usize, 10), tail.last_error_offset);
    try testing.expectEqualStrings("a", (try tail.prev()).?.value.kind);
}

test "an over-long line is discarded whole and the one before it is still read" {
    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    var writer: strand.Writer(Event) = .init(&input.writer, .{});
    try writer.write(.{ .kind = "short", .at = 1 });
    try writer.write(.{ .kind = "x" ** 300, .at = 2 });
    try writer.write(.{ .kind = "last", .at = 3 });

    for ([_]usize{ 8, 64, 4096 }) |block| {
        var fixture = try Fixture.init(input.written(), 64);
        defer fixture.deinit();

        var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{
            .max_line_bytes = 64,
            .block_bytes = block,
        });
        defer tail.deinit();

        try testing.expectEqualStrings("last", (try tail.prev()).?.value.kind);
        try testing.expectError(error.LineTooLong, tail.prev());
        try testing.expectEqual(@as(u64, 2), tail.last_error_line);
        try testing.expectEqualStrings("short", (try tail.prev()).?.value.kind);
        try testing.expectEqual(@as(?Line(Event), null), try tail.prev());
    }
}

test "blank lines are passed over and still counted" {
    const got = try backwards("{\"kind\":\"a\"}\n\n   \n{\"kind\":\"b\"}\n", .{});
    defer freeAll(got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("{\"kind\":\"b\"}", got[0]);

    var fixture = try Fixture.init("{\"kind\":\"a\"}\n\n   \n{\"kind\":\"b\"}\n", 64);
    defer fixture.deinit();
    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{});
    defer tail.deinit();
    try testing.expectEqual(@as(u64, 1), (try tail.prev()).?.number);
    // Two blank lines lie between them, and they are counted.
    try testing.expectEqual(@as(u64, 4), (try tail.prev()).?.number);
}

test "keep is what makes a value outlive its line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var kept: Event = undefined;
    {
        var fixture = try Fixture.init("{\"kind\":\"a\"}\n{\"kind\":\"b\\u0063\"}\n", 64);
        defer fixture.deinit();

        var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{ .block_bytes = 4 });
        defer tail.deinit();

        kept = try tail.keep(arena.allocator(), (try tail.prev()).?);
        // Read on, so the block buffer is shuffled under it.
        while (try tail.prev()) |_| {}
    }
    try testing.expectEqualStrings("bc", kept.kind);
}

test "a file with no end cannot be tailed" {
    // `Io.File.Reader` in streaming mode has no size to start from.
    var fixture = try Fixture.init("{\"kind\":\"a\"}\n", 64);
    defer fixture.deinit();

    var streaming = fixture.file.readerStreaming(testing.io, fixture.buffer);
    streaming.size = null;
    streaming.size_err = error.Streaming;
    try testing.expectError(error.Streaming, Tail(Event).init(testing.allocator, &streaming, .{}));
}

test "a line read backwards knows the offset it began at" {
    const input =
        "\xEF\xBB\xBF" ++
        "{\"kind\":\"a\"}\n" ++
        "\n" ++
        "{\"kind\":\"b\"}\r\n" ++
        "{\"kind\":\"c\"}";

    for ([_]usize{ 1, 5, 64, 4096 }) |block| {
        var fixture = try Fixture.init(input, 64);
        defer fixture.deinit();

        var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{ .block_bytes = block });
        defer tail.deinit();

        while (try tail.prev()) |line| {
            // The offset a seek needs: the bytes there are the line's bytes.
            // The mark is not one of them, so the last line's offset is 3.
            try testing.expectEqualStrings(
                line.line,
                input[@intCast(line.offset)..][0..line.line.len],
            );
            try testing.expectEqual(tail.offset, line.offset);
        }
    }
}

test "skipped counts what a tolerant backwards read lost" {
    var fixture = try Fixture.init(
        \\{"kind":"a"}
        \\not json
        \\
        \\{"kind":"b"}
        \\
    , 64);
    defer fixture.deinit();

    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{ .on_malformed = .skip });
    defer tail.deinit();

    var seen: usize = 0;
    while (try tail.prev()) |_| seen += 1;
    try testing.expectEqual(@as(usize, 2), seen);
    try testing.expectEqual(@as(u64, 1), tail.skipped);
}
