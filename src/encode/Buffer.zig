//! Owned encoding bytes and the allocation failure behind a writer error.
//!
//! The writer's buffer and end are the storage and length; no second list
//! keeps them in sync. A bound belongs to the caller measuring these bytes.

const std = @import("std");

const Self = @This();

allocator: std.mem.Allocator,
writer: std.Io.Writer,
allocation_failed: bool = false,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain, .flush = flush, .rebase = rebase } },
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.writer.buffer);
    self.* = undefined;
}

pub fn reset(self: *Self) void {
    self.writer.end = 0;
    self.allocation_failed = false;
}

/// The writer reports WriteFailed for both causes; this owner knows which.
pub fn diagnose(self: *const Self, err: std.Io.Writer.Error) (std.Io.Writer.Error || std.mem.Allocator.Error) {
    return if (self.allocation_failed) error.OutOfMemory else err;
}

/// Transfer the bytes as one allocation of exactly their length.
pub fn toOwnedSlice(self: *Self) std.mem.Allocator.Error![]u8 {
    std.debug.assert(self.writer.end <= self.writer.buffer.len);
    var storage: std.ArrayList(u8) = .{
        .items = self.writer.buffered(),
        .capacity = self.writer.buffer.len,
    };
    const bytes = try storage.toOwnedSlice(self.allocator);
    self.writer.buffer = &.{};
    self.writer.end = 0;
    std.debug.assert(self.writer.buffer.len == 0);
    std.debug.assert(self.writer.end == 0);
    return bytes;
}

fn grow(self: *Self, additional: usize) std.Io.Writer.Error!void {
    std.debug.assert(self.writer.end <= self.writer.buffer.len);
    var storage: std.ArrayList(u8) = .{
        .items = self.writer.buffered(),
        .capacity = self.writer.buffer.len,
    };
    storage.ensureUnusedCapacity(self.allocator, additional) catch {
        self.allocation_failed = true;
        return error.WriteFailed;
    };
    self.writer.buffer = storage.allocatedSlice();
    std.debug.assert(self.writer.buffer.len - self.writer.end >= additional);
}

fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *Self = @fieldParentPtr("writer", writer);
    std.debug.assert(data.len > 0);
    const start = writer.end;
    defer std.debug.assert(writer.end <= writer.buffer.len);
    for (data[0 .. data.len - 1]) |bytes| {
        try self.grow(bytes.len);
        @memcpy(writer.buffer[writer.end..][0..bytes.len], bytes);
        writer.end += bytes.len;
    }
    const pattern = data[data.len - 1];
    const total = std.math.mul(usize, pattern.len, splat) catch {
        self.allocation_failed = true;
        return error.WriteFailed;
    };
    try self.grow(total);
    switch (pattern.len) {
        0 => {},
        1 => {
            @memset(writer.buffer[writer.end..][0..total], pattern[0]);
            writer.end += total;
        },
        else => for (0..splat) |_| {
            @memcpy(writer.buffer[writer.end..][0..pattern.len], pattern);
            writer.end += pattern.len;
        },
    }
    return writer.end - start;
}

fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {}

fn rebase(writer: *std.Io.Writer, _: usize, capacity: usize) std.Io.Writer.Error!void {
    const self: *Self = @fieldParentPtr("writer", writer);
    try self.grow(capacity);
}
