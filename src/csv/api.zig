//! CSV (RFC 4180) on Strand's shared type mapping and ownership core: whole
//! documents, and rows streamed off a reader on JSON Lines' line framing.
const std = @import("std");
const aegis = @import("aegis");
const core = @import("../core.zig");
const WireDecoder = @import("Decoder.zig");
const WireEncoder = @import("Encoder.zig");
const fields = @import("text.zig");
const LineReader = @import("../jsonl/line/reader.zig").LineReader;
pub const Format = WireDecoder.Format;
pub const capabilities = WireDecoder.capabilities;
pub const Dialect = fields.Dialect;
pub const Parsed = core.Parsed;
pub const ParseOptions = struct {
    limits: core.Limits = .{},
    dialect: Dialect = .{},
    /// A column the type does not have is refused unless this says to skip it.
    ignore_unknown_fields: bool = false,
    diagnostics: ?*core.Diagnostics = null,
};
fn Decode(comptime T: type) type {
    return struct {
        const Error = @typeInfo(@TypeOf(core.deserialize(T, @as(*WireDecoder, undefined), @as(*core.Context, undefined)))).error_union.error_set;
        fn run(c: *core.Context, input: []const u8, dialect: Dialect) Error!T {
            aegis.assert.pre(dialect.valid(), "the delimiter and the quote are two bytes, neither a line break");
            try c.input(input.len);
            var decoder: WireDecoder = undefined;
            decoder.init(c, input);
            decoder.dialect = dialect;
            defer decoder.deinit();
            return core.deserialize(T, &decoder, c) catch |err| {
                if (err == error.OutOfMemory and c.allocation_limited) return error.AllocationLimit;
                return err;
            };
        }
        /// The decoder with its dialect, as acquisition calls it.
        pub const Runner = struct {
            dialect: Dialect,
            pub fn run(self: Runner, c: *core.Context, input: []const u8) Error!T {
                return Decode(T).run(c, input, self.dialect);
            }
        };
    };
}
fn acceptance(options: ParseOptions) core.Acceptance {
    return .{ .reject_unknown_fields = !options.ignore_unknown_fields };
}
fn parseWith(comptime T: type, comptime ownership: core.Ownership, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(core.acquireWith(T, ownership, gpa, input, .{}, Decode(T).Runner{ .dialect = .{} }))).error_union.error_set!Parsed(T) {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "csv";
    }
    return core.acquireWith(T, ownership, gpa, input, .{
        .limits = options.limits,
        .acceptance = acceptance(options),
        .diagnostics = options.diagnostics,
    }, Decode(T).Runner{ .dialect = options.dialect });
}
/// The rows of a CSV document, as a slice or array of `Row`: a struct, read
/// by the header's names, or a tuple or array, read by position. Fields are
/// borrowed from `input` where no doubled quote is in them; `input` outlives
/// the result, whose `deinit` releases only what it allocated.
pub fn parse(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .borrowed, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .borrowed, gpa, input, options);
}
/// The rows, independent of `input`: every retained span is copied.
pub fn parseOwned(comptime T: type, gpa: std.mem.Allocator, input: []const u8, options: ParseOptions) @typeInfo(@TypeOf(parseWith(T, .owned, gpa, input, options))).error_union.error_set!Parsed(T) {
    return parseWith(T, .owned, gpa, input, options);
}
/// Bounds requests per operation; caller-owned arena backing and reset are external.
pub fn parseLeaky(comptime T: type, arena: std.mem.Allocator, input: []const u8, options: ParseOptions) Decode(T).Error!T {
    if (options.diagnostics) |d| {
        d.* = .{};
        d.format = "csv";
    }
    if (input.len > options.limits.input_bytes) return error.InputLimit;
    var c = core.Context.init(arena, options.limits, .borrowed);
    c.acceptance = acceptance(options);
    c.diagnostics = options.diagnostics;
    return Decode(T).run(&c, input, options.dialect);
}

