//! The behaviour of `strand` spelled out as scenarios. The short tests that
//! introduce each declaration live beside it, in the file that declares it;
//! these are the ones that need a stream, a malformed line, or a look at
//! where memory came from.

const std = @import("std");
const testing = std.testing;
const strand = @import("strand.zig");
const fixtures = @import("fixtures.zig");

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
    options: strand.Reader(T).Options,
) !std.ArrayList(T) {
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(T) = .init(testing.allocator, &source, options);
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
    var writer: strand.Writer(Event) = .init(&out.writer, .{});
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
    var writer: strand.Writer(Message) = .init(&out.writer, .{});
    try writer.write(.{ .hello = .{ .version = 3 } });
    try writer.write(.{ .ping = 99 });
    try writer.write(.{ .goodbye = .{ .reason = "done" } });

    // The tag of each line is readable without parsing it.
    var it = strand.lines(out.written());
    try testing.expectEqual(.hello, strand.tagOf(Message, it.next().?.line).?);
    try testing.expectEqual(.ping, strand.tagOf(Message, it.next().?.line).?);
    try testing.expectEqual(.goodbye, strand.tagOf(Message, it.next().?.line).?);

    var parsed = try readAll(Message, arena.allocator(), out.written(), .{});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 3), parsed.items[0].hello.version);
    try testing.expectEqual(@as(u64, 99), parsed.items[1].ping);
    try testing.expectEqualStrings("done", parsed.items[2].goodbye.reason);
}

test "recursive pointer schemas use the standard JSON extension path" {
    const Node = struct {
        value: u8,
        next: ?*@This() = null,
    };
    const node: Node = .{ .value = 7 };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: strand.Writer(Node) = .init(&out.writer, .{});
    try writer.write(node);

    var source: std.Io.Reader = .fixed(out.written());
    var reader: strand.Reader(Node) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    const decoded = (try reader.next()).?.value;
    try testing.expectEqual(@as(u8, 7), decoded.value);
    try testing.expectEqual(@as(?*Node, null), decoded.next);
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
    var reader: strand.Reader(Event) = .init(testing.allocator, &strict, .{ .ignore_unknown_fields = false });
    defer reader.deinit();
    try testing.expectError(error.MalformedLine, reader.next());
    try testing.expectEqual(error.UnknownField, reader.fault.err.?);
}

test "a malformed line is reported by number, and the stream survives it" {
    const input =
        \\{"kind":"first"}
        \\{"kind":"second",,}
        \\{"kind":"third"}
        \\
    ;

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    try testing.expectEqualStrings("first", (try reader.next()).?.value.kind);
    try testing.expectError(error.MalformedLine, reader.next());
    try testing.expectEqual(@as(u64, 2), reader.fault.line);
    try testing.expectEqual(error.SyntaxError, reader.fault.err.?);

    // The bad line was consumed whole, so reading continues past it.
    const third = (try reader.next()).?;
    try testing.expectEqualStrings("third", third.value.kind);
    try testing.expectEqual(@as(u64, 3), third.number);
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
}

test "a malformed line says where in it the parse gave up" {
    const input =
        \\{"kind":"open",}
        \\{"kind":"open","at":}
        \\{"kind":"open"
        \\{"kind":"open"}
        \\
    ;

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    // The brace that turned out to be where a key had to be.
    try testing.expectError(error.MalformedLine, reader.next());
    try testing.expectEqual(error.SyntaxError, reader.fault.err.?);
    try testing.expectEqual(@as(?usize, 15), reader.fault.offset);

    // A value that is not there at all: the brace again, further along.
    try testing.expectError(error.MalformedLine, reader.next());
    try testing.expectEqual(@as(?usize, 20), reader.fault.offset);

    // A line cut off at its end has nowhere further to point than its end.
    try testing.expectError(error.MalformedLine, reader.next());
    try testing.expectEqual(error.UnexpectedEndOfInput, reader.fault.err.?);
    try testing.expectEqual(@as(?usize, 14), reader.fault.offset);

    // And a good line clears none of it and reports none of it.
    const good = (try reader.next()).?;
    try testing.expectEqualStrings("open", good.value.kind);
    try testing.expectEqual(@as(u64, 4), good.number);
}

test "an over-long line has no offset in it to report" {
    var source: std.Io.Reader = .fixed("{\"kind\":\"far too long for this\"}\n{\"kind\":\"ok\"}\n");
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{ .max_line_bytes = 8 });
    defer reader.deinit();

    // The line never reached `std.json`, so there is nothing to have a
    // place in: an invented one would be worse than none.
    try testing.expectError(error.LineTooLong, reader.next());
    try testing.expectEqual(@as(?usize, null), reader.fault.offset);
    try testing.expectEqual(@as(?strand.ParseLineError, null), reader.fault.err);
}

test "on_malformed = .skip passes over the bad line" {
    const input =
        \\{"kind":"first"}
        \\not json at all
        \\{"kind":"third"}
        \\
    ;

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{ .on_malformed = .skip });
    defer reader.deinit();

    try testing.expectEqualStrings("first", (try reader.next()).?.value.kind);
    const third = (try reader.next()).?;
    try testing.expectEqualStrings("third", third.value.kind);
    try testing.expectEqual(@as(u64, 3), third.number);
    // The skip is not silent: it is on the record.
    try testing.expectEqual(@as(u64, 2), reader.fault.line);
    try testing.expect(reader.fault.err != null);
}

test "the last line needs no newline, and blank lines do not break numbering" {
    const input = "{\"kind\":\"first\"}\n\n   \n{\"kind\":\"last\"}";

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    try testing.expectEqual(@as(u64, 1), (try reader.next()).?.number);
    const last = (try reader.next()).?;
    try testing.expectEqualStrings("last", last.value.kind);
    try testing.expectEqual(@as(u64, 4), last.number);
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());

    // Without skip_blank a blank line is a line, and it is not a `T`.
    var strict: std.Io.Reader = .fixed(input);
    var keeper: strand.Reader(Event) = .init(testing.allocator, &strict, .{ .skip_blank = false });
    defer keeper.deinit();
    _ = try keeper.next();
    try testing.expectError(error.MalformedLine, keeper.next());
    try testing.expectEqual(@as(u64, 2), keeper.fault.line);
}

test "CRLF is tolerated, and the terminator is not part of the line" {
    const input = "{\"kind\":\"first\"}\r\n{\"kind\":\"second\"}\r\n";

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    const first = (try reader.next()).?;
    try testing.expectEqualStrings("{\"kind\":\"first\"}", first.line);
    try testing.expectEqualStrings("second", (try reader.next()).?.value.kind);

    // A `\r` that is not the terminator is a control byte like any other,
    // whether it stands alone in the middle of a line or doubles up before
    // the one that does end it.
    var stray: std.Io.Reader = .fixed("{\"kind\":\"a\rb\"}\n{\"kind\":\"c\"}\r\r\n");
    var strays: strand.Reader(Event) = .init(testing.allocator, &stray, .{});
    defer strays.deinit();
    try testing.expectError(error.ControlByte, strays.next());
    try testing.expectEqual(@as(u64, 1), strays.fault.line);
    try testing.expectEqual(@as(?usize, 10), strays.fault.offset);
    try testing.expectError(error.ControlByte, strays.next());
    try testing.expectEqual(@as(u64, 2), strays.fault.line);
    try testing.expectEqual(@as(?usize, 12), strays.fault.offset);
}

test "max_line_bytes is enforced, and the reader continues after the long line" {
    const input =
        \\{"kind":"short"}
        \\{"kind":"an extravagantly long line that runs well past the bound"}
        \\{"kind":"short again"}
        \\
    ;

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{ .max_line_bytes = 32 });
    defer reader.deinit();

    try testing.expectEqualStrings("short", (try reader.next()).?.value.kind);
    try testing.expectError(error.LineTooLong, reader.next());
    try testing.expectEqual(@as(u64, 2), reader.fault.line);
    // No parse was attempted, so there is no parse error to report.
    try testing.expectEqual(@as(?strand.ParseLineError, null), reader.fault.err);

    const third = (try reader.next()).?;
    try testing.expectEqualStrings("short again", third.value.kind);
    try testing.expectEqual(@as(u64, 3), third.number);

    // A line of exactly the bound is accepted; one byte more is not.
    const exact = "{\"kind\":\"0123456789012345\"}";
    try testing.expectEqual(@as(usize, 27), exact.len);
    var tight: std.Io.Reader = .fixed(exact);
    var strict: strand.Reader(Event) = .init(testing.allocator, &tight, .{ .max_line_bytes = exact.len });
    defer strict.deinit();
    try testing.expectEqualStrings("0123456789012345", (try strict.next()).?.value.kind);

    var tighter: std.Io.Reader = .fixed(exact);
    var too_strict: strand.Reader(Event) = .init(testing.allocator, &tighter, .{ .max_line_bytes = exact.len - 1 });
    defer too_strict.deinit();
    try testing.expectError(error.LineTooLong, too_strict.next());
}

test "the line bound excludes a CRLF terminator" {
    {
        var source: std.Io.Reader = .fixed("{}\r\n");
        var reader: strand.Reader(std.json.Value) = .init(testing.allocator, &source, .{
            .max_line_bytes = 2,
        });
        defer reader.deinit();
        try testing.expect((try reader.next()).?.value == .object);
    }

    var buffer: [2]u8 = undefined;
    var chunked: fixtures.Chunked = .init("{}\r\n", &buffer, 1);
    var streamed: strand.Reader(std.json.Value) = .init(testing.allocator, &chunked.interface, .{
        .max_line_bytes = 2,
    });
    defer streamed.deinit();
    try testing.expect((try streamed.next()).?.value == .object);
}

