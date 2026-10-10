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
//! `Versioned(T)` is an ordinary type to the core, with a codec of its own, so
//! it composes with everything else here: `Reader(Versioned(Event))`,
//! `Writer(Versioned(Event))`, `Tail(Versioned(Event))`,
//! `Follower(Versioned(Event))`, and `json.parse` of one.

const std = @import("std");
const core = @import("../core.zig");

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
/// * `pub fn jsonlMigrate(from: u32, payload: anytype) @TypeOf(payload.*).Error!T`
///   — how to read a version that is not this one. `payload.read(Old)` reads
///   the payload as an older shape, and `payload.alloc` takes storage for
///   what today's shape holds beyond it; both are bounded as the rest of the
///   line is. A version the hook does not know is for the hook to refuse,
///   with `error.UnknownVariant` or a code of its own through
///   `payload.reject`, or to represent.
/// * `pub const jsonl_version_unstamped: u32` — what a line with no `v` on it
///   is taken to be. Defaults to 0, which no `jsonl_version` should ever be,
///   so an unstamped line reaches `jsonlMigrate` as `from = 0` and is
///   recognisable there. A log that was written before versioning existed
///   sets this to the version that log was.
///
/// Every field of `T` belongs inside `data`, including fields named `v` or
/// `data`. Only the envelope's own `v` selects the schema version. The
/// envelope's keys are refused when repeated, and any other key is refused.
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
        pub const unstamped: u32 = if (@hasDecl(T, "jsonl_version_unstamped")) T.jsonl_version_unstamped else 0;

        /// True when this record reached its current shape through
        /// `T.jsonlMigrate` rather than by being written in it.
        pub fn migrated(self: Self) bool {
            return self.from != current;
        }

        fn Compound(comptime Access: type) type {
            return @typeInfo(@TypeOf(@as(*Access, undefined).begin(.record))).error_union.payload;
        }
        fn ReadError(comptime Access: type) type {
            const C = Compound(Access);
            return @typeInfo(@TypeOf(@as(*C, undefined).element(T))).error_union.error_set ||
                @typeInfo(@TypeOf(@as(*C, undefined).readHeld(T, undefined))).error_union.error_set ||
                @typeInfo(@TypeOf(@as(*C, undefined).key([]const u8))).error_union.error_set;
        }

        /// Reads the envelope.
        ///
        /// The two keys are read in whatever order the line puts them, but
        /// `v` before `data`, the order this package writes, is the order
        /// that costs nothing: the version is known by the time `data` is
        /// reached, so the payload is parsed straight into `T` and its
        /// strings still borrow from the line. A line that puts `data` first
        /// has its payload checked and passed over, then read where it lies
        /// once `v` is known; it is read correctly either way.
        ///
        /// A version this build cannot read is `error.UnknownVariant` when
        /// `T` declares no `jsonlMigrate`. Through a `Reader` that is
        /// `error.MalformedLine`, with the line number on the reader.
        pub fn strandDeserialize(access: anytype) ReadError(@TypeOf(access.*))!Self {
            var record = try access.begin(.record);
            defer record.abort();
            var from: ?u32 = null;
            // The payload is held as a value and a flag, not a `?T`: Zig
            // 0.17.0 on aarch64 miscompiles an optional whose payload holds a
            // 48-byte vector such as `@Vector(3, u128)`, and this function
            // would hand the caller `null` where the line said otherwise.
            var parsed: T = undefined;
            var have_parsed = false;
            var held: ?@TypeOf(record).Held = null;
            while (try record.hasNext()) {
                const key = try record.key([]const u8);
                if (std.mem.eql(u8, key, version_key)) {
                    if (from != null) return error.DuplicateField;
                    from = try record.element(u32);
                } else if (std.mem.eql(u8, key, data_key)) {
                    if (have_parsed or held != null) return error.DuplicateField;
                    if (from == current) {
                        parsed = try record.element(T);
                        have_parsed = true;
                    } else held = try record.hold();
                } else return error.UnknownField;
            }
            const version = from orelse unstamped;
            if (have_parsed) {
                try record.finish();
                return .{ .value = parsed, .from = version };
            }
            const data = held orelse return error.MissingField;
            const value = if (version == current) try record.readHeld(T, data) else migrated: {
                if (!@hasDecl(T, "jsonlMigrate")) return error.UnknownVariant;
                var payload: Payload(@TypeOf(record)) = .{ .record = &record, .held = data };
                break :migrated T.jsonlMigrate(version, &payload) catch |err| return payload.failure(err);
            };
            try record.finish();
            return .{ .value = value, .from = version };
        }

        /// Writes the envelope.
        ///
        /// Always stamps `current`, never `from`: `value` is in today's shape
        /// whatever shape the line it came from was in, so writing it back
        /// under an older version would be a lie about its contents.
        pub fn strandSerialize(self: Self, access: anytype) @typeInfo(@TypeOf(access.write(Envelope{ .v = current, .data = self.value }))).error_union.error_set!void {
            try access.write(Envelope{ .v = current, .data = self.value });
        }
        const Envelope = struct { v: u32, data: T };
    };
}

/// An older payload, as a `jsonlMigrate` hook sees it.
pub fn Payload(comptime Record: type) type {
    return struct {
        record: *Record,
        held: Record.Held,
        /// What the hook may fail with: the parse's own errors, a code of its
        /// own included through `reject`.
        pub const Error = core.DecodeError;
        const Self = @This();

        /// The payload as an older shape: parsed where it lies on the line,
        /// under the line's own limits, strings borrowed as the line's are.
        pub fn read(self: *Self, comptime Old: type) Error!Old {
            return self.record.readHeld(Old, self.held) catch |err| self.failure(err);
        }

        /// Storage for today's shape, bounded as the line's own is.
        pub fn alloc(self: *Self, comptime U: type, n: usize) Error![]U {
            return self.record.access.alloc(U, n);
        }

        /// Refuses the payload with a code of the hook's own, which a reader's
        /// diagnostics carry as `custom_code`.
        pub fn reject(self: *Self, code: u32) error{CustomRejected} {
            return self.record.access.reject(code);
        }

        fn failure(_: *const Self, err: anyerror) Error {
            inline for (@typeInfo(Error).error_set.error_names.?) |name| {
                if (err == @field(anyerror, name)) return @field(Error, name);
            }
            return error.CustomRejected;
        }
    };
}

/// What `Versioned` requires of `T`, checked where the mistake is made.
fn checkShape(comptime T: type) void {
    const name = @typeName(T);
    if (!@hasDecl(T, "jsonl_version")) {
        @compileError("strand.jsonl.Versioned(" ++ name ++ ") needs `pub const jsonl_version: u32` on " ++ name);
    }
    if (@TypeOf(T.jsonl_version) != u32 and @TypeOf(T.jsonl_version) != comptime_int) {
        @compileError(name ++ ".jsonl_version must be a u32");
    }
    if (T.jsonl_version == 0) {
        @compileError(name ++ ".jsonl_version must not be 0: 0 is what a line with no version is");
    }
}
