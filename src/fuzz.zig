//! Properties that must hold for any bytes at all, checked by
//! `std.testing.fuzz` and by a table of awkward inputs so that a plain
//! `zig build test` checks them too.
//!
//! The properties are the ones a log reader is trusted for: nothing panics,
//! nothing leaks, a line is reported under its own number, and a line that
//! could not be parsed does not cost the reader its place in the stream.
//!
//! `zig build test` runs each property over the corpus below and over the
//! table, which is quick. `zig build test --fuzz` is what generates the rest.

const std = @import("std");
const testing = std.testing;
const zjsonl = @import("zjsonl.zig");

/// The shape a log line is parsed into here. Optional, defaulted and nested
/// fields so that a generated line can go wrong in more than one way.
const Event = struct {
    kind: []const u8,
    at: u64 = 0,
    level: enum { info, warn } = .info,
    note: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
};

/// The tagged union `tagOf` is asked about.
const Message = union(enum) {
    hello: struct { version: u8 },
    ping: u64,
    goodbye: struct { reason: []const u8 },
};

//=========================================================================
// The properties.
//=========================================================================

/// One physical line of `input`, as everything outside `zjsonl` sees it. This
/// is the oracle: an index scan written out, deliberately not sharing code
/// with `zjsonl.LineIterator` or with the reader.
const Physical = struct {
    /// The bytes up to the terminator, `\r` included.
    raw: []const u8,
    /// `raw` without a trailing `\r`, which is what the reader reports.
    line: []const u8,
    number: u64,
};

/// Walks `rest` the way the oracle says lines are laid out.
const PhysicalLines = struct {
    rest: []const u8,
    number: u64 = 0,

    fn next(it: *PhysicalLines) ?Physical {
        if (it.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, it.rest, '\n') orelse it.rest.len;
        const raw = it.rest[0..end];
        it.rest = it.rest[@min(end + 1, it.rest.len)..];
        it.number += 1;
        return .{
            .raw = raw,
            .line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw,
            .number = it.number,
        };
    }
};

/// The reader's own rule for a blank line, restated rather than imported.
fn isBlank(line: []const u8) bool {
    return std.mem.indexOfNone(u8, line, " \t") == null;
}

/// In `.fail` mode the reader and the oracle move in lockstep: every line the
/// oracle sees is either skipped as blank, refused for its length, or
/// reported — under the oracle's number, with the oracle's bytes.
fn checkReaderFail(input: []const u8, max_line_bytes: usize) !void {
    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{
        .max_line_bytes = max_line_bytes,
    });
    defer reader.deinit();

    var oracle: PhysicalLines = .{ .rest = input };
    while (oracle.next()) |physical| {
        // The bound is measured before the `\r` is dropped, because the reader
        // has to read the byte before it can know it was a terminator.
        if (physical.raw.len > max_line_bytes) {
            try testing.expectError(error.LineTooLong, reader.next());
            try testing.expectEqual(physical.number, reader.last_error_line);
            try testing.expectEqual(physical.number, reader.number);
            continue;
        }
        if (isBlank(physical.line)) continue;

        const control = zjsonl.indexOfControl(physical.line);
        if (reader.next()) |maybe_line| {
            const line = maybe_line orelse return error.TestReaderEndedEarly;
            try testing.expectEqual(physical.number, line.number);
            try testing.expectEqualStrings(physical.line, line.line);
            try testing.expectEqualStrings(line.value.kind, line.value.kind);
            // A line that came back is a line with nothing raw in it.
            try testing.expectEqual(@as(?usize, null), control);
        } else |err| switch (err) {
            error.MalformedLine => {
                try testing.expectEqual(physical.number, reader.last_error_line);
                try testing.expect(reader.last_error != null);
                // The control byte scan runs first, so a line that parsed
                // badly is a line that had no control byte to blame.
                try testing.expectEqual(@as(?usize, null), control);
            },
            error.ControlByte => {
                try testing.expectEqual(physical.number, reader.last_error_line);
                try testing.expectEqual(control, reader.last_error_offset);
                try testing.expectEqual(@as(?zjsonl.ParseLineError, null), reader.last_error);
            },
            else => return err,
        }
    }
    try testing.expectEqual(@as(?zjsonl.Line(Event), null), try reader.next());
    try testing.expectEqual(oracle.number, reader.number);
}