pub const WriteOptions = struct {
    limits: core.Limits = .{},
    dialect: Dialect = .{},
};
/// The header's names for rows of `Row`: a struct's fields as they are
/// written; none for a tuple or an array.
fn names(comptime Row: type) []const []const u8 {
    const info = @typeInfo(Row);
    if (info == .@"struct" and !info.@"struct".is_tuple) return comptime core.wireNames(Row);
    return &.{};
}
/// Streams a CSV document: `rows` (a slice or array of struct, tuple or array
/// rows), the header first when the dialect has one and the rows are structs.
/// A sink failure may publish a prefix; write into a fixed or allocating
/// writer first where nothing must reach the sink unless all of it does.
pub fn write(output: *std.Io.Writer, rows: anytype, options: WriteOptions) @typeInfo(@TypeOf(core.serialize(rows, @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set!void {
    aegis.assert.pre(options.dialect.valid(), "the delimiter and the quote are two bytes, neither a line break");
    const Row = std.meta.Elem(@TypeOf(rows));
    const header = names(Row);
    var no_scratch: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&no_scratch);
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    var encoder: WireEncoder = undefined;
    encoder.init(output, options.dialect, .document, header, options.dialect.header and header.len != 0);
    try core.serialize(rows, &encoder, &c);
}

/// Rows of `T` written one at a time, the header before the first: for a
/// table that is produced as it goes.
pub fn Writer(comptime T: type) type {
    return struct {
        const Self = @This();
        output: *std.Io.Writer,
        options: WriteOptions,
        /// Whether the header is still to be written.
        header_pending: bool,

        pub fn init(output: *std.Io.Writer, options: WriteOptions) Self {
            aegis.assert.pre(options.dialect.valid(), "the delimiter and the quote are two bytes, neither a line break");
            return .{ .output = output, .options = options, .header_pending = options.dialect.header and names(T).len != 0 };
        }
        /// One row, and the header first if it has not been written.
        pub fn write(self: *Self, row: T) @typeInfo(@TypeOf(core.serialize(row, @as(*WireEncoder, undefined), @as(*core.Context, undefined)))).error_union.error_set!void {
            var no_scratch: [0]u8 = .{};
            var fixed: std.heap.FixedBufferAllocator = .init(&no_scratch);
            var c = core.Context.init(fixed.allocator(), self.options.limits, .borrowed);
            var encoder: WireEncoder = undefined;
            encoder.init(self.output, self.options.dialect, .row, names(T), self.header_pending);
            try core.serialize(row, &encoder, &c);
            self.header_pending = false;
        }
    };
}

/// Rows of `T` read one at a time off a `*std.Io.Reader`, on JSON Lines' line
/// framing: a row is a line, joined with the lines after it while a quoted
/// field is open, and held to `max_row_bytes`. The header, when the dialect
/// has one, is the first row and is read for the names; blank lines are
/// passed over. A row is parsed on an arena kept for it alone, so a value
/// lives until the next `next` unless it is copied out.
pub fn Reader(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Options = struct {
            parse: ParseOptions = .{},
            /// The longest row accepted, its line breaks included. A longer
            /// one is `error.LineTooLong`, and the reader moves on past it.
            max_row_bytes: usize = 1 << 20,
        };
        pub const Row = struct {
            value: T,
            /// The row's number, the header not counted: 1 for the first.
            number: u64,
            /// The number of the line the row starts on, and where it starts.
            line: u64,
            offset: u64,
        };
        /// `LineReader`'s errors, and `MalformedRow` for a row that is not a
        /// `T` (its error in `fault`) or a quoted field the stream ended in.
        pub const NextError = LineReader.NextError || error{MalformedRow};

        lines: LineReader,
        options: Options,
        arena: std.heap.ArenaAllocator,
        /// The header's names, owned here.
        header: std.heap.ArenaAllocator,
        names: []const core.Span = &.{},
        header_done: bool,
        rows: u64 = 0,
        /// What the last malformed row was refused for, and its line.
        fault: struct { line: u64 = 0, err: ?core.DecodeError = null } = .{},

        pub fn init(gpa: std.mem.Allocator, input: *std.Io.Reader, options: Options) Self {
            aegis.assert.pre(options.parse.dialect.valid(), "the delimiter and the quote are two bytes, neither a line break");
            return .{
                .lines = .init(gpa, input, .{
                    .max_line_bytes = options.max_row_bytes,
                    .skip_blank = true,
                    // A row keeps its `\r` and its raw bytes: a quoted field
                    // may hold either, and the row's grammar says what they are.
                    .crlf = false,
                    .reject_control_bytes = false,
                }),
                .options = options,
                .arena = .init(gpa),
                .header = .init(gpa),
                .header_done = !options.parse.dialect.header,
            };
        }
        pub fn deinit(self: *Self) void {
            self.lines.deinit();
            self.arena.deinit();
            self.header.deinit();
            self.* = undefined;
        }

        /// The next row's bytes, joined across the line breaks inside its
        /// quoted fields, without its own line ending.
        const Record = struct { bytes: []const u8, line: u64, offset: u64 };
        fn record(self: *Self) NextError!?Record {
            while (true) {
                const r = (try self.recordOrBlank()) orelse return null;
                // A blank line is no row: its `\r` was all it held.
                if (r.bytes.len != 0) return r;
            }
        }
        fn recordOrBlank(self: *Self) NextError!?Record {
            const first = (try self.lines.next()) orelse return null;
            var bytes = first.line;
            while (fields.open(bytes, self.options.parse.dialect.quote)) {
                switch (try self.lines.join(first.number, bytes)) {
                    .grown => |grown| bytes = grown,
                    .ended => {
                        self.fault = .{ .line = first.number, .err = error.SyntaxError };
                        return error.MalformedRow;
                    },
                    .damaged => unreachable, // unreachable: control bytes are not refused here
                }
            }
            if (bytes.len > 0 and bytes[bytes.len - 1] == '\r') bytes = bytes[0 .. bytes.len - 1];
            return .{ .bytes = bytes, .line = first.number, .offset = first.offset };
        }

        /// The next row, or null at the end of the stream.
        pub fn next(self: *Self) NextError!?Row {
            _ = self.arena.reset(.retain_capacity);
            if (!self.header_done) {
                const head = (try self.record()) orelse return null;
                self.header_done = true;
                self.names = self.readNames(head.bytes) catch |err| {
                    self.fault = .{ .line = head.line, .err = err };
                    return error.MalformedRow;
                };
            }
            const row = (try self.record()) orelse return null;
            const options = self.options.parse;
            var c = core.Context.init(self.arena.allocator(), options.limits, .borrowed);
            c.acceptance = acceptance(options);
            c.diagnostics = options.diagnostics;
            const value = self.parseRow(&c, row.bytes) catch |err| {
                self.fault = .{ .line = row.line, .err = err };
                return error.MalformedRow;
            };
            self.rows += 1;
            return .{ .value = value, .number = self.rows, .line = row.line, .offset = row.offset };
        }

        fn parseRow(self: *Self, c: *core.Context, bytes: []const u8) Decode(T).Error!T {
            try c.input(bytes.len);
            var decoder: WireDecoder = undefined;
            decoder.init(c, bytes);
            decoder.dialect = self.options.parse.dialect;
            decoder.mode = .row;
            decoder.names = self.names;
            decoder.header_read = true;
            defer decoder.deinit();
            return core.deserialize(T, &decoder, c);
        }

        /// The header's names, copied into the reader's own arena.
        fn readNames(self: *Self, bytes: []const u8) core.DecodeError![]const core.Span {
            const options = self.options.parse;
            var c = core.Context.init(self.header.allocator(), options.limits, .owned);
            const Names = []const []const u8;
            var decoder: WireDecoder = undefined;
            decoder.init(&c, bytes);
            decoder.dialect = options.dialect;
            decoder.dialect.header = false;
            decoder.mode = .row;
            decoder.header_read = true;
            defer decoder.deinit();
            const list = try core.deserialize(Names, &decoder, &c);
            const spans = try c.alloc(core.Span, list.len);
            for (spans, list) |*span, name| span.* = .{ .bytes = name, .lifetime = .owned };
            return spans;
        }
    };
}
