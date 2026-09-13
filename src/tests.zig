//! The behaviour of `zjsonl` spelled out as scenarios. The short tests that
//! introduce each declaration live beside it in `zjsonl.zig`; these are the
//! ones that need a stream, a malformed line, or a look at where memory came
//! from.

const std = @import("std");
const testing = std.testing;
const zjsonl = @import("zjsonl.zig");

/// A line of a log: an optional field, two defaults, an enum, a nested array
/// and a nested struct.
const Event = struct {
    kind: []const u8,
    at: u64 = 0,
    level: enum { debug, info, warn, err } = .info,
    note: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    span: struct { id: u32, parent: ?u32 = null } = .{ .id = 0 },
};

/// A line of a protocol: `std.json` writes and reads a tagged union as a
/// one-key object naming the arm.
const Message = union(enum) {
    hello: struct { version: u8 },
    ping: u64,
    goodbye: struct { reason: []const u8 },
};

/// Reads `input` as a stream of `T` and collects what comes back, keeping
/// every value in `arena` so the whole batch outlives the reader.
fn readAll(
    comptime T: type,
    arena: std.mem.Allocator,
    input: []const u8,
    options: zjsonl.Reader(T).Options,
) !std.ArrayList(T) {
    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(T) = .init(testing.allocator, &source, options);
    defer reader.deinit();

    var out: std.ArrayList(T) = .empty;
    errdefer out.deinit(testing.allocator);
    while (try reader.next()) |line| {
        try out.append(testing.allocator, try reader.keep(line, arena));
    }
    return out;
}

test "round trip: what the writer writes, the reader reads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const events = [_]Event{
        .{ .kind = "open", .at = 1, .tags = &.{ "io", "file" } },
        .{ .kind = "warn \"quoted\"", .at = 2, .level = .warn, .note = "line\nbreak" },
        .{ .kind = "close", .at = 3, .span = .{ .id = 7, .parent = 7 } },
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: zjsonl.Writer(Event) = .init(&out.writer, .{});
    for (events) |event| try writer.write(event);

    try testing.expectEqual(@as(u64, 3), writer.count);
    // One line per value, whatever the value holds.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out.written(), "\n"));
    // `note` is null on two of the three, and left out rather than written.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\"note\""));

    var parsed = try readAll(Event, arena.allocator(), out.written(), .{});
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(events.len, parsed.items.len);
    for (events, parsed.items) |want, got| {
        try testing.expectEqualStrings(want.kind, got.kind);
        try testing.expectEqual(want.at, got.at);
        try testing.expectEqual(want.level, got.level);
        try testing.expectEqual(want.span.id, got.span.id);
        try testing.expectEqual(want.span.parent, got.span.parent);
        try testing.expectEqual(want.tags.len, got.tags.len);
        for (want.tags, got.tags) |a, b| try testing.expectEqualStrings(a, b);
        if (want.note) |note| try testing.expectEqualStrings(note, got.note.?) else try testing.expectEqual(@as(?[]const u8, null), got.note);
    }
}

test "round trip: tagged unions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: zjsonl.Writer(Message) = .init(&out.writer, .{});
    try writer.write(.{ .hello = .{ .version = 3 } });
    try writer.write(.{ .ping = 99 });
    try writer.write(.{ .goodbye = .{ .reason = "done" } });

    // The tag of each line is readable without parsing it.
    var it = zjsonl.lines(out.written());
    try testing.expectEqual(.hello, zjsonl.tagOf(Message, it.next().?.bytes).?);
    try testing.expectEqual(.ping, zjsonl.tagOf(Message, it.next().?.bytes).?);
    try testing.expectEqual(.goodbye, zjsonl.tagOf(Message, it.next().?.bytes).?);

    var parsed = try readAll(Message, arena.allocator(), out.written(), .{});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 3), parsed.items[0].hello.version);
    try testing.expectEqual(@as(u64, 99), parsed.items[1].ping);
    try testing.expectEqualStrings("done", parsed.items[2].goodbye.reason);
}

test "unknown fields are ignored, missing fields take their defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const input =
        \\{"kind":"open","at":1,"unheard_of":{"nested":[1,2,3]},"also":null}
        \\{"kind":"open"}
        \\
    ;
    var parsed = try readAll(Event, arena.allocator(), input, .{});
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), parsed.items.len);
    try testing.expectEqual(@as(u64, 1), parsed.items[0].at);
    try testing.expectEqual(@as(u64, 0), parsed.items[1].at);
    try testing.expectEqual(.info, parsed.items[1].level);
    try testing.expectEqual(@as(usize, 0), parsed.items[1].tags.len);
    try testing.expectEqual(@as(u32, 0), parsed.items[1].span.id);

    // With the option off, the same line is a hard error.
    var strict: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &strict, .{ .ignore_unknown_fields = false });
    defer reader.deinit();
    try testing.expectError(error.MalformedLine, reader.next());
    try testing.expectEqual(error.UnknownField, reader.last_error.?);
}

