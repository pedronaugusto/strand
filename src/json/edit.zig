//! JSONC edited in place: a value set, a member added, an element inserted
//! or removed, each found by JSON Pointer through the decoder every JSONC
//! parse uses (its member and element spans, comments and trailing commas
//! included) and spelled by `json.write`, so every byte the change does not
//! replace stays as it was: comments, blank lines, the order and spelling of
//! the rest. A container written across lines gets a new member on a line of
//! its own at its members' indentation; one written on a line keeps to it.
//! Each edit is read back before it is kept: a change that would leave text
//! the reader refuses is an error, and the text is as it was.
const std = @import("std");
const core = @import("../core.zig");
const edit = @import("../core/edit.zig");
const decoding = @import("Decoder.zig");
const strings = @import("text.zig");
const api = @import("api.zig");

const Wire = decoding.Dialect(.jsonc);
pub const Error = edit.Error;

pub const EditOptions = struct {
    limits: core.Limits = .{},
};

/// One member of an object or element of an array, where it lies.
const Child = struct {
    /// A member's name as written, escapes in it; empty for an element.
    name: []const u8 = "",
    escaped: bool = false,
    /// The member's first byte (its name's quote), or the element's.
    start: usize,
    value_start: usize,
    value_end: usize,
};
/// An object or an array, where it lies, and its members or elements.
const Container = struct {
    object: bool,
    /// The opening bracket, and the position past the closing one.
    open: usize,
    end: usize,
    children: []const Child,
    /// Its members stand on lines of their own.
    lines: bool,
};

/// What a pointer reaches.
const Place = struct {
    /// The value's span.
    start: usize,
    end: usize,
    /// The container it is in and its place there; null for the root.
    parent: ?Container = null,
    index: usize = 0,
};