test "strings borrow from the line when they can, and are copied when they cannot" {
    const input =
        \\{"kind":"plain"}
        \\{"kind":"esc\u0061ped"}
        \\
    ;

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
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

test "a line already in the stream's buffer is framed where it lies" {
    const input =
        \\{"kind":"one"}
        \\{"kind":"two"}
        \\{"kind":"three"}
        \\{"kind":"four"}
        \\{"kind":"a line with more bytes on it than the stream's buffer holds"}
        \\{"kind":"five"}
        \\
    ;

    // A stream holding the whole of its input — what a `.fixed` reader is,
    // and what a reader with a buffer wider than its lines mostly is — is
    // read without a single byte being copied anywhere: the line buffer is
    // never written to at all.
    {
        var source: std.Io.Reader = .fixed(input);
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
        defer reader.deinit();

        var seen: usize = 0;
        while (try reader.next()) |line| : (seen += 1) {
            try testing.expect(within(line.line, input));
        }
        try testing.expectEqual(@as(usize, 6), seen);
        try testing.expectEqual(@as(usize, 0), reader.line_buf.written().len);
    }

    // And a stream whose buffer is narrower than some of its lines reads the
    // same lines: the ones that are all there are framed where they lie, and
    // the one that straddles a refill is assembled in the line buffer.
    const buffer = try testing.allocator.alloc(u8, 32);
    defer testing.allocator.free(buffer);
    var chunked: fixtures.Chunked = .init(input, buffer, 32);
    var reader: strand.Reader(Event) = .init(testing.allocator, &chunked.interface, .{});
    defer reader.deinit();

    var framed: usize = 0;
    var assembled: usize = 0;
    var long: ?bool = null;
    while (try reader.next()) |line| {
        if (within(line.line, buffer)) framed += 1 else assembled += 1;
        if (line.line.len > buffer.len) long = within(line.line, reader.line_buf.written());
    }
    try testing.expectEqual(@as(u64, 6), reader.number);
    try testing.expect(framed > 0);
    try testing.expect(assembled > 0);
    // The line that cannot fit in the stream's buffer is the one that has to
    // be copied, and it is copied into the reader's own.
    try testing.expectEqual(@as(?bool, true), long);
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
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
        defer reader.deinit();

        const first = (try reader.next()).?;
        kept = try reader.keep(arena.allocator(), first);
        // The copy borrows neither the line buffer nor anything in it.
        try testing.expect(!within(kept.kind, first.line));

        // Read on: the line the value came from is gone by now.
        _ = try reader.next();
        try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
    }

    // The reader is deinitialized and the kept value is still whole.
    try testing.expectEqualStrings("kept", kept.kind);
    try testing.expectEqualStrings("a\tnote", kept.note.?);
}

test "kindOf and tagOf answer null rather than guess" {
    // An escaped key is not decoded, and saying so is the contract.
    try testing.expectEqual(@as(?[]const u8, null), strand.kindOf("{\"ki\\u006ed\":1}"));
    try testing.expectEqual(@as(?std.meta.Tag(Message), null), strand.tagOf(Message, "{\"pi\\u006eg\":1}"));
    // Neither is anything that is not a one-key object.
    try testing.expectEqual(@as(?[]const u8, null), strand.kindOf("[{\"kind\":1}]"));
    try testing.expectEqual(@as(?[]const u8, null), strand.kindOf("null"));
    try testing.expectEqual(@as(?[]const u8, null), strand.kindOf("42"));
    try testing.expectEqual(@as(?[]const u8, null), strand.kindOf("\"kind\""));
    try testing.expectEqual(@as(?[]const u8, null), strand.kindOf(""));
    try testing.expectEqual(@as(?[]const u8, null), strand.kindOf("{\"unterminated"));
    try testing.expectEqual(@as(?[]const u8, null), strand.kindOf("{\"kind\"}"));
    // An empty key is a key.
    try testing.expectEqualStrings("", strand.kindOf("{\"\":1}").?);
}

test "a long stream costs what one line costs" {
    const line_count = 10_000;

    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    var writer: strand.Writer(Event) = .init(&input.writer, .{});
    for (0..line_count) |i| {
        try writer.write(.{ .kind = "tick", .at = i, .tags = &.{"generated"} });
    }

    var source: std.Io.Reader = .fixed(input.written());
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
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
    var it = strand.lines(buffer);
    while (it.next()) |line| : (count += 1) {
        const event = try strand.parseLine(Event, arena.allocator(), line.line, .{});
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
    const event = try strand.parseLine(Event, arena.allocator(), line, .{ .copy_strings = true });
    try testing.expectEqualStrings("open", event.kind);
    try testing.expect(!within(event.kind, line));
}

test "parseLine rejects a trailing line terminator" {
    try testing.expectError(error.SyntaxError, strand.parseLine(bool, testing.allocator, "true\n", .{}));
    try testing.expectError(error.SyntaxError, strand.parseLine(bool, testing.allocator, "true\r\n", .{}));
}

test "large unsigned integers accept exponent notation" {
    const value = try strand.parseLine(u128, testing.allocator, "2e38", .{});
    try testing.expectEqual(@as(u128, 200_000_000_000_000_000_000_000_000_000_000_000_000), value);

    var diagnostics: strand.Diagnostics = .{};
    const diagnosed = try strand.parseLine(u128, testing.allocator, "2e38", .{ .diagnostics = &diagnostics });
    try testing.expectEqual(value, diagnosed);
}

test "an empty stream is a stream" {
    var source: std.Io.Reader = .fixed("");
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
    try testing.expectEqual(@as(u64, 0), reader.number);
}

test "a byte-order mark belongs to the file, not to its first line" {
    const input = "\xEF\xBB\xBF{\"kind\":\"first\"}\n{\"kind\":\"second\"}\n";

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    const first = (try reader.next()).?;
    try testing.expectEqualStrings("first", first.value.kind);
    try testing.expectEqualStrings("{\"kind\":\"first\"}", first.line);
    try testing.expectEqual(@as(u64, 1), first.number);
    try testing.expectEqualStrings("second", (try reader.next()).?.value.kind);

    // With the option off, `std.json` is shown the mark and says so.
    var marked: std.Io.Reader = .fixed(input);
    var strict: strand.Reader(Event) = .init(testing.allocator, &marked, .{ .skip_bom = false });
    defer strict.deinit();
    try testing.expectError(error.MalformedLine, strict.next());

    // `lines` agrees with the reader about where the first line starts.
    var it = strand.lines(input);
    try testing.expectEqualStrings("{\"kind\":\"first\"}", it.next().?.line);
}

test "a control byte is a damaged line, named by number and offset" {
    const input = "{\"kind\":\"first\"}\n{\"kind\":\"se\x00cond\"}\n{\"kind\":\"third\"}\n";

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    try testing.expectEqualStrings("first", (try reader.next()).?.value.kind);
    try testing.expectError(error.ControlByte, reader.next());
    try testing.expectEqual(@as(u64, 2), reader.fault.line);
    try testing.expectEqual(@as(?usize, 11), reader.fault.offset);
    // It never reached `std.json`, so there is nothing of `std.json`'s to say.
    try testing.expectEqual(@as(?strand.ParseLineError, null), reader.fault.err);
    // And the stream is where it was: the next line is the next line.
    const third = (try reader.next()).?;
    try testing.expectEqualStrings("third", third.value.kind);
    try testing.expectEqual(@as(u64, 3), third.number);

    // Skipping treats it the way it treats any other line it cannot use.
    var skipping: std.Io.Reader = .fixed(input);
    var skipper: strand.Reader(Event) = .init(testing.allocator, &skipping, .{ .on_malformed = .skip });
    defer skipper.deinit();
    try testing.expectEqualStrings("first", (try skipper.next()).?.value.kind);
    try testing.expectEqualStrings("third", (try skipper.next()).?.value.kind);

    // With the scan off the line is still refused, but by `std.json`, which
    // has no idea what it was looking at.
    var raw: std.Io.Reader = .fixed(input);
    var tolerant: strand.Reader(Event) = .init(testing.allocator, &raw, .{ .reject_control_bytes = false });
    defer tolerant.deinit();
    _ = try tolerant.next();
    try testing.expectError(error.MalformedLine, tolerant.next());
    try testing.expectEqual(error.SyntaxError, tolerant.fault.err.?);

    // A tab is whitespace to JSON, so it is not damage.
    var tabbed: std.Io.Reader = .fixed("{\"kind\":\t\"fine\"}\n");
    var tabs: strand.Reader(Event) = .init(testing.allocator, &tabbed, .{});
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
    var writer: strand.Writer(Event) = .init(&out.writer, .{ .format = .pretty });
    try writer.writeAll(&events);

    // It really is more than one line per record.
    try testing.expect(std.mem.count(u8, out.written(), "\n") > events.len);

    var source: std.Io.Reader = .fixed(out.written());
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{ .format = .pretty });
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
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());

    // A `.pretty` reader reads a minified stream too: a record that parses on
    // its first line never asks for a second.
    var minified: std.Io.Writer.Allocating = .init(testing.allocator);
    defer minified.deinit();
    var plain: strand.Writer(Event) = .init(&minified.writer, .{});
    try plain.writeAll(&events);

    var flat: std.Io.Reader = .fixed(minified.written());
    var tolerant: strand.Reader(Event) = .init(testing.allocator, &flat, .{ .format = .pretty });
    defer tolerant.deinit();
    try testing.expectEqual(@as(u64, 1), (try tolerant.next()).?.number);
    try testing.expectEqual(@as(u64, 2), (try tolerant.next()).?.number);
    try testing.expectEqual(@as(?strand.Line(Event), null), try tolerant.next());
}

test "pretty: a record that never finishes is one malformed record" {
    const input =
        \\{
        \\  "kind": "truncated",
    ;
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{ .format = .pretty });
    defer reader.deinit();

    try testing.expectError(error.MalformedLine, reader.next());
    // Blamed on the line it began on, not the one it ran out on.
    try testing.expectEqual(@as(u64, 1), reader.fault.line);
    try testing.expectEqual(error.UnexpectedEndOfInput, reader.fault.err.?);
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
}

test "pretty: a terminated prefix remains unfinished when a terminator is required" {
    const input =
        \\{
        \\  "kind": "waiting"
        \\
    ;
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
        .format = .pretty,
        .require_terminator = true,
    });
    defer reader.deinit();

    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
}

test "pretty: a control byte on a joined line is what the reader says it is" {
    // A record whose first line is only the start of a value, whose second
    // line carries a raw NUL, and a reader told to pass damage over. The
    // record is damaged, not unfinished, and the reader has to say the one
    // that is true: the byte, where it is, and no parse error.
    const input = "{\n\"kind\":\"a\x00\"}\n{\"kind\":\"b\"}\n";

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
        .format = .pretty,
        .on_malformed = .skip,
    });
    defer reader.deinit();

    const good = (try reader.next()).?;
    try testing.expectEqualStrings("b", good.value.kind);
    try testing.expectEqual(@as(u64, 3), good.number);

    try testing.expectEqual(@as(u64, 1), reader.skipped);
    try testing.expectEqual(@as(u64, 1), reader.fault.line);
    // Where in the joined record the byte is: past the `{`, past the `\n`
    // that joined the two, and nine bytes into the line that carried it.
    try testing.expectEqual(@as(?usize, 11), reader.fault.offset);
    try testing.expectEqual(@as(?strand.ParseLineError, null), reader.fault.err);
}

