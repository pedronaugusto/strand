//! A YAML value of any shape, as the core schema resolves it: null, a
//! boolean, an integer, a float, a string, a sequence, or a mapping whose
//! keys are values too, in the order they were read.
const std = @import("std");
const schema = @import("schema.zig");
pub const Entry = struct { key: Value, value: Value };
pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i128,
    float: f64,
    string: []const u8,
    sequence: []const Value,
    mapping: []const Entry,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Value {
        return switch (try access.peek()) {
            .none => blk: {
                _ = try access.read(?bool);
                break :blk .null;
            },
            .boolean => .{ .boolean = try access.read(bool) },
            .number => |spelling| if (schema.number(spelling.bytes) == .integer)
                .{ .integer = try access.read(i128) }
            else
                .{ .float = try access.read(f64) },
            .text => .{ .string = try access.read([]const u8) },
            .begin => |header| if (header.kind == .sequence)
                .{ .sequence = try access.read([]const Value) }
            else blk: {
                const pairs = try access.readPairs(Value, Value);
                const entries = try access.alloc(Entry, pairs.len);
                for (entries, pairs) |*e, p| e.* = .{ .key = p.key, .value = p.value };
                break :blk .{ .mapping = entries };
            },
            else => error.UnexpectedType,
        };
    }
    pub fn strandSerialize(self: Value, access: anytype) @TypeOf(access.*).Error!void {
        switch (self) {
            .null => try access.write(@as(?bool, null)),
            .boolean => |b| try access.write(b),
            .integer => |n| try access.write(n),
            .float => |f| try access.write(f),
            .string => |s| try access.write(s),
            .sequence => |items| try access.writeSequence(items),
            .mapping => |entries| try access.writePairs(entries),
        }
    }

    /// Whether two values are the same: a float by its value, any NaN the
    /// NaN; a mapping by its keys and their values in any order, as YAML
    /// gives a mapping's keys no order.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null => true,
            .boolean => |x| x == b.boolean,
            .integer => |x| x == b.integer,
            .float => |f| f == b.float or (std.math.isNan(f) and std.math.isNan(b.float)),
            .string => |x| std.mem.eql(u8, x, b.string),
            .sequence => |x| x.len == b.sequence.len and for (x, b.sequence) |p, q| {
                if (!p.eql(q)) break false;
            } else true,
            .mapping => |x| x.len == b.mapping.len and for (x) |p| {
                const q = b.get(p.key) orelse break false;
                if (!p.value.eql(q)) break false;
            } else true,
        };
    }
    /// The value of a mapping under `key`, if the value is a mapping that has one.
    pub fn get(self: Value, key: Value) ?Value {
        if (self != .mapping) return null;
        for (self.mapping) |entry| if (entry.key.eql(key)) return entry.value;
        return null;
    }
    /// The value of a mapping under the string `key`.
    pub fn field(self: Value, key: []const u8) ?Value {
        return self.get(.{ .string = key });
    }
};
