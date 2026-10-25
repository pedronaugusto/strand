//! An INI document of any shape: its members in order, the keys before its
//! first section and then its sections, each a key's text, a key with no
//! value, or a section of such keys, so a document is read and written
//! through the core as every type is.
const std = @import("std");
const core = @import("../core.zig");

pub const Member = core.Pair([]const u8, Part);
/// What one member holds.
pub const Part = union(enum) {
    /// A key's value, a continued one's lines joined by line feeds.
    text: []const u8,
    /// A key with no value, where the dialect takes one.
    none,
    /// A section's keys.
    section: []const Member,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Part {
        return switch (try access.peek()) {
            .text => .{ .text = try access.read([]const u8) },
            .none => blk: {
                _ = try access.read(?[]const u8);
                break :blk .none;
            },
            .begin => .{ .section = try access.readPairs([]const u8, Part) },
            else => error.UnexpectedType,
        };
    }
    pub fn strandSerialize(self: Part, access: anytype) @TypeOf(access.*).Error!void {
        switch (self) {
            .text => |t| try access.write(t),
            .none => try access.write(@as(?[]const u8, null)),
            .section => |members| try access.writePairs(members),
        }
    }
};

pub const Value = struct {
    members: []const Member = &.{},

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Value {
        return .{ .members = try access.readPairs([]const u8, Part) };
    }
    pub fn strandSerialize(self: Value, access: anytype) @TypeOf(access.*).Error!void {
        try access.writePairs(self.members);
    }

    /// The value of the key named `name` before any section, if it has one.
    pub fn get(self: Value, name: []const u8) ?[]const u8 {
        return text(self.members, name);
    }
    /// The keys of the section named `name`, if there is one.
    pub fn section(self: Value, name: []const u8) ?[]const Member {
        for (self.members) |m| if (m.value == .section and std.mem.eql(u8, m.key, name)) return m.value.section;
        return null;
    }
    /// The value of the key named `name` in `members` (a section's), if it has one.
    pub fn text(members: []const Member, name: []const u8) ?[]const u8 {
        for (members) |m| if (m.value == .text and std.mem.eql(u8, m.key, name)) return m.value.text;
        return null;
    }

    /// Whether two documents are the same: members in order.
    pub fn eql(a: Value, b: Value) bool {
        return same(a.members, b.members);
    }
    fn same(a: []const Member, b: []const Member) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!std.mem.eql(u8, x.key, y.key) or std.meta.activeTag(x.value) != std.meta.activeTag(y.value)) return false;
            switch (x.value) {
                .text => |t| if (!std.mem.eql(u8, t, y.value.text)) return false,
                .none => {},
                .section => |s| if (!same(s, y.value.section)) return false,
            }
        }
        return true;
    }
};
