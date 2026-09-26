//! Properties that must hold for any bytes at all, checked by
//! `std.testing.fuzz` and by a table of awkward inputs so that a plain
//! `zig build test` checks them too.
//!
//! The properties are the ones a log reader is trusted for: nothing panics,
//! nothing leaks, a line is reported under its own number, and a line that
//! could not be parsed does not cost the reader its place in the stream.
//!
//! `zig build test` runs each property over the corpus below, over the table,
//! and over as many seeded rounds as `-Dcampaign` asks for, which is quick.
//! `zig build test --fuzz` runs the same properties under the compiler's
//! fuzzer, which steers by coverage and does not stop.

const std = @import("std");
const testing = std.testing;
const strand = @import("strand.zig");
const fixtures = @import("fixtures.zig");

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

/// The scanner is an implementation detail; `std.json` remains its oracle.
/// Successful parses must produce the same typed value, and neither scanner
/// may accept bytes the other rejects.
fn checkScanner(line: []const u8) !void {
    var std_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer std_arena.deinit();
    var strand_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer strand_arena.deinit();

    var std_err: ?anyerror = null;
    const expected: ?Event = if (std.mem.endsWith(u8, line, "\n")) result: {
        // `parseLine` takes bytes without their JSON Lines terminator; this
        // is the one deliberate difference from a general JSON parser.
        std_err = error.SyntaxError;
        break :result null;
    } else std.json.parseFromSliceLeaky(Event, std_arena.allocator(), line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch |err| result: {
        std_err = err;
        break :result null;
    };
    var strand_err: ?anyerror = null;
    const actual: ?Event = strand.parseLine(Event, strand_arena.allocator(), line, .{}) catch |err| result: {
        strand_err = err;
        break :result null;
    };

    try testing.expectEqual(std_err == null, strand_err == null);
    if (expected) |want| {
        const got = actual.?;
        try testing.expectEqualStrings(want.kind, got.kind);
        try testing.expectEqual(want.at, got.at);
        try testing.expectEqual(want.level, got.level);
        try testing.expectEqual(want.note == null, got.note == null);
        if (want.note) |note| try testing.expectEqualStrings(note, got.note.?);
        try testing.expectEqual(want.tags.len, got.tags.len);
        for (want.tags, got.tags) |want_tag, got_tag| try testing.expectEqualStrings(want_tag, got_tag);
    }
}

//=========================================================================
// The properties.
//=========================================================================

/// One physical line of `input`, as everything outside `strand` sees it. This
/// is the oracle: an index scan written out, deliberately not sharing code
/// with `strand.LineIterator` or with the reader.
const Physical = struct {
    /// The bytes up to the terminator, `\r` included.
    raw: []const u8,
    /// `raw` without a trailing `\r`, which is what the reader reports.
    line: []const u8,
    number: u64,
    /// The offset of the line's first byte in the input.
    offset: u64,
};

/// Walks `rest` the way the oracle says lines are laid out.
const PhysicalLines = struct {
    rest: []const u8,
    number: u64 = 0,
    offset: u64 = 0,

    fn next(it: *PhysicalLines) ?Physical {
        if (it.rest.len == 0) return null;
        const end = std.mem.indexOfScalar(u8, it.rest, '\n') orelse it.rest.len;
        const raw = it.rest[0..end];
        const offset = it.offset;
        it.offset += @min(end + 1, it.rest.len);
        it.rest = it.rest[@min(end + 1, it.rest.len)..];
        it.number += 1;
        return .{
            .raw = raw,
            .line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw,
            .number = it.number,
            .offset = offset,
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
    try checkReaderFailOver(&source, input, max_line_bytes);

    // And the same over a stream that hands its bytes over a few at a time
    // through a buffer of its own. A line the reader can frame where it lies
    // and a line it has to copy out of several reads are the same line, so
    // the size of that buffer is not allowed to change a single answer:
    // not the bytes, not the number, not the offset, not the bound.
    for ([_]usize{ 1, 2, 7, 64, 4096 }) |buffer_len| {
        const buffer = try testing.allocator.alloc(u8, buffer_len);
        defer testing.allocator.free(buffer);
        var chunked: fixtures.Chunked = .init(input, buffer, buffer_len);
        try checkReaderFailOver(&chunked.interface, input, max_line_bytes);
    }
}

fn checkReaderFailOver(source: *std.Io.Reader, input: []const u8, max_line_bytes: usize) !void {
    var reader: strand.Reader(Event) = .init(testing.allocator, source, .{
        .max_line_bytes = max_line_bytes,
        // The oracle counts bytes, and a mark the reader drops is bytes the
        // oracle would still be counting. `a byte-order mark belongs to the
        // file` in the suite is where dropping it is checked.
        .skip_bom = false,
    });
    defer reader.deinit();
    var oracle_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer oracle_arena.deinit();

    var oracle: PhysicalLines = .{ .rest = input };
    while (oracle.next()) |physical| {
        // The `\r` half of a CRLF terminator is not a record byte.
        if (physical.line.len > max_line_bytes) {
            try testing.expectError(error.LineTooLong, reader.next());
            try testing.expectEqual(physical.number, reader.lines.fault.line);
            try testing.expectEqual(physical.number, reader.lines.number);
            continue;
        }
        if (isBlank(physical.line)) continue;

        const control = strand.indexOfControl(physical.line);
        if (reader.next()) |maybe_line| {
            const line = maybe_line orelse return error.TestReaderEndedEarly;
            try testing.expectEqual(physical.number, line.number);
            try testing.expectEqualStrings(physical.line, line.line);
            // The offset is where the line's bytes actually are.
            try testing.expectEqual(physical.offset, line.offset);
            try testing.expectEqual(physical.offset, reader.lines.offset);
            _ = oracle_arena.reset(.retain_capacity);
            const expected = try std.json.parseFromSliceLeaky(Event, oracle_arena.allocator(), physical.line, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_if_needed,
            });
            try testing.expectEqualStrings(expected.kind, line.value.kind);
            // A line that came back is a line with nothing raw in it.
            try testing.expectEqual(@as(?usize, null), control);
        } else |err| switch (err) {
            error.MalformedLine => {
                try testing.expectEqual(physical.number, reader.lines.fault.line);
                try testing.expectEqual(physical.offset, reader.lines.offset);
                try testing.expect(reader.lines.fault.err != null);
                // Where the parse gave up is a place in the line, or is not
                // reported at all. It is never a place outside it.
                if (reader.lines.fault.offset) |at| try testing.expect(at <= physical.line.len);
                // The control byte scan runs first, so a line that parsed
                // badly is a line that had no control byte to blame.
                try testing.expectEqual(@as(?usize, null), control);
            },
            error.ControlByte => {
                try testing.expectEqual(physical.number, reader.lines.fault.line);
                try testing.expectEqual(physical.offset, reader.lines.offset);
                try testing.expectEqual(control, reader.lines.fault.offset);
                try testing.expectEqual(@as(?strand.ParseLineError, null), reader.lines.fault.err);
            },
            else => return err,
        }
    }
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
    try testing.expectEqual(oracle.number, reader.lines.number);
}

/// A `LineReader` moves in lockstep with the oracle in both modes: every line
/// the oracle sees is passed over as blank, refused for its length, refused
/// or passed over for a control byte, or handed back under the oracle's
/// number and offset with the oracle's bytes. A refusal is never the end of
/// the stream — the lines after an over-long one are all still read — and
/// the size of the stream's own buffer changes nothing, since a line the
/// reader can frame where it lies and one it copies out of several reads are
/// the same line.
fn checkLineReader(input: []const u8, max_line_bytes: usize) !void {
    for ([_]@FieldType(strand.LineReader.Options, "on_malformed"){ .fail, .skip }) |on_malformed| {
        var source: std.Io.Reader = .fixed(input);
        try checkLineReaderOver(&source, input, max_line_bytes, on_malformed);
        for ([_]usize{ 1, 2, 7, 64, 4096 }) |buffer_len| {
            const buffer = try testing.allocator.alloc(u8, buffer_len);
            defer testing.allocator.free(buffer);
            var chunked: fixtures.Chunked = .init(input, buffer, buffer_len);
            try checkLineReaderOver(&chunked.interface, input, max_line_bytes, on_malformed);
        }
    }
}

fn checkLineReaderOver(
    source: *std.Io.Reader,
    input: []const u8,
    max_line_bytes: usize,
    on_malformed: @FieldType(strand.LineReader.Options, "on_malformed"),
) !void {
    var reader: strand.LineReader = .init(testing.allocator, source, .{
        .max_line_bytes = max_line_bytes,
        .on_malformed = on_malformed,
        // The oracle counts bytes, and a mark the reader drops is bytes the
        // oracle would still be counting.
        .skip_bom = false,
    });
    defer reader.deinit();

    var damaged: u64 = 0;
    var oracle: PhysicalLines = .{ .rest = input };
    while (oracle.next()) |physical| {
        if (physical.line.len > max_line_bytes) {
            // Refused in either mode: a bound is not damage to pass over.
            try testing.expectError(error.LineTooLong, reader.next());
            try testing.expectEqual(physical.number, reader.fault.line);
            try testing.expectEqual(physical.number, reader.number);
            try testing.expectEqual(physical.offset, reader.offset);
            try testing.expectEqual(@as(?usize, null), reader.fault.offset);
            continue;
        }
        if (isBlank(physical.line)) continue;

        if (strand.indexOfControl(physical.line)) |control| {
            damaged += 1;
            switch (on_malformed) {
                .fail => {
                    try testing.expectError(error.ControlByte, reader.next());
                    try testing.expectEqual(physical.number, reader.fault.line);
                    try testing.expectEqual(physical.offset, reader.offset);
                    try testing.expectEqual(@as(?usize, control), reader.fault.offset);
                    try testing.expectEqual(@as(?strand.ParseLineError, null), reader.fault.err);
                },
                // Passed over, and said nothing about until the line after
                // it, which is where the next answer comes from.
                .skip => {},
            }
            continue;
        }

        const line = (try reader.next()) orelse return error.TestReaderEndedEarly;
        try testing.expectEqual(physical.number, line.number);
        try testing.expectEqualStrings(physical.line, line.line);
        try testing.expectEqual(physical.offset, line.offset);
        try testing.expectEqual(physical.offset, reader.offset);
        // A line that is handed back is where the next read begins.
        try testing.expectEqual(physical.offset, reader.recordStart().offset);
        try testing.expectEqual(physical.number - 1, reader.recordStart().lines_before);
    }
    try testing.expectEqual(@as(?strand.RawLine, null), try reader.next());
    try testing.expectEqual(oracle.number, reader.number);
    try testing.expectEqual(if (on_malformed == .skip) damaged else 0, reader.skipped);
}

/// In `.skip` mode the lines that come back are a subsequence of the oracle's,
/// in order, with the right numbers and bytes — and the stream is still read
/// to its end, whatever it contained.
fn checkReaderSkip(input: []const u8) !void {
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
        .on_malformed = .skip,
        // Long enough that no line can trip it: `.skip` is about parsing.
        .max_line_bytes = input.len + 1,
        // The oracle counts bytes, and a mark the reader drops is bytes the
        // oracle would still be counting.
        .skip_bom = false,
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
    try testing.expectEqual(all.number, reader.lines.number);
}

/// A reader resumed at a line's offset reports that line under the number and
/// the offset the oracle gives it, and carries on from there in lockstep with
/// a reader that read the whole stream.
///
/// This is the property an index rests on: the offsets in it are the oracle's
/// own byte counts, and what comes back at one of them has to be the line the
/// oracle put there — not merely a line, and not line 1 of a new stream.
fn checkResume(input: []const u8) !void {
    const options: strand.Reader(Event).Options = .{
        // The oracle counts bytes, and a mark the reader drops is bytes the
        // oracle would still be counting.
        .skip_bom = false,
    };

    var count: PhysicalLines = .{ .rest = input };
    while (count.next()) |_| {}
    const total = count.number;

    var oracle: PhysicalLines = .{ .rest = input };
    while (oracle.next()) |physical| {
        if (isBlank(physical.line)) continue;

        var source: std.Io.Reader = .fixed(input[@intCast(physical.offset)..]);
        var reader: strand.Reader(Event) = .resumeAt(testing.allocator, &source, options, .{
            .offset = physical.offset,
            .lines_before = physical.number - 1,
        });
        defer reader.deinit();

        if (reader.next()) |maybe_line| {
            const line = maybe_line orelse return error.TestResumeEndedEarly;
            try testing.expectEqual(physical.number, line.number);
            try testing.expectEqual(physical.offset, line.offset);
            try testing.expectEqualStrings(physical.line, line.line);
        } else |err| switch (err) {
            // A line that is not a `T` is still that line, under its own
            // number and at its own offset.
            error.MalformedLine, error.ControlByte => {
                try testing.expectEqual(physical.number, reader.lines.fault.line);
                try testing.expectEqual(physical.offset, reader.lines.offset);
            },
            else => return err,
        }

        // And the rest of the stream keeps the oracle's numbering too.
        var rest: PhysicalLines = .{
            .rest = input[@intCast(physical.offset)..],
            .number = physical.number - 1,
            .offset = physical.offset,
        };
        // The line just read, skipped over: what follows is what is left.
        _ = rest.next();
        while (rest.next()) |after| {
            if (isBlank(after.line)) continue;
            if (reader.next()) |maybe_line| {
                const line = maybe_line orelse return error.TestResumeEndedEarly;
                try testing.expectEqual(after.number, line.number);
                try testing.expectEqual(after.offset, line.offset);
                try testing.expectEqualStrings(after.line, line.line);
            } else |err| switch (err) {
                error.MalformedLine, error.ControlByte => {
                    try testing.expectEqual(after.number, reader.lines.fault.line);
                    try testing.expectEqual(after.offset, reader.lines.offset);
                },
                else => return err,
            }
        }
        try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
        // Having read to the end from the middle, it has counted the whole
        // file: the lines behind it plus the lines it read.
        try testing.expectEqual(total, reader.lines.number);
    }
}

/// `kindOf` either declines, or points at a real key of a real object.
fn checkKindOf(line: []const u8) !void {
    const kind = strand.kindOf(line);
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
    const tag = strand.tagOf(Message, line);
    if (tag) |t| {
        const key = strand.kindOf(line) orelse return error.TestTagWithoutKey;
        try testing.expectEqualStrings(@tagName(t), key);
    }

    if (!isShallow(line)) return;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const value = strand.parseLine(Message, arena.allocator(), line, .{}) catch return;

    if (tag) |t| {
        try testing.expectEqual(std.meta.activeTag(value), t);
    } else {
        try testing.expect(std.mem.indexOfScalar(u8, line, '\\') != null);
    }
}

/// `lines` splits exactly the way the oracle does, and hands back views.
fn checkLines(input: []const u8) !void {
    // `lines` takes a byte-order mark off the front of the buffer, which the
    // oracle does not know about: it is not part of the first line, and it is
    // not where that line begins either.
    const bom = "\xEF\xBB\xBF";
    const marked = std.mem.startsWith(u8, input, bom);
    var oracle: PhysicalLines = .{
        .rest = if (marked) input[bom.len..] else input,
        .offset = if (marked) bom.len else 0,
    };
    var it = strand.lines(input);
    while (it.next()) |line| {
        const physical = oracle.next() orelse return error.TestExtraLine;
        try testing.expectEqual(physical.number, line.number);
        try testing.expectEqualStrings(physical.line, line.line);
        try testing.expectEqual(physical.offset, line.offset);
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
/// thousand `[` is a stack overflow in the oracle — never in `strand`, which
/// only ever hands the line to `std.json` as a whole.
fn isShallow(line: []const u8) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (line) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > 32) return false;
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return true;
}

test "the shallow guard ignores delimiters in strings and completed containers" {
    try testing.expect(isShallow("{\"text\":\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\"}"));
    try testing.expect(isShallow("{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}{}"));
    try testing.expect(!isShallow("[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[["));
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
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
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
    try testing.expect(reader.lines.number <= all.number);
}

/// A round trip through `.pretty`: what the writer indents over several lines,
/// the reader puts back together as one record, whatever the values held.
fn checkPrettyRoundTrip(events: []const Event) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: strand.Writer(Event) = .init(&out.writer, .{ .format = .pretty });
    try writer.writeAll(events);

    var source: std.Io.Reader = .fixed(out.written());
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{ .format = .pretty });
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
    try testing.expectEqual(@as(?strand.Line(Event), null), try reader.next());
}

