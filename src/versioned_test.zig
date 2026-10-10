//! versioned scenarios through the public API.
const std = @import("std");
const strand = @import("strand.zig");
const json = strand.json;
const jsonl = strand.jsonl;
const Versioned = jsonl.Versioned;
const testing = std.testing;

/// `value` as one line: its JSON, then a newline.
fn writeLine(out: *std.Io.Writer, value: anytype) !void {
    try json.write(out, value, .{});
    try out.writeByte('\n');
}

/// Version 1: one string field, and a count that was a string.
const EventV1 = struct {
    kind: []const u8,
    count: []const u8 = "0",
};

/// Version 2: the count became a number, and `kind` gained a namespace.
pub const Event = struct {
    scope: []const u8 = "app",
    kind: []const u8,
    count: u32 = 0,

    pub const jsonl_version: u32 = 2;

    /// Lines older than version 2, brought forward.
    ///
    /// Version 1 wrote the count as a string and had no scope; a line with no
    /// `v` at all predates the envelope and is version 1 too.
    pub fn jsonlMigrate(from: u32, payload: anytype) @TypeOf(payload.*).Error!Event {
        switch (from) {
            0, 1 => {
                const old = try payload.read(EventV1);
                return .{
                    .scope = "app",
                    .kind = old.kind,
                    .count = std.fmt.parseInt(u32, old.count, 10) catch return payload.reject(1),
                };
            },
            // A line from a build newer than this one.
            else => return error.UnknownVariant,
        }
    }
};

/// A record with integers wide enough to hold numbers written in exponent form.
pub const Wide = struct {
    id: u128,
    count: u64 = 0,

    pub const jsonl_version: u32 = 2;

    pub fn jsonlMigrate(from: u32, payload: anytype) @TypeOf(payload.*).Error!Wide {
        if (from != 1) return error.UnknownVariant;
        const old = try payload.read(struct { id: u128, count: u64 = 0 });
        return .{ .id = old.id, .count = old.count };
    }
};

test "a number past its integer's range is refused, never a panic" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Parsed straight into `T`, `v` first: read here, as the number it is.
    const straight = try json.parseLeaky(Versioned(Wide), a, "{\"v\":2,\"data\":{\"id\":1.8e38}}", .{});
    try testing.expectEqual(@as(u128, 180_000_000_000_000_000_000_000_000_000_000_000_000), straight.value.id);
    try testing.expectError(error.NumberOutOfRange, json.parseLeaky(Versioned(Wide), a, "{\"v\":2,\"data\":{\"id\":3.402823669209384634633746074317682114555e38}}", .{}));

    // Held until `v` is known and read where it lies, and migrated through
    // the hook: 2^64 is a `u64`'s largest value rounded up.
    for ([_][]const u8{
        "{\"data\":{\"id\":1,\"count\":1.8446744073709552e19},\"v\":2}",
        "{\"v\":1,\"data\":{\"id\":1,\"count\":1.8446744073709552e19}}",
    }) |line| {
        try testing.expectError(error.NumberOutOfRange, json.parseLeaky(Versioned(Wide), a, line, .{}));
    }
    // A number written as a string is a string.
    try testing.expectError(error.UnexpectedType, json.parseLeaky(Versioned(Wide), a, "{\"v\":1,\"data\":{\"id\":\"2e38\"}}", .{}));
    const migrated = try json.parseLeaky(Versioned(Wide), a, "{\"v\":1,\"data\":{\"id\":7,\"count\":1.5e3}}", .{});
    try testing.expectEqual(Wide{ .id = 7, .count = 1500 }, migrated.value);
}

test "a line of the current version is parsed straight into T" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const line = "{\"v\":2,\"data\":{\"scope\":\"net\",\"kind\":\"open\",\"count\":3}}";
    const record = try json.parseLeaky(Versioned(Event), arena.allocator(), line, .{});

    try testing.expectEqual(@as(u32, 2), record.from);
    try testing.expect(!record.migrated());
    try testing.expectEqualStrings("net", record.value.scope);
    try testing.expectEqual(@as(u32, 3), record.value.count);
    // `v` before `data` is the fast path, and the fast path still borrows.
    try testing.expect(@intFromPtr(record.value.kind.ptr) >= @intFromPtr(line.ptr));
    try testing.expect(@intFromPtr(record.value.kind.ptr) < @intFromPtr(line.ptr) + line.len);
}

test "an older line goes through the migrate hook" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const record = try json.parseLeaky(
        Versioned(Event),
        arena.allocator(),
        "{\"v\":1,\"data\":{\"kind\":\"open\",\"count\":\"7\"}}",
        .{},
    );
    try testing.expectEqual(@as(u32, 1), record.from);
    try testing.expect(record.migrated());
    try testing.expectEqualStrings("app", record.value.scope);
    try testing.expectEqualStrings("open", record.value.kind);
    try testing.expectEqual(@as(u32, 7), record.value.count);
}

