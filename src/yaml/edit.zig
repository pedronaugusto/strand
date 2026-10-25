//! YAML edited in place: a value set, a key added, an entry inserted, a key
//! or an entry removed, each found by JSON Pointer through the reader every
//! YAML parse uses (recording where each node is written) and spelled by
//! YAML's own writer, so every byte the change does not replace stays as it
//! was: comments, blank lines, key order, quoting, anchors elsewhere.
//!
//! A value is replaced where it is written: in flow style inside a flow
//! collection or in place of one, else in block style, a collection written
//! after its key on lines of its own at two more than the key's column, or
//! on its entry's line after `- `. A key added to a block mapping goes on a
//! line after its last member's, at the column its members start at; an
//! entry added to a block sequence likewise, or before the entry it is
//! inserted at; in a flow collection both go between its brackets, after a
//! comma. Removing a member takes its lines (a comment on the last of them
//! too); removing a collection's only member leaves it empty (`{}`, `[]`).
//! A node replaced takes its anchor and tag with it: an alias left naming no
//! anchor is refused. Each edit is read back before it is kept: a change
//! that would leave text the reader refuses is an error, and the text is as
//! it was. The stream holds one document, as `yaml.parse` reads one.
const std = @import("std");
const core = @import("../core.zig");
const edit = @import("../core/edit.zig");
const document = @import("document.zig");
const api = @import("api.zig");

pub const Error = edit.Error;

pub const EditOptions = struct {
    limits: core.Limits = .{},
};

/// The stream read, with where each node is written.
const Read = struct {
    doc: document.Document,
    spans: document.Spans,
    /// Each node's collection; the stream's own is 0, which has none.
    parents: []u32,
    text: []const u8,

    fn node(self: *const Read, n: u32) document.Node {
        return self.doc.nodes.items[n];
    }
    fn span(self: *const Read, n: u32) document.NodeSpan {
        return self.spans.nodes.items[n];
    }
    /// The nodes of collection `n`: keys and values in turn in a mapping.
    fn children(self: *const Read, a: std.mem.Allocator, n: u32) Error![]u32 {
        var list: std.ArrayList(u32) = .empty;
        var i = n + 1;
        while (i < self.node(n).end) : (i = self.node(i).end) try list.append(a, i);
        return list.items;
    }
    /// The members of collection `n`: a mapping's key and value, or an entry.
    fn members(self: *const Read, a: std.mem.Allocator, n: u32) Error![]Member {
        const kids = try self.children(a, n);
        if (self.node(n).kind != .mapping) {
            const list = try a.alloc(Member, kids.len);
            for (kids, list) |k, *m| m.* = .{ .first = k, .last = k };
            return list;
        }
        const list = try a.alloc(Member, kids.len / 2);
        for (list, 0..) |*m, i| m.* = .{ .first = kids[2 * i], .last = kids[2 * i + 1] };
        return list;
    }
    fn start(self: *const Read, m: Member) u32 {
        return self.span(m.first).start;
    }
    /// Where a block collection's member starts: its `-` or `?`, or its key.
    fn entry(self: *const Read, m: Member) u32 {
        return self.span(m.first).entry;
    }
    fn end(self: *const Read, m: Member) u32 {
        return self.span(m.last).end;
    }
};
/// A member of a collection: its first node (a key, or the entry) and its last.
const Member = struct { first: u32, last: u32 };

fn readStream(a: std.mem.Allocator, text: []const u8, options: EditOptions) Error!Read {
    var c: core.Context = .init(a, options.limits, .borrowed);
    try c.input(text.len);
    var failed: usize = 0;
    var spans: document.Spans = .{};
    const doc = try document.readSpans(&c, a, text, &failed, &spans);
    const parents = try a.alloc(u32, doc.nodes.items.len);
    @memset(parents, 0);
    for (doc.nodes.items, 0..) |n, i| {
        if (n.kind != .sequence and n.kind != .mapping) continue;
        var child: u32 = @intCast(i + 1);
        while (child < n.end) : (child = doc.nodes.items[child].end) parents[child] = @intCast(i);
    }
    return .{ .doc = doc, .spans = spans, .parents = parents, .text = text };
}