test "a malformed line is reported by number, and the stream survives it" {
    const input =
        \\{"kind":"first"}
        \\{"kind":"second",,}
        \\{"kind":"third"}
        \\
    ;

    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    try testing.expectEqualStrings("first", (try reader.next()).?.value.kind);
    try testing.expectError(error.MalformedLine, reader.next());
    try testing.expectEqual(@as(u64, 2), reader.last_error_line);
    try testing.expectEqual(error.SyntaxError, reader.last_error.?);

    // The bad line was consumed whole, so reading continues past it.
    const third = (try reader.next()).?;
    try testing.expectEqualStrings("third", third.value.kind);
    try testing.expectEqual(@as(u64, 3), third.number);
    try testing.expectEqual(@as(?zjsonl.Line(Event), null), try reader.next());
}

test "on_malformed = .skip passes over the bad line" {
    const input =
        \\{"kind":"first"}
        \\not json at all
        \\{"kind":"third"}
        \\
    ;

    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{ .on_malformed = .skip });
    defer reader.deinit();

    try testing.expectEqualStrings("first", (try reader.next()).?.value.kind);
    const third = (try reader.next()).?;
    try testing.expectEqualStrings("third", third.value.kind);
    try testing.expectEqual(@as(u64, 3), third.number);
    // The skip is not silent: it is on the record.
    try testing.expectEqual(@as(u64, 2), reader.last_error_line);
    try testing.expect(reader.last_error != null);
}

test "the last line needs no newline, and blank lines do not break numbering" {
    const input = "{\"kind\":\"first\"}\n\n   \n{\"kind\":\"last\"}";

    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    try testing.expectEqual(@as(u64, 1), (try reader.next()).?.number);
    const last = (try reader.next()).?;
    try testing.expectEqualStrings("last", last.value.kind);
    try testing.expectEqual(@as(u64, 4), last.number);
    try testing.expectEqual(@as(?zjsonl.Line(Event), null), try reader.next());

    // Without skip_blank a blank line is a line, and it is not a `T`.
    var strict: std.Io.Reader = .fixed(input);
    var keeper: zjsonl.Reader(Event) = .init(testing.allocator, &strict, .{ .skip_blank = false });
    defer keeper.deinit();
    _ = try keeper.next();
    try testing.expectError(error.MalformedLine, keeper.next());
    try testing.expectEqual(@as(u64, 2), keeper.last_error_line);
}

test "CRLF is tolerated, and the terminator is not part of the line" {
    const input = "{\"kind\":\"first\"}\r\n{\"kind\":\"second\"}\r\n";

    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    const first = (try reader.next()).?;
    try testing.expectEqualStrings("{\"kind\":\"first\"}", first.line);
    try testing.expectEqualStrings("second", (try reader.next()).?.value.kind);
}

test "max_line_bytes is enforced, and the reader continues after the long line" {
    const input =
        \\{"kind":"short"}
        \\{"kind":"an extravagantly long line that runs well past the bound"}
        \\{"kind":"short again"}
        \\
    ;

    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{ .max_line_bytes = 32 });
    defer reader.deinit();

    try testing.expectEqualStrings("short", (try reader.next()).?.value.kind);
    try testing.expectError(error.LineTooLong, reader.next());
    try testing.expectEqual(@as(u64, 2), reader.last_error_line);
    // No parse was attempted, so there is no parse error to report.
    try testing.expectEqual(@as(?zjsonl.ParseLineError, null), reader.last_error);

    const third = (try reader.next()).?;
    try testing.expectEqualStrings("short again", third.value.kind);
    try testing.expectEqual(@as(u64, 3), third.number);

    // A line of exactly the bound is accepted; one byte more is not.
    const exact = "{\"kind\":\"0123456789012345\"}";
    try testing.expectEqual(@as(usize, 27), exact.len);
    var tight: std.Io.Reader = .fixed(exact);
    var strict: zjsonl.Reader(Event) = .init(testing.allocator, &tight, .{ .max_line_bytes = exact.len });
    defer strict.deinit();
    try testing.expectEqualStrings("0123456789012345", (try strict.next()).?.value.kind);

    var tighter: std.Io.Reader = .fixed(exact);
    var too_strict: zjsonl.Reader(Event) = .init(testing.allocator, &tighter, .{ .max_line_bytes = exact.len - 1 });
    defer too_strict.deinit();
    try testing.expectError(error.LineTooLong, too_strict.next());
}

test "strings borrow from the line when they can, and are copied when they cannot" {
    const input =
        \\{"kind":"plain"}
        \\{"kind":"esc\u0061ped"}
        \\
    ;

    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    const plain = (try reader.next()).?;
    try testing.expectEqualStrings("plain", plain.value.kind);
    // No copy: the field is a view into the line's own bytes.
    try testing.expect(within(plain.value.kind, plain.line));

    const escaped = (try reader.next()).?;
    try testing.expectEqualStrings("escaped", escaped.value.kind);
    // A copy: the decoded bytes are not in the line, so they are in the arena.
    try testing.expect(!within(escaped.value.kind, escaped.line));
}