test "pretty: the bound is on the record, not on one of its lines" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: strand.Writer(Event) = .init(&out.writer, .{ .format = .pretty });
    try writer.write(.{ .kind = "open", .at = 1, .tags = &.{ "a", "b", "c" } });
    try writer.write(.{ .kind = "after", .at = 2 });

    var source: std.Io.Reader = .fixed(out.written());
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
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
    var batch: strand.Writer(Event) = .init(&batched.writer, .{});
    try batch.writeAll(&events);

    var looped: std.Io.Writer.Allocating = .init(testing.allocator);
    defer looped.deinit();
    var loop: strand.Writer(Event) = .init(&looped.writer, .{});
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
        var writer: strand.Writer(Event) = .init(&out.writer, .{});
        try writer.write(.{ .kind = raw, .at = 1, .note = raw });

        // One record, one line: the only `\n` is the one the writer added.
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\n"));
        try testing.expect(std.mem.endsWith(u8, out.written(), "\n"));
        // And no raw control byte survived into the line either.
        try testing.expectEqual(
            @as(?usize, null),
            strand.indexOfControl(out.written()[0 .. out.written().len - 1]),
        );

        // Which means it reads back as what went in.
        var source: std.Io.Reader = .fixed(out.written());
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
        defer reader.deinit();
        const line = (try reader.next()).?;
        try testing.expectEqualStrings(raw, line.value.kind);
        try testing.expectEqualStrings(raw, line.value.note.?);
        try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
    }
}

test "require_terminator: an unfinished last line is not a line" {
    const input = "{\"kind\":\"whole\"}\n{\"kind\":\"hal";

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{ .require_terminator = true });
    defer reader.deinit();

    try testing.expectEqualStrings("whole", (try reader.next()).?.value.kind);
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
    // The half-written line was not counted, so a follower can read it again.
    try testing.expectEqual(@as(u64, 1), reader.number);

    // Without the option, the same bytes are a line, and a bad one.
    var again: std.Io.Reader = .fixed(input);
    var plain: strand.Reader(Event) = .init(testing.allocator, &again, .{});
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
    var writer: strand.Writer(Event) = .init(&input.writer, .{});
    for (0..line_count) |i| {
        try writer.write(.{ .kind = "tick", .at = i, .tags = &.{ "generated", "here" } });
    }

    var counting: Counting = .{ .child = testing.allocator };
    var source: std.Io.Reader = .fixed(input.written());
    var reader: strand.Reader(Event) = .init(counting.allocator(), &source, .{});
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
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
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

//=========================================================================
// Where a line was, and how many were lost. A line number says which line a
// person should look at; an offset says where a program should seek.
//=========================================================================

test "a line knows the byte offset it began at" {
    // A byte-order mark, CRLF, a blank line and a line with no terminator:
    // every one of them moves the offset without being a line of its own.
    const input =
        "\xEF\xBB\xBF" ++
        "{\"kind\":\"first\"}\r\n" ++
        "\n" ++
        "   \n" ++
        "{\"kind\":\"second\"}\n" ++
        "{\"kind\":\"third\"}";

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    var seen: usize = 0;
    var first_offset: ?u64 = null;
    while (try reader.next()) |line| : (seen += 1) {
        if (first_offset == null) first_offset = line.offset;
        // The offset is the place a seek would have to land for the line to
        // be read again, so the bytes there are the line's own bytes.
        try testing.expectEqualStrings(line.line, input[@intCast(line.offset)..][0..line.line.len]);
        try testing.expectEqual(line.offset, reader.offset);
    }
    try testing.expectEqual(@as(usize, 3), seen);
    // Three bytes of mark, then the first line: the mark belongs to the file.
    try testing.expectEqual(@as(?u64, 3), first_offset);
}

test "an offset names the line a reader refused" {
    const input =
        \\{"kind":"good"}
        \\not json at all
        \\{"kind":"after"}
        \\
    ;
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    _ = (try reader.next()).?;
    try testing.expectError(error.MalformedLine, reader.next());
    try testing.expectEqual(@as(u64, 2), reader.fault.line);
    try testing.expectEqualStrings(
        "not json at all",
        input[@intCast(reader.offset)..][0.."not json at all".len],
    );

    // And an over-long line, which never reaches `std.json` at all.
    var long: std.Io.Reader = .fixed("{\"kind\":\"x\"}\n{\"kind\":\"" ++ "y" ** 200 ++ "\"}\n{\"kind\":\"z\"}\n");
    var bounded: strand.Reader(Event) = .init(testing.allocator, &long, .{ .max_line_bytes = 64 });
    defer bounded.deinit();
    _ = (try bounded.next()).?;
    try testing.expectError(error.LineTooLong, bounded.next());
    try testing.expectEqual(@as(u64, 13), bounded.offset);
    try testing.expectEqualStrings("z", (try bounded.next()).?.value.kind);
}

test "an offset is what turns a line number into a place to seek back to" {
    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    var writer: strand.Writer(Event) = .init(&input.writer, .{});
    for (0..500) |i| try writer.write(.{ .kind = "tick", .at = i });

    // Read the whole stream once, remembering where every tenth line was.
    var offsets: std.ArrayList(u64) = .empty;
    defer offsets.deinit(testing.allocator);
    {
        var source: std.Io.Reader = .fixed(input.written());
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
        defer reader.deinit();
        while (try reader.next()) |line| {
            if (line.number % 10 == 0) try offsets.append(testing.allocator, line.offset);
        }
    }
    try testing.expectEqual(@as(usize, 50), offsets.items.len);

    // An index of fifty entries is enough to start a reader anywhere.
    for (offsets.items, 1..) |offset, tenth| {
        var source: std.Io.Reader = .fixed(input.written()[@intCast(offset)..]);
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
        defer reader.deinit();
        const line = (try reader.next()).?;
        try testing.expectEqual(@as(u64, tenth * 10 - 1), line.value.at);
        // A reader that starts at an offset counts from there.
        try testing.expectEqual(@as(u64, 0), line.offset);
    }
}

test "a reader resumed at an offset carries the line number with it" {
    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    // A mark, so that the first line does not begin where the file does.
    try input.writer.writeAll("\xEF\xBB\xBF");
    var writer: strand.Writer(Event) = .init(&input.writer, .{});
    for (0..500) |i| try writer.write(.{ .kind = "tick", .at = i });

    // The index: every tenth line, as a place and as a number.
    const Mark = struct { offset: u64, number: u64, at: u64 };
    var index: std.ArrayList(Mark) = .empty;
    defer index.deinit(testing.allocator);
    {
        var source: std.Io.Reader = .fixed(input.written());
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
        defer reader.deinit();
        while (try reader.next()) |line| {
            if (line.number % 10 == 0) try index.append(testing.allocator, .{
                .offset = line.offset,
                .number = line.number,
                .at = line.value.at,
            });
        }
    }
    try testing.expectEqual(@as(usize, 50), index.items.len);

    // Reading back from an entry gives that line under its own number, at
    // its own offset, and every line after it under the next ones.
    for (index.items) |mark| {
        var source: std.Io.Reader = .fixed(input.written()[@intCast(mark.offset)..]);
        var reader: strand.Reader(Event) = .resumeAt(testing.allocator, &source, .{}, .{
            .offset = mark.offset,
            .lines_before = mark.number - 1,
        });
        defer reader.deinit();

        const first = (try reader.next()).?;
        try testing.expectEqual(mark.number, first.number);
        try testing.expectEqual(mark.offset, first.offset);
        try testing.expectEqual(mark.at, first.value.at);

        if (mark.number < 500) {
            const second = (try reader.next()).?;
            try testing.expectEqual(mark.number + 1, second.number);
            try testing.expectEqual(mark.at + 1, second.value.at);
            // The line after it is placed where it really is in the file.
            try testing.expectEqualStrings(
                second.line,
                input.written()[@intCast(second.offset)..][0..second.line.len],
            );
        }
    }

    // Resumed at the end, there is nothing left and the count still holds.
    var empty: std.Io.Reader = .fixed("");
    var done: strand.Reader(Event) = .resumeAt(testing.allocator, &empty, .{}, .{
        .offset = input.written().len,
        .lines_before = 500,
    });
    defer done.deinit();
    try testing.expectEqual(@as(?strand.Line(Event), null), try done.next());
    try testing.expectEqual(@as(u64, 500), done.number);
}

test "a resumed reader does not eat three bytes looking for a mark" {
    // These three bytes are a byte-order mark, and they are also the middle
    // of a line: only a reader that began at offset 0 may drop them.
    const input = "{\"kind\":\"a\"}\n{\"kind\":\"\xEF\xBB\xBF\"}\n";
    const offset = std.mem.indexOfScalar(u8, input, '\n').? + 1;

    var source: std.Io.Reader = .fixed(input[offset..]);
    var reader: strand.Reader(Event) = .resumeAt(testing.allocator, &source, .{}, .{
        .offset = offset,
        .lines_before = 1,
    });
    defer reader.deinit();

    const line = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 2), line.number);
    try testing.expectEqual(offset, line.offset);
    try testing.expectEqualStrings("\xEF\xBB\xBF", line.value.kind);
}

test "skipped counts the lines a tolerant reader lost" {
    const input =
        \\{"kind":"one"}
        \\not json
        \\
        \\{"kind":"two"}
        \\{"kind":3}
        \\{"kind":"three"}
        \\
    ;
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{ .on_malformed = .skip });
    defer reader.deinit();

    var seen: usize = 0;
    while (try reader.next()) |_| seen += 1;
    try testing.expectEqual(@as(usize, 3), seen);
    // Two lines were damaged; the blank one was not damage.
    try testing.expectEqual(@as(u64, 2), reader.skipped);
    try testing.expectEqual(@as(u64, 6), reader.number);

    // A control byte is counted the same way.
    var damaged: std.Io.Reader = .fixed("{\"kind\":\"a\x00\"}\n{\"kind\":\"b\"}\n");
    var tolerant: strand.Reader(Event) = .init(testing.allocator, &damaged, .{ .on_malformed = .skip });
    defer tolerant.deinit();
    try testing.expectEqualStrings("b", (try tolerant.next()).?.value.kind);
    try testing.expectEqual(@as(u64, 1), tolerant.skipped);
}

//=========================================================================
// A key that appears twice, which is a thing other encoders write.
//=========================================================================

test "a repeated key is refused, kept first or kept last, as asked" {
    const line = "{\"kind\":\"first\",\"at\":1,\"kind\":\"second\"}\n";

    for ([_]struct { strand.DuplicateFields, ?[]const u8 }{
        .{ .@"error", null },
        .{ .use_first, "first" },
        .{ .use_last, "second" },
    }) |case| {
        var source: std.Io.Reader = .fixed(line);
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
            .duplicate_fields = case[0],
        });
        defer reader.deinit();

        if (case[1]) |want| {
            try testing.expectEqualStrings(want, (try reader.next()).?.value.kind);
        } else {
            try testing.expectError(error.MalformedLine, reader.next());
            try testing.expectEqual(error.DuplicateField, reader.fault.err.?);
        }
    }
}

//=========================================================================
// A record that says where it starts.
//=========================================================================

