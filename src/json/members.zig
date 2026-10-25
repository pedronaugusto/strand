//! The members of a JSON object, one at a time, read off its bytes on
//! demand: each member's name and value as the bytes they are written as,
//! and where they lie, with nothing allocated and nothing read past the
//! member asked for.

const std = @import("std");
const core = @import("../core.zig");
const decoding = @import("Decoder.zig");
const strings = @import("text.zig");

const Wire = decoding.Dialect(.json);

/// What reading a member can fail with: the bytes are not JSON
/// (`SyntaxError`), the value is JSON but not an object (`UnexpectedType`),
/// or a limit was reached.
pub const MembersError = error{ SyntaxError, UnexpectedType, InputLimit, DepthLimit, ItemLimit, LengthLimit, WorkLimit };

pub const MembersOptions = struct {
    /// The limits of every strand read. Nesting is held to `Members.max_depth`
    /// whatever `limits.depth` says.
    limits: core.Limits = .{},
};

/// One member of the object, as it is written.
pub const Member = struct {
    /// The name between its quotes, escapes as written: `is` compares it with
    /// a name, `nameInto` unescapes it.
    name: []const u8,
    /// The value: one complete JSON value, checked, with nothing before or
    /// after it. `json.intOf` reads an integer out of it; `json.parseLeaky`
    /// reads it as any type; `Members` reads an object's members in turn.
    value: []const u8,
    /// The offset of the byte before the member: the `,` after the member
    /// before it, or the `{` that opens the object for the first. The bytes
    /// up to it are everything the object holds before this member.
    separator: usize,
    /// The offset of the member's first byte, the quote that opens its name.
    start: usize,
    /// The offset of the value's first byte.
    value_start: usize,
    /// Whether the name has an escape in it.
    escaped: bool,

    /// The offset just past the value's last byte.
    pub fn valueEnd(member: Member) usize {
        return member.value_start + member.value.len;
    }

    /// Whether the name is `text` once unescaped: `"s\u0065q"` is `seq`.
    /// A name written plain is compared as it lies, and nothing is allocated
    /// for one that is not.
    pub inline fn is(member: Member, text: []const u8) bool {
        if (!member.escaped) return member.name.len == text.len and std.mem.eql(u8, member.name, text);
        return strings.spells(member.name, text);
    }

    /// Which of `names` the name is once unescaped, as an index into them, or
    /// null for none: `is` for each, with the comparisons laid out at compile
    /// time, so a reader picking its members out of a line pays a length
    /// check for each name the member is not.
    pub inline fn which(member: Member, comptime names: []const []const u8) ?usize {
        if (!member.escaped) {
            inline for (names, 0..) |name, i| {
                if (member.name.len == name.len and plainIs(member.name, name)) return i;
            }
            return null;
        }
        inline for (names, 0..) |name, i| if (strings.spells(member.name, name)) return i;
        return null;
    }

    inline fn plainIs(name: []const u8, comptime text: []const u8) bool {
        if (comptime std.mem.findScalar(u8, text, '\\') != null) return false;
        inline for (text, 0..) |b, k| if (name[k] != b) return false;
        return true;
    }

    /// The name unescaped into `buffer`; `error.NoSpaceLeft` when it does not
    /// fit. A buffer as long as `name` always holds it.
    pub fn nameInto(member: Member, buffer: []u8) error{NoSpaceLeft}![]u8 {
        if (buffer.len < member.name.len and buffer.len < strings.unescapedLength(member.name, .refuse)) return error.NoSpaceLeft;
        if (buffer.len >= member.name.len) return buffer[0..strings.unescape(member.name, buffer, .refuse)];
        // Shorter than the name as written, and long enough for its text.
        var decoded: strings.Unescaped = .{ .rest = member.name };
        var n: usize = 0;
        while (decoded.next()) |b| : (n += 1) buffer[n] = b;
        return buffer[0..n];
    }
};

