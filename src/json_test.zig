const core = @import("core.zig");
const shakedown = @import("shakedown");
const jsonl = @import("jsonl.zig");
const std = @import("std");
const json = @import("json.zig");
test "S2 JSON exact decimal integers, shared field policy and lifetime" {
    const T = struct {
        n: u128,
        text: []const u8,
        pub const strand = .{ .fields = .{ .text = .{ .name = "label" } } };
    };
    var bytes = "{\"n\":340282366920938463463374607431768211455.0,\"label\":\"hi\"}".*;
    var result = try json.parse(T, std.testing.allocator, &bytes, .{});
    defer result.deinit();
    try std.testing.expectEqual(std.math.maxInt(u128), result.value.n);
    try std.testing.expectEqual(@as(usize, 0), result.requested_peak);
    var owned = try json.parseOwned(T, std.testing.allocator, &bytes, .{});
    defer owned.deinit();
    @memset(&bytes, ' ');
    try std.testing.expectEqualStrings("hi", owned.value.text);
}
test "S2 JSON strict limits reach ignored and Raw values" {
    const T = struct {};
    try std.testing.expectError(error.DepthLimit, json.parse(T, std.testing.allocator, "{\"x\":[[]]}", .{ .ignore_unknown_fields = true, .limits = .{ .depth = 2 } }));
    try std.testing.expectError(error.DuplicateField, json.parse(T, std.testing.allocator, "{\"x\":1,\"x\":2}", .{ .ignore_unknown_fields = true }));
    try std.testing.expectError(error.LengthLimit, json.parse(json.Raw, std.testing.allocator, "[\"long\"]", .{ .limits = .{ .string_bytes = 3 } }));
    var raw = try json.parse(json.Raw, std.testing.allocator, "[1e99999]", .{});
    defer raw.deinit();
    try std.testing.expectEqualStrings("[1e99999]", raw.value.bytes);
}
test "S2 JSON core write and union" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const T = struct { text: []const u8, n: u8 };
    try json.write(&writer, T{ .text = "a\nb", .n = 4 }, .{});
    try std.testing.expectEqualStrings("{\"text\":\"a\\nb\",\"n\":4}", writer.buffered());
    const U = union(enum) { a: u8, b: []const u8 };
    var result = try json.parse(U, std.testing.allocator, "{\"a\":3}", .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u8, 3), result.value.a);
    try std.testing.expectError(error.NumberOutOfRange, json.parse(u8, std.testing.allocator, "1.5", .{}));
}