test "a separated stream says where every record begins" {
    const events = [_]Event{
        .{ .kind = "open", .at = 1 },
        .{ .kind = "retry", .at = 2, .level = .warn },
        .{ .kind = "close", .at = 3 },
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var log: strand.Writer(Event) = .init(&out.writer, .{ .record_separator = true });
    try log.writeAll(&events);

    // One byte per record, in front of it, and the rest is the line it
    // would have been.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out.written(), &.{strand.separator}));
    try testing.expectEqual(@as(u8, 0x1e), out.written()[0]);
    try testing.expect(std.mem.startsWith(u8, out.written()[1..], "{\"kind\":\"open\""));

    var source: std.Io.Reader = .fixed(out.written());
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
        .record_separator = true,
    });
    defer reader.deinit();

    for (events) |want| {
        const line = (try reader.next()).?;
        try testing.expectEqualStrings(want.kind, line.value.kind);
        // The line is the record and not the byte in front of it; the
        // offset is where the record begins, which is that byte.
        try testing.expectEqual(@as(u8, strand.separator), out.written()[@intCast(line.offset)]);
        try testing.expectEqualStrings(
            line.line,
            out.written()[@intCast(line.offset + 1)..][0..line.line.len],
        );
    }
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
}

test "a torn record is what a separator makes visible" {
    // A line with the tail of a record on the front of it, which is what a
    // writer interrupted mid-record leaves behind, and a line with no
    // record on it at all.
    const input =
        "\x1e{\"kind\":\"first\"}\n" ++
        "\",\"at\":9}\x1e{\"kind\":\"second\"}\n" ++
        "nothing at all\n" ++
        "\x1e{\"kind\":\"third\"}\n";

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
        .record_separator = true,
    });
    defer reader.deinit();

    try testing.expectEqualStrings("first", (try reader.next()).?.value.kind);

    // The tail of the torn record is dropped and the record after it is
    // read: that is the whole of what the separator buys.
    const second = (try reader.next()).?;
    try testing.expectEqualStrings("second", second.value.kind);
    try testing.expectEqual(@as(u8, strand.separator), input[@intCast(second.offset)]);

    // And a line carrying no record is not a malformed record: it is a line
    // with nothing on it that this reader was promised.
    try testing.expectError(error.MissingSeparator, reader.next());
    try testing.expectEqual(@as(u64, 3), reader.fault.line);
    try testing.expectEqual(@as(?strand.ParseLineError, null), reader.fault.err);

    // The stream is not lost: the next line is read as usual.
    try testing.expectEqualStrings("third", (try reader.next()).?.value.kind);
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
}

test "a torn prefix does not count against a separated record's bound" {
    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    try input.writer.splatByteAll('x', 1024);
    try input.writer.writeAll("\x1e{}\n");

    {
        var source: std.Io.Reader = .fixed(input.written());
        var reader: strand.Reader(std.json.Value) = .init(testing.allocator, &source, .{
            .record_separator = true,
            .max_line_bytes = 2,
        });
        defer reader.deinit();
        try testing.expect((try reader.next()).?.value == .object);
    }

    var buffer: [7]u8 = undefined;
    var chunked: fixtures.Chunked = .init(input.written(), &buffer, 3);
    var streamed: strand.Reader(std.json.Value) = .init(testing.allocator, &chunked.interface, .{
        .record_separator = true,
        .max_line_bytes = 2,
    });
    defer streamed.deinit();
    try testing.expect((try streamed.next()).?.value == .object);
}

test "a separator is a decision both ends make" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var log: strand.Writer(Event) = .init(&out.writer, .{ .record_separator = true });
    try log.write(.{ .kind = "open", .at = 1 });

    // To a reader that was not told, the separator is a raw control byte,
    // which is what it is.
    var source: std.Io.Reader = .fixed(out.written());
    var plain: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer plain.deinit();
    try testing.expectError(error.ControlByte, plain.next());
    try testing.expectEqual(@as(?usize, 0), plain.fault.offset);

    // And a stream with no separators on it is nothing but torn records to
    // a reader that was told there would be.
    var unseparated: std.Io.Reader = .fixed("{\"kind\":\"open\"}\n");
    var expectant: strand.Reader(Event) = .init(testing.allocator, &unseparated, .{
        .record_separator = true,
    });
    defer expectant.deinit();
    try testing.expectError(error.MissingSeparator, expectant.next());
}

//=========================================================================
// The bound on what a writer will emit, which is the reader's bound seen
// from the other end.
//=========================================================================

test "a writer can be held to the bound its readers are held to" {
    const bound = 64;
    const small: Event = .{ .kind = "open", .at = 1 };
    const large: Event = .{ .kind = "x" ** bound, .at = 2 };

    // With no bound, a writer will happily emit a record no reader with the
    // matching bound will read back.
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var log: strand.Writer(Event) = .init(&out.writer, .{});
        try log.write(large);

        var source: std.Io.Reader = .fixed(out.written());
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
            .max_line_bytes = bound,
        });
        defer reader.deinit();
        try testing.expectError(error.LineTooLong, reader.next());
    }

    // With one, the record is refused where it is written, and none of it
    // is written: the log is left where the record before it left it.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var log: strand.Writer(Event) = .init(&out.writer, .{ .max_line_bytes = bound });

    try log.write(small);
    const after_small = out.written().len;
    try testing.expect(after_small <= bound + 1);

    try testing.expectError(error.LineTooLong, log.write(large));
    try testing.expectEqual(after_small, out.written().len);
    try testing.expectEqual(@as(u64, 1), log.count);

    // And the writer is still a writer: the record after the refused one
    // goes on the end as if nothing had happened.
    try log.write(.{ .kind = "close", .at = 3 });
    try testing.expectEqual(@as(u64, 2), log.count);

    var source: std.Io.Reader = .fixed(out.written());
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{ .max_line_bytes = bound });
    defer reader.deinit();
    try testing.expectEqualStrings("open", (try reader.next()).?.value.kind);
    try testing.expectEqualStrings("close", (try reader.next()).?.value.kind);
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
}

test "the bound is on the record, whatever shape it is written in" {
    // A record indented over several lines is longer than the same record
    // minified, and the bound is on the bytes either way.
    const event: Event = .{ .kind = "open", .at = 1, .tags = &.{ "a", "b" } };

    var minified: std.Io.Writer.Allocating = .init(testing.allocator);
    defer minified.deinit();
    var lean: strand.Writer(Event) = .init(&minified.writer, .{ .max_line_bytes = 1 << 20 });
    try lean.write(event);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var wide: strand.Writer(Event) = .init(&out.writer, .{
        .format = .pretty,
        .max_line_bytes = minified.written().len,
    });
    try testing.expectError(error.LineTooLong, wide.write(event));
    try testing.expectEqual(@as(usize, 0), out.written().len);
}

//=========================================================================
// The two encoding options, which had no test between them.
//=========================================================================

test "escape_unicode writes a line with nothing but ASCII on it" {
    const event: Event = .{ .kind = "café \u{1f600}", .at = 1, .note = "naïve" };

    var plain: std.Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var as_written: strand.Writer(Event) = .init(&plain.writer, .{});
    try as_written.write(event);
    // The default writes the characters themselves, which is what a log a
    // person reads wants.
    try testing.expect(std.mem.indexOf(u8, plain.written(), "café") != null);

    var escaped: std.Io.Writer.Allocating = .init(testing.allocator);
    defer escaped.deinit();
    var as_ascii: strand.Writer(Event) = .init(&escaped.writer, .{ .escape_unicode = true });
    try as_ascii.write(event);

    for (escaped.written()) |byte| try testing.expect(byte < 0x80);
    try testing.expect(std.mem.indexOf(u8, escaped.written(), "caf\\u00e9") != null);
    // A character outside the basic plane is a surrogate pair, which is how
    // JSON spells one.
    try testing.expect(std.mem.indexOf(u8, escaped.written(), "\\ud83d\\ude00") != null);

    // Either way it reads back as the same value.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ plain.written(), escaped.written() }) |bytes| {
        var parsed = try readAll(Event, arena.allocator(), bytes, .{});
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), parsed.items.len);
        try testing.expectEqualStrings(event.kind, parsed.items[0].kind);
        try testing.expectEqualStrings(event.note.?, parsed.items[0].note.?);
    }
}

test "quoted Zig field names use JSON escaping" {
    const Odd = struct { @"quote\"slash\\é": u8 };
    const value: Odd = .{ .@"quote\"slash\\é" = 7 };

    inline for (.{ false, true }) |escape_unicode| {
        var actual: std.Io.Writer.Allocating = .init(testing.allocator);
        defer actual.deinit();
        var writer: strand.Writer(Odd) = .init(&actual.writer, .{ .escape_unicode = escape_unicode });
        try writer.write(value);

        var expected: std.Io.Writer.Allocating = .init(testing.allocator);
        defer expected.deinit();
        try std.json.Stringify.value(value, .{ .escape_unicode = escape_unicode }, &expected.writer);
        try expected.writer.writeByte('\n');
        try testing.expectEqualStrings(expected.written(), actual.written());
    }
}

test "emit_null_optional_fields writes the field rather than leaving it out" {
    const event: Event = .{ .kind = "open", .at = 1 };

    var left_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer left_out.deinit();
    var lean: strand.Writer(Event) = .init(&left_out.writer, .{});
    try lean.write(event);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, left_out.written(), "note"));

    var written_out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written_out.deinit();
    var full: strand.Writer(Event) = .init(&written_out.writer, .{ .emit_null_optional_fields = true });
    try full.write(event);
    try testing.expect(std.mem.indexOf(u8, written_out.written(), "\"note\":null") != null);

    // A reader that defaults its missing fields reads both as the same
    // value, which is why leaving them out is the default.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ left_out.written(), written_out.written() }) |bytes| {
        var parsed = try readAll(Event, arena.allocator(), bytes, .{});
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(@as(?[]const u8, null), parsed.items[0].note);
        try testing.expectEqualStrings("open", parsed.items[0].kind);
    }
}

test "null tuple elements keep their positions" {
    const Pair = struct { ?u8, u8 };
    const pair: Pair = .{ null, 1 };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: strand.Writer(Pair) = .init(&out.writer, .{});
    try writer.write(pair);
    try testing.expectEqualStrings("[null,1]\n", out.written());

    var source: std.Io.Reader = .fixed(out.written());
    var reader: strand.Reader(Pair) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    const decoded = (try reader.next()).?.value;
    try testing.expectEqual(@as(?u8, null), decoded[0]);
    try testing.expectEqual(@as(u8, 1), decoded[1]);
}

//=========================================================================
// Flushing, which is a decision about durability rather than about bytes.
//=========================================================================

/// A writer that counts the drains it is asked for and keeps what it was
/// given, so that a flush is observable.
const Draining = struct {
    interface: std.Io.Writer,
    flushes: usize = 0,
    written: std.ArrayList(u8) = .empty,

    fn init(buffer: []u8) Draining {
        return .{ .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer, .end = 0 } };
    }

    fn deinit(self: *Draining) void {
        self.written.deinit(testing.allocator);
    }

    fn drain(io_writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Draining = @alignCast(@fieldParentPtr("interface", io_writer));
        self.flushes += 1;
        self.written.appendSlice(testing.allocator, io_writer.buffered()) catch return error.WriteFailed;
        io_writer.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.written.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
            n += bytes.len;
        }
        for (0..splat) |_| {
            self.written.appendSlice(testing.allocator, data[data.len - 1]) catch return error.WriteFailed;
            n += data[data.len - 1].len;
        }
        return n;
    }
};