/// In `.skip` mode the lines that come back are a subsequence of the oracle's,
/// in order, with the right numbers and bytes — and the stream is still read
/// to its end, whatever it contained.
fn checkReaderSkip(input: []const u8) !void {
    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{
        .on_malformed = .skip,
        // Long enough that no line can trip it: `.skip` is about parsing.
        .max_line_bytes = input.len + 1,
    });
    defer reader.deinit();

    var oracle: PhysicalLines = .{ .rest = input };
    var previous: u64 = 0;
    while (try reader.next()) |line| {
        try testing.expect(line.number > previous);
        previous = line.number;

        var physical = oracle.next() orelse return error.TestReaderInventedALine;
        while (physical.number < line.number) {
            physical = oracle.next() orelse return error.TestReaderInventedALine;
        }
        try testing.expectEqual(physical.number, line.number);
        try testing.expectEqualStrings(physical.line, line.line);
        try testing.expect(!isBlank(physical.line));
    }

    var all: PhysicalLines = .{ .rest = input };
    while (all.next()) |_| {}
    try testing.expectEqual(all.number, reader.number);
}

/// `kindOf` either declines, or points at a real key of a real object.
fn checkKindOf(line: []const u8) !void {
    const kind = zjsonl.kindOf(line);
    if (kind) |key| {
        // A view into the line, quoted on both sides, and no escape in it.
        const start = @intFromPtr(key.ptr) - @intFromPtr(line.ptr);
        try testing.expect(start >= 1 and start + key.len < line.len);
        try testing.expectEqual(@as(u8, '"'), line[start - 1]);
        try testing.expectEqual(@as(u8, '"'), line[start + key.len]);
        try testing.expect(std.mem.indexOfAny(u8, key, "\"\\") == null);
    }

    if (!isShallow(line)) return;
    var parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{}) catch return;
    defer parsed.deinit();

    switch (parsed.value) {
        // `std.json.ObjectMap` keeps insertion order, so `keys()[0]` really is
        // the first key of the line.
        .object => |object| {
            if (object.count() == 0) {
                try testing.expectEqual(@as(?[]const u8, null), kind);
            } else if (kind) |key| {
                try testing.expectEqualStrings(object.keys()[0], key);
            } else {
                // The only reason to decline a valid object is an escape.
                try testing.expect(std.mem.indexOfScalar(u8, line, '\\') != null);
            }
        },
        // Nothing but an object has a first key.
        else => try testing.expectEqual(@as(?[]const u8, null), kind),
    }
}

/// `tagOf` agrees with `kindOf` about the key, and with a full parse about
/// the arm.
fn checkTagOf(line: []const u8) !void {
    const tag = zjsonl.tagOf(Message, line);
    if (tag) |t| {
        const key = zjsonl.kindOf(line) orelse return error.TestTagWithoutKey;
        try testing.expectEqualStrings(@tagName(t), key);
    }

    if (!isShallow(line)) return;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const value = zjsonl.parseLine(Message, arena.allocator(), line, .{}) catch return;

    if (tag) |t| {
        try testing.expectEqual(std.meta.activeTag(value), t);
    } else {
        try testing.expect(std.mem.indexOfScalar(u8, line, '\\') != null);
    }
}

/// `lines` splits exactly the way the oracle does, and hands back views.
fn checkLines(input: []const u8) !void {
    var oracle: PhysicalLines = .{ .rest = input };
    var it = zjsonl.lines(input);
    while (it.next()) |line| {
        const physical = oracle.next() orelse return error.TestExtraLine;
        try testing.expectEqual(physical.number, line.number);
        try testing.expectEqualStrings(physical.line, line.line);
        try testing.expect(std.mem.indexOfScalar(u8, line.line, '\n') == null);
        if (line.line.len != 0) {
            const start = @intFromPtr(line.line.ptr) - @intFromPtr(input.ptr);
            try testing.expect(start + line.line.len <= input.len);
        }
    }
    try testing.expectEqual(@as(?Physical, null), oracle.next());
}

/// True when `line` nests shallowly enough for the recursive oracles above.
/// `std.json`'s value parsers recurse once per level, so a line of ten
/// thousand `[` is a stack overflow in the oracle — never in `zjsonl`, which
/// only ever hands the line to `std.json` as a whole.
fn isShallow(line: []const u8) bool {
    var depth: usize = 0;
    for (line) |byte| switch (byte) {
        '[', '{' => {
            depth += 1;
            if (depth > 32) return false;
        },
        else => {},
    };
    return true;
}