/// A YAML document held as its text, edited in place.
pub const Edit = struct {
    gpa: std.mem.Allocator,
    text: edit.Text,
    options: EditOptions,

    /// `text` checked as a YAML stream of at most one document and copied:
    /// the edit's own.
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

    /// The value at `pointer` made `value`: replaced where it is written, or
    /// a key added where there is none, or an entry appended where the last
    /// token is `-`.
    pub fn set(self: *Edit, pointer: []const u8, value: anytype) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try readStream(a, self.bytes(), self.options);
        const path = try edit.Pointer.parse(pointer);
        const text = self.bytes();
        if (r.node(0).count() == 0) {
            // No document: the value is one, after what comments there are.
            if (!path.done()) return error.PathNotFound;
            const spelled = try self.spell(a, value, false);
            return self.commit(a, &.{.{ .start = text.len, .end = text.len, .replacement = try newlineBefore(a, text, text.len, spelled) }});
        }
        if (try find(a, &r, path)) |n| {
            const parent = r.parents[n];
            const in_flow = parent != 0 and r.span(parent).flow;
            const spelled = try self.spell(a, value, r.span(n).flow or in_flow);
            if (try emptyValue(a, &r, n, spelled)) |splice| return self.commit(a, &.{splice});
            if (in_flow) {
                // An empty value right after its `:` is given a space.
                const s = r.span(n);
                const gap: []const u8 = if (s.start > 0 and text[s.start - 1] == ':') " " else "";
                return self.commit(a, &.{.{ .start = s.start, .end = s.end, .replacement = try std.mem.concat(a, u8, &.{ gap, trimLine(spelled) }) }});
            }
            return self.commit(a, &.{try placed(a, &r, n, spelled)});
        }
        const split = path.split() orelse return error.PathNotFound;
        const parent = (try find(a, &r, split.parent)) orelse return error.PathNotFound;
        return self.add(a, &r, parent, split.last, null, value);
    }
    /// `value` put into the sequence before the entry `pointer` names, or at
    /// its end for `-`; into a mapping, as `set` adds a key.
    pub fn insert(self: *Edit, pointer: []const u8, value: anytype) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try readStream(a, self.bytes(), self.options);
        if (r.node(0).count() == 0) return error.PathNotFound;
        const split = (try edit.Pointer.parse(pointer)).split() orelse return error.PathNotFound;
        const parent = (try find(a, &r, split.parent)) orelse return error.PathNotFound;
        if (r.node(parent).kind != .sequence) return self.set(pointer, value);
        const count = r.node(parent).count();
        const at = if (split.last.isEnd()) count else split.last.index() orelse return error.PathNotFound;
        if (at > count) return error.PathNotFound;
        return self.add(a, &r, parent, split.last, at, value);
    }
    /// The key or entry at `pointer` taken out, with its lines.
    pub fn remove(self: *Edit, pointer: []const u8) Error!void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try readStream(a, self.bytes(), self.options);
        if (r.node(0).count() == 0) return error.PathNotFound;
        const n = (try find(a, &r, try edit.Pointer.parse(pointer))) orelse return error.PathNotFound;
        const parent = r.parents[n];
        if (parent == 0) return error.PathNotFound;
        const members = try r.members(a, parent);
        const i = for (members, 0..) |m, k| {
            if (m.last == n) break k;
        } else return error.PathNotFound;
        if (r.span(parent).flow) {
            // A pair in a flow sequence (`[a: b]`) is a mapping left empty.
            if (members.len == 1 and r.node(parent).kind == .mapping and !braced(&r, parent)) {
                const s = r.span(parent);
                return self.commit(a, &.{.{ .start = s.start, .end = s.end, .replacement = "{}" }});
            }
            var splices: std.ArrayList(edit.Splice) = .empty;
            try flowCut(a, &r, members, i, &splices);
            return self.commit(a, splices.items);
        }
        if (members.len == 1) {
            // A block collection's only member: the collection made empty.
            const empty = if (r.node(parent).kind == .mapping) "{}\n" else "[]\n";
            return self.commit(a, &.{try placed(a, &r, parent, empty)});
        }
        return self.commit(a, &.{blockCut(&r, members, i)});
    }

    /// A key `token` (or an entry at `at`) added to collection `parent`.
    fn add(self: *Edit, a: std.mem.Allocator, r: *const Read, parent: u32, token: edit.Token, at: ?usize, value: anytype) Error!void {
        const p = r.node(parent);
        const members = try r.members(a, parent);
        const flow = r.span(parent).flow;
        const spelled = switch (p.kind) {
            .sequence => if (flow) trimLine(try self.spell(a, value, true)) else try self.spell(a, @as([]const @TypeOf(value), &.{value}), false),
            .mapping => try self.spellPair(a, token.unescape(try a.alloc(u8, token.written.len)), value, flow),
            else => return error.PathNotFound,
        };
        const index = if (p.kind == .mapping) members.len else at orelse if (token.isEnd()) members.len else return error.PathNotFound;
        if (flow) return self.commit(a, &.{try flowAdd(a, r, parent, members, index, spelled)});
        // A block collection has a member: an empty one is in flow style.
        const text = self.bytes();
        const indent = try spaces(a, column(text, r.entry(members[0])));
        const lines = try edit.indented(a, spelled, indent);
        if (index < members.len) {
            const before = r.entry(members[index]);
            return self.commit(a, &.{.{ .start = before, .end = before, .replacement = try std.mem.concat(a, u8, &.{ lines, indent }) }});
        }
        const after = edit.lineEnd(text, r.end(members[members.len - 1]));
        return self.commit(a, &.{.{ .start = after, .end = after, .replacement = try newlineBefore(a, text, after, try std.mem.concat(a, u8, &.{ indent, lines })) }});
    }

    /// `value` as a document, in flow style where `flow` says.
    fn spell(self: *Edit, a: std.mem.Allocator, value: anytype, flow: bool) Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        try api.write(&out.writer, value, .{ .limits = self.options.limits, .allocator = a, .flow = flow });
        return out.written();
    }
    /// `name: value` as a block mapping's member, or a flow mapping's.
    fn spellPair(self: *Edit, a: std.mem.Allocator, name: []const u8, value: anytype, flow: bool) Error![]const u8 {
        const entry = [1]core.Pair([]const u8, @TypeOf(value)){.{ .key = name, .value = value }};
        const written = try self.spell(a, core.Pairs([]const u8, @TypeOf(value)){ .items = &entry }, flow);
        if (!flow) return written;
        // `{name: value}`: what is between the braces.
        const line = trimLine(written);
        return line[1 .. line.len - 1];
    }
    /// The text the splices make, if it reads as YAML.
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
    _ = try api.parseLeaky(api.Value, arena.allocator(), text, .{ .limits = options.limits });
}

