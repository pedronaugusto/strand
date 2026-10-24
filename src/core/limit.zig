//! A length held to a byte limit, compared in aegis's domain: strand's own,
//! not part of `core`.
const aegis = @import("aegis");

const Bytes = aegis.units.Bytes(usize);

/// Whether `n` bytes are more than `limit` allows; `n` equal to it is within.
pub fn exceeds(n: usize, limit: Bytes) bool {
    return Bytes.fromRaw(n).compare(limit) == .gt;
}

/// What is left of `limit` once `used` bytes are taken, or null when they
/// are more than it.
pub fn left(limit: Bytes, used: usize) ?Bytes {
    return limit.sub(.fromRaw(used)) catch null;
}