/// A `.pretty` reader over any bytes at all reads the stream to its end,
/// numbers what it returns in order, and never claims a line the oracle does
/// not have.
///
/// It cannot be held to the same lockstep as `checkReaderFail`: joining is
/// exactly the freedom to turn several physical lines into one record, so the
/// property is that it stays inside the input rather than that it agrees line
/// for line.
fn checkPretty(input: []const u8) !void {
    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{
        .format = .pretty,
        .on_malformed = .skip,
    });
    defer reader.deinit();

    var all: PhysicalLines = .{ .rest = input };
    while (all.next()) |_| {}

    var previous: u64 = 0;
    while (true) {
        const line = reader.next() catch |err| switch (err) {
            // The one failure `.skip` does not swallow.
            error.LineTooLong => continue,
            else => return err,
        } orelse break;
        try testing.expect(line.number > previous);
        previous = line.number;
        try testing.expect(line.number <= all.number);
    }
    try testing.expect(reader.number <= all.number);
}

/// A round trip through `.pretty`: what the writer indents over several lines,
/// the reader puts back together as one record, whatever the values held.
fn checkPrettyRoundTrip(events: []const Event) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: zjsonl.Writer(Event) = .init(&out.writer, .{ .format = .pretty });
    try writer.writeAll(events);

    var source: std.Io.Reader = .fixed(out.written());
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, .{ .format = .pretty });
    defer reader.deinit();

    for (events) |want| {
        const line = (try reader.next()) orelse return error.TestReaderEndedEarly;
        try testing.expectEqualStrings(want.kind, line.value.kind);
        try testing.expectEqual(want.at, line.value.at);
        try testing.expectEqual(want.level, line.value.level);
        try testing.expectEqual(want.tags.len, line.value.tags.len);
        if (want.note) |note| {
            try testing.expectEqualStrings(note, line.value.note.?);
        } else {
            try testing.expectEqual(@as(?[]const u8, null), line.value.note);
        }
    }
    try testing.expectEqual(@as(?zjsonl.Line(Event), null), try reader.next());
}

/// The versioned record this package writes is the versioned record it reads,
/// and a version it does not know is refused rather than guessed at.
const Versioned2 = struct {
    kind: []const u8,
    at: u64 = 0,

    pub const jsonl_version: u32 = 2;

    pub fn jsonlMigrate(
        allocator: std.mem.Allocator,
        from: u32,
        data: std.json.Value,
    ) std.json.ParseFromValueError!Versioned2 {
        if (from != 1) return error.UnknownField;
        const old = try zjsonl.payloadOf(struct { kind: []const u8 }, allocator, data);
        return .{ .kind = old.kind, .at = 0 };
    }
};

/// `Versioned` over any bytes: it either parses, or it fails with one of
/// `std.json`'s errors — never a panic and never a leak.
fn checkVersioned(line: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const record = zjsonl.parseLine(
        zjsonl.Versioned(Versioned2),
        arena.allocator(),
        line,
        .{},
    ) catch return;

    // A record that came back came back in today's shape, and says which
    // shape the line was in.
    try testing.expect(record.from == 1 or record.from == 2 or record.from == 0);
    try testing.expectEqual(record.from != 2, record.migrated());

    // And writing it back gives a line that reads as itself.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try zjsonl.writeLine(&out.writer, record);
    try testing.expect(std.mem.startsWith(u8, out.written(), "{\"v\":2,\"data\":"));

    var again: std.heap.ArenaAllocator = .init(testing.allocator);
    defer again.deinit();
    const round = try zjsonl.parseLine(
        zjsonl.Versioned(Versioned2),
        again.allocator(),
        out.written()[0 .. out.written().len - 1],
        .{},
    );
    try testing.expectEqual(@as(u32, 2), round.from);
    try testing.expectEqualStrings(record.value.kind, round.value.kind);
    try testing.expectEqual(record.value.at, round.value.at);
}

