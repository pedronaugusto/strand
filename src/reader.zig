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

const LineReader = @import("line_reader.zig").LineReader;

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

        /// Reading and parsing policy, fixed at `init`. The framing fields
        /// are `LineReader.Options`', under the same names, and are handed to
        /// `lines`; the rest say how a line becomes a `T`.
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

        /// A reader over `input`, with `allocator` backing the line buffer and
        /// the per-line arena. Does not read from `input`.
        pub fn init(allocator: Allocator, input: *std.Io.Reader, options: Options) Self {
            return .resumeAt(allocator, input, options, .{});
        }

        /// A reader over an `input` already positioned part-way into a file,
        /// numbering and placing its lines as if it had read the rest. See
        /// `LineReader.resumeAt`, which this is over.
        pub fn resumeAt(
            allocator: Allocator,
            input: *std.Io.Reader,
            options: Options,
            start: Start,
        ) Self {
            return .{
                .lines = .resumeAt(allocator, input, options.framing(), start),
                .options = options,
                .arena = .init(allocator),
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
            while (true) {
                const raw = (try self.lines.next()) orelse return null;
                if (try self.parse(raw)) |line| return line;
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
        pub fn nextRaw(self: *Self) NextError!?RawLine {
            return self.lines.next();
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
                        switch (try self.lines.join(raw.number, record)) {
                            .grown => |joined| {
                                record = joined;
                                continue;
                            },
                            // The record is damaged rather than unfinished,
                            // and the line reader has already said where and
                            // counted it: saying anything else here would
                            // replace the true diagnosis with a guess.
                            .damaged => return null,
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
    };
}
