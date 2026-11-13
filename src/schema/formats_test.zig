//! The format grammars against their RFCs: forms built from each grammar's
//! own productions are accepted, forms built to break one rule are refused,
//! and random strings get the verdict of a model written here from the RFC's
//! text.
const std = @import("std");
const shakedown = @import("shakedown");
const net = @import("formats/net.zig");
const text = @import("formats/text.zig");
const Pointer = @import("Location.zig");

const testing = std.testing;
const gen = shakedown.gen;

fn pick(s: *shakedown.Source, alphabet: []const u8) u8 {
    return alphabet[gen.intRange(s, usize, 0, alphabet.len - 1)];
}

test "ipv4: a dotted-quad exactly as RFC 2673 writes one" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            // Four octets written plainly: accepted.
            var buf: [32]u8 = undefined;
            const quad = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ gen.intRange(s, u8, 0, 255), gen.intRange(s, u8, 0, 255), gen.intRange(s, u8, 0, 255), gen.intRange(s, u8, 0, 255) });
            try testing.expect(net.isIpv4(quad));
            // Any string of digits and dots: the RFC's verdict.
            var any: [16]u8 = undefined;
            const n = gen.intRange(s, usize, 0, any.len);
            for (any[0..n]) |*c| c.* = pick(s, "0123456789..");
            try testing.expectEqual(model(any[0..n]), net.isIpv4(any[0..n]));
        }

        /// Four dec-octets: `0`, or 1 to 3 digits not beginning with 0, at most 255.
        fn model(t: []const u8) bool {
            var parts: [5][]const u8 = undefined;
            var count: usize = 0;
            var start: usize = 0;
            for (t, 0..) |c, i| if (c == '.') {
                if (count == 4) return false;
                parts[count] = t[start..i];
                count += 1;
                start = i + 1;
            };
            if (count != 3) return false;
            parts[3] = t[start..];
            for (parts[0..4]) |p| {
                if (p.len == 0 or p.len > 3) return false;
                if (p.len > 1 and p[0] == '0') return false;
                const v = std.fmt.parseInt(u16, p, 10) catch return false;
                if (v > 255) return false;
            }
            return true;
        }
    }.one, .{ .cases = 5000, .seed = 0x1b4 });
}

test "ipv6: every text form RFC 4291 §2.2 gives, and none past it" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(testing.allocator);
            // Eight pieces, the last two maybe a dotted-quad, a run of them
            // maybe written `::`.
            const tail = gen.boolean(s);
            const pieces: usize = if (tail) 7 else 8; // the quad is one piece here, two groups
            const elide = gen.boolean(s);
            const from = gen.intRange(s, usize, 0, pieces - 1);
            const len = gen.intRange(s, usize, 1, pieces - from);
            var i: usize = 0;
            var wrote_any = false;
            while (i < pieces) {
                if (elide and i == from) {
                    try out.appendSlice(testing.allocator, "::");
                    i += len;
                    wrote_any = false;
                    continue;
                }
                if (wrote_any) try out.append(testing.allocator, ':');
                if (tail and i == pieces - 1) {
                    try out.print(testing.allocator, "{d}.{d}.{d}.{d}", .{ gen.intRange(s, u8, 0, 255), gen.intRange(s, u8, 0, 255), gen.intRange(s, u8, 0, 255), gen.intRange(s, u8, 0, 255) });
                } else {
                    for (0..gen.intRange(s, usize, 1, 4)) |_| try out.append(testing.allocator, pick(s, "0123456789abcdefABCDEF"));
                }
                wrote_any = true;
                i += 1;
            }
            // An elided run of every group but the tail still leaves the
            // form valid: `::` then the quad, or `::` alone.
            testing.expect(net.isIpv6(out.items)) catch |err| {
                std.debug.print("refused {s}\n", .{out.items});
                return err;
            };
            // Broken: a ninth group, a second `::`, a five-digit group.
            var broken: std.ArrayList(u8) = .empty;
            defer broken.deinit(testing.allocator);
            switch (gen.intRange(s, u8, 0, 2)) {
                0 => if (!elide) {
                    try broken.appendSlice(testing.allocator, "1:");
                    try broken.appendSlice(testing.allocator, out.items);
                },
                1 => if (elide) {
                    try broken.appendSlice(testing.allocator, out.items);
                    try broken.appendSlice(testing.allocator, if (std.mem.endsWith(u8, out.items, "::")) "1::1" else "::1");
                },
                else => if (!tail) {
                    try broken.appendSlice(testing.allocator, "12345:");
                    try broken.appendSlice(testing.allocator, out.items);
                },
            }
            if (broken.items.len > 0) testing.expect(!net.isIpv6(broken.items)) catch |err| {
                std.debug.print("accepted {s}\n", .{broken.items});
                return err;
            };
        }
    }.one, .{ .cases = 5000, .seed = 0x1b6 });
}

