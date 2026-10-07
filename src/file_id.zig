//! Which file an open handle is, as the filesystem numbers it and not as a
//! path spells it.
//!
//! Two paths can name one file — through a symbolic link, a bind mount, a
//! second spelling of the same drive — and a path compared as a string
//! cannot see it. The filesystem can: on POSIX a file is its device and its
//! inode, and on Windows its volume's serial number and its file id. The
//! inode alone is not enough: two volumes number their files independently,
//! so a file on one can carry the number of a file on another. Both are read
//! from the handle itself, so nothing is allocated and no path is resolved.
//! A directory is a file here like any other.

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

/// A file's identity: equal for two handles to one file, and different for
/// two files that both exist at once. Numbers can be reused once a file is
/// gone, which is what `Identity.fingerprint` is for.
pub const FileId = struct {
    /// The device on POSIX; the volume's serial number on Windows.
    volume: u64,
    /// The inode on POSIX; the file id on Windows, which is 128 bits on ReFS.
    file: u128,

    pub const Error = Io.File.StatError;

    /// What the file or directory `handle` is open on is.
    pub fn of(handle: Io.File.Handle) Error!FileId {
        return switch (builtin.os.tag) {
            .linux => linux(handle),
            .windows => windows(handle),
            else => posix(handle),
        };
    }

    pub const PathError = Io.Dir.StatFileError;

    /// What the file or directory at `sub_path` is, relative to `dir` —
    /// which an absolute `sub_path` ignores — read from the path and not
    /// from a handle, so it is the same answer `of` gives on a handle to
    /// the file, and a file that cannot be opened has one too: a socket,
    /// above all. A symbolic link is followed, as opening it would be.
    ///
    /// On Windows the file is opened for its attributes, directories
    /// included, and asked as `of` asks; there is no identity there for a
    /// file nothing can open.
    pub fn ofPath(io: Io, dir: Io.Dir, sub_path: []const u8) PathError!FileId {
        try io.checkCancel();
        if (builtin.os.tag == .windows) {
            const file = try dir.openFile(io, sub_path, .{ .allow_directory = true });
            defer file.close(io);
            return of(file.handle);
        }
        const path = try std.posix.toPosixPath(sub_path);
        return if (builtin.os.tag == .linux) linuxAt(io, dir.handle, &path) else posixAt(io, dir.handle, &path);
    }

    pub fn eql(a: FileId, b: FileId) bool {
        return a.volume == b.volume and a.file == b.file;
    }
};

const StatError = FileId.Error;

fn linux(fd: std.posix.fd_t) StatError!FileId {
    const sys = std.os.linux;
    while (true) {
        var statx = std.mem.zeroes(sys.Statx);
        // The device numbers are always filled in; the inode is asked for.
        switch (sys.errno(sys.statx(fd, "", sys.AT.EMPTY_PATH, .{ .INO = true }, &statx))) {
            .SUCCESS => {
                if (!statx.mask.INO) return error.Unexpected;
                return .{ .volume = linuxVolume(statx), .file = statx.ino };
            },
            .INTR => continue,
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }
}

/// `linux` for a path: the same call, at a path rather than on a handle.
fn linuxAt(io: Io, dir: std.posix.fd_t, path: [*:0]const u8) FileId.PathError!FileId {
    const sys = std.os.linux;
    while (true) {
        var statx = std.mem.zeroes(sys.Statx);
        switch (sys.errno(sys.statx(dir, path, 0, .{ .INO = true }, &statx))) {
            .SUCCESS => {
                if (!statx.mask.INO) return error.Unexpected;
                return .{ .volume = linuxVolume(statx), .file = statx.ino };
            },
            .INTR => try io.checkCancel(),
            else => |e| return pathFailure(e),
        }
    }
}

/// `posix` for a path.
fn posixAt(io: Io, dir: std.posix.fd_t, path: [*:0]const u8) FileId.PathError!FileId {
    while (true) {
        var stat = std.mem.zeroes(std.posix.Stat);
        switch (std.posix.errno(std.c.fstatat(dir, path, &stat, 0))) {
            .SUCCESS => return .{
                .volume = unsigned(stat.dev),
                .file = unsigned(stat.ino),
            },
            .INTR => try io.checkCancel(),
            else => |e| return pathFailure(e),
        }
    }
}

/// A stat at a path's failure, as `std.Io.Dir.statFile` names it.
fn pathFailure(e: std.posix.E) FileId.PathError {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOTDIR => error.NotDir,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.SystemResources,
        else => std.posix.unexpectedErrno(e),
    };
}

/// A Linux device as one number: the major and the minor both, since two
/// volumes can share either.
fn linuxVolume(statx: std.os.linux.Statx) u64 {
    return (@as(u64, statx.dev_major) << 32) | statx.dev_minor;
}

test linuxVolume {
    var a = std.mem.zeroes(std.os.linux.Statx);
    a.dev_major = 1;
    a.dev_minor = 1;
    var b = a;
    b.dev_major = 2;
    try std.testing.expect(linuxVolume(a) != linuxVolume(b));
    b = a;
    b.dev_minor = 2;
    try std.testing.expect(linuxVolume(a) != linuxVolume(b));
    try std.testing.expectEqual(linuxVolume(a), linuxVolume(a));
}

