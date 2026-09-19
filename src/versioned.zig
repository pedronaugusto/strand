//! Schema evolution: a record that says which shape it is in, and a hook that
//! brings an older one forward.
//!
//! A log outlives the program that wrote it. The third field added to an
//! event is easy — a reader that defaults its missing fields already copes —
//! but the day a field changes meaning, or splits in two, or moves, the
//! defaults stop being enough and the line has to say which shape it is. The
//! shape here is the one the ecosystem already uses:
//!
//! ```
//! {"v":2,"data":{"kind":"open","path":"/tmp"}}
//! ```
//!
//! `v` first, `data` second, and everything the record actually holds inside
//! `data`, so that the envelope can never collide with the record. A reader
//! that meets `"v":1` hands the payload to the type's own `jsonlMigrate`,
//! which returns the record in today's shape; a reader that meets today's
//! version parses straight into `T` with the borrow rule intact.
//!
//! `Versioned(T)` is an ordinary `std.json` type — it has `jsonParse` and
//! `jsonStringify` — so it composes with everything else here:
//! `Reader(Versioned(Event))`, `Writer(Versioned(Event))`,
//! `Tail(Versioned(Event))`, `Follower(Versioned(Event))`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The envelope's two keys. Short, because they are on every line.
const version_key = "v";
const data_key = "data";

/// `T` with its schema version on the outside.
///
/// `T` must declare:
///
/// * `pub const jsonl_version: u32` — the version this build writes. Start at
///   1 and add one whenever a reader of the old shape would get the new one
///   wrong.
///
/// `T` may declare:
///
/// * `pub fn jsonlMigrate(allocator: Allocator, from: u32, data: std.json.Value)
///   std.json.ParseFromValueError!T` — how to read a version that is not this
///   one. `payloadOf` is the usual first line of it: parse `data` as the old
///   shape, then build today's out of it. A version the hook does not know is
///   for the hook to refuse, or to represent — see "Arms added over time" in
///   README.md.
/// * `pub const jsonl_version_unstamped: u32` — what a line with no `v` on it
///   is taken to be. Defaults to 0, which no `jsonl_version` should ever be,
///   so an unstamped line reaches `jsonlMigrate` as `from = 0` and is
///   recognisable there. A log that was written before versioning existed
///   sets this to the version that log was.
///
/// A `T` with a field named `v` is a compile error: an envelope key and a
/// record field of the same name means the author has confused the two, and
/// the confusion is quiet — the field would be written inside `data`, where
/// it is ignored by everything that reads the version.
pub fn Versioned(comptime T: type) type {
    comptime checkShape(T);
    return struct {
        /// The record, in the shape this build understands. A line from an
        /// older version has already been through `T.jsonlMigrate` by the
        /// time it is here.
        value: T,
        /// The version the line was stamped with, before any migration —
        /// `current` for a line this build wrote, `unstamped` for a line with
        /// no `v` on it. Defaults to `current` so that a value being written
        /// need not mention it.
        from: u32 = current,

        const Self = @This();

        /// The version this build writes, from `T.jsonl_version`.
        pub const current: u32 = T.jsonl_version;

        /// The version a line with no `v` is taken to be. See
        /// `T.jsonl_version_unstamped`.
        pub const unstamped: u32 = if (@hasDecl(T, "jsonl_version_unstamped"))
            T.jsonl_version_unstamped
        else
            0;

        /// True when this record reached its current shape through
        /// `T.jsonlMigrate` rather than by being written in it.
        pub fn migrated(self: Self) bool {
            return self.from != current;
        }

        /// Reads the envelope. Called by `std.json`; see `Reader`.
        ///
        /// The two keys are read in whatever order the line puts them, but
        /// `v` before `data` — the order this package writes — is the order
        /// that costs nothing: the version is known by the time `data` is
        /// reached, so the payload is parsed straight into `T` and its
        /// strings still borrow from the line. A line that puts `data` first
        /// is held as a `std.json.Value` until `v` turns up, which allocates
        /// and copies; it is read correctly either way.
        ///
        /// `error.UnknownField` is what a version this build cannot read
        /// comes back as, when `T` declares no `jsonlMigrate` or the line
        /// carries a key that is neither `v` nor `data` under
        /// `ignore_unknown_fields = false`. Through a `Reader` that is
        /// `error.MalformedLine`, with the line number on the reader.
        pub fn jsonParse(
            allocator: Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!Self {
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            var from: ?u32 = null;
            var parsed: ?T = null;
            var stashed: ?std.json.Value = null;

            while (true) {
                const key = switch (try source.nextAllocMax(
                    allocator,
                    .alloc_if_needed,
                    options.max_value_len.?,
                )) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => break,
                    else => return error.UnexpectedToken,
                };

                if (std.mem.eql(u8, key, version_key)) {
                    if (from != null) return error.DuplicateField;
                    from = try std.json.innerParse(u32, allocator, source, options);
                } else if (std.mem.eql(u8, key, data_key)) {
                    if (parsed != null or stashed != null) return error.DuplicateField;
                    if (from != null and from.? == current) {
                        parsed = try std.json.innerParse(T, allocator, source, options);
                    } else {
                        stashed = try std.json.innerParse(std.json.Value, allocator, source, options);
                    }
                } else if (options.ignore_unknown_fields) {
                    try source.skipValue();
                } else {
                    return error.UnknownField;
                }
            }

            const version = from orelse unstamped;
            if (parsed) |value| return .{ .value = value, .from = version };
            const data = stashed orelse return error.MissingField;
            if (version == current) {
                return .{
                    .value = try std.json.parseFromValueLeaky(T, allocator, data, options),
                    .from = version,
                };
            }
            if (!@hasDecl(T, "jsonlMigrate")) return error.UnknownField;
            return .{ .value = try T.jsonlMigrate(allocator, version, data), .from = version };
        }

        /// Writes the envelope. Called by `std.json`; see `Writer`.
        ///
        /// Always stamps `current`, never `from`: `value` is in today's shape
        /// whatever shape the line it came from was in, so writing it back
        /// under an older version would be a lie about its contents.
        pub fn jsonStringify(self: Self, jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField(version_key);
            try jw.write(current);
            try jw.objectField(data_key);
            try jw.write(self.value);
            try jw.endObject();
        }
    };
}