test "a flush policy is how often the destination is asked to drain" {
    const events = [_]Event{
        .{ .kind = "one", .at = 1 },
        .{ .kind = "two", .at = 2 },
        .{ .kind = "three", .at = 3 },
    };

    for ([_]struct { @FieldType(strand.Writer(Event).Options, "flush"), usize }{
        .{ .never, 0 },
        .{ .per_record, 3 },
        .{ .per_batch, 1 },
    }) |case| {
        var buffer: [4096]u8 = undefined;
        var sink: Draining = .init(&buffer);
        defer sink.deinit();

        var log: strand.Writer(Event) = .init(&sink.interface, .{ .flush = case[0] });
        try log.writeAll(&events);
        try testing.expectEqual(case[1], sink.flushes);

        // Whatever the policy, the bytes are the same bytes once drained.
        try sink.interface.flush();
        try testing.expectEqual(@as(usize, 3), std.mem.count(u8, sink.written.items, "\n"));
        try testing.expect(std.mem.startsWith(u8, sink.written.items, "{\"kind\":\"one\""));
    }
}

//=========================================================================
// Syncing, which is the other half of that decision: a flush survives the
// process, and only a sync survives the machine.
//=========================================================================

test "a count is how often a stream of records drains" {
    const events = [_]Event{
        .{ .kind = "one", .at = 1 },   .{ .kind = "two", .at = 2 },
        .{ .kind = "three", .at = 3 }, .{ .kind = "four", .at = 4 },
        .{ .kind = "five", .at = 5 },  .{ .kind = "six", .at = 6 },
        .{ .kind = "seven", .at = 7 },
    };

    var buffer: [4096]u8 = undefined;
    var sink: Draining = .init(&buffer);
    defer sink.deinit();

    // Three at a time, whether they arrive one at a time or in a batch: the
    // third and the sixth records drain, and the seventh is still in the
    // buffer afterwards.
    var log: strand.Writer(Event) = .init(&sink.interface, .{ .flush = .{ .per_records = 3 } });
    try log.write(events[0]);
    try log.write(events[1]);
    try testing.expectEqual(@as(usize, 0), sink.flushes);
    try log.write(events[2]);
    try testing.expectEqual(@as(usize, 1), sink.flushes);

    try log.writeAll(events[3..]);
    try testing.expectEqual(@as(usize, 2), sink.flushes);
    try testing.expectEqual(@as(u64, 7), log.count);

    // And the drains were drains: what they wrote is the records, in order.
    try log.flush();
    try testing.expectEqual(@as(usize, 7), std.mem.count(u8, sink.written.items, "\n"));
    try testing.expect(std.mem.startsWith(u8, sink.written.items, "{\"kind\":\"one\""));
}

test "a count is how often a stream of records reaches the disk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "log.jsonl", .{ .read = true });
    defer file.close(testing.io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(testing.io, &buffer);
    var log: strand.Writer(Event) = .initFile(&file_writer, .{ .sync = .{ .per_records = 2 } });

    // A sync drains first, so the file's length moves at every second
    // record and at no other.
    try log.write(.{ .kind = "one", .at = 1 });
    try testing.expectEqual(@as(u64, 0), try file.length(testing.io));
    try log.write(.{ .kind = "two", .at = 2 });
    const after_two = try file.length(testing.io);
    try testing.expect(after_two > 0);

    try log.write(.{ .kind = "three", .at = 3 });
    try testing.expectEqual(after_two, try file.length(testing.io));
    try log.write(.{ .kind = "four", .at = 4 });
    try testing.expect(try file.length(testing.io) > after_two);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(testing.io, &read_buffer);
    try file_reader.seekTo(0);
    var reader: strand.Reader(Event) = .init(testing.allocator, &file_reader.interface, .{});
    defer reader.deinit();
    var seen: usize = 0;
    while (try reader.next()) |_| seen += 1;
    try testing.expectEqual(@as(usize, 4), seen);
}

test "a sync policy drains the destination before it asks the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Read access as well as write: this test measures the file as it goes,
    // and asking for a file's length is read access — Windows refuses it on a
    // handle opened only for writing.
    const file = try tmp.dir.createFile(testing.io, "log.jsonl", .{ .read = true });
    defer file.close(testing.io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(testing.io, &buffer);

    // `.flush` is never, so nothing but the sync can have drained it — and
    // a sync of a file that has not been given the bytes syncs nothing.
    var log: strand.Writer(Event) = .initFile(&file_writer, .{ .sync = .per_record });
    const record = "{\"kind\":\"one\",\"at\":1,\"level\":\"info\",\"tags\":[],\"span\":{\"id\":0}}\n".len;
    try log.write(.{ .kind = "one", .at = 1 });
    try testing.expectEqual(@as(u64, record), try file.length(testing.io));
    try log.write(.{ .kind = "two", .at = 2 });
    try testing.expectEqual(@as(u64, 2 * record), try file.length(testing.io));
    try testing.expectEqual(@as(u64, 2), log.count);

    // And the bytes on the file are the records, read back as records.
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(testing.io, &read_buffer);
    try file_reader.seekTo(0);
    var reader: strand.Reader(Event) = .init(testing.allocator, &file_reader.interface, .{});
    defer reader.deinit();
    try testing.expectEqualStrings("one", (try reader.next()).?.value.kind);
    try testing.expectEqualStrings("two", (try reader.next()).?.value.kind);
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
}

test "a flush and a sync are also things to ask for one at a time" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "log.jsonl", .{ .read = true });
    defer file.close(testing.io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(testing.io, &buffer);

    // Nothing is drained by policy here, so the only thing that can move
    // the end of the file is the call that says to.
    var log: strand.Writer(Event) = .initFile(&file_writer, .{});
    try log.write(.{ .kind = "one", .at = 1 });
    try log.write(.{ .kind = "two", .at = 2 });
    try testing.expectEqual(@as(u64, 0), try file.length(testing.io));

    try log.flush();
    const after_flush = try file.length(testing.io);
    try testing.expect(after_flush > 0);

    try log.write(.{ .kind = "three", .at = 3 });
    try testing.expectEqual(after_flush, try file.length(testing.io));

    // A sync drains first, so the third record reaches the file here and
    // not at the write that made it.
    try log.sync();
    try testing.expect(try file.length(testing.io) > after_flush);
    try testing.expectEqual(@as(u64, 3), log.count);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(testing.io, &read_buffer);
    try file_reader.seekTo(0);
    var reader: strand.Reader(Event) = .init(testing.allocator, &file_reader.interface, .{});
    defer reader.deinit();
    var seen: usize = 0;
    while (try reader.next()) |_| seen += 1;
    try testing.expectEqual(@as(usize, 3), seen);
}

test "a sync asked for by hand still needs a file" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var log: strand.Writer(Event) = .init(&out.writer, .{});
    // A flush of a destination that is not a file is an ordinary drain.
    try log.write(.{ .kind = "one", .at = 1 });
    try log.flush();
    try testing.expect(out.written().len > 0);

    // A sync of one is not.
    try testing.expectError(error.SyncFailed, log.sync());
    try testing.expect(log.sync_failed);
}

test "a per-batch sync is once for the batch and not once for the record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(testing.io, "log.jsonl", .{ .read = true });
    defer file.close(testing.io);

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(testing.io, &buffer);
    var log: strand.Writer(Event) = .initFile(&file_writer, .{ .sync = .per_batch });

    // A plain `write` under `.per_batch` neither drains nor syncs, so the
    // record is still in this program's buffer and the file is empty.
    try log.write(.{ .kind = "loose", .at = 0 });
    try testing.expectEqual(@as(u64, 0), try file.length(testing.io));

    // The batch is what a sync follows, and it takes the loose record with
    // it: what is drained is everything the buffer holds.
    try log.writeAll(&.{
        .{ .kind = "one", .at = 1 },
        .{ .kind = "two", .at = 2 },
    });
    try testing.expect(try file.length(testing.io) > 0);
    try testing.expectEqual(@as(u64, 3), log.count);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(testing.io, &read_buffer);
    try file_reader.seekTo(0);
    var reader: strand.Reader(Event) = .init(testing.allocator, &file_reader.interface, .{});
    defer reader.deinit();
    var seen: usize = 0;
    while (try reader.next()) |_| seen += 1;
    try testing.expectEqual(@as(usize, 3), seen);
}

test "a sync policy with no file to sync says so rather than pretending" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    // `init` refuses this combination outright; a writer assembled by hand
    // reports it on the first record rather than silently writing a log
    // that is not as durable as it was asked to be.
    var log: strand.Writer(Event) = .{
        .output = &out.writer,
        .file = null,
        .options = .{ .sync = .per_record },
    };
    try testing.expectError(error.SyncFailed, log.write(.{ .kind = "one", .at = 1 }));
    // The record itself was written; it is the durability that failed.
    try testing.expectEqualStrings("{\"kind\":\"one\",\"at\":1,\"level\":\"info\",\"tags\":[],\"span\":{\"id\":0}}\n", out.written());
}

test "a writer whose sync has failed is not written to again" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var log: strand.Writer(Event) = .{
        .output = &out.writer,
        .file = null,
        .options = .{ .sync = .per_record },
    };
    try testing.expectError(error.SyncFailed, log.write(.{ .kind = "one", .at = 1 }));
    try testing.expect(log.sync_failed);

    // A log whose sync has failed is a log that is not what it was asked to
    // be, and the records after it would be claiming a durability the file
    // does not have. The bytes of the first one are all there is.
    const after = out.written().len;
    try testing.expectError(error.SyncFailed, log.write(.{ .kind = "two", .at = 2 }));
    try testing.expectError(error.SyncFailed, log.writeAll(&.{.{ .kind = "three", .at = 3 }}));
    try testing.expectEqual(after, out.written().len);
    try testing.expectEqual(@as(u64, 1), log.count);
}

//=========================================================================
// Bytes that are not UTF-8. The format is UTF-8 by definition, so the
// question is only what happens when the bytes are not, and the answer has
// to be the same one every time.
//=========================================================================

