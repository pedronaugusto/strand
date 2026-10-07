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

        /// An object `writeObjectOpen` began: the members written so far, and
        /// no closing brace yet.
        pub const OpenObject = struct {
            output: *std.Io.Writer,
            options: ValueOptions,
            /// Whether no member has been written, so the next needs no comma.
            empty: bool,

            /// Writes one more member: `name` and `value` spelled as
            /// `writeValue` spells a struct's field, after a comma where a
            /// member came before it. Nothing checks that `name` is not one
            /// already written.
            pub fn member(object: *OpenObject, comptime name: []const u8, value: anytype) std.Io.Writer.Error!void {
                if (!object.empty) try object.output.writeByte(',');
                object.empty = false;
                try encode.memberName(name, stringify(object.options), object.output);
                try writeValue(object.output, value, object.options);
            }

            /// Writes the closing brace. The object is finished.
            pub fn close(object: OpenObject) std.Io.Writer.Error!void {
                try object.output.writeByte('}');
            }
        };

        /// Writes a struct as `writeValue` writes it, but for the closing
        /// brace, and hands back the object to go on with: members the struct
        /// does not have — a checksum over the bytes before it, a length, a
        /// signature — written by `OpenObject.member`, then `close`. What
        /// `output` holds after `writeObjectOpen` is exactly the object so far,
        /// so a checksum taken over it covers what a reader sees in front of
        /// the member that carries it.
        ///
        /// `value` is a struct, not a tuple, without a `jsonStringify` of its
        /// own, which would write its own object; either is refused at compile
        /// time. Its fields can be anything `writeValue` writes, a field
        /// `std.json` writes for itself included.
        pub fn writeObjectOpen(output: *std.Io.Writer, value: anytype, options: ValueOptions) std.Io.Writer.Error!OpenObject {
            const T = @TypeOf(value);
            const info = comptime info: {
                const info = @typeInfo(T);
                if (info != .@"struct" or info.@"struct".is_tuple or std.meta.hasFn(T, "jsonStringify"))
                    @compileError("writeObjectOpen takes a struct that writes as its fields, not '" ++ @typeName(T) ++ "'");
                break :info info.@"struct";
            };
            const encoding = stringify(options);
            if (comptime encode.supports(T)) {
                if (output.end < output.buffer.len) {
                    if (encode.valueBuffer(value, encoding, output.buffer[output.end..])) |written| {
                        // The closing brace is the last byte encoded, and is
                        // left where it is, past what `output` holds.
                        output.end += written - 1;
                        return .{ .output = output, .options = options, .empty = written == 2 };
                    } else |_| {}
                }
                try output.writeByte('{');
                const empty = try encode.members(value, encoding, output, true);
                return .{ .output = output, .options = options, .empty = empty };
            }
            // A field `std.json` writes for itself: each member written as
            // `std.json` writes a struct's, the field's value by `writeValue`.
            try output.writeByte('{');
            var object: OpenObject = .{ .output = output, .options = options, .empty = true };
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                if (comptime field_type != void) {
                    const absent = if (comptime @typeInfo(field_type) == .optional)
                        !options.emit_null_optional_fields and @field(value, field_name) == null
                    else
                        false;
                    if (!absent) try object.member(field_name, @field(value, field_name));
                }
            }
            return object;
        }

        fn stringify(options: ValueOptions) std.json.Stringify.Options {
            return .{
                .emit_null_optional_fields = options.emit_null_optional_fields,
                .escape_unicode = options.escape_unicode,
            };
        }

        /// Writes one value's JSON, minified, with no terminator: the bytes a line
        /// holds, for a caller that frames the line itself — an envelope around the
        /// value, a checksum after it, a length in front of it.
        ///
        /// The encoding is `Writer`'s, which is `std.json`'s byte for byte under the
        /// same options. A value that fits in the unused part of `output`'s buffer
        /// is encoded there directly, and one that does not goes through `output`'s
        /// interface, which drains or grows it as `output` does.
        pub fn writeValue(output: *std.Io.Writer, value: anytype, options: ValueOptions) std.Io.Writer.Error!void {
            const encoding = stringify(options);
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