/// The members of the JSON object `bytes` holds, in the order they are
/// written, read as they are asked for: a reader that wants a few members of
/// a long line reads up to the last of them and stops, and whatever comes
/// after is never looked at. What is read is read by the decoder every JSON
/// parse uses, with the same grammar and the same limits: every value passed
/// over is checked as `json.Raw` checks one, whitespace may be anywhere JSON
/// allows it, and names may be escaped. Duplicate names are handed over as
/// they come, each in its place; telling them apart is the caller's.
///
/// Nothing is allocated: names and values are views into `bytes`, which must
/// outlive them, and nesting is held to `max_depth`.
///
/// ```
/// var members: json.Members = undefined;
/// members.init(line, .{});
/// while (try members.next()) |member| {
///     if (member.is("id")) id = json.intOf(u64, member.value);
/// }
/// ```
///
/// `next` returns null at the object's closing brace. `finish` reads to it,
/// checks that nothing but whitespace follows, and says where the object
/// ends: a reader that stopped early learns no more of the bytes than it
/// read, and one that called `finish` knows they are one JSON object. After
/// an error the iterator answers that error again.
pub const Members = struct {
    /// How deep a value may nest, the object itself counted: the decoder's
    /// own frames, which is also strand's default depth limit.
    pub const max_depth = @typeInfo(@FieldType(Wire, "frames")).array.len;

    decoder: Wire,
    context: core.Context,
    phase: Phase,
    /// The `{` that opens the object.
    open_at: usize,
    /// Members read so far.
    count: usize,
    /// Where the object ends, once it has.
    end_at: usize,

    const Phase = union(enum) { before, inside, after, failed: MembersError };

    /// Starts over `bytes`, where `members` lies: a decoder's frames are
    /// kilobytes, which a value handed back would build and then copy.
    pub fn init(members: *Members, bytes: []const u8, options: MembersOptions) void {
        var limits = options.limits;
        limits.depth = @min(limits.depth, max_depth);
        // Nothing is allocated: names, strings and values are checked where
        // they lie, keys are not remembered, and nesting stays in the frames.
        members.context = .init(.failing, limits, .borrowed);
        members.decoder.init(&members.context, bytes);
        members.decoder.checking = true;
        members.phase = .before;
        members.open_at = 0;
        members.count = 0;
        members.end_at = 0;
    }

    /// The next member, or null where the object closes.
    pub fn next(members: *Members) MembersError!?Member {
        return members.step() catch |err| {
            members.phase = .{ .failed = err };
            return err;
        };
    }

    inline fn step(members: *Members) MembersError!?Member {
        switch (members.phase) {
            .before => try members.open(),
            .inside => {},
            .after => return null,
            .failed => |err| return err,
        }
        const c = &members.context;
        const d = &members.decoder;
        const found = (d.passMember(c, &members.count) catch |err| return refused(err)) orelse {
            c.leave();
            members.phase = .after;
            members.end_at = d.last_end;
            return null;
        };
        return .{
            .name = found.name,
            .value = d.input[found.value_start..found.value_end],
            .separator = if (members.count == 1) members.open_at else found.separator,
            // The name is a view into the input, past its opening quote.
            .start = @intFromPtr(found.name.ptr) - @intFromPtr(d.input.ptr) - 1, // safe: a checked name is borrowed from the input, never copied
            .value_start = found.value_start,
            .escaped = found.escaped,
        };
    }

    fn open(members: *Members) MembersError!void {
        const c = &members.context;
        const d = &members.decoder;
        try c.input(d.input.len);
        try c.node();
        try c.chargeWork(1);
        members.open_at = d.at;
        const opened = d.open(c, .{ .expected = .record }) catch |err| return refused(err);
        if (opened == null) {
            // Some other value, refused at its first token as a parse into a
            // struct refuses it, or no value at all.
            _ = d.next(c, .{ .expected = .record }) catch |err| return refused(err);
            return error.UnexpectedType;
        }
        try c.enter();
        members.phase = .inside;
    }

    /// Reads the members left, then checks that nothing but whitespace
    /// follows the object. Returns the offset just past its closing brace.
    pub fn finish(members: *Members) MembersError!usize {
        while (try members.next()) |_| {}
        members.decoder.endInput(&members.context) catch |err| {
            const refusal = refused(err);
            members.phase = .{ .failed = refusal };
            return refusal;
        };
        return members.end_at;
    }

    fn refused(err: core.DecodeError) MembersError {
        return switch (err) {
            error.InputLimit, error.DepthLimit, error.ItemLimit, error.LengthLimit, error.WorkLimit => |e| e,
            // unreachable: nothing in reading allocates (`init`).
            error.OutOfMemory, error.AllocationLimit => unreachable,
            // A value that is not one JSON value, however the decoder put it.
            else => error.SyntaxError,
        };
    }
};

