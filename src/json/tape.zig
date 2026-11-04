//! JSON read in two passes. The first checks the whole input and writes it as
//! a tape: a word for each value, key and container end, the strings that had
//! escapes unescaped beside them, and where each word's token was in the
//! input. The second reads the tape as the core's events, with the decoder's
//! protocol and its positions, so a typed read of a tape fails where and as a
//! read of the input fails. A container's word knows how many items it holds
//! before they are read, so the slice they go into is allocated once.
//!
//! The tape is a flat image (`aegis.flat`): its words stream into a region
//! as they are found, and a container's word is written again when it closes.
const std = @import("std");
const aegis = @import("aegis");
const core = @import("../core.zig");
const limit = @import("../core/limit.zig");
const decoding = @import("Decoder.zig");
const strings = @import("text.zig");
const json5_tokens = @import("json5.zig");
const Region = aegis.Region;

/// The tape of one input.
pub const Tape = struct {
    /// One per value, key and container end, in input order (`Word`).
    words: []const u64,
    /// The strings that had an escape in them, or under `.replace` a byte that
    /// is not UTF-8, unescaped.
    strings: []const u8,
    /// Where the decoder stood before each word, and after the last: the
    /// token, or the comma or colon before it.
    positions: []const u32,
};
const Image = aegis.flat.Flat(Tape);

/// What a word is, in its low three bits.
const Kind = enum(u3) { null, false, true, number, string, array, object, end };

/// A word of the tape. A number or a string: bit 3 says whether its bytes are
/// in the tape's strings (else the input's), bits 4 to 31 its length, bits 32
/// to 63 where they start. An array or an object: bits 3 to 31 how many items
/// it holds (members of an object), stopping at the most they spell, and bits
/// 32 to 63 the index of its end word.
const Word = struct {
    const max_len = (1 << 28) - 1;
    const max_count = (1 << 29) - 1;

    inline fn kind(w: u64) Kind {
        return @fromBackingInt(@as(u3, @truncate(w)));
    }
    inline fn scalar(k: Kind) u64 {
        return @backingInt(k);
    }
    inline fn text(k: Kind, in_strings: bool, length: usize, start: usize) u64 {
        return @as(u64, @backingInt(k)) | (@as(u64, @intFromBool(in_strings)) << 3) | (@as(u64, length) << 4) | (@as(u64, start) << 32);
    }
    inline fn container(k: Kind, count: usize, last: usize) u64 {
        return @as(u64, @backingInt(k)) | (@as(u64, @min(count, max_count)) << 3) | (@as(u64, last) << 32);
    }
    inline fn unescaped(w: u64) bool {
        return w & 8 != 0;
    }
    inline fn len(w: u64) usize {
        return @intCast((w >> 4) & max_len);
    }
    inline fn at(w: u64) usize {
        return @intCast(w >> 32);
    }
    inline fn items(w: u64) usize {
        return @intCast((w >> 3) & max_count);
    }
    inline fn end(w: u64) usize {
        return @intCast(w >> 32);
    }
};

/// What a tape of `n` input bytes may take at most: its image, and the
/// strings, positions and open containers written beside it before they
/// are copied in.
pub const Sizes = struct {
    image: usize,
    strings: usize,
    positions: usize,
    stack: usize,

    fn total(s: Sizes) usize {
        return s.image +| s.strings +| s.positions +| s.stack;
    }
};

/// An open container while the tape is written.
const Open = struct { index: u32, items: u32, object: bool, key: bool };

/// The sizes of the tape of `n` input bytes, or `null` where it cannot be
/// written: no address space to reserve on this target, an image past the 4
/// GiB its offsets reach, lengths past the 28 bits a word holds, or more than
/// the operation may still allocate. Every token is a byte at least, so a
/// tape has at most `n` words; a string unescaped is no longer than it was
/// written but under `.replace`, where a bad byte becomes three.
pub fn fits(c: *const core.Context, n: usize) ?Sizes {
    if (!Region.can_reserve) return null;
    inline for (.{ "string_bytes", "key_bytes", "numeric_bytes" }) |name| {
        if (!limit.exceeds(Word.max_len, @field(c.limits, name))) return null;
    }
    const wide: u64 = n;
    const unescaped = if (c.acceptance.invalid_unicode == .refuse) wide else wide * 3;
    const positions = (wide + 1) * @sizeOf(u32);
    // The image: its head and the alignment before each part, then the parts.
    const image = 64 + wide * @sizeOf(u64) + unescaped + positions;
    if (image >= 1 << 32) return null;
    const stack = (@min(wide, c.limits.depth) + 1) * @sizeOf(Open);
    const sizes: Sizes = .{ .image = @intCast(image), .strings = @intCast(unescaped), .positions = @intCast(positions), .stack = @intCast(stack) };
    if (sizes.total() > c.allocationLeft()) return null;
    return sizes;
}

