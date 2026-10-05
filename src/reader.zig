//! `Reader`: a `*std.Io.Reader` as a stream of typed lines.
const codec_module = @import("codec.zig");
const reader_module = @import("line/reader.zig");
const owned_module = @import("owned.zig");
const work_module = @import("testing/work.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;

const parse_line = codec_module.parser;
const ParseOptions = parse_line.ParseOptions;
const DuplicateFields = parse_line.DuplicateFields;
const ParseLineError = parse_line.ParseLineError;
const parseLineInto = parse_line.parseLineInto;

const line_mod = @import("line.zig");
const Line = line_mod.Line;
const RawLine = line_mod.RawLine;
const Format = line_mod.Format;

const LineReader = reader_module.LineReader;
const Scanner = @import("Scanner.zig");

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

        /// Internal. What parsing the current line allocated, reset per line.
        arena: std.heap.ArenaAllocator,

        const Self = @This();

        pub const Options = owner_types.Options;

        pub const NextError = owner_types.NextError;

        pub const Start = owner_types.Start;

        /// A reader over `input`, with `allocator` backing the line buffer and
        pub fn init(allocator: Allocator, input: *std.Io.Reader, options: Options) Self {
            return owner_methods.init(Self, allocator, input, options);
        }

        /// A reader over an `input` already positioned part-way into a file,
        pub fn resumeAt(allocator: Allocator, input: *std.Io.Reader, options: Options, start: Start) Self {
            return owner_methods.resumeAt(Self, allocator, input, options, start);
        }

        /// Releases the line buffer and the arena. Every `Line` this reader
        pub fn deinit(self: *Self) void {
            return owner_methods.deinit(self);
        }

        /// The next line, or `null` at end of stream.
        pub fn next(self: *Self) NextError!?Line(T) {
            return owner_methods.next(self);
        }

        /// The next line's bytes, its number and its place, without parsing
        pub fn nextRaw(self: *Self) NextError!?RawLine {
            return owner_methods.nextRaw(self);
        }

        /// The value on a line `nextRaw` handed back, on this reader's own
        pub fn parse(self: *Self, raw: RawLine) NextError!?Line(T) {
            return owner_methods.parse(self, raw);
        }
        const nextPretty = owner_methods.nextPretty;
        const inPlace = owner_methods.inPlace;
        const grow = owner_methods.grow;
        const malformed = owner_methods.malformed;

        /// A copy of `line.value` and all its storage on `allocator`.
        pub fn keep(self: *Self, allocator: Allocator, line: Line(T)) Allocator.Error!T {
            return owner_methods.keep(allocator, self, line);
        }
        pub const Value = T;
    };
}

/// Where a `.pretty` record's value ends, followed a line at a time.
///
/// The scanner a parse reads tokens from, which `std.json` is the oracle of,
/// so the value it sees end is the one a parse sees end. A line ends between
/// two tokens of a value that goes on after it — a string, a literal or a
/// number cut by the `\n` is not JSON — so the scanner picks up the next line
/// where it left off. It keeps no token and borrows nothing between lines.
const PrettyEnd = struct {
    state: enum {
        /// Inside the value.
        open,
        /// The value ended, or what was followed stopped being JSON.
        closed,
        /// The stream ended inside the value.
        ended,
        /// Not followed: parsed after every joined line.
        per_line,
    },
    scanner: Scanner,

    noinline fn init(self: *PrettyEnd, allocator: Allocator, line: []const u8) void {
        self.scanner = .initCompleteInput(allocator, line);
        self.state = .open;
        self.follow(line);
    }

    fn deinit(self: *PrettyEnd) void {
        self.scanner.deinit();
        self.* = undefined;
    }

    /// Follows `record`, whose front is what was followed before, to its end
    /// or to where its value does.
    fn follow(self: *PrettyEnd, record: []const u8) void {
        std.debug.assert(self.scanner.cursor <= record.len);
        work_module.scan(record.len - self.scanner.cursor);
        // The bytes before the cursor are the same, wherever they are now.
        self.scanner.input = record;
        while (true) {
            const from = self.scanner.cursor;
            const between = self.scanner.state != .string and self.scanner.state != .string_escape;
            const token = self.scanner.next() catch |err| switch (err) {
                error.OutOfMemory => {
                    self.state = .per_line;
                    return;
                },
                // Out of input between two tokens is a value that goes on;
                // inside one, it is not JSON once the `\n` after it is there.
                error.UnexpectedEndOfInput => if (between and blank(record[from..])) return else break,
                else => break,
            };
            switch (token) {
                .object_end, .array_end, .number, .string, .true, .false, .null => {
                    if (self.scanner.stackHeight() == 0) break;
                },
                .end_of_document => break,
                else => {},
            }
        }
        self.state = .closed;
    }

    /// Whether `bytes` hold no part of a token: only the whitespace, commas
    /// and colons the scanner passes over between two.
    fn blank(bytes: []const u8) bool {
        for (bytes) |c| switch (c) {
            ' ', '\t', '\r', '\n', ',', ':' => {},
            else => return false,
        };
        return true;
    }
};