const testing = std.testing;

test Members {
    const line = "{\"seq\":7, \"s\\u0065q\" : [1,{\"a\":\"\\\"\"}] ,\"ev\":{\"x\":1},\"c\":42}";
    var members: Members = undefined;
    members.init(line, .{});
    const first = (try members.next()).?;
    try testing.expectEqualStrings("seq", first.name);
    try testing.expectEqualStrings("7", first.value);
    try testing.expectEqual(@as(usize, 0), first.separator);
    try testing.expectEqual(@as(usize, 1), first.start);
    const second = (try members.next()).?;
    try testing.expect(second.is("seq"));
    try testing.expectEqual(@as(?usize, 1), second.which(&.{ "at", "seq" }));
    try testing.expectEqual(@as(?usize, 0), first.which(&.{ "seq", "seq" }));
    try testing.expectEqual(@as(?usize, null), first.which(&.{ "se", "seqq", "s\\u0065q", "" }));
    try testing.expect(!second.is("s\\u0065q"));
    var buffer: [3]u8 = undefined;
    try testing.expectEqualStrings("seq", try second.nameInto(&buffer));
    try testing.expectError(error.NoSpaceLeft, second.nameInto(buffer[0..2]));
    try testing.expectEqualStrings("[1,{\"a\":\"\\\"\"}]", second.value);
    try testing.expectEqual(@as(u8, ','), line[second.separator]);
    try testing.expectEqual(@as(u8, '"'), line[second.start]);
    try testing.expectEqual(second.valueEnd(), second.value_start + second.value.len);
    _ = (try members.next()).?;
    const last = (try members.next()).?;
    try testing.expect(last.is("c"));
    try testing.expectEqualStrings("{\"seq\":7, \"s\\u0065q\" : [1,{\"a\":\"\\\"\"}] ,\"ev\":{\"x\":1}", line[0..last.separator]);
    try testing.expectEqual(@as(?Member, null), try members.next());
    try testing.expectEqual(line.len, try members.finish());
}

test "a member is read only as far as it is asked for" {
    var members: Members = undefined;
    members.init("{\"a\":1,\"b\":nonsense", .{});
    try testing.expectEqualStrings("1", (try members.next()).?.value);
    try testing.expectError(error.SyntaxError, members.next());
    try testing.expectError(error.SyntaxError, members.next());
    try testing.expectError(error.SyntaxError, members.finish());
}