/// A tape written, in the region that holds it.
pub const Written = struct {
    region: Region,
    view: Image.View,

    pub fn deinit(w: *Written) void {
        w.region.deinit();
        w.* = undefined;
    }
};

/// The four regions a tape is written in.
const Regions = struct {
    image: Region,
    strings: Region,
    positions: Region,
    stack: Region,

    fn reserve(sizes: Sizes) ?Regions {
        var image = Region.reserve(.init(sizes.image)) catch return null;
        var unescaped = Region.reserve(.init(sizes.strings)) catch {
            image.deinit();
            return null;
        };
        var positions = Region.reserve(.init(sizes.positions)) catch {
            unescaped.deinit();
            image.deinit();
            return null;
        };
        const stack = Region.reserve(.init(sizes.stack)) catch {
            positions.deinit();
            unescaped.deinit();
            image.deinit();
            return null;
        };
        return .{ .image = image, .strings = unescaped, .positions = positions, .stack = stack };
    }
};

/// A region the system would not commit more of. Past its reservation is
/// past what `fits` sized, which no input reaches.
fn failure(err: Region.Error) error{OutOfMemory} {
    return switch (err) {
        error.OutOfMemory, error.LimitExceeded => error.OutOfMemory,
    };
}

/// Checks `input` whole and writes its tape, charging what the decoder
/// charges for it and the tape's memory, or `null`, nothing read or charged,
/// where the regions it is written in cannot be reserved.
pub fn write(comptime grammar: decoding.Grammar, c: *core.Context, input: []const u8, sizes: Sizes) core.DecodeError!?Written {
    var regions = Regions.reserve(sizes) orelse return null;
    errdefer regions.image.deinit();
    defer regions.strings.deinit();
    defer regions.positions.deinit();
    defer regions.stack.deinit();
    var image_tail = regions.image.tail(u8) catch |err| return failure(err);
    var unescaped = regions.strings.tail(u8) catch |err| return failure(err);
    var positions = regions.positions.tail(u32) catch |err| return failure(err);
    var stack = regions.stack.tail(Open) catch |err| return failure(err);
    var image = aegis.flat.Image.init(&image_tail, .init(2)) catch |err| return failure(err);
    var root = Image.builder(&image) catch |err| return failure(err);
    var words = root.begin(.words) catch |err| return failure(err);

    const Wire = decoding.Dialect(grammar);
    var d: Wire = undefined;
    d.initTape(c, input, &unescaped);
    defer d.deinit();
    // Every object as a record: its keys are checked for one given twice
    // when they are read from the tape, as the type asks.
    const request: core.Request = .{ .expected = .record };
    var count: usize = 0;
    var deepest: usize = 0;
    while (true) {
        _ = positions.append(@intCast(d.offset())) catch |err| return failure(err);
        const event = d.next(c, request) catch |err| {
            if (c.diagnostics) |diagnostics| diagnostics.offset = d.offset();
            return err;
        };
        if (event != .end) if (stack.len() != 0) {
            const open = &stack.items()[stack.len() - 1];
            if (!open.object or open.key) open.items +|= 1;
            if (open.object) open.key = !open.key;
        };
        const w: u64 = switch (event) {
            .begin => |header| begin: {
                const object = header.kind != .sequence;
                _ = stack.append(.{ .index = @intCast(count), .items = 0, .object = object, .key = true }) catch |err| return failure(err);
                deepest = @max(deepest, stack.len());
                break :begin 0;
            },
            .end => end: {
                const open = stack.items()[stack.len() - 1];
                stack.shrink(stack.len() - 1);
                words.put(open.index, Word.container(if (open.object) .object else .array, open.items, count));
                break :end Word.scalar(.end);
            },
            .text => |span| if (span.lifetime == .transient)
                Word.text(.string, true, span.bytes.len, @intFromPtr(span.bytes.ptr) - @intFromPtr(unescaped.items().ptr))
            else
                Word.text(.string, false, span.bytes.len, @intFromPtr(span.bytes.ptr) - @intFromPtr(input.ptr)),
            .number => |span| Word.text(.number, false, span.bytes.len, @intFromPtr(span.bytes.ptr) - @intFromPtr(input.ptr)),
            .boolean => |b| Word.scalar(if (b) .true else .false),
            .none => Word.scalar(.null),
            else => unreachable, // the decoder makes no other event
        };
        words.append(w) catch |err| return failure(err);
        count += 1;
        if (d.rootEnd() != null) break;
    }
    _ = positions.append(@intCast(d.offset())) catch |err| return failure(err);
    d.endInput(c) catch |err| {
        if (c.diagnostics) |diagnostics| diagnostics.offset = d.offset();
        return err;
    };
    words.end();
    root.set(.strings, unescaped.items()) catch |err| return failure(err);
    root.set(.positions, positions.items()) catch |err| return failure(err);
    root.end();
    const bytes = image.finish();
    try c.hold(bytes.len +| unescaped.len() +| positions.len() * @sizeOf(u32) +| deepest * @sizeOf(Open));
    return .{ .region = regions.image, .view = Image.view(bytes) };
}

