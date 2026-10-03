//! Internal work counts for tests. The observer belongs to the test that
//! installs it; each thread has its own, and consumer builds contain no calls.
const builtin = @import("builtin");

pub const Counts = struct {
    scan_bytes: usize = 0,
    parses: usize = 0,
    lane_searches: usize = 0,
};

threadlocal var observer: ?*Counts = null;

pub fn observe(counts: ?*Counts) void {
    if (builtin.is_test) observer = counts;
}

pub inline fn scan(bytes: usize) void {
    if (builtin.is_test) if (observer) |counts| {
        counts.scan_bytes += bytes;
    };
}

pub inline fn parse() void {
    if (builtin.is_test) if (observer) |counts| {
        counts.parses += 1;
    };
}

// Finding a lane is separate from asking whether a vector has any hits.
pub inline fn laneSearch() void {
    if (builtin.is_test) if (observer) |counts| {
        counts.lane_searches += 1;
    };
}
