//! A type's text form: the one way strand reads and writes a value as a
//! string, in every format, wherever a string meets the type. A type opts in
//! by declaring all three:
//!
//!     pub const text_form = .{ .max_len = 26, .schema_format = "date-time" };
//!     pub fn parse(text: []const u8) ParseError!T
//!     pub fn format(self: T, w: *std.Io.Writer) std.Io.Writer.Error!void
//!
//! `text_form` is a plain literal, so the declaring package imports nothing
//! from strand; `schema_format` is optional, the JSON Schema `format` its text
//! is (only a format Schema defines). `format` is the signature std's `{f}`
//! calls, so one method serves printing and strand. Never recognized by a
//! bare `parse`: without `text_form` a type is read by its shape. A
//! declaration that does not fit is a compile error naming what is wrong.
//!
//! Value types only: `parse` takes no allocator, so the value holds nothing
//! the text owns. Text longer than `max_len` is refused unread
//! (`LengthLimit`), and `format` writing past it is refused as well; a parse
//! error is `InvalidValue`, the type's own error name kept in the
//! diagnostics beside the field path, never the raw string in its place.
const std = @import("std");
const ctx = @import("context.zig");

/// Whether `T` declares a text form; a declaration that does not fit is a
/// compile error.
pub fn declares(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return false,
    }
    if (!@hasDecl(T, "text_form")) return false;
    comptime check(T);
    return true;
}

fn fail(comptime T: type, comptime what: []const u8) noreturn {
    @compileError("strand: " ++ @typeName(T) ++ " declares text_form, but " ++ what);
}

fn check(comptime T: type) void {
    const Form = @TypeOf(T.text_form);
    if (@typeInfo(Form) != .@"struct") fail(T, "text_form is not a struct literal");
    if (!@hasField(Form, "max_len")) fail(T, "text_form has no max_len");
    for (@typeInfo(Form).@"struct".field_names) |name| {
        if (!std.mem.eql(u8, name, "max_len") and !std.mem.eql(u8, name, "schema_format")) fail(T, "text_form has a field strand does not read: " ++ name);
    }
    if (T.text_form.max_len < 1) fail(T, "its max_len is less than 1");
    if (@hasField(Form, "schema_format")) {
        const named: []const u8 = T.text_form.schema_format;
        if (named.len == 0) fail(T, "its schema_format is empty");
    }
    if (!@hasDecl(T, "parse")) fail(T, "has no `pub fn parse(text: []const u8) !Self`");
    const parse = @typeInfo(@TypeOf(T.parse));
    if (parse != .@"fn" or parse.@"fn".param_types.len != 1 or parse.@"fn".param_types[0] != []const u8)
        fail(T, "parse is not `fn (text: []const u8) !Self`: it takes no allocator, a text form is a value type's");
    const returned = @typeInfo(parse.@"fn".return_type.?);
    if (returned != .error_union or returned.error_union.payload != T) fail(T, "parse does not return an error union of Self");
    if (returned.error_union.error_set == anyerror) fail(T, "parse returns anyerror: name its errors");
    if (!@hasDecl(T, "format")) fail(T, "has no `pub fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void`");
    if (@TypeOf(T.format) != fn (T, *std.Io.Writer) std.Io.Writer.Error!void)
        fail(T, "format is not `fn (self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void`, the signature std's {f} calls");
}

/// The longest text `T` reads or writes.
pub fn maxLen(comptime T: type) usize {
    return T.text_form.max_len;
}

/// The JSON Schema `format` `T`'s text is, when it names one.
pub fn schemaFormat(comptime T: type) ?[]const u8 {
    return if (@hasField(@TypeOf(T.text_form), "schema_format")) T.text_form.schema_format else null;
}

/// `value`'s text, in `buffer`; `LengthLimit` when `format` writes past
/// `max_len`.
pub fn write(value: anytype, buffer: *[maxLen(@TypeOf(value))]u8) error{LengthLimit}![]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    // A fixed writer fails only when the buffer is full: the text passed max_len.
    value.format(&w) catch |err| switch (err) {
        error.WriteFailed => return error.LengthLimit,
    };
    return w.buffered();
}

/// The value `text` spells: `LengthLimit` past `max_len`, before `parse`
/// sees it; `InvalidValue` for any error of `parse`, whose name the
/// diagnostics keep.
pub fn read(comptime T: type, text: []const u8, c: *ctx.Context) error{ LengthLimit, InvalidValue }!T {
    if (text.len > maxLen(T)) return error.LengthLimit;
    return T.parse(text) catch |err| c.invalid(@errorName(err));
}
