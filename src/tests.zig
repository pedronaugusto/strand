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
        try out.append(testing.allocator, try reader.keep(arena, line));
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
    try testing.expectEqual(.hello, zjsonl.tagOf(Message, it.next().?.line).?);
    try testing.expectEqual(.ping, zjsonl.tagOf(Message, it.next().?.line).?);
    try testing.expectEqual(.goodbye, zjsonl.tagOf(Message, it.next().?.line).?);

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
        kept = try reader.keep(arena.allocator(), first);
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
        const event = try zjsonl.parseLine(Event, arena.allocator(), line.line, .{});
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

test "a byte-order mark belongs to the file, not to its first line" {
    const input = "\xEF\xBB\xBF{\"kind\":\"first\"}\n{\"kind\":\"second\"}\n";

    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    const first = (try reader.next()).?;
    try testing.expectEqualStrings("first", first.value.kind);
    try testing.expectEqualStrings("{\"kind\":\"first\"}", first.line);
    try testing.expectEqual(@as(u64, 1), first.number);
    try testing.expectEqualStrings("second", (try reader.next()).?.value.kind);

    // With the option off, `std.json` is shown the mark and says so.
    var marked: std.Io.Reader = .fixed(input);
    var strict: zjsonl.Reader(Event) = .init(testing.allocator, &marked, .{ .skip_bom = false });
    defer strict.deinit();
    try testing.expectError(error.MalformedLine, strict.next());

    // `lines` agrees with the reader about where the first line starts.
    var it = zjsonl.lines(input);
    try testing.expectEqualStrings("{\"kind\":\"first\"}", it.next().?.line);
}

test "a control byte is a damaged line, named by number and offset" {
    const input = "{\"kind\":\"first\"}\n{\"kind\":\"se\x00cond\"}\n{\"kind\":\"third\"}\n";

    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    try testing.expectEqualStrings("first", (try reader.next()).?.value.kind);
    try testing.expectError(error.ControlByte, reader.next());
    try testing.expectEqual(@as(u64, 2), reader.last_error_line);
    try testing.expectEqual(@as(?usize, 11), reader.last_error_offset);
    // It never reached `std.json`, so there is nothing of `std.json`'s to say.
    try testing.expectEqual(@as(?zjsonl.ParseLineError, null), reader.last_error);
    // And the stream is where it was: the next line is the next line.
    const third = (try reader.next()).?;
    try testing.expectEqualStrings("third", third.value.kind);
    try testing.expectEqual(@as(u64, 3), third.number);

    // Skipping treats it the way it treats any other line it cannot use.
    var skipping: std.Io.Reader = .fixed(input);
    var skipper: zjsonl.Reader(Event) = .init(testing.allocator, &skipping, .{ .on_malformed = .skip });
    defer skipper.deinit();
    try testing.expectEqualStrings("first", (try skipper.next()).?.value.kind);
    try testing.expectEqualStrings("third", (try skipper.next()).?.value.kind);

    // With the scan off the line is still refused, but by `std.json`, which
    // has no idea what it was looking at.
    var raw: std.Io.Reader = .fixed(input);
    var tolerant: zjsonl.Reader(Event) = .init(testing.allocator, &raw, .{ .reject_control_bytes = false });
    defer tolerant.deinit();
    _ = try tolerant.next();
    try testing.expectError(error.MalformedLine, tolerant.next());
    try testing.expectEqual(error.SyntaxError, tolerant.last_error.?);

    // A tab is whitespace to JSON, so it is not damage.
    var tabbed: std.Io.Reader = .fixed("{\"kind\":\t\"fine\"}\n");
    var tabs: zjsonl.Reader(Event) = .init(testing.allocator, &tabbed, .{});
    defer tabs.deinit();
    try testing.expectEqualStrings("fine", (try tabs.next()).?.value.kind);
}

