//! `Reader`: a `*std.Io.Reader` as a stream of typed lines.
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../core.zig");
const json = @import("../json/api.zig");
const reader_module = @import("line/reader.zig");

const line_mod = @import("line.zig");
const Line = line_mod.Line;
const RawLine = line_mod.RawLine;
const Format = line_mod.Format;

const LineReader = reader_module.LineReader;

/// The policy types of every `Reader`, whatever its record type: shared,
/// so that options and errors mean the same thing across instantiations.
const shared = struct {
    /// Reading and parsing policy, fixed at `init`. The framing fields
    /// are `LineReader.Options`', under the same names, and are handed to
    /// `lines`; `parse` says how a line becomes a `T`.
    pub const Options = struct {
        /// How a line is parsed: its limits, and whether unknown and repeated
        /// keys are refused. A line the parse refuses is `error.MalformedLine`,
        /// with the parse's error in `lines.fault.err`.
        parse: json.ParseOptions = .{},
        /// The longest JSON payload accepted, in bytes, excluding the
        /// terminator, separator and discarded torn prefix; in `.pretty` mode this bounds the joined record
        /// rather than one physical line. A longer one is
        /// `error.LineTooLong`; the rest of it is discarded, so `next`
        /// can be called again to continue with the line after it. This
        /// bound is the reader's memory bound, and it is independent of
        /// the size of `input`'s buffer.
        max_line_bytes: usize = 1 << 20,
        /// When true, a line that is empty or all spaces and tabs is
        /// consumed and not returned. Its number is still counted.
        skip_blank: bool = true,
        /// See `Format`. A `.pretty` reader also reads minified lines,
        /// since a minified record simply parses on its first line; the
        /// cost of the tolerance is that a truncated line joins with the
        /// one after it instead of failing on the spot.
        format: Format = .minified,
        /// See `LineReader.Options.record_separator`.
        record_separator: bool = false,
        /// See `LineReader.Options.reject_control_bytes`. A line refused
        /// for one is `error.ControlByte` and never reaches the parse.
        reject_control_bytes: bool = true,
        /// See `LineReader.Options.require_terminator`. `Follower` sets
        /// it, and rewinds and reads a half-written line again once the
        /// writer has finished it.
        require_terminator: bool = false,
        /// See `LineReader.Options.skip_bom`.
        skip_bom: bool = true,
        /// See `LineReader.Options.crlf`.
        crlf: bool = true,
        /// See `LineReader.Options.oversized_member`; the member is
        /// `lines.oversizedMember()`. A `.pretty` record refused while
        /// it was being joined is looked at as far as the physical line
        /// that took it past the bound.
        oversized_member: ?[]const u8 = null,
        /// What a line that is not a `T` does, and a damaged one.
        on_malformed: @FieldType(LineReader.Options, "on_malformed") = .fail,

        /// The framing half, as the line reader takes it.
        fn framing(options: Options) LineReader.Options {
            return .{
                .max_line_bytes = options.max_line_bytes,
                .skip_blank = options.skip_blank,
                .record_separator = options.record_separator,
                .reject_control_bytes = options.reject_control_bytes,
                .require_terminator = options.require_terminator,
                .skip_bom = options.skip_bom,
                .crlf = options.crlf,
                .oversized_member = options.oversized_member,
                .on_malformed = options.on_malformed,
            };
        }
    };

    /// What `next` can report: everything `LineReader.next` can, and
    /// `MalformedLine`.
    ///
    /// Every refusal of the parse is `MalformedLine`, which says "this line,
    /// the one at `lines.fault.line`, is not a `T`"; `lines.fault.err` holds
    /// which it was, a line past a parse limit included. `ControlByte` is the
    /// same claim about a line the parse was not shown, made before parsing
    /// because a control byte in a line means the line is damaged rather
    /// than merely wrong. `MissingSeparator` is a line with no record on it
    /// at all, which only a reader in `Options.record_separator` mode can
    /// tell. The other three are not about the content of a line:
    /// `OutOfMemory` is the allocator's, `ReadFailed` is the stream's (ask it
    /// for diagnostics), and `LineTooLong` is this reader's own bound.
    pub const NextError = LineReader.NextError || error{MalformedLine};

    /// Where a resumed reader begins. See `resumeAt`.
    pub const Start = LineReader.Start;
};

