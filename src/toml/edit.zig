//! TOML edited in place: a value set, a key added, an element inserted, a
//! key or a table removed, each found by JSON Pointer through the reader
//! every TOML parse uses (recording where each part is written) and spelled
//! by TOML's own writer, so every byte the change does not replace stays as
//! it was: comments, blank lines, key order, quoting, number spelling.
//!
//! A value written `key = value`, or in an array, is replaced where it is. A
//! key added to a table goes after the last `key = value` line of its
//! section (or inside its braces, for an inline table; under its dotted
//! prefix, for a table dotted keys made), and a table or an array of tables
//! added is a new section at the end of its parent's. A table made by
//! headers is set by removing it and adding the new one. Removing a key takes
//! its line; removing a table takes every section and dotted key it is made
//! of. Each edit is read back before it is kept: a change that would leave
//! text the reader refuses is an error, and the text is as it was.
const std = @import("std");
const core = @import("../core.zig");
const edit = @import("../core/edit.zig");
const syntax = @import("syntax.zig");
const api = @import("api.zig");
const strings = @import("text.zig");

pub const Error = edit.Error;
const none = syntax.none;

pub const EditOptions = struct {
    limits: core.Limits = .{},
    version: syntax.Version = .v1_1,
};

/// The document read, with where each part is written.
const Read = struct {
    doc: syntax.Document,
    spans: syntax.Spans,
    /// Each node's container.
    parents: []u32,
    text: []const u8,

    fn node(self: *const Read, n: u32) syntax.Node {
        return self.doc.nodes.items[n];
    }
    fn span(self: *const Read, n: u32) syntax.NodeSpan {
        return self.spans.nodes.items[n];
    }
    fn keyOf(self: *const Read, n: u32) []const u8 {
        return self.doc.bytes(self.node(n).keyRef()).bytes;
    }
    fn isUnder(self: *const Read, n: u32, ancestor: u32) bool {
        var at = n;
        while (at != none) : (at = self.parents[at]) if (at == ancestor) return true;
        return false;
    }
    /// The header whose section is table `n`'s, if any.
    fn header(self: *const Read, n: u32) ?syntax.Header {
        for (self.spans.headers.items) |h| if (h.node == n) return h;
        return null;
    }
};

fn readDocument(a: std.mem.Allocator, text: []const u8, options: EditOptions) Error!Read {
    var c: core.Context = .init(a, options.limits, .borrowed);
    try c.input(text.len);
    var failed: usize = 0;
    var spans: syntax.Spans = .{};
    const doc = try syntax.readSpans(&c, a, text, options.version, &failed, &spans);
    const parents = try a.alloc(u32, doc.nodes.items.len);
    @memset(parents, none);
    for (doc.nodes.items, 0..) |n, i| {
        if (n.kind != .table and n.kind != .array) continue;
        var child = n.first();
        while (child != none) : (child = doc.nodes.items[child].next) parents[child] = @intCast(i);
    }
    return .{ .doc = doc, .spans = spans, .parents = parents, .text = text };
}

