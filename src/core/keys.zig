//! The keys an encoder holds past the call that gave them: those of each map open, to refuse
//! one given twice, and a key whose value comes next. A key is copied in: its bytes are its
//! caller's for that one call only, such as a character spelled into a buffer on the stack.
//! The first `held` keys and `held_bytes` of their bytes are held inline; past either, in
//! memory from the allocator a write was given, and with none the write is `OutOfMemory`.
const std = @import("std");
const Context = @import("context.zig").Context;
const EncodeError = @import("context.zig").EncodeError;

/// How many keys are held inline.
pub const held = 128;
/// How many bytes of keys are held inline.
pub const held_bytes = 4096;

/// Keys and, with each, a `Tag` that two keys must share to be the same: `void` where a key
/// is its bytes alone.
pub fn Keys(comptime Tag: type) type {
    return struct {
        const Self = @This();
        const Entry = struct { end: usize, tag: Tag };

        entries: [held]Entry,
        more_entries: std.ArrayList(Entry),
        /// The keys' bytes end to end: in `local` until they outgrow it, then all of them in `more`.
        local: [held_bytes]u8,
        more: std.ArrayList(u8),
        count: usize,
        len: usize,

        /// Starts `keys` where it lies: its arrays are kilobytes a struct literal would build
        /// elsewhere and copy.
        pub fn init(keys: *Self) void {
            keys.more_entries = .empty;
            keys.more = .empty;
            keys.count = 0;
            keys.len = 0;
        }

        pub fn deinit(keys: *Self, gpa: ?std.mem.Allocator) void {
            if (gpa) |a| {
                keys.more_entries.deinit(a);
                keys.more.deinit(a);
            }
            keys.* = undefined;
        }

        /// How many keys are held: what a map opened now passes to `add` as `from`, and to
        /// `reset` when it ends.
        pub fn mark(keys: *const Self) usize {
            return keys.count;
        }

        /// Holds `key` for the map whose keys start at `from`: `error.DuplicateField` when that
        /// map holds it already.
        pub fn add(keys: *Self, c: *Context, gpa: ?std.mem.Allocator, from: usize, tag: Tag, key: []const u8) EncodeError!void {
            try keys.check(c, from, keys.count, tag, key);
            try keys.keep(gpa, tag, key);
        }

        /// Holds `key` unchecked: one whose value comes next, checked by `checkLast` once it
        /// is known to be a map's.
        pub fn keep(keys: *Self, gpa: ?std.mem.Allocator, tag: Tag, key: []const u8) EncodeError!void {
            const end = keys.len + key.len;
            if (keys.count >= held) try keys.more_entries.ensureUnusedCapacity(gpa orelse return error.OutOfMemory, 1);
            if (keys.more.capacity == 0 and end <= held_bytes) {
                @memcpy(keys.local[keys.len..end], key);
            } else {
                const a = gpa orelse return error.OutOfMemory;
                if (keys.more.capacity == 0) {
                    try keys.more.ensureTotalCapacity(a, end);
                    keys.more.appendSliceAssumeCapacity(keys.local[0..keys.len]);
                }
                try keys.more.appendSlice(a, key);
            }
            const kept: Entry = .{ .end = end, .tag = tag };
            if (keys.count < held) keys.entries[keys.count] = kept else keys.more_entries.appendAssumeCapacity(kept);
            keys.count += 1;
            keys.len = end;
        }

        /// `error.DuplicateField` when the last key held is among those from `from` before it.
        pub fn checkLast(keys: *const Self, c: *Context, from: usize) EncodeError!void {
            const i = keys.count - 1;
            return keys.check(c, from, i, keys.entry(i).tag, keys.at(i));
        }

        /// The bytes of key `i`, until a key is next held.
        pub fn at(keys: *const Self, i: usize) []const u8 {
            const start = if (i == 0) 0 else keys.entry(i - 1).end;
            const bytes = if (keys.more.capacity != 0) keys.more.items else keys.local[0..keys.len];
            return bytes[start..keys.entry(i).end];
        }

        /// The bytes of the last key held, until a key is next held.
        pub fn last(keys: *const Self) []const u8 {
            return keys.at(keys.count - 1);
        }

        /// Forgets the keys from `to` on: the mark a map took when it opened.
        pub fn reset(keys: *Self, to: usize) void {
            keys.count = to;
            keys.len = if (to == 0) 0 else keys.entry(to - 1).end;
            keys.more_entries.shrinkRetainingCapacity(to - @min(to, held));
            if (keys.more.capacity != 0) keys.more.shrinkRetainingCapacity(keys.len);
        }

        fn check(keys: *const Self, c: *Context, from: usize, to: usize, tag: Tag, key: []const u8) EncodeError!void {
            for (from..to) |i| {
                const prior = keys.at(i);
                try c.chargeWork(@min(key.len, prior.len) + 1);
                if (std.meta.eql(keys.entry(i).tag, tag) and std.mem.eql(u8, key, prior)) return error.DuplicateField;
            }
        }

        fn entry(keys: *const Self, i: usize) Entry {
            return if (i < held) keys.entries[i] else keys.more_entries.items[i - held];
        }
    };
}

