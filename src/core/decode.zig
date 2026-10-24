//! One bounded typed mapping kernel over immediate semantic events.
const std = @import("std");
const limit = @import("limit.zig");
const descriptor = @import("descriptor.zig");
const ctx = @import("context.zig");
const model = @import("model.zig");
const scalars = @import("scalars.zig");
const xenoglyph = @import("xenoglyph");

/// Backend.next(context, request) must meter wire reads/scratch through context before
/// doing that work, validate grammar, and distinguish input from scratch spans.
/// endInput verifies no trailing value. All backend errors are named.
pub fn deserialize(comptime T: type, backend: anytype, c: *ctx.Context) Errors(T, @TypeOf(backend.*))!T {
    comptime descriptor.check(T, @TypeOf(backend.*).capabilities, true, .borrowed);
    var cursor: Cursor(@TypeOf(backend.*)) = .{ .backend = backend, .context = c };
    const value = try cursor.readFresh(T, .{});
    try backend.endInput(c);
    return value;
}

/// Whether `name` is `spelling`, a name the schema spells at compile time:
/// a short one is compared a byte at a time with no call.
inline fn spelled(name: []const u8, comptime spelling: []const u8) bool {
    if (name.len != spelling.len) return false;
    if (spelling.len > 32) return std.mem.eql(u8, name, spelling);
    inline for (spelling, 0..) |b, k| if (name[k] != b) return false;
    return true;
}

/// A record member's key, and the field it names.
const Member = struct { name: []const u8, field: ?usize };

/// The field of `T` a key names by case folding (`Names.fold_case`): the
/// first of its names, fields in order and then aliases, the key folds to.
fn foldedField(comptime T: type, key: []const u8, c: *ctx.Context) error{WorkLimit}!?usize {
    const names = MemberNames(T);
    inline for (names.spellings, names.fields) |spelling, field_index| {
        try c.chargeWork(@as(usize, @min(key.len, spelling.len)) + 1);
        if (foldsTo(key, spelling)) return field_index;
    }
    return null;
}

/// Whether `key`, UTF-8, folds to `spelling`: code point by code point under
/// Unicode's simple case folding (CaseFolding.txt C and S), as Go's
/// `encoding/json` matches names, so `ſ` and the Kelvin sign fold to `s` and
/// `k` and `Σ`, `σ` and `ς` to one another. A sequence that is not UTF-8
/// matches only the same bytes.
fn foldsTo(key: []const u8, spelling: []const u8) bool {
    var k: usize = 0;
    var s: usize = 0;
    while (k < key.len and s < spelling.len) {
        if (key[k] < 0x80 and spelling[s] < 0x80) {
            if (std.ascii.toLower(key[k]) != std.ascii.toLower(spelling[s])) return false;
            k += 1;
            s += 1;
            continue;
        }
        const a = xenoglyph.utf8.decode(key[k..]);
        const b = xenoglyph.utf8.decode(spelling[s..]);
        const same = if (a.code_point == xenoglyph.utf8.replacement or b.code_point == xenoglyph.utf8.replacement)
            std.mem.eql(u8, key[k..][0..a.len], spelling[s..][0..b.len])
        else
            xenoglyph.case.simpleFold(a.code_point) == xenoglyph.case.simpleFold(b.code_point);
        if (!same) return false;
        k += a.len;
        s += b.len;
    }
    return k == key.len and s == spelling.len;
}

/// Whether `T` reads `null` itself: an optional, a raw value, a type whose
/// values include null (`strand_nullable`, a dynamic value), or a pointer to
/// one. Any other value keeps what it holds under `Nulls.keep`.
fn readsNull(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional, .null => true,
        .pointer => |p| p.size == .one and readsNull(p.child),
        else => descriptor.has(T, "StrandRawFormat") or descriptor.has(T, "strand_nullable"),
    };
}

/// Whether `T` is a map of the core's own (`Pairs`).
fn isPairs(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and descriptor.has(T, "StrandKey") and @hasField(T, "items");
}

/// Whether `null` empties `T` under `Nulls.keep`: a sequence or a map.
/// Text and bytes are values, not sequences.
fn emptiedByNull(comptime T: type) bool {
    if (comptime isPairs(T)) return true;
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child != u8,
        else => false,
    };
}

/// Whether reading `T` into a value merges with it (`Duplicates.merge`): a
/// record, an optional, a pointer, a sequence, an array or a map. Anything
/// else, a type with a reading of its own among them, is read afresh.
fn merges(comptime T: type, comptime policy: descriptor.Field) bool {
    if (comptime isPairs(T)) return true;
    if (comptime descriptor.has(T, "strandDeserialize") or scalars.kind(T) != null) return false;
    return switch (@typeInfo(T)) {
        .optional => true,
        .pointer => |p| p.size == .one or (p.size == .slice and p.child != u8),
        .array => policy.as == .normal,
        .@"struct" => |i| !i.is_tuple,
        else => false,
    };
}

/// The names a record's keys are matched against: every field's, in
/// declaration order, then the aliases; which field each names; and, for each
/// field, the position of the name after its own, which is the one a writer
/// that keeps declaration order puts next.
fn MemberNames(comptime T: type) type {
    @setEvalBranchQuota(100_000);
    const i = @typeInfo(T).@"struct";
    var n = 0;
    for (i.field_names) |name| {
        n += 1 + descriptor.field(T, name).aliases.len;
    }
    var list: [n][]const u8 = undefined;
    var owners: [n]usize = undefined;
    var after: [i.field_names.len]usize = @splat(0);
    var k = 0;
    for (i.field_names, 0..) |name, index| {
        list[k] = descriptor.field(T, name).name;
        owners[k] = index;
        k += 1;
    }
    const primaries = k;
    for (0..primaries) |p| after[owners[p]] = (p + 1) % primaries;
    for (i.field_names, 0..) |name, index| {
        for (descriptor.field(T, name).aliases) |alias| {
            list[k] = alias;
            owners[k] = index;
            k += 1;
        }
    }
    const frozen_list = list;
    const frozen_owners = owners;
    const frozen_after = after;
    return struct {
        pub const spellings: []const []const u8 = &frozen_list;
        pub const fields: []const usize = &frozen_owners;
        pub const next = frozen_after;
    };
}

/// The keys of a record that matched no field, kept to refuse one given twice.
const Ignored = struct {
    inline_names: [8][]const u8 = undefined,
    extra: [][]const u8 = &.{},
    len: usize = 0,
    fn add(self: *Ignored, c: *ctx.Context, name: []const u8) ctx.DecodeError!void {
        for (0..self.len) |k| {
            const prior = if (k < self.inline_names.len) self.inline_names[k] else self.extra[k - self.inline_names.len];
            try c.chargeWork(@min(name.len, prior.len));
            if (std.mem.eql(u8, name, prior)) return error.DuplicateField;
        }
        if (self.len < self.inline_names.len) {
            self.inline_names[self.len] = name;
        } else {
            const k = self.len - self.inline_names.len;
            if (k == self.extra.len) {
                const grown = try c.alloc([]const u8, try ctx.Context.grownCapacity(self.extra.len, c.limits.container_items));
                @memcpy(grown[0..k], self.extra);
                self.extra = grown;
            }
            self.extra[k] = name;
        }
        self.len += 1;
    }
};

/// Where a value lies in the input, to be replayed.
const Region = struct { start: usize, end: usize };

/// What a backend's `replay` starts: itself, or what a wrapper wraps.
fn Replayed(comptime Backend: type) type {
    return if (@hasDecl(Backend, "Replayed")) Backend.Replayed else Backend;
}

/// Text a backend hands over is UTF-8 once one of them has checked it.
inline fn validText(comptime Backend: type, bytes: []const u8) bool {
    return Backend.capabilities.utf8_text or std.unicode.utf8ValidateSlice(bytes);
}