/// A TOML document held as its text, edited in place.
pub const Edit = struct {
    gpa: std.mem.Allocator,
    text: edit.Text,
    options: EditOptions,

    /// `text` checked as TOML and copied: the edit's own.
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

    /// The value at `pointer` made `value`: replaced where it is written as a
    /// value, or a table remade, or a key added where there is none, or an
    /// element appended where the last token is `-`.
    pub fn set(self: *Edit, pointer: []const u8, value: anytype) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try readDocument(a, self.bytes(), self.options);
        const path = try edit.Pointer.parse(pointer);
        if (try find(a, &r, path)) |n| {
            if (inlineValue(&r, n)) {
                const s = r.span(n);
                return self.commit(a, &.{.{ .start = s.start, .end = s.end, .replacement = try self.spellInline(a, value) }});
            }
            try self.remove(pointer);
            return self.set(pointer, value);
        }
        const split = path.split() orelse return error.PathNotFound;
        const parent = (try find(a, &r, split.parent)) orelse return error.PathNotFound;
        return self.add(a, &r, split.parent, parent, split.last, null, value);
    }
    /// `value` put into the array before the element `pointer` names, or at
    /// its end for `-`; into a table, as `set` adds a key.
    pub fn insert(self: *Edit, pointer: []const u8, value: anytype) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try readDocument(a, self.bytes(), self.options);
        const split = (try edit.Pointer.parse(pointer)).split() orelse return error.PathNotFound;
        const parent = (try find(a, &r, split.parent)) orelse return error.PathNotFound;
        if (r.node(parent).kind == .table) return self.set(pointer, value);
        const at = if (split.last.isEnd()) r.node(parent).count() else split.last.index() orelse return error.PathNotFound;
        if (at > r.node(parent).count()) return error.PathNotFound;
        return self.add(a, &r, split.parent, parent, split.last, at, value);
    }
    /// The key, element or table at `pointer` taken out, with its line, or
    /// every section and dotted key a table is made of. A table that only
    /// what was taken out made (`[a.b.c]` for `a.b`, `a.b = 1` for `a`)
    /// stays, empty, as a removal leaves the rest.
    pub fn remove(self: *Edit, pointer: []const u8) Error!void {
        // On a copy: a table remade is part of the one edit.
        var work: Edit = .{ .gpa = self.gpa, .text = try edit.Text.init(self.gpa, self.bytes()), .options = self.options };
        defer work.deinit();
        const kind = try work.cut(pointer);
        try work.keep((try edit.Pointer.parse(pointer)).split().?.parent, kind);
        std.mem.swap(edit.Text, &self.text, &work.text);
    }
    /// The container `path` reached before a removal, of `kind`, made again
    /// empty where nothing defines it now, and its own the same way.
    fn keep(self: *Edit, path: edit.Pointer, kind: syntax.Kind) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try readDocument(a, self.bytes(), self.options);
        if (try find(a, &r, path) != null) return;
        const split = path.split() orelse return;
        try self.keep(split.parent, .table);
        if (kind == .array) return self.set(path.rest, [0]u8{});
        return self.set(path.rest, struct {}{});
    }
    /// The removal itself, giving the kind of container it was in.
    fn cut(self: *Edit, pointer: []const u8) Error!syntax.Kind {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try readDocument(a, self.bytes(), self.options);
        const n = (try find(a, &r, try edit.Pointer.parse(pointer))) orelse return error.PathNotFound;
        const parent = r.parents[n];
        if (parent == none) return error.PathNotFound;
        const kind = r.node(parent).kind;
        const text = self.bytes();
        var splices: std.ArrayList(edit.Splice) = .empty;
        if (inlineValue(&r, n)) {
            const s = r.span(n);
            const start = if (s.entry != none) s.entry else s.start;
            if (inlineContainer(&r, parent)) {
                try splices.append(a, memberCut(&r, parent, n, start, s.end));
            } else {
                try splices.append(a, lineCut(text, start, s.end));
            }
            try self.commit(a, splices.items);
            return kind;
        }
        if (inlineAround(&r, n)) |container| {
            // A table dotted keys make inside braces: the braces' members
            // but those under it, written again between them.
            var kept: std.ArrayList([]const u8) = .empty;
            for (r.spans.nodes.items, 0..) |s, i| {
                const at: u32 = @intCast(i);
                if (s.entry == none or (inlineAround(&r, at) orelse none) != container or r.isUnder(at, n)) continue;
                try kept.append(a, text[s.entry..s.end]);
            }
            const inner = try std.mem.join(a, ", ", kept.items);
            const c = r.span(container);
            const replacement = if (kept.items.len == 0) "{}" else try std.mem.concat(a, u8, &.{ "{ ", inner, " }" });
            try self.commit(a, &.{.{ .start = c.start, .end = c.end, .replacement = replacement }});
            return kind;
        }
        // A table: every section it or a table under it is, and every dotted
        // key under it outside them.
        for (r.spans.headers.items) |h| {
            if (h.node != 0 and r.isUnder(h.node, n)) try splices.append(a, .{ .start = h.start, .end = h.end, .replacement = "" });
        }
        for (r.spans.nodes.items, 0..) |s, i| {
            if (s.entry == none or !r.isUnder(@intCast(i), n)) continue;
            const inside = for (splices.items) |splice| {
                if (s.entry >= splice.start and s.entry < splice.end) break true;
            } else false;
            if (!inside) try splices.append(a, lineCut(text, s.entry, s.end));
        }
        if (splices.items.len == 0) return error.PathNotFound;
        try self.commit(a, splices.items);
        return kind;
    }

    /// A key `token` (or an element at `at`) added to container `parent`,
    /// which `parent_path` reaches.
    fn add(self: *Edit, a: std.mem.Allocator, r: *const Read, parent_path: edit.Pointer, parent: u32, token: edit.Token, at: ?usize, value: anytype) Error!void {
        const text = self.bytes();
        const p = r.node(parent);
        if (p.kind == .array) {
            if (p.state == .of_tables) return self.addTable(a, r, parent_path, parent, at, value);
            const index = at orelse if (token.isEnd()) p.count() else return error.PathNotFound;
            return self.addElement(a, r, parent, index, try self.spellInline(a, value));
        }
        const name = token.unescape(try a.alloc(u8, token.written.len));
        const keys = try pathKeys(a, parent_path);
        if (inlineContainer(r, parent)) {
            const member = try std.mem.concat(a, u8, &.{ try spellKey(a, name), " = ", try self.spellInline(a, value) });
            return self.addMember(a, r, parent, member);
        }
        if (p.state == .dotted) {
            // Under the dotted prefix of a key already there.
            const sibling = lastEntry(r, parent) orelse return error.PathNotFound;
            const s = r.span(sibling);
            const prefix = try dottedPrefix(a, text[s.entry..s.end], depthBetween(r, sibling, parent));
            const line = try std.mem.concat(a, u8, &.{ edit.indentation(text, s.entry), prefix, try spellKey(a, name), " = ", try self.spellInline(a, value), "\n" });
            const after = edit.lineEnd(text, s.end);
            return self.commit(a, &.{.{ .start = after, .end = after, .replacement = try newlineBefore(a, text, after, line) }});
        }
        // A table with a section of its own, or none yet.
        const written = try self.spellUnder(a, keys, name, value);
        const sections = written.len != 0 and written[0] == '[';
        if (r.header(parent)) |h| {
            if (sections) {
                // After the last section under the table, its own among them.
                var end = h.end;
                for (r.spans.headers.items) |other| if (r.isUnder(other.node, parent)) {
                    end = @max(end, other.end);
                };
                return self.commit(a, &.{.{ .start = end, .end = end, .replacement = try separated(a, text, end, written) }});
            }
            const insert_at = if (h.body_end != 0) h.body_end else h.end;
            return self.commit(a, &.{.{ .start = insert_at, .end = insert_at, .replacement = try newlineBefore(a, text, insert_at, written) }});
        }
        // A table made only on the way to others: a section of its own at the end.
        const section = if (sections) written else try std.mem.concat(a, u8, &.{ "[", try spellPath(a, keys), "]\n", written });
        return self.commit(a, &.{.{ .start = text.len, .end = text.len, .replacement = try separated(a, text, text.len, section) }});
    }
    /// A table added to an array of tables: its `[[...]]` section after the
    /// last element's, or before element `at`'s.
    fn addTable(self: *Edit, a: std.mem.Allocator, r: *const Read, parent_path: edit.Pointer, parent: u32, at: ?usize, value: anytype) Error!void {
        const text = self.bytes();
        const split = parent_path.split() orelse return error.PathNotFound;
        const keys = try pathKeys(a, split.parent);
        const name = split.last.unescape(try a.alloc(u8, split.last.written.len));
        const one = [1]@TypeOf(value){value};
        const written = try self.spellUnder(a, keys, name, @as([]const @TypeOf(value), &one));
        if (written.len == 0 or !std.mem.startsWith(u8, written, "[[")) return error.UnsupportedValue;
        var element = r.node(parent).first();
        var k: usize = 0;
        var last: u32 = none;
        while (element != none) : (element = r.node(element).next) {
            if (at != null and k == at.?) {
                const h = r.header(element) orelse return error.PathNotFound;
                return self.commit(a, &.{.{ .start = h.start, .end = h.start, .replacement = try std.mem.concat(a, u8, &.{ written, "\n" }) }});
            }
            last = element;
            k += 1;
        }
        const end = if (last != none) (r.header(last) orelse return error.PathNotFound).end else text.len;
        return self.commit(a, &.{.{ .start = end, .end = end, .replacement = try separated(a, text, end, written) }});
    }
    fn addElement(self: *Edit, a: std.mem.Allocator, r: *const Read, parent: u32, at: usize, spelled: []const u8) Error!void {
        const text = self.bytes();
        const s = r.span(parent);
        var kids: std.ArrayList(u32) = .empty;
        var child = r.node(parent).first();
        while (child != none) : (child = r.node(child).next) try kids.append(a, child);
        if (kids.items.len == 0) return self.commit(a, &.{.{ .start = s.start + 1, .end = s.start + 1, .replacement = spelled }});
        const lines = std.mem.findScalar(u8, text[s.start..r.span(kids.items[0]).start], '\n') != null;
        const indent = edit.indentation(text, r.span(kids.items[0]).start);
        if (at < kids.items.len) {
            const before = r.span(kids.items[at]).start;
            const replacement = if (lines) try std.mem.concat(a, u8, &.{ spelled, ",\n", indent }) else try std.mem.concat(a, u8, &.{ spelled, ", " });
            return self.commit(a, &.{.{ .start = before, .end = before, .replacement = replacement }});
        }
        const last_end = r.span(kids.items[kids.items.len - 1]).end;
        const replacement = if (lines) try std.mem.concat(a, u8, &.{ ",\n", indent, spelled }) else try std.mem.concat(a, u8, &.{ ", ", spelled });
        return self.commit(a, &.{.{ .start = last_end, .end = last_end, .replacement = replacement }});
    }
    fn addMember(self: *Edit, a: std.mem.Allocator, r: *const Read, parent: u32, member: []const u8) Error!void {
        const s = r.span(parent);
        const last = lastChild(r, parent);
        if (last == none) {
            // `{}`, or `{ }`: the member between the braces.
            return self.commit(a, &.{.{ .start = s.start, .end = s.end, .replacement = try std.mem.concat(a, u8, &.{ "{ ", member, " }" }) }});
        }
        const end = r.span(last).end;
        return self.commit(a, &.{.{ .start = end, .end = end, .replacement = try std.mem.concat(a, u8, &.{ ", ", member }) }});
    }

    fn spellInline(self: *Edit, a: std.mem.Allocator, value: anytype) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        try api.writeValue(&out.writer, value, .{ .limits = self.options.limits, .allocator = a });
        return out.written();
    }
    /// `name = value` as a line of the table `keys` names, or the sections
    /// `value` is under it.
    fn spellUnder(self: *Edit, a: std.mem.Allocator, keys: []const []const u8, name: []const u8, value: anytype) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        const entry = [1]core.Pair([]const u8, @TypeOf(value)){.{ .key = name, .value = value }};
        try api.write(&out.writer, core.Pairs([]const u8, @TypeOf(value)){ .items = &entry }, .{ .limits = self.options.limits, .allocator = a, .path = keys });
        const written = out.written();
        // A section starts after the line break the writer puts between sections.
        return std.mem.trimStart(u8, written, "\n");
    }
    /// The text the splices make, if it reads as TOML.
    fn commit(self: *Edit, a: std.mem.Allocator, splices: []const edit.Splice) Error!void {
        const sorted = try a.dupe(edit.Splice, splices);
        std.mem.sort(edit.Splice, sorted, {}, struct {
            fn lessThan(_: void, x: edit.Splice, y: edit.Splice) bool {
                return x.start > y.start;
            }
        }.lessThan);
        var next: []const u8 = self.bytes();
        for (sorted) |s| next = try std.mem.concat(a, u8, &.{ next[0..s.start], s.replacement, next[s.end..] });
        try check(a, next, self.options);
        try self.text.replace(self.gpa, next);
    }
};