test "keys spelled into one reused buffer stay apart" {
    var c: Context = .init(std.testing.allocator, .{}, .borrowed);
    var keys: Keys(void) = undefined;
    keys.init();
    defer keys.deinit(std.testing.allocator);
    var buffer: [1]u8 = undefined;
    for ("abc") |letter| {
        buffer[0] = letter;
        try keys.add(&c, null, 0, {}, &buffer);
    }
    buffer[0] = 'b';
    try std.testing.expectError(error.DuplicateField, keys.add(&c, null, 0, {}, &buffer));
}

test "keys past the held bytes and the held count move to the allocator and reset back" {
    var c: Context = .init(std.testing.allocator, .{}, .borrowed);
    var keys: Keys(void) = undefined;
    keys.init();
    defer keys.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    var name: [32]u8 = undefined;
    for (0..200) |i| try keys.add(&c, gpa, 0, {}, try std.mem.print(&name, "key-{d:0>24}", .{i}));
    try std.testing.expectError(error.DuplicateField, keys.add(&c, gpa, 0, {}, try std.mem.print(&name, "key-{d:0>24}", .{150})));
    const inner = keys.mark();
    try keys.add(&c, gpa, inner, {}, try std.mem.print(&name, "key-{d:0>24}", .{150}));
    keys.reset(inner);
    try std.testing.expectEqual(@as(usize, 200), keys.mark());
    keys.reset(0);
    try keys.add(&c, gpa, 0, {}, "key");
    try std.testing.expectError(error.DuplicateField, keys.add(&c, gpa, 0, {}, "key"));
}

test "a key held past the held bytes with no allocator is refused, and at the bound is held" {
    var c: Context = .init(std.testing.allocator, .{}, .borrowed);
    var keys: Keys(void) = undefined;
    keys.init();
    defer keys.deinit(null);
    const whole: [held_bytes]u8 = @splat('k');
    try keys.add(&c, null, 0, {}, &whole);
    try std.testing.expectError(error.OutOfMemory, keys.add(&c, null, 0, {}, "k"));
    keys.reset(0);
    for (0..held) |i| {
        const one: [1]u8 = .{@intCast(i)};
        try keys.add(&c, null, 0, {}, &one);
    }
    try std.testing.expectError(error.OutOfMemory, keys.keep(null, {}, "x"));
}

test "keys of one spelling and different tags are different keys" {
    var c: Context = .init(std.testing.allocator, .{}, .borrowed);
    var keys: Keys(u8) = undefined;
    keys.init();
    defer keys.deinit(null);
    try keys.add(&c, null, 0, 1, "1");
    try keys.add(&c, null, 0, 2, "1");
    try std.testing.expectError(error.DuplicateField, keys.add(&c, null, 0, 1, "1"));
    try keys.keep(null, 2, "1");
    try std.testing.expectError(error.DuplicateField, keys.checkLast(&c, 0));
}