/// The direct writer is byte-for-byte the standard-library stringifier with
/// strand's defaults, including escaping and omitted null optionals.
fn checkWriter(events: []const Event) !void {
    inline for (.{ false, true }) |escape_unicode| {
        var actual: std.Io.Writer.Allocating = .init(testing.allocator);
        defer actual.deinit();
        var writer: strand.Writer(Event) = .init(&actual.writer, .{ .escape_unicode = escape_unicode });
        try writer.writeAll(events);

        var expected: std.Io.Writer.Allocating = .init(testing.allocator);
        defer expected.deinit();
        for (events) |event| {
            try std.json.Stringify.value(event, .{
                .emit_null_optional_fields = false,
                .escape_unicode = escape_unicode,
            }, &expected.writer);
            try expected.writer.writeByte('\n');
        }
        try testing.expectEqualStrings(expected.written(), actual.written());
    }
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
        const old = try strand.payloadOf(struct { kind: []const u8 }, allocator, data);
        return .{ .kind = old.kind, .at = 0 };
    }
};

/// `Versioned` over any bytes: it either parses, or it fails with one of
/// `std.json`'s errors — never a panic and never a leak.
fn checkVersioned(line: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const record = strand.parseLine(
        strand.Versioned(Versioned2),
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
    try strand.writeLine(&out.writer, record);
    try testing.expect(std.mem.startsWith(u8, out.written(), "{\"v\":2,\"data\":"));

    var again: std.heap.ArenaAllocator = .init(testing.allocator);
    defer again.deinit();
    const round = try strand.parseLine(
        strand.Versioned(Versioned2),
        again.allocator(),
        out.written()[0 .. out.written().len - 1],
        .{},
    );
    try testing.expectEqual(@as(u32, 2), round.from);
    try testing.expectEqualStrings(record.value.kind, round.value.kind);
    try testing.expectEqual(record.value.at, round.value.at);
}

/// A record carrying values it does not read, and the same record typed the
/// way `std.json` would type it without this package, which is the oracle.
const Carrying = struct {
    kind: []const u8 = "",
    data: strand.Raw = .null,
    more: []const strand.Raw = &.{},
};

const CarryingValues = struct {
    kind: []const u8 = "",
    data: std.json.Value = .null,
    more: []const std.json.Value = &.{},
};

/// A value kept as its bytes is refused where `std.json` refuses the same
/// value as a `std.json.Value`, and anywhere else its bytes are that value:
/// the same value when they are parsed, a view into the line, with nothing
/// before or after them, and the same bytes when the record is written and
/// read again.
///
/// Both sides keep the last of a repeated key. A `Raw` checks that its value
/// is JSON and leaves a key repeated inside it to whoever parses it, so the
/// oracle is `std.json` with repeats allowed.
fn checkRaw(line: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A line on its own, as a `Raw`: the line less its outer whitespace.
    const oracle_value: ?std.json.Value = if (std.mem.endsWith(u8, line, "\n"))
        null
    else
        std.json.parseFromSliceLeaky(std.json.Value, a, line, .{ .duplicate_field_behavior = .use_last }) catch null;
    const alone: ?strand.Raw = strand.parseLine(strand.Raw, a, line, .{}) catch null;
    try testing.expectEqual(oracle_value == null, alone == null);
    if (alone) |raw| try testing.expectEqualStrings(std.mem.trim(u8, line, " \t\r\n"), raw.bytes);

    // Inside a record.
    const want: ?CarryingValues = if (std.mem.endsWith(u8, line, "\n"))
        null
    else
        std.json.parseFromSliceLeaky(CarryingValues, a, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_if_needed,
            .duplicate_field_behavior = .use_last,
        }) catch null;
    const got: ?Carrying = strand.parseLine(Carrying, a, line, .{ .duplicate_fields = .use_last }) catch null;
    try testing.expectEqual(want == null, got == null);
    const record = got orelse return;

    try checkRawValue(a, line, record.data, want.?.data);
    try testing.expectEqual(want.?.more.len, record.more.len);
    for (record.more, want.?.more) |raw, value| try checkRawValue(a, line, raw, value);

    // Written and read again, the values are the same bytes, but for the
    // line breaks a minified line cannot hold.
    var out: std.Io.Writer.Allocating = .init(a);
    try strand.writeLine(&out.writer, record);
    const again = try strand.parseLine(Carrying, a, out.written()[0 .. out.written().len - 1], .{ .duplicate_fields = .use_last });
    try expectSameRaw(record.data, again.data);
    try testing.expectEqual(record.more.len, again.more.len);
    for (record.more, again.more) |before, after| try expectSameRaw(before, after);
}

