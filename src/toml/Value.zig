//! A TOML value of any shape, its distinctions kept: integers apart from
//! floats, each kind of date and time its own, a table's keys in the order
//! they were read.
const std = @import("std");
const codecs = @import("codecs.zig");
const number = @import("number.zig");
const temporal = @import("temporal.zig");
pub const Entry = struct { key: []const u8, value: Value };
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    offset_date_time: codecs.OffsetDateTime,
    local_date_time: codecs.LocalDateTime,
    local_date: codecs.LocalDate,
    local_time: codecs.LocalTime,
    array: []const Value,
    table: []const Entry,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Value {
        return switch (try access.peek()) {
            .text => .{ .string = try access.read([]const u8) },
            .number => |spelling| if (number.integerValue(spelling.bytes) != null)
                .{ .integer = try access.read(i64) }
            else
                .{ .float = try access.read(f64) },
            .integer => .{ .integer = try access.read(i64) },
            .floating => .{ .float = try access.read(f64) },
            .boolean => .{ .boolean = try access.read(bool) },
            .tag => |kind| switch (std.enums.fromInt(temporal.Kind, kind) orelse return error.UnexpectedType) {
                .offset_date_time => .{ .offset_date_time = try access.read(codecs.OffsetDateTime) },
                .local_date_time => .{ .local_date_time = try access.read(codecs.LocalDateTime) },
                .local_date => .{ .local_date = try access.read(codecs.LocalDate) },
                .local_time => .{ .local_time = try access.read(codecs.LocalTime) },
            },
            .begin => |header| if (header.kind == .sequence)
                .{ .array = try access.read([]const Value) }
            else blk: {
                const pairs = try access.readPairs([]const u8, Value);
                const entries = try access.alloc(Entry, pairs.len);
                for (entries, pairs) |*e, p| e.* = .{ .key = p.key, .value = p.value };
                break :blk .{ .table = entries };
            },
            else => error.UnexpectedType,
        };
    }
    pub fn strandSerialize(self: Value, access: anytype) @TypeOf(access.*).Error!void {
        switch (self) {
            .string => |s| try access.write(s),
            .integer => |n| try access.write(n),
            .float => |f| try access.write(f),
            .boolean => |b| try access.write(b),
            .offset_date_time => |t| try access.write(t),
            .local_date_time => |t| try access.write(t),
            .local_date => |t| try access.write(t),
            .local_time => |t| try access.write(t),
            .array => |items| try access.writeSequence(items),
            .table => |entries| try access.writePairs(entries),
        }
    }

    /// Whether two values are the same: a float by its bits, so a NaN is the
    /// NaN; a table by its keys and their values, in any order, as TOML
    /// gives a table's keys no order.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |x| std.mem.eql(u8, x, b.string),
            .integer => |x| x == b.integer,
            .float => |f| @as(u64, @bitCast(f)) == @as(u64, @bitCast(b.float)) or (std.math.isNan(f) and std.math.isNan(b.float)),
            .boolean => |x| x == b.boolean,
            .offset_date_time => |x| std.meta.eql(x, b.offset_date_time),
            .local_date_time => |x| std.meta.eql(x, b.local_date_time),
            .local_date => |x| std.meta.eql(x, b.local_date),
            .local_time => |x| std.meta.eql(x, b.local_time),
            .array => |x| x.len == b.array.len and for (x, b.array) |p, q| {
                if (!p.eql(q)) break false;
            } else true,
            .table => |x| x.len == b.table.len and for (x) |p| {
                const q = b.get(p.key) orelse break false;
                if (!p.value.eql(q)) break false;
            } else true,
        };
    }
    /// The entry of a table under `key`, if the value is a table that has one.
    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .table) return null;
        for (self.table) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.value;
        return null;
    }
};
