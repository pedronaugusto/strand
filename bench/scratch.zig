//! A scratch directory owned by one benchmark invocation.
const std = @import("std");

// The name belongs to the harness; creation and cleanup belong here.
pub fn Directory(comptime name: []const u8) type {
    return struct {
        dir: std.Io.Dir,
        path: [prefix.len + 16]u8,

        const prefix = ".zig-cache/" ++ name ++ "-";

        pub fn init(io: std.Io) !@This() {
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
                errdefer cwd.deleteTree(io, &path) catch {}; // glint-ignore: Z026 -- the error path already returns the failure that matters; a stray scratch directory is all a failed delete leaves
                return .{ .dir = try cwd.openDir(io, &path, .{}), .path = path };
            }
        }

        pub fn deinit(self: *@This(), io: std.Io) void {
            self.dir.close(io);
            std.Io.Dir.cwd().deleteTree(io, &self.path) catch {}; // glint-ignore: Z026 -- cleanup of a scratch directory after its test; a failed delete leaves a stray directory and nothing a caller could act on
            self.* = undefined;
        }
    };
}
