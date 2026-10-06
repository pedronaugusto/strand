//! A sync that is the call each platform means by one.

const std = @import("std");
const builtin = @import("builtin");

/// Which call put the file's bytes on the disk under it. See `syncFile`.
pub const SyncKind = enum {
    /// The platform's strongest: the drive was told to write its own cache
    /// out, not merely told about the bytes.
    full,
    /// The record and what it takes to find the record, without the
    /// timestamps that say nothing about either.
    data,
    /// The ordinary one, which is all the platform or the filesystem has.
    plain,

    /// The call `syncFile` asks for first at `level` on this platform: what
    /// a sync is here, before a filesystem has had its say. What it reports
    /// is this, or `.plain` from a filesystem that declines the stronger
    /// call — `F_FULLFSYNC` on a network mount, say — so a caller that
    /// promises a durability names this one and checks the answer.
    pub fn asked(level: SyncLevel) SyncKind {
        if (comptime builtin.os.tag.isDarwin()) return .full;
        if (comptime builtin.os.tag == .linux) return switch (level) {
            .data => .data,
            .all => .plain,
        };
        return .plain;
    }
};

/// How much of what a file has been given `syncFile` is to put down.
pub const SyncLevel = enum {
    /// The bytes, and what it takes to find them — the file's length above
    /// all — without the timestamps. What a log appending records needs,
    /// and what `Writer` asks for.
    data,
    /// Everything, timestamps included: `fsync` where `data` would be
    /// `fdatasync`. For a caller whose promise is written in terms of the
    /// ordinary call.
    all,
};

pub const SyncError = std.Io.File.SyncError;

/// Puts what a file has been given onto the disk under it, as completely as
/// the platform allows, and says which call did it.
///
/// `std.Io.File.sync` is `fsync` where there is one, and on two platforms
/// `fsync` is the wrong call:
///
/// On Darwin it is too weak. `fsync` there hands the bytes to the drive and
/// does not make the drive write them down, so a machine that loses power can
/// lose a record an `fsync` returned success for. `fcntl(F_FULLFSYNC)` is the
/// call that waits for the media, and it is what a sync asks for there, at
/// either level.
///
/// On Linux it is more than a log needs. `fsync` writes the file's timestamps
/// back as well, which is a second metadata write per record for a mtime no
/// reader of this log consults; `fdatasync` writes the record and whatever it
/// takes to find the record — the file's new length above all — and nothing
/// else. `std.Io.File` exposes no such call, so this is the syscall, which is
/// also what makes it the same call whether or not libc is linked. It is
/// what `.data` asks for; `.all` is `fsync`.
///
/// A file or filesystem that has no such call — a network mount, an image —
/// refuses it, and then `fsync` is the strongest thing there is on that
/// filesystem and is what it gets. A call interrupted by a signal is made
/// again. Any other failure is reported rather than retried or answered
/// with a weaker call: a failed sync can clear the error the kernel was
/// holding, so asking a second time is how the loss gets lost rather than
/// how it gets fixed.
pub fn syncFile(io: std.Io, file: std.Io.File, level: SyncLevel) SyncError!SyncKind {
    if (comptime builtin.os.tag.isDarwin()) {
        while (true) {
            switch (std.posix.errno(std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0)))) {
                .SUCCESS => return .full,
                .INTR => continue,
                // This filesystem cannot be asked. Everything else is the
                // file saying the bytes are not down.
                .OPNOTSUPP, .INVAL, .NOTTY, .PERM => break,
                else => |e| return failure(e),
            }
        }
    }
    if (comptime builtin.os.tag == .linux) {
        if (level == .data) while (true) {
            switch (std.os.linux.errno(std.os.linux.fdatasync(file.handle))) {
                .SUCCESS => return .data,
                .INTR => continue,
                // This file cannot be asked — a kernel without the call, a
                // filesystem that declines it. Everything else is the file
                // saying the bytes are not down.
                .INVAL, .NOSYS => break,
                else => |e| return failure(e),
            }
        };
    }
    try file.sync(io);
    return .plain;
}