/// A JSONC document held as its text, edited in place.
pub const Edit = struct {
    gpa: std.mem.Allocator,
    text: edit.Text,
    options: EditOptions,

    /// `text` checked as JSONC and copied: the edit's own.
    pub fn init(gpa: std.mem.Allocator, text: []const u8, options: EditOptions) Error!Edit {
        try check(gpa, text, options);
        return .{ .gpa = gpa, .text = try edit.Text.init(gpa, text), .options = options };
    }
    pub fn deinit(self: *Edit) void {
        self.text.deinit(self.gpa);
    }
    /// The document as it is now.
    pub fn bytes(self: *const Edit) []const u8 {
        return self.text.bytes.items;
    }

    /// The value at `pointer` made `value`: replaced where there is one, or
    /// added as the object's new last member, or appended to the array where
    /// the last token is `-`.
    pub fn set(self: *Edit, pointer: []const u8, value: anytype) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = self.bytes();
        const path = try edit.Pointer.parse(pointer);
        if (try self.find(a, path)) |place| {
            const spelled = try self.spell(a, value, edit.indentation(text, place.start));
            return self.commit(a, .{ .start = place.start, .end = place.end, .replacement = spelled });
        }
        const split = path.split() orelse return error.PathNotFound;
        const parent = (try self.find(a, split.parent)) orelse return error.PathNotFound;
        const container = try readContainer(a, text, parent.start, self.options) orelse return error.PathNotFound;
        if (container.object) {
            var name: std.Io.Writer.Allocating = .init(a);
            try api.write(&name.writer, split.last.unescape(try a.alloc(u8, split.last.written.len)), .{});
            return self.add(a, container, container.children.len, name.written(), value);
        }
        if (!split.last.isEnd()) return error.PathNotFound;
        return self.add(a, container, container.children.len, null, value);
    }
    /// `value` put into the array before the element `pointer` names, or at
    /// its end for `-`; into an object, as `set` adds a member.
    pub fn insert(self: *Edit, pointer: []const u8, value: anytype) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const path = try edit.Pointer.parse(pointer);
        const split = path.split() orelse return error.PathNotFound;
        const parent = (try self.find(a, split.parent)) orelse return error.PathNotFound;
        const container = try readContainer(a, self.bytes(), parent.start, self.options) orelse return error.PathNotFound;
        if (container.object) return self.set(pointer, value);
        const at = if (split.last.isEnd()) container.children.len else split.last.index() orelse return error.PathNotFound;
        if (at > container.children.len) return error.PathNotFound;
        return self.add(a, container, at, null, value);
    }
    /// The member or element at `pointer` taken out, with its separator and,
    /// where it stands on lines of its own, those lines.
    pub fn remove(self: *Edit, pointer: []const u8) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = self.bytes();
        const place = (try self.find(a, try edit.Pointer.parse(pointer))) orelse return error.PathNotFound;
        const container = place.parent orelse return error.PathNotFound;
        const child = container.children[place.index];
        const after = space(text, child.value_end);
        const comma_after = after < text.len and text[after] == ',';
        // The comma before it, where it is the last of several and has none after.
        const comma_before: ?usize = if (!comma_after and place.index > 0) space(text, container.children[place.index - 1].value_end) else null;
        if (!container.lines) {
            var start = child.start;
            var end = child.value_end;
            if (comma_after) {
                // A comma after it goes with it, and the spaces after that.
                end = after + 1;
                while (end < text.len and (text[end] == ' ' or text[end] == '\t')) end += 1;
            } else if (comma_before) |k| start = k;
            return self.commit(a, .{ .start = start, .end = end, .replacement = "" });
        }
        // On lines of its own: its lines go, a comment after it on its last
        // line too; a comment on the lines above it stays.
        const line = edit.lineStart(text, child.start);
        const own_start = if (edit.blankBetween(text, line, child.start)) line else child.start;
        const tail = if (comma_after) after + 1 else child.value_end;
        const own_end = lineRest(text, tail) orelse tail;
        if (comma_before) |k| {
            // The comma before goes too, and what stands between it and the
            // member stays.
            return self.commit(a, .{ .start = k, .end = own_end, .replacement = text[k + 1 .. own_start] });
        }
        try self.commit(a, .{ .start = own_start, .end = own_end, .replacement = "" });
    }

    /// The place `path` reaches, or null where nothing is there.
    fn find(self: *Edit, a: std.mem.Allocator, path: edit.Pointer) Error!?Place {
        const text = self.bytes();
        const root_start = space(text, 0);
        var place: Place = .{ .start = root_start, .end = try valueEnd(text, root_start, self.options) };
        var rest = path;
        while (rest.next()) |token| {
            const container = try readContainer(a, text, place.start, self.options) orelse return null;
            const k: usize = if (container.object) blk: {
                // The last member of a name, as a reader keeping the last does.
                var found: ?usize = null;
                for (container.children, 0..) |child, i| if (nameIs(a, child, token)) {
                    found = i;
                };
                break :blk found orelse return null;
            } else token.index() orelse return null;
            if (k >= container.children.len) return null;
            const child = container.children[k];
            place = .{ .start = child.value_start, .end = child.value_end, .parent = container, .index = k };
        }
        return place;
    }

    /// A new member or element at `at` among `container`'s: on a line of its
    /// own where its members are, else on theirs.
    fn add(self: *Edit, a: std.mem.Allocator, container: Container, at: usize, name: ?[]const u8, value: anytype) Error!void {
        const text = self.bytes();
        var member: std.ArrayList(u8) = .empty;
        const indent = memberIndent(a, text, container) catch return error.OutOfMemory;
        if (name) |n| {
            try member.appendSlice(a, n);
            try member.appendSlice(a, ": ");
        }
        try member.appendSlice(a, try self.spell(a, value, if (container.lines) indent else ""));
        const kids = container.children;
        if (kids.len == 0) {
            // Inside the brackets, after any comment there.
            const open = container.open + 1;
            const replacement = if (container.lines or std.mem.findScalar(u8, text[open .. container.end - 1], '\n') != null)
                try std.mem.concat(a, u8, &.{ "\n", indent, member.items, "\n", edit.indentation(text, container.open) })
            else
                member.items;
            return self.commit(a, .{ .start = open, .end = open, .replacement = replacement });
        }
        if (at < kids.len) {
            // Before an element: the new one, then its separator.
            const before = kids[at].start;
            const replacement = if (container.lines)
                try std.mem.concat(a, u8, &.{ member.items, ",\n", indent })
            else
                try std.mem.concat(a, u8, &.{ member.items, ", " });
            return self.commit(a, .{ .start = before, .end = before, .replacement = replacement });
        }
        // After the last: a comma after it (unless it has one already), the
        // new member after its line's comment where members stand on lines.
        const last = kids[kids.len - 1];
        const after = space(text, last.value_end);
        if (after < text.len and text[after] == ',') {
            const insert_at = if (container.lines) (lineRest(text, after + 1) orelse after + 1) else after + 1;
            const replacement = if (container.lines)
                try std.mem.concat(a, u8, &.{ "\n", indent, member.items, "," })
            else
                try std.mem.concat(a, u8, &.{ " ", member.items, "," });
            const at_line_end = if (container.lines and insert_at > 0 and text[insert_at - 1] == '\n') insert_at - 1 else insert_at;
            return self.commit(a, .{ .start = at_line_end, .end = at_line_end, .replacement = replacement });
        }
        if (container.lines) {
            const line_end = lineRest(text, last.value_end) orelse last.value_end;
            const end = if (line_end > 0 and text[line_end - 1] == '\n') line_end - 1 else line_end;
            const replacement = try std.mem.concat(a, u8, &.{ ",", text[last.value_end..end], "\n", indent, member.items });
            return self.commit(a, .{ .start = last.value_end, .end = end, .replacement = replacement });
        }
        const replacement = try std.mem.concat(a, u8, &.{ ", ", member.items });
        return self.commit(a, .{ .start = last.value_end, .end = last.value_end, .replacement = replacement });
    }

    /// `value` as JSON, indented as a container across lines is (two spaces a
    /// level, each line after the first after `indent`), or on one line.
    fn spell(self: *Edit, a: std.mem.Allocator, value: anytype, indent: []const u8) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        try api.write(&out.writer, value, .{ .limits = self.options.limits, .whitespace = .indent_2 });
        return edit.indented(a, out.written(), indent);
    }
    /// `splice` made, if the text it makes reads as JSONC.
    fn commit(self: *Edit, a: std.mem.Allocator, splice: edit.Splice) Error!void {
        const next = try self.text.spliced(a, splice);
        try check(a, next, self.options);
        try self.text.replace(self.gpa, next);
    }
};