test "a line with no version at all is the unstamped one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const record = try json.parseLeaky(
        Versioned(Event),
        arena.allocator(),
        "{\"data\":{\"kind\":\"open\",\"count\":\"2\"}}",
        .{},
    );
    try testing.expectEqual(@as(u32, 0), record.from);
    try testing.expectEqual(@as(u32, 2), record.value.count);

    // And a type that says its unstamped lines were version 1 sees 1.
    const Stamped = struct {
        pub const Self = @This();
        kind: []const u8,
        pub const jsonl_version: u32 = 2;
        pub const jsonl_version_unstamped: u32 = 1;
        pub fn jsonlMigrate(from: u32, payload: anytype) @TypeOf(payload.*).Error!Self {
            if (from != 1) return error.UnknownVariant;
            return .{ .kind = "migrated" };
        }
    };
    const stamped = try json.parseLeaky(
        Versioned(Stamped),
        arena.allocator(),
        "{\"data\":{\"kind\":\"open\"}}",
        .{},
    );
    try testing.expectEqual(@as(u32, 1), stamped.from);
    try testing.expectEqualStrings("migrated", stamped.value.kind);
}

test "the envelope's keys may arrive in either order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{
        "{\"v\":1,\"data\":{\"kind\":\"open\",\"count\":\"5\"}}",
        "{\"data\":{\"kind\":\"open\",\"count\":\"5\"},\"v\":1}",
    }) |line| {
        const record = try json.parseLeaky(Versioned(Event), arena.allocator(), line, .{});
        try testing.expectEqual(@as(u32, 5), record.value.count);
        try testing.expectEqualStrings("open", record.value.kind);
    }
}

test "a repeated envelope key and a key of no envelope are refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{\"v\":1,\"v\":2,\"data\":{\"kind\":\"old\",\"count\":\"4\"}}",
        "{\"v\":2,\"data\":{\"kind\":\"first\",\"count\":1},\"data\":{\"kind\":\"last\",\"count\":2}}",
        "{\"data\":{\"kind\":\"first\",\"count\":1},\"data\":{\"kind\":\"last\",\"count\":2},\"v\":2}",
    }) |line| {
        try testing.expectError(error.DuplicateField, json.parseLeaky(Versioned(Event), arena.allocator(), line, .{}));
    }
    try testing.expectError(error.UnknownField, json.parseLeaky(Versioned(Event), arena.allocator(), "{\"v\":2,\"at\":1,\"data\":{\"kind\":\"x\"}}", .{}));
}

test "a version from the future is a malformed line, by number" {
    const input =
        \\{"v":2,"data":{"kind":"known"}}
        \\{"v":99,"data":{"kind":"unknowable"}}
        \\{"v":2,"data":{"kind":"known again"}}
        \\
    ;
    var source: std.Io.Reader = .fixed(input);
    var reader: jsonl.Reader(Versioned(Event)) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    try testing.expectEqualStrings("known", (try reader.next()).?.value.value.kind);
    try testing.expectError(error.MalformedLine, reader.next());
    try testing.expectEqual(@as(u64, 2), reader.lines.fault.line);
    try testing.expectEqual(error.UnknownVariant, reader.lines.fault.err.?);
    try testing.expectEqualStrings("known again", (try reader.next()).?.value.value.kind);
}

test "a hook refuses a payload with a code of its own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diagnostics: strand.core.Diagnostics = .{};
    try testing.expectError(error.CustomRejected, json.parseLeaky(
        Versioned(Event),
        arena.allocator(),
        "{\"v\":1,\"data\":{\"kind\":\"open\",\"count\":\"seven\"}}",
        .{ .diagnostics = &diagnostics },
    ));
    try testing.expectEqual(@as(?u32, 1), diagnostics.custom_code);
}

test "a missing data member is a missing field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.MissingField, json.parseLeaky(
        Versioned(Event),
        arena.allocator(),
        "{\"v\":2}",
        .{},
    ));
}

test "round trip: what is written under the envelope is read back under it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    var log: jsonl.Writer(Versioned(Event)) = .init(&out.writer, .{});
    try log.writeAll(&.{
        .{ .value = .{ .kind = "open", .count = 1 } },
        .{ .value = .{ .scope = "net", .kind = "close", .count = 2 } },
    });
    try testing.expectEqualStrings(
        \\{"v":2,"data":{"scope":"app","kind":"open","count":1}}
        \\{"v":2,"data":{"scope":"net","kind":"close","count":2}}
        \\
    , out.written());

    var source: std.Io.Reader = .fixed(out.written());
    var reader: jsonl.Reader(Versioned(Event)) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    try testing.expectEqual(@as(u32, 1), (try reader.next()).?.value.value.count);
    try testing.expectEqualStrings("net", (try reader.next()).?.value.value.scope);
    try testing.expectEqual(@as(?jsonl.Line(Versioned(Event)), null), try reader.next());
}