test "S2 native Value lexemes, truncations and exact policies" {
    const input = "{\"a\":[1e9999,true,null,\"x\\n\"]}";
    var value = try json.parse(json.Value, std.testing.allocator, input, .{});
    defer value.deinit();
    try std.testing.expectEqualStrings("1e9999", value.value.object[0].value.array[0].number);
    for (0..input.len) |n| {
        if (json.parse(json.Value, std.testing.allocator, input[0..n], .{})) |result| {
            var owner = result;
            owner.deinit();
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "S2 exact IEEE numbers" {
    const T = struct {
        n: f64,
        pub const strand = .{ .fields = .{ .n = .{ .exact = true } } };
    };
    var value = try json.parse(T, std.testing.allocator, "{\"n\":0.5}", .{});
    defer value.deinit();
    try std.testing.expectEqual(@as(f64, 0.5), value.value.n);
    try std.testing.expectError(error.InexactNumber, json.parse(T, std.testing.allocator, "{\"n\":0.1}", .{}));
    try std.testing.expectError(error.NumberOutOfRange, json.parse(f64, std.testing.allocator, "1e9999", .{}));
}

test "S2 JSONL every chunk boundary and independent keep" {
    const T = struct { text: []const u8 };
    const input = "\xef\xbb\xbf{\"text\":\"a\\nç\"}\r\n\n{\"text\":\"b\"}\n";
    for (0..input.len + 1) |split| {
        var decoder = jsonl.Decoder(T).init(std.testing.allocator, .{});
        defer decoder.deinit();
        var count: usize = 0;
        for ([_][]const u8{ input[0..split], input[split..] }) |chunk| {
            var rest = chunk;
            while (rest.len != 0) {
                const result = decoder.push(rest);
                rest = rest[result.consumed..];
                switch (result.status) {
                    .failure => |err| return err,
                    .need_input => {},
                    .record => |record| {
                        count += 1;
                        try std.testing.expectEqualStrings(if (count == 1) "a\nç" else "b", record.value.text);
                        var saved = try decoder.keep(record.value);
                        defer saved.deinit();
                        try std.testing.expectEqualStrings(record.value.text, saved.value.text);
                    },
                }
            }
        }
        try std.testing.expectEqual(@as(usize, 2), count);
        try std.testing.expectEqual(@as(u64, 3), decoder.number);
    }
}
test "S2 JSONL drain cap across calls and final policy" {
    var decoder = jsonl.Decoder(u8).init(std.testing.allocator, .{ .max_line_bytes = 2, .recovery_bytes = 3 });
    defer decoder.deinit();
    const input = "123456789\n7\n";
    var result = decoder.push(input);
    try std.testing.expectEqual(error.LineTooLong, result.status.failure);
    var at = result.consumed;
    while (true) {
        result = decoder.push(input[at..]);
        at += result.consumed;
        if (result.status == .record) break;
        try std.testing.expectEqual(error.RecoveryLimit, result.status.failure);
        try std.testing.expect(result.consumed <= 3);
    }
    try std.testing.expectEqual(@as(u8, 7), result.status.record.value);
    try std.testing.expectEqual(@as(u64, 2), result.status.record.number);
    var required = jsonl.Decoder(u8).init(std.testing.allocator, .{ .final_record = .require_terminator });
    defer required.deinit();
    _ = required.push("7");
    try std.testing.expectEqual(error.TruncatedRecord, required.finish().status.failure);
}

fn jsonAllocationSweep(gpa: std.mem.Allocator) !void {
    var no_resize: shakedown.alloc.NoResize = .init(gpa);
    var owner = try json.parseOwned(json.Value, no_resize.allocator(), "{\"escaped\":\"a\\nb\",\"items\":[{\"n\":1.0},null,true]}", .{});
    defer owner.deinit();
}
fn decoderAllocationSweep(gpa: std.mem.Allocator) !void {
    var no_resize: shakedown.alloc.NoResize = .init(gpa);
    var decoder = jsonl.Decoder(json.Value).init(no_resize.allocator(), .{});
    defer decoder.deinit();
    const first = decoder.push("{\"escaped\":\"a\\n");
    if (first.status == .failure) return first.status.failure;
    const last = decoder.push("b\"}\n");
    if (last.status == .failure) return last.status.failure;
    try std.testing.expect(last.status == .record);
    var saved = try decoder.keep(last.status.record.value);
    defer saved.deinit();
}
test "S2 NoResize rollback across every JSON and decoder allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, jsonAllocationSweep, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decoderAllocationSweep, .{});
    try std.testing.expectError(error.AllocationLimit, json.parseOwned([]const u8, std.testing.allocator, "\"data\"", .{ .limits = .{ .allocation_bytes = 0 } }));
}

test "S2 constructed Value emission validates lexemes and duplicate keys" {
    var buffer: [128]u8 = undefined;
    for ([_][]const u8{ "true", "[1]", "01", "1 ", "-", "1e" }) |invalid| {
        var output = std.Io.Writer.fixed(&buffer);
        try std.testing.expectError(error.InvalidRaw, json.write(&output, json.Value{ .number = invalid }, .{}));
    }
    const object: json.Value = .{ .object = &.{ .{ .key = "x", .value = .null_value }, .{ .key = "x", .value = .null_value } } };
    var output = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.DuplicateField, json.write(&output, object, .{}));
}
test "S2 std Value bridge uses bounded context and standard numeric alternatives" {
    var owner = try json.parseStdValue(std.testing.allocator, "{\"n\":1e9999,\"a\":[1,0.5]}", .{});
    defer owner.deinit();
    try std.testing.expectEqualStrings("1e9999", owner.value.object.get("n").?.number_string);
    try owner.value.object.getPtr("a").?.array.append(.{ .integer = 2 });
    var buffer: [128]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    try json.write(&output, owner.value, .{ .scratch = &scratch });
    var round = try json.parseStdValue(std.testing.allocator, output.buffered(), .{});
    defer round.deinit();
    try std.testing.expectEqual(@as(i64, 1), round.value.object.get("a").?.array.items[0].integer);
    try std.testing.expectError(error.AllocationLimit, json.parseStdValue(std.testing.allocator, "[1]", .{ .limits = .{ .allocation_bytes = 0 } }));
}

test "S2 internal tag with a catch-all arm" {
    const U = union(enum) {
        a: struct { n: u8 },
        b,
        other,
        pub const strand = .{ .tag = "kind", .other = "other" };
    };
    var owner = try json.parse(U, std.testing.allocator, "{\"n\":3,\"kind\":\"a\"}", .{});
    defer owner.deinit();
    try std.testing.expectEqual(@as(u8, 3), owner.value.a.n);
    var buffer: [128]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    try json.write(&output, owner.value, .{});
    try std.testing.expectEqualStrings("{\"kind\":\"a\",\"n\":3}", output.buffered());
}
fn standardAllocationSweep(gpa: std.mem.Allocator) !void {
    var owner = try json.parseStdValue(gpa, "{\"x\":[1,\"a\\nb\"]}", .{});
    defer owner.deinit();
}
test "S2 standard bridge rollback every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, standardAllocationSweep, .{});
}