fn checkRawValue(a: std.mem.Allocator, line: []const u8, raw: strand.Raw, value: std.json.Value) !void {
    try testing.expect(inLineOrDefault(raw, line));
    try testing.expectEqualStrings(std.mem.trim(u8, raw.bytes, " \t\r\n"), raw.bytes);
    // The same value, compared as `std.json` writes it; the writer recurses,
    // so only over values shallow enough to write.
    if (!isShallow(raw.bytes)) return;
    const parsed = try raw.parse(std.json.Value, a, .{ .duplicate_fields = .use_last });
    try testing.expectEqualStrings(
        try std.json.Stringify.valueAlloc(a, value, .{}),
        try std.json.Stringify.valueAlloc(a, parsed, .{}),
    );
}

fn expectSameRaw(before: strand.Raw, after: strand.Raw) !void {
    try testing.expectEqual(before.bytes.len, after.bytes.len);
    for (before.bytes, after.bytes) |b, c| try testing.expectEqual(if (b == '\n' or b == '\r') ' ' else b, c);
}

/// A reader over lines that carry values reads the lines `parseLine` reads,
/// and every value it keeps is a view into the line it came from.
fn checkRawReader(input: []const u8) !void {
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Carrying) = .init(testing.allocator, &source, .{ .on_malformed = .skip });
    defer reader.deinit();
    while (try reader.next()) |line| {
        try testing.expect(inLineOrDefault(line.value.data, line.line));
        for (line.value.more) |raw| try testing.expect(inLineOrDefault(raw, line.line));
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const alone = try strand.parseLine(Carrying, arena.allocator(), line.line, .{});
        try testing.expectEqualStrings(alone.data.bytes, line.value.data.bytes);
        try testing.expectEqual(alone.more.len, line.value.more.len);
    }
}

