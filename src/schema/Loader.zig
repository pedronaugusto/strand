//! Where a compile gets a document no schema it has holds: the caller's, by
//! URI, through a file, uplink, or a table. strand fetches nothing itself. A
//! loader embeds this and recovers itself with `@fieldParentPtr`.
const std = @import("std");

const Loader = @This();

vtable: *const VTable,

pub const VTable = struct {
    /// The document at `uri` (absolute, with no fragment), allocated on
    /// `gpa`, which the compile owns from then on.
    load: *const fn (loader: *Loader, gpa: std.mem.Allocator, io: std.Io, uri: []const u8) LoadError![]const u8,
};

pub const LoadError = error{
    /// No document at the URI.
    NotFound,
    /// The loader will not fetch the URI (its scheme, its host, a policy).
    Refused,
    Canceled,
    OutOfMemory,
    /// The document was there and reading it failed.
    ReadFailed,
};

/// The document at `uri`, from the loader's own `load`.
pub fn load(l: *Loader, gpa: std.mem.Allocator, io: std.Io, uri: []const u8) LoadError![]const u8 {
    return l.vtable.load(l, gpa, io, uri);
}
