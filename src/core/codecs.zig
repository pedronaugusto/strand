//! Explicit std-container data codecs use only their public APIs.
const std = @import("std");
/// An unmanaged list is a variable sequence, including when its element is u8.
/// Its data belongs to Parsed/the caller arena; do not deinit it separately.
pub fn ArrayList(comptime T: type) type {
    return struct {
        /// Logical sequence length for validation of constructed defaults.
        pub fn length(value: std.ArrayList(T)) usize {
            return value.items.len;
        }
        pub fn encode(value: std.ArrayList(T), access: anytype) @typeInfo(@TypeOf(access.writeSequence(value.items))).error_union.error_set!void {
            try access.writeSequence(value.items);
        }
        pub fn decode(access: anytype) @typeInfo(@TypeOf(access.sequence(T))).error_union.error_set!std.ArrayList(T) {
            return .fromOwnedSlice(try access.sequence(T));
        }
    };
}
