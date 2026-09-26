//! The bytes that must not appear raw in a line, found a register at a time.

const std = @import("std");
const builtin = @import("builtin");

/// The offset of the first byte in `bytes` that must not appear raw in a JSON
/// Lines line, or `null`.
///
/// Those are the C0 controls other than tab: JSON forbids them inside a
/// string without an escape and has no use for them between tokens, so one
/// arriving raw means the bytes are damaged rather than merely wrong. `\r`
/// and `\n` reach this test only when they are not the terminator, which is
/// exactly when they are damage too. DEL and the C1 range are left alone:
/// they are ordinary characters inside a JSON string.
///
/// Every line a reader returns is scanned by this, so it reads a register's
/// worth of bytes at a time rather than one: a byte is control when it is
/// below 0x20 and is not a tab, and both halves of that predicate answer a
/// whole vector at once. `scalarControl` is the same predicate written out,
/// and only the last few bytes of a short line go through it.
///
/// The register is as wide as the machine has, and then half of it, and half
/// of that: a log line is often shorter than one register of a machine with
/// wide ones, and such a line still has to be read a register at a time.
/// Taking the widest and giving up on anything narrower would put every line
/// under sixty-four bytes through the byte loop on a machine with 512-bit
/// registers, which is where the lines and the machines both are.
pub fn indexOfControl(bytes: []const u8) ?usize {
    if (!@inComptime() and !std.debug.inValgrind()) {
        if (std.simd.suggestVectorLength(u8)) |widest| {
            inline for (0..4) |halvings| {
                const block_len = widest >> halvings;
                if (comptime block_len >= 8) {
                    if (bytes.len >= block_len) return controlInBlocks(block_len, bytes);
                }
            }
        }
    }
    return scalarControl(bytes);
}

/// The offset of the first byte in `bytes` that is a C0 control other than
/// tab, `\r` and `\n` among them, or `null`.
///
/// `indexOfControl`'s predicate, answered for a caller who expects to find
/// one and wants the first: framing a line means stopping at its terminator,
/// and a terminator answers this predicate. `indexOfControl` folds four
/// vectors into one answer because it is written for a line that holds none
/// of these bytes at all; this one asks each vector on its own, because the
/// answer is usually in the first.
pub fn firstControlOrTerminator(bytes: []const u8) ?usize {
    var i: usize = 0;
    if (!@inComptime() and !std.debug.inValgrind()) {
        if (std.simd.suggestVectorLength(u8)) |block_len| {
            const Block = @Vector(block_len, u8);
            const highest: Block = @splat(0x20);
            const tab: Block = @splat('\t');
            while (i + block_len <= bytes.len) : (i += block_len) {
                const block: Block = bytes[i..][0..block_len].*;
                const hits = (block < highest) & (block != tab);
                if (firstHit(block_len, hits)) |at| return i + at;
            }
        }
    }
    return if (scalarControl(bytes[i..])) |at| i + at else null;
}

/// The index of the first true lane of `hits`, or `null` when there is none.
///
/// `std.simd.firstTrue` asks the vector for its smallest matching index, and
/// on x86_64 that is a blend and then a minimum taken across the register
/// by halves: over a dozen instructions, each waiting on the one before, on
/// every line a reader frames. x86 turns a compare into a bitmask in one
/// instruction and finds the lowest set bit of it in another, and those two
/// are the whole answer. NEON has no such mask and is good at the reduction,
/// so everywhere else the question is asked of the vector.
inline fn firstHit(comptime n: usize, hits: @Vector(n, bool)) ?usize {
    if (comptime builtin.cpu.arch.isX86()) {
        const mask: std.meta.Int(.unsigned, n) = @bitCast(hits);
        return if (mask == 0) null else @ctz(mask);
    }
    return if (@reduce(.Or, hits)) std.simd.firstTrue(hits).? else null;
}

test firstControlOrTerminator {
    try std.testing.expectEqual(@as(?usize, null), firstControlOrTerminator("{\"a\":\"b\"}"));
    try std.testing.expectEqual(@as(?usize, 9), firstControlOrTerminator("{\"a\":\"b\"}\n{}"));
    // A tab is not one of these bytes; every other C0 control is.
    try std.testing.expectEqual(@as(?usize, null), firstControlOrTerminator("{\"a\":\t1}"));
    try std.testing.expectEqual(@as(?usize, 0), firstControlOrTerminator("\r\n"));
}