fn check(gpa: std.mem.Allocator, text: []const u8, options: EditOptions) Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try api.parseLeaky(api.Value, arena.allocator(), text, .{ .limits = options.limits, .version = options.version });
}

/// The node `path` reaches, or null.
fn find(a: std.mem.Allocator, r: *const Read, path: edit.Pointer) Error!?u32 {
    var n: u32 = 0;
    var rest = path;
    while (rest.next()) |token| {
        const node = r.node(n);
        if (node.kind == .table) {
            const name = token.unescape(try a.alloc(u8, token.written.len));
            var child = node.first();
            n = while (child != none) : (child = r.node(child).next) {
                if (std.mem.eql(u8, r.keyOf(child), name)) break child;
            } else return null;
        } else if (node.kind == .array) {
            const index = token.index() orelse return null;
            var child = node.first();
            var k: usize = 0;
            n = while (child != none) : ({
                child = r.node(child).next;
                k += 1;
            }) {
                if (k == index) break child;
            } else return null;
        } else return null;
    }
    return n;
}

/// Whether node `n` is written as one value: after a key's `=`, or in an array.
fn inlineValue(r: *const Read, n: u32) bool {
    if (r.span(n).entry != none) return true;
    const parent = r.parents[n];
    return parent != none and r.node(parent).kind == .array and r.node(parent).state == .value;
}
/// Whether container `n` is written between its brackets.
fn inlineContainer(r: *const Read, n: u32) bool {
    const node = r.node(n);
    if (node.kind == .array) return node.state == .value;
    const s = r.span(n);
    return node.state == .closed and s.start < r.text.len and r.text[s.start] == '{';
}
fn lastChild(r: *const Read, parent: u32) u32 {
    var last: u32 = none;
    var child = r.node(parent).first();
    while (child != none) : (child = r.node(child).next) last = child;
    return last;
}
/// The last node under `table` written as `key = value`.
fn lastEntry(r: *const Read, table: u32) ?u32 {
    var best: ?u32 = null;
    for (r.spans.nodes.items, 0..) |s, i| {
        if (s.entry != none and r.isUnder(@intCast(i), table) and i != table and !sectionBetween(r, @intCast(i), table)) {
            if (best == null or s.entry > r.span(best.?).entry) best = @intCast(i);
        }
    }
    return best;
}
/// Whether a table between node `n` and `ancestor` has a section of its
/// own, which `n` is written in.
fn sectionBetween(r: *const Read, n: u32, ancestor: u32) bool {
    var at = r.parents[n];
    while (at != ancestor) : (at = r.parents[at]) if (r.header(at) != null) return true;
    return false;
}
/// The inline table node `n` is written inside, if any.
fn inlineAround(r: *const Read, n: u32) ?u32 {
    var at = r.parents[n];
    while (at != none) : (at = r.parents[at]) if (r.node(at).kind == .table and inlineContainer(r, at)) return at;
    return null;
}
fn depthBetween(r: *const Read, n: u32, ancestor: u32) usize {
    var d: usize = 0;
    var at = n;
    while (at != ancestor) : (at = r.parents[at]) d += 1;
    return d;
}