test "invalid UTF-8 in a line is a malformed line, and the stream survives it" {
    const cases: []const []const u8 = &.{
        "{\"kind\":\"\xff\"}", // a byte no UTF-8 sequence starts with
        "{\"kind\":\"\xc3\"}", // a sequence that stops half way
        "{\"kind\":\"\xc0\xaf\"}", // an overlong encoding of '/'
        "{\"kind\":\"\xed\xa0\x80\"}", // a lone surrogate half
        "\xff{\"kind\":\"ok\"}", // not inside a string at all
    };

    for (cases) |bad| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try buf.writer.writeAll(bad);
        try buf.writer.writeAll("\n{\"kind\":\"after\"}\n");

        var source: std.Io.Reader = .fixed(buf.written());
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
        defer reader.deinit();

        try testing.expectError(error.MalformedLine, reader.next());
        try testing.expectEqual(@as(u64, 1), reader.fault.line);
        // `std.json` validates UTF-8 itself, so this is a syntax error and
        // not a second opinion of this package's.
        try testing.expectEqual(error.SyntaxError, reader.fault.err.?);
        // And the line after it is read, because a bad line is one line.
        try testing.expectEqualStrings("after", (try reader.next()).?.value.kind);
    }
}

test "a Zig string that is not UTF-8 is not written as a JSON string" {
    // `std.json.Stringify` writes a `[]const u8` as a JSON string only when
    // it is valid UTF-8, and as an array of byte values when it is not. That
    // is the one case where a value written by `Writer` does not read back as
    // the same value, and it is worth pinning: a log of arbitrary bytes wants
    // a base64 or hex field, not a Zig string.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try strand.writeLine(&out.writer, .{ .kind = @as([]const u8, "\xff\xfe"), .at = @as(u64, 1) });
    try testing.expectEqualStrings("{\"kind\":[255,254],\"at\":1}\n", out.written());

    // The framing holds either way: it is still one line.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.written(), "\n"));

    // Read back by this package the bytes survive, because `std.json` reads
    // an array of numbers into a `[]const u8` field. Read back by anything
    // else the field is an array and not a string, which is why a log of
    // arbitrary bytes should encode them rather than rely on this.
    var source: std.Io.Reader = .fixed(out.written());
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    try testing.expectEqualStrings("\xff\xfe", (try reader.next()).?.value.kind);
}

//=========================================================================
// A record with an encoder of its own, and a line with no schema at all.
//=========================================================================

/// A record that writes itself: two fields flattened into one string, which
/// is the shape a `jsonStringify` method usually exists for.
const Packed = struct {
    host: []const u8,
    port: u16,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("addr");
        try jw.print("\"{s}:{d}\"", .{ self.host, self.port });
        try jw.endObject();
    }
};

test "a record with its own jsonStringify is written through it, one line per record" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var log: strand.Writer(Packed) = .init(&out.writer, .{});
    try log.writeAll(&.{
        .{ .host = "localhost", .port = 8080 },
        .{ .host = "example", .port = 443 },
    });
    try testing.expectEqualStrings(
        \\{"addr":"localhost:8080"}
        \\{"addr":"example:443"}
        \\
    , out.written());
    try testing.expectEqual(@as(u64, 2), log.count);

    // One line per record, and the lines read back.
    const Addr = struct { addr: []const u8 };
    var source: std.Io.Reader = .fixed(out.written());
    var reader: strand.Reader(Addr) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    try testing.expectEqualStrings("localhost:8080", (try reader.next()).?.value.addr);
    try testing.expectEqualStrings("example:443", (try reader.next()).?.value.addr);
}

test "a schemaless line is a std.json.Value like any other type" {
    const input =
        \\{"kind":"open","at":1}
        \\[1,2,3]
        \\{"deep":{"nested":{"thing":true}}}
        \\
    ;
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(std.json.Value) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    try testing.expectEqualStrings("open", (try reader.next()).?.value.object.get("kind").?.string);
    try testing.expectEqual(@as(usize, 3), (try reader.next()).?.value.array.items.len);
    const deep = (try reader.next()).?;
    try testing.expect(deep.value.object.get("deep").?.object.get("nested").?.object.get("thing").?.bool);
    try testing.expectEqual(@as(?strand.Line(std.json.Value), null), try reader.next());
}

test "a schemaless line is bounded by max_line_bytes and not by the stack" {
    // `std.json` parses a `Value` with a heap stack rather than by recursing,
    // so the only bound on how deep a line may nest is how long it may be —
    // which is `max_line_bytes`, the bound this reader already has.
    const depth = 50_000;

    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    try input.writer.splatByteAll('[', depth);
    try input.writer.splatByteAll(']', depth);
    try input.writer.writeAll("\n{\"after\":1}\n");

    var source: std.Io.Reader = .fixed(input.written());
    var reader: strand.Reader(std.json.Value) = .init(testing.allocator, &source, .{
        .max_line_bytes = 4 * depth,
    });
    defer reader.deinit();

    var value = (try reader.next()).?.value;
    var measured: usize = 0;
    while (value == .array and value.array.items.len == 1) : (measured += 1) value = value.array.items[0];
    try testing.expectEqual(@as(usize, depth - 1), measured);
    try testing.expectEqualStrings("after", (try reader.next()).?.line[2..7]);

    // The same line, past the bound, is one refused line rather than a crash.
    var again: std.Io.Reader = .fixed(input.written());
    var bounded: strand.Reader(std.json.Value) = .init(testing.allocator, &again, .{
        .max_line_bytes = 1024,
    });
    defer bounded.deinit();
    try testing.expectError(error.LineTooLong, bounded.next());
    // Refused, not fatal: the line after the deep one is still read.
    try testing.expectEqual(@as(usize, 1), (try bounded.next()).?.value.object.count());
    try testing.expectEqual(@as(?strand.Line(std.json.Value), null), try bounded.next());
}

test "a deeply nested unknown field is ignored without using the call stack" {
    const depth = 50_000;
    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();
    try input.writer.writeAll("{\"kind\":\"x\",\"ignored\":");
    try input.writer.splatByteAll('[', depth);
    try input.writer.writeByte('0');
    try input.writer.splatByteAll(']', depth);
    try input.writer.writeByte('}');

    const Parsed = struct { kind: []const u8 };
    const parsed = try strand.parseLine(Parsed, testing.allocator, input.written(), .{});
    try testing.expectEqualStrings("x", parsed.kind);
}

//=========================================================================
// Routing: what kind of line is this, answered before it is a value.
//=========================================================================

test "a reader that routes its own lines parses only the ones it wants" {
    const input =
        \\{"hello":{"version":1}}
        \\{"ping":2}
        \\
        \\{"ping":3}
        \\{"hello":{"version":4}}
        \\{"ping":5}
        \\
    ;

    // What every line is, according to a reader that parses all of them.
    const Seen = struct { line: []const u8, number: u64, offset: u64 };
    var all: std.ArrayList(Seen) = .empty;
    defer {
        for (all.items) |item| testing.allocator.free(item.line);
        all.deinit(testing.allocator);
    }
    {
        var source: std.Io.Reader = .fixed(input);
        var reader: strand.Reader(std.json.Value) = .init(testing.allocator, &source, .{});
        defer reader.deinit();
        while (try reader.next()) |line| try all.append(testing.allocator, .{
            .line = try testing.allocator.dupe(u8, line.line),
            .number = line.number,
            .offset = line.offset,
        });
    }
    try testing.expectEqual(@as(usize, 5), all.items.len);

    // And the same stream routed by the arm its first key names, parsing
    // the two lines that are worth parsing and nothing else.
    var counting: Counting = .{ .child = testing.allocator };
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Message) = .init(counting.allocator(), &source, .{});
    defer reader.deinit();

    var seen: usize = 0;
    var greetings: usize = 0;
    var after_first: ?usize = null;
    while (try reader.nextRaw()) |raw| : (seen += 1) {
        const want = all.items[seen];
        try testing.expectEqualStrings(want.line, raw.line);
        try testing.expectEqual(want.number, raw.number);
        try testing.expectEqual(want.offset, raw.offset);

        if (strand.tagOf(Message, raw.line) != .hello) {
            // A line that is only looked at costs nothing at all: the
            // allocator is not touched between one parse and the next.
            if (after_first) |count| try testing.expectEqual(count, counting.allocations);
            continue;
        }
        const line = (try reader.parse(raw)).?;
        try testing.expectEqual(want.number, line.number);
        try testing.expectEqual(want.offset, line.offset);
        try testing.expectEqual(([_]u8{ 1, 4 })[greetings], line.value.hello.version);
        greetings += 1;
        after_first = counting.allocations;
    }
    try testing.expectEqual(@as(usize, 5), seen);
    try testing.expectEqual(@as(usize, 2), greetings);
    // Five lines framed, two parsed: the arena grew once, and the line
    // buffer was never written to at all.
    try testing.expect(counting.allocations <= 2);
}

test "lines and nextRaw place a line in the same way" {
    const input = "\xEF\xBB\xBF{\"kind\":\"a\"}\r\n{\"kind\":\"b\"}\n{\"kind\":\"c\"}";

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    var it = strand.lines(input);
    while (it.next()) |want| {
        const raw = (try reader.nextRaw()).?;
        try testing.expectEqualStrings(want.line, raw.line);
        try testing.expectEqual(want.number, raw.number);
        // The offset a seek needs, from either side, mark and all.
        try testing.expectEqual(want.offset, raw.offset);
        try testing.expectEqualStrings(
            want.line,
            input[@intCast(want.offset)..][0..want.line.len],
        );
    }
    try testing.expectEqual(@as(?strand.RawLine, null), try reader.nextRaw());
}

//=========================================================================
// A stream that is not a file: no size, no seek, and a byte at a time.
//=========================================================================

test "a non-seekable stream is read under the same guarantees as a file" {
    const input =
        "\xEF\xBB\xBF" ++
        "{\"kind\":\"one\"}\r\n" ++
        "\n" ++
        "broken\n" ++
        "{\"kind\":\"two\",\"at\":2}\n" ++
        "{\"kind\":\"three\"}";

    // Recognition is independent of the reader's own buffer capacity, so
    // this runs from smaller than a BOM to comfortably large.
    for ([_]usize{ 1, 2, 3, 4, 16, 512 }) |buffer_len| {
        for ([_]usize{ 1, 3, 64 }) |chunk| {
            const buffer = try testing.allocator.alloc(u8, buffer_len);
            defer testing.allocator.free(buffer);

            var trickle: fixtures.Chunked = .init(input, buffer, chunk);
            var reader: strand.Reader(Event) = .init(testing.allocator, &trickle.interface, .{
                .on_malformed = .skip,
            });
            defer reader.deinit();

            var kinds: [3][]const u8 = undefined;
            var seen: usize = 0;
            while (try reader.next()) |line| : (seen += 1) {
                kinds[seen] = try testing.allocator.dupe(u8, line.value.kind);
            }
            defer for (kinds[0..seen]) |kind| testing.allocator.free(kind);

            try testing.expectEqual(@as(usize, 3), seen);
            try testing.expectEqualStrings("one", kinds[0]);
            try testing.expectEqualStrings("two", kinds[1]);
            try testing.expectEqualStrings("three", kinds[2]);
            try testing.expectEqual(@as(u64, 1), reader.skipped);
            // Every physical line was counted, blank and broken alike.
            try testing.expectEqual(@as(u64, 5), reader.number);
        }
    }
}

//=========================================================================
// A value kept as its bytes: `Raw`.
//=========================================================================