/// Reading a file backwards gives the same lines as reading it forwards, in
/// the other order, under the same options.
///
/// This is the whole claim `Tail` makes, and it is checked against `Reader`
/// rather than against a second copy of the splitting rules: the two share no
/// code, so an agreement between them is evidence rather than a tautology.
/// The line numbers are checked too, since they run the other way: a line that
/// is the *i*th from the start of a file of *n* lines is the *(n + 1 - i)*th
/// from its end.
fn checkTail(input: []const u8) !void {
    const options: zjsonl.Reader(Event).Options = .{
        .on_malformed = .skip,
        // A bound the generated input can reach, so that an over-long line is
        // part of the property.
        .max_line_bytes = 96,
        // The forward reader takes the mark off the stream and the backwards
        // one off the line, which is the same line but a different length,
        // and the bound above would see the difference.
        .skip_bom = false,
    };

    var forward_lines: std.ArrayList([]const u8) = .empty;
    var forward_numbers: std.ArrayList(u64) = .empty;
    defer {
        for (forward_lines.items) |item| testing.allocator.free(item);
        forward_lines.deinit(testing.allocator);
        forward_numbers.deinit(testing.allocator);
    }

    var source: std.Io.Reader = .fixed(input);
    var reader: zjsonl.Reader(Event) = .init(testing.allocator, &source, options);
    defer reader.deinit();
    while (true) {
        const line = reader.next() catch |err| switch (err) {
            error.LineTooLong => continue,
            else => return err,
        } orelse break;
        try forward_lines.append(testing.allocator, try testing.allocator.dupe(u8, line.line));
        try forward_numbers.append(testing.allocator, line.number);
    }
    const total = reader.number;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = input });
    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);

    var buffer: [37]u8 = undefined;
    var file_reader = file.reader(testing.io, &buffer);
    var tail: zjsonl.Tail(Event) = try .init(testing.allocator, &file_reader, .{
        .on_malformed = .skip,
        .max_line_bytes = options.max_line_bytes,
        .skip_bom = options.skip_bom,
        // Small enough that a line spans several of them.
        .block_bytes = 13,
    });
    defer tail.deinit();

    var seen: usize = 0;
    while (true) {
        const line = tail.prev() catch |err| switch (err) {
            error.LineTooLong => continue,
            else => return err,
        } orelse break;
        if (seen >= forward_lines.items.len) return error.TestTailInventedALine;
        const i = forward_lines.items.len - 1 - seen;
        try testing.expectEqualStrings(forward_lines.items[i], line.line);
        try testing.expectEqual(total + 1 - forward_numbers.items[i], line.number);
        seen += 1;
    }
    try testing.expectEqual(forward_lines.items.len, seen);
}

//=========================================================================
// The generator: lines that are nearly right, plus bytes that are not.
//=========================================================================

/// Writes generated JSON Lines into `buf` and returns what was written.
fn generate(smith: *std.testing.Smith, buf: []u8) []u8 {
    @disableInstrumentation();
    var end: usize = 0;
    while (end < buf.len and !smith.eos()) {
        switch (smith.valueRangeAtMost(u8, 0, 6)) {
            0 => append(buf, &end, "{\"kind\":\"open\",\"at\":1,\"tags\":[\"a\"]}"),
            1 => append(buf, &end, "{\"kind\":\"open\",\"at\":"),
            2 => append(buf, &end, "{\"ping\":7}"),
            3 => append(buf, &end, "   "),
            4 => append(buf, &end, "{\"ki\\u006ed\":\"escaped\"}"),
            5 => {
                append(buf, &end, "{\"kind\":\"");
                const filler = smith.valueRangeAtMost(u8, 0, 64);
                for (0..filler) |_| append(buf, &end, "x");
                append(buf, &end, "\"}");
            },
            // Bytes with no intentions at all, newlines among them.
            else => {
                var chunk: [24]u8 = undefined;
                append(buf, &end, chunk[0..smith.slice(&chunk)]);
            },
        }
        switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => append(buf, &end, "\n"),
            1 => append(buf, &end, "\r\n"),
            else => {},
        }
    }
    return buf[0..end];
}

/// Appends what fits and drops the rest, so the generator cannot overrun.
fn append(buf: []u8, end: *usize, bytes: []const u8) void {
    @disableInstrumentation();
    const n = @min(bytes.len, buf.len - end.*);
    @memcpy(buf[end.*..][0..n], bytes[0..n]);
    end.* += n;
}

/// Writes generated versioned envelopes into `buf` and returns what was
/// written. Versions from before, at and after the current one, plus lines
/// with no version at all and lines that are not envelopes.
fn generateVersioned(smith: *std.testing.Smith, buf: []u8) []u8 {
    @disableInstrumentation();
    var end: usize = 0;
    while (end < buf.len and !smith.eos()) {
        switch (smith.valueRangeAtMost(u8, 0, 6)) {
            0 => append(buf, &end, "{\"v\":2,\"data\":{\"kind\":\"open\",\"at\":1}}"),
            1 => append(buf, &end, "{\"v\":1,\"data\":{\"kind\":\"open\"}}"),
            2 => append(buf, &end, "{\"data\":{\"kind\":\"open\"},\"v\":1}"),
            3 => append(buf, &end, "{\"data\":{\"kind\":\"unstamped\"}}"),
            4 => append(buf, &end, "{\"v\":9999,\"data\":{\"kind\":\"future\"}}"),
            5 => append(buf, &end, "{\"v\":2}"),
            else => {
                var chunk: [24]u8 = undefined;
                append(buf, &end, chunk[0..smith.slice(&chunk)]);
            },
        }
        append(buf, &end, "\n");
    }
    return buf[0..end];
}

