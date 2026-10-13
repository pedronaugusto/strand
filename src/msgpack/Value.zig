//! A MessagePack value of any shape, its distinctions kept: integers from
//! -2^63 to 2^64 - 1, str apart from bin, extensions with their type and data,
//! and a map's keys of any kind, in order.
const std = @import("std");
const Ext = @import("codecs.zig").Ext;
pub const Entry = struct { key: Value, value: Value };
pub const Value = union(enum) {
    nil,
    boolean: bool,
    /// An integer from 0.
    unsigned: u64,
    /// An integer below 0.
    negative: i64,
    float: f64,
    str: []const u8,
    bin: []const u8,
    array: []const Value,
    map: []const Entry,
    ext: Ext,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Value {
        return switch (try access.peek()) {
            .integer => {
                const v = try access.read(i65);
                return if (v >= 0) .{ .unsigned = @intCast(v) } else .{ .negative = @intCast(v) };
            },
            .floating => .{ .float = try access.read(f64) },
            .text => .{ .str = try access.read([]const u8) },
            .bytes => .{ .bin = try access.bytes(.prefer) },
            .boolean => .{ .boolean = try access.read(bool) },
            .none => blk: {
                _ = try access.read(?bool);
                break :blk .nil;
            },
            .tag => .{ .ext = try access.read(Ext) },
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
            .nil => try access.write(@as(?bool, null)),
            .boolean => |b| try access.write(b),
            .unsigned => |n| try access.write(n),
            .negative => |n| try access.write(n),
            .float => |f| try access.write(f),
            .str => |t| try access.write(t),
            .bin => |b| try access.bytes(b),
            .array => |items| try access.writeSequence(items),
            .map => |entries| try access.writePairs(entries),
            .ext => |e| try access.write(e),
        }
    }

    /// Whether two values are the same: a float by its bits, so a NaN is the
    /// NaN; an integer by its value, whichever variant holds it.
    pub fn eql(a: Value, b: Value) bool {
        if (integer(a)) |x| return if (integer(b)) |y| x == y else false;
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .nil => true,
            .boolean => |x| x == b.boolean,
            .unsigned, .negative => unreachable, // unreachable: integers compared above
            .float => |f| @as(u64, @bitCast(f)) == @as(u64, @bitCast(b.float)) or (std.math.isNan(f) and std.math.isNan(b.float)),
            .str => |x| std.mem.eql(u8, x, b.str),
            .bin => |x| std.mem.eql(u8, x, b.bin),
            .array => |x| x.len == b.array.len and for (x, b.array) |p, q| {
                if (!p.eql(q)) break false;
            } else true,
            .map => |x| x.len == b.map.len and for (x, b.map) |p, q| {
                if (!p.key.eql(q.key) or !p.value.eql(q.value)) break false;
            } else true,
            .ext => |e| e.type_id == b.ext.type_id and std.mem.eql(u8, e.data, b.ext.data),
        };
    }
    fn integer(v: Value) ?i65 {
        return switch (v) {
            .unsigned => |n| n,
            .negative => |n| n,
            else => null,
        };
    }
};
