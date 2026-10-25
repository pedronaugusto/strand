//! The inputs of python-dotenv 1.2.4's own parser tests (`tests/test_parser.py`;
//! BSD-3-Clause, its licence in `src/corpus/python-dotenv/LICENSE`), each with
//! what python-dotenv reads from a file of it, as trials'
//! `strand/formats/dotenv/python_dotenv.py suite` writes these cases: every
//! key and value in order, a key with no `=` null. `null` for the cases
//! strand refuses: a line python-dotenv skips as an error, or a key given
//! twice, of which python-dotenv keeps the last.
const std = @import("std");
const strand = @import("../strand.zig");
const dotenv = strand.dotenv;
const core = strand.core;

const Expected = []const struct { []const u8, ?[]const u8 };
const Case = struct { input: []const u8, expected: ?Expected };

const cases = [_]Case{
    .{ .input = "", .expected = &.{} },
    .{ .input = "a=b", .expected = &.{.{ "a", "b" }} },
    .{ .input = "'a'=b", .expected = &.{.{ "a", "b" }} },
    .{ .input = "[=b", .expected = &.{.{ "[", "b" }} },
    .{ .input = " a = b ", .expected = &.{.{ "a", "b" }} },
    .{ .input = "export a=b", .expected = &.{.{ "a", "b" }} },
    .{ .input = " export 'a'=b", .expected = &.{.{ "a", "b" }} },
    .{ .input = "# a=b", .expected = &.{} },
    .{ .input = "a=b#c", .expected = &.{.{ "a", "b#c" }} },
    .{ .input = "a=b #c", .expected = &.{.{ "a", "b" }} },
    .{ .input = "a=b\x09#c", .expected = &.{.{ "a", "b" }} },
    .{ .input = "a= #b", .expected = &.{.{ "a", "" }} },
    .{ .input = "a=  # b", .expected = &.{.{ "a", "" }} },
    .{ .input = "a=#b", .expected = &.{.{ "a", "#b" }} },
    .{ .input = "a=# # comment", .expected = &.{.{ "a", "#" }} },
    .{ .input = "a=\x09#c", .expected = &.{.{ "a", "" }} },
    .{ .input = "a= #c\x0ad=e", .expected = &.{ .{ "a", "" }, .{ "d", "e" } } },
    .{ .input = "a=b c", .expected = &.{.{ "a", "b c" }} },
    .{ .input = "a=b\x09c", .expected = &.{.{ "a", "b\x09c" }} },
    .{ .input = "a=b  c", .expected = &.{.{ "a", "b  c" }} },
    .{ .input = "a=b\xc2\xa0 c", .expected = &.{.{ "a", "b\xc2\xa0 c" }} },
    .{ .input = "a=b c ", .expected = &.{.{ "a", "b c" }} },
    .{ .input = "a='b c '", .expected = &.{.{ "a", "b c " }} },
    .{ .input = "a=\"b c \"", .expected = &.{.{ "a", "b c " }} },
    .{ .input = "export export_a=1", .expected = &.{.{ "export_a", "1" }} },
    .{ .input = "export port=8000", .expected = &.{.{ "port", "8000" }} },
    .{ .input = "a=\"b\x0ac\"", .expected = &.{.{ "a", "b\x0ac" }} },
    .{ .input = "a='b\x0ac'", .expected = &.{.{ "a", "b\x0ac" }} },
    .{ .input = "a=\"b\x0ac\"", .expected = &.{.{ "a", "b\x0ac" }} },
    .{ .input = "a=\"b\\nc\"", .expected = &.{.{ "a", "b\x0ac" }} },
    .{ .input = "a='b\\nc'", .expected = &.{.{ "a", "b\\nc" }} },
    .{ .input = "a=\"b\\\"c\"", .expected = &.{.{ "a", "b\"c" }} },
    .{ .input = "a='b\\'c'", .expected = &.{.{ "a", "b'c" }} },
    .{ .input = "a='b\\\\c'", .expected = &.{.{ "a", "b\\c" }} },
    .{ .input = "a=\"b\\\\c\"", .expected = &.{.{ "a", "b\\c" }} },
    .{ .input = "a='b\\\\'\x0ac='d'", .expected = &.{ .{ "a", "b\\" }, .{ "c", "d" } } },
    .{ .input = "a=\"b\\\\\"\x0ac=\"d\"", .expected = &.{ .{ "a", "b\\" }, .{ "c", "d" } } },
    .{ .input = "a='b\\\\\\'c'", .expected = &.{.{ "a", "b\\'c" }} },
    .{ .input = "a=\xc3\xa0", .expected = &.{.{ "a", "\xc3\xa0" }} },
    .{ .input = "a=\"\xc3\xa0\"", .expected = &.{.{ "a", "\xc3\xa0" }} },
    .{ .input = "no_value_var", .expected = &.{.{ "no_value_var", null }} },
    .{ .input = "a: b", .expected = null },
    .{ .input = "a=b\x0ac=d", .expected = &.{ .{ "a", "b" }, .{ "c", "d" } } },
    .{ .input = "a=b\x0dc=d", .expected = &.{ .{ "a", "b" }, .{ "c", "d" } } },
    .{ .input = "a=b\x0d\x0ac=d", .expected = &.{ .{ "a", "b" }, .{ "c", "d" } } },
    .{ .input = "a=\x0ab=c", .expected = &.{ .{ "a", "" }, .{ "b", "c" } } },
    .{ .input = "\x0a\x0a", .expected = &.{} },
    .{ .input = "a=b\x0a\x0a", .expected = &.{.{ "a", "b" }} },
    .{ .input = "a=b\x0a\x0ac=d", .expected = &.{ .{ "a", "b" }, .{ "c", "d" } } },
    .{ .input = "a=\"\x0ab=c", .expected = null },
    .{ .input = "# comment\x0aa=\"b\x0ac\"\x0ad=e\x0a", .expected = &.{ .{ "a", "b\x0ac" }, .{ "d", "e" } } },
    .{ .input = "a=b\x0a# comment 1", .expected = &.{.{ "a", "b" }} },
    .{ .input = "# comment 1\x0a# comment 2", .expected = &.{} },
    .{ .input = "uglyKey[%$=\"S3cr3t_P4ssw#rD\" #\x0aa=b", .expected = &.{ .{ "uglyKey[%$", "S3cr3t_P4ssw#rD" }, .{ "a", "b" } } },
    .{ .input = "\xef\xbb\xbfa=b", .expected = &.{.{ "a", "b" }} },
    .{ .input = "\xef\xbb\xbfa=b\x0ac=d", .expected = &.{ .{ "a", "b" }, .{ "c", "d" } } },
};

test "python-dotenv's parser cases: each read as it reads a file of it, or refused" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        const read = dotenv.parseLeaky(core.Pairs([]const u8, ?[]const u8), arena.allocator(), case.input, .{});
        const expected = case.expected orelse {
            if (read) |_| {
                std.debug.print("unexpected acceptance: {f}\n", .{std.zig.fmtString(case.input)});
                return error.TestUnexpectedResult;
            } else |_| continue;
        };
        const env = read catch |err| {
            std.debug.print("unexpected refusal: {f}: {s}\n", .{ std.zig.fmtString(case.input), @errorName(err) });
            return err;
        };
        try std.testing.expectEqual(expected.len, env.items.len);
        for (expected, env.items) |e, item| {
            try std.testing.expectEqualStrings(e[0], item.key);
            if (e[1]) |value| try std.testing.expectEqualStrings(value, item.value.?) else try std.testing.expect(item.value == null);
        }
    }
}