/// A stream of `T`, one per line, over a `*std.Io.Reader`.
///
/// A `LineReader` frames the lines, and this parses them: `lines` is that
/// line reader, and it is where the reader's place in the stream is kept —
/// the line number, the offset, what was refused and how many were passed
/// over. `Reader` adds an arena holding whatever parsing the current line had
/// to allocate. The line buffer and the arena are recycled at the start of
/// every `next`, which is what keeps memory bounded over a stream of any
/// length, and which is why a value must be copied out (`keep`) to outlive
/// the line it came from.
///
/// Threads: a `Reader` has no global state and no lock. Two readers on two
/// streams are independent and may run on two threads at once — that is what
/// `Follower`'s tests do — but one `Reader` is not shared between threads.
pub fn Reader(comptime T: type) type {
    return struct {
        /// The line layer: the stream, where this reader is in it, and what
        /// it refused. `lines.number` is the number of the line `next` last
        /// returned, `lines.offset` where that line began, `lines.fault` the
        /// last line refused and why — a line that is not a `T` included —
        /// and `lines.skipped` how many were passed over under
        /// `on_malformed = .skip`. Read-only to the caller.
        lines: LineReader,
        /// Read-only after `init`.
        options: Options,
        /// Private: What parsing the current line allocated, reset per line.
        arena: std.heap.ArenaAllocator,

        const Self = @This();

        pub const Options = shared.Options;

        pub const NextError = shared.NextError;

        pub const Start = shared.Start;

        /// A reader over `input`, with `gpa` backing the line buffer and
        /// the per-line arena. Does not read from `input`.
        pub fn init(gpa: Allocator, input: *std.Io.Reader, options: Options) Self {
            return .resumeAt(gpa, input, .{}, options);
        }

        /// A reader over an `input` already positioned part-way into a file,
        /// numbering and placing its lines as if it had read the rest. See
        /// `LineReader.resumeAt`, which this is over.
        pub fn resumeAt(gpa: Allocator, input: *std.Io.Reader, start: Start, options: Options) Self {
            return .{
                .lines = .resumeAt(gpa, input, start, options.framing()),
                .options = options,
                .arena = .init(gpa),
            };
        }

        /// Releases the line buffer and the arena. Every `Line` this reader
        /// returned, and every string borrowed from one, dangles afterwards.
        pub fn deinit(self: *Self) void {
            self.lines.deinit();
            self.arena.deinit();
            self.* = undefined;
        }

        /// The next line, or `null` at end of stream.
        ///
        /// Ownership: the returned `Line` borrows. Its `line` field is a
        /// slice of `input`'s own buffer when the whole line was already
        /// there and of the reader's line buffer when it was not, and the
        /// value's strings point either into that same line (when they needed
        /// no unescaping) or into the reader's arena (when they did). The
        /// next call to `next` reads the stream, overwrites the line buffer
        /// and resets the arena, so everything the previous `Line` pointed at
        /// is gone by the time the next one is returned. To keep a value past
        /// that point, call `keep`.
        ///
        /// `error.MalformedLine`, `error.ControlByte` and
        /// `error.LineTooLong` do not desynchronize the stream: the offending
        /// line has been consumed in full, and calling `next` again continues
        /// with the one after it. `error.ReadFailed` and `error.OutOfMemory`
        /// can arrive in the middle of a line, and leave the stream wherever
        /// they found it.
        pub fn next(self: *Self) NextError!?Line(T) {
            if (self.options.format == .pretty) return self.nextPretty();
            while (true) {
                // The frame and the value come back in this call's result,
                // each layer still doing its own work.
                const raw = (try @call(.always_inline, LineReader.next, .{&self.lines})) orelse return null;
                if (try @call(.always_inline, Self.parse, .{ self, raw })) |line| return line;
                // The record was passed over under `.skip`; the next one.
            }
        }

        /// The next line's bytes, its number and its place, without parsing
        /// them into a `T`: `lines.next()`, under the name it has here.
        ///
        /// This is what routing a stream is built from: `json.kindOf` or
        /// `json.tagOf` on `raw.line` says what kind of line it is, and only
        /// the ones worth having need to become values. A line that is not
        /// parsed costs no arena and no allocator at all. `parse` is how one
        /// of them becomes a `Line(T)` afterwards.
        ///
        /// Ownership: `raw.line` borrows exactly as `Line.line` does, and is
        /// gone at the next call to `next`, `nextRaw` or `deinit`.
        ///
        /// In `.pretty` mode a record is known to be finished only when it
        /// parses, so what this hands back there is one physical line and not
        /// a record. Routing a `.pretty` stream means parsing it.
        pub fn nextRaw(self: *Self) NextError!?RawLine {
            return self.lines.next();
        }

        /// The value on a line `nextRaw` handed back, on this reader's own
        /// arena. `null` when the line is not a `T` and `on_malformed` is
        /// `.skip`, or when an unfinished pretty record reaches the end
        /// under `require_terminator`. The framing layer keeps its rewind
        /// point in that case, so the caller can read the record again.
        ///
        /// Ownership: exactly `next`'s — the value borrows the line, the line
        /// borrows the stream, and the next read takes both back.
        ///
        /// `raw` must be the line the reader last handed back. In `.pretty`
        /// mode a record that is only a prefix of a value is joined to the
        /// lines after it here, which means reading them.
        pub fn parse(self: *Self, raw: RawLine) NextError!?Line(T) {
            _ = self.arena.reset(.retain_capacity);
            if (json.parseLeaky(T, self.arena.allocator(), raw.line, self.options.parse)) |value| {
                return .{ .value = value, .line = raw.line, .number = raw.number, .offset = raw.offset };
            } else |err| {
                @branchHint(.unlikely);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (self.options.format != .pretty) return self.malformed(raw.number, raw.line, err);
                return self.joined(raw, err);
            }
        }

        /// `next` in `.pretty` mode: each record parsed where it lies in the
        /// input's buffer when it can be, and joined line by line by `parse`
        /// when it cannot.
        noinline fn nextPretty(self: *Self) NextError!?Line(T) {
            while (true) {
                const raw = (try self.lines.next()) orelse return null;
                if (self.lines.bufferedFrom(raw)) |rest| {
                    if (self.inPlace(raw, rest)) |line| return line;
                }
                if (try self.parse(raw)) |line| return line;
                if (self.lines.unfinished) return null;
            }
        }

        /// A `.pretty` record parsed where it lies in the input's buffer:
        /// from its first byte, across the line breaks inside its value, to
        /// where the value ends. One parse and no copy. The lines it ran over
        /// are then the record's, as joining them would have made them.
        ///
        /// `null` hands the record to the joining path, which says what is
        /// wrong with it: a value that does not parse, or that is cut off by
        /// the end of what is buffered, something after it on its last line,
        /// and lines `takeThrough` will not take. What that path makes of a
        /// record this one takes is the same record.
        noinline fn inPlace(self: *Self, raw: RawLine, rest: []const u8) ?Line(T) {
            // The value starts on the record's first line. A first line that is
            // only whitespace (a lone carriage return when `crlf` is off) is
            // not the start of a record, whatever follows it.
            var start: usize = 0;
            while (start < raw.line.len and (rest[start] == ' ' or rest[start] == '\t' or rest[start] == '\r')) start += 1;
            if (start == raw.line.len) return null;
            _ = self.arena.reset(.retain_capacity);
            const found = json.parsePrefixLeaky(T, self.arena.allocator(), rest, self.options.parse) catch return null;
            // Whitespace to the end of the line the value ended on, which
            // is where the record ends.
            var at = found.end;
            while (at < rest.len and (rest[at] == ' ' or rest[at] == '\t')) at += 1;
            if (at == rest.len or rest[at] != '\n') return null;
            var line: Line(T) = .{ .value = found.value, .line = raw.line, .number = raw.number, .offset = raw.offset };
            if (at == raw.line.len) return line;
            line.line = self.lines.takeThrough(raw, rest, at) orelse return null;
            return line;
        }

        /// A `.pretty` record that did not parse on its first line: joined to
        /// the lines after it as far as its value runs, then parsed once.
        ///
        /// A record ends where its JSON value does, which a scan follows a
        /// line at a time, so a record of `n` lines is parsed once and not
        /// `n` times. A blank line ends a record too: it leaves the record
        /// ending in its terminator, which the parse refuses. `null` when the
        /// record is decided without a value: refused under `.skip`, damaged,
        /// or unfinished under `require_terminator`. `failed` is what the first
        /// line's parse said, which is the answer when the value ends on that line.
        noinline fn joined(self: *Self, raw: RawLine, failed: anytype) NextError!?Line(T) {
            var end: ValueEnd = .{};
            var record = raw.line;
            if (end.follow(record)) |_| return self.malformed(raw.number, record, failed);
            while (end.state == .open) {
                const before = record.len;
                switch (try self.lines.join(raw.number, record)) {
                    .grown => |grown| record = grown,
                    // The record is damaged rather than unfinished, and the
                    // line reader has already said where and counted it.
                    .damaged => return null,
                    .ended => |kept| {
                        if (self.options.require_terminator) return null;
                        record = kept;
                        break;
                    },
                }
                if (record.len == before + 1) break;
                _ = end.follow(record);
            }
            _ = self.arena.reset(.retain_capacity);
            const value = json.parseLeaky(T, self.arena.allocator(), record, self.options.parse) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                return self.malformed(raw.number, record, err);
            };
            return .{ .value = value, .line = record, .number = raw.number, .offset = raw.offset };
        }

        /// Records a parse failure against `number` and does what
        /// `on_malformed` says about it: `null` is a record passed over.
        fn malformed(self: *Self, number: u64, record: []const u8, err: anytype) NextError!?Line(T) {
            self.lines.fault.parse(
                number,
                line_mod.decodeError(err),
                line_mod.whereItFailed(T, self.arena.allocator(), record, self.options.parse),
            );
            switch (self.options.on_malformed) {
                .fail => return error.MalformedLine,
                .skip => {
                    self.lines.skipped += 1;
                    return null;
                },
            }
        }

        /// A copy of `line.value` and all its storage, in an owner of its own
        /// on `gpa`.
        ///
        /// The result outlives the line and the reader. The value already
        /// returned is copied, edits and migrations included; the line is not
        /// read again. The copy is checked and bounded by `options.parse`'s
        /// limits; a failed copy leaves nothing behind. Release it with its
        /// `deinit`.
        pub fn keep(self: *Self, gpa: Allocator, line: Line(T)) core.DecodeError!core.Parsed(T) {
            return core.clone(gpa, line.value, self.options.parse.limits);
        }
    };
}