test "hostname: labels as RFC 1123 builds them, and each limit broken" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(testing.allocator);
            const labels = gen.intRange(s, usize, 1, 4);
            for (0..labels) |l| {
                if (l > 0) try out.append(testing.allocator, '.');
                const n = gen.intRange(s, usize, 1, 63);
                for (0..n) |k| {
                    const inner = k > 0 and k + 1 < n;
                    const c = pick(s, if (inner) "abcxyz019-" else "abcXYZ019");
                    // `--` at the third and fourth places is an A-label's.
                    try out.append(testing.allocator, if (c == '-' and k == 3 and out.items[out.items.len - 1] == '-') 'a' else c);
                }
            }
            try testing.expect(net.isHostname(out.items) == (out.items.len <= 253));
            // A label past 63, a leading hyphen, an underscore: refused.
            var broken = try out.clone(testing.allocator);
            defer broken.deinit(testing.allocator);
            switch (gen.intRange(s, u8, 0, 2)) {
                0 => try broken.appendNTimes(testing.allocator, 'a', 64),
                1 => try broken.insert(testing.allocator, 0, '-'),
                else => try broken.insert(testing.allocator, gen.intRange(s, usize, 0, broken.items.len), '_'),
            }
            try testing.expect(!net.isHostname(broken.items));
        }
    }.one, .{ .cases = 3000, .seed = 0x1123 });
}

test "uuid and json-pointer: random strings get RFC 9562's and RFC 6901's verdicts" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            var u: [36]u8 = undefined;
            for (&u, 0..) |*c, i| c.* = switch (i) {
                8, 13, 18, 23 => if (gen.intRange(s, u8, 0, 20) == 0) pick(s, "a0") else '-',
                else => if (gen.intRange(s, u8, 0, 40) == 0) pick(s, "g-") else pick(s, "0123456789abcdefABCDEF"),
            };
            const n = if (gen.intRange(s, u8, 0, 10) == 0) gen.intRange(s, usize, 0, 35) else 36;
            try testing.expectEqual(uuidModel(u[0..n]), text.isUuid(u[0..n]));
            // A pointer written from tokens, escapes and all: accepted.
            var w: std.Io.Writer.Allocating = .init(testing.allocator);
            defer w.deinit();
            for (0..gen.intRange(s, usize, 0, 4)) |_| {
                try w.writer.writeByte('/');
                var token: [6]u8 = undefined;
                const len = gen.intRange(s, usize, 0, token.len);
                for (token[0..len]) |*c| c.* = pick(s, "a~/01");
                try Pointer.writeToken(&w.writer, token[0..len]);
            }
            try testing.expect(text.isJsonPointer(w.written()));
            var p: [10]u8 = undefined;
            const pn = gen.intRange(s, usize, 0, p.len);
            for (p[0..pn]) |*c| c.* = pick(s, "/~01a");
            try testing.expectEqual(pointerModel(p[0..pn]), text.isJsonPointer(p[0..pn]));
        }

        fn uuidModel(t: []const u8) bool {
            if (t.len != 36) return false;
            for (t, 0..) |c, i| {
                const dash = i == 8 or i == 13 or i == 18 or i == 23;
                if (dash != (c == '-')) return false;
                if (!dash and std.mem.findScalar(u8, "0123456789abcdefABCDEF", c) == null) return false;
            }
            return true;
        }

        fn pointerModel(t: []const u8) bool {
            if (t.len > 0 and t[0] != '/') return false;
            for (t, 0..) |c, i| if (c == '~' and (i + 1 == t.len or (t[i + 1] != '0' and t[i + 1] != '1'))) return false;
            return true;
        }
    }.one, .{ .cases = 5000, .seed = 0x6901 });
}

test "email: RFC 5321 mailboxes built from dot-atoms, quoted strings and address literals" {
    try shakedown.check(testing.allocator, {}, struct {
        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const s = case.source;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(testing.allocator);
            if (gen.boolean(s)) {
                for (0..gen.intRange(s, usize, 1, 3)) |a| {
                    if (a > 0) try out.append(testing.allocator, '.');
                    for (0..gen.intRange(s, usize, 1, 6)) |_| try out.append(testing.allocator, pick(s, "az09!#$%&'*+-/=?^_`{|}~"));
                }
            } else {
                try out.append(testing.allocator, '"');
                for (0..gen.intRange(s, usize, 0, 6)) |_| switch (gen.intRange(s, u8, 0, 3)) {
                    0 => try out.appendSlice(testing.allocator, "\\\""),
                    else => try out.append(testing.allocator, pick(s, "az @.,[]")),
                };
                try out.append(testing.allocator, '"');
            }
            try out.append(testing.allocator, '@');
            switch (gen.intRange(s, u8, 0, 2)) {
                0 => try out.appendSlice(testing.allocator, "example.com"),
                1 => try out.print(testing.allocator, "[{d}.{d}.{d}.{d}]", .{ gen.intRange(s, u8, 0, 255), 0, 0, gen.intRange(s, u8, 0, 255) }),
                else => try out.appendSlice(testing.allocator, "[IPv6:2001:db8::1]"),
            }
            testing.expect(net.isEmail(out.items, false)) catch |err| {
                std.debug.print("refused {s}\n", .{out.items});
                return err;
            };
            // A dot leading the local part, or no `@`: refused.
            var broken = try out.clone(testing.allocator);
            defer broken.deinit(testing.allocator);
            if (gen.boolean(s)) {
                if (broken.items[0] != '"') try broken.insert(testing.allocator, 0, '.');
            } else {
                const at = std.mem.findScalarLast(u8, broken.items, '@').?;
                _ = broken.orderedRemove(at);
                if (std.mem.findScalar(u8, broken.items, '@') != null) return;
            }
            if (!std.mem.eql(u8, broken.items, out.items)) try testing.expect(!net.isEmail(broken.items, false));
        }
    }.one, .{ .cases = 3000, .seed = 0x5321 });
}