test "firstControlOrTerminator stops where the byte loop stops" {
    // Every length up to four vectors, with every awkward byte at every
    // offset: the first byte the vectors answer for has to be the first byte
    // the predicate written out answers for.
    const block_len = std.simd.suggestVectorLength(u8) orelse 16;
    var buf: [4 * 64 + 3]u8 = undefined;
    const longest = @min(4 * block_len + 3, buf.len);

    for (0..longest) |len| {
        const bytes = buf[0..len];
        for ([_]u8{ 0x00, 0x1f, '\n', '\r', '\t', ' ', 'x', 0x7f, 0xff }) |byte| {
            for (0..len) |at| {
                @memset(bytes, 'x');
                bytes[at] = byte;
                try std.testing.expectEqual(scalarControl(bytes), firstControlOrTerminator(bytes));
            }
        }
        @memset(bytes, '\t');
        try std.testing.expectEqual(scalarControl(bytes), firstControlOrTerminator(bytes));
    }
}

/// `indexOfControl` over `bytes`, which is at least `block_len` long, a
/// vector of that width at a time.
fn controlInBlocks(comptime block_len: usize, bytes: []const u8) ?usize {
    const Block = @Vector(block_len, u8);
    const highest: Block = @splat(0x20);
    const tab: Block = @splat('\t');
    const group = 4 * block_len;

    var i: usize = 0;
    // Four blocks are folded into one answer before anything leaves the
    // vector registers, because asking a vector "did any lane match" is the
    // expensive instruction here and the compares are not. A line that has no
    // control byte in it — which is every line of an undamaged log — pays one
    // of those per group.
    while (i + group <= bytes.len) : (i += group) {
        var any: @Vector(block_len, bool) = @splat(false);
        inline for (0..4) |k| {
            const block: Block = bytes[i + k * block_len ..][0..block_len].*;
            any = any | ((block < highest) & (block != tab));
        }
        // One of these four blocks holds it; which byte it is, is worth
        // finding the slow way, since it ends the scan.
        if (@reduce(.Or, any)) return i + scalarControl(bytes[i..][0..group]).?;
    }

    // What is left of the line is folded the same way, in one go: the last
    // block is read overlapping the one before it rather than a byte at a
    // time, so a line of any length at all costs at most one more of those
    // instructions.
    const rest = i;
    var any: @Vector(block_len, bool) = @splat(false);
    while (i + block_len <= bytes.len) : (i += block_len) {
        const block: Block = bytes[i..][0..block_len].*;
        any = any | ((block < highest) & (block != tab));
    }
    if (i < bytes.len) {
        const block: Block = bytes[bytes.len - block_len ..][0..block_len].*;
        any = any | ((block < highest) & (block != tab));
    }
    if (!@reduce(.Or, any)) return null;
    // The overlap may reach back over bytes already cleared, so what it found
    // is at `rest` or after it, or was never here.
    return if (scalarControl(bytes[rest..])) |at| rest + at else null;
}

/// `indexOfControl`'s predicate, one byte at a time: the last few bytes of a
/// line, and the whole of one too short for the narrowest vector or on a
/// machine with no vectors to use.
fn scalarControl(bytes: []const u8) ?usize {
    for (bytes, 0..) |byte, i| {
        if (byte < 0x20 and byte != '\t') return i;
    }
    return null;
}

test indexOfControl {
    try std.testing.expectEqual(@as(?usize, null), indexOfControl("{\"a\":\"b\"}"));
    try std.testing.expectEqual(@as(?usize, null), indexOfControl("{\"a\":\t1}"));
    try std.testing.expectEqual(@as(?usize, 5), indexOfControl("{\"a\":\x00}"));
    try std.testing.expectEqual(@as(?usize, 0), indexOfControl("\r"));
    // DEL is an ordinary character as far as JSON is concerned.
    try std.testing.expectEqual(@as(?usize, null), indexOfControl("\x7f"));
}

test "indexOfControl reads a line by the vector the way it reads it by the byte" {
    // Every length up to four vectors, with every awkward byte at every
    // offset of every one of them: the unrolled pair, the single block and
    // the tail all have to answer what the loop they replace answers.
    const block_len = std.simd.suggestVectorLength(u8) orelse 16;
    var buf: [4 * 64 + 3]u8 = undefined;
    const longest = @min(4 * block_len + 3, buf.len);

    for (0..longest) |len| {
        const bytes = buf[0..len];
        for ([_]u8{ 0x00, 0x01, 0x1f, '\n', '\r', '\t', ' ', 'x', 0x7f, 0xff }) |byte| {
            for (0..len) |at| {
                @memset(bytes, 'x');
                bytes[at] = byte;
                try std.testing.expectEqual(scalarControl(bytes), indexOfControl(bytes));
            }
        }
        // A line that is nothing but tabs is the case the second half of the
        // predicate is there for.
        @memset(bytes, '\t');
        try std.testing.expectEqual(scalarControl(bytes), indexOfControl(bytes));
    }
}
