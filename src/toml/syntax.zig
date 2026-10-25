//! A TOML document read into its tables. A document's tables are not written
//! in one piece (`[a]`, `[b]`, `[a.c]`; dotted keys; arrays of tables
//! extended by their headers), so it is read whole before the first value is
//! handed on, into one array of nodes linked into a tree (a container's first
//! and last member, each node's next sibling), every rule about defining a
//! table checked as it is read, and every key found through one index. The
//! nodes, the index and every decoded string live in working storage the
//! operation is charged for and gives back when the parse ends; what the
//! result keeps is copied out of it by the core.
const std = @import("std");
const limit = @import("../core/limit.zig");
const core = @import("../core.zig");
const text = @import("text.zig");
const number = @import("number.zig");
const temporal = @import("temporal.zig");

pub const Error = core.DecodeError;

/// Which TOML a document is read as.
pub const Version = enum {
    /// TOML 1.0.0: inline tables on one line, seconds always written, no
    /// `\e` or `\xHH`.
    v1_0,
    /// TOML 1.1.0.
    v1_1,
};

/// No node.
pub const none = std.math.maxInt(u32);

pub const Kind = enum(u8) {
    table,
    array,
    string,
    integer,
    float,
    true,
    false,
    offset_date_time,
    local_date_time,
    local_date,
    local_time,
};
/// How a table came to be, and so what may still define it or add to it.
pub const State = enum(u8) {
    /// Made on the way to a header's table, or to a dotted key's; a header
    /// may still define it.
    implicit,
    /// Defined by its header.
    header,
    /// Defined by dotted keys: a header may add tables under it, not define it.
    dotted,
    /// An inline table, or a table inside one: closed once its braces are.
    closed,
    /// An array made by `[[...]]`, which each such header extends.
    of_tables,
    /// An array value, or anything that is no container.
    value,
};
/// Bytes of the input, or of the decoded strings.
pub const Ref = struct {
    start: u32 = 0,
    len: u32 = 0,
    decoded: bool = false,
};
/// A span of 32-bit positions.
const Span32 = struct { start: u32 = 0, len: u32 = 0 };
/// A key, a value, a table or an array: 28 bytes.
pub const Node = struct {
    kind: Kind,
    state: State = .value,
    key_decoded: bool = false,
    bytes_decoded: bool = false,
    /// The key it has in its table; none in an array.
    key: Span32 = .{},
    /// A scalar's spelling (a string's value, a number's normal spelling, a
    /// date's or a time's text); a container's first member and how many.
    data: Span32 = .{},
    /// The next member of the container it is in.
    next: u32 = none,
    /// Where it was written, for a failure's place.
    at: u32,

    pub fn keyRef(self: Node) Ref {
        return .{ .start = self.key.start, .len = self.key.len, .decoded = self.key_decoded };
    }
    pub fn bytesRef(self: Node) Ref {
        return .{ .start = self.data.start, .len = self.data.len, .decoded = self.bytes_decoded };
    }
    pub fn first(self: Node) u32 {
        return if (self.data.len == 0) none else self.data.start;
    }
    pub fn count(self: Node) u32 {
        return self.data.len;
    }
    fn scalar(kind: Kind, ref: Ref, at: u32) Node {
        return .{ .kind = kind, .bytes_decoded = ref.decoded, .data = .{ .start = ref.start, .len = ref.len }, .at = at };
    }
};

/// A document read: its nodes, the root first, and the bytes they refer to.
pub const Document = struct {
    input: []const u8,
    nodes: std.ArrayList(Node),
    decoded: std.ArrayList(u8),
    pub fn bytes(self: *const Document, ref: Ref) core.Span {
        const source = if (ref.decoded) self.decoded.items else self.input;
        return .{ .bytes = source[ref.start..][0..ref.len], .lifetime = if (ref.decoded) .transient else .borrowed };
    }
    /// Gives back the document's working storage.
    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.decoded.deinit(allocator);
    }
};

const Segment = struct { key: Ref, at: u32 };

