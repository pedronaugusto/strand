//! The logbook example's scratch directory and its lifetime.
const std = @import("std");

pub const Scratch = struct {
    dir: std.Io.Dir,
    path: [prefix.len + 16]u8,

    const prefix = ".zig-cache/logbook-";

    pub fn init(io: std.Io) !Scratch {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, ".zig-cache");
        var path: [prefix.len + 16]u8 = undefined;
        @memcpy(path[0..prefix.len], prefix);
        while (true) {
            var random: [12]u8 = undefined;
            io.random(&random);
            _ = std.base64.url_safe.Encoder.encode(path[prefix.len..], &random);
            // Only a directory this invocation created belongs to it.
            cwd.createDir(io, &path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return err,
            };
            errdefer cwd.deleteTree(io, &path) catch {};
            return .{ .dir = try cwd.openDir(io, &path, .{}), .path = path };
        }
    }

    pub fn deinit(self: *Scratch, io: std.Io) void {
        self.dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, &self.path) catch {};
        self.* = undefined;
    }
};

test "logbook scratch directories have independent lifetimes" {
    const io = std.testing.io;
    var first = try Scratch.init(io);
    var first_open = true;
    defer if (first_open) first.deinit(io);
    var second = try Scratch.init(io);
    defer second.deinit(io);
    try std.testing.expect(!std.mem.eql(u8, &first.path, &second.path));
    try first.dir.writeFile(io, .{ .sub_path = "log.jsonl", .data = "first\n" });
    try second.dir.writeFile(io, .{ .sub_path = "log.jsonl", .data = "second\n" });
    first.deinit(io);
    first_open = false;
    const file = try second.dir.openFile(io, "log.jsonl", .{});
    defer file.close(io);
    var bytes: [32]u8 = undefined;
    var reader = file.reader(io, &bytes);
    try std.testing.expectEqualStrings("second\n", try reader.interface.take(7));
}
