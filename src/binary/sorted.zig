//! Maps held until they close and then written with their entries sorted by
//! their encoded keys: the deterministic profiles of the binary formats (CBOR,
//! MessagePack), which agree on this and on nothing else. An encoder opens a
//! frame for every container, marks where each item of a held map starts, and
//! closes the frame; everything written inside a held map goes to the
//! innermost one, so nested maps are sorted inside out.
const std = @import("std");
const core = @import("../core.zig");

/// How a closed map's entries are ordered.
pub const Order = enum {
    /// By the encoded keys' bytes.
    bytewise,
    /// Shorter encoded keys first, then by their bytes.
    length_first,
};

/// A map being held: its encoded entries, back to back, and where each
/// entry's key and value start.
pub const Held = struct {
    bytes: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    /// Whether the next item written is a key.
    key_next: bool = true,
    /// Where the item after a prefix that belongs to it (a CBOR tag) starts.
    prefix_start: ?usize = null,
    pub const Entry = struct { key: usize, value: usize, end: usize = 0 };
};
/// A container: a map held for sorting, or anything else, written where it stands.
const Frame = struct { held: ?Held = null };

pub const Error = error{ OutOfMemory, OutputLimit, DuplicateField, WorkLimit, CustomRejected };

/// The containers open, innermost last.
pub const Stack = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(Frame) = .empty,

    pub fn deinit(self: *Stack) void {
        for (self.frames.items) |*f| if (f.held) |*h| free(h, self.allocator);
        self.frames.deinit(self.allocator);
        self.* = undefined;
    }
    /// The innermost map held, if any: everything inside it is written there.
    pub fn sink(self: *Stack) ?*Held {
        var i = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            if (self.frames.items[i].held) |*h| return h;
        }
        return null;
    }
    /// Appends `data` to the innermost map held. A map's bytes are all
    /// written in the end: a map that holds more than the output left is
    /// refused while it is held.
    pub fn append(self: *Stack, held: *Held, data: []const u8, c: *const core.Context) Error!void {
        if (data.len > (c.limits.output_bytes - c.outputUsed()) -| held.bytes.items.len) return error.OutputLimit;
        try held.bytes.appendSlice(self.allocator, data);
    }
    /// Before an item: in a held map, where its entry's key or value starts.
    pub fn item(self: *Stack) Error!void {
        if (self.frames.items.len == 0) return;
        const h = &(self.frames.items[self.frames.items.len - 1].held orelse return);
        const at = h.prefix_start orelse h.bytes.items.len;
        h.prefix_start = null;
        if (h.key_next) {
            try h.entries.append(self.allocator, .{ .key = at, .value = at });
        } else h.entries.items[h.entries.items.len - 1].value = at;
        h.key_next = !h.key_next;
    }
    /// Before a prefix that is part of the item after it, such as a tag: the
    /// item's entry starts here.
    pub fn prefix(self: *Stack) void {
        if (self.frames.items.len == 0) return;
        const h = &(self.frames.items[self.frames.items.len - 1].held orelse return);
        if (h.prefix_start == null) h.prefix_start = h.bytes.items.len;
    }
    /// A container opened: a map is held until it closes.
    pub fn open(self: *Stack, map: bool) Error!void {
        try self.frames.append(self.allocator, .{ .held = if (map) .{} else null });
    }
    /// The container closed. For a held map, its entries sorted, which the
    /// caller writes in order through `Sorted.next` and then frees.
    pub fn close(self: *Stack, order: Order, c: *core.Context) Error!?Sorted {
        const f = self.frames.pop() orelse return error.CustomRejected;
        var h = f.held orelse return null;
        errdefer free(&h, self.allocator);
        const all = h.bytes.items;
        const entries = h.entries.items;
        for (entries, 0..) |*e, i| e.end = if (i + 1 < entries.len) entries[i + 1].key else all.len;
        const Compare = struct {
            bytes: []const u8,
            length_first: bool,
            fn less(o: @This(), x: Held.Entry, y: Held.Entry) bool {
                const kx = o.bytes[x.key..x.value];
                const ky = o.bytes[y.key..y.value];
                if (o.length_first and kx.len != ky.len) return kx.len < ky.len;
                return std.mem.order(u8, kx, ky) == .lt;
            }
        };
        try c.chargeWork(all.len + entries.len * 8);
        std.mem.sort(Held.Entry, entries, Compare{ .bytes = all, .length_first = order == .length_first }, Compare.less);
        for (entries[@min(1, entries.len)..], 0..) |e, i| {
            const prior = entries[i];
            if (std.mem.eql(u8, all[prior.key..prior.value], all[e.key..e.value])) return error.DuplicateField;
        }
        return .{ .held = h, .allocator = self.allocator };
    }
};

/// A closed map's entries in their order.
pub const Sorted = struct {
    held: Held,
    allocator: std.mem.Allocator,
    at: usize = 0,
    /// The next entry's bytes, key and value.
    pub fn next(self: *Sorted) ?[]const u8 {
        if (self.at == self.held.entries.items.len) return null;
        const e = self.held.entries.items[self.at];
        self.at += 1;
        return self.held.bytes.items[e.key..e.end];
    }
    pub fn deinit(self: *Sorted) void {
        free(&self.held, self.allocator);
    }
};

fn free(h: *Held, allocator: std.mem.Allocator) void {
    h.bytes.deinit(allocator);
    h.entries.deinit(allocator);
}