/// A view into `line`, or the default, which is in no line at all.
fn inLineOrDefault(raw: strand.Raw, line: []const u8) bool {
    if (raw.bytes.ptr == strand.Raw.null.bytes.ptr) return true;
    return @intFromPtr(raw.bytes.ptr) >= @intFromPtr(line.ptr) and
        @intFromPtr(raw.bytes.ptr) + raw.bytes.len <= @intFromPtr(line.ptr) + line.len;
}

/// A separated stream is the same stream with one byte in front of every
/// record: what the writer marks, the reader finds, and what lies between two
/// records is dropped rather than read as one.
fn checkSeparated(events: []const Event, damage: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var writer: strand.Writer(Event) = .init(&out.writer, .{ .record_separator = true });
    try writer.writeAll(events);

    // Damage on the front of the stream, which is what a reader that joined
    // a log part-way through sees: not a record, and not a reason to lose
    // the records after it. A separator inside the damage would be a record
    // starting there, which is the one thing it must not claim to be.
    var torn: std.Io.Writer.Allocating = .init(testing.allocator);
    defer torn.deinit();
    for (damage) |byte| {
        try torn.writer.writeByte(if (byte == strand.separator) 'x' else byte);
    }
    try torn.writer.writeAll(out.written());

    var source: std.Io.Reader = .fixed(torn.written());
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, .{
        .record_separator = true,
        .on_malformed = .skip,
    });
    defer reader.deinit();

    for (events) |want| {
        const line = while (true) {
            const maybe = reader.next() catch |err| switch (err) {
                error.LineTooLong => continue,
                else => return err,
            };
            break maybe orelse return error.TestReaderEndedEarly;
        };
        try testing.expectEqualStrings(want.kind, line.value.kind);
        try testing.expectEqual(want.at, line.value.at);
        // The offset is the separator, and the line is what follows it.
        try testing.expectEqual(
            @as(u8, strand.separator),
            torn.written()[@intCast(line.offset)],
        );
    }
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
    const options: strand.Reader(Event).Options = .{
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
    var forward_offsets: std.ArrayList(u64) = .empty;
    defer {
        for (forward_lines.items) |item| testing.allocator.free(item);
        forward_lines.deinit(testing.allocator);
        forward_numbers.deinit(testing.allocator);
        forward_offsets.deinit(testing.allocator);
    }

    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Event) = .init(testing.allocator, &source, options);
    defer reader.deinit();
    while (true) {
        const line = reader.next() catch |err| switch (err) {
            error.LineTooLong => continue,
            else => return err,
        } orelse break;
        try forward_lines.append(testing.allocator, try testing.allocator.dupe(u8, line.line));
        try forward_numbers.append(testing.allocator, line.number);
        try forward_offsets.append(testing.allocator, line.offset);
    }
    const total = reader.lines.number;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = input });
    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);

    var buffer: [37]u8 = undefined;
    var file_reader = file.reader(testing.io, &buffer);
    var tail: strand.Tail(Event) = try .init(testing.allocator, &file_reader, .{
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
        // The two directions number lines differently and place them the
        // same: an offset is a fact about the file, not about the read.
        try testing.expectEqual(forward_offsets.items[i], line.offset);
        seen += 1;
    }
    try testing.expectEqual(forward_lines.items.len, seen);
}