/// A member of an inline table or array cut with its comma.
fn memberCut(r: *const Read, parent: u32, n: u32, start: u32, end: u32) edit.Splice {
    const text = r.text;
    var after = end;
    while (after < text.len and (text[after] == ' ' or text[after] == '\t')) after += 1;
    if (after < text.len and text[after] == ',') {
        var stop = after + 1;
        while (stop < text.len and (text[stop] == ' ' or text[stop] == '\t')) stop += 1;
        return .{ .start = start, .end = stop, .replacement = "" };
    }
    // The last: the comma before it goes, unless it is the only one.
    var previous: u32 = none;
    var child = r.node(parent).first();
    while (child != n) : (child = r.node(child).next) previous = child;
    if (previous == none) return .{ .start = start, .end = end, .replacement = "" };
    return .{ .start = r.span(previous).end, .end = end, .replacement = "" };
}
/// A `key = value` cut with its line, where nothing else stands on it but a
/// comment.
fn lineCut(text: []const u8, start: usize, end: usize) edit.Splice {
    const line = edit.lineStart(text, start);
    var stop = end;
    while (stop < text.len and (text[stop] == ' ' or text[stop] == '\t')) stop += 1;
    if (stop < text.len and text[stop] == '#') stop = std.mem.findScalarPos(u8, text, stop, '\n') orelse text.len;
    if (stop < text.len and text[stop] == '\r') stop += 1;
    const alone = edit.blankBetween(text, line, start) and (stop == text.len or text[stop] == '\n');
    if (!alone) return .{ .start = start, .end = end, .replacement = "" };
    return .{ .start = line, .end = if (stop < text.len) stop + 1 else stop, .replacement = "" };
}
fn newlineBefore(a: std.mem.Allocator, text: []const u8, at: usize, line: []const u8) Error![]const u8 {
    if (at == 0 or text[at - 1] == '\n') return line;
    return std.mem.concat(a, u8, &.{ "\n", line });
}
/// A section placed at `at`: a blank line before it, as the writer spaces them.
fn separated(a: std.mem.Allocator, text: []const u8, at: usize, section: []const u8) Error![]const u8 {
    if (at == 0) return section;
    const before: []const u8 = if (text[at - 1] != '\n') "\n\n" else if (at >= 2 and text[at - 2] == '\n') "" else "\n";
    const after: []const u8 = if (at < text.len) "\n" else "";
    return std.mem.concat(a, u8, &.{ before, section, after });
}