test "pretty: a record written over several lines is read back as one" {
    const events = [_]Event{
        .{ .kind = "open", .at = 1, .tags = &.{ "io", "file" } },
        .{ .kind = "close", .at = 2, .span = .{ .id = 7, .parent = 7 } },
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: zjsonl.Writer(Event) = .init(&out.writer, .{ .format = .pretty });
    try writer.writeAll(&events);

    // It really is more than one line per record.
    try testing.expect(std.mem.count(u8, out.written(), "\n") > events.len);

    var source: std.Io.Reader = .fixed(out.written());
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{ .format = .pretty });
    defer reader.deinit();

    const first = (try reader.next()).?;
    try testing.expectEqualStrings("open", first.value.kind);
    // The record's number is the number of the line it started on.
    try testing.expectEqual(@as(u64, 1), first.number);
    // And its bytes are the whole record, newlines and all.
    try testing.expect(std.mem.indexOfScalar(u8, first.line, '\n') != null);

    const second = (try reader.next()).?;
    try testing.expectEqualStrings("close", second.value.kind);
    try testing.expectEqual(@as(u32, 7), second.value.span.id);
    try testing.expectEqual(@as(?zjsonl.Line(Event), null), try reader.next());

    // A `.pretty` reader reads a minified stream too: a record that parses on
    // its first line never asks for a second.
    var minified: std.Io.Writer.Allocating = .init(testing.allocator);
    defer minified.deinit();
    var plain: zjsonl.Writer(Event) = .init(&minified.writer, .{});
    try plain.writeAll(&events);

    var flat: std.Io.Reader = .fixed(minified.written());
    var tolerant: zjsonl.Reader(Event) = .init(testing.allocator, &flat, .{ .format = .pretty });
    defer tolerant.deinit();
    try testing.expectEqual(@as(u64, 1), (try tolerant.next()).?.number);
    try testing.expectEqual(@as(u64, 2), (try tolerant.next()).?.number);
    try testing.expectEqual(@as(?zjsonl.Line(Event), null), try tolerant.next());
}

test "pretty: a record that never finishes is one malformed record" {
    const input =
        \\{
        \\  "kind": "truncated",
    ;
    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{ .format = .pretty });
    defer reader.deinit();

    try testing.expectError(error.MalformedLine, reader.next());
    // Blamed on the line it began on, not the one it ran out on.
    try testing.expectEqual(@as(u64, 1), reader.last_error_line);
    try testing.expectEqual(error.UnexpectedEndOfInput, reader.last_error.?);
    try testing.expectEqual(@as(?zjsonl.Line(Event), null), try reader.next());
}

test "pretty: the bound is on the record, not on one of its lines" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: zjsonl.Writer(Event) = .init(&out.writer, .{ .format = .pretty });
    try writer.write(.{ .kind = "open", .at = 1, .tags = &.{ "a", "b", "c" } });
    try writer.write(.{ .kind = "after", .at = 2 });

    var source: std.Io.Reader = .fixed(out.written());
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{
        .format = .pretty,
        // Every physical line of the record fits; the record does not.
        .max_line_bytes = 24,
    });
    defer reader.deinit();
    try testing.expectError(error.LineTooLong, reader.next());
}

test "writeAll writes the batch and counts it" {
    const events = [_]Event{
        .{ .kind = "one", .at = 1 },
        .{ .kind = "two", .at = 2 },
        .{ .kind = "three", .at = 3 },
    };

    var batched: std.Io.Writer.Allocating = .init(testing.allocator);
    defer batched.deinit();
    var batch: zjsonl.Writer(Event) = .init(&batched.writer, .{});
    try batch.writeAll(&events);

    var looped: std.Io.Writer.Allocating = .init(testing.allocator);
    defer looped.deinit();
    var loop: zjsonl.Writer(Event) = .init(&looped.writer, .{});
    for (events) |event| try loop.write(event);

    // The same bytes and the same count: it is the loop, not another format.
    try testing.expectEqualStrings(looped.written(), batched.written());
    try testing.expectEqual(loop.count, batch.count);
    try testing.expectEqual(@as(u64, 3), batch.count);
}

