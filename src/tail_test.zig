//! tail scenarios through the public API.
const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const strand = @import("strand.zig");
const Tail = strand.Tail;
const line_mod = @import("line.zig");
const Fault = line_mod.Fault;
const Line = line_mod.Line;
const testing = std.testing;

const fixtures = @import("testing/fixtures.zig");
const Fixture = fixtures.Fixture;
const Event = fixtures.Event;

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

test "tail snapshots the current file length rather than a reader's cached size" {
    const first = "{\"kind\":\"first\"}\n";
    const second = "{\"kind\":\"second\"}\n";
    var fixture = try Fixture.init(first, 64);
    defer fixture.deinit();

    try testing.expectEqual(@as(u64, first.len), try fixture.reader.getSize());
    try fixture.write_file.writePositionalAll(testing.io, second, first.len);

    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{});
    defer tail.deinit();
    try testing.expectEqualStrings("second", (try tail.prev()).?.value.kind);
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

test "a zero block size uses the smallest supported block" {
    var fixture = try Fixture.init("{\"kind\":\"only\"}\n", 64);
    defer fixture.deinit();

    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{ .block_bytes = 0 });
    defer tail.deinit();
    try testing.expectEqualStrings("only", (try tail.prev()).?.value.kind);
}

test "the tail bound excludes CRLF and a leading byte-order mark" {
    var fixture = try Fixture.init("\xEF\xBB\xBF{}\r\n", 64);
    defer fixture.deinit();

    var tail: Tail(std.json.Value) = try .init(testing.allocator, &fixture.reader, .{
        .max_line_bytes = 2,
    });
    defer tail.deinit();
    const line = (try tail.prev()).?;
    try testing.expectEqualStrings("{}", line.line);
    try testing.expectEqual(@as(u64, 3), line.offset);
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
    try testing.expectEqual(@as(u64, 2), tail.fault.line);
    // And placed within itself, the same way a forwards read places it.
    try testing.expectEqual(@as(?usize, 1), tail.fault.offset);
    try testing.expectEqual(error.SyntaxError, tail.fault.err.?);
    try testing.expectEqualStrings("first", (try tail.prev()).?.value.kind);
    try testing.expectEqual(@as(?Line(Event), null), try tail.prev());
}

test "a control byte is reported with the line and the offset" {
    var fixture = try Fixture.init("{\"kind\":\"a\"}\n{\"kind\":\"b\x00\"}\n", 64);
    defer fixture.deinit();

    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{});
    defer tail.deinit();

    try testing.expectError(error.ControlByte, tail.prev());
    try testing.expectEqual(@as(u64, 1), tail.fault.line);
    try testing.expectEqual(@as(?usize, 10), tail.fault.offset);
    try testing.expectEqualStrings("a", (try tail.prev()).?.value.kind);
}

test "an over-long line is discarded whole and the one before it is still read" {
    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    var writer: strand.Writer(Event) = .init(&input.writer, .{});
    try writer.write(.{ .kind = "short", .at = 1 });
    try writer.write(.{ .kind = &@as([300]u8, @splat('x')), .at = 2 });
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
        try testing.expectEqual(@as(u64, 2), tail.fault.line);
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

test "a separated file is read backwards the same way" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: strand.Writer(Event) = .init(&out.writer, .{ .record_separator = true });
    try writer.writeAll(&.{
        .{ .kind = "a", .at = 1 },
        .{ .kind = "b", .at = 2 },
        .{ .kind = "c", .at = 3 },
    });

    var fixture = try Fixture.init(out.written(), 64);
    defer fixture.deinit();

    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{
        .record_separator = true,
        .block_bytes = 8,
    });
    defer tail.deinit();

    for ([_][]const u8{ "c", "b", "a" }) |want| {
        const line = (try tail.prev()).?;
        try testing.expectEqualStrings(want, line.value.kind);
        // The separator is where the record begins, backwards as forwards.
        try testing.expectEqual(
            @as(u8, strand.separator),
            out.written()[@intCast(line.offset)],
        );
    }
    try testing.expectEqual(@as(?Line(Event), null), try tail.prev());
}