/// A pointer's tokens, unescaped: a table's keys.
fn pathKeys(a: std.mem.Allocator, path: edit.Pointer) Error![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    var rest = path;
    while (rest.next()) |token| try keys.append(a, token.unescape(try a.alloc(u8, token.written.len)));
    return keys.items;
}
fn spellKey(a: std.mem.Allocator, name: []const u8) Error![]const u8 {
    if (strings.bare(name)) return name;
    var out: std.Io.Writer.Allocating = .init(a);
    _ = strings.quoted(&out.writer, name) catch return error.OutOfMemory;
    return out.written();
}
fn spellPath(a: std.mem.Allocator, keys: []const []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (keys, 0..) |k, i| {
        if (i > 0) try out.append(a, '.');
        try out.appendSlice(a, try spellKey(a, k));
    }
    return out.items;
}
/// The prefix of a dotted key `entry` (`a.b.c = 1`) without its last `drop`
/// parts, each ending in its dot, as written.
fn dottedPrefix(a: std.mem.Allocator, entry: []const u8, drop: usize) Error![]const u8 {
    var dots: std.ArrayList(usize) = .empty;
    var i: usize = 0;
    while (i < entry.len and entry[i] != '=') {
        switch (entry[i]) {
            '"' => {
                i += 1;
                while (i < entry.len and entry[i] != '"') : (i += 1) if (entry[i] == '\\') {
                    i += 1;
                };
                i += 1;
            },
            '\'' => i = (std.mem.findScalarPos(u8, entry, i + 1, '\'') orelse entry.len) + 1,
            '.' => {
                try dots.append(a, i);
                i += 1;
            },
            else => i += 1,
        }
    }
    if (drop > dots.items.len + 1 or drop == 0) return error.PathNotFound;
    if (drop == dots.items.len + 1) return "";
    const cut = dots.items[dots.items.len - drop];
    var end = cut + 1;
    while (end < entry.len and (entry[end] == ' ' or entry[end] == '\t')) end += 1;
    return entry[0..end];
}
