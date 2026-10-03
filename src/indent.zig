//! Minified JSON laid out as `std.json` lays a value out under an indenting
//! `whitespace` option, as the bytes go by: what `.pretty` is for a value
//! this package's own encoder writes, because `std.json` does not know the
//! shape — a union tagged inside its object.

const std = @import("std");

/// A writer that takes one minified JSON value and hands `out` the same
/// value indented, byte for byte as `std.json.Stringify` writes it with
/// `whitespace`: a line per member and per item, `": "` after a key, and an
/// empty object or array as `{}` or `[]`.
///
/// Whitespace outside strings is dropped first, so a value whose bytes were
/// already spaced — a `Raw` — is laid out with the rest rather than left as
/// it was written.
pub const Indent = struct {
    out: *std.Io.Writer,
    unit: []const u8,
    depth: usize = 0,
    in_string: bool = false,
    escaped: bool = false,
    /// The bracket just written, whose line break waits for the next byte:
    /// a closing bracket there makes an empty pair with nothing between.
    open: ?u8 = null,
    interface: std.Io.Writer,

    pub fn init(out: *std.Io.Writer, whitespace: @FieldType(std.json.Stringify.Options, "whitespace"), buffer: []u8) Indent {
        return .{
            .out = out,
            .unit = switch (whitespace) {
                .minified => "",
                .indent_1 => " ",
                .indent_2 => "  ",
                .indent_3 => "   ",
                .indent_4 => "    ",
                .indent_8 => "        ",
                .indent_tab => "\t",
            },
            .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Indent = @alignCast(@fieldParentPtr("interface", w)); // safe: this vtable is installed only on an Indent's own `interface`
        try self.feed(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.feed(bytes);
            n += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try self.feed(last);
        return n + last.len * splat;
    }

    fn feed(self: *Indent, bytes: []const u8) std.Io.Writer.Error!void {
        if (self.unit.len == 0) return self.out.writeAll(bytes);
        for (bytes) |b| try self.byte(b);
    }

    fn byte(self: *Indent, b: u8) std.Io.Writer.Error!void {
        const out = self.out;
        if (self.in_string) {
            try out.writeByte(b);
            if (self.escaped) {
                self.escaped = false;
            } else if (b == '\\') {
                self.escaped = true;
            } else if (b == '"') {
                self.in_string = false;
            }
            return;
        }
        switch (b) {
            ' ', '\t', '\r', '\n' => return,
            else => {},
        }
        if (self.open) |bracket| {
            self.open = null;
            if (b == @as(u8, if (bracket == '{') '}' else ']')) {
                self.depth -= 1;
                return out.writeByte(b);
            }
            try self.newline();
        }
        switch (b) {
            '{', '[' => {
                try out.writeByte(b);
                self.depth += 1;
                self.open = b;
            },
            '}', ']' => {
                self.depth -= 1;
                try self.newline();
                try out.writeByte(b);
            },
            ',' => {
                try out.writeByte(',');
                try self.newline();
            },
            ':' => try out.writeAll(": "),
            '"' => {
                try out.writeByte('"');
                self.in_string = true;
            },
            else => try out.writeByte(b),
        }
    }

    fn newline(self: *Indent) std.Io.Writer.Error!void {
        try self.out.writeByte('\n');
        for (0..self.depth) |_| try self.out.writeAll(self.unit);
    }
};

test Indent {
    const V = struct {
        a: u8 = 1,
        e: struct {} = .{},
        l: []const u8 = "a\"{,:}",
        n: []const []const u8 = &.{ "x", "y" },
        o: struct { p: ?u8 = null, q: []const u8 = &.{}, r: []const u32 = &.{} } = .{},
    };
    inline for (.{ .indent_2, .indent_tab, .indent_1, .minified }) |whitespace| {
        var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer expected.deinit();
        try std.json.Stringify.value(V{}, .{ .whitespace = whitespace }, &expected.writer);

        var minified: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer minified.deinit();
        try std.json.Stringify.value(V{}, .{}, &minified.writer);

        var got: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer got.deinit();
        var buffer: [3]u8 = undefined;
        var indent: Indent = .init(&got.writer, whitespace, &buffer);
        try indent.interface.writeAll(minified.written());
        try indent.interface.flush();
        try std.testing.expectEqualStrings(expected.written(), got.written());
    }
}