test "a line with no record on it is not a malformed record" {
    var fixture = try Fixture.init("\x1e{\"kind\":\"a\"}\nnothing\n\x1e{\"kind\":\"c\"}\n", 64);
    defer fixture.deinit();

    var tail: Tail(Event) = try .init(testing.allocator, &fixture.reader, .{
        .record_separator = true,
    });
    defer tail.deinit();

    try testing.expectEqualStrings("c", (try tail.prev()).?.value.kind);
    try testing.expectError(error.MissingSeparator, tail.prev());
    try testing.expectEqual(@as(u64, 2), tail.fault.line);
    try testing.expectEqualStrings("a", (try tail.prev()).?.value.kind);
}

test "a file that shrinks under a tail is reported rather than misread" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "log.jsonl",
        .data = fixtures.repeat("{\"kind\":\"a\"}\n", 400),
    });

    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);
    var buffer: [64]u8 = undefined;
    var reader = file.reader(testing.io, &buffer);

    // A tail is a view of the file as it was when it opened, so a rotation
    // that empties the file under it is a fact it can state rather than a
    // block of some other file spliced onto the last one read.
    // One line per block, so that every `prev` has to go back to the file.
    var tail: Tail(Event) = try .init(testing.allocator, &reader, .{ .block_bytes = 13 });
    defer tail.deinit();
    try testing.expectEqualStrings("a", (try tail.prev()).?.value.kind);

    const writer = try tmp.dir.openFile(testing.io, "log.jsonl", .{ .mode = .read_write });
    defer writer.close(testing.io);
    try writer.setLength(testing.io, 0);

    try testing.expectError(error.Truncated, tail.prev());
}

test "a separated tail bounds only its JSON payload" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = line_mod.bom ++ "\x1e{}\r\n" ++ fixtures.repeat("torn", 512) ++ "\x1e{}\r\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log", .data = data });
    const file = try tmp.dir.openFile(testing.io, "log", .{});
    defer file.close(testing.io);
    for ([_]usize{ 1, 2, 3, 7, 64, data.len }) |block_bytes| {
        var source = file.reader(testing.io, &.{});
        var tail = try Tail(struct {}).init(testing.allocator, &source, .{
            .record_separator = true,
            .max_line_bytes = 2,
            .block_bytes = block_bytes,
        });
        defer tail.deinit();
        const last = (try tail.prev()).?;
        try testing.expectEqualStrings("{}", last.line);
        try testing.expectEqual(@as(u64, data.len - 5), last.offset);
        try testing.expectEqual(@as(u64, 1), last.number);
        const first = (try tail.prev()).?;
        try testing.expectEqualStrings("{}", first.line);
        try testing.expectEqual(@as(u64, line_mod.bom.len), first.offset);
        try testing.expectEqual(@as(u64, 2), first.number);
        try testing.expect(try tail.prev() == null);
        // A torn prefix cannot make the retained line grow with it.
        try testing.expect(tail.buf.capacity < 128 or block_bytes == data.len);
    }
}

test "a separated tail accepts the exact payload bound and refuses the next byte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log", .data = "\x1e{}\n" ++ fixtures.repeat("prefix", 24) ++ "\x1e{} \r\n" });
    const file = try tmp.dir.openFile(testing.io, "log", .{});
    defer file.close(testing.io);
    for ([_]usize{ 1, 2, 7, 4096 }) |block_bytes| {
        var source = file.reader(testing.io, &.{});
        var tail = try Tail(struct {}).init(testing.allocator, &source, .{
            .record_separator = true,
            .max_line_bytes = 2,
            .block_bytes = block_bytes,
        });
        defer tail.deinit();
        try testing.expectError(error.LineTooLong, tail.prev());
        try testing.expectEqual(@as(u64, 4 + 6 * 24), tail.offset);
        const first = (try tail.prev()).?;
        try testing.expectEqualStrings("{}", first.line);
        try testing.expect(try tail.prev() == null);
    }
}