/// The node `path` reaches in the document, or null. An alias is a value
/// that may be replaced or removed, never gone through.
fn find(a: std.mem.Allocator, r: *const Read, path: edit.Pointer) Error!?u32 {
    var n: u32 = 1;
    var rest = path;
    while (rest.next()) |token| {
        const node = r.node(n);
        const kids = try r.children(a, n);
        switch (node.kind) {
            .mapping => {
                const name = token.unescape(try a.alloc(u8, token.written.len));
                var i: usize = 0;
                n = while (i < kids.len) : (i += 2) {
                    const key = r.node(r.doc.resolved(kids[i]));
                    if (key.kind == .scalar and std.mem.eql(u8, r.doc.bytes(key).bytes, name)) break kids[i + 1];
                } else return null;
            },
            .sequence => {
                const index = token.index() orelse return null;
                if (index >= kids.len) return null;
                n = kids[index];
            },
            .scalar, .alias => return null,
        }
    }
    return n;
}

/// Node `n` of a block collection, or the document's, replaced by `spelled`
/// (a document, its line break last): on its line where it is one line,
/// else a block at its column, or two past its key's.
fn placed(a: std.mem.Allocator, r: *const Read, n: u32, spelled: []const u8) Error!edit.Splice {
    const text = r.text;
    const s = r.span(n);
    const body = trimLine(spelled);
    const one_line = std.mem.findScalar(u8, body, '\n') == null;
    const parent = r.parents[n];
    if (parent == 0) {
        if (one_line or edit.blankBetween(text, edit.lineStart(text, s.start), s.start)) return .{ .start = s.start, .end = s.end, .replacement = body };
        // After `---` on its line: a block starts on the next.
        return .{ .start = s.start, .end = s.end, .replacement = try std.mem.concat(a, u8, &.{ "\n", body }) };
    }
    // An empty node right after its `-` or `:` is given a space.
    const gap: []const u8 = if (s.start > 0 and text[s.start - 1] != ' ' and text[s.start - 1] != '\n') " " else "";
    if (r.node(parent).kind == .mapping) {
        const k = keyBefore(r, parent, n);
        if (colonAfter(text, r.span(k).end)) |colon| {
            const same_line = std.mem.findScalar(u8, text[colon..s.start], '\n') == null;
            const key_column = column(text, r.span(k).entry);
            // On a line after its key's, deeper: replaced there where
            // comments stand before it, to keep them.
            const deeper = !same_line and column(text, s.start) > key_column;
            const commented = std.mem.findScalar(u8, text[colon..s.start], '#') != null;
            if (one_line) {
                if (same_line or (deeper and commented)) return .{ .start = s.start, .end = s.end, .replacement = try std.mem.concat(a, u8, &.{ gap, body }) };
                return .{ .start = colon + 1, .end = s.end, .replacement = try std.mem.concat(a, u8, &.{ " ", body }) };
            }
            if (deeper) {
                return .{ .start = s.start, .end = s.end, .replacement = try edit.indented(a, body, try spaces(a, column(text, s.start))) };
            }
            const indent = try spaces(a, key_column + 2);
            return .{ .start = colon + 1, .end = s.end, .replacement = try std.mem.concat(a, u8, &.{ "\n", indent, try edit.indented(a, body, indent) }) };
        }
    }
    // An entry, or the value of an explicit key: in place at its column.
    if (one_line) return .{ .start = s.start, .end = s.end, .replacement = try std.mem.concat(a, u8, &.{ gap, body }) };
    const indent = try spaces(a, column(text, s.start) + gap.len);
    return .{ .start = s.start, .end = s.end, .replacement = try std.mem.concat(a, u8, &.{ gap, try edit.indented(a, body, indent) }) };
}
/// A mapping's value left empty with no `:` written for it (`{a, b: 1}`,
/// `? a` alone), made `spelled`: `: value` after its key, on the key's line
/// in a flow mapping, on a line of its own after an explicit key.
fn emptyValue(a: std.mem.Allocator, r: *const Read, n: u32, spelled: []const u8) Error!?edit.Splice {
    const text = r.text;
    const parent = r.parents[n];
    if (parent == 0 or r.node(parent).kind != .mapping) return null;
    const node = r.node(n);
    const s = r.span(n);
    if (node.kind != .scalar or node.style != .plain or node.data.len != 0 or node.tag != .none or s.start != s.end) return null;
    const k = keyBefore(r, parent, n);
    const key_end = r.span(k).end;
    if (colonAfter(text, key_end) != null or (s.start > 0 and text[s.start - 1] == ':')) return null;
    const body = trimLine(spelled);
    if (r.span(parent).flow) return .{ .start = key_end, .end = key_end, .replacement = try std.mem.concat(a, u8, &.{ ": ", body }) };
    const key_column = column(text, r.span(k).entry);
    const after = edit.lineEnd(text, key_end);
    const line = try std.mem.concat(a, u8, &.{ try spaces(a, key_column), ": ", try edit.indented(a, body, try spaces(a, key_column + 2)), "\n" });
    return .{ .start = after, .end = after, .replacement = try newlineBefore(a, text, after, line) };
}
/// Whether flow mapping `n` is written in braces: not a pair in a flow sequence.
fn braced(r: *const Read, n: u32) bool {
    const s = r.span(n);
    return s.end > s.start and r.text[s.end - 1] == '}';
}
/// Past the white space, line breaks and comments from `at`.
fn skipGap(text: []const u8, at: usize) usize {
    var i = at;
    while (i < text.len) switch (text[i]) {
        ' ', '\t', '\r', '\n' => i += 1,
        '#' => i = edit.lineEnd(text, i),
        else => break,
    };
    return i;
}
/// The key value `n` of `mapping` is after.
fn keyBefore(r: *const Read, mapping: u32, n: u32) u32 {
    var key = mapping + 1;
    while (r.node(key).end != n) key = r.node(r.node(key).end).end;
    return key;
}
/// The `:` after an implicit key ending at `at`, on its line.
fn colonAfter(text: []const u8, at: usize) ?usize {
    var i = at;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return if (i < text.len and text[i] == ':') i else null;
}