/// A line that carries values it does not read: a plugin's own record, a
/// list of them, one that may be absent, and one inside a union arm.
const Carried = struct {
    kind: []const u8,
    data: strand.Raw = .null,
    rest: []const strand.Raw = &.{},
    maybe: ?strand.Raw = null,
    inner: struct { at: u64 = 0, payload: strand.Raw = .null } = .{},
    route: union(enum) { local: u32, onward: strand.Raw } = .{ .local = 0 },
};

test "a raw value is read and written back byte for byte" {
    // Whitespace inside a value is the value's; a line written by this
    // package has none outside one, so the whole line comes back.
    const input =
        \\{"kind":"a","data":{ "who" : "ada",  "n": [1, 2.50, -0e+1] },"rest":[true,"x\u0041",[ ]],"maybe":{"k":null},"inner":{"at":3,"payload":"\u00e9\n"},"route":{"onward":{"to":  [ {} ]}}}
        \\{"kind":"b","data":null,"route":{"local":7}}
        \\{"kind":"c","data":12345678901234567890123,"inner":{"payload":[[[[]]]]},"route":{"onward":"far"}}
        \\
    ;
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Carried) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: strand.Writer(Carried) = .init(&out.writer, .{});

    const first = (try reader.next()).?;
    try testing.expectEqualStrings("{ \"who\" : \"ada\",  \"n\": [1, 2.50, -0e+1] }", first.value.data.bytes);
    try testing.expectEqual(@as(usize, 3), first.value.rest.len);
    try testing.expectEqualStrings("\"x\\u0041\"", first.value.rest[1].bytes);
    try testing.expectEqualStrings("[ ]", first.value.rest[2].bytes);
    try testing.expectEqualStrings("{\"k\":null}", first.value.maybe.?.bytes);
    try testing.expectEqualStrings("\"\\u00e9\\n\"", first.value.inner.payload.bytes);
    try testing.expectEqualStrings("{\"to\":  [ {} ]}", first.value.route.onward.bytes);
    try writer.write(first.value);

    // A JSON null is a value like any other; for an optional it is absent.
    const second = (try reader.next()).?;
    try testing.expectEqualStrings("null", second.value.data.bytes);
    try testing.expectEqual(@as(?strand.Raw, null), second.value.maybe);
    try writer.write(second.value);

    // A number is its digits, however many there are.
    const third = (try reader.next()).?;
    try testing.expectEqualStrings("12345678901234567890123", third.value.data.bytes);
    try writer.write(third.value);

    // What was written is what was read, less the defaults the writer
    // spells out: an absent `inner` and `rest` read back as their
    // defaults, so write the same records from the same defaults.
    var expected: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected.deinit();
    var it = strand.lines(input);
    while (it.next()) |line| {
        if (line.line.len == 0) continue;
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        try strand.writeLine(&expected.writer, try strand.parseLine(Carried, arena.allocator(), line.line, .{}));
    }
    try testing.expectEqualStrings(expected.written(), out.written());
    // The first line has every field, so it is its own bytes exactly.
    try testing.expectEqualStrings(input[0 .. std.mem.indexOfScalar(u8, input, '\n').? + 1], out.written()[0 .. std.mem.indexOfScalar(u8, out.written(), '\n').? + 1]);
}

test "a raw value borrows from its line as a string does, and keep copies it" {
    const input =
        \\{"kind":"a","data":{"x":[1,2,3]},"rest":["y"]}
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Carried) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    const line = (try reader.next()).?;
    try testing.expect(within(line.value.data.bytes, line.line));
    try testing.expect(within(line.value.rest[0].bytes, line.line));

    const kept = try reader.keep(arena.allocator(), line);
    try testing.expect(!within(kept.data.bytes, line.line));
    try testing.expectEqualStrings("{\"x\":[1,2,3]}", kept.data.bytes);
    try testing.expectEqualStrings("\"y\"", kept.rest[0].bytes);

    const copied = try strand.parseLine(Carried, arena.allocator(), input[0 .. input.len - 1], .{ .copy_strings = true });
    try testing.expect(!within(copied.data.bytes, input));

    // Read later, as whatever the reader wants it to be, borrowing from the
    // raw bytes rather than the line.
    const X = struct { x: bool };
    try testing.expectError(error.UnexpectedToken, kept.data.parse(X, arena.allocator(), .{}));
    const Xs = struct { x: []const u32 };
    try testing.expectEqual(@as(u32, 3), (try kept.data.parse(Xs, arena.allocator(), .{})).x[2]);
}

test "a malformed raw value is a malformed line, under the error std.json gives it" {
    // Each of these is refused as `std.json` refuses the same line with a
    // `std.json.Value` where the `Raw` is, and the stream carries on.
    const Mirror = struct {
        kind: []const u8,
        data: std.json.Value = .null,
    };
    const Held = struct {
        kind: []const u8,
        data: strand.Raw = .null,
    };
    const bad = [_][]const u8{
        "{\"kind\":\"a\",\"data\":}",
        "{\"kind\":\"a\",\"data\":[1,}",
        "{\"kind\":\"a\",\"data\":[1 2]}",
        "{\"kind\":\"a\",\"data\":tru}",
        "{\"kind\":\"a\",\"data\":{\"k\"}}",
        "{\"kind\":\"a\",\"data\":{\"k\":1,}}",
        "{\"kind\":\"a\",\"data\":\"\\q\"}",
        "{\"kind\":\"a\",\"data\":\"\\ud800\"}",
        "{\"kind\":\"a\",\"data\":\"\xff\"}",
        "{\"kind\":\"a\",\"data\":01}",
        "{\"kind\":\"a\",\"data\":-}",
        "{\"kind\":\"a\",\"data\":[[[",
        "{\"kind\":\"a\",\"data\":1",
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var input: std.ArrayList(u8) = .empty;
    for (bad) |line| {
        const want = std.json.parseFromSliceLeaky(Mirror, arena.allocator(), line, .{});
        try testing.expect(std.meta.isError(want));
        const want_err = if (want) |_| unreachable else |err| err;
        try testing.expectError(want_err, strand.parseLine(Held, arena.allocator(), line, .{}));
        try input.appendSlice(arena.allocator(), line);
        try input.appendSlice(arena.allocator(), "\n{\"kind\":\"good\"}\n");
    }

    var source: std.Io.Reader = .fixed(input.items);
    var reader: strand.Reader(Held) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    for (bad, 0..) |_, i| {
        try testing.expectError(error.MalformedLine, reader.next());
        try testing.expectEqual(@as(u64, 2 * i + 1), reader.fault.line);
        try testing.expect(reader.fault.err != null);
        try testing.expectEqualStrings("good", (try reader.next()).?.value.kind);
    }
    try testing.expectEqual(@as(?strand.Line(Held), null), try reader.next());
}

test "a type holding a raw value stays on the direct path both ways" {
    // The point of the type: a `std.json.Value` in the same place sends the
    // whole line to the token parser.
    const decode = @import("decode.zig");
    const encode = @import("encode.zig");
    try testing.expect(comptime decode.supports(Carried));
    try testing.expect(comptime encode.supports(Carried));
    try testing.expect(comptime decode.supports(strand.Raw));
    try testing.expect(comptime encode.supports(strand.Raw));
    const Valued = struct { kind: []const u8, data: std.json.Value = .null };
    try testing.expect(!comptime decode.supports(Valued));
    try testing.expect(!comptime encode.supports(Valued));
}

test "a raw value is written as one line whatever its bytes hold" {
    const Held = struct { data: strand.Raw };
    const value: Held = .{ .data = .{ .bytes = "{\n  \"who\": \"\u{e9}\u{1f600}\",\r\n  \"n\": 1\n}" } };

    // Minified: a line break is a space, and the value means what it meant.
    const line = "{\"data\":{   \"who\": \"\u{e9}\u{1f600}\",    \"n\": 1 }}\n";
    try expectWritten(Held, value, .{}, line);
    // Under escape_unicode, nothing but ASCII.
    try expectWritten(Held, value, .{ .escape_unicode = true }, "{\"data\":{   \"who\": \"\\u00e9\\ud83d\\ude00\",    \"n\": 1 }}\n");
    // A value with nothing to change is its bytes, in either mode.
    try expectWritten(Held, .{ .data = .{ .bytes = "[1,  \"x\"]" } }, .{ .escape_unicode = true }, "{\"data\":[1,  \"x\"]}\n");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The minified line reads back to the same value.
    const back = try strand.parseLine(Held, arena.allocator(), line[0 .. line.len - 1], .{});
    const Who = struct { who: []const u8, n: u8 };
    try testing.expectEqualStrings("\u{e9}\u{1f600}", (try back.data.parse(Who, arena.allocator(), .{})).who);

    // Pretty: written as it is, not re-indented, and read back by a pretty
    // reader, which takes `\r\n` for a terminator as every reader here does.
    var pretty: std.Io.Writer.Allocating = .init(arena.allocator());
    var pretty_writer: strand.Writer(Held) = .init(&pretty.writer, .{ .format = .pretty });
    try pretty_writer.write(value);
    try testing.expect(std.mem.indexOf(u8, pretty.written(), value.data.bytes) != null);
    var source: std.Io.Reader = .fixed(pretty.written());
    var reader: strand.Reader(Held) = .init(testing.allocator, &source, .{ .format = .pretty });
    defer reader.deinit();
    try testing.expectEqualStrings(
        "{\n  \"who\": \"\u{e9}\u{1f600}\",\n  \"n\": 1\n}",
        (try reader.next()).?.value.data.bytes,
    );
}

test "a raw value comes through a versioned record and its migration" {
    const Now = struct {
        kind: []const u8,
        data: strand.Raw = .null,
        pub const jsonl_version: u32 = 2;
        pub fn jsonlMigrate(allocator: std.mem.Allocator, from: u32, data: std.json.Value) std.json.ParseFromValueError!@This() {
            _ = from;
            return strand.payloadOf(@This(), allocator, data);
        }
    };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The current version is read straight into the record: bytes kept.
    const now = try strand.parseLine(strand.Versioned(Now), a, "{\"v\":2,\"data\":{\"kind\":\"k\",\"data\":[1, 2]}}", .{});
    try testing.expectEqualStrings("[1, 2]", now.value.data.bytes);
    // An older one goes through a `std.json.Value`, and is kept encoded.
    const old = try strand.parseLine(strand.Versioned(Now), a, "{\"v\":1,\"data\":{\"kind\":\"k\",\"data\":[1, 2]}}", .{});
    try testing.expectEqualStrings("[1,2]", old.value.data.bytes);
    try testing.expect(old.migrated());
}

test "a raw value comes off the end of a file owned" {
    const input = "{\"kind\":\"a\",\"data\":[1]}\n{\"kind\":\"b\",\"data\":{\"z\":2}}\n";
    var fixture: fixtures.Fixture = try .init(input, 64);
    defer fixture.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var tail: strand.Tail(Carried) = try .init(testing.allocator, &fixture.reader, .{});
    defer tail.deinit();
    const last = try tail.last(arena.allocator(), 2);
    try testing.expectEqualStrings("[1]", last[0].data.bytes);
    try testing.expectEqualStrings("{\"z\":2}", last[1].data.bytes);
}

//=========================================================================
// What a line costs, held to a budget.
//
// Two loops over the same bytes: this package's reader, and the same parse
// over a frame taken straight out of the input reader's buffer with nothing
// in between. The second is the floor — the typed decoder doing the work and the
// line layer doing nothing — so the first divided by the second is what the
// line layer costs, and that is the number a budget can be set on. An
// absolute ns/line would only be a fact about the machine that ran it.
//
// The reader measures within a few per cent of the floor on aarch64 and
// x86_64 alike (README.md's figures are 78 ns/line against 75), and the
// budget is ten per cent over the floor. A reader that copied every line
// into its own buffer measured about 1.15x, and so did one whose
// control-byte scan was a byte loop, so either regression fails this test
// rather than showing up as a number nobody reads.
//=========================================================================

/// The shape the figures were measured over: a short string, a number, an
/// enum, and one line in seven carrying a note with escapes in it.
const Timed = struct {
    kind: []const u8,
    at: u64 = 0,
    level: enum { info, warn } = .info,
    note: ?[]const u8 = null,
};

const timed_lines = 120_000;

/// The budget, as a fraction of what the same parse costs with no line layer
/// at all.
const timed_budget = 1.10;

fn timedInput(allocator: std.mem.Allocator) ![]u8 {
    const kinds: []const []const u8 = &.{ "request", "open", "retry", "close", "flush" };
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.ensureUnusedCapacity(timed_lines * 80);

    var log: strand.Writer(Timed) = .init(&out.writer, .{});
    for (0..timed_lines) |i| try log.write(.{
        .kind = kinds[i % kinds.len],
        .at = i,
        .level = if (i % 1000 == 0) .warn else .info,
        .note = if (i % 7 == 0) "user \"ada\" said \"no\"" else null,
    });

    var list = out.toArrayList();
    return list.toOwnedSlice(allocator);
}

/// This package's reader over `input`, in nanoseconds.
fn timeReader(input: []const u8) !u64 {
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Timed) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    var checksum: u64 = 0;
    const started = std.Io.Clock.awake.now(testing.io);
    while (try reader.next()) |line| checksum +%= line.value.at +% line.value.kind.len;
    const elapsed = started.untilNow(testing.io, .awake);

    try testing.expectEqual(@as(u64, timed_lines), reader.number);
    std.mem.doNotOptimizeAway(checksum);
    return @intCast(@max(elapsed.toNanoseconds(), 1));
}

