//! A length held to a byte limit, compared in aegis's domain: strand's own,
//! not part of `core`.
const std = @import("std");
const aegis = @import("aegis");

pub const Bytes = aegis.units.Bytes(usize);

/// Whether `n` bytes are more than `limit` allows; `n` equal to it is within.
pub fn exceeds(n: usize, limit: Bytes) bool {
    return Bytes.fromRaw(n).compare(limit) == .gt;
}

/// The bytes a buffer bounded by `limit` holds with one more (the `\r` half
/// of a terminator after a line of exactly the limit), at most the largest
/// count.
pub fn withOne(limit: Bytes) usize {
    const more = limit.add(.fromRaw(1)) catch return std.math.maxInt(usize);
    return more.raw();
}

/// What is left of `limit` once `used` bytes are taken, or null when they
/// are more than it.
pub fn left(limit: Bytes, used: usize) ?Bytes {
    return limit.sub(.fromRaw(used)) catch null;
}
