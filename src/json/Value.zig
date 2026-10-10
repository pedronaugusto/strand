//! JSON-native dynamic values retain validated numeric lexemes and object order.
const number = @import("number.zig");
const WireDecoder = @import("Decoder.zig");
const core = @import("../core.zig");
pub const Member = struct { key: []const u8, value: Value };
pub const Value = union(enum) {
    null_value,
    boolean: bool,
    number: []const u8,
    string: []const u8,
    array: []const Value,
    object: []const Member,
    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!Value {
        return switch (try access.peek()) {
            .none => blk: {
                _ = try access.read(?bool);
                break :blk .null_value;
            },
            .boolean => .{ .boolean = try access.read(bool) },
            .number => .{ .number = try access.number() },
            .text => .{ .string = try access.read([]const u8) },
            .begin => |header| if (header.kind == .sequence)
                .{ .array = try access.read([]const Value) }
            else blk: {
                const pairs = try access.read(core.Pairs([]const u8, Value));
                // Identical semantic pair storage, copied without wire re-parsing.
                const members = try access.alloc(Member, pairs.items.len);
                for (members, pairs.items) |*member, pair| member.* = .{ .key = pair.key, .value = pair.value };
                break :blk .{ .object = members };
            },
            else => error.UnexpectedType,
        };
    }
    pub fn strandSerialize(self: Value, access: anytype) @TypeOf(access.*).Error!void {
        switch (self) {
            .null_value => try access.write(@as(?bool, null)),
            .boolean => |v| try access.write(v),
            .string => |v| try access.write(v),
            .array => |v| try access.writeSequence(v),
            .object => |v| try access.writePairs(v),
            .number => |v| {
                try access.chargeWork(v.len);
                if (!number.valid(v)) return error.InvalidRaw;
                try access.raw(WireDecoder.Format, v);
            },
        }
    }
};