test "S2 push buffer and arena share the resident allocation cap" {
    var decoder = jsonl.Decoder(json.Value).init(std.testing.allocator, .{ .parse = .{ .limits = .{ .allocation_bytes = 128 } } });
    defer decoder.deinit();
    const result = decoder.push("[\"a\\nb\"]\n");
    try std.testing.expectEqual(error.AllocationLimit, result.status.failure);
    try std.testing.expect(decoder.buffer.len + decoder.arena_resident_bytes <= 128);
}

test "S2 scalar and vector escape boundaries match standard ordinary JSON" {
    var text: [128]u8 = undefined;
    for (&text, 0..) |*byte, i| byte.* = @intCast(i); // safe: i is in 0..128.
    for (0..text.len + 1) |length| {
        var actual: [1024]u8 = undefined;
        var expected: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&actual);
        var standard = std.Io.Writer.fixed(&expected);
        try json.write(&out, text[0..length], .{});
        try std.json.Stringify.value(text[0..length], .{}, &standard);
        try std.testing.expectEqualStrings(standard.buffered(), out.buffered());
    }
}
test "S2 every strict limit at zero, exact boundary and one below" {
    inline for (.{ "input_bytes", "items", "numeric_bytes", "work" }) |name| {
        const boundary: usize = if (comptime std.mem.eql(u8, name, "work")) 3 else 1;
        for ([_]usize{ 0, boundary - 1, boundary }) |limit| {
            var limits: core.Limits = .{};
            @field(limits, name) = limit;
            const parsed = json.parse(u8, std.testing.allocator, "1", .{ .limits = limits });
            if (limit == boundary) {
                var owner = try parsed;
                owner.deinit();
            } else if (parsed) |result| {
                var owner = result;
                owner.deinit();
                return error.TestUnexpectedResult;
            } else |err| try std.testing.expect(err == error.InputLimit or err == error.ItemLimit or err == error.LengthLimit or err == error.WorkLimit);
        }
    }
    for ([_]usize{ 0, 1, 2 }) |limit| {
        if (limit == 2) {
            var owner = try json.parse(json.Raw, std.testing.allocator, "[[1,2]]", .{ .limits = .{ .depth = limit, .container_items = limit } });
            owner.deinit();
            var text = try json.parse([]const u8, std.testing.allocator, "\"ab\"", .{ .limits = .{ .string_bytes = limit } });
            text.deinit();
            var key = try json.parse(struct {}, std.testing.allocator, "{\"ab\":1}", .{ .ignore_unknown_fields = true, .limits = .{ .key_bytes = limit } });
            key.deinit();
        } else {
            try std.testing.expectError(error.DepthLimit, json.parse(json.Raw, std.testing.allocator, "[[1,2]]", .{ .limits = .{ .depth = limit } }));
            try std.testing.expectError(error.ItemLimit, json.parse(json.Raw, std.testing.allocator, "[1,2]", .{ .limits = .{ .container_items = limit } }));
            try std.testing.expectError(error.LengthLimit, json.parse([]const u8, std.testing.allocator, "\"ab\"", .{ .limits = .{ .string_bytes = limit } }));
            try std.testing.expectError(error.LengthLimit, json.parse(struct {}, std.testing.allocator, "{\"ab\":1}", .{ .ignore_unknown_fields = true, .limits = .{ .key_bytes = limit } }));
        }
    }
    var memory: [8]u8 = undefined;
    for ([_]usize{ 0, 2, 3 }) |limit| {
        var output = std.Io.Writer.fixed(&memory);
        if (limit == 3) try json.write(&output, @as(u8, 123), .{ .limits = .{ .output_bytes = limit } }) else try std.testing.expectError(error.OutputLimit, json.write(&output, @as(u8, 123), .{ .limits = .{ .output_bytes = limit } }));
    }
}
const Generated = struct { n: u64, text: []const u8 };
fn generatedJson(_: void, case: *shakedown.Case) anyerror!void {
    const labels = [_][]const u8{ "plain", "a\nb", "say \"yes\"", "λ", "" };
    const value: Generated = .{ .n = shakedown.gen.int(case.source, u64), .text = shakedown.gen.oneOf(case.source, []const u8, &labels) };
    var memory: [256]u8 = undefined;
    var output = std.Io.Writer.fixed(&memory);
    try json.write(&output, value, .{});
    var parsed = try json.parseOwned(Generated, std.testing.allocator, output.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(value, parsed.value);
    var decoder = jsonl.Decoder(Generated).init(std.testing.allocator, .{});
    defer decoder.deinit();
    var rest = output.buffered();
    while (rest.len != 0) {
        const size = @min(rest.len, 1 + shakedown.gen.int(case.source, u8) % 7);
        const result = decoder.push(rest[0..size]);
        if (result.status == .failure) return result.status.failure;
        try std.testing.expectEqual(size, result.consumed);
        rest = rest[size..];
    }
    const record = decoder.push("\n");
    if (record.status == .failure) return record.status.failure;
    try std.testing.expectEqualDeep(value, record.status.record.value);
}
test "S2 generated common JSON round trip and arbitrary chunk partitions" {
    try shakedown.check(std.testing.allocator, {}, generatedJson, .{ .cases = 512, .seed = 0x737472616e645332 });
}

fn HundredFields() type {
    @setEvalBranchQuota(1_000_000);
    var names: [100][]const u8 = undefined;
    var types: [100]type = @splat(u8);
    const attrs: [100]std.builtin.Type.Struct.FieldAttributes = @splat(.{});
    for (&names, 0..) |*name, i| name.* = std.fmt.comptimePrint("f{d}", .{i});
    _ = &types;
    return @Struct(.auto, null, &names, &types, &attrs);
}
test "S2 fixed hundred-field schema needs no heap or caller scratch" {
    const T = HundredFields();
    var value: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |name| @field(value, name) = 1;
    var memory: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&memory);
    try json.write(&output, value, .{});
    var owner = try json.parse(T, std.testing.failing_allocator, output.buffered(), .{});
    defer owner.deinit();
    try std.testing.expectEqualDeep(value, owner.value);
    try std.testing.expectEqual(@as(usize, 0), owner.requested_peak);
}

