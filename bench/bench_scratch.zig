const std = @import("std");

/// A file under `.zig-cache`, which is where a build already puts things it
/// does not want to keep.
const Directory = @import("scratch.zig").Directory("bench");

pub const Scratch = struct {
    scratch: Directory,
    file: std.Io.File,

    pub fn init(io: std.Io, bytes: []const u8) !Scratch {
        var scratch = try Directory.init(io);
        errdefer scratch.deinit(io);
        const dir = scratch.dir;
        try dir.writeFile(io, .{ .sub_path = "log.jsonl", .data = bytes });
        return .{ .scratch = scratch, .file = try dir.openFile(io, "log.jsonl", .{}) };
    }

    /// The same, for a line too big to want a second copy of in memory.
    pub fn initBigLine(io: std.Io, gpa: std.mem.Allocator, big_line_bytes: usize) !Scratch {
        var scratch = try Directory.init(io);
        errdefer scratch.deinit(io);
        const dir = scratch.dir;
        {
            const file = try dir.createFile(io, "big.jsonl", .{});
            defer file.close(io);
            const buffer = try gpa.alloc(u8, 1 << 20);
            defer gpa.free(buffer);
            var file_writer = file.writer(io, buffer);
            const w = &file_writer.interface;
            try w.writeAll("{\"kind\":\"");
            try w.splatByteAll('x', big_line_bytes);
            try w.writeAll("\",\"at\":1}\n");
            try w.flush();
        }
        return .{ .scratch = scratch, .file = try dir.openFile(io, "big.jsonl", .{}) };
    }

    pub fn deinit(self: *Scratch, io: std.Io) void {
        self.file.close(io);
        self.scratch.deinit(io);
        self.* = undefined;
    }
};

test "benchmark scratch files have independent lifetimes" {
    const io = std.testing.io;
    var first = try Scratch.init(io, "first\n");
    var first_open = true;
    defer if (first_open) first.deinit(io);
    var second = try Scratch.init(io, "second\n");
    defer second.deinit(io);
    var first_bytes: [32]u8 = undefined;
    var first_reader = first.file.reader(io, &first_bytes);
    try std.testing.expectEqualStrings("first\n", try first_reader.interface.take(6));
    first.deinit(io);
    first_open = false;
    const reopened = try second.scratch.dir.openFile(io, "log.jsonl", .{});
    reopened.close(io);
    var second_bytes: [32]u8 = undefined;
    var second_reader = second.file.reader(io, &second_bytes);
    try std.testing.expectEqualStrings("second\n", try second_reader.interface.take(7));
}

test "benchmark big line scratch has the same invocation owner" {
    const io = std.testing.io;
    var first = try Scratch.initBigLine(io, std.testing.allocator, 31);
    var first_open = true;
    defer if (first_open) first.deinit(io);
    var second = try Scratch.initBigLine(io, std.testing.allocator, 65);
    defer second.deinit(io);
    try std.testing.expectEqual(@as(u64, 31 + "{\"kind\":\"".len + "\",\"at\":1}\n".len), try first.file.length(io));
    try std.testing.expectEqual(@as(u64, 65 + "{\"kind\":\"".len + "\",\"at\":1}\n".len), try second.file.length(io));
    first.deinit(io);
    first_open = false;
    const reopened = try second.scratch.dir.openFile(io, "big.jsonl", .{});
    reopened.close(io);
}