/// Fills `events` with generated values, drawing their strings out of `text`,
/// and returns the ones that fit. The strings are where a round trip can go
/// wrong, so they are where the awkward bytes go.
fn generateEvents(smith: *std.testing.Smith, events: []Event, text: []u8) []Event {
    @disableInstrumentation();
    const specials: []const []const u8 = &.{
        "plain",       "with \"quotes\"", "line\nbreak",
        "tab\there",   "\u{2028}sep",     "back\\slash",
        "\x01control", "",                "\u{1f600}",
    };
    var used: usize = 0;
    var count: usize = 0;
    while (count < events.len and !smith.eos()) : (count += 1) {
        const pick = specials[smith.valueRangeAtMost(u8, 0, specials.len - 1)];
        if (used + pick.len > text.len) break;
        @memcpy(text[used..][0..pick.len], pick);
        const kind = text[used..][0..pick.len];
        used += pick.len;
        events[count] = .{
            .kind = kind,
            .at = smith.valueRangeAtMost(u64, 0, std.math.maxInt(u64)),
            .level = if (smith.valueRangeAtMost(u8, 0, 1) == 0) .info else .warn,
            .note = if (smith.valueRangeAtMost(u8, 0, 1) == 0) null else kind,
        };
    }
    return events[0..count];
}

/// Seeds. Their bytes drive the generator rather than being the input, so
/// they are here to give a campaign somewhere to start, and to give
/// `zig build test` a handful of runs that are not the empty one.
const corpus: []const []const u8 = &.{
    "{\"kind\":\"open\",\"at\":1}\n{\"kind\":\"close\"}\n",
    "\x00\x01\x02\x03\x04\x05\x06\x07\n\r\n{\"a\":1}",
    "\xff\xfe\xfd\xfc\xfb\xfa\xf9\xf8\xf7\xf6\xf5\xf4\xf3\xf2\xf1\xf0",
    "{}{}{}{}{}{}{}{}\n\n\n\n{\"ping\":7}\n",
    "        \t\t\t\t\n\"\\\\\"\\\"\\\"\n{\"kind\":\"\"}\n",
};

/// Seeds for the versioned property, for the same reason `corpus` exists.
const versioned_corpus: []const []const u8 = &.{
    "{\"v\":2,\"data\":{\"kind\":\"open\"}}\n",
    "{\"v\":1,\"data\":{\"kind\":\"open\"}}\n{\"v\":9,\"data\":1}\n",
    "\x00\x01\x02\n{}\n",
};

test "fuzz: Reader.next over generated lines" {
    try std.testing.fuzz({}, fuzzReader, .{ .corpus = corpus });
}

fn fuzzReader(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [2048]u8 = undefined;
    const input = generate(smith, &buf);
    // A bound the input can actually reach, so that `error.LineTooLong` is
    // part of the property rather than a branch nothing takes.
    const max_line_bytes = smith.valueRangeAtMost(u32, 1, 128);
    try checkReaderFail(input, max_line_bytes);
    try checkReaderFail(input, buf.len + 1);
    try checkReaderSkip(input);
}

test "fuzz: kindOf over generated lines" {
    try std.testing.fuzz({}, fuzzKindOf, .{ .corpus = corpus });
}

fn fuzzKindOf(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    var it = zjsonl.lines(generate(smith, &buf));
    while (it.next()) |line| try checkKindOf(line.line);
}

test "fuzz: tagOf over generated lines" {
    try std.testing.fuzz({}, fuzzTagOf, .{ .corpus = corpus });
}

fn fuzzTagOf(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    var it = zjsonl.lines(generate(smith, &buf));
    while (it.next()) |line| try checkTagOf(line.line);
}

test "fuzz: lines over generated input" {
    try std.testing.fuzz({}, fuzzLines, .{ .corpus = corpus });
}

fn fuzzLines(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [2048]u8 = undefined;
    try checkLines(generate(smith, &buf));
}

test "fuzz: a pretty reader over generated lines" {
    try std.testing.fuzz({}, fuzzPretty, .{ .corpus = corpus });
}