test "write escapes every terminator that could break the framing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Every byte a line could be broken by, in a string field, plus the two
    // Unicode separators that some readers treat as line ends.
    const hostile = [_][]const u8{
        "\n",       "\r",            "\r\n", "\n\r",
        "a\nb\nc",  "\t",            "\x00", "\x1f",
        "\u{2028}", "\u{2029}",      "}\n{", "\\n",
        "\"\n\"",   "line\r\nbreak",
    };

    for (hostile) |raw| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var writer: zjsonl.Writer(Event) = .init(&out.writer, .{});
        try writer.write(.{ .kind = raw, .at = 1, .note = raw });

        // One record, one line: the only `\n` is the one the writer added.
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\n"));
        try testing.expect(std.mem.endsWith(u8, out.written(), "\n"));
        // And no raw control byte survived into the line either.
        try testing.expectEqual(
            @as(?usize, null),
            zjsonl.indexOfControl(out.written()[0 .. out.written().len - 1]),
        );

        // Which means it reads back as what went in.
        var source: std.Io.Reader = .fixed(out.written());
        var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{});
        defer reader.deinit();
        const line = (try reader.next()).?;
        try testing.expectEqualStrings(raw, line.value.kind);
        try testing.expectEqualStrings(raw, line.value.note.?);
        try testing.expectEqual(@as(?zjsonl.Line(Event), null), try reader.next());
    }
}

test "require_terminator: an unfinished last line is not a line" {
    const input = "{\"kind\":\"whole\"}\n{\"kind\":\"hal";

    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{ .require_terminator = true });
    defer reader.deinit();

    try testing.expectEqualStrings("whole", (try reader.next()).?.value.kind);
    try testing.expectEqual(@as(?zjsonl.Line(Event), null), try reader.next());
    // The half-written line was not counted, so a follower can read it again.
    try testing.expectEqual(@as(u64, 1), reader.number);

    // Without the option, the same bytes are a line, and a bad one.
    var again: std.Io.Reader = .fixed(input);
    var plain: zjsonl.Reader(Event) = .init(testing.allocator, &again, .{});
    defer plain.deinit();
    _ = try plain.next();
    try testing.expectError(error.MalformedLine, plain.next());
    try testing.expectEqual(@as(u64, 2), plain.number);
}

/// Counts what an allocator was asked to do, and passes the asking on.
const Counting = struct {
    child: std.mem.Allocator,
    allocations: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocations += 1;
        return self.child.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocations += 1;
        return self.child.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
    }
};

test "a long stream stops allocating once its buffers have grown" {
    const line_count = 20_000;

    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    var writer: zjsonl.Writer(Event) = .init(&input.writer, .{});
    for (0..line_count) |i| {
        try writer.write(.{ .kind = "tick", .at = i, .tags = &.{ "generated", "here" } });
    }

    var counting: Counting = .{ .child = testing.allocator };
    var source: std.Io.Reader = .fixed(input.written());
    var reader: zjsonl.Reader(Event) = .init(counting.allocator(), &source, .{});
    defer reader.deinit();

    // The first thousand lines are where the line buffer and the arena reach
    // the size the longest line needs.
    var seen: usize = 0;
    while (seen < 1000) : (seen += 1) _ = (try reader.next()).?;
    const settled = counting.allocations;

    while (try reader.next()) |line| : (seen += 1) {
        try testing.expectEqual(seen, line.value.at);
    }
    try testing.expectEqual(@as(usize, line_count), seen);
    // Not one allocation for the other nineteen thousand lines: the line
    // buffer is reused and the arena is reset rather than freed.
    try testing.expectEqual(settled, counting.allocations);
}

test "a very large line is read without copying its strings" {
    const payload_len = 4 << 20;

    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    try input.writer.writeAll("{\"kind\":\"");
    try input.writer.splatByteAll('x', payload_len);
    try input.writer.writeAll("\",\"at\":1}\n{\"kind\":\"after\"}\n");

    var source: std.Io.Reader = .fixed(input.written());
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{
        .max_line_bytes = payload_len + 1024,
    });
    defer reader.deinit();

    const big = (try reader.next()).?;
    try testing.expectEqual(@as(usize, payload_len), big.value.kind.len);
    // Four megabytes that were never copied: the field is the line's bytes.
    try testing.expect(within(big.value.kind, big.line));
    // The arena holds nothing, because nothing needed unescaping.
    try testing.expect(reader.arena.queryCapacity() < 64 * 1024);

    try testing.expectEqualStrings("after", (try reader.next()).?.value.kind);
}