/// `data` parsed as an older shape, for use inside a `jsonlMigrate` hook.
///
/// Ownership: `std.json`'s leaky contract — allocations land on `allocator`,
/// which in a hook is the arena the line is being parsed on, and the result
/// lives exactly as long as the rest of the line's value does.
pub fn payloadOf(
    comptime Old: type,
    allocator: Allocator,
    data: std.json.Value,
) std.json.ParseFromValueError!Old {
    return std.json.parseFromValueLeaky(Old, allocator, data, .{ .ignore_unknown_fields = true });
}

/// What `Versioned` requires of `T`, checked where the mistake is made.
fn checkShape(comptime T: type) void {
    const name = @typeName(T);
    if (!@hasDecl(T, "jsonl_version")) {
        @compileError("strand.Versioned(" ++ name ++ ") needs `pub const jsonl_version: u32` on " ++ name);
    }
    if (@TypeOf(T.jsonl_version) != u32 and @TypeOf(T.jsonl_version) != comptime_int) {
        @compileError(name ++ ".jsonl_version must be a u32");
    }
    if (T.jsonl_version == 0) {
        @compileError(name ++ ".jsonl_version must not be 0: 0 is what a line with no version is");
    }
    const info = @typeInfo(T);
    if (info == .@"struct") {
        for (info.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, version_key)) {
                @compileError("strand.Versioned(" ++ name ++ "): " ++ name ++ " has a field named `" ++
                    version_key ++ "`, which is the envelope's own key. The record goes inside `" ++
                    data_key ++ "`, so the field would never be read as the version; rename one of them.");
            }
        }
    }
}

//=========================================================================
// Tests. The scenario is one type through three versions, which is the only
// way to show that a migration is a migration.
//=========================================================================

const testing = std.testing;
const strand = @import("strand.zig");

/// Version 1: one string field, and a count that was a string.
const EventV1 = struct {
    kind: []const u8,
    count: []const u8 = "0",
};

/// Version 2: the count became a number, and `kind` gained a namespace.
const Event = struct {
    scope: []const u8 = "app",
    kind: []const u8,
    count: u32 = 0,

    pub const jsonl_version: u32 = 2;

    /// Lines older than version 2, brought forward.
    ///
    /// Version 1 wrote the count as a string and had no scope; a line with no
    /// `v` at all predates the envelope and is version 1 too.
    pub fn jsonlMigrate(
        allocator: Allocator,
        from: u32,
        data: std.json.Value,
    ) std.json.ParseFromValueError!Event {
        switch (from) {
            0, 1 => {
                const old = try payloadOf(EventV1, allocator, data);
                return .{
                    .scope = "app",
                    .kind = old.kind,
                    .count = std.fmt.parseInt(u32, old.count, 10) catch return error.InvalidNumber,
                };
            },
            // A line from a build newer than this one.
            else => return error.UnknownField,
        }
    }
};