pub fn Cursor(comptime Backend: type) type {
    return struct {
        backend: *Backend,
        context: *ctx.Context,
        pending: ?model.Event = null,
        pending_start: usize = 0,
        request: model.Request = .{},
        first_event: bool = true,
        const Self = @This();
        const Error = ctx.DecodeError || Backend.Error;
        /// The next event, as the backend makes it. Nothing is kept: `peek` keeps
        /// it for the caller who wants to look first.
        inline fn fetch(self: *Self) Error!model.Event {
            if (self.context.diagnostics) |d| d.offset = self.backend.offset();
            const event = self.backend.next(self.context, self.request) catch |err| {
                if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                return err;
            };
            if (self.first_event) {
                if (self.context.depth == 0 and !Backend.capabilities.scalar_roots and event != .begin) return error.UnsupportedValue;
                self.first_event = false;
            }
            return event;
        }
        fn peek(self: *Self) Error!model.Event {
            if (self.pending == null) {
                self.pending_start = self.backend.offset();
                self.pending = try self.fetch();
            }
            return self.pending.?;
        }
        /// Whether the container being read has no more members. A format that can
        /// tell without producing the next member's event says so, so that the
        /// member is fetched knowing the type it was asked for.
        fn atEnd(self: *Self) Error!bool {
            if (self.pending) |event| return event == .end;
            if (comptime @hasDecl(Backend, "atEnd")) return self.backend.atEnd();
            return try self.peek() == .end;
        }
        fn take(self: *Self) Error!model.Event {
            if (self.pending) |event| {
                self.pending = null;
                return event;
            }
            return self.fetch();
        }
        fn end(self: *Self) Error!void {
            if (try self.take() != .end) return error.SyntaxError;
        }
        fn start(self: *Self, expected: model.Kind) Error!model.Compound {
            self.request = .{ .expected = switch (expected) {
                .sequence => .sequence,
                .tuple => .tuple,
                .named_tuple => .named_tuple,
                .map => .map,
                .record => .record,
                .variant => .variant,
                .named_unit => .named_unit,
                .newtype => .newtype,
                .some => .some,
            } };
            const header: model.Compound = opened: {
                if (comptime @hasDecl(Backend, "open")) if (self.pending == null) {
                    if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                    const found = self.backend.open(self.context, self.request) catch |err| {
                        if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                        return err;
                    };
                    if (found) |compound| {
                        self.first_event = false;
                        break :opened compound;
                    }
                };
                const event = try self.take();
                if (event != .begin) return error.UnexpectedType;
                break :opened event.begin;
            };
            if (header.name.len != 0) {
                try self.context.span(header.name.len, false);
                try self.context.chargeWork(header.name.len);
                if (!std.unicode.utf8ValidateSlice(header.name)) return error.InvalidUtf8;
            }
            if (header.len == null and !Backend.capabilities.indefinite_containers) return error.UnsupportedValue;
            if (header.kind != expected and !(expected == .tuple and header.kind == .sequence) and !(expected == .record and header.kind == .map) and !(expected == .map and header.kind == .record)) return error.UnexpectedType;
            try self.context.enter();
            errdefer self.context.leave();
            if (header.len) |n| try self.context.count(n);
            return header;
        }
        fn equals(self: *Self, a: []const u8, b: []const u8) Error!bool {
            try self.context.chargeWork(@min(a.len, b.len));
            return std.mem.eql(u8, a, b);
        }
        /// A value of one kind read by the backend's own reader of that kind,
        /// with no event between: `null` when the next value is of another
        /// kind, which the event path then reads and refuses or takes.
        inline fn direct(self: *Self, comptime reader: []const u8) Error!@typeInfo(@typeInfo(@TypeOf(@field(Backend, reader))).@"fn".return_type.?).error_union.payload {
            if (self.pending != null) return null;
            if (self.context.diagnostics) |d| d.offset = self.backend.offset();
            const result = @field(Backend, reader)(self.backend, self.context) catch |err| {
                if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                return err;
            };
            if (result != null) try self.directDone();
            return result;
        }
        /// An integer read and converted by the backend in one pass, as
        /// `direct` reads a value.
        inline fn directInteger(self: *Self, comptime T: type) Error!?T {
            if (self.pending != null) return null;
            if (self.context.diagnostics) |d| d.offset = self.backend.offset();
            const result = self.backend.integer(T, self.context) catch |err| {
                if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                return err;
            };
            if (result != null) try self.directDone();
            return result;
        }
        inline fn directDone(self: *Self) Error!void {
            if (self.first_event and self.context.depth == 0 and !Backend.capabilities.scalar_roots) return error.UnsupportedValue;
            self.first_event = false;
        }
        /// The key of the next member of the record being read, or `null`
        /// where it closes, the close taken. A format that reads a key and
        /// the separators around it in one step says so with `memberKey`.
        inline fn member(self: *Self) Error!?[]const u8 {
            if (comptime @hasDecl(Backend, "memberKey")) if (self.pending == null) {
                if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                const span = (self.backend.memberKey(self.context) catch |err| {
                    if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                    return err;
                }) orelse return null;
                try self.context.node();
                try self.context.span(span.bytes.len, true);
                try self.context.chargeWork(span.bytes.len);
                if (!validText(Backend, span.bytes)) return error.InvalidUtf8;
                return span.bytes;
            };
            if (try self.atEnd()) {
                try self.end();
                return null;
            }
            return try self.key();
        }
        /// The next member of a record of `T`: the field its key names, or
        /// the key when it names none, or `null` where the record closes, the
        /// close taken. `hint` is the name expected next: a writer keeps
        /// declaration order. A format that can match a key against the
        /// schema's names where it lies says so with `memberOf`.
        inline fn recordMember(self: *Self, comptime T: type, hint: usize) Error!?Member {
            const names = MemberNames(T);
            if (comptime @hasDecl(Backend, "memberOf")) if (self.pending == null) {
                if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                const found = (self.backend.memberOf(self.context, names.spellings, hint) catch |err| {
                    if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                    return err;
                }) orelse return null;
                try self.context.node();
                try self.context.span(found.name.len, true);
                try self.context.chargeWork(found.name.len);
                if (!validText(Backend, found.name)) return error.InvalidUtf8;
                if (names.fields.len == 0) return .{ .name = found.name, .field = null };
                if (found.index) |k| return .{ .name = found.name, .field = names.fields[k] };
                return .{ .name = found.name, .field = try self.folded(T, found.name) };
            };
            const name = (try self.member()) orelse return null;
            inline for (names.spellings, names.fields) |spelling, field_index| {
                if (spelled(name, spelling)) return .{ .name = name, .field = field_index };
            }
            return .{ .name = name, .field = try self.folded(T, name) };
        }
        /// The field a key no name spells exactly finds by case folding, where
        /// the reading asks for it.
        inline fn folded(self: *Self, comptime T: type, name: []const u8) Error!?usize {
            if (self.context.acceptance.names != .fold_case) return null;
            return foldedField(T, name, self.context);
        }
        /// Whether the next value is `null`, taken if it is: by the format's
        /// own reader where it has one (`none`), else by its event.
        fn takeNull(self: *Self) Error!bool {
            if (comptime @hasDecl(Backend, "none")) if (self.pending == null) {
                if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                const found = self.backend.none(self.context) catch |err| {
                    if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                    return err;
                };
                if (found) try self.directDone();
                return found;
            };
            if (try self.peek() != .none) return false;
            _ = try self.take();
            return true;
        }
        /// What a value read fresh holds where `null` keeps it (`Nulls.keep`):
        /// its type's zero. A type with none refuses the null.
        fn zero(self: *Self, comptime T: type) Errors(T, Backend)!T {
            if (comptime isPairs(T)) return .{ .items = &.{} };
            switch (@typeInfo(T)) {
                .bool => return false,
                .int, .float => return 0,
                .void => return {},
                .optional => return null,
                .pointer => |i| switch (i.size) {
                    .slice => return try self.context.allocPointer(T, 0),
                    .one => {
                        const storage = try self.context.allocPointer(T, 1);
                        storage.* = try self.zero(i.child);
                        return storage;
                    },
                    else => return error.UnexpectedType,
                },
                .array => |i| {
                    var value: T = undefined;
                    for (&value) |*element| element.* = try self.zero(i.child);
                    if (comptime i.sentinel()) |sentinel| value[i.len] = sentinel;
                    return value;
                },
                .@"struct" => |i| {
                    if (comptime descriptor.has(T, "StrandRawFormat") or descriptor.has(T, "strand_bytes") or descriptor.has(T, "strand_scalar")) return error.UnexpectedType;
                    var value: T = undefined;
                    inline for (i.field_names, i.field_attrs) |name, attrs| {
                        if (attrs.@"comptime") continue;
                        if (i.is_tuple) {
                            @field(value, name) = try self.zero(@FieldType(T, name));
                        } else {
                            @field(value, name) = try self.defaultOf(T, name);
                        }
                    }
                    return value;
                },
                else => return error.UnexpectedType,
            }
        }
        /// A field's default, as a record fills a field no member gave: its
        /// declared default made, or its literal default copied.
        fn defaultOf(self: *Self, comptime T: type, comptime name: []const u8) Errors(T, Backend)!@FieldType(T, name) {
            const F = @FieldType(T, name);
            const declared = comptime descriptor.fieldOptions(T, name);
            if (@hasField(@TypeOf(declared), "default") and @typeInfo(@TypeOf(declared.default)) == .@"fn") {
                const value = try declared.default(self.context);
                if (comptime @typeInfo(F) == .pointer) {
                    const pointer = @typeInfo(F).pointer;
                    if (comptime pointer.size == .slice and pointer.child == u8 and !@hasField(@TypeOf(declared), "codec")) {
                        try self.context.span(value.len, false);
                        try self.context.chargeWork(value.len);
                        if ((comptime descriptor.field(T, name)).as != .bytes and !std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
                    }
                }
                return value;
            }
            const default_value = (comptime descriptor.default(T, name)) orelse return error.MissingField;
            return cloneField(F, comptime descriptor.field(T, name), default_value, self.context);
        }
        fn key(self: *Self) Error![]const u8 {
            self.request = .{ .expected = .text };
            try self.context.node();
            const event = try self.take();
            if (event != .text) return error.UnexpectedType;
            try self.context.span(event.text.bytes.len, true);
            try self.context.chargeWork(event.text.bytes.len);
            if (!validText(Backend, event.text.bytes)) return error.InvalidUtf8;
            return event.text.bytes;
        }
        fn integer(self: *Self, comptime T: type, number: model.Integer) Error!T {
            @setRuntimeSafety(true);
            const i = @typeInfo(T).int;
            const U = @Int(.unsigned, i.bits);
            if (limit.exceeds(number.magnitude.len, self.context.limits.numeric_bytes)) return error.LengthLimit;
            try self.context.chargeWork(number.magnitude.len);
            var value: U = 0;
            var n = number.magnitude.len;
            while (n > 0) {
                n -= 1;
                if (i.bits < 8) {
                    if (value != 0 or number.magnitude[n] > std.math.maxInt(U)) return error.NumberOutOfRange;
                    // safe: the byte was checked against the destination width.
                    value = @intCast(number.magnitude[n]); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
                } else {
                    if (i.bits == 8) {
                        if (value != 0) return error.NumberOutOfRange;
                        value = number.magnitude[n];
                    } else {
                        if (value > std.math.maxInt(U) >> 8) return error.NumberOutOfRange;
                        value = (value << 8) | number.magnitude[n];
                    }
                }
            }
            if (i.signedness == .unsigned) {
                if (number.negative and value != 0) return error.NumberOutOfRange;
                return value;
            }
            if (i.bits == 0) return 0;
            if (number.negative) {
                const minimum: U = @as(U, 1) << (i.bits - 1);
                if (value > minimum) return error.NumberOutOfRange;
                if (value == minimum) return std.math.minInt(T);
                // safe: value is strictly below the magnitude of the signed min.
                return -@as(T, @intCast(value)); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
            }
            if (value > std.math.maxInt(T)) return error.NumberOutOfRange;
            // safe: positive magnitude was checked against the signed maximum.
            return @intCast(value); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
        }
        fn readInteger(self: *Self, comptime T: type) Error!T {
            @setRuntimeSafety(true);
            if (comptime @hasDecl(Backend, "integer")) {
                if (try self.directInteger(T)) |value| return value;
            }
            if (comptime @hasDecl(Backend, "number") and @hasDecl(Backend, "parseInteger")) {
                if (try self.direct("number")) |lexeme| return Backend.parseInteger(T, lexeme, self.context);
            }
            const event = try self.take();
            if (event == .number) {
                if (comptime @hasDecl(Backend, "parseInteger")) return Backend.parseInteger(T, event.number.bytes, self.context);
                return error.UnexpectedType;
            }
            if (event != .integer) return error.UnexpectedType;
            return self.integer(T, event.integer);
        }
        fn readFloat(self: *Self, comptime T: type, comptime policy: descriptor.Field) Error!T {
            @setRuntimeSafety(true);
            if (comptime @hasDecl(Backend, "number") and @hasDecl(Backend, "parseFloat")) {
                if (try self.direct("number")) |lexeme| return Backend.parseFloat(T, lexeme, policy.exact, self.context);
            }
            const event = try self.take();
            if (event == .number) {
                if (comptime @hasDecl(Backend, "parseFloat")) return Backend.parseFloat(T, event.number.bytes, policy.exact, self.context);
                return error.UnexpectedType;
            }
            if (event != .floating) return error.UnexpectedType;
            // safe: float narrowing is the declared destination's rounding;
            // overflow is explicitly rejected before publishing the result.
            if (!Backend.capabilities.nonfinite_floats and !std.math.isFinite(event.floating)) return error.UnsupportedValue;
            const value = model.narrowFloat(T, event.floating);
            if (std.math.isFinite(event.floating) and !std.math.isFinite(value)) return error.NumberOutOfRange;
            if (policy.exact and std.math.isFinite(event.floating) and @as(f128, value) != event.floating) return error.InexactNumber;
            return value;
        }
        pub fn read(self: *Self, comptime T: type, comptime policy: descriptor.Field) Errors(T, Backend)!T {
            @setRuntimeSafety(true);
            comptime descriptor.check(T, Backend.capabilities, true, .borrowed);
            self.request = typeRequest(T, policy);
            if (self.context.diagnostics) |d| d.expected = self.request.expected;
            try self.context.node();
            try self.context.chargeWork(1);
            if (comptime descriptor.has(T, "strandDeserialize")) {
                try self.context.enterHook();
                defer self.context.leaveHook();
                var access: PolicyAccess(Backend, policy) = .{ .cursor = self };
                const value = try T.strandDeserialize(&access);
                if (!access.used or !access.complete) return error.CustomRejected;
                return value;
            }
            if (comptime scalars.kind(T)) |k| {
                if (k == .text) return scalars.parse(T, try self.textValue());
                return scalars.fromInteger(T, try self.readInteger(scalars.Representation(T)));
            }
            switch (@typeInfo(T)) {
                .bool => {
                    const event = try self.take();
                    if (event != .boolean) return error.UnexpectedType;
                    return event.boolean;
                },
                .int => return self.readInteger(T),
                .float => return self.readFloat(T, policy),
                .void => {
                    if (try self.take() != .unit) return error.UnexpectedType;
                    return {};
                },
                .null => {
                    if (try self.take() != .none) return error.UnexpectedType;
                    return null;
                },
                .optional => |i| {
                    if (try self.peek() == .none) {
                        _ = try self.take();
                        return null;
                    }
                    const event = try self.peek();
                    if (event == .begin and event.begin.kind == .some) {
                        const header = try self.start(.some);
                        defer self.context.leave();
                        if (header.len) |n| if (n != 1) return error.SyntaxError;
                        const value: T = try self.read(i.child, policy);
                        try self.end();
                        return value;
                    }
                    // Optional presence is a type hint, not an extra wire node.
                    if (!self.context.replaying) self.context.items -= 1;
                    return try self.read(i.child, policy);
                },
                .pointer => |i| switch (i.size) {
                    .one => {
                        if (!self.context.replaying) self.context.items -= 1;
                        const storage = try self.context.allocPointer(T, 1);
                        storage.* = try self.read(i.child, policy);
                        return storage;
                    },
                    .slice => return self.slice(T, policy, null),
                    else => unreachable,
                },
                .array, .vector => return self.fixed(T, policy, null),
                .@"struct" => |i| {
                    if (i.is_tuple) {
                        const header = try self.start(.tuple);
                        defer self.context.leave();
                        var count: usize = 0;
                        inline for (i.field_attrs) |attrs| if (!attrs.@"comptime") {
                            count += 1;
                        };
                        if (header.len) |n| if (n != count) return error.UnexpectedType;
                        var value: T = undefined;
                        inline for (i.field_names, i.field_attrs) |name, attrs| {
                            if (attrs.@"comptime") continue;
                            const F = @FieldType(T, name);
                            @field(value, name) = if (try self.keptByNull(F, comptime descriptor.field(T, name))) try self.zero(F) else try self.readField(T, name);
                        }
                        try self.end();
                        return value;
                    }
                    var value: T = undefined;
                    try self.record(T, &value, true);
                    return value;
                },
                .@"enum" => |i| {
                    const name = try self.symbolValue();
                    // Matched against the type's names in one pass, charged
                    // once: the names are a constant set.
                    try self.context.chargeWork(name.len);
                    inline for (i.field_names) |variant| {
                        const v = comptime descriptor.variant(T, variant);
                        if (spelled(name, v.name)) return @field(T, variant);
                        inline for (v.aliases) |alias| if (spelled(name, alias)) return @field(T, variant);
                    }
                    return error.UnknownVariant;
                },
                .@"union" => return self.readUnion(T),
                else => @compileError("unsupported core decode type"),
            }
        }
        /// A value read where it starts from nothing, at the root, as an
        /// element or as a map's value: a `null` that `Nulls.keep` takes for a
        /// type without one is the type's zero. A record's field is the
        /// record's to keep, and an optional's value its own.
        pub inline fn readFresh(self: *Self, comptime T: type, comptime policy: descriptor.Field) Errors(T, Backend)!T {
            if (try self.keptByNull(T, policy)) return self.zero(T);
            return self.read(T, policy);
        }
        /// A value read into what `into` holds, as a member given again merges
        /// (`Duplicates.merge`): a record member by member, an optional's value,
        /// a pointer's, a sequence's elements by position, an array's, and a
        /// map's entries, a key given again taking its later value. Anything
        /// else is read afresh and replaces it. `null` under `Nulls.keep`
        /// leaves it, or empties a sequence or a map.
        fn readInto(self: *Self, comptime T: type, comptime policy: descriptor.Field, into: *T) Errors(T, Backend)!void {
            @setRuntimeSafety(true);
            if (try self.keptByNull(T, policy)) {
                if (comptime emptiedByNull(T)) into.* = try self.zero(T);
                return;
            }
            if (comptime !merges(T, policy)) {
                into.* = try self.read(T, policy);
                return;
            }
            comptime descriptor.check(T, Backend.capabilities, true, .borrowed);
            self.request = typeRequest(T, policy);
            if (self.context.diagnostics) |d| d.expected = self.request.expected;
            try self.context.node();
            try self.context.chargeWork(1);
            if (comptime isPairs(T)) {
                const entry = @typeInfo(@FieldType(T, "items")).pointer.child;
                try self.context.enterHook();
                defer self.context.leaveHook();
                var access: PolicyAccess(Backend, policy) = .{ .cursor = self };
                into.* = .{ .items = try access.pairsFrom(@FieldType(entry, "key"), @FieldType(entry, "value"), into.items) };
                if (!access.used or !access.complete) return error.CustomRejected;
                return;
            }
            switch (@typeInfo(T)) {
                .optional => |i| {
                    const event = try self.peek();
                    // A presence is a hint, as `read` counts it.
                    if (!self.context.replaying) self.context.items -= 1;
                    if (event != .none and !(event == .begin and event.begin.kind == .some)) {
                        if (into.*) |*inner| return self.readInto(i.child, policy, inner);
                    }
                    into.* = try self.read(T, policy);
                },
                .pointer => |i| switch (i.size) {
                    .one => {
                        if (!self.context.replaying) self.context.items -= 1;
                        const storage = try self.context.allocPointer(T, 1);
                        storage.* = into.*.*;
                        try self.readInto(i.child, policy, storage);
                        into.* = storage;
                    },
                    .slice => into.* = try self.slice(T, policy, @as(T, into.*)),
                    else => unreachable,
                },
                .array => into.* = try self.fixed(T, policy, @as(*const T, into)),
                .@"struct" => try self.record(T, into, false),
                else => unreachable,
            }
        }
        fn readUnion(self: *Self, comptime T: type) Errors(T, Backend)!T {
            const i = @typeInfo(T).@"union";
            const opt = comptime descriptor.options(T);
            if (@hasField(@TypeOf(opt), "tag")) return self.tagged(T);
            const header = try self.start(if (Backend.capabilities.variant_record) .record else .variant);
            defer self.context.leave();
            if (header.len) |n| if (n != 1) return error.SyntaxError;
            const variant_name = if (Backend.capabilities.variant_record) try self.key() else header.name;
            inline for (i.field_names, i.field_types) |name, F| {
                const v = comptime descriptor.variant(T, name);
                var matches = try self.equals(variant_name, v.name);
                inline for (v.aliases) |alias| matches = matches or try self.equals(variant_name, alias);
                if (matches) {
                    const value = @unionInit(T, name, try self.readFresh(F, .{ .name = name }));
                    try self.end();
                    return value;
                }
            }
            if (@hasField(@TypeOf(opt), "other")) {
                const F = @FieldType(T, opt.other);
                const payload = if (F == void) blk: {
                    try self.skip();
                    break :blk {};
                } else try self.readFresh(F, .{});
                try self.end();
                return @unionInit(T, opt.other, payload);
            }
            return error.UnknownVariant;
        }
        /// Routing scans a bounded record once, then replays just the selected
        /// payload. This supports content-before-tag without an unbounded DOM.
        fn tagged(self: *Self, comptime T: type) Errors(T, Backend)!T {
            const opt = comptime descriptor.options(T);
            const record_start = if (self.pending != null) self.pending_start else self.backend.offset();
            const header = try self.start(.record);
            var entered = true;
            defer if (entered) self.context.leave();
            var tag: ?[]const u8 = null;
            var payload: ?Region = null;
            var count: usize = 0;
            while (!try self.atEnd()) {
                if (count >= self.context.limits.container_items) return error.ItemLimit;
                count += 1;
                const name = try self.key();
                if (try self.equals(name, opt.tag)) {
                    if (tag != null) return error.DuplicateField;
                    try self.context.node();
                    const span = try self.keySpan();
                    tag = if (span.lifetime == .transient) try self.context.retain(span.bytes, .transient, .copy) else span.bytes;
                } else if (@hasField(@TypeOf(opt), "content") and try self.equals(name, opt.content)) {
                    if (payload != null) return error.DuplicateField;
                    const payload_start = self.backend.offset();
                    try self.skip();
                    payload = .{ .start = payload_start, .end = self.backend.offset() };
                } else {
                    if (@hasField(@TypeOf(opt), "content")) return error.UnknownField;
                    try self.skip();
                }
            }
            if (header.len) |n| if (n != count) return error.SyntaxError;
            try self.end();
            self.context.leave();
            entered = false;
            const tag_name = tag orelse return error.MissingField;
            const record_end = self.backend.offset();
            const was_replaying = self.context.replaying;
            self.context.replaying = true;
            defer self.context.replaying = was_replaying;
            inline for (@typeInfo(T).@"union".field_names, @typeInfo(T).@"union".field_types) |name, F| {
                const v = comptime descriptor.variant(T, name);
                var matches = try self.equals(tag_name, v.name);
                inline for (v.aliases) |alias| matches = matches or try self.equals(tag_name, alias);
                if (matches) {
                    const value = if (@hasField(@TypeOf(opt), "content")) blk: {
                        const span = payload orelse return error.MissingField;
                        var backend: Replayed(Backend) = undefined;
                        self.backend.replay(&backend, span.start, span.end);
                        defer if (@hasDecl(Backend, "deinit")) backend.deinit();
                        break :blk try deserialize(F, &backend, self.context);
                    } else if (F == void) blk: {
                        // An arm with nothing in it has no field for another
                        // member: an unknown one, refused or passed over.
                        const unknown: descriptor.Unknown = if (self.context.acceptance.reject_unknown_fields) .reject else if (@hasField(@TypeOf(opt), "unknown_fields")) opt.unknown_fields else .ignore;
                        if (count != 1 and unknown == .reject) return error.UnknownField;
                        break :blk {};
                    } else blk: {
                        var backend: Replayed(Backend) = undefined;
                        self.backend.replay(&backend, record_start, record_end);
                        defer if (@hasDecl(Backend, "deinit")) backend.deinit();
                        var filtered: Filtered(Replayed(Backend)) = .{ .backend = &backend, .tag = opt.tag };
                        break :blk try deserialize(F, &filtered, self.context);
                    };
                    return @unionInit(T, name, value);
                }
            }
            if (@hasField(@TypeOf(opt), "other")) {
                const F = @FieldType(T, opt.other);
                if (F == void) return @unionInit(T, opt.other, {});
                const span: Region = payload orelse .{ .start = record_start, .end = record_end };
                var backend: Replayed(Backend) = undefined;
                self.backend.replay(&backend, span.start, span.end);
                defer if (@hasDecl(Backend, "deinit")) backend.deinit();
                return @unionInit(T, opt.other, try deserialize(F, &backend, self.context));
            }
            return error.UnknownVariant;
        }
        /// An array or a vector; an array read into `prior`, a `*const T` or
        /// `null` known when compiled, reads each element into the one there.
        fn fixed(self: *Self, comptime T: type, comptime policy: descriptor.Field, prior: anytype) Errors(T, Backend)!T {
            const i = if (@typeInfo(T) == .array) @typeInfo(T).array else @typeInfo(T).vector;
            if (i.len > policy.max_len) return error.LengthLimit;

            if (policy.as != .normal) {
                if (i.child != u8) @compileError("text/bytes array codec requires u8 elements");
                const event = try self.take();
                const span = switch (event) {
                    .text => |v| if (policy.as == .text) v else return error.UnexpectedType,
                    .bytes => |v| if (policy.as == .bytes) v else return error.UnexpectedType,
                    else => return error.UnexpectedType,
                };
                if (span.bytes.len != i.len) return error.UnexpectedType;
                if (span.bytes.len > policy.max_len) return error.LengthLimit;
                try self.context.span(span.bytes.len, false);
                try self.context.chargeWork(span.bytes.len);
                if (policy.as == .text and !validText(Backend, span.bytes)) return error.InvalidUtf8;
                var array: if (@typeInfo(T) == .array) T else [i.len]i.child = undefined;
                @memcpy(&array, span.bytes);
                if (@typeInfo(T) == .array) if (i.sentinel()) |sentinel| {
                    array[i.len] = sentinel;
                };
                return array;
            }
            const header = try self.start(.tuple);
            defer self.context.leave();
            if (header.len) |n| if (n != i.len) return error.UnexpectedType;
            var array: if (@typeInfo(T) == .array) T else [i.len]i.child = undefined;
            if (@typeInfo(T) == .array) if (i.sentinel()) |sentinel| {
                array[i.len] = sentinel;
            };
            for (&array, 0..) |*element, index| {
                const mark: ctx.Diagnostics.Checkpoint = if (self.context.diagnostics) |d| d.checkpoint() else .none;
                if (self.context.diagnostics) |d| d.index(index);
                if (comptime @TypeOf(prior) == *const T) {
                    element.* = prior[index];
                    try self.readInto(i.child, .{ .name = "" }, element);
                } else element.* = try self.readFresh(i.child, .{ .name = "" });
                if (self.context.diagnostics) |d| d.restore(mark);
            }
            try self.end();
            return array;
        }
        /// A name the format spells apart from text where it can: an enum's.
        /// A value's text, for a type that reads its own (an aegis duration or size).
        fn textValue(self: *Self) Error![]const u8 {
            const direct_text = if (comptime @hasDecl(Backend, "text")) try self.direct("text") else null;
            const span = direct_text orelse switch (try self.take()) {
                .text => |s| s,
                else => return error.UnexpectedType,
            };
            try self.context.span(span.bytes.len, false);
            try self.context.chargeWork(span.bytes.len);
            if (!validText(Backend, span.bytes)) return error.InvalidUtf8;
            return span.bytes;
        }
        fn symbolValue(self: *Self) Error![]const u8 {
            self.request = .{ .expected = .symbol };
            const direct_text = if (comptime @hasDecl(Backend, "text")) try self.direct("text") else null;
            const span = direct_text orelse switch (try self.take()) {
                .text => |s| s,
                else => return error.UnexpectedType,
            };
            try self.context.span(span.bytes.len, false);
            try self.context.chargeWork(span.bytes.len);
            if (!validText(Backend, span.bytes)) return error.InvalidUtf8;
            return span.bytes;
        }
        fn keyValue(self: *Self) Error![]const u8 {
            return (try self.keySpan()).bytes;
        }
        fn keySpan(self: *Self) Error!model.Span {
            self.request = .{ .expected = .text };
            const event = try self.take();
            if (event != .text) return error.UnexpectedType;
            try self.context.span(event.text.bytes.len, false);
            try self.context.chargeWork(event.text.bytes.len);
            if (!validText(Backend, event.text.bytes)) return error.InvalidUtf8;
            return event.text;
        }
        /// A slice: text, bytes or a sequence. A sequence read into `prior`, a
        /// `T` or `null` known when compiled, reads each element into the one
        /// at its position there, and the rest afresh.
        fn slice(self: *Self, comptime T: type, comptime policy: descriptor.Field, prior: anytype) Errors(T, Backend)!T {
            const i = @typeInfo(T).pointer;
            if (i.child == u8) {
                const direct_text = if (comptime @hasDecl(Backend, "text")) (if (policy.as != .bytes) try self.direct("text") else null) else null;
                const bytes = direct_text orelse switch (try self.take()) {
                    .text => |s| if (policy.as == .bytes) return error.UnexpectedType else s,
                    .bytes => |s| if (policy.as != .bytes) return error.UnexpectedType else s,
                    else => return error.UnexpectedType,
                };
                if (bytes.bytes.len > policy.max_len) return error.LengthLimit;
                try self.context.span(bytes.bytes.len, false);
                try self.context.chargeWork(bytes.bytes.len);
                if (policy.as != .bytes and !validText(Backend, bytes.bytes)) return error.InvalidUtf8;
                if (i.attrs.@"const" and i.sentinel() == null and (i.attrs.@"align" orelse 1) == 1) return self.context.retain(bytes.bytes, bytes.lifetime, policy.borrow);
                if (policy.borrow == .require) return error.BorrowUnavailable;
                try self.context.chargeWork(bytes.bytes.len);
                const storage = try self.context.allocPointer(T, bytes.bytes.len);
                @memcpy(storage, bytes.bytes);
                return storage;
            }
            const header = try self.start(.sequence);
            defer self.context.leave();
            if (header.len) |n| {
                if (n > policy.max_len) return error.LengthLimit;
                const values = try self.context.allocPointer(T, n);
                for (values, 0..) |*v, k| try self.readElement(T, prior, k, v);
                try self.end();
                return values;
            }
            var values = try self.context.allocPointer(T, 0);
            var initialized: usize = 0;
            while (!try self.atEnd()) {
                if (initialized >= policy.max_len or initialized >= self.context.limits.container_items) return error.LengthLimit;
                try self.context.count(1);
                if (initialized == values.len) {
                    const capacity = try ctx.Context.grownCapacity(values.len, @min(policy.max_len, self.context.limits.container_items));
                    const grown = try self.context.allocPointer(T, capacity);
                    try self.context.chargeWork(initialized);
                    @memcpy(grown[0..initialized], values[0..initialized]);
                    values = grown;
                }
                try self.readElement(T, prior, initialized, &values[initialized]);
                initialized += 1;
            }
            try self.end();
            if (i.sentinel()) |sentinel| {
                values.ptr[initialized] = sentinel;
                return values[0..initialized :sentinel];
            }
            return values[0..initialized];
        }
        /// A sequence's element at `k`: read into `prior`'s at `k` where
        /// there is one, else afresh.
        inline fn readElement(self: *Self, comptime T: type, prior: anytype, k: usize, slot: *@typeInfo(T).pointer.child) Errors(T, Backend)!void {
            const E = @typeInfo(T).pointer.child;
            if (comptime @TypeOf(prior) == T) if (k < prior.len) {
                slot.* = prior[k];
                return self.readInto(E, .{}, slot);
            };
            slot.* = try self.readFresh(E, .{});
        }
        /// A field read into what it holds; one with a codec of its own is
        /// read afresh.
        inline fn readFieldInto(self: *Self, comptime T: type, comptime name: []const u8, into: *@FieldType(T, name)) Errors(T, Backend)!void {
            const declared = comptime descriptor.fieldOptions(T, name);
            if (@hasField(@TypeOf(declared), "codec")) {
                into.* = try self.readField(T, name);
                return;
            }
            try self.readInto(@FieldType(T, name), comptime descriptor.field(T, name), into);
            try descriptor.validate(T, name, into.*);
        }
        inline fn readField(self: *Self, comptime T: type, comptime name: []const u8) Errors(T, Backend)!@FieldType(T, name) {
            const declared = comptime descriptor.fieldOptions(T, name);
            const value = if (@hasField(@TypeOf(declared), "codec")) blk: {
                try self.context.node();
                var access: PolicyAccess(Backend, descriptor.field(T, name)) = .{ .cursor = self };
                const result = try declared.codec.decode(&access);
                if (!access.used or !access.complete) return error.CustomRejected;
                break :blk result;
            } else try self.read(@FieldType(T, name), comptime descriptor.field(T, name));
            try descriptor.validate(T, name, value);
            return value;
        }
        /// A record of `T` read into `value`: `fresh`, a field no member gives
        /// takes its default; else into what `value` holds, each member merging
        /// with its field (`Duplicates.merge`).
        fn record(self: *Self, comptime T: type, value: *T, fresh: bool) Errors(T, Backend)!void {
            const opt = comptime descriptor.options(T);
            const declared: descriptor.Duplicates = if (@hasField(@TypeOf(opt), "duplicates")) opt.duplicates else .reject;
            const duplicates = self.context.acceptance.duplicates orelse declared;
            // A strict reading takes the path that knows nothing of merging
            // or kept nulls, so that it pays for neither.
            if (fresh and duplicates != .merge and self.context.acceptance.nulls != .keep) return self.recordWith(T, value, true, duplicates, false);
            return self.recordWith(T, value, fresh, duplicates, true);
        }
        fn recordWith(self: *Self, comptime T: type, value: *T, fresh: bool, duplicates: descriptor.Duplicates, comptime lenient: bool) Errors(T, Backend)!void {
            const i = @typeInfo(T).@"struct";
            const opt = comptime descriptor.options(T);
            const acceptance = self.context.acceptance;
            const unknown: descriptor.Unknown = if (acceptance.reject_unknown_fields) .reject else if (@hasField(@TypeOf(opt), "unknown_fields")) opt.unknown_fields else .ignore;
            const header = try self.start(.record);
            defer self.context.leave();
            // `given`: a member named the field in this record. `filled`: the
            // field holds a value, which a record read fresh otherwise takes
            // from its default; it is `given` but where a lenient reading
            // keeps a null or merges into a value already there.
            var given: [i.field_names.len]bool = @splat(false);
            var filled: if (lenient) [i.field_names.len]bool else void = if (lenient) @splat(!fresh) else {};
            // A record's keys are checked here, not by the format: the known
            // ones by `given`, the ignored ones by name.
            var ignored: Ignored = .{};
            var pairs: usize = 0;
            var hint: usize = 0;
            // The diagnostics an operation keeps are fixed for its length.
            const diagnostics = self.context.diagnostics;
            while (try self.recordMember(T, hint)) |entry| {
                const name = entry.name;
                // The key's node was counted as it was read; the container's
                // own bound is the pairs it holds.
                if (pairs >= self.context.limits.container_items) return error.ItemLimit;
                pairs += 1;
                if (entry.field) |found| switch (found) {
                    inline 0...@max(i.field_names.len, 1) - 1 => |index| {
                        // Only a declared field is named.
                        if (comptime index >= i.field_names.len) unreachable;
                        hint = comptime MemberNames(T).next[index];
                        const field_name = i.field_names[index];
                        const F = i.field_types[index];
                        const f = comptime descriptor.field(T, field_name);
                        const again = given[index];
                        if (again and duplicates == .reject) {
                            if (diagnostics) |d| d.field(field_name);
                            return error.DuplicateField;
                        }
                        if (comptime i.field_attrs[index].@"comptime") {
                            // A constant of the type: the member, when it is
                            // there, holds that value or the record is not one.
                            const found_value = try self.read(F, f);
                            if (!descriptor.same(F, found_value, @field(@as(T, undefined), field_name))) {
                                if (diagnostics) |d| d.field(field_name);
                                return error.UnexpectedType;
                            }
                            if (lenient) filled[index] = true;
                        } else if (f.skip_decode or (again and duplicates == .first)) {
                            try self.skip();
                        } else if (lenient and try self.keptByNull(F, f)) {
                            // `Nulls.keep`: the field keeps what it holds, or is
                            // emptied.
                            if (comptime emptiedByNull(F)) {
                                @field(value, field_name) = try self.zero(F);
                                filled[index] = true;
                            }
                        } else if (lenient and filled[index] and ((again and duplicates == .merge) or (!again and !fresh))) {
                            // A field that holds a value merges with it where
                            // the member comes again under `merge`, or where the
                            // record is itself read into what it holds. Through a
                            // copy: a packed record's field has no address.
                            const mark: ctx.Diagnostics.Checkpoint = if (diagnostics) |d| d.checkpoint() else .none;
                            if (diagnostics) |d| d.field(field_name);
                            var held = @field(value, field_name);
                            try self.readFieldInto(T, field_name, &held);
                            @field(value, field_name) = held;
                            if (diagnostics) |d| d.restore(mark);
                        } else if (diagnostics) |d| {
                            const mark = d.checkpoint();
                            d.field(field_name);
                            @field(value, field_name) = try self.readField(T, field_name);
                            d.restore(mark);
                            if (lenient) filled[index] = true;
                        } else {
                            @field(value, field_name) = try self.readField(T, field_name);
                            if (lenient) filled[index] = true;
                        }
                        given[index] = !f.skip_decode;
                    },
                    else => unreachable,
                } else {
                    if (unknown == .reject) {
                        if (self.context.diagnostics) |d| d.field(name);
                        return error.UnknownField;
                    }
                    if (acceptance.duplicates == .reject) try ignored.add(self.context, name);
                    try self.skip();
                }
            }
            if (header.len) |n| if (n != pairs) return error.SyntaxError;
            if (lenient and !fresh) return;
            inline for (i.field_names, i.field_attrs, 0..) |name, attrs, index| {
                if (attrs.@"comptime") continue;
                if (!(if (lenient) filled[index] else given[index])) {
                    const mark: ctx.Diagnostics.Checkpoint = if (self.context.diagnostics) |d| d.checkpoint() else .none;
                    if (self.context.diagnostics) |d| {
                        d.offset = self.backend.offset();
                        d.field(name);
                    }
                    @field(value, name) = try self.defaultOf(T, name);
                    try descriptor.validate(T, name, @field(value, name));
                    if (self.context.diagnostics) |d| d.restore(mark);
                }
            }
        }
        /// Whether the next value is a `null` that `Nulls.keep` takes for a
        /// value of `F`, which has no null of its own: taken and counted, as
        /// `read` counts a value, if so.
        inline fn keptByNull(self: *Self, comptime F: type, comptime policy: descriptor.Field) Error!bool {
            if (comptime readsNull(F)) return false;
            if (self.context.acceptance.nulls != .keep) return false;
            self.request = typeRequest(F, policy);
            if (!try self.takeNull()) return false;
            try self.context.node();
            try self.context.chargeWork(1);
            return true;
        }
        /// Every ignored value still traverses the complete wire structure.
        pub fn skip(self: *Self) Error!void {
            @setRuntimeSafety(true);
            // A format that passes over a value itself, checked and charged
            // as the events below would be, does it without them.
            if (comptime @hasDecl(Backend, "pass")) if (self.pending == null) {
                if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                const passed = self.backend.pass(self.context) catch |err| {
                    if (self.context.diagnostics) |d| d.offset = self.backend.offset();
                    return err;
                };
                if (passed) {
                    self.first_event = false;
                    return;
                }
            };
            try self.context.node();
            try self.context.chargeWork(1);
            // Whatever the last request was, an ignored value may be anything.
            self.request = .{};
            switch (try self.take()) {
                .end => return error.SyntaxError,
                // A tag belongs to the value after it, which goes with it.
                .tag => return self.skip(),
                .simple => {},
                .text => |span| {
                    try self.context.span(span.bytes.len, false);
                    try self.context.chargeWork(span.bytes.len);
                    if (!validText(Backend, span.bytes)) return error.InvalidUtf8;
                },
                .bytes => |span| {
                    try self.context.span(span.bytes.len, false);
                    try self.context.chargeWork(span.bytes.len);
                },
                .scalar => |v| if (!std.unicode.utf8ValidCodepoint(v)) return error.InvalidUtf8,
                .floating => |v| if (!Backend.capabilities.nonfinite_floats and !std.math.isFinite(v)) return error.UnsupportedValue,
                .number => |n| {
                    if (limit.exceeds(n.bytes.len, self.context.limits.numeric_bytes)) return error.LengthLimit;
                    try self.context.chargeWork(n.bytes.len);
                },
                .integer => |n| {
                    if (limit.exceeds(n.magnitude.len, self.context.limits.numeric_bytes)) return error.LengthLimit;
                    try self.context.chargeWork(n.magnitude.len);
                },
                .begin => |header| {
                    if (header.len == null and !Backend.capabilities.indefinite_containers) return error.UnsupportedValue;
                    try self.context.span(header.name.len, false);
                    try self.context.chargeWork(header.name.len);
                    if (!std.unicode.utf8ValidateSlice(header.name)) return error.InvalidUtf8;
                    try self.context.enter();
                    defer self.context.leave();
                    if (header.len) |n| try self.context.count(n);
                    var count: usize = 0;
                    while (!try self.atEnd()) {
                        if (count >= self.context.limits.container_items) return error.ItemLimit;
                        count += 1;
                        if (header.kind == .record) _ = try self.key();
                        if (header.kind == .map) {
                            const key_event = try self.peek();
                            if (key_event == .text) try self.context.span(key_event.text.bytes.len, true);
                            if (key_event == .bytes) try self.context.span(key_event.bytes.bytes.len, true);
                            try self.skip();
                        }
                        try self.skip();
                    }
                    if (header.len) |n| if (count != n) return error.SyntaxError;
                    try self.end();
                },
                else => {},
            }
        }
    };
}

/// A custom codec consumes exactly one bounded data value, commonly a surrogate
/// record/tuple/newtype. A second read or no read is rejected. It cannot obtain
/// an unmetered token source through this contract.
pub fn Access(comptime Backend: type) type {
    return PolicyAccess(Backend, .{});
}
fn PolicyAccess(comptime Backend: type, comptime policy: descriptor.Field) type {
    return struct {
        cursor: *Cursor(Backend),
        used: bool = false,
        complete: bool = true,
        pub const Error = ctx.DecodeError || Backend.Error;
        /// The format being read: a codec whose spelling is a format's own
        /// (a TOML date, tagged in TOML and text elsewhere) asks which it is.
        pub const Format = Backend.Format;
        const Self = @This();
        /// Inspection does not consume or expose the backend. The codec must
        /// still consume exactly one value through bounded access.
        pub fn peek(self: *Self) Error!model.Event {
            return self.cursor.peek();
        }
        pub fn number(self: *Self) Error![]const u8 {
            if (self.used) return error.CustomRejected;
            self.used = true;
            const event = try self.cursor.take();
            if (event != .number) return error.UnexpectedType;
            return self.cursor.context.retain(event.number.bytes, event.number.lifetime, policy.borrow);
        }
        pub fn begin(self: *Self, kind: model.Kind) Error!PolicyCompoundAccess(Backend, policy) {
            if (self.used) return error.CustomRejected;
            self.used = true;
            self.complete = false;
            const header = try self.cursor.start(kind);
            errdefer self.cursor.context.leave();
            if (header.len) |n| if (n > policy.max_len) return error.LengthLimit;
            return .{ .access = self, .header = header };
        }
        pub fn named(self: *Self, comptime T: type, kind: model.Kind, name: []const u8) Errors(T, Backend)!T {
            var compound = try self.begin(kind);
            defer compound.abort();
            if (!try self.cursor.equals(compound.header.name, name)) return error.UnexpectedType;
            const value = try compound.elementPolicy(T, policy);
            try compound.finish();
            return value;
        }
        pub fn namedUnit(self: *Self, name: []const u8) Error!void {
            var compound = try self.begin(.named_unit);
            defer compound.abort();
            if (!try self.cursor.equals(compound.header.name, name)) return error.UnexpectedType;
            try compound.finish();
        }
        pub fn namedTuple(self: *Self, comptime T: type, name: []const u8) Errors(T, Backend)!T {
            var compound = try self.begin(.named_tuple);
            defer compound.abort();
            if (!try self.cursor.equals(compound.header.name, name)) return error.UnexpectedType;
            const result: T = switch (@typeInfo(T)) {
                .@"struct" => |i| blk: {
                    if (!i.is_tuple) @compileError("named tuple requires a tuple shape");
                    var value: T = undefined;
                    inline for (i.field_names, i.field_types, i.field_attrs) |field_name, F, attrs| if (!attrs.@"comptime") {
                        @field(value, field_name) = try compound.element(F);
                    };
                    break :blk value;
                },
                .array => |i| blk: {
                    var value: T = undefined;
                    for (0..i.len) |j| value[j] = try compound.element(i.child);
                    if (comptime i.sentinel()) |sentinel| value[i.len] = sentinel;
                    break :blk value;
                },
                .vector => |i| blk: {
                    var value: [i.len]i.child = undefined;
                    for (&value) |*v| v.* = try compound.element(i.child);
                    break :blk value;
                },
                else => @compileError("named tuple requires a fixed tuple shape"),
            };
            try compound.finish();
            return result;
        }
        pub fn bytes(self: *Self, comptime borrow: ctx.Borrow) Error![]const u8 {
            if (!Backend.capabilities.bytes) return error.UnsupportedValue;
            if (self.used) return error.CustomRejected;
            self.used = true;
            if (!self.cursor.context.replaying) self.cursor.context.items -= 1;
            const bytes_policy = comptime blk: {
                var f = policy;
                f.as = .bytes;
                if (f.borrow == .prefer) f.borrow = borrow;
                break :blk f;
            };
            return self.cursor.read([]const u8, bytes_policy);
        }
        pub fn scalar(self: *Self) Error!u21 {
            if (self.used) return error.CustomRejected;
            self.used = true;
            self.cursor.request = .{ .expected = .scalar };
            const event = try self.cursor.take();
            if (event != .scalar) return error.UnexpectedType;
            if (!std.unicode.utf8ValidCodepoint(event.scalar)) return error.InvalidUtf8;
            return event.scalar;
        }
        pub fn sequence(self: *Self, comptime T: type) Errors(T, Backend)![]T {
            var sequence_access = try self.begin(.sequence);
            defer sequence_access.abort();
            if (sequence_access.header.len) |n| {
                const result = try self.alloc(T, n);
                for (result) |*v| v.* = try sequence_access.element(T);
                try sequence_access.finish();
                return result;
            }
            var result: []T = &.{};
            var n: usize = 0;
            while (try sequence_access.hasNext()) {
                if (n >= policy.max_len) return error.LengthLimit;
                if (n >= self.cursor.context.limits.container_items) return error.ItemLimit;
                if (n == result.len) {
                    const capacity = try ctx.Context.grownCapacity(n, @min(policy.max_len, self.cursor.context.limits.container_items));
                    const grown = try self.alloc(T, capacity);
                    try self.chargeWork(n);
                    @memcpy(grown[0..n], result[0..n]);
                    result = grown;
                }
                result[n] = try sequence_access.element(T);
                n += 1;
            }
            try sequence_access.finish();
            return result[0..n];
        }
        pub fn reject(self: *Self, code: u32) error{CustomRejected} {
            return self.cursor.context.reject(code);
        }
        /// The tag on the value that follows, which the codec then reads.
        /// It does not use up the access: the tagged value is the one value.
        pub fn tag(self: *Self) Error!u64 {
            if (self.used) return error.CustomRejected;
            const event = try self.cursor.take();
            if (event != .tag) return error.UnexpectedType;
            return event.tag;
        }
        /// A format's simple value.
        pub fn simple(self: *Self) Error!u8 {
            if (self.used) return error.CustomRejected;
            self.used = true;
            const event = try self.cursor.take();
            if (event != .simple) return error.UnexpectedType;
            return event.simple;
        }
        pub fn readPairs(self: *Self, comptime K: type, comptime V: type) (Errors(K, Backend) || Errors(V, Backend))![]model.Pair(K, V) {
            return self.pairsFrom(K, V, &.{});
        }
        /// A map's entries after `prior`'s. Where the reading names a choice
        /// for a key given twice (`Acceptance.duplicates`), a key already
        /// there keeps its first value (`first`) or takes the later one read
        /// afresh (`last`, `merge`); otherwise every entry is kept, in order.
        fn pairsFrom(self: *Self, comptime K: type, comptime V: type, prior: []const model.Pair(K, V)) (Errors(K, Backend) || Errors(V, Backend))![]model.Pair(K, V) {
            const duplicates = self.cursor.context.acceptance.duplicates;
            const unique = duplicates != null and duplicates.? != .reject;
            var map = try self.begin(.map);
            defer map.abort();
            var storage: []model.Pair(K, V) = &.{};
            var n: usize = 0;
            if (prior.len != 0) {
                storage = try self.alloc(model.Pair(K, V), prior.len);
                try self.chargeWork(prior.len);
                @memcpy(storage, prior);
                n = prior.len;
            }
            while (try map.hasNext()) {
                if (n >= policy.max_len) return error.LengthLimit;
                if (n >= self.cursor.context.limits.container_items) return error.ItemLimit;
                const key = try map.key(K);
                if (unique) if (try self.entryOf(K, V, storage[0..n], key)) |entry| {
                    if (duplicates.? == .first) {
                        _ = try map.hold();
                    } else {
                        entry.value = try map.element(V);
                    }
                    continue;
                };
                if (n == storage.len) {
                    const capacity = try ctx.Context.grownCapacity(n, @min(policy.max_len, self.cursor.context.limits.container_items));
                    const next = try self.alloc(model.Pair(K, V), capacity);
                    try self.chargeWork(n);
                    @memcpy(next[0..n], storage[0..n]);
                    storage = next;
                }
                storage[n] = .{ .key = key, .value = try map.element(V) };
                n += 1;
            }
            try map.finish();
            return storage[0..n];
        }
        /// The entry of `entries` whose key is `key`, each comparison charged.
        fn entryOf(self: *Self, comptime K: type, comptime V: type, entries: []model.Pair(K, V), key: K) ctx.DecodeError!?*model.Pair(K, V) {
            for (entries) |*entry| {
                try self.chargeWork(if (comptime @typeInfo(K) == .pointer and @typeInfo(K).pointer.size == .slice) @min(key.len, entry.key.len) + 1 else 1);
                if (descriptor.same(K, entry.key, key)) return entry;
            }
            return null;
        }
        pub fn read(self: *Self, comptime T: type) Errors(T, Backend)!T {
            if (self.used) return error.CustomRejected;
            self.used = true;
            if (!self.cursor.context.replaying) self.cursor.context.items -= 1;
            return self.cursor.read(T, policy);
        }
        pub fn alloc(self: *Self, comptime T: type, n: usize) ctx.DecodeError![]T {
            return self.cursor.context.alloc(T, n);
        }
        pub fn chargeWork(self: *Self, n: usize) ctx.DecodeError!void {
            try self.cursor.context.chargeWork(n);
        }
        pub fn raw(self: *Self, comptime Brand: type) (ctx.DecodeError || Backend.Error)![]const u8 {
            if (Backend.Format != Brand) @compileError("raw format brand does not match the backend");
            if (self.used) return error.CustomRejected;
            self.used = true;
            const start = if (self.cursor.pending != null) self.cursor.pending_start else self.cursor.backend.offset();
            if (!self.cursor.context.replaying) self.cursor.context.items -= 1;
            try self.cursor.skip();
            const span = self.cursor.backend.raw(start, self.cursor.backend.offset());
            if (span.bytes.len > policy.max_len) return error.LengthLimit;
            return self.cursor.context.retain(span.bytes, span.lifetime, policy.borrow);
        }
        pub fn skip(self: *Self) (ctx.DecodeError || Backend.Error)!void {
            if (self.used) return error.CustomRejected;
            self.used = true;
            if (!self.cursor.context.replaying) self.cursor.context.items -= 1;
            try self.cursor.skip();
        }
    };
}

/// Checked copying for defaults; result storage belongs to the same arena.
pub fn clone(comptime T: type, value: T, c: *ctx.Context) ctx.DecodeError!T {
    return cloneField(T, .{}, value, c);
}
fn cloneField(comptime T: type, comptime policy: descriptor.Field, value: T, c: *ctx.Context) ctx.DecodeError!T {
    @setRuntimeSafety(true);
    try c.enter();
    defer c.leave();
    try c.chargeWork(1);
    try c.node();
    switch (@typeInfo(T)) {
        .pointer => |i| switch (i.size) {
            .one => {
                const result = try c.allocPointer(T, 1);
                result.* = try clone(i.child, value.*, c);
                return result;
            },
            .slice => {
                if (value.len > policy.max_len) return error.LengthLimit;
                try c.count(value.len);
                if (i.child == u8) {
                    try c.span(value.len, false);
                    try c.chargeWork(value.len);
                    if (policy.as != .bytes and !std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
                }
                const result = try c.allocPointer(T, value.len);
                for (result, value) |*to, from| to.* = try clone(i.child, from, c);
                return result;
            },
            else => unreachable,
        },
        .optional => |i| return if (value) |v| try clone(i.child, v, c) else null,
        .@"struct" => |i| {
            var result = value;
            inline for (i.field_names, i.field_types, i.field_attrs) |name, F, attrs| if (!attrs.@"comptime") {
                @field(result, name) = try cloneField(F, comptime descriptor.field(T, name), @field(value, name), c);
                try descriptor.validate(T, name, @field(result, name));
            };
            return result;
        },
        .array => |i| {
            var result = value;
            for (&result) |*v| v.* = try clone(i.child, v.*, c);
            return result;
        },
        .vector => |i| {
            var result: [i.len]i.child = value;
            for (&result) |*v| v.* = try clone(i.child, v.*, c);
            return result;
        },
        .@"union" => return switch (value) {
            inline else => |v, tag| @unionInit(T, @tagName(tag), try clone(@TypeOf(v), v, c)),
        },
        else => return value,
    }
}

fn Errors(comptime T: type, comptime Backend: type) type {
    @setEvalBranchQuota(1_000_000);
    return ctx.DecodeError || Backend.Error || HookErrors(T, Backend, &.{});
}
fn HookErrors(comptime T: type, comptime Backend: type, comptime seen: []const type) type {
    for (seen) |prior| if (T == prior) return error{};
    const next = seen ++ .{T};
    if (descriptor.has(T, "strandDeserialize")) {
        const result = @TypeOf(T.strandDeserialize(@as(*Access(Backend), undefined)));
        const errors = @typeInfo(result).error_union.error_set;
        if (@typeInfo(errors).error_set.error_names == null) @compileError("data codecs require a named error set");
        return errors;
    }
    return switch (@typeInfo(T)) {
        inline .pointer, .optional, .array, .vector => |i| HookErrors(i.child, Backend, next),
        inline .@"struct", .@"union" => |i| blk: {
            var errors: type = error{};
            for (i.field_types, i.field_names) |F, name| {
                const opt = descriptor.fieldOptions(T, name);
                if (@hasField(@TypeOf(opt), "codec") and @hasDecl(opt.codec, "decode")) errors = errors || @typeInfo(@TypeOf(opt.codec.decode(@as(*Access(Backend), undefined)))).error_union.error_set else errors = errors || HookErrors(F, Backend, next);
                if (@hasField(@TypeOf(opt), "default") and @typeInfo(@TypeOf(opt.default)) == .@"fn") errors = errors || @typeInfo(@TypeOf(opt.default(@as(*ctx.Context, undefined)))).error_union.error_set;
            }
            if (@typeInfo(errors).error_set.error_names == null) @compileError("field codecs and defaults require named errors");
            break :blk errors;
        },
        else => error{},
    };
}

/// A validated internal-tag replay suppresses exactly the routing key/value.
fn Filtered(comptime Backend: type) type {
    return struct {
        backend: *Backend,
        tag: []const u8,
        level: usize = 0,
        key_turn: bool = true,
        pub const Error = Backend.Error;
        pub const Format = Backend.Format;
        pub const capabilities = Backend.capabilities;
        const Self = @This();
        pub fn parseInteger(comptime T: type, spelling: []const u8, c: *ctx.Context) ctx.DecodeError!T {
            if (comptime @hasDecl(Backend, "parseInteger")) return Backend.parseInteger(T, spelling, c);
            return error.UnexpectedType;
        }
        pub fn parseFloat(comptime T: type, spelling: []const u8, exact: bool, c: *ctx.Context) ctx.DecodeError!T {
            if (comptime @hasDecl(Backend, "parseFloat")) return Backend.parseFloat(T, spelling, exact, c);
            return error.UnexpectedType;
        }
        pub fn offset(self: *const Self) usize {
            return self.backend.offset();
        }
        pub fn endInput(self: *Self, c: *ctx.Context) Error!void {
            try self.backend.endInput(c);
        }
        pub fn raw(self: *const Self, start: usize, end: usize) model.Span {
            return self.backend.raw(start, end);
        }
        pub const Replayed = Backend;
        pub fn replay(self: *const Self, into: *Backend, start: usize, end: usize) void {
            self.backend.replay(into, start, end);
        }
        pub fn next(self: *Self, c: *ctx.Context, request: model.Request) (ctx.DecodeError || Error)!model.Event {
            while (true) {
                var event = try self.backend.next(c, request);
                if (self.level == 1 and self.key_turn and event == .text) {
                    try c.chargeWork(event.text.bytes.len);
                    if (std.mem.eql(u8, event.text.bytes, self.tag)) {
                        _ = try self.backend.next(c, request);
                        continue;
                    }
                    self.key_turn = false;
                } else if (self.level == 1 and event != .end) self.key_turn = true;
                if (event == .begin) {
                    if (self.level == 0) if (event.begin.len) |n| {
                        event.begin.len = n - 1;
                    };
                    self.level += 1;
                } else if (event == .end) {
                    self.level -= 1;
                }
                return event;
            }
        }
    };
}

/// Bounded compound visitor: every member is read through the same kernel;
/// finishing validates the declared arity and consumes the explicit end marker.
pub fn CompoundAccess(comptime Backend: type) type {
    return PolicyCompoundAccess(Backend, .{});
}
fn PolicyCompoundAccess(comptime Backend: type, comptime policy: descriptor.Field) type {
    return struct {
        access: *PolicyAccess(Backend, policy),
        header: model.Compound,
        count: usize = 0,
        key_pending: bool = false,
        live: bool = true,
        pub const Error = ctx.DecodeError || Backend.Error;
        const Self = @This();
        pub fn hasNext(self: *Self) Error!bool {
            if (!self.live or self.key_pending) return error.CustomRejected;
            return !try self.access.cursor.atEnd();
        }
        pub fn key(self: *Self, comptime T: type) Errors(T, Backend)!T {
            if (!self.live or self.key_pending or (self.header.kind != .map and self.header.kind != .record)) return error.CustomRejected;
            if (self.count >= policy.max_len) return error.LengthLimit;
            if (self.count >= self.access.cursor.context.limits.container_items) return error.ItemLimit;
            self.key_pending = true;
            // The key is looked at as what it is read as: a format whose
            // events follow the type (YAML's plain scalars) makes it that.
            if (self.access.cursor.pending == null) self.access.cursor.request = typeRequest(T, .{});
            const event = try self.access.cursor.peek();
            if (event == .text) try self.access.cursor.context.span(event.text.bytes.len, true);
            if (event == .bytes) try self.access.cursor.context.span(event.bytes.bytes.len, true);
            return self.access.cursor.read(T, .{});
        }
        pub fn element(self: *Self, comptime T: type) Errors(T, Backend)!T {
            return self.elementPolicy(T, .{});
        }
        fn elementPolicy(self: *Self, comptime T: type, comptime field_policy: descriptor.Field) Errors(T, Backend)!T {
            if (!self.live or ((self.header.kind == .map or self.header.kind == .record) and !self.key_pending)) return error.CustomRejected;
            if (self.count >= policy.max_len) return error.LengthLimit;
            if (self.count >= self.access.cursor.context.limits.container_items) return error.ItemLimit;
            self.key_pending = false;
            self.count += 1;
            return self.access.cursor.readFresh(T, field_policy);
        }
        /// Where a member's value lies, checked and passed over, to be read
        /// later by `readHeld`: a value whose type depends on a member that
        /// comes after it.
        pub const Held = struct { start: usize, end: usize };
        /// Passes over the next member's value, checked and counted as any
        /// value is, and says where it lies.
        pub fn hold(self: *Self) Error!Held {
            if (!self.live or ((self.header.kind == .map or self.header.kind == .record) and !self.key_pending)) return error.CustomRejected;
            if (self.count >= policy.max_len) return error.LengthLimit;
            if (self.count >= self.access.cursor.context.limits.container_items) return error.ItemLimit;
            self.key_pending = false;
            self.count += 1;
            const cursor = self.access.cursor;
            const start = if (cursor.pending != null) cursor.pending_start else cursor.backend.offset();
            try cursor.skip();
            return .{ .start = start, .end = cursor.backend.offset() };
        }
        /// A held value, read as a `T`. Its bytes and nodes were counted when
        /// it was held; reading it again costs work and allocation only.
        pub fn readHeld(self: *Self, comptime T: type, held: Held) Errors(T, Backend)!T {
            const cursor = self.access.cursor;
            const was_replaying = cursor.context.replaying;
            cursor.context.replaying = true;
            defer cursor.context.replaying = was_replaying;
            var backend: Replayed(Backend) = undefined;
            cursor.backend.replay(&backend, held.start, held.end);
            defer if (@hasDecl(Replayed(Backend), "deinit")) backend.deinit();
            return deserialize(T, &backend, cursor.context);
        }
        pub fn finish(self: *Self) Error!void {
            if (!self.live or self.key_pending) return error.CustomRejected;
            if (self.header.len) |n| if (n != self.count) return error.SyntaxError;
            try self.access.cursor.end();
            self.access.complete = true;
            self.abort();
        }
        pub fn abort(self: *Self) void {
            if (self.live) {
                self.access.cursor.context.leave();
                self.live = false;
            }
        }
    };
}

fn expectedKind(comptime T: type, comptime policy: descriptor.Field) ctx.Diagnostics.Expected {
    if (comptime scalars.kind(T)) |k| return if (k == .text) .text else .integer;
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int => .integer,
        .float => .floating,
        // A presence hint asks for what the value is, unless the value is a presence itself.
        .optional => |i| if (@typeInfo(i.child) == .optional) .option else expectedKind(i.child, policy),
        .void, .null => .unit,
        .pointer => |i| if (i.size == .one) expectedKind(i.child, policy) else if (i.child == u8) (if (policy.as == .bytes) .bytes else .text) else .sequence,
        .array, .vector => .tuple,
        .@"struct" => |i| if (i.is_tuple) .tuple else .record,
        .@"enum" => .symbol,
        .@"union" => .variant,
        else => .unknown,
    };
}

fn typeRequest(comptime T: type, comptime policy: descriptor.Field) model.Request {
    var result: model.Request = .{ .expected = expectedKind(T, policy), .exact = policy.exact, .borrow = policy.borrow };
    if (comptime scalars.kind(T)) |k| {
        if (k != .text) result.integer_bits = @typeInfo(scalars.Representation(T)).int.bits;
        return result;
    }
    switch (@typeInfo(T)) {
        .int => |i| result.integer_bits = i.bits,
        .float => |i| result.float_bits = i.bits,
        .optional => |i| {
            const child = typeRequest(i.child, policy);
            result.integer_bits = child.integer_bits;
            result.float_bits = child.float_bits;
            result.nullable = true;
        },
        .pointer => |i| if (i.size == .one) {
            const child = typeRequest(i.child, policy);
            result.integer_bits = child.integer_bits;
            result.float_bits = child.float_bits;
        },
        else => {},
    }
    return result;
}
