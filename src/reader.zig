//! `Reader`: a `*std.Io.Reader` as a stream of typed lines.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parse_line = @import("parse_line.zig");
const ParseOptions = parse_line.ParseOptions;
const DuplicateFields = parse_line.DuplicateFields;
const ParseLineError = parse_line.ParseLineError;
const parseLineInto = parse_line.parseLineInto;

const line_mod = @import("line.zig");
const Line = line_mod.Line;
const RawLine = line_mod.RawLine;
const Format = line_mod.Format;
const Fault = line_mod.Fault;
const separator = line_mod.separator;
const bom = line_mod.bom;
const trimCr = line_mod.trimCr;
const isBlank = line_mod.isBlank;

const control = @import("control.zig");
const indexOfControl = control.indexOfControl;
const firstControlOrTerminator = control.firstControlOrTerminator;

/// A stream of `T`, one per line, over a `*std.Io.Reader`.
///
/// The reader owns two buffers and reuses both: the bytes of the current line,
/// and an arena holding whatever parsing that line had to allocate. Both are
/// recycled at the start of every `next`, which is what keeps memory bounded
/// over a stream of any length, and which is why a value must be copied out
/// (`keep`) to outlive the line it came from.
///
/// Threads: a `Reader` has no global state and no lock. Two readers on two
/// streams are independent and may run on two threads at once — that is what
/// `Follower`'s tests do — but one `Reader` is not shared between threads.
pub fn Reader(comptime T: type) type {
    return struct {
        /// The byte source. Not owned: this reader never closes or flushes it,
        /// and leaves it positioned just past the last line returned.
        input: *std.Io.Reader,
        /// Read-only after `init`.
        options: Options,
        /// The number of the line `next` last returned, which is also the
        /// count of physical lines consumed so far — blank, malformed and
        /// over-long lines included.
        number: u64 = 0,
        /// The byte offset of the record `next` last returned or refused,
        /// measured from where this reader started. See `Line.offset`.
        offset: u64 = 0,
        /// How many records `next` passed over under
        /// `on_malformed = .skip` — the count a stream that tolerates damage
        /// is judged by, since under `.skip` nothing else says a line was
        /// lost. Blank lines are not damage and are not counted.
        skipped: u64 = 0,
        /// What the reader would not hand over, and why: the line number,
        /// the `std.json` error if the line got that far, and the offset in
        /// the line. See `Fault`. It is the last such line, whether it was
        /// reported or skipped; `fault.line` is 0 until there has been one.
        fault: Fault = .{},

        /// Internal. The current record's bytes; `Line.line` is a view of it.
        line_buf: std.Io.Writer.Allocating,
        /// Internal. What parsing the current line allocated, reset per line.
        arena: std.heap.ArenaAllocator,
        /// Internal. Set while the current record is a slice of `input`'s own
        /// buffer rather than a copy in `line_buf`. It says what a record
        /// about to be joined to has to do first, and it is the whole of the
        /// bookkeeping the zero-copy frame costs.
        borrowed: bool = false,
        /// Internal. Set when the scan that framed the current record also
        /// cleared it of control bytes, which is what the one scan in
        /// `frameBuffered` does. It says that `nextRaw` has nothing left to
        /// look for.
        cleared: bool = false,
        /// Internal. Whether the stream has been looked at for a byte-order
        /// mark, which happens once and before anything else is read.
        bom_checked: bool = false,
        /// Internal. Bytes taken from `input` so far, terminators and a
        /// byte-order mark included. `Line.offset` is a snapshot of this.
        consumed: u64 = 0,
        /// Internal. What `consumed` was when the current record began.
        record_offset: u64 = 0,
        /// Internal. How many physical lines preceded the current record.
        record_number: u64 = 0,

        const Self = @This();

        /// Reading and parsing policy, fixed at `init`.
        pub const Options = struct {
            /// See `ParseOptions.ignore_unknown_fields`.
            ignore_unknown_fields: bool = true,
            /// See `ParseOptions.duplicate_fields`.
            duplicate_fields: DuplicateFields = .@"error",
            /// The longest record accepted, in bytes, not counting the
            /// terminator; in `.pretty` mode this bounds the joined record
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
            /// When true, every record on the stream begins with a
            /// `separator` byte, and what comes before the first one on a
            /// line is the tail of a record that was torn — it is discarded,
            /// and the reader carries on with the record the separator
            /// marks. A line with no separator on it at all is
            /// `error.MissingSeparator`.
            ///
            /// This is what JSON Lines cannot do on its own: a line that
            /// does not parse is either damage or a record from a writer
            /// that knows something this reader does not, and there is no
            /// way to tell. A separator says where a record starts, so a
            /// reader can find the next one and say what it lost.
            ///
            /// A reader in this mode does not read a stream without
            /// separators, and a reader not in it does not read one with
            /// them: the byte is a raw control byte, which is
            /// `error.ControlByte`. It is a decision both ends make
            /// together, like the schema.
            record_separator: bool = false,
            /// When true, a C0 control byte other than tab — a NUL above all,
            /// which is what a torn write or a half-written block leaves
            /// behind — is `error.ControlByte` naming the line and the offset,
            /// rather than whatever `std.json` would have made of it.
            ///
            /// JSON forbids these bytes raw in a string and has no use for
            /// them between tokens, so this refuses nothing that was valid;
            /// it costs one scan of the line and buys an error that says what
            /// actually happened.
            reject_control_bytes: bool = true,
            /// When true, a final line the stream has not terminated with a
            /// `\n` is not a line: `next` returns `null`, `number` does not
            /// advance, and the bytes are dropped. This is what a reader of a
            /// file still being appended to wants, because the last line of
            /// such a file is usually half-written; see `Follower`, which
            /// rewinds and reads it again once the writer has finished it.
            ///
            /// When false — the default, and what a finished file wants — a
            /// final line with no terminator is a line like any other.
            require_terminator: bool = false,
            /// When true, a UTF-8 byte-order mark at the very start of the
            /// stream is not part of the first line. Editors and Windows
            /// tooling put one there; `std.json` has no idea what it is.
            skip_bom: bool = true,
            /// What a line that is not a `T` does.
            on_malformed: enum {
                /// `next` returns `error.MalformedLine` or
                /// `error.ControlByte`.
                fail,
                /// `next` moves on to the following line.
                skip,
            } = .fail,
        };

        /// What `next` can report.
        ///
        /// The parse errors of `std.json` collapse into `MalformedLine`,
        /// which says "this line, the one at `fault.line`, is not a
        /// `T`"; `fault.err` holds which parse error it was. `ControlByte`
        /// is the same claim about a line `std.json` was not shown, made
        /// before parsing because a control byte in a line means the line is
        /// damaged rather than merely wrong. `MissingSeparator` is a line
        /// with no record on it at all, which only a reader in
        /// `Options.record_separator` mode can tell. The other three are not
        /// about
        /// the content of a line: `OutOfMemory` is the allocator's,
        /// `ReadFailed` is the stream's (ask it for diagnostics), and
        /// `LineTooLong` is this reader's own bound.
        pub const NextError = error{
            MalformedLine,
            ControlByte,
            MissingSeparator,
            LineTooLong,
            ReadFailed,
            OutOfMemory,
        };

        /// Where a resumed reader begins: the place it is reading from, and
        /// how much of the file is behind it. See `resumeAt`.
        pub const Start = struct {
            /// The byte offset `input` is positioned at. Every offset this
            /// reader reports is measured from here, so an offset taken out
            /// of an index reads back as the same offset.
            offset: u64 = 0,
            /// How many lines came before that offset. The first line this
            /// reader returns is numbered `lines_before + 1`, so a line
            /// number taken out of an index reads back as the same line
            /// number.
            lines_before: u64 = 0,
        };

        /// A reader over `input`, with `allocator` backing the line buffer and
        /// the per-line arena. Does not read from `input`.
        pub fn init(allocator: Allocator, input: *std.Io.Reader, options: Options) Self {
            return .resumeAt(allocator, input, options, .{});
        }

        /// A reader over an `input` already positioned part-way into a file,
        /// numbering and placing its lines as if it had read the rest.
        ///
        /// This is the other half of `Line.offset`. An index is a list of
        /// offsets and the line numbers they belong to; `init` would read
        /// back from such an offset as line 1 at offset 0, which makes the
        /// index a place and not a line number. `resumeAt` is told both, so
        /// the line it returns first carries the number and the offset the
        /// index recorded, and every line after it carries the next ones.
        ///
        /// `input` must already be positioned at `start.offset` — this reader
        /// does not seek, because it does not own the stream. A byte-order
        /// mark is looked for only at offset 0, since that is the only place
        /// one can be.
        ///
        /// `start.lines_before` is not checked against anything: a reader
        /// cannot know what it did not read. An offset that is not where a
        /// line begins reads as a line beginning there, which is the same
        /// answer a caller would get by seeking a file and reading it.
        pub fn resumeAt(
            allocator: Allocator,
            input: *std.Io.Reader,
            options: Options,
            start: Start,
        ) Self {
            return .{
                .input = input,
                .options = options,
                .number = start.lines_before,
                .offset = start.offset,
                .line_buf = .init(allocator),
                .arena = .init(allocator),
                .consumed = start.offset,
                .record_offset = start.offset,
                .record_number = start.lines_before,
                // A mark belongs to the very start of a file, so a reader
                // that begins anywhere else must not eat three bytes of a
                // line looking for one.
                .bom_checked = start.offset != 0,
            };
        }

        /// Releases the line buffer and the arena. Every `Line` this reader
        /// returned, and every string borrowed from one, dangles afterwards.
        pub fn deinit(self: *Self) void {
            self.line_buf.deinit();
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
            while (true) {
                const raw = (try self.nextRaw()) orelse return null;
                if (try self.parse(raw)) |line| return line;
                // The record was passed over under `.skip`; the next one.
            }
        }

        /// The next line's bytes, its number and its place, without parsing
        /// them into a `T`.
        ///
        /// This is `next` with the parse left out, and it is what routing a
        /// stream is built from: `kindOf` or `tagOf` on `raw.line` says what
        /// kind of line it is, and only the ones worth having need to become
        /// values. A line that is not parsed costs no arena and no allocator
        /// at all. `parse` is how one of them becomes a `Line(T)` afterwards.
        ///
        /// Everything about a line other than its type is decided here:
        /// blank lines are passed over, the number and the offset are the
        /// ones `next` would report, a line past `max_line_bytes` is
        /// `error.LineTooLong`, and a raw control byte is `error.ControlByte`
        /// or a skip, as `on_malformed` says.
        ///
        /// Ownership: `raw.line` borrows exactly as `Line.line` does, and is
        /// gone at the next call to `next`, `nextRaw` or `deinit`.
        ///
        /// In `.pretty` mode a record is known to be finished only when it
        /// parses, so what this hands back there is one physical line and not
        /// a record. Routing a `.pretty` stream means parsing it.
        pub fn nextRaw(self: *Self) NextError!?RawLine {
            while (true) {
                self.line_buf.writer.end = 0;

                var record: []const u8 = undefined;
                var offset: u64 = undefined;
                if (self.options.record_separator) {
                    switch (try self.readSeparatedPhysical()) {
                        .record => |framed| {
                            record = framed.bytes;
                            offset = framed.offset;
                        },
                        .missing => |blank| {
                            if (blank and self.options.skip_blank) continue;
                            self.offset = self.record_offset;
                            self.fault.framing(self.number);
                            switch (self.options.on_malformed) {
                                .fail => return error.MissingSeparator,
                                .skip => {
                                    self.skipped += 1;
                                    continue;
                                },
                            }
                        },
                        .ended => return null,
                    }
                } else {
                    record = (try self.readPhysical()) orelse return null;
                    if (self.options.skip_blank and isBlank(record)) continue;
                    offset = self.record_offset;
                }
                const number = self.number;
                self.offset = offset;
                if (!self.cleared and try self.checkControl(record, 0, number)) {
                    self.skipped += 1;
                    continue;
                }
                return .{ .line = record, .number = number, .offset = offset };
            }
        }

        /// The value on a line `nextRaw` handed back, on this reader's own
        /// arena. `null` when the line is not a `T` and `on_malformed` is
        /// `.skip`, which is the one thing `next` does with it that a caller
        /// routing lines itself would otherwise have to write out.
        ///
        /// Ownership: exactly `next`'s — the value borrows the line, the line
        /// borrows the stream, and the next read takes both back.
        ///
        /// `raw` must be the line the reader last handed back. In `.pretty`
        /// mode a record that is only a prefix of a value is joined to the
        /// lines after it here, which means reading them.
        pub fn parse(self: *Self, raw: RawLine) NextError!?Line(T) {
            var record = raw.line;
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
                    error.UnexpectedEndOfInput => if (self.options.format == .pretty) {
                        // A prefix of a value: the rest of it is on the lines
                        // that follow, unless there are none.
                        switch (try self.joinPhysical(raw.number, record)) {
                            .grown => |joined| {
                                record = joined;
                                continue;
                            },
                            // The record is damaged rather than unfinished,
                            // and `checkControl` has already said where:
                            // saying anything else here would replace the
                            // true diagnosis with a guess.
                            .damaged => {
                                self.skipped += 1;
                                return null;
                            },
                            .ended => if (self.options.require_terminator)
                                return null
                            else
                                return self.malformed(raw.number, record, error.UnexpectedEndOfInput),
                        }
                    } else {
                        return self.malformed(raw.number, record, error.UnexpectedEndOfInput);
                    },
                    else => |parse_err| return self.malformed(raw.number, record, parse_err),
                }
            }
        }

        /// Records a parse failure against `number` and does what
        /// `on_malformed` says about it: `null` is a record passed over.
        fn malformed(self: *Self, number: u64, record: []const u8, err: ParseLineError) NextError!?Line(T) {
            self.fault.parse(
                number,
                err,
                line_mod.whereItFailed(T, self.arena.allocator(), record, self.options),
            );
            switch (self.options.on_malformed) {
                .fail => return error.MalformedLine,
                .skip => {
                    self.skipped += 1;
                    return null;
                },
            }
        }

        /// A copy of `line.value` that outlives the reader, allocated on
        /// `allocator`.
        ///
        /// Ownership: the result borrows nothing — not from the reader's line
        /// buffer, not from its arena — so it stays valid across any number of
        /// further `next` calls and past `deinit`. Allocations are not
        /// individually tracked, so `allocator` should be an arena the caller
        /// frees as a whole.
        ///
        /// This re-parses `line.line` with every string copied rather than
        /// handing over pages: a value from `next` points partly into the
        /// reader's line buffer, which the reader must keep reusing, so there
        /// is nothing whole to hand over. In practice the only error is
        /// `error.OutOfMemory`, since these bytes have already parsed once —
        /// but a `T` with a custom `jsonParse` method is free to disagree, so
        /// the full set is reported rather than asserted away.
        pub fn keep(self: *Self, allocator: Allocator, line: Line(T)) ParseLineError!T {
            return line_mod.keep(T, allocator, line.line, self.options);
        }

        /// Looks for a control byte in `record[from..]`. Returns true when the
        /// caller should skip this record; returns `error.ControlByte` when it
        /// should fail.
        ///
        /// The option and the answer are in the caller's own code, because
        /// every line goes through them; the scan is a call, since it holds a
        /// vector loop at three widths and the reading loop is better off
        /// without a copy of that in it. What to say about the byte, when
        /// there is one, is a line nobody takes twice and is left where it is.
        inline fn checkControl(self: *Self, record: []const u8, from: usize, number: u64) NextError!bool {
            if (!self.options.reject_control_bytes) return false;
            const offset = indexOfControl(record[from..]) orelse return false;
            return self.controlByte(from + offset, number);
        }

        /// Records the control byte `checkControl` found and does what
        /// `on_malformed` says about it.
        fn controlByte(self: *Self, at: usize, number: u64) NextError!bool {
            self.fault.control(number, at);
            return switch (self.options.on_malformed) {
                .fail => error.ControlByte,
                .skip => true,
            };
        }

        /// What a join did. Three outcomes rather than two, because a record
        /// that did not grow can have failed to for either of two reasons,
        /// and the caller has a different thing to say about each.
        pub const Joined = union(enum) {
            /// The next line is part of this record: these are its bytes now.
            grown: []const u8,
            /// The stream ended first, and the record is exactly as it was —
            /// which for a `.pretty` reader means a record that never
            /// finished.
            ended,
            /// The line joined on holds a raw control byte and the reader was
            /// told to skip such a record. `fault` names it already.
            damaged,
        };

        /// Appends the next physical line to the current record, separated by
        /// the `\n` that ended the previous one.
        fn joinPhysical(self: *Self, number: u64, record: []const u8) NextError!Joined {
            if (self.borrowed) {
                // The record so far is a slice of the input reader's buffer,
                // and reading the line after it is what takes that buffer
                // back: a record that is about to grow has to own its bytes.
                self.line_buf.writer.end = 0;
                self.line_buf.writer.writeAll(record) catch return error.OutOfMemory;
                self.borrowed = false;
            }
            const before = self.line_buf.writer.end;
            // The separator counts against the bound like any other byte.
            if (self.options.max_line_bytes -| before == 0) {
                // It is the record that is too long, and the record began at
                // `number`, whatever line the reader has reached since.
                self.fault.framing(number);
                self.offset = self.record_offset;
                self.consumed += try self.discardLine();
                return error.LineTooLong;
            }
            self.line_buf.writer.writeByte('\n') catch return error.OutOfMemory;
            const joined = (try self.readPhysical()) orelse {
                self.line_buf.writer.end = before;
                return .ended;
            };
            if (try self.checkControl(joined, before + 1, number)) return .damaged;
            return .{ .grown = joined };
        }

        const SeparatedPhysical = union(enum) {
            record: struct { bytes: []const u8, offset: u64 },
            missing: bool,
            ended,
        };

        /// Discards a torn prefix without storing it, then frames only the
        /// record following the first separator on the physical line.
        fn readSeparatedPhysical(self: *Self) NextError!SeparatedPhysical {
            var prefix: BomPrefix = .{};
            const before_bom = self.consumed;
            if (!self.bom_checked) {
                self.bom_checked = true;
                if (self.options.skip_bom) prefix = try self.skipBom();
            }

            self.record_offset = if (prefix.len == 0) self.consumed else before_bom;
            self.record_number = self.number;
            var discarded = false;
            var blank = true;
            var pending_cr = false;
            var pending = prefix.slice();
            while (true) {
                const from_prefix = pending.len != 0;
                const contents = if (from_prefix) pending else self.input.buffered();
                if (contents.len == 0) {
                    _ = self.input.peekByte() catch |err| switch (err) {
                        error.ReadFailed => return error.ReadFailed,
                        error.EndOfStream => {
                            if (!discarded) return .ended;
                            if (self.options.require_terminator) return .ended;
                            self.number += 1;
                            return .{ .missing = blank };
                        },
                    };
                    continue;
                }

                const separator_at = std.mem.findScalar(u8, contents, separator);
                const newline_at = std.mem.findScalar(u8, contents, '\n');
                const at = if (separator_at) |sep|
                    if (newline_at) |newline| @min(sep, newline) else sep
                else
                    newline_at orelse contents.len;

                if (at == contents.len) {
                    for (contents) |byte| {
                        discarded = true;
                        if (byte == '\r') {
                            pending_cr = true;
                        } else {
                            if (pending_cr) blank = false;
                            pending_cr = false;
                            if (byte != ' ' and byte != '\t') blank = false;
                        }
                    }
                    if (from_prefix) {
                        pending = pending[contents.len..];
                    } else {
                        self.input.toss(contents.len);
                        self.consumed += contents.len;
                    }
                    continue;
                }

                const byte = contents[at];
                if (byte == '\n') {
                    for (contents[0..at]) |prefix_byte| {
                        discarded = true;
                        if (prefix_byte == '\r') {
                            pending_cr = true;
                        } else {
                            if (pending_cr) blank = false;
                            pending_cr = false;
                            if (prefix_byte != ' ' and prefix_byte != '\t') blank = false;
                        }
                    }
                    if (!from_prefix) {
                        self.input.toss(at + 1);
                        self.consumed += at + 1;
                    }
                    self.number += 1;
                    return .{ .missing = blank };
                }

                const offset = if (from_prefix)
                    self.record_offset + at
                else
                    self.consumed + at;
                if (!from_prefix) {
                    self.input.toss(at + 1);
                    self.consumed += at + 1;
                }
                const after_separator = self.consumed;
                const framed = try self.readPhysical();
                self.record_offset = offset;
                self.record_number = self.number -| @intFromBool(framed != null);
                if (framed) |bytes| return .{ .record = .{ .bytes = bytes, .offset = offset } };
                if (!self.options.require_terminator and self.consumed == after_separator) {
                    self.number += 1;
                    return .{ .record = .{ .bytes = "", .offset = offset } };
                }
                return .ended;
            }
        }

        /// Reads one physical line and returns the record so far: a slice of
        /// `input`'s own buffer when the whole line was already sitting in
        /// it, and the line buffer's contents when it was not. `null` at end
        /// of stream, and at an unterminated final line under
        /// `require_terminator`. Counts the line.
        ///
        /// The line that is already whole in `input`'s buffer is framed right
        /// here, in the caller's own code: that is every line of a stream the
        /// reader is keeping up with, and a call and its prologue are a real
        /// part of what such a line costs. Everything else — the mark, the
        /// line that straddles a refill, the bound, the terminator that has
        /// not arrived — is in `readStreamed`, out of the way.
        inline fn readPhysical(self: *Self) NextError!?[]const u8 {
            if (self.bom_checked and self.line_buf.writer.end == 0) {
                // The first physical line of a record is where the record
                // begins, and where it begins is what `Line.offset` reports.
                self.record_offset = self.consumed;
                self.record_number = self.number;
                if (self.frameBuffered()) |frame| {
                    return self.takeFrame(frame, self.options.max_line_bytes);
                }
            }
            return self.readStreamed();
        }

        /// `readPhysical` for every line the frame above did not take: the
        /// first line of a stream, a line that straddles a refill, a record
        /// being joined to in `.pretty` mode, and the end of the stream.
        fn readStreamed(self: *Self) NextError!?[]const u8 {
            const prior = self.line_buf.writer.end;
            var prefix: BomPrefix = .{};
            if (prior == 0) {
                self.record_offset = self.consumed;
                self.record_number = self.number;
            }
            if (!self.bom_checked) {
                self.bom_checked = true;
                if (self.options.skip_bom) prefix = try self.skipBom();
                if (prefix.len != 0)
                    self.line_buf.writer.writeAll(prefix.slice()) catch return error.OutOfMemory;
            }

            const before = self.line_buf.writer.end;
            // The first physical line of a record is where the record begins,
            // and where it begins is what `Line.offset` reports.
            if (before == 0) {
                self.record_offset = self.consumed;
                self.record_number = self.number;
            }
            const max = self.options.max_line_bytes;
            // One past the bound, so that a record of exactly `max` bytes is
            // accepted and the first byte over it is what trips the limit.
            // Saturating, because `Limit` reads a saturated `usize` as
            // unlimited, which is what a bound of `maxInt(usize)` means.
            const room = max -| before;

            // A whole line already in `input`'s buffer is handed back as a
            // slice of it. The bytes have been read once and are not read
            // again, and nothing below this is done at all: framing a line
            // this way costs one scan for the terminator and no copy. What
            // follows is for the line that straddles a refill, which is the
            // only one whose bytes are not all in one place.
            if (before == 0) {
                if (self.frameBuffered()) |frame| return self.takeFrame(frame, room);
            }
            self.borrowed = false;
            self.cleared = false;

            const n = self.input.streamDelimiterLimit(
                &self.line_buf.writer,
                '\n',
                // One byte beyond the record bound may be the `\r` half of
                // its terminator; the next byte distinguishes that from an
                // over-long record.
                .limited(room +| 2),
            ) catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                // The only writer is `line_buf`, which fails only to allocate.
                error.WriteFailed => return error.OutOfMemory,
                error.StreamTooLong => {
                    self.number += 1;
                    self.fault.framing(self.number);
                    self.offset = self.record_offset;
                    self.consumed += self.line_buf.writer.end - before;
                    self.consumed += try self.discardLine();
                    return error.LineTooLong;
                },
            };
            self.consumed += n;

            // `streamDelimiterLimit` stops before the delimiter, so what is
            // next is either it or the end of the stream — unless the stream
            // is a file that grew in between, in which case what is next is
            // the rest of this very line. The byte is looked at rather than
            // taken, so that the third case consumes nothing and reads as
            // what it is: a line that is not finished yet.
            const terminated = if (self.input.peekByte()) |byte| byte == '\n' else |err| switch (err) {
                error.EndOfStream => false,
                error.ReadFailed => return error.ReadFailed,
            };
            if (terminated) {
                self.input.toss(1);
                self.consumed += 1;
            }
            if (!terminated) {
                // Nothing at all is the end of the stream; a final line with
                // no newline is a line unless the caller said otherwise.
                if ((n == 0 and prefix.len == 0) or self.options.require_terminator) {
                    self.line_buf.writer.end = prior;
                    return null;
                }
            }

            const record_len = if (self.line_buf.writer.end > 0 and
                self.line_buf.writer.buffer[self.line_buf.writer.end - 1] == '\r')
                self.line_buf.writer.end - 1
            else
                self.line_buf.writer.end;
            if (record_len > max) {
                self.number += 1;
                self.fault.framing(self.number);
                self.offset = self.record_offset;
                return error.LineTooLong;
            }

            self.number += 1;
            // Tolerate CRLF: the `\r` belongs to the terminator, not the JSON.
            if (self.line_buf.writer.end > before and
                self.line_buf.writer.buffer[self.line_buf.writer.end - 1] == '\r')
            {
                self.line_buf.writer.end -= 1;
            }
            return self.line_buf.written();
        }

        /// A line off `input`'s own buffer: its bytes with the terminator on
        /// the end, and whether framing it also cleared it.
        const Framed = struct {
            /// The line and the `\n` that ends it, `\r` included when there
            /// is one.
            bytes: []const u8,
            /// Whether the scan that found the terminator also passed over
            /// every byte before it and found no control byte among them.
            cleared: bool,
        };

        /// The whole of the next line, terminator included, when `input` is
        /// already holding it; `null` when it is not, which is a line that
        /// straddles a refill or a reader with nothing in hand yet.
        ///
        /// Nothing is read here: what is looked at is what an earlier read
        /// left behind, so a reader whose buffer holds many lines gives all
        /// of them up one after another without touching the stream.
        ///
        /// One scan, not two. The byte that ends a line and the byte that
        /// must not appear raw inside one are the same predicate — below
        /// 0x20 and not a tab — so the first byte that answers it is either
        /// the end of the line or the damage in it, and a line that ends at
        /// its terminator is a line with nothing wrong in it. A reader told
        /// to leave control bytes alone, or reading a stream whose records
        /// begin with a separator that is itself a control byte, looks for
        /// the terminator on its own and says nothing about the rest.
        inline fn frameBuffered(self: *Self) ?Framed {
            const contents = self.input.buffered();
            if (self.options.reject_control_bytes and !self.options.record_separator) {
                var at = firstControlOrTerminator(contents) orelse return null;
                // A `\r` with the terminator behind it is the terminator.
                if (contents[at] == '\r' and at + 1 < contents.len and contents[at + 1] == '\n') {
                    at += 1;
                }
                if (contents[at] == '\n') return .{ .bytes = contents[0 .. at + 1], .cleared = true };
                // A control byte before the terminator: where the line ends
                // is still worth knowing, and the scan over it that says
                // where the byte is happens where it always did.
                const end = std.mem.findScalarPos(u8, contents, at, '\n') orelse return null;
                return .{ .bytes = contents[0 .. end + 1], .cleared = false };
            }
            const end = std.mem.findScalar(u8, contents, '\n') orelse return null;
            return .{ .bytes = contents[0 .. end + 1], .cleared = false };
        }

        /// Takes a framed line off `input` without copying it. `room` is what
        /// is left of the bound; a line past it is discarded here in full,
        /// since it is already known where it ends.
        inline fn takeFrame(self: *Self, frame: Framed, room: usize) NextError!?[]const u8 {
            const line = frame.bytes[0 .. frame.bytes.len - 1];
            const record = trimCr(line);
            self.number += 1;
            self.input.toss(frame.bytes.len);
            self.consumed += frame.bytes.len;
            if (record.len > room) {
                self.fault.framing(self.number);
                self.offset = self.record_offset;
                return error.LineTooLong;
            }
            self.borrowed = true;
            self.cleared = frame.cleared;
            // Tolerate CRLF: the `\r` belongs to the terminator, not the JSON.
            return record;
        }

        /// Consumes a UTF-8 byte-order mark if the stream opens with one.
        /// Called once, before anything else is read.
        ///
        const BomPrefix = struct {
            bytes: [bom.len]u8 = undefined,
            len: usize = 0,

            fn slice(self: *const BomPrefix) []const u8 {
                return self.bytes[0..self.len];
            }
        };

        /// Consumes a UTF-8 byte-order mark one byte at a time. When the
        /// opening bytes are not a mark, returns the bytes already consumed
        /// so the caller can treat them as the start of the first line.
        fn skipBom(self: *Self) NextError!BomPrefix {
            if (self.input.buffer.len >= bom.len) {
                if (self.input.peek(bom.len)) |head| {
                    if (!std.mem.eql(u8, head, bom)) return .{};
                    self.input.toss(bom.len);
                    self.consumed += bom.len;
                    return .{};
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    error.ReadFailed => return error.ReadFailed,
                }
            }

            var prefix: BomPrefix = .{};
            while (prefix.len < bom.len) {
                const byte = self.input.takeByte() catch |err| switch (err) {
                    error.EndOfStream => return prefix,
                    error.ReadFailed => return error.ReadFailed,
                };
                prefix.bytes[prefix.len] = byte;
                self.consumed += 1;
                if (byte != bom[prefix.len]) {
                    prefix.len += 1;
                    return prefix;
                }
                prefix.len += 1;
            }
            prefix.len = 0;
            return prefix;
        }

        /// Discards the remainder of an over-long line, terminator included,
        /// and says how many bytes that was. An over-long line with no
        /// terminator ends the stream, so what it discarded is not counted:
        /// there is no offset after it to be wrong.
        fn discardLine(self: *Self) error{ReadFailed}!u64 {
            return self.input.discardDelimiterInclusive('\n') catch |err| switch (err) {
                // The over-long line was the last one, with no terminator.
                error.EndOfStream => 0,
                error.ReadFailed => error.ReadFailed,
            };
        }
    };
}