fn posix(fd: std.posix.fd_t) StatError!FileId {
    const fstat = if (std.posix.lfs64_abi) std.posix.system.fstat64 else std.posix.system.fstat;
    while (true) {
        var stat = std.mem.zeroes(std.posix.Stat);
        switch (std.posix.errno(fstat(fd, &stat))) {
            .SUCCESS => return .{
                .volume = unsigned(stat.dev),
                .file = unsigned(stat.ino),
            },
            .INTR => continue,
            .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }
}

/// The bits of a `dev_t` or `ino_t`, whichever sign and width the platform
/// gives it: Darwin's device number is an `i32`.
fn unsigned(x: anytype) u64 {
    const bits_type = @Int(.unsigned, @bitSizeOf(@TypeOf(x)));
    return @as(bits_type, @bitCast(x));
}

/// `FILE_ID_INFORMATION`: the volume's 64-bit serial number and the file's
/// 128-bit id, which is the pair Windows documents as naming one file. The
/// 64-bit index `FileInternalInformation` gives is not unique on ReFS.
const FileIdInformation = extern struct {
    VolumeSerialNumber: u64,
    FileId: [16]u8,
};

fn windows(handle: std.os.windows.HANDLE) StatError!FileId {
    const w = std.os.windows;
    var status: w.IO_STATUS_BLOCK = undefined;

    var id: FileIdInformation = undefined;
    switch (w.ntdll.NtQueryInformationFile(handle, &status, &id, @sizeOf(FileIdInformation), .Id)) {
        .SUCCESS => return .{
            .volume = id.VolumeSerialNumber,
            .file = std.mem.readInt(u128, &id.FileId, .little),
        },
        .ACCESS_DENIED => return error.AccessDenied,
        // A filesystem that has no 128-bit ids (FAT, some redirectors):
        // the volume's 32-bit serial and the 64-bit index are what it has.
        .INVALID_PARAMETER, .INVALID_INFO_CLASS, .NOT_IMPLEMENTED, .NOT_SUPPORTED => {},
        else => return error.Unexpected,
    }

    var volume: extern struct {
        info: w.FILE.FS_VOLUME_INFORMATION,
        // Room for the label, which is not wanted but is written.
        label: [64]w.WCHAR,
    } = undefined;
    switch (w.ntdll.NtQueryVolumeInformationFile(handle, &status, &volume, @sizeOf(@TypeOf(volume)), .Volume)) {
        .SUCCESS, .BUFFER_OVERFLOW => {},
        .ACCESS_DENIED => return error.AccessDenied,
        else => return error.Unexpected,
    }
    var internal: w.FILE.INTERNAL_INFORMATION = undefined;
    switch (w.ntdll.NtQueryInformationFile(handle, &status, &internal, @sizeOf(w.FILE.INTERNAL_INFORMATION), .Internal)) {
        .SUCCESS => {},
        .ACCESS_DENIED => return error.AccessDenied,
        else => return error.Unexpected,
    }
    return .{
        .volume = volume.info.VolumeSerialNumber,
        .file = @as(u64, @bitCast(internal.IndexNumber)),
    };
}

test FileId {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "one", .data = "{}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two", .data = "{}\n" });
    const one = try tmp.dir.openFile(io, "one", .{});
    defer one.close(io);
    const again = try tmp.dir.openFile(io, "one", .{});
    defer again.close(io);
    const two = try tmp.dir.openFile(io, "two", .{});
    defer two.close(io);

    // Two handles to one file are one file; two files beside each other
    // are on one volume and are two files.
    const a = try FileId.of(one.handle);
    try std.testing.expect(a.eql(try FileId.of(again.handle)));
    const b = try FileId.of(two.handle);
    try std.testing.expect(!a.eql(b));
    try std.testing.expectEqual(a.volume, b.volume);
    // A directory is a file here like any other.
    try std.testing.expect(!a.eql(try FileId.of(tmp.dir.handle)));
    try std.testing.expect((try FileId.of(tmp.dir.handle)).eql(try FileId.of(tmp.dir.handle)));
}

test "FileId.ofPath" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "one", .data = "{}\n" });
    try tmp.dir.createDir(io, "sub", .default_dir);
    const one = try tmp.dir.openFile(io, "one", .{});
    defer one.close(io);
    const sub = try tmp.dir.openDir(io, "sub", .{});
    defer sub.close(io);

    // A path names what a handle to it is open on, a file or a directory,
    // relative to a directory or not.
    try std.testing.expect((try FileId.ofPath(io, tmp.dir, "one")).eql(try FileId.of(one.handle)));
    try std.testing.expect((try FileId.ofPath(io, tmp.dir, "sub")).eql(try FileId.of(sub.handle)));
    try std.testing.expect((try FileId.ofPath(io, tmp.dir, ".")).eql(try FileId.of(tmp.dir.handle)));
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const absolute = buffer[0..try tmp.dir.realPathFile(io, "one", &buffer)];
    try std.testing.expect((try FileId.ofPath(io, Io.Dir.cwd(), absolute)).eql(try FileId.of(one.handle)));
    try std.testing.expectError(error.FileNotFound, FileId.ofPath(io, tmp.dir, "gone"));

    // A socket cannot be opened as a file, and still has an identity.
    if (builtin.os.tag != .windows) {
        const sock_path = try std.testing.allocator.print("{s}.sock", .{absolute});
        defer std.testing.allocator.free(sock_path);
        const address = try std.Io.net.UnixAddress.init(sock_path);
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        const by_path = try FileId.ofPath(io, Io.Dir.cwd(), sock_path);
        try std.testing.expect(!by_path.eql(try FileId.of(one.handle)));
        try std.testing.expect(by_path.eql(try FileId.ofPath(io, tmp.dir, "one.sock")));
    }
}