/// Where a `.pretty` record's value ends, followed a line at a time: how
/// deep the scan is in containers, and whether it is inside a string. A line
/// ends between two tokens of a value that goes on after it, because a raw
/// line break is not allowed inside a string, so the scan picks up the next
/// line where it left off. It borrows nothing between lines.
pub const ValueEnd = struct {
    state: enum { start, open, closed } = .start,
    depth: usize = 0,
    in_string: bool = false,
    escaped: bool = false,
    /// How much of the record has been followed.
    seen: usize = 0,

    /// Follows `record`, whose front is what was followed before, to where
    /// its value ends: the offset just past it, or `null` when it goes on.
    pub fn follow(self: *ValueEnd, record: []const u8) ?usize {
        var at = self.seen;
        defer self.seen = record.len;
        while (at < record.len) : (at += 1) {
            const b = record[at];
            if (self.in_string) {
                if (self.escaped) {
                    self.escaped = false;
                } else if (b == '\\') {
                    self.escaped = true;
                } else if (b == '"') {
                    self.in_string = false;
                    if (self.depth == 0) return self.close(at + 1);
                }
                continue;
            }
            switch (b) {
                ' ', '\t', '\r', '\n' => {},
                '{', '[' => {
                    self.state = .open;
                    self.depth += 1;
                },
                '}', ']' => {
                    if (self.depth == 0) return self.close(at);
                    self.depth -= 1;
                    if (self.depth == 0) return self.close(at + 1);
                },
                '"' => {
                    self.state = .open;
                    self.in_string = true;
                },
                else => if (self.depth == 0) {
                    // A scalar at the top: a number or a word, which ends
                    // where the line does.
                    return self.close(record.len);
                },
            }
        }
        return null;
    }

    fn close(self: *ValueEnd, at: usize) usize {
        self.state = .closed;
        return at;
    }
};

test ValueEnd {
    var end: ValueEnd = .{};
    try std.testing.expectEqual(null, end.follow("{"));
    try std.testing.expectEqual(null, end.follow("{\n  \"a\": \"}\\\"\","));
    const record = "{\n  \"a\": \"}\\\"\",\n  \"b\": []\n}";
    try std.testing.expectEqual(@as(?usize, record.len), end.follow(record));
    var scalar: ValueEnd = .{};
    try std.testing.expectEqual(@as(?usize, 2), scalar.follow("17"));
}