/// Whether `text` reads as JSONC.
fn check(gpa: std.mem.Allocator, text: []const u8, options: EditOptions) Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Checked as every value is, kept as its bytes: no tree built to be dropped.
    _ = try api.jsonc.parseLeaky(api.Raw, arena.allocator(), text, .{ .limits = options.limits, .duplicates = .last });
}

/// Where the white space and comments after `at` end.
fn space(text: []const u8, at: usize) usize {
    var i = at;
    while (i < text.len) {
        switch (text[i]) {
            ' ', '\t', '\n', '\r' => i += 1,
            '/' => {
                if (i + 1 >= text.len) return i;
                if (text[i + 1] == '/') {
                    i = std.mem.findScalarPos(u8, text, i, '\n') orelse text.len;
                } else if (text[i + 1] == '*') {
                    i = if (std.mem.findPos(u8, text, i + 2, "*/")) |k| k + 2 else return i;
                } else return i;
            },
            else => return i,
        }
    }
    return i;
}
/// Where the line after `at` ends, past its line feed, when nothing but
/// spaces and a comment stand there; null when something else does.
fn lineRest(text: []const u8, at: usize) ?usize {
    var i = at;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r')) i += 1;
    if (i == text.len) return i;
    if (text[i] == '\n') return i + 1;
    if (std.mem.startsWith(u8, text[i..], "//")) return edit.lineEnd(text, i);
    return null;
}

/// Where the value at `start` ends.
fn valueEnd(text: []const u8, start: usize, options: EditOptions) Error!usize {
    var c: core.Context = .init(.failing, options.limits, .borrowed);
    var d: Wire = undefined;
    d.init(&c, text);
    d.checking = true;
    d.at = start;
    if (!try d.pass(&c)) return error.SyntaxError;
    return d.last_end;
}

/// The object or array at `start`, or null where the value is neither.
fn readContainer(a: std.mem.Allocator, text: []const u8, start: usize, options: EditOptions) Error!?Container {
    if (start >= text.len or (text[start] != '{' and text[start] != '[')) return null;
    const object = text[start] == '{';
    var c: core.Context = .init(.failing, options.limits, .borrowed);
    var d: Wire = undefined;
    d.init(&c, text);
    d.checking = true;
    d.at = start;
    _ = (try d.open(&c, .{ .expected = if (object) .record else .sequence })) orelse return error.SyntaxError;
    try c.enter();
    var children: std.ArrayList(Child) = .empty;
    var count: usize = 0;
    if (object) {
        while (try d.passMember(&c, &count)) |m| try children.append(a, .{
            .name = m.name,
            .escaped = m.escaped,
            .start = @intFromPtr(m.name.ptr) - @intFromPtr(text.ptr) - 1,
            .value_start = m.value_start,
            .value_end = m.value_end,
        });
    } else {
        while (try d.passElementSpan(&c, &count)) |e| try children.append(a, .{ .start = e.value_start, .value_start = e.value_start, .value_end = e.value_end });
    }
    const end = d.last_end;
    const lines = children.items.len != 0 and std.mem.findScalar(u8, text[start..children.items[0].start], '\n') != null;
    return .{ .object = object, .open = start, .end = end, .children = children.items, .lines = lines };
}

/// Whether a member's name, as written, is the token's.
fn nameIs(a: std.mem.Allocator, child: Child, token: edit.Token) bool {
    const wanted = token.unescape(a.alloc(u8, token.written.len) catch return false);
    if (!child.escaped) return std.mem.eql(u8, child.name, wanted);
    return strings.spells(child.name, wanted);
}

/// The indentation a new member of `container` takes: its members', or one
/// level past its own line's.
fn memberIndent(a: std.mem.Allocator, text: []const u8, container: Container) ![]const u8 {
    if (container.children.len != 0 and container.lines) return edit.indentation(text, container.children[0].start);
    return std.mem.concat(a, u8, &.{ edit.indentation(text, container.open), "  " });
}
