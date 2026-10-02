//! Minified value output over the selected encoder.
const std = @import("std");
pub fn Values(comptime encode: type) type {
    return struct {
        /// How `writeValue` spells a value. The same two settings as
        /// `Writer.Options`, and the same defaults.
        pub const ValueOptions = struct {
            /// When false, an optional field that is `null` is left out rather than
            /// written as `null`. `std.json`'s own default is true: a caller whose
            /// bytes must be the ones `std.json.Stringify.value(v, .{}, w)` writes
            /// says so here.
            emit_null_optional_fields: bool = false,
            /// When true, non-ASCII characters are written as `\uXXXX` escapes.
            escape_unicode: bool = false,
        };

        /// Writes one value's JSON, minified, with no terminator: the bytes a line
        /// holds, for a caller that frames the line itself — an envelope around the
        /// value, a checksum after it, a length in front of it.
        ///
        /// The encoding is `Writer`'s, which is `std.json`'s byte for byte under the
        /// same options. A value that fits in the unused part of `output`'s buffer
        /// is encoded there directly, and one that does not goes through `output`'s
        /// interface, which drains or grows it as `output` does.
        pub fn writeValue(output: *std.Io.Writer, value: anytype, options: ValueOptions) std.Io.Writer.Error!void {
            const encoding: std.json.Stringify.Options = .{
                .emit_null_optional_fields = options.emit_null_optional_fields,
                .escape_unicode = options.escape_unicode,
            };
            if (comptime encode.supports(@TypeOf(value))) {
                if (output.end < output.buffer.len) {
                    if (encode.valueBuffer(value, encoding, output.buffer[output.end..])) |written| {
                        output.end += written;
                        return;
                    } else |_| {}
                }
                return encode.value(value, encoding, output);
            }
            return std.json.Stringify.value(value, encoding, output);
        }
    };
}