/// A member added to a flow collection at `index`: after a comma, on a line
/// of its own where its members stand on lines of their own.
fn flowAdd(a: std.mem.Allocator, r: *const Read, parent: u32, members: []const Member, index: usize, spelled: []const u8) Error!edit.Splice {
    const text = r.text;
    const s = r.span(parent);
    if (r.node(parent).kind == .mapping and !braced(r, parent)) {
        // A pair in a flow sequence: braces make it a mapping of two.
        return .{ .start = s.start, .end = s.end, .replacement = try std.mem.concat(a, u8, &.{ "{", text[s.start..s.end], ", ", spelled, "}" }) };
    }
    if (members.len == 0) {
        // `{}`, `[ ]`: the member between the brackets.
        var open = s.end - 1;
        while (open > s.start and text[open - 1] != '[' and text[open - 1] != '{') open -= 1;
        return .{ .start = open, .end = s.end - 1, .replacement = spelled };
    }
    const lines = std.mem.findScalar(u8, text[s.start..r.start(members[0])], '\n') != null;
    const indent = edit.indentation(text, r.start(members[0]));
    if (index < members.len) {
        const before = r.start(members[index]);
        const replacement = if (lines) try std.mem.concat(a, u8, &.{ spelled, ",\n", indent }) else try std.mem.concat(a, u8, &.{ spelled, ", " });
        return .{ .start = before, .end = before, .replacement = replacement };
    }
    const last_end = r.end(members[members.len - 1]);
    const replacement = if (lines) try std.mem.concat(a, u8, &.{ ",\n", indent, spelled }) else try std.mem.concat(a, u8, &.{ ", ", spelled });
    return .{ .start = last_end, .end = last_end, .replacement = replacement };
}
/// Member `i` of a flow collection cut with its comma, and its line where
/// it stands alone on one; a comment between it and its comma stays.
fn flowCut(a: std.mem.Allocator, r: *const Read, members: []const Member, i: usize, splices: *std.ArrayList(edit.Splice)) Error!void {
    const text = r.text;
    const start = r.entry(members[i]);
    const end = r.end(members[i]);
    const comma = skipGap(text, end);
    if (comma < text.len and text[comma] == ',') {
        var stop = comma + 1;
        while (stop < text.len and (text[stop] == ' ' or text[stop] == '\t')) stop += 1;
        if (!edit.blankBetween(text, end, comma)) {
            try splices.append(a, .{ .start = start, .end = end, .replacement = "" });
            return splices.append(a, .{ .start = comma, .end = stop, .replacement = "" });
        }
        const line = edit.lineStart(text, start);
        if (stop < text.len and text[stop] == '\n' and edit.blankBetween(text, line, start)) return splices.append(a, .{ .start = line, .end = stop + 1, .replacement = "" });
        return splices.append(a, .{ .start = start, .end = stop, .replacement = "" });
    }
    // The last: the comma before it goes, unless it is the only one.
    if (i == 0) return splices.append(a, .{ .start = start, .end = end, .replacement = "" });
    try splices.append(a, .{ .start = r.end(members[i - 1]), .end = end, .replacement = "" });
}
/// Member `i` of a block collection cut with its lines, where nothing else
/// stands on the first before it; else up to the next member.
fn blockCut(r: *const Read, members: []const Member, i: usize) edit.Splice {
    const text = r.text;
    const start = r.entry(members[i]);
    const end = r.end(members[i]);
    const line = edit.lineStart(text, start);
    if (edit.blankBetween(text, line, start)) {
        var stop: usize = end;
        while (stop < text.len and (text[stop] == ' ' or text[stop] == '\t')) stop += 1;
        if (stop < text.len and text[stop] == '#') stop = std.mem.findScalarPos(u8, text, stop, '\n') orelse text.len;
        if (stop < text.len and text[stop] == '\r') stop += 1;
        if (stop == text.len or text[stop] == '\n') return .{ .start = line, .end = @min(stop + 1, text.len), .replacement = "" };
    }
    // After `- ` on its line (`- a: 1`): the next member takes its place.
    if (i + 1 < members.len) return .{ .start = start, .end = r.entry(members[i + 1]), .replacement = "" };
    return .{ .start = r.end(members[i - 1]), .end = end, .replacement = "" };
}

/// A document's one line, or its block, without the line break that ends it.
fn trimLine(spelled: []const u8) []const u8 {
    return std.mem.trimEnd(u8, spelled, "\n");
}
fn column(text: []const u8, at: usize) usize {
    return at - edit.lineStart(text, at);
}
fn spaces(a: std.mem.Allocator, n: usize) Error![]const u8 {
    const s = try a.alloc(u8, n);
    @memset(s, ' ');
    return s;
}
fn newlineBefore(a: std.mem.Allocator, text: []const u8, at: usize, line: []const u8) Error![]const u8 {
    if (at == 0 or text[at - 1] == '\n') return line;
    return std.mem.concat(a, u8, &.{ "\n", line });
}