/// Puts a directory's entries — the names created, renamed and removed in
/// it — onto the disk under it, and says which call did it, or that there is
/// no call to make. A file's own sync does not do this: a file that was
/// created or renamed is found through its directory, and until the
/// directory is down a crash can leave the bytes on the disk with no name
/// that reaches them.
///
/// The call is the one `syncFile` makes at `.all`, platform by platform:
///
/// | | |
/// |---|---|
/// | Linux | `fsync` on the directory, by syscall. A directory opened without `.iterate` is an `O_PATH` handle, which cannot be synced; that is `error.AccessDenied` here rather than the panic `std.Io.File.sync` makes of it |
/// | macOS | `fcntl(F_FULLFSYNC)`, for the reason it is the call for a file. A filesystem with no such call gets `fsync` |
/// | Windows | none, and the answer is `null`. A directory handle opened to be read cannot be flushed, and NTFS writes a directory's entries through its own journal rather than through the directory |
///
/// Other platforms get `fsync`. An interrupted call is made again, and any
/// other failure is reported rather than retried, as `syncFile`'s is.
pub fn syncDir(io: std.Io, dir: std.Io.Dir) SyncError!?SyncKind {
    if (comptime builtin.os.tag == .windows) return null;
    if (comptime builtin.os.tag == .linux) {
        while (true) {
            switch (std.os.linux.errno(std.os.linux.fsync(dir.handle))) {
                .SUCCESS => return .plain,
                .INTR => continue,
                // An `O_PATH` handle: open, but not for this.
                .BADF => return error.AccessDenied,
                else => |e| return failure(e),
            }
        }
    }
    const kind = try syncFile(io, .{ .handle = dir.handle, .flags = .{ .nonblocking = false } }, .all);
    return kind;
}

/// A sync's failure as `std.Io.File.sync` names it.
fn failure(e: anytype) SyncError {
    return switch (e) {
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        .ACCES => error.AccessDenied,
        else => std.posix.unexpectedErrno(e),
    };
}

test syncFile {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "log.jsonl", .data = "{\"kind\":\"one\"}\n" });
    const file = try tmp.dir.openFile(std.testing.io, "log.jsonl", .{ .mode = .write_only });
    defer file.close(std.testing.io);

    // A sync is the strongest call the platform has, and on the two platforms
    // where that is not what `std` calls a sync, this is the test that the
    // other one is what was asked for.
    const kind = try syncFile(std.testing.io, file, .data);
    const expected: SyncKind = switch (builtin.os.tag) {
        .linux => .data,
        else => if (builtin.os.tag.isDarwin()) .full else .plain,
    };
    try std.testing.expectEqual(expected, kind);

    // Everything, timestamps included, is the ordinary call where the
    // ordinary call is the whole of it, and still the strongest on Darwin.
    const all = try syncFile(std.testing.io, file, .all);
    try std.testing.expectEqual(@as(SyncKind, if (builtin.os.tag.isDarwin()) .full else .plain), all);

    // What was asked for is what a filesystem that takes it answers.
    try std.testing.expectEqual(SyncKind.asked(.data), kind);
    try std.testing.expectEqual(SyncKind.asked(.all), all);
    comptime std.debug.assert(SyncKind.asked(.all) == if (builtin.os.tag.isDarwin()) .full else .plain);
}

test syncDir {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    // A name made and then moved is what a directory sync is for.
    try tmp.dir.writeFile(io, .{ .sub_path = "record.tmp", .data = "{}\n" });
    try tmp.dir.rename("record.tmp", tmp.dir, "record", io);

    const expected: ?SyncKind = switch (builtin.os.tag) {
        .windows => null,
        else => if (builtin.os.tag.isDarwin()) .full else .plain,
    };
    try std.testing.expectEqual(expected, try syncDir(io, tmp.dir));

    // A directory opened only to be named is a handle that cannot be synced
    // on Linux, and that is an error rather than a crash.
    const path_only = try tmp.dir.openDir(io, ".", .{});
    defer path_only.close(io);
    if (comptime builtin.os.tag == .linux) {
        try std.testing.expectError(error.AccessDenied, syncDir(io, path_only));
    } else {
        try std.testing.expectEqual(expected, try syncDir(io, path_only));
    }
}
