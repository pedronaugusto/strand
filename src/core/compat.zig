//! Shared-core specialization for the historical mapping policy. Its backend
//! supplies wire primitives; std hooks remain exclusively in the JSON bridge.
//! The legacy error and allocation contracts deliberately differ from bounded
//! acquisition. This specialization preserves the existing in-place fast path.
const std = @import("std");

pub fn valueInto(comptime T: type, self: anytype, out: *T) !void {
    if (T == @TypeOf(self.*).RawType) {
        out.* = try self.raw();
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |i| if (!i.is_tuple) return self.object(T, out),
        else => {},
    }
    out.* = try self.value(T);
}

pub fn value(comptime T: type, self: anytype) !T {
    if (T == @TypeOf(self.*).RawType) return self.raw();
    switch (@typeInfo(T)) {
        .bool => {
            self.space();
            if (self.word(@TypeOf(self.*).true_word)) return true;
            if (self.word(@TypeOf(self.*).false_word)) return false;
            return error.UnexpectedToken;
        },
        .float, .comptime_float => {
            const slice = try self.scalar();
            return std.fmt.parseFloat(T, slice);
        },
        .int, .comptime_int => return self.integer(T),
        .optional => |i| {
            self.space();
            if (self.word(@TypeOf(self.*).null_word)) return null;
            return try self.value(i.child);
        },
        .@"enum" => {
            const slice = try self.scalar();
            if (std.meta.stringToEnum(T, slice)) |tag| return tag;
            if (!@TypeOf(self.*).integerSpelling(slice)) return error.InvalidEnumTag;
            const tag_type = @typeInfo(T).@"enum".tag_type;
            const n = std.fmt.parseInt(tag_type, slice, 10) catch return error.InvalidEnumTag;
            return std.enums.fromInt(T, n) orelse error.InvalidEnumTag;
        },
        .@"struct" => |i| {
            if (i.is_tuple) {
                try self.take(@TypeOf(self.*).sequence_begin);
                var result: T = undefined;
                inline for (i.field_types, 0..) |field_type, n| {
                    if (n != 0) try self.take(@TypeOf(self.*).comma);
                    result[n] = try self.value(field_type);
                }
                try self.take(@TypeOf(self.*).sequence_end);
                return result;
            }
            var result: T = undefined;
            try self.object(T, &result);
            return result;
        },
        .array => |i| {
            self.space();
            if (i.child == u8 and self.cursor < self.input.len and self.input[self.cursor] == @TypeOf(self.*).text_begin) {
                const text = try self.string(false);
                if (text.len != i.len) return error.LengthMismatch;
                var result: T = undefined;
                @memcpy(&result, text);
                return result;
            }
            try self.take(@TypeOf(self.*).sequence_begin);
            var result: T = undefined;
            for (&result, 0..) |*item, n| {
                if (n != 0) try self.take(@TypeOf(self.*).comma);
                item.* = try self.value(i.child);
            }
            try self.take(@TypeOf(self.*).sequence_end);
            return result;
        },
        .vector => |i| {
            // Vectors use their array's JSON shape, including strings
            // for UTF-8 bytes, just as std.json writes them.
            const A = [i.len]i.child;
            return try self.value(A);
        },
        .pointer => return pointer(T, self),
        .@"union" => |i| {
            if (comptime @TypeOf(self.*).internal(T)) |inside| return self.tagged(T, inside);
            try self.take(@TypeOf(self.*).record_begin);
            const name = try self.string(false);
            try self.take(@TypeOf(self.*).colon);
            var result: ?T = null;
            inline for (i.field_names, i.field_types) |field_name, field_type| {
                if (std.mem.eql(u8, field_name, name)) {
                    result = if (field_type == void) payload: {
                        try self.take(@TypeOf(self.*).record_begin);
                        try self.take(@TypeOf(self.*).record_end);
                        break :payload @unionInit(T, field_name, {});
                    } else @unionInit(T, field_name, try self.value(field_type));
                    break;
                }
            } else return error.UnknownField;
            try self.take(@TypeOf(self.*).record_end);
            return result.?;
        },
        else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
    }
}