test "payload fields v and data belong to the payload, not the envelope" {
    const Payload = struct {
        v: u32,
        data: []const u8,
        pub const jsonl_version: u32 = 2;
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeLine(&out.writer, Versioned(Payload){ .value = .{ .v = 12, .data = "kept" } });
    try testing.expectEqualStrings("{\"v\":2,\"data\":{\"v\":12,\"data\":\"kept\"}}\n", out.written());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{\"v\":2,\"data\":{\"v\":12,\"data\":\"kept\"}}",
        "{\"data\":{\"v\":12,\"data\":\"kept\"},\"v\":2}",
    }) |line| {
        const record = try json.parseLeaky(Versioned(Payload), arena.allocator(), line, .{});
        try testing.expectEqual(@as(u32, 2), record.from);
        try testing.expectEqual(@as(u32, 12), record.value.v);
        try testing.expectEqualStrings("kept", record.value.data);
        try testing.expect(!record.migrated());
    }
}

test "a migrated record is written back in today's shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const record = try json.parseLeaky(
        Versioned(Event),
        arena.allocator(),
        "{\"v\":1,\"data\":{\"kind\":\"open\",\"count\":\"9\"}}",
        .{},
    );

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeLine(&out.writer, record);
    try testing.expectEqualStrings(
        "{\"v\":2,\"data\":{\"scope\":\"app\",\"kind\":\"open\",\"count\":9}}\n",
        out.written(),
    );
}

//=========================================================================
// The composition the documents claim: an envelope is an ordinary type, so
// every reader in the package reads one without being told about it.
//=========================================================================

const fixtures = @import("testing/fixtures.zig");

/// A log with one line of the old shape on it and two of the new, which is
/// what a file written across a version change looks like.
const mixed_log =
    "{\"v\":1,\"data\":{\"kind\":\"open\",\"count\":\"1\"}}\n" ++
    "{\"v\":2,\"data\":{\"scope\":\"net\",\"kind\":\"retry\",\"count\":2}}\n" ++
    "{\"v\":2,\"data\":{\"scope\":\"app\",\"kind\":\"close\",\"count\":3}}\n";

test "a versioned log read backwards is migrated the same way" {
    var fixture = try fixtures.Fixture.init(mixed_log, 64);
    defer fixture.deinit();

    // One line per block, so that the backwards read really does go back to
    // the file for each of them.
    var tail: jsonl.Tail(Versioned(Event)) = try .init(testing.allocator, &fixture.reader, .{
        .block_bytes = 16,
    });
    defer tail.deinit();

    const last = (try tail.prev()).?;
    try testing.expectEqualStrings("close", last.value.value.kind);
    try testing.expect(!last.value.migrated());

    const middle = (try tail.prev()).?;
    try testing.expectEqualStrings("net", middle.value.value.scope);

    // The oldest line is the one the hook has work to do on, and reading
    // backwards changes nothing about that.
    const first = (try tail.prev()).?;
    try testing.expectEqual(@as(u32, 1), first.value.from);
    try testing.expect(first.value.migrated());
    try testing.expectEqualStrings("open", first.value.value.kind);
    try testing.expectEqualStrings("app", first.value.value.scope);
    try testing.expectEqual(@as(u32, 1), first.value.value.count);
    try testing.expectEqual(@as(?jsonl.Line(Versioned(Event)), null), try tail.prev());
}

test "a versioned log followed as it grows is migrated the same way" {
    var fixture = try fixtures.Fixture.init(mixed_log, 512);
    defer fixture.deinit();

    var follower: jsonl.Follower(Versioned(Event)) = .init(
        testing.allocator,
        &fixture.reader,
        .{ .wait = .{ .poll = .fromMicroseconds(100) } },
    );
    defer follower.deinit(testing.io);

    const first = try follower.next(testing.io);
    try testing.expect(first.value.migrated());
    try testing.expectEqual(@as(u32, 1), first.value.value.count);
    try testing.expectEqualStrings("retry", (try follower.next(testing.io)).value.value.kind);
    try testing.expectEqualStrings("close", (try follower.next(testing.io)).value.value.kind);

    // And a line of the old shape appended while the follower is running
    // goes through the hook like any other.
    try fixture.write_file.writePositionalAll(
        testing.io,
        "{\"v\":1,\"data\":{\"kind\":\"late\",\"count\":\"4\"}}\n",
        mixed_log.len,
    );
    const late = try follower.next(testing.io);
    try testing.expect(late.value.migrated());
    try testing.expectEqualStrings("late", late.value.value.kind);
    try testing.expectEqual(@as(u32, 4), late.value.value.count);
    try testing.expectEqual(@as(u64, 4), late.number);
}

/// 48 bytes of vector: the size Zig 0.17.0 on aarch64 miscompiles inside an
/// optional, which an envelope must not turn into a missing payload.
const Wide48 = struct {
    item: struct { note: ?@Vector(3, u128) },

    pub const jsonl_version: u32 = 1;
};

test "a payload holding a 48-byte vector comes back whole from the envelope" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const note: [3]u128 = .{ 1, 2, 3 };
    const data = "{\"item\":{\"note\":[1,2,3]}}";
    for ([_][]const u8{
        "{\"v\":1,\"data\":" ++ data ++ "}",
        "{\"data\":" ++ data ++ ",\"v\":1}",
    }) |line| {
        const result = try json.parseLeaky(Versioned(Wide48), a, line, .{});
        try testing.expectEqual(note, @as([3]u128, result.value.item.note orelse return error.TestUnexpectedResult));
    }
}