/// What the index looks at: the nodes so far, their tables and their bytes.
pub const View = struct {
    nodes: []const Node,
    parents: []const u32,
    input: []const u8,
    decoded: []const u8,
    fn key(self: View, n: u32) []const u8 {
        const node = self.nodes[n];
        const source = if (node.key_decoded) self.decoded else self.input;
        return source[node.key.start..][0..node.key.len];
    }
};
/// Each table's keys, as the positions of the nodes under them; a node's
/// table and key are its identity.
pub const IndexContext = struct {
    view: View,
    pub fn hash(self: IndexContext, n: u32) u64 {
        return std.hash.Wyhash.hash(self.view.parents[n], self.view.key(n));
    }
    pub fn eql(self: IndexContext, a: u32, b: u32) bool {
        return self.view.parents[a] == self.view.parents[b] and std.mem.eql(u8, self.view.key(a), self.view.key(b));
    }
};
/// A key looked for in a table: the table's position and the key.
pub const Lookup = struct { table: u32, key: []const u8 };
pub const LookupContext = struct {
    view: View,
    pub fn hash(_: LookupContext, lookup: Lookup) u64 {
        return std.hash.Wyhash.hash(lookup.table, lookup.key);
    }
    pub fn eql(self: LookupContext, lookup: Lookup, n: u32) bool {
        return self.view.parents[n] == lookup.table and std.mem.eql(u8, self.view.key(n), lookup.key);
    }
};

/// Where a document's parts are written, for an editor: each node's value
/// and key, each header's section. Recorded by `readSpans` alone.
pub const Spans = struct {
    nodes: std.ArrayList(NodeSpan) = .empty,
    headers: std.ArrayList(Header) = .empty,
    pub fn deinit(self: *Spans, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.headers.deinit(allocator);
    }
};
/// A node's value, from its first byte to past its last, and where the key
/// of its `key = value` starts (`none` for an array's element or a table
/// made by a header or on the way to one).
pub const NodeSpan = struct { start: u32, end: u32, entry: u32 = none };
/// A header's section: the line it starts on, the end of its last
/// `key = value` line (its header line's end when it has none), and where
/// the next header's line starts. The root's is the first, from 0.
pub const Header = struct { node: u32, start: u32, body_end: u32, end: u32 };

