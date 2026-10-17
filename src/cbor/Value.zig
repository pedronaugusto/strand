//! A CBOR data item of any shape, its distinctions kept: unsigned and negative
//! integers down to -2^64, byte strings apart from text, tags, simple values,
//! `undefined` apart from `null`, and a map's keys of any kind, in order.
const std = @import("std");
pub const Entry = struct { key: Value, value: Value };
pub const Tagged = struct { number: u64, value: *const Value };
pub const Value = union(enum) {
    /// Null is one of its values: it reads null itself.
    pub const strand_nullable = true;
    unsigned: u64,
    /// -1 - n.
    negative: u64,
    bytes: []const u8,
    text: []const u8,
    array: []const Value,
    map: []const Entry,
    tag: Tagged,
    boolean: bool,
    null_value,
    undefined,
    /// A simple value other than false, true, null and undefined.
    simple: u8,
    float: f64,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Value {
        return switch (try access.peek()) {
            .integer => {
                const v = try access.read(i65);
                return if (v >= 0) .{ .unsigned = @intCast(v) } else .{ .negative = @intCast(-1 - v) };
            },
            .floating => .{ .float = try access.read(f64) },
            .text => .{ .text = try access.read([]const u8) },
            .bytes => .{ .bytes = try access.bytes(.prefer) },
            .boolean => .{ .boolean = try access.read(bool) },
            .none => blk: {
                _ = try access.read(?bool);
                break :blk .null_value;
            },
            .simple => {
                const v = try access.simple();
                return if (v == 23) .undefined else .{ .simple = v };
            },
            .tag => {
                const number = try access.tag();
                const inner = try access.alloc(Value, 1);
                inner[0] = try access.read(Value);
                return .{ .tag = .{ .number = number, .value = &inner[0] } };
            },
            .begin => |header| if (header.kind == .sequence)
                .{ .array = try access.read([]const Value) }
            else blk: {
                const pairs = try access.readPairs(Value, Value);
                const entries = try access.alloc(Entry, pairs.len);
                for (entries, pairs) |*e, p| e.* = .{ .key = p.key, .value = p.value };
                break :blk .{ .map = entries };
            },
            else => error.UnexpectedType,
        };
    }
    pub fn strandSerialize(self: Value, access: anytype) @TypeOf(access.*).Error!void {
        switch (self) {
            .unsigned => |n| try access.write(n),
            .negative => |n| try access.write(-1 - @as(i65, n)),
            .bytes => |b| try access.bytes(b),
            .text => |t| try access.write(t),
            .array => |items| try access.writeSequence(items),
            .map => |entries| try access.writePairs(entries),
            .tag => |t| {
                try access.tag(t.number);
                try access.write(t.value.*);
            },
            .boolean => |b| try access.write(b),
            .null_value => try access.write(@as(?bool, null)),
            .undefined => try access.simple(23),
            .simple => |v| try access.simple(v),
            .float => |f| try access.write(f),
        }
    }

    /// Whether two items are the same: a float by its bits, so a NaN is the NaN.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .unsigned => |n| n == b.unsigned,
            .negative => |n| n == b.negative,
            .bytes => |x| std.mem.eql(u8, x, b.bytes),
            .text => |x| std.mem.eql(u8, x, b.text),
            .array => |x| x.len == b.array.len and for (x, b.array) |p, q| {
                if (!p.eql(q)) break false;
            } else true,
            .map => |x| x.len == b.map.len and for (x, b.map) |p, q| {
                if (!p.key.eql(q.key) or !p.value.eql(q.value)) break false;
            } else true,
            .tag => |t| t.number == b.tag.number and t.value.eql(b.tag.value.*),
            .boolean => |x| x == b.boolean,
            .null_value, .undefined => true,
            .simple => |v| v == b.simple,
            .float => |f| @as(u64, @bitCast(f)) == @as(u64, @bitCast(b.float)) or (std.math.isNan(f) and std.math.isNan(b.float)),
        };
    }
};