test "a backward read takes the record after a torn one on its line" {
    const input = "\x1e{\"kind\":\"a\"}\n\x1e{\"kind\":\"to\x1e{\"kind\":\"b\"}\n";
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log", .data = input });
    const file = try tmp.dir.openFile(testing.io, "log", .{});
    defer file.close(testing.io);
    for ([_]usize{ 1, 3, 4096 }) |block_bytes| {
        var source = file.reader(testing.io, &.{});
        var tail = try Tail(Event).init(testing.allocator, &source, .{
            .record_separator = true,
            .block_bytes = block_bytes,
        });
        defer tail.deinit();
        const b = (try tail.prev()).?;
        try testing.expectEqualStrings("b", b.value.kind);
        try testing.expectEqual(@as(u64, std.mem.findScalarLast(u8, input, 0x1e).?), b.offset);
        try testing.expectEqual(@as(u64, 1), tail.skipped);
        try testing.expectEqualStrings("a", (try tail.prev()).?.value.kind);
        try testing.expectEqual(@as(?strand.Line(Event), null), try tail.prev());
    }
}

test "separated forward and backward framing agree at every payload boundary" {
    for ([_][]const u8{
        "",                      "\n",                                              " \t\r\n",                 line_mod.bom ++ " \t\n",   "\xef\xbb \n",
        "no separator at all\n", "torn\x1e{}\r\n",                                  "\x1e{}",                  "\x1e\n",                  "torn\x1e \r\n",
        "\x1e{}\x1e{}\n",        "\x1e" ++ @as([512]u8, @splat('x')) ++ "\x1e{}\n", "\x1e{\"k\":\"to\x1e{}\n", "torn\x1e{\x1e\x1e{}\r\n",
    }) |input| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "log", .data = input });
        const file = try tmp.dir.openFile(testing.io, "log", .{});
        defer file.close(testing.io);
        for ([_]usize{ 1, 2, 7, 4096 }) |block_bytes| {
            for (0..9) |max| {
                for ([_]bool{ false, true }) |crlf| {
                    for ([_]bool{ false, true }) |skip_blank| {
                        var passed = false;
                        defer if (!passed) std.debug.print("input={any}, block={d}, max={d}, crlf={}, blank={}\n", .{ input, block_bytes, max, crlf, skip_blank });
                        var forward_source: std.Io.Reader = .fixed(input);
                        var forward: strand.LineReader = .init(testing.allocator, &forward_source, .{
                            .record_separator = true,
                            .max_line_bytes = max,
                            .crlf = crlf,
                            .skip_blank = skip_blank,
                        });
                        defer forward.deinit();
                        var source = file.reader(testing.io, &.{});
                        var tail = try Tail(struct {}).init(testing.allocator, &source, .{
                            .record_separator = true,
                            .max_line_bytes = max,
                            .block_bytes = block_bytes,
                            .crlf = crlf,
                            .skip_blank = skip_blank,
                        });
                        defer tail.deinit();
                        const backward = tail.prevRaw();
                        if (forward.next()) |expected| {
                            const actual = try backward;
                            if (expected) |line| {
                                try testing.expect(actual != null);
                                try testing.expectEqualStrings(line.line, actual.?.line);
                                try testing.expectEqual(line.offset, actual.?.offset);
                            } else try testing.expect(actual == null);
                        } else |err| try testing.expectError(err, backward);
                        passed = true;
                    }
                }
            }
        }
    }
}

test "a pipe has no end to start a backward read from" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const fds = try std.Io.Threaded.pipe2(.{});
    const read_end: std.Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const write_end: std.Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer read_end.close(testing.io);
    defer write_end.close(testing.io);
    // Something is buffered in it, which is what a size of the pipe reports
    // on some systems.
    try write_end.writeStreamingAll(testing.io, "{\"kind\":\"a\"}\n");
    var source = read_end.reader(testing.io, &.{});
    try testing.expectError(error.Streaming, Tail(Event).init(testing.allocator, &source, .{}));
}