test "a line of the current version is parsed straight into T" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const line = "{\"v\":2,\"data\":{\"scope\":\"net\",\"kind\":\"open\",\"count\":3}}";
    const record = try strand.parseLine(Versioned(Event), arena.allocator(), line, .{});

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

    const record = try strand.parseLine(
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

    const record = try strand.parseLine(
        Versioned(Event),
        arena.allocator(),
        "{\"data\":{\"kind\":\"open\",\"count\":\"2\"}}",
        .{},
    );
    try testing.expectEqual(@as(u32, 0), record.from);
    try testing.expectEqual(@as(u32, 2), record.value.count);

    // And a type that says its unstamped lines were version 1 sees 1.
    const Stamped = struct {
        kind: []const u8,
        pub const jsonl_version: u32 = 2;
        pub const jsonl_version_unstamped: u32 = 1;
        pub fn jsonlMigrate(_: Allocator, from: u32, _: std.json.Value) std.json.ParseFromValueError!@This() {
            // The hook's error set is `std.json`'s, so a surprise here is
            // reported as one of those rather than as a test failure.
            if (from != 1) return error.UnknownField;
            return .{ .kind = "migrated" };
        }
    };
    const stamped = try strand.parseLine(
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
        const record = try strand.parseLine(Versioned(Event), arena.allocator(), line, .{});
        try testing.expectEqual(@as(u32, 5), record.value.count);
        try testing.expectEqualStrings("open", record.value.kind);
    }
}

test "a version from the future is a malformed line, by number" {
    const input =
        \\{"v":2,"data":{"kind":"known"}}
        \\{"v":99,"data":{"kind":"unknowable"}}
        \\{"v":2,"data":{"kind":"known again"}}
        \\
    ;
    var source: std.Io.Reader = .fixed(input);
    var reader: strand.Reader(Versioned(Event)) = .init(testing.allocator, &source, .{});
    defer reader.deinit();

    try testing.expectEqualStrings("known", (try reader.next()).?.value.value.kind);
    try testing.expectError(error.MalformedLine, reader.next());
    try testing.expectEqual(@as(u64, 2), reader.last_error_line);
    try testing.expectEqual(error.UnknownField, reader.last_error.?);
    try testing.expectEqualStrings("known again", (try reader.next()).?.value.value.kind);
}

test "a missing data member is a missing field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.MissingField, strand.parseLine(
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

    var log: strand.Writer(Versioned(Event)) = .init(&out.writer, .{});
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
    var reader: strand.Reader(Versioned(Event)) = .init(testing.allocator, &source, .{});
    defer reader.deinit();
    try testing.expectEqual(@as(u32, 1), (try reader.next()).?.value.value.count);
    try testing.expectEqualStrings("net", (try reader.next()).?.value.value.scope);
    try testing.expectEqual(@as(?strand.Line(Versioned(Event)), null), try reader.next());
}

test "a migrated record is written back in today's shape" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const record = try strand.parseLine(
        Versioned(Event),
        arena.allocator(),
        "{\"v\":1,\"data\":{\"kind\":\"open\",\"count\":\"9\"}}",
        .{},
    );

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try strand.writeLine(&out.writer, record);
    try testing.expectEqualStrings(
        "{\"v\":2,\"data\":{\"scope\":\"app\",\"kind\":\"open\",\"count\":9}}\n",
        out.written(),
    );
}

//=========================================================================
// The composition the documents claim: an envelope is an ordinary type, so
// every reader in the package reads one without being told about it.
//=========================================================================

const fixtures = @import("fixtures.zig");

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
    var tail: strand.Tail(Versioned(Event)) = try .init(testing.allocator, &fixture.reader, .{
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
    try testing.expectEqual(@as(?strand.Line(Versioned(Event)), null), try tail.prev());
}

test "a versioned log followed as it grows is migrated the same way" {
    var fixture = try fixtures.Fixture.init(mixed_log, 512);
    defer fixture.deinit();

    var follower: strand.Follower(Versioned(Event)) = .init(
        testing.allocator,
        testing.io,
        &fixture.reader,
        .{ .wait = .{ .poll = .fromMicroseconds(100) } },
    );
    defer follower.deinit();

    const first = try follower.next();
    try testing.expect(first.value.migrated());
    try testing.expectEqual(@as(u32, 1), first.value.value.count);
    try testing.expectEqualStrings("retry", (try follower.next()).value.value.kind);
    try testing.expectEqualStrings("close", (try follower.next()).value.value.kind);

    // And a line of the old shape appended while the follower is running
    // goes through the hook like any other.
    try fixture.write_file.writePositionalAll(
        testing.io,
        "{\"v\":1,\"data\":{\"kind\":\"late\",\"count\":\"4\"}}\n",
        mixed_log.len,
    );
    const late = try follower.next();
    try testing.expect(late.value.migrated());
    try testing.expectEqualStrings("late", late.value.value.kind);
    try testing.expectEqual(@as(u32, 4), late.value.value.count);
    try testing.expectEqual(@as(u64, 4), late.number);
}
