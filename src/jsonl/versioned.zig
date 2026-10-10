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
const typed_parse = @import("../json/api.zig").parse_module;
const from_value = @import("../json/api.zig").from_value_module;

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
/// * `pub fn jsonlMigrate(arena: Allocator, from: u32, data: std.json.Value)
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
/// Every field of `T` belongs inside `data`, including fields named `v` or
/// `data`. Only the envelope's own `v` selects the schema version.
pub fn Versioned(comptime T: type) type {
    comptime {
        checkShape(T);
        std.debug.assert(!std.mem.eql(u8, version_key, data_key));
        std.debug.assert(@sizeOf(u32) == 4);
    }
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
            arena: Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!Self {
            if (.object_begin != try source.next()) return error.UnexpectedToken;

            var from: ?u32 = null;
            // The payload is held as a value and a flag, not a `?T`: Zig
            // 0.17.0 on aarch64 miscompiles an optional whose payload holds a
            // 48-byte vector such as `@Vector(3, u128)`, and this function
            // would hand the caller `null` where the line said otherwise.
            var parsed: T = undefined;
            var have_parsed = false;
            var stashed: ?std.json.Value = null;

            while (true) {
                const key = switch (try source.nextAllocMax(
                    arena,
                    .alloc_if_needed,
                    options.max_value_len.?,
                )) {
                    inline .string, .allocated_string => |slice| slice,
                    .object_end => break,
                    else => return error.UnexpectedToken,
                };

                if (std.mem.eql(u8, key, version_key)) {
                    if (from != null) switch (options.duplicate_field_behavior) {
                        .@"error" => return error.DuplicateField,
                        .use_first => {
                            try source.skipValue();
                            continue;
                        },
                        .use_last => {},
                    };
                    from = try typed_parse.inner(u32, arena, source, options);
                } else if (std.mem.eql(u8, key, data_key)) {
                    if (have_parsed or stashed != null) switch (options.duplicate_field_behavior) {
                        .@"error" => return error.DuplicateField,
                        .use_first => {
                            try source.skipValue();
                            continue;
                        },
                        .use_last => {},
                    };
                    if (options.duplicate_field_behavior == .use_last) {
                        have_parsed = false;
                        stashed = try std.json.innerParse(std.json.Value, arena, source, options);
                    } else if (from != null and from.? == current) {
                        parsed = try typed_parse.inner(T, arena, source, options);
                        have_parsed = true;
                    } else {
                        stashed = try std.json.innerParse(std.json.Value, arena, source, options);
                    }
                } else if (options.ignore_unknown_fields) {
                    try source.skipValue();
                } else {
                    return error.UnknownField;
                }
            }

            const version = from orelse unstamped;
            if (have_parsed) return .{ .value = parsed, .from = version };
            const data = stashed orelse return error.MissingField;
            if (version == current) {
                return .{
                    .value = try from_value.parseFromValue(T, arena, data, options),
                    .from = version,
                };
            }
            if (!@hasDecl(T, "jsonlMigrate")) return error.UnknownField;
            return .{ .value = try T.jsonlMigrate(arena, version, data), .from = version };
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
/// `std.json.parseFromValueLeaky` with unknown fields ignored, except that a
/// number it would panic on casting into one of `Old`'s integers is
/// `error.Overflow`: 2^64 into a `u64`, for one.
/// Byte vectors accept strings and arrays, matching std.json's encoding.
/// Arrays and vectors compose with the reflected shapes, and an earlier
/// field's conversion error is returned before any later integer overflow.
///
/// Ownership: `std.json`'s leaky contract — allocations land on `arena`,
/// which in a hook is the arena the line is being parsed on, and the result
/// lives exactly as long as the rest of the line's value does.
pub fn payloadOf(
    comptime Old: type,
    arena: Allocator,
    data: std.json.Value,
) std.json.ParseFromValueError!Old {
    return from_value.parseFromValue(Old, arena, data, .{ .ignore_unknown_fields = true });
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
}

//=========================================================================
// Tests. The scenario is one type through three versions, which is the only
// way to show that a migration is a migration.
//=========================================================================

const testing = std.testing;