test "what is not an object is said to be one, or not JSON" {
    for ([_]struct { []const u8, MembersError }{
        .{ "[1]", error.UnexpectedType },
        .{ " \"x\" ", error.UnexpectedType },
        .{ "7", error.UnexpectedType },
        .{ "", error.SyntaxError },
        .{ "  ", error.SyntaxError },
        .{ "}", error.SyntaxError },
        .{ "{", error.SyntaxError },
        .{ "{\"a\"}", error.SyntaxError },
        .{ "{\"a\":1,}", error.SyntaxError },
        .{ "{\"a\":1 \"b\":2}", error.SyntaxError },
        .{ "{\"a\":\"\xff\"}", error.SyntaxError },
        .{ "{\"a\":01}", error.SyntaxError },
        .{ "{\"a\":[1}}", error.SyntaxError },
    }) |case| {
        var members: Members = undefined;
        members.init(case[0], .{});
        try testing.expectError(case[1], members.finish());
    }
    var members: Members = undefined;
    members.init("{} x", .{});
    try testing.expectEqual(@as(?Member, null), try members.next());
    try testing.expectError(error.SyntaxError, members.finish());
    members.init(" {}\n", .{});
    try testing.expectEqual(@as(usize, 3), try members.finish());
}

/// A JSON value's bytes, a member's `value`, as a `T` when they are an
/// integer written as one: an optional `-`, then digits with no zero in front
/// of others, and nothing else, which `T` holds. Null for anything else, a
/// number with a fraction or an exponent among it.
pub fn intOf(comptime T: type, bytes: []const u8) ?T {
    const bits = @typeInfo(T).int.bits;
    const negative = bytes.len != 0 and bytes[0] == '-';
    const digits = bytes[@intFromBool(negative)..];
    // JSON's integer: at least one digit, and no zero in front of others.
    if (digits.len == 0 or (digits[0] == '0' and digits.len > 1)) return null;
    if (bits > 64 or digits.len > 19) {
        for (digits) |d| if (d -% '0' > 9) return null;
        return std.fmt.parseInt(T, bytes, 10) catch null;
    }
    // Nineteen digits always fit the accumulator.
    var magnitude: u64 = 0;
    for (digits) |d| {
        const digit = d -% '0';
        if (digit > 9) return null;
        magnitude = magnitude * 10 + digit;
    }
    if (@typeInfo(T).int.signedness == .unsigned) {
        if (negative and magnitude != 0) return null;
        return std.math.cast(T, magnitude);
    }
    if (negative) {
        if (magnitude > @as(u64, 1) << (bits - 1)) return null;
        return @intCast(-@as(i65, magnitude)); // safe: at most the magnitude of the signed minimum.
    }
    return std.math.cast(T, magnitude);
}

fn decimal(buffer: []u8, value: anytype) ![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    try out.print("{d}", .{value});
    return out.buffered();
}

test intOf {
    try testing.expectEqual(@as(?i64, -12), intOf(i64, "-12"));
    try testing.expectEqual(@as(?u32, 0), intOf(u32, "0"));
    try testing.expectEqual(@as(?u32, 0), intOf(u32, "-0"));
    for ([_][]const u8{ "7.0", "7e0", "07", "\"7\"", "", "-", " 7", "7 ", "null", "4294967296", "-1", "+1", "1_0", "-01" }) |other|
        try testing.expectEqual(@as(?u32, null), intOf(u32, other));
    // Every width at its edges, and past them, the wide ones too.
    inline for (.{ i8, u8, i64, u64, i128, u128, u0, i1 }) |T| {
        var buffer: [48]u8 = undefined;
        try testing.expectEqual(@as(?T, std.math.maxInt(T)), intOf(T, try decimal(&buffer, std.math.maxInt(T))));
        try testing.expectEqual(@as(?T, std.math.minInt(T)), intOf(T, try decimal(&buffer, std.math.minInt(T))));
        try testing.expectEqual(@as(?T, null), intOf(T, try decimal(&buffer, @as(i256, std.math.maxInt(T)) + 1)));
        try testing.expectEqual(@as(?T, null), intOf(T, try decimal(&buffer, @as(i256, std.math.minInt(T)) - 1)));
    }
    try testing.expectEqual(@as(?u64, 9999999999999999999), intOf(u64, "9999999999999999999"));
    try testing.expectEqual(@as(?u64, null), intOf(u64, "99999999999999999999"));
}