fn fuzzPretty(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [2048]u8 = undefined;
    try checkPretty(generate(smith, &buf));
}

test "fuzz: a pretty round trip over generated values" {
    try std.testing.fuzz({}, fuzzPrettyRoundTrip, .{ .corpus = corpus });
}

fn fuzzPrettyRoundTrip(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var text: [512]u8 = undefined;
    var events: [16]Event = undefined;
    try checkPrettyRoundTrip(generateEvents(smith, &events, &text));
}

test "fuzz: Tail over generated files" {
    try std.testing.fuzz({}, fuzzTail, .{ .corpus = corpus });
}

fn fuzzTail(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    try checkTail(generate(smith, &buf));
}

test "fuzz: Versioned over generated lines" {
    try std.testing.fuzz({}, fuzzVersioned, .{ .corpus = versioned_corpus });
}

fn fuzzVersioned(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    var it = zjsonl.lines(generateVersioned(smith, &buf));
    while (it.next()) |line| try checkVersioned(line.line);
}

//=========================================================================
// The same properties, over inputs chosen by hand. A fuzz test that is only
// ever run over its corpus proves little, and a corpus drives the generator
// rather than the code, so the awkward cases are stated outright.
//=========================================================================

const table: []const []const u8 = &.{
    "",
    "\n",
    "\r\n",
    "\n\n\n",
    "   \t  ",
    "{",
    "}",
    "{}",
    "{\"\":1}",
    "null",
    "42",
    "\"kind\"",
    "[{\"kind\":\"open\"}]",
    "{\"kind\":\"open\"}",
    "{\"kind\":\"open\"}\n",
    "{\"kind\":\"open\"}\r\n{\"kind\":\"close\"}",
    "{\"kind\":\"open\"}\nnot json\n{\"kind\":\"close\"}\n",
    "{\"ki\\u006ed\":\"open\"}\n",
    "{\"kind\":\"o\\u0070en\",\"at\":2}\n",
    "{\"ping\":7}\n{\"hello\":{\"version\":1}}\n{\"goodbye\":{\"reason\":\"x\"}}\n",
    "{\"kind\":\"open\",\"at\":-1}\n",
    "{\"kind\":\"open\",\"at\":99999999999999999999999}\n",
    "{\"kind\":\"open\",\"kind\":\"twice\"}\n",
    "{\"kind\":\"open\"} trailing\n",
    "{\"kind\":\"open\"}{\"kind\":\"again\"}\n",
    "\x00\x01\x02\n\xff\xfe\n",
    "{\"kind\":\"\xff\xfe\"}\n",
    "{ \"kind\" : \"spaced\" }\n",
    "{\"tags\":[\"a\",\"b\"],\"span\":{\"id\":1}}\n",
};

test "the properties hold on a table of awkward inputs" {
    for (table) |input| {
        try checkLines(input);
        try checkReaderFail(input, 1 << 20);
        try checkReaderFail(input, 8);
        try checkReaderFail(input, 1);
        try checkReaderSkip(input);

        try checkPretty(input);
        try checkTail(input);

        var it = zjsonl.lines(input);
        while (it.next()) |line| {
            try checkKindOf(line.line);
            try checkTagOf(line.line);
            try checkVersioned(line.line);
        }
    }

    for (versioned_table) |line| try checkVersioned(line);
    try checkPrettyRoundTrip(&.{});
    try checkPrettyRoundTrip(&.{
        .{ .kind = "plain", .at = 1 },
        .{ .kind = "with \"quotes\" and a\nbreak", .at = 2, .level = .warn, .note = "x" },
        .{ .kind = "", .at = std.math.maxInt(u64), .tags = &.{ "a", "b" } },
    });
}

/// Envelopes chosen by hand, for the cases a generator is unlikely to reach.
const versioned_table: []const []const u8 = &.{
    "{}",
    "{\"v\":2}",
    "{\"data\":null}",
    "{\"v\":0,\"data\":{\"kind\":\"zero\"}}",
    "{\"v\":2,\"data\":{\"kind\":\"open\"},\"extra\":[1,2]}",
    "{\"v\":2,\"v\":2,\"data\":{\"kind\":\"twice\"}}",
    "{\"v\":-1,\"data\":{}}",
    "{\"v\":\"2\",\"data\":{}}",
    "{\"data\":{\"kind\":\"first\"},\"data\":{\"kind\":\"again\"}}",
    "[{\"v\":2,\"data\":{}}]",
};
