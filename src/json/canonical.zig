//! The JSON Canonicalization Scheme (RFC 8785): one spelling for every JSON
//! value, for hashing and signing. Members are sorted by their names' UTF-16
//! code units, numbers are IEEE 754 doubles written as ECMAScript writes them,
//! strings escape what ECMAScript escapes and nothing else, and there is no
//! whitespace. A name given twice is refused. JSON text has one kind of
//! number, and JCS reads every one as the double nearest it; a typed value
//! knows its integers, and one past ±(2^53−1), which a reader taking it for a
//! JavaScript number would not get back, is refused: it needs a string codec.
//! A failure can leave a prefix written, as `json.write`'s can.
const std = @import("std");
const core = @import("../core.zig");
const api = @import("api.zig");
const Value = @import("Value.zig").Value;
const Member = @import("Value.zig").Member;

pub const Options = struct {
    limits: core.Limits = .{},
};
pub const Error = core.DecodeError || core.EncodeError || std.Io.Writer.Error;

/// `value` in canonical form: written as JSON first, then read back as a
/// `json.Value` and written canonically. `gpa` holds the two in between.
pub fn write(gpa: std.mem.Allocator, output: *std.Io.Writer, value: anytype, options: Options) (Error || api.WriteError(@TypeOf(value)))!void {
    try checkIntegers(value, options);
    var scratch: std.Io.Writer.Allocating = .init(gpa);
    defer scratch.deinit();
    api.write(&scratch.writer, value, .{ .limits = options.limits }) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
    return canonicalize(gpa, output, scratch.written(), options);
}

/// Refuses an integer in `value` past ±(2^53−1), by writing it through a
/// backend that checks integers and writes nothing.
fn checkIntegers(value: anytype, options: Options) (core.EncodeError || error{WriteFailed})!void {
    var no_scratch: [0]u8 = .{};
    var fixed: std.heap.FixedBufferAllocator = .init(&no_scratch);
    var c = core.Context.init(fixed.allocator(), options.limits, .borrowed);
    var check: IntegerCheck = .{};
    try core.serialize(value, &check, &c);
}
const IntegerCheck = struct {
    pub const Format = api.Format;
    pub const capabilities = api.capabilities;
    pub const canonical = true;
    pub const Error = core.EncodeError || error{WriteFailed};
    const Self = @This();
    pub fn integer(_: *Self, value: anytype, _: *core.Context) Self.Error!void {
        const limit = (1 << 53) - 1;
        if (value > limit or value < -limit) return error.NumberOutOfRange;
    }
    pub fn boolean(_: *Self, _: bool, _: *core.Context) Self.Error!void {}
    pub fn floating(_: *Self, _: anytype, _: *core.Context) Self.Error!void {}
    pub fn text(_: *Self, _: []const u8, _: *core.Context) Self.Error!void {}
    pub fn key(_: *Self, _: []const u8, _: *core.Context) Self.Error!void {}
    pub fn bytes(_: *Self, _: []const u8, _: *core.Context) Self.Error!void {}
    pub fn scalar(_: *Self, _: u21, _: *core.Context) Self.Error!void {}
    pub fn nullValue(_: *Self, _: *core.Context) Self.Error!void {}
    pub fn unit(_: *Self, _: *core.Context) Self.Error!void {}
    pub fn begin(_: *Self, _: core.Kind, _: []const u8, _: usize, _: *core.Context) Self.Error!void {}
    pub fn end(_: *Self, _: *core.Context) Self.Error!void {}
    pub fn validateRaw(_: *Self, _: []const u8, _: *core.Context) Self.Error!void {}
    pub fn raw(_: *Self, _: []const u8, _: *core.Context) Self.Error!void {}
};

/// The JSON text `input`, canonical.
pub fn canonicalize(gpa: std.mem.Allocator, output: *std.Io.Writer, input: []const u8, options: Options) Error!void {
    var parsed = try api.parse(Value, gpa, input, .{ .limits = options.limits, .duplicates = .reject });
    defer parsed.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try emit(arena.allocator(), output, parsed.value);
}

fn emit(a: std.mem.Allocator, out: *std.Io.Writer, value: Value) Error!void {
    switch (value) {
        .null_value => try out.writeAll("null"),
        .boolean => |b| try out.writeAll(if (b) "true" else "false"),
        .number => |lexeme| try number(out, lexeme),
        .string => |s| try string(out, s),
        .array => |items| {
            try out.writeByte('[');
            for (items, 0..) |item, i| {
                if (i != 0) try out.writeByte(',');
                try emit(a, out, item);
            }
            try out.writeByte(']');
        },
        .object => |members| {
            const sorted = try a.dupe(Member, members);
            std.mem.sort(Member, sorted, {}, struct {
                fn less(_: void, x: Member, y: Member) bool {
                    return utf16Less(x.key, y.key);
                }
            }.less);
            try out.writeByte('{');
            for (sorted, 0..) |member, i| {
                if (i != 0) try out.writeByte(',');
                try string(out, member.key);
                try out.writeByte(':');
                try emit(a, out, member.value);
            }
            try out.writeByte('}');
        },
    }
}