/// True when `inner` points into `outer`.
fn within(inner: []const u8, outer: []const u8) bool {
    return @intFromPtr(inner.ptr) >= @intFromPtr(outer.ptr) and
        @intFromPtr(inner.ptr) + inner.len <= @intFromPtr(outer.ptr) + outer.len;
}

test "keep is what makes a value outlive its line" {
    const input =
        \\{"kind":"kept","note":"a\tnote"}
        \\{"kind":"overwritten and then some, to be sure the buffer is reused"}
        \\
    ;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var kept: Event = undefined;
    {
        var source: std.Io.Reader = .fixed(input);
        var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{});
        defer reader.deinit();

        const first = (try reader.next()).?;
        kept = try reader.keep(first, arena.allocator());
        // The copy borrows neither the line buffer nor anything in it.
        try testing.expect(!within(kept.kind, first.line));

        // Read on: the line the value came from is gone by now.
        _ = try reader.next();
        try testing.expectEqual(@as(?zjsonl.Line(Event), null), try reader.next());
    }

    // The reader is deinitialized and the kept value is still whole.
    try testing.expectEqualStrings("kept", kept.kind);
    try testing.expectEqualStrings("a\tnote", kept.note.?);
}

test "kindOf and tagOf answer null rather than guess" {
    // An escaped key is not decoded, and saying so is the contract.
    try testing.expectEqual(@as(?[]const u8, null), zjsonl.kindOf("{\"ki\\u006ed\":1}"));
    try testing.expectEqual(@as(?std.meta.Tag(Message), null), zjsonl.tagOf(Message, "{\"pi\\u006eg\":1}"));
    // Neither is anything that is not a one-key object.
    try testing.expectEqual(@as(?[]const u8, null), zjsonl.kindOf("[{\"kind\":1}]"));
    try testing.expectEqual(@as(?[]const u8, null), zjsonl.kindOf("null"));
    try testing.expectEqual(@as(?[]const u8, null), zjsonl.kindOf("42"));
    try testing.expectEqual(@as(?[]const u8, null), zjsonl.kindOf("\"kind\""));
    try testing.expectEqual(@as(?[]const u8, null), zjsonl.kindOf(""));
    try testing.expectEqual(@as(?[]const u8, null), zjsonl.kindOf("{\"unterminated"));
    try testing.expectEqual(@as(?[]const u8, null), zjsonl.kindOf("{\"kind\"}"));
    // An empty key is a key.
    try testing.expectEqualStrings("", zjsonl.kindOf("{\"\":1}").?);
}

test "a long stream costs what one line costs" {
    const line_count = 10_000;

    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    var writer: zjsonl.Writer(Event) = .init(&input.writer, .{});
    for (0..line_count) |i| {
        try writer.write(.{ .kind = "tick", .at = i, .tags = &.{"generated"} });
    }

    var source: std.Io.Reader = .fixed(input.written());
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    var seen: u64 = 0;
    while (try reader.next()) |line| : (seen += 1) {
        try testing.expectEqual(seen, line.value.at);
        try testing.expectEqualStrings("generated", line.value.tags[0]);
    }
    try testing.expectEqual(@as(u64, line_count), seen);
    try testing.expectEqual(@as(u64, line_count), reader.number);

    // Bounded memory: both of the reader's buffers are sized by the longest
    // line, not by the number of lines. A line here is under 100 bytes.
    try testing.expect(reader.line_buf.writer.buffer.len < 1024);
    try testing.expect(reader.arena.queryCapacity() < 64 * 1024);
}

test "parseLine and lines: the buffer already in memory" {
    const buffer =
        \\{"kind":"open"}
        \\{"kind":"close"}
    ;

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var count: usize = 0;
    var it = zjsonl.lines(buffer);
    while (it.next()) |line| : (count += 1) {
        const event = try zjsonl.parseLine(Event, arena.allocator(), line.bytes, .{});
        try testing.expectEqual(line.number, count + 1);
        try testing.expect(event.kind.len > 0);
        // Nothing was copied: the field is a view into the original buffer.
        try testing.expect(within(event.kind, buffer));
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "parseLine with copy_strings borrows nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const line = "{\"kind\":\"open\"}";
    const event = try zjsonl.parseLine(Event, arena.allocator(), line, .{ .copy_strings = true });
    try testing.expectEqualStrings("open", event.kind);
    try testing.expect(!within(event.kind, line));
}

test "an empty stream is a stream" {
    var source: std.Io.Reader = .fixed("");
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    try testing.expectEqual(@as(?zjsonl.Line(Event), null), try reader.next());
    try testing.expectEqual(@as(u64, 0), reader.number);
}