pub fn members(comptime T: type, comptime skip: ?[]const u8, comptime from: anytype, self: anytype, result: *T) !void {
    const info = @typeInfo(T).@"struct";
    var seen: [info.field_names.len]bool = @splat(false);
    _ = &seen;
    var hint: usize = 0;
    _ = &hint;
    var skipped = from == .after_skipped;
    _ = &skipped;
    const closed = switch (from) {
        .open => closed: {
            self.space();
            if (self.cursor < self.input.len and self.input[self.cursor] == @TypeOf(self.*).record_end) {
                self.cursor += 1;
                break :closed true;
            }
            break :closed false;
        },
        .after_skipped => closed: {
            try self.objectEnd();
            break :closed self.input[self.cursor - 1] == @TypeOf(self.*).record_end;
        },
    };
    if (closed) {} else fields_loop: while (true) {
        // The key the last one leads to, spelled as it is declared:
        // what a writer that keeps declaration order puts here, and
        // then there is no string to read and compare.
        self.space();
        inline for (info.field_names, 0..) |field_name, i| {
            if (comptime @TypeOf(self.*).literalKey(field_name)) |key| {
                if (i == hint and self.input.len - self.cursor >= key.len and
                    std.mem.eql(u8, self.input[self.cursor..][0..key.len], key))
                {
                    self.cursor += key.len;
                    try self.take(@TypeOf(self.*).colon);
                    try self.putField(T, result, &seen, field_name, i);
                    hint = (i + 1) % info.field_names.len;
                    try self.objectEnd();
                    if (self.input[self.cursor - 1] == @TypeOf(self.*).record_end) break :fields_loop;
                    continue :fields_loop;
                }
            }
        }
        const name = try self.string(false);
        try self.take(@TypeOf(self.*).colon);
        if (skip) |tag| if (std.mem.eql(u8, name, tag)) {
            if (skipped) return error.DuplicateField;
            skipped = true;
            try self.skipValue();
            try self.objectEnd();
            if (self.input[self.cursor - 1] == @TypeOf(self.*).record_end) break :fields_loop;
            continue :fields_loop;
        };

        inline for (info.field_names, 0..) |field_name, i| {
            if (i == hint and std.mem.eql(u8, field_name, name)) {
                try self.putField(T, result, &seen, field_name, i);
                hint = (i + 1) % info.field_names.len;
                try self.objectEnd();
                if (self.input[self.cursor - 1] == @TypeOf(self.*).record_end) break :fields_loop;
                continue :fields_loop;
            }
        }
        inline for (info.field_names, info.field_attrs, 0..) |field_name, field_attrs, i| {
            if (field_attrs.@"comptime")
                @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ field_name);
            if (std.mem.eql(u8, field_name, name)) {
                try self.putField(T, result, &seen, field_name, i);
                hint = (i + 1) % info.field_names.len;
                try self.objectEnd();
                if (self.input[self.cursor - 1] == @TypeOf(self.*).record_end) break :fields_loop;
                continue :fields_loop;
            }
        }
        if (!self.options.ignore_unknown_fields) return error.UnknownField;
        try self.skipValue();
        try self.objectEnd();
        if (self.input[self.cursor - 1] == @TypeOf(self.*).record_end) break;
    }

    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, field_type, field_attrs, i| if (!seen[i]) {
        if (field_attrs.defaultValue(field_type)) |default| {
            @field(result, field_name) = default;
            seen[i] = true;
        } else return error.MissingField;
    };
    std.debug.assert(std.mem.allEqual(bool, &seen, true));
}

pub fn putField(comptime T: type, comptime field_name: []const u8, comptime i: usize, self: anytype, result: *T, seen: anytype) !void {
    const field_type = @FieldType(T, field_name);
    if (seen[i]) switch (self.options.duplicate_field_behavior) {
        .use_first => {
            _ = try self.value(field_type);
            return;
        },
        .@"error" => return error.DuplicateField,
        .use_last => {},
    };
    // A field of a packed struct is bits inside an integer and has no
    // address to decode into, so it is decoded and then stored.
    if (@typeInfo(T).@"struct".layout == .@"packed") {
        @field(result, field_name) = try self.value(field_type);
    } else try self.valueInto(field_type, &@field(result, field_name));
    seen[i] = true;
}