/// A follower that reopens a path reads the file it holds to its end, then
/// the file that replaced it from its start — the same lines a plain reader
/// makes of each of the two, in that order, and numbered from 1 again after
/// the rotation.
///
/// The rotation is staged before the follower has read anything, so the
/// property is the ordering rule and not merely that a new file is noticed: a
/// follower that moved early would lose lines off the end of the old file,
/// and one that never moved would hang rather than fail.
fn checkRotation(a: []const u8, b: []const u8) !void {
    const options: strand.Reader(Event).Options = .{
        .on_malformed = .skip,
        // A follower's own reading policy: a final line the writer never
        // finished is not a line, on the abandoned file as on the live one.
        .require_terminator = true,
    };

    const Expected = struct { line: []const u8, number: u64 };
    var want: std.ArrayList(Expected) = .empty;
    defer {
        for (want.items) |item| testing.allocator.free(item.line);
        want.deinit(testing.allocator);
    }
    for ([_][]const u8{ a, b }) |bytes| {
        var source: std.Io.Reader = .fixed(bytes);
        var reader: strand.Reader(Event) = .init(testing.allocator, &source, options);
        defer reader.deinit();
        while (try reader.next()) |line| try want.append(testing.allocator, .{
            .line = try testing.allocator.dupe(u8, line.line),
            .number = line.number,
        });
    }

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = a });
    const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer file.close(testing.io);

    var buffer: [64]u8 = undefined;
    var source = file.reader(testing.io, &buffer);
    var path: strand.PathOpener = .{ .dir = tmp.dir, .sub_path = "log.jsonl" };
    var follower: strand.Follower(Event) = .init(testing.allocator, testing.io, &source, .{
        .reader = .{ .on_malformed = .skip },
        .wait = .{ .poll = .fromMicroseconds(50) },
        .reopen = path.opener(),
    });
    defer follower.deinit();

    // The name moves and a new file takes it, all before the first read.
    try tmp.dir.rename("log.jsonl", tmp.dir, "log.1", testing.io);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = b });

    // A follower with nothing to notice waits, and a wait does not end on
    // its own: if the system called these the same file, fail here instead.
    const replaced = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
    defer replaced.close(testing.io);
    try testing.expect((try replaced.stat(testing.io)).inode != (try file.stat(testing.io)).inode);

    for (want.items) |expected| {
        const line = try follower.next();
        try testing.expectEqualStrings(expected.line, line.line);
        try testing.expectEqual(expected.number, line.number);
    }
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