fn ReaderOf(comptime recording: bool) type {
    return struct {
        const Reader = @This();
        c: *core.Context,
        input: []const u8,
        at: usize = 0,
        version: Version,
        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node) = .empty,
        /// Each node's container, while the document is read: a key is found by
        /// its table and its name, and a header's depth by its table's line.
        parents: std.ArrayList(u32) = .empty,
        /// Each container's last member, while the document is read.
        lasts: std.ArrayList(u32) = .empty,
        index: std.HashMapUnmanaged(u32, void, IndexContext, std.hash_map.default_max_load_percentage) = .empty,
        decoded: std.ArrayList(u8) = .empty,
        segments: std.ArrayList(Segment) = .empty,
        spans: if (recording) *Spans else void,

        fn fail(self: *Reader, err: anyerror) Error {
            return switch (err) {
                error.OutOfMemory => if (self.c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
                error.AllocationLimit => error.AllocationLimit,
                else => error.SyntaxError,
            };
        }

        fn view(self: *const Reader) View {
            return .{ .nodes = self.nodes.items, .parents = self.parents.items, .input = self.input, .decoded = self.decoded.items };
        }
        fn keyBytes(self: *const Reader, ref: Ref) []const u8 {
            const source = if (ref.decoded) self.decoded.items else self.input;
            return source[ref.start..][0..ref.len];
        }
        fn here(self: *const Reader) u32 {
            return @intCast(self.at); // safe: the input is held below 4 GiB when the read starts.
        }

        /// A new node, its place in the array.
        fn node(self: *Reader, n: Node, depth: usize) Error!u32 {
            if ((n.kind == .table or n.kind == .array) and depth >= self.c.limits.depth) return error.DepthLimit;
            const position = std.math.cast(u32, self.nodes.items.len) orelse return error.ItemLimit;
            if (position == none) return error.ItemLimit;
            self.nodes.append(self.allocator, n) catch |err| return self.fail(err);
            self.parents.append(self.allocator, none) catch |err| return self.fail(err);
            self.lasts.append(self.allocator, none) catch |err| return self.fail(err);
            if (recording) self.spans.nodes.append(self.allocator, .{ .start = n.at, .end = n.at }) catch |err| return self.fail(err);
            return position;
        }
        /// Links `child` at the end of `container`'s members.
        fn link(self: *Reader, container: u32, child: u32) Error!void {
            const c = &self.nodes.items[container];
            if (c.data.len >= self.c.limits.container_items or c.data.len == none) return error.ItemLimit;
            const last = self.lasts.items[container];
            if (last == none) c.data.start = child else self.nodes.items[last].next = child;
            self.lasts.items[container] = child;
            c.data.len += 1;
            self.parents.items[child] = container;
        }
        /// The node under `name` in `table`, if there is one.
        fn find(self: *Reader, table: u32, name: []const u8) Error!?u32 {
            try self.c.chargeWork(name.len + 1);
            return self.index.getKeyAdapted(Lookup{ .table = table, .key = name }, LookupContext{ .view = self.view() });
        }
        /// Adds `child` to `table` under `segment`, whose key the table does not have.
        fn add(self: *Reader, table: u32, segment: Segment, child: u32) Error!void {
            self.nodes.items[child].key = .{ .start = segment.key.start, .len = segment.key.len };
            self.nodes.items[child].key_decoded = segment.key.decoded;
            try self.link(table, child);
            const slot = self.index.getOrPutContextAdapted(self.allocator, Lookup{ .table = table, .key = self.keyBytes(segment.key) }, LookupContext{ .view = self.view() }, IndexContext{ .view = self.view() }) catch |err| return self.fail(err);
            std.debug.assert(!slot.found_existing);
            slot.key_ptr.* = child;
        }
        /// How many containers lie above `table`.
        fn depthOf(self: *const Reader, table: u32) usize {
            var depth: usize = 0;
            var at = table;
            while (self.parents.items[at] != none) : (at = self.parents.items[at]) depth += 1;
            return depth;
        }

        // Layout: whitespace, comments, line ends.

        fn whitespace(self: *Reader) void {
            while (self.at < self.input.len and (self.input[self.at] == ' ' or self.input[self.at] == '\t')) self.at += 1;
        }
        /// A comment, if one starts here, up to its line's end.
        fn comment(self: *Reader) Error!void {
            if (self.at >= self.input.len or self.input[self.at] != '#') return;
            self.at += 1;
            while (self.at < self.input.len) : (self.at += 1) {
                const byte = self.input[self.at];
                if (byte == '\n' or (byte == '\r' and self.at + 1 < self.input.len and self.input[self.at + 1] == '\n')) return;
                if (!text.ordinary(byte)) return error.SyntaxError;
            }
        }
        /// A line end here: whether one was taken.
        fn newline(self: *Reader) bool {
            if (self.at < self.input.len and self.input[self.at] == '\n') {
                self.at += 1;
                return true;
            }
            if (self.at + 1 < self.input.len and self.input[self.at] == '\r' and self.input[self.at + 1] == '\n') {
                self.at += 2;
                return true;
            }
            return false;
        }
        /// Whitespace, then a comment, then the line's end or the input's.
        fn endOfLine(self: *Reader) Error!void {
            self.whitespace();
            try self.comment();
            if (self.at == self.input.len) return;
            if (!self.newline()) return error.SyntaxError;
        }
        /// Whitespace, comments and line ends, as arrays (and TOML 1.1's inline
        /// tables) allow between their members.
        fn blank(self: *Reader) Error!void {
            while (true) {
                self.whitespace();
                try self.comment();
                if (!self.newline()) return;
            }
        }

        // Keys.

        /// A key, its dotted parts into `segments`.
        fn key(self: *Reader) Error!void {
            self.segments.clearRetainingCapacity();
            while (true) {
                self.whitespace();
                const segment = try self.simpleKey();
                self.segments.append(self.allocator, segment) catch |err| return self.fail(err);
                self.whitespace();
                if (self.at >= self.input.len or self.input[self.at] != '.') return;
                self.at += 1;
            }
        }
        fn simpleKey(self: *Reader) Error!Segment {
            const start = self.here();
            if (self.at >= self.input.len) return error.SyntaxError;
            const byte = self.input[self.at];
            if (byte == '"' or byte == '\'') {
                const kind = text.kindAt(self.input, self.at);
                // A multiline string is no key.
                if (kind == .multiline_basic or kind == .multiline_literal) return error.SyntaxError;
                const ref = try self.string(kind);
                try self.c.span(ref.len, true);
                return .{ .key = ref, .at = start };
            }
            while (self.at < self.input.len and (std.ascii.isAlphanumeric(self.input[self.at]) or self.input[self.at] == '_' or self.input[self.at] == '-')) self.at += 1;
            if (self.at == start) return error.SyntaxError;
            try self.c.span(self.at - start, true);
            return .{ .key = .{ .start = start, .len = self.here() - start }, .at = start };
        }

        /// The string here, of `kind`: its bytes in the input where its value is
        /// those bytes, decoded where it is not.
        fn string(self: *Reader, kind: text.Kind) Error!Ref {
            const scanned = try text.scan(self.input, self.at, kind, self.version == .v1_1);
            self.at = scanned.end;
            if (scanned.plain) return .{ .start = @intCast(scanned.content.ptr - self.input.ptr), .len = @intCast(scanned.content.len) }; // safe: a span of the input, below 4 GiB.
            try self.c.span(scanned.len, false);
            return self.decode(scanned.len, .{ .string = .{ .scanned = scanned, .kind = kind } });
        }
        const Decoding = union(enum) { string: struct { scanned: text.Scanned, kind: text.Kind }, number: []const u8 };
        /// `len` bytes onto the decoded strings, made by `what`.
        fn decode(self: *Reader, len: usize, what: Decoding) Error!Ref {
            const start = std.math.cast(u32, self.decoded.items.len) orelse return error.AllocationLimit;
            const end = std.math.cast(u32, self.decoded.items.len + len) orelse return error.AllocationLimit;
            const out = self.decoded.addManyAsSlice(self.allocator, len) catch |err| return self.fail(err);
            switch (what) {
                .string => |s| text.decode(s.scanned, s.kind, out),
                .number => |token| number.normalize(token, out),
            }
            return .{ .start = start, .len = end - start, .decoded = true };
        }

        // Tables.

        /// Under `from`, the table a header's or a dotted key's next part names,
        /// made where there is none. A header passes through any table but an
        /// inline one, and into the last table of an array of tables; a dotted
        /// key passes only through what dotted keys made.
        fn descend(self: *Reader, from: u32, segment: Segment, comptime by_header: bool, depth: usize) Error!u32 {
            if (try self.find(from, self.keyBytes(segment.key))) |found| {
                const n = self.nodes.items[found];
                switch (n.kind) {
                    .table => {
                        if (by_header and n.state != .closed) return found;
                        if (!by_header and n.state == .dotted) return found;
                    },
                    .array => if (by_header and n.state == .of_tables) return self.lasts.items[found],
                    else => {},
                }
                return error.SyntaxError;
            }
            const made = try self.node(.{ .kind = .table, .state = if (by_header) .implicit else .dotted, .at = segment.at }, depth);
            try self.add(from, segment, made);
            return made;
        }

        /// `[a.b.c]` or `[[a.b.c]]`: the table it defines.
        fn header(self: *Reader, root: u32, comptime array_header: bool) Error!u32 {
            const segments = self.segments.items;
            var t = root;
            for (segments[0 .. segments.len - 1]) |s| t = try self.descend(t, s, true, self.depthOf(t) + 1);
            const last = segments[segments.len - 1];
            const depth = self.depthOf(t) + 1;
            const found = try self.find(t, self.keyBytes(last.key));
            if (!array_header) {
                if (found) |existing| {
                    // Only a table made on the way to another is defined later.
                    const n = &self.nodes.items[existing];
                    if (n.kind != .table or n.state != .implicit) return error.SyntaxError;
                    n.state = .header;
                    n.at = last.at;
                    return existing;
                }
                const defined = try self.node(.{ .kind = .table, .state = .header, .at = last.at }, depth);
                try self.add(t, last, defined);
                return defined;
            }
            const list = if (found) |existing| blk: {
                const n = self.nodes.items[existing];
                if (n.kind != .array or n.state != .of_tables) return error.SyntaxError;
                break :blk existing;
            } else blk: {
                const made = try self.node(.{ .kind = .array, .state = .of_tables, .at = last.at }, depth);
                try self.add(t, last, made);
                break :blk made;
            };
            const element = try self.node(.{ .kind = .table, .state = .header, .at = last.at }, depth + 1);
            try self.link(list, element);
            return element;
        }

        /// `a.b.c = value` into `table`, which is `depth` containers down.
        fn keyValue(self: *Reader, table: u32, depth: usize) Error!void {
            const entry = self.here();
            try self.key();
            if (self.at >= self.input.len or self.input[self.at] != '=') return error.SyntaxError;
            self.at += 1;
            self.whitespace();
            // The table the key names is found, and the key checked, before the
            // value is read: a value may hold keys of its own.
            const segments = self.segments.items;
            var t = table;
            var d = depth;
            for (segments[0 .. segments.len - 1]) |s| {
                d += 1;
                t = try self.descend(t, s, false, d);
            }
            const last = segments[segments.len - 1];
            if (try self.find(t, self.keyBytes(last.key)) != null) return error.SyntaxError;
            const child = try self.value(d + 1);
            if (recording) {
                self.spans.nodes.items[child].end = self.here();
                self.spans.nodes.items[child].entry = entry;
            }
            try self.add(t, last, child);
        }

        // Values.

        fn value(self: *Reader, depth: usize) Error!u32 {
            if (self.at >= self.input.len) return error.SyntaxError;
            const start = self.here();
            switch (self.input[self.at]) {
                '"', '\'' => {
                    const ref = try self.string(text.kindAt(self.input, self.at));
                    return self.node(.scalar(.string, ref, start), depth);
                },
                '[' => return self.array(depth),
                '{' => return self.inlineTable(depth),
                else => {},
            }
            if (try temporal.lex(self.input[self.at..], self.version == .v1_1)) |lexed| {
                self.at += lexed.len;
                try self.delimited();
                const kind: Kind = switch (lexed.parts.kind) {
                    .offset_date_time => .offset_date_time,
                    .local_date_time => .local_date_time,
                    .local_date => .local_date,
                    .local_time => .local_time,
                };
                return self.node(.scalar(kind, .{ .start = start, .len = self.here() - start }, start), depth);
            }
            while (self.at < self.input.len and (std.ascii.isAlphanumeric(self.input[self.at]) or std.mem.findScalar(u8, "_+-.", self.input[self.at]) != null)) self.at += 1;
            const token = self.input[start..self.at];
            try self.delimited();
            if (std.mem.eql(u8, token, "true")) return self.node(.{ .kind = .true, .at = start }, depth);
            if (std.mem.eql(u8, token, "false")) return self.node(.{ .kind = .false, .at = start }, depth);
            const scanned = number.scan(token) orelse return error.SyntaxError;
            if (limit.exceeds(scanned.len, self.c.limits.numeric_bytes)) return error.LengthLimit;
            const ref: Ref = if (scanned.len == token.len) .{ .start = start, .len = self.here() - start } else try self.decode(scanned.len, .{ .number = token });
            const spelling = self.keyBytes(ref);
            // Outside TOML's signed 64 bits, or past a binary64's range, a number
            // is refused here, whatever it is read into.
            switch (scanned.kind) {
                .integer => if (number.integerValue(spelling) == null) return error.NumberOutOfRange,
                .float => {
                    const body = if (spelling[0] == '-') spelling[1..] else spelling;
                    if (!std.mem.eql(u8, body, "inf") and !std.mem.eql(u8, body, "nan")) {
                        const v = std.fmt.parseFloat(f64, spelling) catch return error.SyntaxError;
                        if (!std.math.isFinite(v)) return error.NumberOutOfRange;
                    }
                },
            }
            return self.node(.scalar(if (scanned.kind == .integer) .integer else .float, ref, start), depth);
        }
        /// After a bare value: what may follow one.
        fn delimited(self: *Reader) Error!void {
            if (self.at == self.input.len) return;
            switch (self.input[self.at]) {
                ' ', '\t', '\n', '\r', '#', ',', ']', '}' => {},
                else => return error.SyntaxError,
            }
        }

        fn array(self: *Reader, depth: usize) Error!u32 {
            const list = try self.node(.{ .kind = .array, .at = self.here() }, depth);
            self.at += 1;
            while (true) {
                try self.blank();
                if (self.at < self.input.len and self.input[self.at] == ']') break;
                const element = try self.value(depth + 1);
                if (recording) self.spans.nodes.items[element].end = self.here();
                try self.link(list, element);
                try self.blank();
                if (self.at < self.input.len and self.input[self.at] == ',') {
                    self.at += 1;
                    continue;
                }
                if (self.at < self.input.len and self.input[self.at] == ']') break;
                return error.SyntaxError;
            }
            self.at += 1;
            return list;
        }

        fn inlineTable(self: *Reader, depth: usize) Error!u32 {
            const t = try self.node(.{ .kind = .table, .state = .closed, .at = self.here() }, depth);
            self.at += 1;
            const multiline = self.version == .v1_1;
            var first = true;
            while (true) {
                if (multiline) try self.blank() else self.whitespace();
                if (self.at < self.input.len and self.input[self.at] == '}') {
                    // TOML 1.0 has no comma after the last pair.
                    if (!first and !multiline) return error.SyntaxError;
                    break;
                }
                try self.keyValue(t, depth);
                first = false;
                if (multiline) try self.blank() else self.whitespace();
                if (self.at < self.input.len and self.input[self.at] == ',') {
                    self.at += 1;
                    continue;
                }
                if (self.at < self.input.len and self.input[self.at] == '}') break;
                return error.SyntaxError;
            }
            self.at += 1;
            // Everything the braces made is closed with them.
            self.close(t);
            return t;
        }
        /// Closes the tables a dotted key made inside an inline table.
        fn close(self: *Reader, table: u32) void {
            var child = self.nodes.items[table].first();
            while (child != none) : (child = self.nodes.items[child].next) {
                const n = &self.nodes.items[child];
                if (n.kind == .table and n.state == .dotted) {
                    n.state = .closed;
                    self.close(child);
                }
            }
        }
    };
}