pub fn emit(comptime Wire: type, v: anytype, options: anytype, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const T = @TypeOf(v);
    if (T == Wire.RawType) return Wire.raw(v.bytes, options, writer);
    if (comptime Wire.hasOwnStringify(T)) return Wire.stdValue(v, options, writer);
    switch (@typeInfo(T)) {
        .bool => try writer.writeAll(if (v) Wire.true_word else Wire.false_word),
        .int => |info| if (info.bits > 128) {
            try writer.printInt(v, 10, .lower, .{});
        } else {
            var digits: [Wire.decimal_max]u8 = undefined;
            try writer.writeAll(Wire.decimal(&digits, v));
        },
        .comptime_int => try Wire.value(@as(std.math.IntFittingRange(v, v), v), options, writer),
        .float, .comptime_float => {
            if (@as(f64, @floatCast(v)) == v) {
                try writer.print(Wire.empty_record, .{@as(f64, @floatCast(v))});
            } else {
                try writer.writeByte(Wire.text_begin);
                try writer.print(Wire.empty_record, .{v});
                try writer.writeByte(Wire.text_begin);
            }
        },
        .optional => if (v) |payload| try Wire.value(payload, options, writer) else try writer.writeAll(Wire.null_word),
        .@"enum" => |info| {
            if (info.mode == .nonexhaustive) {
                inline for (info.field_names) |field_name| {
                    if (v == @field(T, field_name)) break;
                } else return Wire.value(@backingInt(v), options, writer);
            }
            try Wire.string(@tagName(v), options, writer);
        },
        .enum_literal => try Wire.string(@tagName(v), options, writer),
        .error_set => try Wire.string(@errorName(v), options, writer),
        .@"struct" => |info| {
            try writer.writeByte(if (info.is_tuple) Wire.sequence_begin else Wire.record_begin);
            _ = try Wire.members(v, options, writer, true);
            try writer.writeByte(if (info.is_tuple) Wire.sequence_end else Wire.record_end);
        },
        .@"union" => |info| {
            if (comptime Wire.internal(T)) |inside| return Wire.tagged(v, inside, options, Wire.WriterSink{ .writer = writer });
            const Tag = info.tag_type.?;
            try writer.writeByte(Wire.record_begin);
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                if (v == @field(Tag, field_name)) {
                    try Wire.memberName(field_name, options, writer);
                    if (field_type == void) {
                        try writer.writeAll(Wire.empty_record);
                    } else {
                        try Wire.value(@field(v, field_name), options, writer);
                    }
                    break;
                }
            } else unreachable;
            try writer.writeByte(Wire.record_end);
        },
        .pointer => |info| switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                .array => try Wire.value(@as([]const std.meta.Elem(info.child), v), options, writer),
                else => try Wire.value(v.*, options, writer),
            },
            .many, .slice => {
                if (info.size == .many and info.sentinel() == null)
                    @compileError("unable to stringify type '" ++ @typeName(T) ++ "' without sentinel");
                const slice = if (info.size == .many) std.mem.span(v) else v;
                if (info.child == u8) {
                    if (!try Wire.text(Wire.WriterSink{ .writer = writer }, slice, options)) try Wire.array(slice, options, writer);
                } else {
                    try Wire.array(slice, options, writer);
                }
            },
            else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
        },
        .array => try Wire.value(&v, options, writer),
        .vector => |info| {
            const a: [info.len]info.child = v;
            try Wire.value(&a, options, writer);
        },
        else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
    }
}

pub fn emitMembers(comptime Wire: type, v: anytype, options: anytype, writer: *std.Io.Writer, first: bool) std.Io.Writer.Error!bool {
    const info = @typeInfo(@TypeOf(v)).@"struct";
    var none = first;
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (field_type == void) continue;
        var include = true;
        if (!info.is_tuple and @typeInfo(field_type) == .optional and !options.emit_null_optional_fields) {
            if (@field(v, field_name) == null) include = false;
        }
        if (include) {
            if (!none) try writer.writeByte(Wire.comma);
            none = false;
            if (!info.is_tuple) try Wire.memberName(field_name, options, writer);
            try Wire.value(@field(v, field_name), options, writer);
        }
    }
    return none;
}

pub fn emitBuffer(comptime Wire: type, v: anytype, options: anytype, out: anytype) @TypeOf(out.*).Error!void {
    const T = @TypeOf(v);
    if (T == Wire.RawType) return out.raw(v.bytes, options);
    if (comptime Wire.hasOwnStringify(T)) return out.stdValue(v, options);
    switch (@typeInfo(T)) {
        .bool => try out.write(if (v) Wire.true_word else Wire.false_word),
        .int => try out.integer(v),
        .comptime_int => try Wire.bufferValue(@as(std.math.IntFittingRange(v, v), v), options, out),
        .float, .comptime_float => try out.stdValue(v, options),
        .optional => if (v) |payload| try Wire.bufferValue(payload, options, out) else try out.write(Wire.null_word),
        // A value a non-exhaustive enum does not name is its number.
        .@"enum" => |info| if (info.mode == .exhaustive) switch (v) {
            inline else => |tag| try Wire.bufferTagName(@tagName(tag), options, out),
        } else switch (v) {
            inline else => |tag| try Wire.bufferTagName(@tagName(tag), options, out),
            _ => try Wire.bufferValue(@backingInt(v), options, out),
        },
        .enum_literal => try Wire.bufferString(@tagName(v), options, out),
        .error_set => try Wire.bufferString(@errorName(v), options, out),
        .@"struct" => |info| {
            try out.byte(if (info.is_tuple) Wire.sequence_begin else Wire.record_begin);
            try Wire.bufferMembers(v, options, out, false);
            try out.byte(if (info.is_tuple) Wire.sequence_end else Wire.record_end);
        },
        .@"union" => |info| {
            if (comptime Wire.internal(T)) |inside| return Wire.tagged(v, inside, options, out);
            const Tag = info.tag_type.?;
            try out.byte(Wire.record_begin);
            inline for (info.field_names, info.field_types) |field_name, field_type| {
                if (v == @field(Tag, field_name)) {
                    if (comptime Wire.safeFieldName(field_name)) {
                        try out.write(Wire.keyLiteral(field_name));
                    } else {
                        try Wire.bufferString(field_name, options, out);
                        try out.byte(Wire.colon);
                    }
                    if (field_type == void) {
                        try out.write(Wire.empty_record);
                    } else {
                        try Wire.bufferValue(@field(v, field_name), options, out);
                    }
                    break;
                }
            } else unreachable;
            try out.byte(Wire.record_end);
        },
        .pointer => |info| switch (info.size) {
            .one => switch (@typeInfo(info.child)) {
                .array => try Wire.bufferValue(@as([]const std.meta.Elem(info.child), v), options, out),
                else => try Wire.bufferValue(v.*, options, out),
            },
            .many, .slice => {
                if (info.size == .many and info.sentinel() == null)
                    @compileError("unable to stringify type '" ++ @typeName(T) ++ "' without sentinel");
                const slice = if (info.size == .many) std.mem.span(v) else v;
                if (info.child == u8) {
                    if (!try Wire.text(out, slice, options)) try Wire.bufferArray(slice, options, out);
                } else try Wire.bufferArray(slice, options, out);
            },
            else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
        },
        .array => try Wire.bufferValue(&v, options, out),
        .vector => |info| {
            const a: [info.len]info.child = v;
            try Wire.bufferValue(&a, options, out);
        },
        else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
    }
}