/// Writes generated lines carrying values into `buf` and returns what was
/// written: a record whose `data`, and sometimes whose `more`, is a value
/// that is nearly JSON, nested a few deep.
fn generateCarrying(smith: *std.testing.Smith, buf: []u8) []u8 {
    @disableInstrumentation();
    var end: usize = 0;
    while (end < buf.len and !smith.eos()) {
        append(buf, &end, "{\"kind\":\"k\",\"data\":");
        generateValue(smith, buf, &end, 3);
        if (smith.valueRangeAtMost(u8, 0, 1) == 0) {
            append(buf, &end, ",\"more\":[");
            generateValue(smith, buf, &end, 2);
            append(buf, &end, ",");
            generateValue(smith, buf, &end, 2);
            append(buf, &end, "]");
        }
        append(buf, &end, "}");
        switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => append(buf, &end, "\n"),
            1 => append(buf, &end, "\r\n"),
            else => {},
        }
    }
    return buf[0..end];
}

/// One value, most of the time: the scalars, containers of more of them,
/// whitespace where JSON allows it and where it does not, the ways a value
/// goes wrong, and bytes with no intentions at all.
fn generateValue(smith: *std.testing.Smith, buf: []u8, end: *usize, depth: u8) void {
    @disableInstrumentation();
    switch (smith.valueRangeAtMost(u8, 0, 10)) {
        0 => append(buf, end, "null"),
        1 => append(buf, end, "true"),
        2 => append(buf, end, "-12.50e+3"),
        3 => append(buf, end, "\"t\\u00e9xt\\n\u{1f600}\""),
        4 => append(buf, end, " { }\t"),
        5 => if (depth == 0) append(buf, end, "{}") else {
            append(buf, end, "{\"a\" : ");
            generateValue(smith, buf, end, depth - 1);
            append(buf, end, ", \"b\":");
            generateValue(smith, buf, end, depth - 1);
            append(buf, end, "}");
        },
        6 => if (depth == 0) append(buf, end, "[]") else {
            append(buf, end, "[ ");
            generateValue(smith, buf, end, depth - 1);
            append(buf, end, ",");
            generateValue(smith, buf, end, depth - 1);
            append(buf, end, " ]");
        },
        7 => {
            const broken: []const []const u8 = &.{ "[1,", "{\"a\"", "tru", "01", "\"\\q\"", "\"\xff\"", "}", "", "1 2", "\"\\ud800\"" };
            append(buf, end, broken[smith.valueRangeAtMost(u8, 0, broken.len - 1)]);
        },
        8 => append(buf, end, "  \r "),
        else => {
            var chunk: [8]u8 = undefined;
            append(buf, end, chunk[0..smith.slice(&chunk)]);
        },
    }
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

/// Seeds, from `src/corpus/lines`. Their bytes drive the generator rather than
/// being the input, so they are there to give a campaign somewhere to start
/// and to give `zig build test` a handful of runs that are not the empty one.
///
/// They are files rather than string literals so that an input a campaign
/// found can be kept: write the bytes into `src/corpus/lines` under a name that
/// says what they are, add the line here, and every later run starts from it
/// too.
const corpus: []const []const u8 = &.{
    @embedFile("corpus/lines/plain.jsonl"),
    @embedFile("corpus/lines/control-bytes.jsonl"),
    @embedFile("corpus/lines/not-utf8.jsonl"),
    @embedFile("corpus/lines/empty-objects.jsonl"),
    @embedFile("corpus/lines/escapes.jsonl"),
    @embedFile("corpus/lines/byte-order-mark.jsonl"),
};

/// Seeds for the versioned property, from `src/corpus/versioned`.
const versioned_corpus: []const []const u8 = &.{
    @embedFile("corpus/versioned/current.jsonl"),
    @embedFile("corpus/versioned/older-and-unknown.jsonl"),
    @embedFile("corpus/versioned/damaged.jsonl"),
};

test "fuzz: Reader.next over generated lines" {
    try std.testing.fuzz({}, fuzzReader, .{ .corpus = corpus });
}

test "fuzz: strand scanner agrees with std.json" {
    try std.testing.fuzz({}, fuzzScanner, .{ .corpus = corpus });
}

fn fuzzScanner(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [2048]u8 = undefined;
    const input = generate(smith, &buf);
    try checkScanner(input);
    var it: PhysicalLines = .{ .rest = input };
    while (it.next()) |line| try checkScanner(line.line);
}

test "fuzz: LineReader over generated lines" {
    try std.testing.fuzz({}, fuzzLineReader, .{ .corpus = corpus });
}

fn fuzzLineReader(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [2048]u8 = undefined;
    const input = generate(smith, &buf);
    // A bound the input can reach, so that a refusal and the lines read
    // after it are part of the property, and one it cannot.
    try checkLineReader(input, smith.valueRangeAtMost(u32, 1, 128));
    try checkLineReader(input, buf.len + 1);
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

test "fuzz: a resumed Reader over generated lines" {
    try std.testing.fuzz({}, fuzzResume, .{ .corpus = corpus });
}

fn fuzzResume(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    try checkResume(generate(smith, &buf));
}

test "fuzz: kindOf over generated lines" {
    try std.testing.fuzz({}, fuzzKindOf, .{ .corpus = corpus });
}

fn fuzzKindOf(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    var it = strand.lines(generate(smith, &buf));
    while (it.next()) |line| try checkKindOf(line.line);
}

test "fuzz: tagOf over generated lines" {
    try std.testing.fuzz({}, fuzzTagOf, .{ .corpus = corpus });
}

fn fuzzTagOf(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [512]u8 = undefined;
    var it = strand.lines(generate(smith, &buf));
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

test "fuzz: typed writer agrees with std.json" {
    try std.testing.fuzz({}, fuzzWriter, .{ .corpus = corpus });
}

fn fuzzWriter(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var text: [512]u8 = undefined;
    var events: [16]Event = undefined;
    try checkWriter(generateEvents(smith, &events, &text));
}

fn fuzzPrettyRoundTrip(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var text: [512]u8 = undefined;
    var events: [16]Event = undefined;
    try checkPrettyRoundTrip(generateEvents(smith, &events, &text));
}

test "fuzz: a separated stream over generated values" {
    try std.testing.fuzz({}, fuzzSeparated, .{ .corpus = corpus });
}

fn fuzzSeparated(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var text: [512]u8 = undefined;
    var events: [16]Event = undefined;
    var damage: [64]u8 = undefined;
    const made = generateEvents(smith, &events, &text);
    try checkSeparated(made, damage[0..smith.slice(&damage)]);
}

test "fuzz: a follower over a file replaced under it" {
    try std.testing.fuzz({}, fuzzRotation, .{ .corpus = corpus });
}

fn fuzzRotation(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var before: [256]u8 = undefined;
    var after: [256]u8 = undefined;
    const a = generate(smith, &before);
    const b = generate(smith, &after);
    try checkRotation(a, b);
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
    var it = strand.lines(generateVersioned(smith, &buf));
    while (it.next()) |line| try checkVersioned(line.line);
}

test "fuzz: raw values over generated lines" {
    try std.testing.fuzz({}, fuzzRaw, .{ .corpus = corpus });
}

fn fuzzRaw(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    var buf: [1024]u8 = undefined;
    const input = generateCarrying(smith, &buf);
    try checkRawReader(input);
    var it: PhysicalLines = .{ .rest = input };
    while (it.next()) |line| try checkRaw(line.line);
}

//=========================================================================
// The campaign: every property over generated inputs, driven by a seed.
//
// `zig build test --fuzz` runs the properties under the compiler's fuzzer,
// which steers the next input by the coverage the last one reached and runs
// until it is stopped. That is the mode to leave running; it is not a mode a
// build can wait on. A `std.testing.Smith` can be driven from any bytes at
// all, so the same properties take bytes from a seeded generator here: no
// coverage to steer it, and a run that ends.
//
// `-Dcampaign=N` is how many rounds, `-Dseed=N` is which ones. A round that
// fails prints both, and a run with those two numbers is that round again.
//=========================================================================

const build_options = @import("build_options");

/// Bytes shaped the way a `std.testing.Smith` reads them.
///
/// It takes one byte to decide whether a sequence has ended — anything but
/// zero ends it — and eight little-endian bytes for a value, which it throws
/// away and replaces with the bottom of the range unless it is inside it. A
/// stream of uniform random bytes therefore ends at once and chooses nothing,
/// and mostly zeros with small values among them is what drives it through
/// its choices instead.
fn seedBytes(random: std.Random, out: []u8) void {
    for (out) |*byte| byte.* = switch (random.uintLessThan(u8, 10)) {
        0...7 => 0,
        8 => random.uintLessThan(u8, 7),
        else => random.int(u8),
    };
}

/// Every property, over one generated input.
fn oneRound(bytes: []const u8) !void {
    inline for (.{
        fuzzLineReader,
        fuzzReader,
        fuzzScanner,
        fuzzResume,
        fuzzKindOf,
        fuzzTagOf,
        fuzzLines,
        fuzzPretty,
        fuzzPrettyRoundTrip,
        fuzzWriter,
        fuzzSeparated,
        fuzzRotation,
        fuzzTail,
        fuzzVersioned,
        fuzzRaw,
    }) |property| {
        var smith: std.testing.Smith = .{ .in = bytes };
        try property({}, &smith);
    }
}

test "the properties hold over generated inputs" {
    // The corpus first, through every property rather than only the ones
    // that name it, and then as much generated input as the build asked for.
    for (corpus) |seed| try oneRound(seed);
    for (versioned_corpus) |seed| try oneRound(seed);

    var prng: std.Random.DefaultPrng = .init(build_options.seed);
    var bytes: [1024]u8 = undefined;
    for (0..build_options.campaign) |i| {
        const len = prng.random().intRangeAtMost(usize, 1, bytes.len);
        seedBytes(prng.random(), bytes[0..len]);
        oneRound(bytes[0..len]) catch |err| {
            std.debug.print(
                "round {d} of seed 0x{x} failed: rerun with -Dseed=0x{x} -Dcampaign={d}\n",
                .{ i, build_options.seed, build_options.seed, i + 1 },
            );
            return err;
        };
    }
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
    "\xEF\xBB\xBF{\"kind\":\"open\"}\n",
    "\xEF\xBB\xBF",
    "\xEF\xBB",
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
        try checkScanner(input);
        try checkLines(input);
        try checkReaderFail(input, 1 << 20);
        try checkReaderFail(input, 8);
        try checkReaderFail(input, 1);
        try checkReaderSkip(input);
        try checkLineReader(input, 1 << 20);
        try checkLineReader(input, 8);
        try checkLineReader(input, 1);
        try checkResume(input);

        try checkPretty(input);
        try checkTail(input);

        var it = strand.lines(input);
        while (it.next()) |line| {
            try checkKindOf(line.line);
            try checkTagOf(line.line);
            try checkVersioned(line.line);
            try checkRaw(line.line);
        }
        try checkRawReader(input);
    }

    // Rotation takes two files, so the table is walked in pairs: every input
    // is followed once as the file that was replaced and once as the one
    // that replaced it.
    for (table, 0..) |before, i| try checkRotation(before, table[(i + 1) % table.len]);

    for (versioned_table) |line| try checkVersioned(line);
    for (raw_table) |line| try checkRaw(line);
    try checkSeparated(&.{}, "");
    try checkSeparated(&.{
        .{ .kind = "plain", .at = 1 },
        .{ .kind = "with \"quotes\" and a\nbreak", .at = 2, .level = .warn },
    }, "half a record\n\x1e{\"kind\":\n");
    try checkPrettyRoundTrip(&.{});
    try checkPrettyRoundTrip(&.{
        .{ .kind = "plain", .at = 1 },
        .{ .kind = "with \"quotes\" and a\nbreak", .at = 2, .level = .warn, .note = "x" },
        .{ .kind = "", .at = std.math.maxInt(u64), .tags = &.{ "a", "b" } },
    });
    try checkWriter(&.{});
    try checkWriter(&.{
        .{ .kind = "plain", .at = 1 },
        .{ .kind = "quote \" slash \\ newline\n", .at = std.math.maxInt(u64), .note = "\u{1f600}" },
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

/// Values chosen by hand, inside a record and on their own.
const raw_table: []const []const u8 = &.{
    "{\"data\":{}}",
    "{\"data\": [ ] ,\"more\":[ null , 0 ]}",
    "{\"data\":\"\\u0000\"}",
    "{\"data\":\"\\ud83d\\ude00\"}",
    "{\"data\":\"\\ud83d\"}",
    "{\"data\":1e400}",
    "{\"data\":-0}",
    "{\"data\":[1,[2,[3,[4]]]]}",
    "{\"data\":{\"a\":1,\"a\":2}}",
    "{\"data\":{\"a\"\r:\r1}}",
    "{\"data\":1,\"data\":2}",
    "{\"data\":}",
    "{\"data\"}",
    "{\"more\":[,]}",
    "{\"more\":{}}",
    " [\"x\"] ",
    "\t{\"k\":true}\r",
    "\"",
    "tru",
    "[1]]",
};