/// The tape of a dialect's input read as the core's events: the decoder's
/// protocol, and where it stands in the input at every step, the
/// decoder's.
pub fn Reader(comptime grammar: decoding.Grammar) type {
    const Wire = decoding.Dialect(grammar);
    const json5 = grammar == .json5;
    return struct {
        pub const Format = Wire.Format;
        pub const Error = Wire.Error;
        pub const capabilities = Wire.capabilities;
        pub const parseInteger = Wire.parseInteger;
        pub const parseFloat = Wire.parseFloat;
        const State = enum(u8) { first, member, value, after };
        // aegis: design: a parser's frame, whose transitions are the decoder's: the next word decides the edge, as the next byte decides the decoder's, held to the differential test against it
        const Frame = struct { object: bool, check_keys: bool, state: State, key_start: usize };
        const Words = @TypeOf(@as(Image.View, undefined).get(.words));
        const Positions = @TypeOf(@as(Image.View, undefined).get(.positions));
        const Accepting = struct { reject_duplicates: bool, unicode: strings.Unicode };
        const Self = @This();

        words: Words,
        tape_strings: []const u8,
        positions: Positions,
        input: []const u8,
        /// The next word.
        index: usize,
        /// One past the root's last word.
        stop: usize,
        /// Where the decoder would stand: the next unread byte, whitespace passed.
        at: usize,
        allocator: std.mem.Allocator,
        frames: [128]Frame,
        extra: std.ArrayList(Frame),
        depth: usize,
        keys: [128][]const u8,
        extra_keys: std.ArrayList([]const u8),
        key_count: usize,
        accepting: Accepting,
        root_done: bool,

        /// Starts `self` over `written`, the tape of `input`, built where it lies.
        pub fn init(self: *Self, c: *core.Context, written: *const Written, input: []const u8) void {
            const view = written.view;
            self.words = view.get(.words);
            self.tape_strings = view.get(.strings);
            self.positions = view.get(.positions);
            self.input = input;
            self.begin(0, wordCount(self.words), c.allocator(), .{
                .reject_duplicates = c.acceptance.duplicates == .reject,
                .unicode = c.acceptance.invalid_unicode,
            });
            self.at = self.position(0);
        }
        fn begin(self: *Self, first: usize, stop: usize, allocator: std.mem.Allocator, accepting: Accepting) void {
            self.index = first;
            self.stop = stop;
            self.allocator = allocator;
            self.extra = .empty;
            self.depth = 0;
            self.extra_keys = .empty;
            self.key_count = 0;
            self.accepting = accepting;
            self.root_done = false;
        }
        pub fn deinit(self: *Self) void {
            self.extra.deinit(self.allocator);
            self.extra_keys.deinit(self.allocator);
            self.* = undefined;
        }

        inline fn wordCount(words: Words) usize {
            return if (comptime Words == []const u64) words.len else words.len();
        }
        inline fn word(self: *const Self, i: usize) u64 {
            return if (comptime Words == []const u64) self.words[i] else self.words.at(i);
        }
        inline fn kindAt(self: *const Self, i: usize) Kind {
            return Word.kind(self.word(i));
        }
        inline fn position(self: *const Self, i: usize) usize {
            return if (comptime Positions == []const u32) self.positions[i] else self.positions.at(i);
        }
        /// The word at the cursor is read: the decoder stands where it stood
        /// before the next.
        inline fn took(self: *Self) void {
            self.index += 1;
            self.at = self.position(self.index);
        }
        /// Past the comma at the cursor, as the decoder takes it.
        inline fn separated(self: *Self) void {
            self.at = Wire.leadingIn(self.input, self.at);
        }
        /// A string's or a number's bytes: borrowed from the input, or the
        /// tape's unescaped, which live as long as the read.
        fn spanAt(self: *const Self, i: usize) core.Span {
            const w = self.word(i);
            // aegis: no-danger: the writer put a word's bytes where its start and length say, inside the input or the tape's strings
            if (Word.unescaped(w)) return .{ .bytes = self.tape_strings[Word.at(w)..][0..Word.len(w)], .lifetime = .transient };
            // aegis: no-danger: the writer put a word's bytes where its start and length say, inside the input or the tape's strings
            return .{ .bytes = self.input[Word.at(w)..][0..Word.len(w)], .lifetime = .borrowed };
        }

        /// Where the next token begins, or the comma before it.
        pub fn offset(self: *const Self) usize {
            return self.at;
        }
        /// A value's bytes, as the decoder's `raw` finds them.
        pub fn raw(self: *const Self, start: usize, end: usize) core.Span {
            const from = Wire.leadingIn(self.input, start);
            const to = if (end == self.at) self.lastEnd() else end;
            // aegis: no-danger: `from` and `to` are positions in the input the tape recorded, each at most its length
            return .{ .bytes = self.input[from..@max(from, to)], .lifetime = .borrowed };
        }
        /// Where the last token read ended.
        fn lastEnd(self: *const Self) usize {
            if (self.index == 0) return self.at;
            const i = self.index - 1;
            const w = self.word(i);
            const start = Wire.leadingIn(self.input, self.position(i));
            return switch (Word.kind(w)) {
                .null, .true => start + 4,
                .false => start + 5,
                .number => Word.at(w) + Word.len(w),
                // Past the closing quote, where there is one: a JSON5 key may be a name.
                .string => if (!Word.unescaped(w)) Word.at(w) + Word.len(w) + @intFromBool(start < Word.at(w)) else self.escapedEnd(i, start),
                .array, .object, .end => start + 1,
            };
        }
        /// Where the string with an escape at `start` ends, found again in the
        /// input; it ended when the tape was written.
        fn escapedEnd(self: *const Self, i: usize, start: usize) usize {
            const unicode = self.accepting.unicode;
            const quote = self.input[start];
            if (json5 and quote != '"' and quote != '\'') {
                return (json5_tokens.identifier(self.input, start) catch return self.position(i + 1)).end;
            }
            // aegis: no-danger: `start` is the string's opening quote, inside the input
            const body = self.input[start + 1 ..];
            const found = (if (json5) json5_tokens.end(body, quote, unicode) else strings.end(body, unicode)) catch return self.position(i + 1);
            return start + 1 + found.at + 1;
        }
        /// Starts `into` over a value already read, as the root of its own reading.
        pub fn replay(self: *const Self, into: *Self, from: usize, end: usize) void {
            _ = end;
            const first = self.wordAt(from);
            const w = self.word(first);
            const stop = switch (Word.kind(w)) {
                .array, .object => Word.end(w) + 1,
                else => first + 1,
            };
            into.words = self.words;
            into.tape_strings = self.tape_strings;
            into.positions = self.positions;
            into.input = self.input;
            into.begin(first, stop, self.allocator, self.accepting);
            into.at = Wire.leadingIn(self.input, from);
        }
        /// The word whose token is at `from`, or the comma or colon before it.
        fn wordAt(self: *const Self, from: usize) usize {
            var low: usize = 0;
            var high: usize = wordCount(self.words);
            while (high - low > 1) {
                const middle = low + (high - low) / 2;
                if (self.position(middle) <= from) low = middle else high = middle;
            }
            return low;
        }

        inline fn frame(self: *Self) *Frame {
            const i = self.depth - 1;
            return if (i < self.frames.len) &self.frames[i] else &self.extra.items[i - self.frames.len];
        }
        fn failed(c: *core.Context, err: anyerror) Error {
            return switch (err) {
                error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
                else => error.SyntaxError,
            };
        }
        inline fn push(self: *Self, c: *core.Context, object: bool, check_keys: bool) Error!void {
            if (self.depth >= c.limits.depth) return error.DepthLimit;
            const entry: Frame = .{ .object = object, .check_keys = check_keys, .state = .first, .key_start = self.key_count };
            if (self.depth < self.frames.len) self.frames[self.depth] = entry else self.extra.append(self.allocator, entry) catch |err| return failed(c, err);
            self.depth += 1;
        }
        fn close(self: *Self) core.Event {
            const entry = self.frame().*;
            if (self.depth > self.frames.len) _ = self.extra.pop();
            self.depth -= 1;
            self.key_count = entry.key_start;
            self.extra_keys.shrinkRetainingCapacity(entry.key_start - @min(entry.key_start, self.keys.len));
            if (self.depth == 0) self.root_done = true;
            self.took();
            return .end;
        }
        /// Refuses `name` where the object on top has it already, and else keeps
        /// it. Every name on a tape is unescaped, so the same text is the same bytes.
        fn remember(self: *Self, c: *core.Context, name: []const u8) Error!void {
            const from = self.frame().key_start;
            for (from..self.key_count) |i| {
                const prior = if (i < self.keys.len) self.keys[i] else self.extra_keys.items[i - self.keys.len];
                try c.chargeWork(@max(name.len, prior.len));
                if (std.mem.eql(u8, name, prior)) return error.DuplicateField;
            }
            if (self.key_count < self.keys.len) self.keys[self.key_count] = name else self.extra_keys.append(self.allocator, name) catch |err| return failed(c, err);
            self.key_count += 1;
        }
        /// Whether a closing word follows a comma, as a JSONC or JSON5
        /// container's last comma does.
        inline fn trailing(self: *const Self) bool {
            return self.input[self.at] == ',';
        }

        /// Whether the container being read is over, without reading a member of it.
        pub fn atEnd(self: *Self) Error!bool {
            if (self.depth == 0) return false;
            const f = self.frame();
            switch (f.state) {
                .first => return self.kindAt(self.index) == .end,
                .member, .value => return false,
                .after => {
                    if (self.kindAt(self.index) == .end) {
                        if (self.trailing()) {
                            self.separated();
                            f.state = .first;
                        }
                        return true;
                    }
                    self.separated();
                    f.state = .member;
                    return false;
                },
            }
        }

        pub fn next(self: *Self, c: *core.Context, request: core.Request) Error!core.Event {
            if (self.depth == 0) {
                if (self.root_done) return error.SyntaxError;
                return self.value(c, request);
            }
            const f = self.frame();
            switch (f.state) {
                .first => if (self.kindAt(self.index) == .end) return self.close(),
                .member => {},
                .value => {
                    f.state = .after;
                    return self.value(c, request);
                },
                .after => {
                    if (self.kindAt(self.index) == .end) return self.close();
                    self.separated();
                },
            }
            if (f.object) {
                f.state = .value;
                return self.key(c, f.check_keys);
            }
            f.state = .after;
            return self.value(c, request);
        }

        /// The next key of the object on top, or `null` where it closes, the close taken.
        pub inline fn memberKey(self: *Self, c: *core.Context) Error!?core.Span {
            if (!try self.toKey()) return null;
            return (try self.key(c, self.frame().check_keys)).text;
        }

        pub const Match = Wire.Match;
        /// `memberKey`, matched against `names`, the one at `hint` first.
        pub inline fn memberOf(self: *Self, c: *core.Context, comptime names: []const []const u8, hint: usize) Error!?Match {
            if (!try self.toKey()) return null;
            const name = (try self.key(c, self.frame().check_keys)).text.bytes;
            if (names.len != 0) switch (hint) {
                inline 0...names.len - 1 => |h| if (std.mem.eql(u8, name, names[h])) return .{ .index = h, .name = name },
                else => {},
            };
            inline for (names, 0..) |spelling, k| {
                if (std.mem.eql(u8, name, spelling)) return .{ .index = k, .name = name };
            }
            return .{ .index = null, .name = name };
        }
        /// Moves to the next key of the object on top, the comma before it
        /// taken, or closes the object and says so.
        inline fn toKey(self: *Self) Error!bool {
            const f = self.frame();
            switch (f.state) {
                .first => if (self.kindAt(self.index) == .end) {
                    _ = self.close();
                    return false;
                },
                .member => {},
                .after => {
                    if (self.kindAt(self.index) == .end) {
                        _ = self.close();
                        return false;
                    }
                    self.separated();
                },
                .value => return error.SyntaxError,
            }
            f.state = .value;
            return true;
        }

        /// A key, and the colon after it.
        inline fn key(self: *Self, c: *core.Context, check: bool) Error!core.Event {
            const name = self.spanAt(self.index);
            self.took();
            if (check) try self.remember(c, name.bytes);
            return .{ .text = name };
        }

        /// Moves to the next value of the container on top, as the decoder's
        /// `toValue` does.
        inline fn toValue(self: *Self) Error!bool {
            if (self.depth == 0) return !self.root_done;
            const f = self.frame();
            switch (f.state) {
                .value => {},
                .first => if (f.object or self.kindAt(self.index) == .end) return false,
                .member => if (f.object) return false,
                .after => {
                    if (f.object) return false;
                    if (self.kindAt(self.index) == .end) {
                        if (self.trailing()) {
                            self.separated();
                            f.state = .first;
                        }
                        return false;
                    }
                    self.separated();
                    f.state = .member;
                },
            }
            return true;
        }
        /// The value at the cursor is now being read.
        inline fn reading(self: *Self) void {
            if (self.depth == 0) self.root_done = true else self.frame().state = .after;
        }
        inline fn ended(self: *Self) void {
            if (self.depth == 0) self.root_done = true;
        }

        /// Opens the next value if it is the container `request` expects.
        pub inline fn open(self: *Self, c: *core.Context, request: core.Request) Error!?@FieldType(core.Event, "begin") {
            const object = switch (request.expected) {
                .record, .map, .variant => true,
                .sequence, .tuple => false,
                else => return null,
            };
            if (!try self.toValue()) return null;
            if (self.kindAt(self.index) != @as(Kind, if (object) .object else .array)) return null;
            self.reading();
            try self.push(c, object, object and self.accepting.reject_duplicates and request.expected != .record);
            self.took();
            return .{ .kind = if (!object) .sequence else if (request.expected == .map) .map else .record };
        }
        /// How many items the container just opened holds.
        pub fn opened(self: *const Self) ?usize {
            if (self.index == 0) return null;
            return Word.items(self.word(self.index - 1));
        }

        /// Whether the next value is `null`, read if it is.
        pub inline fn none(self: *Self, c: *core.Context) Error!bool {
            _ = c;
            if (!try self.toValue()) return false;
            if (self.kindAt(self.index) != .null) return false;
            self.reading();
            self.took();
            return true;
        }
        /// The next value's lexeme if it is a number, read.
        pub inline fn number(self: *Self, c: *core.Context) Error!?[]const u8 {
            _ = c;
            if (!try self.toValue()) return null;
            if (self.kindAt(self.index) != .number) return null;
            self.reading();
            const lexeme = self.spanAt(self.index).bytes;
            self.took();
            return lexeme;
        }
        /// The next value if it is an integer spelled with digits alone that
        /// fits `T`, as the decoder's `integer` reads it.
        pub inline fn integer(self: *Self, comptime T: type, c: *core.Context) Error!?T {
            const bits = @typeInfo(T).int.bits;
            if (bits == 0 or bits > 64) return null;
            if (!try self.toValue()) return null;
            const w = self.word(self.index);
            if (Word.kind(w) != .number) return null;
            const found = (try Wire.integerAt(T, self.input, Word.at(w), c)) orelse return null;
            self.reading();
            self.took();
            return found.value;
        }
        /// The next value if it is a string, read.
        pub inline fn text(self: *Self, c: *core.Context) Error!?core.Span {
            _ = c;
            if (!try self.toValue()) return null;
            if (self.kindAt(self.index) != .string) return null;
            self.reading();
            const span = self.spanAt(self.index);
            self.took();
            return span;
        }

        /// Passes over the next value, checked and charged as the decoder's
        /// `pass` checks and charges it, standing where it stands at each step.
        pub fn pass(self: *Self, c: *core.Context) Error!bool {
            if (!try self.toValue()) return false;
            self.reading();
            try self.passAt(c, self.at);
            return true;
        }
        /// The value at the next word, whose token is at `at`.
        fn passAt(self: *Self, c: *core.Context, at: usize) Error!void {
            try c.node();
            try c.chargeWork(1);
            const w = self.word(self.index);
            switch (Word.kind(w)) {
                .number => {
                    try c.chargeWork(Word.len(w));
                    self.took();
                },
                .null, .false, .true => self.took(),
                .string => {
                    self.at = at;
                    try c.chargeWork(Word.len(w));
                    self.took();
                },
                .object, .array => |k| {
                    self.at = at;
                    try self.passContainer(c, k == .object);
                },
                .end => return error.SyntaxError,
            }
        }
        fn passContainer(self: *Self, c: *core.Context, object: bool) Error!void {
            try c.enter();
            defer c.leave();
            try self.push(c, object, object and self.accepting.reject_duplicates);
            self.took();
            var count: usize = 0;
            if (object) {
                while (try self.passMember(c, &count)) {}
            } else {
                while (try self.passElement(c, &count)) {}
            }
        }
        /// The next member of the object on top passed over, or false where it
        /// closes, the close taken.
        fn passMember(self: *Self, c: *core.Context, count: *usize) Error!bool {
            const f = self.frame();
            switch (f.state) {
                .first => if (self.kindAt(self.index) == .end) {
                    _ = self.close();
                    return false;
                },
                .member => {},
                .after => if (self.kindAt(self.index) == .end) {
                    _ = self.close();
                    return false;
                },
                .value => return error.SyntaxError,
            }
            const name = self.spanAt(self.index).bytes;
            if (f.check_keys) try self.remember(c, name);
            if (count.* >= c.limits.container_items) return error.ItemLimit;
            count.* += 1;
            try c.node();
            try c.chargeWork(name.len);
            self.index += 1;
            f.state = .after;
            try self.passAt(c, self.position(self.index));
            return true;
        }
        /// The next element of the array on top passed over, or false where it
        /// closes, the close taken.
        fn passElement(self: *Self, c: *core.Context, count: *usize) Error!bool {
            const f = self.frame();
            var at = self.at;
            switch (f.state) {
                .first => if (self.kindAt(self.index) == .end) {
                    _ = self.close();
                    return false;
                },
                .member => {},
                .after => {
                    if (self.kindAt(self.index) == .end) {
                        _ = self.close();
                        return false;
                    }
                    at = Wire.leadingIn(self.input, at);
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
            const w = self.word(self.index);
            switch (Word.kind(w)) {
                .object => {
                    // Nothing, such as an arm of a union that holds nothing, is an
                    // empty object.
                    if (request.expected == .unit and self.kindAt(self.index + 1) == .end) {
                        self.index += 1;
                        self.took();
                        self.ended();
                        return .unit;
                    }
                    try self.push(c, true, self.accepting.reject_duplicates and request.expected != .record);
                    self.took();
                    return .{ .begin = .{ .kind = if (request.expected == .map) .map else .record } };
                },
                .array => {
                    try self.push(c, false, false);
                    self.took();
                    return .{ .begin = .{ .kind = .sequence } };
                },
                .string => {
                    const span = self.spanAt(self.index);
                    self.took();
                    self.ended();
                    return .{ .text = span };
                },
                .number => {
                    const span = self.spanAt(self.index);
                    self.took();
                    self.ended();
                    return .{ .number = span };
                },
                .true, .false, .null => |k| {
                    self.took();
                    self.ended();
                    return switch (k) {
                        .true => .{ .boolean = true },
                        .false => .{ .boolean = false },
                        else => .none,
                    };
                },
                .end => return error.SyntaxError,
            }
        }

        pub fn endInput(self: *Self, c: *core.Context) Error!void {
            _ = c;
            if (!self.root_done or self.index != self.stop) return error.SyntaxError;
        }
    };
}