// Schema-independent policy types shared by the typed owners.
const owner_types = struct {
    /// Reading and parsing policy, fixed at `init`. The framing fields
    /// are `LineReader.Options`', under the same names, and are handed to
    /// `lines`; the rest say how a line becomes a `T`.
    pub const Options = struct {
        /// See `ParseOptions.ignore_unknown_fields`.
        ignore_unknown_fields: bool = true,
        /// See `ParseOptions.duplicate_fields`.
        duplicate_fields: DuplicateFields = .@"error",
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
        /// for one is `error.ControlByte` rather than whatever
        /// `std.json` would have made of it.
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
    /// The parse errors of `std.json` collapse into `MalformedLine`,
    /// which says "this line, the one at `lines.fault.line`, is not a
    /// `T`"; `lines.fault.err` holds which parse error it was.
    /// `ControlByte` is the same claim about a line `std.json` was not
    /// shown, made before parsing because a control byte in a line means
    /// the line is damaged rather than merely wrong. `MissingSeparator` is
    /// a line with no record on it at all, which only a reader in
    /// `Options.record_separator` mode can tell. The other three are not
    /// about the content of a line: `OutOfMemory` is the allocator's,
    /// `ReadFailed` is the stream's (ask it for diagnostics), and
    /// `LineTooLong` is this reader's own bound.
    pub const NextError = LineReader.NextError || error{MalformedLine};

    /// Where a resumed reader begins. See `resumeAt`.
    pub const Start = LineReader.Start;
};
// Operations infer the record type from the owner; the facade retains typed signatures.
const owner_methods = struct {
    pub const Options = owner_types.Options;
    pub const NextError = owner_types.NextError;
    pub const Start = owner_types.Start;

    /// A reader over `input`, with `allocator` backing the line buffer and
    /// the per-line arena. Does not read from `input`.
    pub fn init(comptime Self: type, allocator: Allocator, input: *std.Io.Reader, options: Options) Self {
        return .resumeAt(allocator, input, options, .{});
    }

    /// A reader over an `input` already positioned part-way into a file,
    /// numbering and placing its lines as if it had read the rest. See
    /// `LineReader.resumeAt`, which this is over.
    pub fn resumeAt(comptime Self: type, allocator: Allocator, input: *std.Io.Reader, options: Options, start: Start) Self {
        return .{
            .lines = .resumeAt(allocator, input, options.framing(), start),
            .options = options,
            .arena = .init(allocator),
        };
    }

    /// Releases the line buffer and the arena. Every `Line` this reader
    /// returned, and every string borrowed from one, dangles afterwards.
    pub fn deinit(self: anytype) void {
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
    pub fn next(self: anytype) NextError!?Line(@TypeOf(self.*).Value) {
        const Self = @TypeOf(self.*);
        const T = Self.Value;

        // A `.pretty` reader of a type the direct decoder reads has a
        // loop of its own, so that a minified line's is as it was.
        if (comptime parse_line.direct(T)) if (self.options.format == .pretty) return self.nextPretty();
        while (true) {
            // Keep the frame and the decoded value in this call's
            // result rather than returning each through a separate
            // aggregate. The two layers still own their own work.
            const raw = (try @call(.always_inline, LineReader.next, .{&self.lines})) orelse return null;
            if (try @call(.always_inline, Self.parse, .{ self, raw })) |line| return line;
            // An unfinished pretty record is the end reached while
            // joining, not a skipped record. Keep the framing layer's
            // rewind point for the caller that will read it again.
            if (self.lines.unfinished) return null;
            // The record was passed over under `.skip`; the next one.
        }
    }

    /// The next line's bytes, its number and its place, without parsing
    /// them into a `T`: `lines.next()`, under the name it has here.
    ///
    /// This is what routing a stream is built from: `kindOf` or `tagOf`
    /// on `raw.line` says what kind of line it is, and only the ones
    /// worth having need to become values. A line that is not parsed
    /// costs no arena and no allocator at all. `parse` is how one of them
    /// becomes a `Line(T)` afterwards.
    ///
    /// Ownership: `raw.line` borrows exactly as `Line.line` does, and is
    /// gone at the next call to `next`, `nextRaw` or `deinit`.
    ///
    /// In `.pretty` mode a record is known to be finished only when it
    /// parses, so what this hands back there is one physical line and not
    /// a record. Routing a `.pretty` stream means parsing it.
    pub fn nextRaw(self: anytype) NextError!?RawLine {
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
    pub fn parse(self: anytype, raw: RawLine) NextError!?Line(@TypeOf(self.*).Value) {
        const T = @TypeOf(self.*).Value;

        var record = raw.line;
        // A `.pretty` record that has to be joined is parsed again here,
        // at the one place every line is parsed: a second call site of
        // `parseLineInto` changes what is inlined into this one, and a
        // minified line paid four percent for it over long lines. The
        // join itself stays out of line.
        var pretty: PrettyEnd = undefined;
        var joining = false;
        defer if (joining) pretty.deinit();
        while (true) {
            _ = self.arena.reset(.retain_capacity);
            // Asked for by name: what is left of `parseLine` once the
            // line is good is a scanner on the stack and one call under
            // it, and a second call around that is a cost every line
            // pays for nothing.
            const how: ParseOptions = .{
                .ignore_unknown_fields = self.options.ignore_unknown_fields,
                .duplicate_fields = self.options.duplicate_fields,
                .copy_strings = false,
            };
            // The value is decoded into the `Line` it is handed back in,
            // not copied into it; `parseLineInto` says what a copy costs.
            var line: Line(T) = .{
                .value = undefined,
                .line = record,
                .number = raw.number,
                .offset = raw.offset,
            };
            if (@call(.always_inline, parseLineInto, .{ T, self.arena.allocator(), record, how, &line.value })) {
                return line;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |parse_err| {
                    @branchHint(.unlikely);
                    if (self.options.format != .pretty) return self.malformed(raw.number, record, parse_err);
                    if (!joining) {
                        pretty.init(self.arena.child_allocator, record);
                        joining = true;
                    }
                    record = (try self.grow(&pretty, raw.number, record, parse_err)) orelse return null;
                },
            }
        }
    }

    /// `next` in `.pretty` mode: each record parsed where it lies in the
    /// input's buffer when it can be, and joined line by line by `parse`
    /// when it cannot.
    noinline fn nextPretty(self: anytype) NextError!?Line(@TypeOf(self.*).Value) {
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
    /// where the value ends. One parse on the decoder a minified line
    /// takes, and no copy. The lines it ran over are then the record's,
    /// as joining them would have made them.
    ///
    /// `null` hands the record to the joining path below, which says
    /// what is wrong with it: a value that does not parse, or that is
    /// cut off by the end of what is buffered, something after it on
    /// its last line, and lines `takeThrough` will not take. What that
    /// path makes of a record this one takes is the same record.
    noinline fn inPlace(self: anytype, raw: RawLine, rest: []const u8) ?Line(@TypeOf(self.*).Value) {
        const T = @TypeOf(self.*).Value;

        _ = self.arena.reset(.retain_capacity);
        const how: ParseOptions = .{
            .ignore_unknown_fields = self.options.ignore_unknown_fields,
            .duplicate_fields = self.options.duplicate_fields,
            .copy_strings = false,
        };
        var line: Line(T) = .{
            .value = undefined,
            .line = raw.line,
            .number = raw.number,
            .offset = raw.offset,
        };
        const end = parse_line.parsePrefixInto(T, self.arena.allocator(), rest, how, &line.value) catch return null;
        // Whitespace to the end of the line the value ended on, which
        // is where the record ends.
        var at = end;
        while (at < rest.len and (rest[at] == ' ' or rest[at] == '\t')) at += 1;
        if (at == rest.len or rest[at] != '\n') return null;
        if (at == raw.line.len) return line;
        line.line = self.lines.takeThrough(raw, rest, at) orelse return null;
        return line;
    }

    /// What a `.pretty` record that did not parse does next: the record
    /// joined to the lines after it, as far as the next place a parse can
    /// decide it, or `null` when it is decided without one — refused under
    /// `.skip`, damaged, or unfinished under `require_terminator`.
    ///
    /// A record ends where its JSON value does. Parsing it after every
    /// joined line would find that too, but it parses a record of `n`
    /// lines `n` times, so a scan follows the value's end a line at a
    /// time instead and the record is parsed again only where the value
    /// ends, where it stops being JSON, or at a blank line, which
    /// `parseLine` refuses. That is the same record a parse per line
    /// makes, with one exception: a record that is JSON but not a `T`
    /// is refused where its value ends, as one record, and not on the
    /// line where it stopped being a `T`, which would read the rest of
    /// its lines as records of their own.
    noinline fn grow(self: anytype, pretty: *PrettyEnd, number: u64, prefix: []const u8, failed: ParseLineError) NextError!?[]const u8 {
        switch (pretty.state) {
            .open => {},
            .closed => if (failed == error.UnexpectedEndOfInput) {
                // The parse wants more than the value the scan saw end,
                // which `std.json` as the oracle of both rules out. Join
                // and parse a line at a time rather than guess.
                pretty.state = .per_line;
            } else {
                _ = try self.malformed(number, prefix, failed);
                return null;
            },
            .per_line => if (failed != error.UnexpectedEndOfInput) {
                _ = try self.malformed(number, prefix, failed);
                return null;
            },
            // The stream ended inside the value, and this was the parse
            // that says what the record is.
            .ended => {
                _ = try self.malformed(number, prefix, failed);
                return null;
            },
        }
        var record = prefix;
        while (true) {
            const before = record.len;
            switch (try self.lines.join(number, record)) {
                .grown => |joined| record = joined,
                // The record is damaged rather than unfinished, and the
                // line reader has already said where and counted it:
                // saying anything else here would replace the true
                // diagnosis with a guess.
                .damaged => return null,
                .ended => {
                    if (self.options.require_terminator) return null;
                    if (pretty.state == .per_line) {
                        _ = try self.malformed(number, record, failed);
                        return null;
                    }
                    pretty.state = .ended;
                    return record;
                },
            }
            if (pretty.state == .per_line) return record;
            if (record.len == before + 1) {
                // A blank line, which leaves the record ending in its
                // terminator: the parse refuses that.
                pretty.state = .closed;
                return record;
            }
            pretty.follow(record);
            if (pretty.state != .open) return record;
        }
    }

    /// Records a parse failure against `number` and does what
    /// `on_malformed` says about it: `null` is a record passed over.
    fn malformed(self: anytype, number: u64, record: []const u8, err: ParseLineError) NextError!?Line(@TypeOf(self.*).Value) {
        const T = @TypeOf(self.*).Value;

        self.lines.fault.parse(
            number,
            err,
            line_mod.whereItFailed(T, self.arena.allocator(), record, self.options),
        );
        switch (self.options.on_malformed) {
            .fail => return error.MalformedLine,
            .skip => {
                self.lines.skipped += 1;
                return null;
            },
        }
    }

    /// A copy of `line.value` and all its storage on `allocator`.
    ///
    /// The result outlives the line and the reader. This calls `copyOwned`
    /// on the value already returned, preserving edits and migrations;
    /// it does not read `line.line` or call JSON hooks again. Custom
    /// parsers and migrations therefore run only when the line is read,
    /// even when their decisions depend on external state.
    ///
    /// The value must meet `copyOwned`'s finite-data-tree contract. A
    /// schema holding external resources or cyclic state needs its own
    /// ownership operation. Unsupported field types fail at compile time.
    /// Release the result with `freeOwned` on the same allocator, or
    /// release its destination arena as a whole. A failed copy frees
    /// everything it allocated and leaves the source value intact.
    pub fn keep(allocator: Allocator, self: anytype, line: Line(@TypeOf(self.*).Value)) Allocator.Error!@TypeOf(self.*).Value {
        return owned_module.copyOwned(allocator, line.value);
    }
};
