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
};

/// Puts what a file has been given onto the disk under it, as completely as
/// the platform allows, and says which call did it.
///
/// `std.Io.File.sync` is `fsync` where there is one, and on two platforms
/// `fsync` is the wrong call:
///
/// On Darwin it is too weak. `fsync` there hands the bytes to the drive and
/// does not make the drive write them down, so a machine that loses power can
/// lose a record an `fsync` returned success for. `fcntl(F_FULLFSYNC)` is the
/// call that waits for the media, and it is what a sync asks for there.
///
/// On Linux it is more than a log needs. `fsync` writes the file's timestamps
/// back as well, which is a second metadata write per record for a mtime no
/// reader of this log consults; `fdatasync` writes the record and whatever it
/// takes to find the record — the file's new length above all — and nothing
/// else. `std.Io.File` exposes no such call, so this is the syscall, which is
/// also what makes it the same call whether or not libc is linked.
///
/// A file or filesystem that has no such call — a network mount, an image —
/// refuses it, and then `fsync` is the strongest thing there is on that
/// filesystem and is what it gets. Any other failure is reported rather than
/// retried: a failed sync can clear the error the kernel was holding, so
/// asking a second time is how the loss gets lost rather than how it gets
/// fixed.
pub fn syncFile(file: std.Io.File, io: std.Io) !SyncKind {
    if (comptime builtin.os.tag.isDarwin()) {
        while (true) {
            switch (std.posix.errno(std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0)))) {
                .SUCCESS => return .full,
                .INTR => continue,
                // This filesystem cannot be asked. Everything else is the
                // file saying the bytes are not down.
                .OPNOTSUPP, .INVAL, .NOTTY, .PERM => break,
                else => return error.SyncFailed,
            }
        }
    }
    if (comptime builtin.os.tag == .linux) {
        while (true) {
            switch (std.os.linux.errno(std.os.linux.fdatasync(file.handle))) {
                .SUCCESS => return .data,
                .INTR => continue,
                // This file cannot be asked — a kernel without the call, a
                // filesystem that declines it. Everything else is the file
                // saying the bytes are not down.
                .INVAL, .NOSYS => break,
                else => return error.SyncFailed,
            }
        }
    }
    try file.sync(io);
    return .plain;
}

test syncFile {
    var fixture = try @import("fixtures.zig").Fixture.init("{\"kind\":\"one\"}\n", 64);
    defer fixture.deinit();

    // A sync is the strongest call the platform has, and on the two platforms
    // where that is not what `std` calls a sync, this is the test that the
    // other one is what was asked for.
    const kind = try syncFile(fixture.write_file, std.testing.io);
    const expected: SyncKind = switch (builtin.os.tag) {
        .linux => .data,
        else => if (builtin.os.tag.isDarwin()) .full else .plain,
    };
    try std.testing.expectEqual(expected, kind);
}