/// Whether `a` sorts before `b` by UTF-16 code units, as RFC 8785 sorts
/// names: by code point, but a code point past U+FFFF as its surrogates,
/// which sort before U+E000 to U+FFFF.
fn utf16Less(a: []const u8, b: []const u8) bool {
    var x = std.unicode.Utf8View.initUnchecked(a).iterator();
    var y = std.unicode.Utf8View.initUnchecked(b).iterator();
    while (true) {
        const p = x.nextCodepoint() orelse return y.nextCodepoint() != null;
        const q = y.nextCodepoint() orelse return false;
        if (p == q) continue;
        return unit(p) < unit(q) or (unit(p) == unit(q) and p < q);
    }
}
/// A code point's first UTF-16 code unit.
fn unit(cp: u21) u16 {
    if (cp < 0x10000) return @intCast(cp);
    return @intCast(0xd800 + ((cp - 0x10000) >> 10));
}

/// A string as ECMAScript's `JSON.stringify` writes it.
fn string(out: *std.Io.Writer, s: []const u8) Error!void {
    try out.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |byte, i| {
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x0c => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...0x07, 0x0b, 0x0e...0x1f => null,
            else => continue,
        };
        try out.writeAll(s[start..i]);
        if (escape) |e| try out.writeAll(e) else try out.print("\\u{x:0>4}", .{byte});
        start = i + 1;
    }
    try out.writeAll(s[start..]);
    try out.writeByte('"');
}

/// A number lexeme as the double it is, written as ECMAScript's
/// `Number.prototype.toString` writes it (ECMA-262, 7.1.12.1).
fn number(out: *std.Io.Writer, lexeme: []const u8) Error!void {
    const v = std.fmt.parseFloat(f64, lexeme) catch return error.NumberOutOfRange;
    if (!std.math.isFinite(v)) return error.NumberOutOfRange;
    var buffer: [64]u8 = undefined;
    try out.writeAll(ecmascript(&buffer, v));
}

/// `v`, finite, as ECMAScript writes a Number.
pub fn ecmascript(buffer: *[64]u8, v: f64) []const u8 {
    if (v == 0) return "0";
    var at: usize = 0;
    if (v < 0) {
        buffer[0] = '-';
        at = 1;
    }
    // The shortest digits that read back as `v`, and the exponent of the first.
    var scientific: [64]u8 = undefined;
    const spelled = std.fmt.float.render(&scientific, @abs(v), .{}) catch unreachable; // unreachable: 64 bytes hold any double's shortest form
    const e_at = std.mem.findScalar(u8, spelled, 'e').?;
    var digits: [20]u8 = undefined;
    var k: usize = 0;
    for (spelled[0..e_at]) |c| if (c != '.') {
        digits[k] = c;
        k += 1;
    };
    const s = digits[0..k];
    const n = (std.fmt.parseInt(i32, spelled[e_at + 1 ..], 10) catch unreachable) + 1; // unreachable: render writes a decimal exponent
    const put = struct {
        fn bytes(b: *[64]u8, i: *usize, data: []const u8) void {
            @memcpy(b[i.*..][0..data.len], data);
            i.* += data.len;
        }
        fn zeros(b: *[64]u8, i: *usize, count: usize) void {
            @memset(b[i.*..][0..count], '0');
            i.* += count;
        }
    };
    const kk: i32 = @intCast(k);
    if (kk <= n and n <= 21) {
        put.bytes(buffer, &at, s);
        put.zeros(buffer, &at, @intCast(n - kk));
    } else if (0 < n and n <= 21) {
        put.bytes(buffer, &at, s[0..@intCast(n)]);
        put.bytes(buffer, &at, ".");
        put.bytes(buffer, &at, s[@intCast(n)..]);
    } else if (-6 < n and n <= 0) {
        put.bytes(buffer, &at, "0.");
        put.zeros(buffer, &at, @intCast(-n));
        put.bytes(buffer, &at, s);
    } else {
        put.bytes(buffer, &at, s[0..1]);
        if (k > 1) {
            put.bytes(buffer, &at, ".");
            put.bytes(buffer, &at, s[1..]);
        }
        put.bytes(buffer, &at, if (n - 1 < 0) "e-" else "e+");
        var exponent: [8]u8 = undefined;
        put.bytes(buffer, &at, std.mem.print(&exponent, "{d}", .{@abs(n - 1)}) catch unreachable); // unreachable: an exponent has at most three digits
    }
    return buffer[0..at];
}
