//! JSON text as immediate core events, read in one pass straight off the
//! input: no token tape, no tokenizer state machine between the bytes and the
//! event. A container's frame says what may come next in it; a string is found
//! a vector at a time and borrowed from the input unless it has an escape.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const numbers = @import("number.zig");
const strings = @import("text.zig");
const format = enum { json };
const capabilities_of: core.Capabilities = .{ .map_keys = .text_only, .bytes = false, .named_shapes = false, .nonfinite_floats = false, .variant_record = true, .max_integer_bits = std.math.maxInt(usize), .utf8_text = true };

/// The decoder of a dialect: JSON, or with `jsonc` JSONC, whose comments
/// (`//`, `/* */`) are whitespace and whose containers may end in a comma.
/// The dialect is fixed when the type is made, so JSON pays nothing for it.
pub fn Dialect(comptime jsonc: bool) type {
    return struct {
        pub const Format = format;
        pub const Error = core.DecodeError;
        pub const capabilities = capabilities_of;
        pub const parseInteger = numbers.integer;
        pub const parseFloat = numbers.floating;
        /// Where a container is: what its next byte may be.
        const State = enum(u8) {
            /// Just opened: a member, or the close.
            first,
            /// After a comma: a member.
            member,
            /// After a key and its colon: the value.
            value,
            /// After a member: a comma or the close.
            after,
        };
        /// `check_keys`: whether this object's keys are remembered to refuse one given
        /// twice. An object read as a typed record is not: mapping checks its keys.
        const Frame = struct { object: bool, check_keys: bool, state: State, key_start: usize };

        input: []const u8,
        /// The next unread byte, whitespace already passed over.
        at: usize,
        /// Where the last token ended, before the whitespace after it.
        last_end: usize,
        allocator: std.mem.Allocator,
        frames: [128]Frame,
        extra: std.ArrayList(Frame),
        depth: usize,
        keys: [128][]const u8,
        extra_keys: std.ArrayList([]const u8),
        key_count: usize,
        /// What the reading accepts of the text: whether an object's keys are
        /// checked for one given twice, and what text that is not Unicode is.
        accepting: Accepting,
        root_done: bool,
        /// Whether the input is only being checked, as a value about to be written
        /// as it is: a string with an escape in it is checked and its length
        /// counted, and not unescaped, since nothing will read it; keys are told
        /// apart by what they spell, escapes read as they go.
        checking: bool,
        const Self = @This();
        const Accepting = struct { reject_duplicates: bool, unicode: strings.Unicode };

        /// Starts `self` over `bytes`, which the caller has charged to `c.input`. It
        /// is built where it lies, field by field: its frames and keys are kilobytes
        /// that a struct literal would build elsewhere and copy, unread.
        pub fn init(self: *Self, c: *core.Context, bytes: []const u8) void {
            self.begin(bytes, 0, c.allocator(), .{
                .reject_duplicates = c.acceptance.duplicates == .reject,
                .unicode = c.acceptance.invalid_unicode,
            });
        }
        /// Starts over `bytes`, reading from where the whitespace after `from` ends.
        fn begin(self: *Self, bytes: []const u8, from: usize, allocator: std.mem.Allocator, accepting: Accepting) void {
            self.input = bytes;
            self.at = self.space(from);
            self.last_end = self.at;
            self.allocator = allocator;
            self.extra = .empty;
            self.depth = 0;
            self.extra_keys = .empty;
            self.key_count = 0;
            self.accepting = accepting;
            self.root_done = false;
            self.checking = false;
        }
        pub fn deinit(self: *Self) void {
            self.extra.deinit(self.allocator);
            self.extra_keys.deinit(self.allocator);
            self.* = undefined;
        }
        /// Where the next token begins, or the comma before it.
        pub fn offset(self: *const Self) usize {
            return self.at;
        }
        /// A value's bytes, without the separator and whitespace before it or the
        /// whitespace after it. `end` is where the next token begins; the value ended
        /// where the last one did.
        pub fn raw(self: *const Self, start: usize, end: usize) core.Span {
            const from = self.leading(start);
            const to = if (end == self.at) self.last_end else end;
            return .{ .bytes = self.input[from..@max(from, to)], .lifetime = .borrowed };
        }
        /// Starts `into` over a value already read, as the root of its own input.
        pub fn replay(self: *const Self, into: *Self, from: usize, end: usize) void {
            const bounded = self.input[0..end];
            into.begin(bounded, from, self.allocator, self.accepting);
            into.at = into.leading(from);
            into.last_end = into.at;
        }
        /// Where the root value ended, for a reader that takes a value from the front
        /// of its input and leaves the rest.
        pub fn rootEnd(self: *const Self) ?usize {
            return if (self.root_done) self.last_end else null;
        }

        fn blank(bytes: []const u8, from: usize) usize {
            var at = from;
            while (at < bytes.len) : (at += 1) switch (bytes[at]) {
                ' ', '\t', '\r', '\n' => {},
                else => break,
            };
            return at;
        }
        /// Past the whitespace from `from`, and in JSONC the comments in it. A
        /// comment that does not end stops it at its `/`, where the next token is
        /// then a syntax error.
        inline fn space(self: *const Self, from: usize) usize {
            const at = blank(self.input, from);
            return if (jsonc) self.comments(at) else at;
        }
        fn comments(self: *const Self, from: usize) usize {
            const bytes = self.input;
            var at = from;
            while (at + 1 < bytes.len and bytes[at] == '/') {
                switch (bytes[at + 1]) {
                    '/' => at = blank(bytes, std.mem.findScalarPos(u8, bytes, at + 2, '\n') orelse bytes.len),
                    '*' => at = blank(bytes, (std.mem.findPos(u8, bytes, at + 2, "*/") orelse return at) + 2),
                    else => return at,
                }
            }
            return at;
        }
        /// Past the whitespace and one comma or colon before a value.
        fn leading(self: *const Self, from: usize) usize {
            var at = self.space(from);
            if (at < self.input.len and (self.input[at] == ',' or self.input[at] == ':')) at = self.space(at + 1);
            return at;
        }
        /// After a comma, whether a JSONC container ends there instead of going on.
        inline fn trailing(self: *const Self, object: bool) bool {
            return jsonc and self.at < self.input.len and self.input[self.at] == closer(object);
        }
        fn failure(c: *core.Context, err: anyerror) Error {
            return switch (err) {
                error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
                else => error.SyntaxError,
            };
        }
        inline fn frame(self: *Self) *Frame {
            const i = self.depth - 1;
            return if (i < self.frames.len) &self.frames[i] else &self.extra.items[i - self.frames.len];
        }
        inline fn push(self: *Self, c: *core.Context, object: bool, check_keys: bool) Error!void {
            if (self.depth >= c.limits.depth) return error.DepthLimit;
            const entry: Frame = .{ .object = object, .check_keys = check_keys, .state = .first, .key_start = self.key_count };
            if (self.depth < self.frames.len) self.frames[self.depth] = entry else self.extra.append(self.allocator, entry) catch |err| return failure(c, err);
            self.depth += 1;
        }
        /// Ends a token at `to`: the whitespace after it is passed over.
        inline fn finish(self: *Self, to: usize) void {
            self.last_end = to;
            self.at = self.space(to);
        }
        fn close(self: *Self) core.Event {
            const entry = self.frame().*;
            if (self.depth > self.frames.len) _ = self.extra.pop();
            self.depth -= 1;
            self.key_count = entry.key_start;
            self.extra_keys.shrinkRetainingCapacity(entry.key_start - @min(entry.key_start, self.keys.len));
            if (self.depth == 0) self.root_done = true;
            self.finish(self.at + 1);
            return .end;
        }
        fn remember(self: *Self, c: *core.Context, name: []const u8) Error!void {
            const from = self.frame().key_start;
            for (from..self.key_count) |i| {
                const prior = if (i < self.keys.len) self.keys[i] else self.extra_keys.items[i - self.keys.len];
                try c.chargeWork(@max(name.len, prior.len));
                const same = if (self.checking) strings.sameText(name, prior, self.accepting.unicode) else std.mem.eql(u8, name, prior);
                if (same) return error.DuplicateField;
            }
            if (self.key_count < self.keys.len) self.keys[self.key_count] = name else self.extra_keys.append(self.allocator, name) catch |err| return failure(c, err);
            self.key_count += 1;
        }
        inline fn byte(self: *const Self) Error!u8 {
            return if (self.at < self.input.len) self.input[self.at] else error.SyntaxError;
        }

        /// Whether the container being read is over, without reading a member of it.
        pub fn atEnd(self: *Self) Error!bool {
            if (self.depth == 0) return false;
            const f = self.frame();
            switch (f.state) {
                .first => return try self.byte() == closer(f.object),
                .member, .value => return false,
                .after => {
                    const b = try self.byte();
                    if (b == closer(f.object)) return true;
                    if (b != ',') return error.SyntaxError;
                    self.at = self.space(self.at + 1);
                    if (self.trailing(f.object)) {
                        f.state = .first;
                        return true;
                    }
                    f.state = .member;
                    return false;
                },
            }
        }
        inline fn closer(object: bool) u8 {
            return if (object) '}' else ']';
        }

        pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
            if (self.depth == 0) {
                if (self.root_done) return error.SyntaxError;
                return self.value(c, request);
            }
            const f = self.frame();
            switch (f.state) {
                .first => if (try self.byte() == closer(f.object)) return self.close(),
                .member => {},
                .value => {
                    f.state = .after;
                    return self.value(c, request);
                },
                .after => {
                    const b = try self.byte();
                    if (b == closer(f.object)) return self.close();
                    if (b != ',') return error.SyntaxError;
                    self.at = self.space(self.at + 1);
                    if (self.trailing(f.object)) return self.close();
                },
            }
            if (f.object) {
                f.state = .value;
                return self.key(c, f.check_keys);
            }
            f.state = .after;
            return self.value(c, request);
        }

        /// The next key of the object on top, the comma before it and the colon after
        /// it taken, or `null` where the object closes, the close taken.
        pub inline fn memberKey(self: *Self, c: *core.Context) Error!?core.Span {
            const f = self.frame();
            switch (f.state) {
                .first => if (try self.byte() == '}') {
                    _ = self.close();
                    return null;
                },
                .member => {},
                .after => {
                    const b = try self.byte();
                    if (b == '}') {
                        _ = self.close();
                        return null;
                    }
                    if (b != ',') return error.SyntaxError;
                    self.at = self.space(self.at + 1);
                    if (self.trailing(true)) {
                        _ = self.close();
                        return null;
                    }
                },
                .value => return error.SyntaxError,
            }
            f.state = .value;
            return (try self.key(c, f.check_keys)).text;
        }

        /// Where one member of the object on top lies: what `memberKey` and
        /// `pass` find of it, read in one step.
        pub const MemberSpan = struct {
            /// The name's body, escapes as written.
            name: []const u8,
            /// Whether there is an escape in it.
            escaped: bool,
            /// The `,` before the member, or where the object's first member
            /// begins.
            separator: usize,
            value_start: usize,
            value_end: usize,
        };

        /// The next member of the object on top, its value passed over as
        /// `pass` passes over one, or `null` where the object closes, the close
        /// taken: `memberKey` then `pass`, checked and charged as they are, in
        /// one step whose position stays in a register for keys, numbers and
        /// words, the common members of a record.
        /// `count` is the members read so far, held to `container_items`.
        pub inline fn passMember(self: *Self, c: *core.Context, count: *usize) Error!?MemberSpan {
            const f = self.frame();
            const bytes = self.input;
            var at = self.at;
            var separator = at;
            switch (f.state) {
                .first => if (at < bytes.len and bytes[at] == '}') {
                    _ = self.close();
                    return null;
                },
                .member => {},
                .after => {
                    if (at >= bytes.len) return error.SyntaxError;
                    if (bytes[at] == '}') {
                        _ = self.close();
                        return null;
                    }
                    if (bytes[at] != ',') return error.SyntaxError;
                    separator = at;
                    at = self.space(at + 1);
                    if (jsonc and at < bytes.len and bytes[at] == '}') {
                        self.at = at;
                        _ = self.close();
                        return null;
                    }
                },
                .value => return error.SyntaxError,
            }
            // The key.
            if (at >= bytes.len or bytes[at] != '"') return error.SyntaxError;
            const body = bytes[at + 1 ..];
            const found = strings.specialNear(body) orelse strings.special(body);
            var name_len = found.at;
            var escaped = !(found.at < body.len and body[found.at] == '"');
            if (!escaped and found.non_ascii and !std.unicode.utf8ValidateSlice(body[0..found.at])) {
                if (self.accepting.unicode == .refuse) return error.SyntaxError;
                // Read again below, its bad bytes as U+FFFD.
                escaped = true;
            }
            if (!escaped) {
                try c.span(found.at, true);
            } else {
                name_len = (try strings.end(body, self.accepting.unicode)).at;
                try c.span(strings.unescapedLength(body[0..name_len], self.accepting.unicode), true);
            }
            const name = body[0..name_len];
            if (f.check_keys) try self.remember(c, name);
            if (count.* >= c.limits.container_items) return error.ItemLimit;
            count.* += 1;
            try c.node();
            try c.chargeWork(name_len);
            at = self.space(at + name_len + 2);
            if (at >= bytes.len or bytes[at] != ':') return error.SyntaxError;
            at = self.space(at + 1);
            // The value.
            f.state = .after;
            try self.passAt(c, at);
            return .{ .name = name, .escaped = escaped, .separator = separator, .value_start = at, .value_end = self.last_end };
        }

        /// A key matched against names a schema spells: which of them it is, if any,
        /// and the key itself.
        pub const Match = struct { index: ?usize, name: []const u8 };

        /// `memberKey`, matched against `names`. The one at `hint` is looked for
        /// first where the key lies, quotes and all, as a writer that keeps the
        /// schema's order puts it: when it is there, no string is read.
        pub inline fn memberOf(self: *Self, c: *core.Context, comptime names: []const []const u8, hint: usize) Error!?Match {
            const f = self.frame();
            switch (f.state) {
                .first => if (try self.byte() == '}') {
                    _ = self.close();
                    return null;
                },
                .member => {},
                .after => {
                    const b = try self.byte();
                    if (b == '}') {
                        _ = self.close();
                        return null;
                    }
                    if (b != ',') return error.SyntaxError;
                    self.at = self.space(self.at + 1);
                    if (self.trailing(true)) {
                        _ = self.close();
                        return null;
                    }
                },
                .value => return error.SyntaxError,
            }
            f.state = .value;
            if (!f.check_keys and names.len != 0) switch (hint) {
                inline 0...names.len - 1 => |h| if (comptime literal(names[h])) |quoted| {
                    const rest = self.input[self.at..];
                    if (rest.len > quoted.len and startsWith(rest, quoted)) {
                        self.finish(self.at + quoted.len);
                        if (self.at >= self.input.len or self.input[self.at] != ':') return error.SyntaxError;
                        self.at = self.space(self.at + 1);
                        return .{ .index = h, .name = names[h] };
                    }
                },
                else => {},
            };
            const name = (try self.key(c, f.check_keys)).text.bytes;
            inline for (names, 0..) |spelling, k| {
                if (name.len == spelling.len and std.mem.eql(u8, name, spelling)) return .{ .index = k, .name = name };
            }
            return .{ .index = null, .name = name };
        }
        /// Whether `bytes`, at least as long, begin with `prefix`, spelled at compile
        /// time: a short one is compared a byte at a time with no call.
        inline fn startsWith(bytes: []const u8, comptime prefix: []const u8) bool {
            if (prefix.len > 24) return std.mem.eql(u8, bytes[0..prefix.len], prefix);
            // A word at a time where the bytes run that far, masked to the prefix.
            if (bytes.len >= 8 and prefix.len <= 16) {
                const head = comptime wordOf(prefix[0..@min(prefix.len, 8)]);
                if (std.mem.readInt(u64, bytes[0..8], .little) & head.mask != head.bits) return false;
                if (prefix.len <= 8) return true;
                if (bytes.len >= 16) {
                    const tail = comptime wordOf(prefix[8..]);
                    return std.mem.readInt(u64, bytes[8..16], .little) & tail.mask == tail.bits;
                }
                inline for (prefix[8..], 8..) |b, k| if (bytes[k] != b) return false;
                return true;
            }
            inline for (prefix, 0..) |b, k| if (bytes[k] != b) return false;
            return true;
        }
        /// Up to eight bytes as a little-endian word, and the mask of the bytes there.
        fn wordOf(comptime bytes: []const u8) struct { bits: u64, mask: u64 } {
            var bits: u64 = 0;
            for (bytes, 0..) |b, k| bits |= @as(u64, b) << @intCast(k * 8);
            const mask: u64 = if (bytes.len == 8) ~@as(u64, 0) else (@as(u64, 1) << @intCast(bytes.len * 8)) - 1;
            return .{ .bits = bits, .mask = mask };
        }

        /// A name as a key spelled with no escape, quotes included; `null` for one
        /// that needs an escape, which is matched once read.
        fn literal(comptime name: []const u8) ?[]const u8 {
            for (name) |b| if (b < 0x20 or b == '"' or b == '\\') return null;
            return "\"" ++ name ++ "\"";
        }

        /// A key and the colon after it.
        inline fn key(self: *Self, c: *core.Context, check: bool) Error!core.Event {
            if (try self.byte() != '"') return error.SyntaxError;
            const name = try self.string(c, true);
            if (self.at >= self.input.len or self.input[self.at] != ':') return error.SyntaxError;
            self.at = self.space(self.at + 1);
            if (check) try self.remember(c, name.bytes);
            return .{ .text = name };
        }

        /// Moves to where the next value of the container on top begins, the comma
        /// before it taken, when that is a value and not the container's end: what
        /// `next` does before it reads a value, done for the readers below that read
        /// one kind of value without an event. False leaves `next` to say what is there.
        inline fn toValue(self: *Self) Error!bool {
            if (self.depth == 0) return !self.root_done;
            const f = self.frame();
            switch (f.state) {
                .value => {},
                .first => if (f.object or try self.byte() == ']') return false,
                .member => if (f.object) return false,
                .after => {
                    if (f.object or try self.byte() != ',') return false;
                    self.at = self.space(self.at + 1);
                    if (self.trailing(false)) {
                        f.state = .first;
                        return false;
                    }
                    f.state = .member;
                },
            }
            return true;
        }
        /// The value at the cursor is now being read.
        inline fn reading(self: *Self) void {
            if (self.depth == 0) self.root_done = true else self.frame().state = .after;
        }

        /// Opens the next value if it is the container `request` expects: an object
        /// for a record, a map or a variant, an array for a sequence or a tuple.
        /// `null`, with nothing read, for anything else.
        pub inline fn open(self: *Self, c: *core.Context, request: core.Request) Error!?@FieldType(core.Event, "begin") {
            const object = switch (request.expected) {
                .record, .map, .variant => true,
                .sequence, .tuple => false,
                else => return null,
            };
            if (!try self.toValue()) return null;
            if (try self.byte() != @as(u8, if (object) '{' else '[')) return null;
            self.reading();
            try self.push(c, object, object and self.accepting.reject_duplicates and request.expected != .record);
            self.finish(self.at + 1);
            return .{ .kind = if (!object) .sequence else if (request.expected == .map) .map else .record };
        }

        /// Whether the next value is `null`, read if it is; false, with nothing
        /// read, for anything else.
        pub inline fn none(self: *Self, c: *core.Context) Error!bool {
            _ = c;
            if (!try self.toValue()) return false;
            if (try self.byte() != 'n') return false;
            self.reading();
            _ = try self.word("null", .none);
            return true;
        }

        /// The next value's lexeme if it is a number, read; `null`, with nothing read,
        /// if it is anything else.
        pub inline fn number(self: *Self, c: *core.Context) Error!?[]const u8 {
            if (!try self.toValue()) return null;
            const b = try self.byte();
            if (b != '-' and (b < '0' or b > '9')) return null;
            self.reading();
            const from = self.at;
            const end = try numberEnd(self.input, from);
            if (limit.exceeds(end - from, c.limits.numeric_bytes)) return error.LengthLimit;
            self.finish(end);
            return self.input[from..end];
        }

        /// The next value if it is an integer spelled with digits alone that fits
        /// `T`, read and converted in the one pass; `null`, with nothing read, for any
        /// other value, which the lexeme path reads and converts or refuses.
        pub inline fn integer(self: *Self, comptime T: type, c: *core.Context) Error!?T {
            const bits = @typeInfo(T).int.bits;
            if (bits == 0 or bits > 64) return null;
            if (!try self.toValue()) return null;
            const bytes = self.input;
            var at = self.at;
            const negative = at < bytes.len and bytes[at] == '-';
            if (negative) at += 1;
            const first = at;
            var magnitude: u64 = 0;
            // Nineteen digits always fit the accumulator.
            while (at < bytes.len and at - first < 19) : (at += 1) {
                const digit = bytes[at] -% '0';
                if (digit > 9) break;
                magnitude = magnitude * 10 + digit;
            }
            const digits = at - first;
            if (digits == 0 or (bytes[first] == '0' and digits > 1)) return null;
            if (at < bytes.len) switch (bytes[at]) {
                '0'...'9', '.', 'e', 'E' => return null,
                else => {},
            };
            if (limit.exceeds(digits, c.limits.numeric_bytes)) return null;
            const result: T = if (@typeInfo(T).int.signedness == .unsigned) result: {
                // `-0` is an unsigned zero unless integers are to be written as
                // one, which the lexeme path then refuses.
                if (negative and (magnitude != 0 or c.acceptance.integers == .digits)) return null;
                break :result std.math.cast(T, magnitude) orelse return null;
            } else result: {
                if (negative) {
                    if (magnitude > @as(u64, 1) << (bits - 1)) return null;
                    break :result @intCast(-@as(i65, magnitude)); // safe: at most the magnitude of the signed minimum.
                }
                break :result std.math.cast(T, magnitude) orelse return null;
            };
            try c.chargeWork(at - self.at);
            self.reading();
            self.finish(at);
            return result;
        }

        /// The next value if it is a string, read; `null`, with nothing read, if it is
        /// anything else.
        pub inline fn text(self: *Self, c: *core.Context) Error!?core.Span {
            if (!try self.toValue()) return null;
            if (try self.byte() != '"') return null;
            self.reading();
            return try self.string(c, false);
        }

        /// Passes over the next value, checked and charged exactly as
        /// `core.Cursor.skip` checks and charges it through events, without
        /// making one: an ignored field, a `Raw` and a member of an object
        /// read on demand go by at the speed of the bytes. Nothing is
        /// unescaped, so nothing is allocated but the frames past the first
        /// 128 and the keys remembered to refuse one given twice. False, with
        /// nothing read, where there is no value to pass, which the event
        /// path then refuses.
        pub fn pass(self: *Self, c: *core.Context) Error!bool {
            if (!try self.toValue()) return false;
            self.reading();
            try self.passValue(c);
            return true;
        }
        inline fn passValue(self: *Self, c: *core.Context) Error!void {
            return self.passAt(c, self.at);
        }
        /// The value at `at`, where the cursor is or is about to be: a number or
        /// a word read with the position in a register, the rest from the cursor.
        inline fn passAt(self: *Self, c: *core.Context, at: usize) Error!void {
            const bytes = self.input;
            try c.node();
            try c.chargeWork(1);
            if (at >= bytes.len) return error.SyntaxError;
            switch (bytes[at]) {
                '-', '0'...'9' => {
                    const end = try numberEnd(bytes, at);
                    if (limit.exceeds(end - at, c.limits.numeric_bytes)) return error.LengthLimit;
                    try c.chargeWork(end - at);
                    self.last_end = end;
                    self.at = self.space(end);
                },
                't', 'f', 'n' => {
                    const spelling: []const u8 = switch (bytes[at]) {
                        't' => "true",
                        'f' => "false",
                        else => "null",
                    };
                    if (bytes.len - at < spelling.len or !std.mem.eql(u8, bytes[at..][0..spelling.len], spelling)) return error.SyntaxError;
                    self.last_end = at + spelling.len;
                    self.at = self.space(at + spelling.len);
                },
                '"' => {
                    self.at = at;
                    try self.passString(c);
                },
                '{' => {
                    self.at = at;
                    try self.passContainer(c, true);
                },
                '[' => {
                    self.at = at;
                    try self.passContainer(c, false);
                },
                else => return error.SyntaxError,
            }
        }
        /// A string passed over, its quote at the cursor: out of line, so that
        /// the vector registers its search takes are saved only around it.
        noinline fn passString(self: *Self, c: *core.Context) Error!void {
            const start = self.at + 1;
            const body = self.input[start..];
            const found = strings.specialNear(body) orelse strings.special(body);
            var len = found.at;
            var end = found.at;
            const plain = found.at < body.len and body[found.at] == '"';
            const valid = !plain or !found.non_ascii or std.unicode.utf8ValidateSlice(body[0..found.at]);
            if (!valid and self.accepting.unicode == .refuse) return error.SyntaxError;
            if (!plain or !valid) {
                end = (try strings.end(body, self.accepting.unicode)).at;
                len = strings.unescapedLength(body[0..end], self.accepting.unicode);
            }
            try c.span(len, false);
            try c.chargeWork(len);
            self.finish(start + end + 1);
        }
        /// An object or an array passed over, the bracket at the cursor.
        fn passContainer(self: *Self, c: *core.Context, object: bool) Error!void {
            try c.enter();
            defer c.leave();
            try self.push(c, object, object and self.accepting.reject_duplicates);
            self.finish(self.at + 1);
            var count: usize = 0;
            if (object) {
                while (try self.passMember(c, &count)) |_| {}
            } else {
                while (try self.passElement(c, &count)) {}
            }
        }
        /// The next element of the array on top passed over, or false where the
        /// array closes, the close taken.
        inline fn passElement(self: *Self, c: *core.Context, count: *usize) Error!bool {
            const f = self.frame();
            const bytes = self.input;
            var at = self.at;
            switch (f.state) {
                .first => if (at < bytes.len and bytes[at] == ']') {
                    _ = self.close();
                    return false;
                },
                .member => {},
                .after => {
                    if (at >= bytes.len) return error.SyntaxError;
                    if (bytes[at] == ']') {
                        _ = self.close();
                        return false;
                    }
                    if (bytes[at] != ',') return error.SyntaxError;
                    at = self.space(at + 1);
                    if (jsonc and at < bytes.len and bytes[at] == ']') {
                        self.at = at;
                        _ = self.close();
                        return false;
                    }
                },
                .value => return error.SyntaxError,
            }
            if (count.* >= c.limits.container_items) return error.ItemLimit;
            count.* += 1;
            f.state = .after;
            try self.passAt(c, at);
            return true;
        }

        fn value(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
            switch (try self.byte()) {
                '{' => {
                    // Nothing, such as an arm of a union that holds nothing, is an
                    // empty object.
                    if (request.expected == .unit) {
                        const inside = self.space(self.at + 1);
                        if (inside < self.input.len and self.input[inside] == '}') {
                            self.finish(inside + 1);
                            self.ended();
                            return .unit;
                        }
                    }
                    try self.push(c, true, self.accepting.reject_duplicates and request.expected != .record);
                    self.finish(self.at + 1);
                    return .{ .begin = .{ .kind = if (request.expected == .map) .map else .record } };
                },
                '[' => {
                    try self.push(c, false, false);
                    self.finish(self.at + 1);
                    return .{ .begin = .{ .kind = .sequence } };
                },
                '"' => {
                    const span = try self.string(c, false);
                    self.ended();
                    return .{ .text = span };
                },
                't' => return self.word("true", .{ .boolean = true }),
                'f' => return self.word("false", .{ .boolean = false }),
                'n' => return self.word("null", .none),
                '-', '0'...'9' => {
                    const start = self.at;
                    const end = try numberEnd(self.input, start);
                    if (limit.exceeds(end - start, c.limits.numeric_bytes)) return error.LengthLimit;
                    self.finish(end);
                    self.ended();
                    return .{ .number = .{ .bytes = self.input[start..end], .lifetime = .borrowed } };
                },
                else => return error.SyntaxError,
            }
        }
        inline fn ended(self: *Self) void {
            if (self.depth == 0) self.root_done = true;
        }
        fn word(self: *Self, comptime spelling: []const u8, event: core.Event) Error!core.Event {
            if (self.input.len - self.at < spelling.len or !std.mem.eql(u8, self.input[self.at..][0..spelling.len], spelling)) return error.SyntaxError;
            self.finish(self.at + spelling.len);
            self.ended();
            return event;
        }

        /// The string at the cursor: borrowed from the input when it has no escape,
        /// unescaped into the operation's storage when it has one.
        inline fn string(self: *Self, c: *core.Context, is_key: bool) Error!core.Span {
            const start = self.at + 1;
            const body = self.input[start..];
            // The common case, a string with no escape, takes one look.
            const found = strings.specialNear(body) orelse strings.special(body);
            if (found.at < body.len and body[found.at] == '"') plain: {
                if (found.non_ascii and !std.unicode.utf8ValidateSlice(body[0..found.at])) {
                    if (self.accepting.unicode == .refuse) return error.SyntaxError;
                    // Rewritten below, its bad bytes as U+FFFD.
                    break :plain;
                }
                try c.span(found.at, is_key);
                self.finish(start + found.at + 1);
                return .{ .bytes = body[0..found.at], .lifetime = .borrowed };
            }
            const unicode = self.accepting.unicode;
            const end = try strings.end(body, unicode);
            const escaped = body[0..end.at];
            if (self.checking) {
                try c.span(strings.unescapedLength(escaped, unicode), is_key);
                self.finish(start + end.at + 1);
                return .{ .bytes = escaped, .lifetime = .borrowed };
            }
            // Nothing is shorter unescaped, so the escaped length bounds the
            // copy; a bad byte made U+FFFD is longer, so then it is counted.
            const storage = try c.alloc(u8, if (unicode == .refuse) escaped.len else strings.unescapedLength(escaped, unicode));
            const n = strings.unescape(escaped, storage, unicode);
            try c.span(n, is_key);
            self.finish(start + end.at + 1);
            return .{ .bytes = storage[0..n], .lifetime = .owned };
        }

        /// Where the number that starts at `start` ends; its grammar is checked.
        inline fn numberEnd(bytes: []const u8, start: usize) Error!usize {
            var at = start;
            if (bytes[at] == '-') at += 1;
            if (at == bytes.len) return error.SyntaxError;
            if (bytes[at] == '0') {
                at += 1;
            } else if (bytes[at] >= '1' and bytes[at] <= '9') {
                at = digitsEnd(bytes, at + 1);
            } else return error.SyntaxError;
            if (at < bytes.len and bytes[at] == '.') {
                const digits = at + 1;
                at = digitsEnd(bytes, digits);
                if (at == digits) return error.SyntaxError;
            }
            if (at < bytes.len and (bytes[at] == 'e' or bytes[at] == 'E')) {
                at += 1;
                if (at < bytes.len and (bytes[at] == '+' or bytes[at] == '-')) at += 1;
                const digits = at;
                at = digitsEnd(bytes, digits);
                if (at == digits) return error.SyntaxError;
            }
            return at;
        }

        /// Where the run of decimal digits from `from` ends, eight bytes at a
        /// time where eight are there.
        inline fn digitsEnd(bytes: []const u8, from: usize) usize {
            var at = from;
            while (at + 8 <= bytes.len) : (at += 8) {
                const x = std.mem.readInt(u64, bytes[at..][0..8], .little) ^ 0x3030303030303030;
                // A digit is a byte of 0 to 9 now: adding 0x76 leaves its high bit
                // clear, and sets it in any other (or it was set already). A
                // carry out of a byte that is no digit only reaches bytes after it.
                const stops = ((x +% 0x7676767676767676) | x) & 0x8080808080808080;
                if (stops != 0) return at + @ctz(stops) / 8;
            }
            while (at < bytes.len and std.ascii.isDigit(bytes[at])) at += 1;
            return at;
        }

        pub fn endInput(self: *Self, c: *core.Context) Error!void {
            _ = c;
            if (!self.root_done or self.at != self.input.len) return error.SyntaxError;
        }
    };
}