pub fn emitBufferMembers(comptime Wire: type, comptime lead: bool, v: anytype, options: anytype, out: anytype) @TypeOf(out.*).Error!void {
    const info = @typeInfo(@TypeOf(v)).@"struct";
    var first = !lead;
    _ = &first;
    // Whether a member before this one is always written, which
    // makes the comma in front of this one a constant.
    comptime var written_before = lead;
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (field_type == void) continue;
        const optional = !info.is_tuple and @typeInfo(field_type) == .optional;
        var include = true;
        if (optional and !options.emit_null_optional_fields) {
            if (@field(v, field_name) == null) include = false;
        }
        if (include) {
            if (!info.is_tuple and comptime Wire.safeFieldName(field_name)) {
                const key = comptime Wire.keyLiteral(field_name);
                if (written_before) {
                    try out.write(Wire.comma_word ++ key);
                } else {
                    if (!first) try out.byte(Wire.comma);
                    try out.write(key);
                }
            } else {
                if (!first) try out.byte(Wire.comma);
                if (!info.is_tuple) {
                    try Wire.bufferString(field_name, options, out);
                    try out.byte(Wire.colon);
                }
            }
            first = false;
            try Wire.bufferValue(@field(v, field_name), options, out);
        }
        if (!optional) written_before = true;
    }
}

fn pointer(comptime T: type, self: anytype) !T {
    const i = @typeInfo(T).pointer;
    return switch (i.size) {
        .one => {
            const result = try self.arena.create(i.child);
            result.* = try self.value(i.child);
            return result;
        },
        .slice => {
            self.space();
            if (i.child == u8 and self.cursor < self.input.len and self.input[self.cursor] == @TypeOf(self.*).text_begin) {
                const always = !i.attrs.@"const" or self.options.allocate.? == .alloc_always;
                const result = try self.string(always);
                if (i.sentinel()) |sentinel| {
                    const copy = try self.arena.allocSentinel(u8, result.len, sentinel);
                    @memcpy(copy, result);
                    return copy;
                }
                if (!i.attrs.@"const" and !always) unreachable;
                return @constCast(result); // safe: a mutable slice is only asked for with `always`, so these bytes were allocated here and are the caller's to write
            }
            try self.take(@TypeOf(self.*).sequence_begin);
            var list: std.ArrayList(i.child) = .empty;
            self.space();
            if (self.cursor < self.input.len and self.input[self.cursor] == @TypeOf(self.*).sequence_end) {
                self.cursor += 1;
            } else {
                while (true) {
                    try list.append(self.arena, try self.value(i.child));
                    self.space();
                    if (self.cursor == self.input.len) return error.UnexpectedEndOfInput;
                    if (self.input[self.cursor] == @TypeOf(self.*).sequence_end) {
                        self.cursor += 1;
                        break;
                    }
                    if (self.input[self.cursor] != @TypeOf(self.*).comma) return error.UnexpectedToken;
                    self.cursor += 1;
                }
            }
            if (i.sentinel()) |sentinel| return try list.toOwnedSliceSentinel(self.arena, sentinel);
            return try list.toOwnedSlice(self.arena);
        },
        else => @compileError("Unable to parse into type '" ++ @typeName(T) ++ "'"),
    };
}
