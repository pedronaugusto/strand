//! Scaffolding more than one test file needs: a record to read lines into, a
//! file on disk to read them from, and a stream that is not a file.
//!
//! Nothing here is part of the package. It is imported by the test files and
//! by nothing else, so it costs a consumer nothing.

const std = @import("std");
const testing = std.testing;

/// The smallest record worth reading: a string and a number. `tests.zig` and
/// `fuzz.zig` have their own, richer, because what they are about is what a
/// line can go wrong in; the readers are about the lines themselves.
pub const Event = struct {
    kind: []const u8,
    at: u64 = 0,
};

/// A file in a temporary directory, holding `bytes`, open once for reading
/// with a reader over it and once for appending to it while it is read.
///
/// Both handles are needed together often enough to be worth one struct: a
/// backwards read wants only the first, and a follower wants both, since what
/// it is being asked about is a file that grows under it.
pub const Fixture = struct {
    tmp: testing.TmpDir,
    /// Open for reading. Reading is also what asking a file's attributes
    /// needs, which is why the follower is given this one.
    file: std.Io.File,
    /// The same file, open for writing.
    write_file: std.Io.File,
    reader: std.Io.File.Reader,
    buffer: []u8,
    write_buffer: []u8,

    pub fn init(bytes: []const u8, buffer_len: usize) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "log.jsonl", .data = bytes });

        const write_file = try tmp.dir.openFile(testing.io, "log.jsonl", .{ .mode = .write_only });
        errdefer write_file.close(testing.io);
        const file = try tmp.dir.openFile(testing.io, "log.jsonl", .{});
        errdefer file.close(testing.io);

        const buffer = try testing.allocator.alloc(u8, buffer_len);
        errdefer testing.allocator.free(buffer);
        const write_buffer = try testing.allocator.alloc(u8, buffer_len);
        return .{
            .tmp = tmp,
            .file = file,
            .write_file = write_file,
            .reader = file.reader(testing.io, buffer),
            .buffer = buffer,
            .write_buffer = write_buffer,
        };
    }

    pub fn deinit(self: *Fixture) void {
        testing.allocator.free(self.buffer);
        testing.allocator.free(self.write_buffer);
        self.file.close(testing.io);
        self.write_file.close(testing.io);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

/// A `std.Io.Reader` over bytes already in memory that hands them over
/// `chunk` at a time through a buffer of the caller's size, and can neither
/// seek nor say how long it is.
///
/// A pipe, in other words. It is what a reader's own buffer being smaller
/// than a line looks like, without a file having to exist for it.
pub const Chunked = struct {
    rest: []const u8,
    chunk: usize,
    interface: std.Io.Reader,

    pub fn init(bytes: []const u8, buffer: []u8, chunk: usize) Chunked {
        return .{
            .rest = bytes,
            .chunk = chunk,
            .interface = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Chunked = @alignCast(@fieldParentPtr("interface", io_reader));
        if (self.rest.len == 0) return error.EndOfStream;
        const room = @intFromEnum(limit.min(.limited(self.rest.len)));
        const take = @max(@min(self.chunk, room), 1);
        const n = try w.write(self.rest[0..take]);
        self.rest = self.rest[n..];
        return n;
    }
};