/// The same parse with no line layer over it: the frame is a slice of the
/// input reader's own buffer, and nothing is copied or checked.
fn timeFloor(input: []const u8) !u64 {
    var source: std.Io.Reader = .fixed(input);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var checksum: u64 = 0;
    var seen: u64 = 0;
    const started = std.Io.Clock.awake.now(testing.io);
    while (source.takeDelimiterInclusive('\n')) |framed| {
        const line = framed[0 .. framed.len - 1];
        _ = arena.reset(.retain_capacity);
        const value = try strand.parseLine(Timed, arena.allocator(), line, .{});
        checksum +%= value.at +% value.kind.len;
        seen += 1;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    const elapsed = started.untilNow(testing.io, .awake);

    try testing.expectEqual(@as(u64, timed_lines), seen);
    std.mem.doNotOptimizeAway(checksum);
    return @intCast(@max(elapsed.toNanoseconds(), 1));
}

test "a line costs what the parse under it costs, within a tenth" {
    const input = try timedInput(testing.allocator);
    defer testing.allocator.free(input);

    // Best of fifteen, interleaved: a machine that is busy for a moment
    // slows whichever loop it lands in, and the best run of each is the one
    // the machine was not busy for. Five rounds were not enough to find
    // that run on a shared CI machine -- the two bests came from rounds
    // the load had hit unevenly, and the ratio between them read anywhere
    // from 0.83x to 1.87x on one host. Fifteen settles it to within a few
    // parts in a hundred, and costs about a second.
    var reader_ns: u64 = std.math.maxInt(u64);
    var floor_ns: u64 = std.math.maxInt(u64);
    for (0..15) |_| {
        reader_ns = @min(reader_ns, try timeReader(input));
        floor_ns = @min(floor_ns, try timeFloor(input));
    }

    const ratio = @as(f64, @floatFromInt(reader_ns)) / @as(f64, @floatFromInt(floor_ns));
    if (!withinBudget(ratio)) {
        std.debug.print(
            "read {d} ns/line against a floor of {d} ns/line: {d:.2}x, over the budget of {d:.2}x\n",
            .{ reader_ns / timed_lines, floor_ns / timed_lines, ratio, timed_budget },
        );
        return error.OverBudget;
    }
}

/// Whether a measured ratio is acceptable in the mode the suite is built in.
/// Debug and ReleaseSmall are not modes anything is measured in: one keeps
/// every safety check and the other asks the compiler not to vectorise, so a
/// budget set on optimized code would say nothing there.
fn withinBudget(ratio: f64) bool {
    return switch (@import("builtin").mode) {
        .ReleaseFast, .ReleaseSafe => ratio <= timed_budget,
        .Debug, .ReleaseSmall => true,
    };
}

/// A tagged union of `arms` arms, each a struct of `fields` integer fields:
/// the shape of a line protocol with many requests, built at comptime.
fn Wide(comptime arms: usize, comptime fields: usize) type {
    // for the names this builds, not for anything strand does
    @setEvalBranchQuota(100_000);
    var field_names: [fields][]const u8 = undefined;
    for (&field_names, 0..) |*name, i| name.* = std.fmt.comptimePrint("f{d}", .{i});
    const Arm = @Struct(.auto, null, &field_names, &@splat(u32), &@splat(.{}));
    var arm_names: [arms][]const u8 = undefined;
    for (&arm_names, 0..) |*name, i| name.* = std.fmt.comptimePrint("arm{d}", .{i});
    const Tag = @Enum(u8, .exhaustive, &arm_names, &std.simd.iota(u8, arms));
    return @Union(.auto, Tag, &arm_names, &@splat(Arm), &@splat(.{}));
}

test "a protocol of many arms decodes and encodes without raising a comptime quota" {
    // Sixty arms of eight fields: the reflection that decides which path
    // a type takes walks every field, and a schema this size is ordinary.
    const Request = Wide(60, 8);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const line = "{\"arm59\":{\"f0\":1,\"f1\":2,\"f2\":3,\"f3\":4,\"f4\":5,\"f5\":6,\"f6\":7,\"f7\":8}}";
    const request = try strand.parseLine(Request, arena.allocator(), line, .{});
    try std.testing.expectEqual(@as(u32, 8), request.arm59.f7);
    try std.testing.expectEqual(std.meta.Tag(Request).arm59, strand.tagOf(Request, line).?);

    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    var writer: strand.Writer(Request) = .init(&out.writer, .{});
    try writer.write(request);
    try std.testing.expectEqualStrings(line ++ "\n", out.written());
}

test "an integer a few bits wide is held to its range on every path" {
    // A type whose largest value is a single digit overflows on the first
    // digit, which is the case a check stated for longer numbers missed.
    const Small = struct { a: u3 = 0, b: u1 = 0, c: i3 = 0 };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(Small{ .a = 7, .b = 1, .c = 3 }, try strand.parseLine(Small, a, "{\"a\":7,\"b\":1,\"c\":3}", .{}));
    for ([_][]const u8{ "{\"a\":8}", "{\"a\":9}", "{\"a\":10}", "{\"b\":2}", "{\"c\":4}" }) |line| {
        try testing.expectError(error.Overflow, strand.parseLine(Small, a, line, .{}));
        // and where the reader asks where it failed, which is the other path
        var where: strand.Diagnostics = .{};
        try testing.expectError(error.Overflow, strand.parseLine(Small, a, line, .{ .diagnostics = &where }));
    }
    try testing.expectError(error.Overflow, strand.parseLine(Small, a, "{\"c\":-5}", .{}));
}

/// Writes `value` twice with `options`: once into a destination with room
/// in its buffer, which is where the writer encodes a record whole, and
/// once into one with none, where it streams. Both must be `want`.
fn expectWritten(comptime T: type, value: T, options: strand.Writer(T).Options, want: []const u8) !void {
    var room: [512]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&room);
    var buffered: strand.Writer(T) = .init(&fixed, options);
    try buffered.write(value);
    try testing.expectEqualStrings(want, fixed.buffered());

    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    var streamed: strand.Writer(T) = .init(&sink.writer, options);
    try streamed.write(value);
    try testing.expectEqualStrings(want, sink.written());
}

test "an integer of any width is written as its digits" {
    // One, three, seven, fifteen, thirty-one and sixty-three bits are each
    // one short of a power of two, where the length of the digit buffer
    // was worked out in a type too narrow to hold it.
    const Widths = struct { a: u3, b: u7, c: i7, d: u15, e: i31, f: u63, g: u1, h: i2 };
    const value: Widths = .{ .a = 7, .b = 127, .c = -64, .d = 32767, .e = -1073741824, .f = std.math.maxInt(u63), .g = 1, .h = -2 };
    const line = "{\"a\":7,\"b\":127,\"c\":-64,\"d\":32767,\"e\":-1073741824,\"f\":9223372036854775807,\"g\":1,\"h\":-2}\n";
    try expectWritten(Widths, value, .{}, line);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const back = try strand.parseLine(Widths, arena.allocator(), line[0 .. line.len - 1], .{});
    try testing.expectEqual(value, back);
}

test "a packed struct is read and written as any struct is" {
    // Its fields are bits of one integer, with no address to decode into
    // one at a time; the value is the same object on the line either way.
    const Caps = packed struct { plan: bool = false, stream: bool = false, level: u3 = 0 };
    const Row = struct { name: []const u8, caps: Caps = .{} };
    const line = "{\"name\":\"claude\",\"caps\":{\"plan\":true,\"stream\":false,\"level\":5}}";

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const row = try strand.parseLine(Row, arena.allocator(), line, .{});
    try testing.expect(row.caps.plan and !row.caps.stream);
    try testing.expectEqual(@as(u3, 5), row.caps.level);
    const partial = try strand.parseLine(Row, arena.allocator(), "{\"name\":\"x\",\"caps\":{\"stream\":true}}", .{});
    try testing.expect(!partial.caps.plan and partial.caps.stream);
    try testing.expectError(error.Overflow, strand.parseLine(Row, arena.allocator(), "{\"name\":\"x\",\"caps\":{\"level\":8}}", .{}));

    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try strand.writeLine(&out.writer, row);
    try testing.expectEqualStrings(line ++ "\n", out.written());
}