/// The document `input`, its nodes and decoded strings on `allocator`,
/// which `Document.deinit` gives back. `failed_at` is where in the text it
/// was refused, when it was.
pub fn read(c: *core.Context, allocator: std.mem.Allocator, input: []const u8, version: Version, failed_at: *usize) Error!Document {
    return readWith(false, c, allocator, input, version, failed_at, {});
}
/// `read`, and where each part is written into `spans`, for an editor.
pub fn readSpans(c: *core.Context, allocator: std.mem.Allocator, input: []const u8, version: Version, failed_at: *usize, spans: *Spans) Error!Document {
    return readWith(true, c, allocator, input, version, failed_at, spans);
}
fn readWith(comptime recording: bool, c: *core.Context, allocator: std.mem.Allocator, input: []const u8, version: Version, failed_at: *usize, spans: if (recording) *Spans else void) Error!Document {
    const Reader = ReaderOf(recording);
    // A node's place in the text is 32 bits.
    if (input.len >= none) return error.InputLimit;
    var reader: Reader = .{ .c = c, .input = input, .version = version, .allocator = allocator, .spans = spans };
    defer {
        reader.parents.deinit(allocator);
        reader.lasts.deinit(allocator);
        reader.index.deinit(allocator);
        reader.segments.deinit(allocator);
    }
    errdefer {
        failed_at.* = reader.at;
        reader.nodes.deinit(allocator);
        reader.decoded.deinit(allocator);
    }
    try c.chargeWork(input.len);
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    const root = try reader.node(.{ .kind = .table, .state = .header, .at = 0 }, 0);
    if (recording) spans.headers.append(allocator, .{ .node = root, .start = 0, .body_end = 0, .end = @intCast(input.len) }) catch |err| return reader.fail(err);
    var current = root;
    var depth: usize = 0;
    while (true) {
        reader.whitespace();
        if (reader.at == input.len) break;
        const line_at = reader.at;
        var entry_line = false;
        switch (input[reader.at]) {
            '#', '\n', '\r' => {},
            '[' => {
                const array_header = reader.at + 1 < input.len and input[reader.at + 1] == '[';
                reader.at += if (array_header) 2 else 1;
                try reader.key();
                const close_len: usize = if (array_header) 2 else 1;
                if (reader.at + close_len > input.len or !std.mem.allEqual(u8, input[reader.at..][0..close_len], ']')) return error.SyntaxError;
                reader.at += close_len;
                current = if (array_header) try reader.header(root, true) else try reader.header(root, false);
                depth = reader.depthOf(current);
                if (recording) {
                    const line_start: u32 = if (std.mem.findScalarLast(u8, input[0..line_at], '\n')) |k| @intCast(k + 1) else 0; // safe: below 4 GiB.
                    spans.headers.items[spans.headers.items.len - 1].end = line_start;
                    spans.headers.append(allocator, .{ .node = current, .start = line_start, .body_end = 0, .end = @intCast(input.len) }) catch |err| return reader.fail(err);
                }
                entry_line = true;
            },
            else => {
                try reader.keyValue(current, depth);
                entry_line = true;
            },
        }
        try reader.endOfLine();
        if (recording and entry_line) spans.headers.items[spans.headers.items.len - 1].body_end = reader.here();
    }
    return .{ .input = input, .nodes = reader.nodes, .decoded = reader.decoded };
}

test "a node is 28 bytes" {
    try std.testing.expectEqual(28, @sizeOf(Node));
}