test "S2 wide integers, exponents and direct IEEE destination rounding" {
    var minimum = try json.parse(i128, std.testing.allocator, "-170141183460469231731687303715884105728.0", .{});
    defer minimum.deinit();
    try std.testing.expectEqual(std.math.minInt(i128), minimum.value);
    var exponent = try json.parse(u128, std.testing.allocator, "3402823669209384634633746074317682114550e-1", .{});
    defer exponent.deinit();
    try std.testing.expectEqual(std.math.maxInt(u128), exponent.value);
    var wide = try json.parse(f128, std.testing.allocator, "1267650600228229401496703205377", .{});
    defer wide.deinit();
    try std.testing.expectEqual(@as(f128, 0x10000000000000000000000001), wide.value);
    const above_half: f128 = 1 + 0x1p-24 + 0x1p-54;
    var memory: [256]u8 = undefined;
    const spelling = try std.mem.print(&memory, "{d:.80}", .{above_half});
    var rounded = try json.parse(f32, std.testing.allocator, spelling, .{});
    defer rounded.deinit();
    try std.testing.expectEqual(@as(f32, 1 + 0x1p-23), rounded.value);
    try std.testing.expectEqual(@as(f32, 1), @as(f32, @floatCast(try std.fmt.parseFloat(f64, spelling))));
    inline for (.{ f16, f32, f64, f128 }) |F| {
        const Exact = struct {
            n: F,
            pub const strand = .{ .fields = .{ .n = .{ .exact = true } } };
        };
        var owner = try json.parse(Exact, std.testing.allocator, "{\"n\":0.5}", .{});
        defer owner.deinit();
        try std.testing.expectEqual(@as(F, 0.5), owner.value.n);
        try std.testing.expectError(error.InexactNumber, json.parse(Exact, std.testing.allocator, "{\"n\":0.1}", .{}));
    }
}
test "S2 push final and skip policies at every byte boundary" {
    const input = "1\nnope\n2";
    for (0..input.len + 1) |split| {
        var decoder = jsonl.Decoder(u8).init(std.testing.allocator, .{ .on_malformed = .skip });
        defer decoder.deinit();
        var count: usize = 0;
        for ([_][]const u8{ input[0..split], input[split..] }) |chunk| {
            var rest = chunk;
            while (rest.len != 0) {
                const result = decoder.push(rest);
                if (result.status == .failure) return result.status.failure;
                if (result.status == .record) count += 1;
                rest = rest[result.consumed..];
            }
        }
        try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expectEqual(@as(u8, 2), decoder.finish().status.record.value);
        try std.testing.expectEqual(@as(u64, 1), decoder.skipped);
        try std.testing.expectEqual(error.Finished, decoder.push("3\n").status.failure);
    }
    var drop = jsonl.Decoder(u8).init(std.testing.allocator, .{ .final_record = .drop });
    defer drop.deinit();
    _ = drop.push("2");
    try std.testing.expect(drop.finish().status == .need_input);
}
test "S2 warmed fixed push decoder makes no backing allocation" {
    var counting: shakedown.alloc.Counting = .init(std.testing.allocator);
    var no_resize: shakedown.alloc.NoResize = .init(counting.allocator());
    var decoder = jsonl.Decoder(Generated).init(no_resize.allocator(), .{});
    defer decoder.deinit();
    const record = "{\"n\":9,\"text\":\"plain\"}\n";
    try std.testing.expect(decoder.push(record).status == .record);
    const allocations = counting.allocations;
    const live = counting.live_bytes;
    for (0..1000) |_| try std.testing.expect(decoder.push(record).status == .record);
    try std.testing.expectEqual(allocations, counting.allocations);
    try std.testing.expectEqual(live, counting.live_bytes);
}
test "S2 push BOM stays at stream start after oversized recovery" {
    const input = "222222222222222222222\n\xef\xbb\xbf2\n";
    for (0..input.len + 1) |split| {
        var no_resize: shakedown.alloc.NoResize = .init(std.testing.allocator);
        var decoder = jsonl.Decoder(u8).init(no_resize.allocator(), .{ .max_line_bytes = 16 });
        defer decoder.deinit();
        var oversized: usize = 0;
        var malformed: usize = 0;
        for ([_][]const u8{ input[0..split], input[split..] }) |chunk| {
            var rest = chunk;
            while (rest.len != 0) {
                const result = decoder.push(rest);
                switch (result.status) {
                    .failure => |err| switch (err) {
                        error.LineTooLong => oversized += 1,
                        error.SyntaxError => malformed += 1,
                        else => return err,
                    },
                    .record => return error.UnexpectedRecord,
                    .need_input => try std.testing.expect(result.consumed != 0),
                }
                rest = rest[result.consumed..];
            }
        }
        try std.testing.expectEqual(@as(usize, 1), oversized);
        try std.testing.expectEqual(@as(usize, 1), malformed);
        try std.testing.expectEqual(@as(u64, 2), decoder.number);
        try std.testing.expectEqual(@as(u64, 22), decoder.record_offset);
        try std.testing.expectEqual(@as(u64, input.len), decoder.consumed);
    }
}
test "S2 caller-arena JSON diagnostics reset across operations and early limits" {
    const T = struct { id: u8 };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics: core.Diagnostics = .{ .format = "stale" };
    const options: json.ParseOptions = .{ .diagnostics = &diagnostics };
    try std.testing.expectError(error.UnknownField, json.parseLeaky(T, arena.allocator(), "{\"old\":1}", options));
    try std.testing.expectEqualStrings("json", diagnostics.format);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.path.len);
    const value = try json.parseLeaky(T, arena.allocator(), "{\"id\":2}", options);
    try std.testing.expectEqual(@as(u8, 2), value.id);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path.len);
    try std.testing.expectError(error.UnknownField, json.parseLeaky(T, arena.allocator(), "{\"again\":1}", options));
    var limited = options;
    limited.limits.input_bytes = 0;
    try std.testing.expectError(error.InputLimit, json.parseLeaky(T, arena.allocator(), "{}", limited));
    try std.testing.expectEqualStrings("json", diagnostics.format);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.path.len);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.offset);
}
