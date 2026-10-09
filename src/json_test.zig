const shakedown = @import("shakedown");
const jsonl = @import("strand.jsonl");
const std = @import("std");
const json = @import("strand.json");
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
    var buffer: [128]u8 = undefined;
    var scratch: [8192]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    try json.write(&output, owner.value, .{ .scratch = &scratch });
    var round = try json.parseStdValue(std.testing.allocator, output.buffered(), .{});
    defer round.deinit();
    try std.testing.expectEqual(@as(i64, 1), round.value.object.get("a").?.array.items[0].integer);
    try std.testing.expectError(error.AllocationLimit, json.parseStdValue(std.testing.allocator, "[1]", .{ .limits = .{ .allocation_bytes = 0 } }));
}

test "S2 legacy internal tag normalizes into common descriptor" {
    const U = union(enum) {
        a: struct { n: u8 },
        b,
        other,
        pub const jsonl_tag = "kind";
        pub const jsonl_other = .other;
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
