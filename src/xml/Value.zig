//! An XML element of any shape: its name and its content in order, entries
//! keyed as a typed record's members are (`@name` an attribute, `$text` a
//! text run, any other name a child element), so mixed content keeps its
//! order and an element is read and written through the core as every type
//! is. A child element holding text alone is that text; any other its own
//! content. The root is the arm its name names. Comments, processing
//! instructions and the doctype are not data and are not kept.
const std = @import("std");
const core = @import("../core.zig");

pub const Entry = core.Pair([]const u8, Part);
/// What one entry holds: text (an attribute's value, a text run, or a child
/// element's text alone), or a child element's content.
pub const Part = union(enum) {
    text: []const u8,
    content: []const Entry,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Part {
        return switch (try access.peek()) {
            .text => .{ .text = try access.read([]const u8) },
            .begin => .{ .content = try access.readPairs([]const u8, Part) },
            else => error.UnexpectedType,
        };
    }
    pub fn strandSerialize(self: Part, access: anytype) @TypeOf(access.*).Error!void {
        switch (self) {
            .text => |t| try access.write(t),
            .content => |entries| try access.writePairs(entries),
        }
    }
};

pub const Element = struct {
    name: []const u8,
    content: []const Entry = &.{},

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Element {
        const pairs = try access.readPairs([]const u8, Part);
        if (pairs.len != 1) return error.UnexpectedType;
        return switch (pairs[0].value) {
            .content => |entries| .{ .name = pairs[0].key, .content = entries },
            .text => |t| blk: {
                if (t.len == 0) break :blk .{ .name = pairs[0].key };
                const one = try access.alloc(Entry, 1);
                one[0] = .{ .key = "$text", .value = .{ .text = t } };
                break :blk .{ .name = pairs[0].key, .content = one };
            },
        };
    }
    pub fn strandSerialize(self: Element, access: anytype) @TypeOf(access.*).Error!void {
        try access.named(Part{ .content = self.content }, .variant, self.name);
    }

    /// The value of the attribute named `name`, if any.
    pub fn attribute(self: Element, name: []const u8) ?[]const u8 {
        for (self.content) |e| {
            if (e.key.len == name.len + 1 and e.key[0] == '@' and std.mem.eql(u8, e.key[1..], name)) return switch (e.value) {
                .text => |t| t,
                .content => null,
            };
        }
        return null;
    }
    /// The first child element named `name`, if any.
    pub fn child(self: Element, name: []const u8) ?Part {
        for (self.content) |e| if (std.mem.eql(u8, e.key, name)) return e.value;
        return null;
    }

    /// Whether two elements are the same: names, and content in order.
    pub fn eql(a: Element, b: Element) bool {
        return std.mem.eql(u8, a.name, b.name) and same(a.content, b.content);
    }
    fn same(a: []const Entry, b: []const Entry) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!std.mem.eql(u8, x.key, y.key) or std.meta.activeTag(x.value) != std.meta.activeTag(y.value)) return false;
            switch (x.value) {
                .text => |t| if (!std.mem.eql(u8, t, y.value.text)) return false,
                .content => |c| if (!same(c, y.value.content)) return false,
            }
        }
        return true;
    }
};
