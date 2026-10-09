//! The shared line/recovery boundary decision, independent of transport.
const std = @import("std");
pub const Part = struct { consumed: usize, terminated: bool };
/// Recovery consumes at most budget, including LF; its caller retains drain
/// state when no complete boundary was consumed.
pub fn part(bytes: []const u8, budget: usize) Part {
    const available = bytes[0..@min(bytes.len, budget)];
    if (std.mem.findScalar(u8, available, '\n')) |at| return .{ .consumed = at + 1, .terminated = true };
    return .{ .consumed = available.len, .terminated = false };
}
