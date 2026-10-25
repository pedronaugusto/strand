//! A YAML stream read into nodes: every node in document order, a collection
//! followed by its members and knowing where they end, an alias naming the
//! node its anchor is on. Aliases are why the stream is read whole before the
//! first value is handed on: an alias repeats a node that came before, and
//! the walk repeats it by going back to it, which a stream read once could
//! not. The nodes and the decoded bytes are working storage the operation is
//! charged for and gives back when the parse ends.
//!
//! What the core schema does not have is refused here: a tag other than its
//! own (`!!str`, `!!int`, `!!float`, `!!bool`, `!!null`, `!!seq`, `!!map`, and
//! `!` on any node), a scalar its tag does not fit, a key given twice in one
//! mapping, an alias to an anchor never set or set on a node still open.
const std = @import("std");
const core = @import("../core.zig");
const parser = @import("parser.zig");
const schema = @import("schema.zig");

pub const Error = core.DecodeError;
pub const Style = parser.Style;

/// No node.
pub const none = std.math.maxInt(u32);

pub const Kind = enum(u2) { scalar, sequence, mapping, alias };
/// A node's tag, as the core schema knows it.
pub const Tag = enum(u4) {
    /// No tag: a plain scalar is what its spelling or the type says; a
    /// quoted or block one is a string.
    none,
    /// `!`: a string, a sequence or a mapping, as the node is.
    non_specific,
    str,
    int,
    float,
    bool,
    null,
    seq,
    map,
};

/// A node: 20 bytes.
pub const Node = struct {
    kind: Kind,
    style: Style = .plain,
    tag: Tag = .none,
    decoded: bool = false,
    /// A scalar's bytes; a collection's member count (pairs in a mapping) in
    /// `len` and how many nodes it is with its aliases repeated in `start`
    /// (at most `none`); an alias's node in `start`.
    data: Span32 = .{},
    /// A collection's end: the position after its last member's last node.
    end: u32 = 0,
    /// Where it was written, for a failure's place.
    at: u32,

    pub fn count(self: Node) u32 {
        return self.data.len;
    }
    pub fn target(self: Node) u32 {
        return self.data.start;
    }
    /// How many nodes a walk of it reads: a collection's members, with each
    /// alias repeating its node, and itself.
    pub fn weight(self: Node) u32 {
        return if (self.kind == .sequence or self.kind == .mapping) self.data.start else 1;
    }
};
pub const Span32 = struct { start: u32 = 0, len: u32 = 0 };

/// A stream read: node 0 is the sequence of its documents, each document
/// one node after it.
pub const Document = struct {
    input: []const u8,
    nodes: std.ArrayList(Node),
    decoded: std.ArrayList(u8),

    pub fn bytes(self: *const Document, node: Node) core.Span {
        const source = if (node.decoded) self.decoded.items else self.input;
        return .{ .bytes = source[node.data.start..][0..node.data.len], .lifetime = if (node.decoded) .transient else .borrowed };
    }
    /// How many documents the stream has.
    pub fn documents(self: *const Document) u32 {
        return self.nodes.items[0].count();
    }
    /// The node an alias names, or the node itself.
    pub fn resolved(self: *const Document, index: u32) u32 {
        const node = self.nodes.items[index];
        return if (node.kind == .alias) node.target() else index;
    }
    /// Gives back the stream's working storage.
    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.decoded.deinit(allocator);
    }
};

/// A scalar key in a mapping, as what it is: two keys are the same when
/// they are the same value (`a` and `"a"`, `1` and `0x1`, `~` and `null`),
/// as `yaml.Value` compares them, and two values spelled alike may differ (`1`
/// and `"1"`). A string compares its bytes, which `node` holds.
pub const Key = struct {
    mapping: u32,
    kind: schema.Kind,
    /// An integer's value, a float's bits (zero and NaN made one), a boolean.
    bits: u128 = 0,
    node: u32 = none,
};
pub const KeyContext = struct {
    nodes: []const Node,
    input: []const u8,
    decoded: []const u8,
    fn text(self: KeyContext, n: u32) []const u8 {
        const node = self.nodes[n];
        const source = if (node.decoded) self.decoded else self.input;
        return source[node.data.start..][0..node.data.len];
    }
    pub fn hash(self: KeyContext, key: Key) u64 {
        var h: std.hash.Wyhash = .init(key.mapping);
        h.update(&.{@backingInt(key.kind)});
        h.update(std.mem.asBytes(&key.bits));
        if (key.node != none) h.update(self.text(key.node));
        return h.final();
    }
    pub fn eql(self: KeyContext, a: Key, b: Key) bool {
        if (a.mapping != b.mapping or a.kind != b.kind or a.bits != b.bits or (a.node == none) != (b.node == none)) return false;
        return a.node == none or std.mem.eql(u8, self.text(a.node), self.text(b.node));
    }
};
/// What a scalar key is, as a value.
fn keyOf(mapping: u32, node: Node, index: u32, text: []const u8) Key {
    const kind: schema.Kind = switch (node.tag) {
        .none => if (node.style == .plain) schema.resolve(text) else .string,
        .non_specific, .str, .seq, .map => .string,
        .int => .integer,
        .float => .float,
        .bool => .boolean,
        .null => .null,
    };
    var key: Key = .{ .mapping = mapping, .kind = kind };
    switch (kind) {
        .null => {},
        .boolean => key.bits = @intFromBool(schema.boolean(text).?),
        .integer => {
            if (schema.integer(i128, text)) |n| key.bits = @bitCast(n) else key.node = index;
        },
        .float => {
            // Past a binary64's range, a float is its spelling.
            if (schema.float(text)) |f| {
                key.bits = if (std.math.isNan(f)) 1 else if (f == 0) 0 else @as(u64, @bitCast(f));
            } else key.node = index;
        },
        .string => key.node = index,
    }
    return key;
}

/// A collection open: its position, its members so far, and how many nodes
/// the stream was, aliases repeated, when it opened.
const Open = struct { node: u32, members: u32, expanded: u64 };

/// Where each node is written, which `readSpans` records for an editor.
pub const Spans = struct {
    nodes: std.ArrayList(NodeSpan) = .empty,
};
pub const NodeSpan = struct {
    /// Its first byte: its anchor's or tag's, when it has one.
    start: u32,
    /// Past its last byte: a block scalar's last line without its line break.
    end: u32 = 0,
    /// The `-` it is a block sequence's entry after, or the `?` it is an
    /// explicit key after; else its start.
    entry: u32,
    /// A collection is written in flow style.
    flow: bool = false,
};

fn BuilderOf(comptime recording: bool) type {
    return struct {
        c: *core.Context,
        allocator: std.mem.Allocator,
        p: *parser.Parser,
        nodes: std.ArrayList(Node) = .empty,
        open: std.ArrayList(Open) = .empty,
        anchors: std.StringHashMapUnmanaged(u32) = .empty,
        keys: std.HashMapUnmanaged(Key, void, KeyContext, std.hash_map.default_max_load_percentage) = .empty,
        /// How many nodes a walk of the stream reads, each alias repeating its
        /// node: held to the item limit before anything is walked, so that
        /// aliases of aliases cannot multiply past it.
        expanded: u64 = 0,
        failed_at: u32 = 0,
        spans: if (recording) *Spans else void,

        const Builder = @This();

        fn fail(self: *Builder, at: u32, err: Error) Error {
            self.failed_at = at;
            return err;
        }
        fn oom(self: *Builder, err: anyerror) Error {
            return switch (err) {
                error.OutOfMemory => if (self.c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
                error.InputLimit => error.InputLimit,
                else => error.SyntaxError,
            };
        }
        fn keyContext(self: *const Builder) KeyContext {
            return .{ .nodes = self.nodes.items, .input = self.p.scanner.input, .decoded = self.p.scanner.decoded.items };
        }

        fn tagOf(self: *Builder, event: parser.Event) Error!Tag {
            if (!event.tagged) return .none;
            const tag = self.p.text(event.tag);
            if (std.mem.eql(u8, tag, "!")) return .non_specific;
            const prefix = "tag:yaml.org,2002:";
            if (std.mem.startsWith(u8, tag, prefix)) {
                const name = tag[prefix.len..];
                inline for (.{ "str", "int", "float", "bool", "null", "seq", "map" }) |known| {
                    if (std.mem.eql(u8, name, known)) return @field(Tag, known);
                }
            }
            // No executable or application type: a tag the core schema lacks.
            return self.fail(event.start.index, error.UnsupportedValue);
        }

        /// Appends `node` as the next member of the collection open, if any.
        fn add(self: *Builder, node: Node) Error!u32 {
            const position = std.math.cast(u32, self.nodes.items.len) orelse return error.ItemLimit;
            if (position == none) return error.ItemLimit;
            var placed = node;
            // A scalar or an alias ends where it is.
            if (node.kind == .scalar or node.kind == .alias) placed.end = position + 1;
            self.expanded +|= if (node.kind == .alias) self.nodes.items[node.target()].weight() else 1;
            if (self.expanded > self.c.limits.items) return self.fail(node.at, error.ItemLimit);
            self.nodes.append(self.allocator, placed) catch |err| return self.oom(err);
            if (recording) {
                const entry = self.p.indicator orelse node.at;
                self.p.indicator = null;
                self.spans.nodes.append(self.allocator, .{ .start = node.at, .entry = entry }) catch |err| return self.oom(err);
            }
            if (self.open.items.len > 0) {
                const top = &self.open.items[self.open.items.len - 1];
                const container = self.nodes.items[top.node];
                top.members += 1;
                const members = if (container.kind == .mapping) (top.members + 1) / 2 else top.members;
                if (members > self.c.limits.container_items) return self.fail(node.at, error.ItemLimit);
                // A mapping's keys: each given once.
                if (container.kind == .mapping and top.members % 2 == 1) try self.checkKey(top.node, position);
            }
            return position;
        }
        fn checkKey(self: *Builder, mapping: u32, position: u32) Error!void {
            const key_node = self.resolvedIndex(position);
            const node = self.nodes.items[key_node];
            if (node.kind != .scalar) return;
            const context = self.keyContext();
            const text = context.text(key_node);
            try self.c.chargeWork(text.len + 1);
            const slot = self.keys.getOrPutContext(self.allocator, keyOf(mapping, node, key_node, text), context) catch |err| return self.oom(err);
            if (slot.found_existing) return self.fail(self.nodes.items[position].at, error.DuplicateField);
        }
        fn resolvedIndex(self: *const Builder, position: u32) u32 {
            const node = self.nodes.items[position];
            return if (node.kind == .alias) node.target() else position;
        }
        fn anchor(self: *Builder, event: parser.Event, position: u32) Error!void {
            if (event.anchor.len == 0) return;
            const name = self.p.text(event.anchor);
            self.anchors.put(self.allocator, name, position) catch |err| return self.oom(err);
        }

        fn run(self: *Builder) Error!void {
            // The stream: a sequence of its documents.
            const stream = try self.add(.{ .kind = .sequence, .at = 0 });
            self.open.append(self.allocator, .{ .node = stream, .members = 0, .expanded = 0 }) catch |err| return self.oom(err);
            while (true) {
                const event = self.p.next() catch |err| {
                    self.failed_at = self.p.failedAt();
                    return self.oom(err);
                };
                const at = event.start.index;
                switch (event.kind) {
                    .stream_start, .document_end => {},
                    .document_start => {
                        // Anchors are a document's own.
                        self.anchors.clearRetainingCapacity();
                    },
                    .stream_end => break,
                    .sequence_start, .mapping_start => {
                        if (self.open.items.len > self.c.limits.depth) return self.fail(at, error.DepthLimit);
                        const kind: Kind = if (event.kind == .sequence_start) .sequence else .mapping;
                        const tag = try self.tagOf(event);
                        switch (tag) {
                            .none, .non_specific => {},
                            .seq => if (kind != .sequence) return self.fail(at, error.UnexpectedType),
                            .map => if (kind != .mapping) return self.fail(at, error.UnexpectedType),
                            else => return self.fail(at, error.UnexpectedType),
                        }
                        const position = try self.add(.{ .kind = kind, .tag = tag, .at = at });
                        if (recording) self.spans.nodes.items[position].flow = event.flow;
                        try self.anchor(event, position);
                        self.open.append(self.allocator, .{ .node = position, .members = 0, .expanded = self.expanded - 1 }) catch |err| return self.oom(err);
                    },
                    .sequence_end, .mapping_end => {
                        const top = self.open.pop().?;
                        const node = &self.nodes.items[top.node];
                        node.data.len = if (node.kind == .mapping) top.members / 2 else top.members;
                        node.data.start = std.math.cast(u32, self.expanded - top.expanded) orelse none;
                        node.end = @intCast(self.nodes.items.len); // safe: below `none`, as every position is.
                        if (recording) self.ended(top.node);
                    },
                    .scalar => {
                        const tag = try self.tagOf(event);
                        var node: Node = .{ .kind = .scalar, .style = event.style, .tag = tag, .decoded = event.value.decoded, .data = .{ .start = event.value.start, .len = event.value.len }, .at = at };
                        try self.check(&node, event);
                        const position = try self.add(node);
                        if (recording) self.ended(position);
                        try self.anchor(event, position);
                    },
                    .alias => {
                        const name = self.p.text(event.anchor);
                        const target = self.anchors.get(name) orelse return self.fail(at, error.SyntaxError);
                        // An alias inside the node its anchor is on would repeat
                        // itself without end.
                        if (self.nodes.items[target].end == 0) return self.fail(at, error.SyntaxError);
                        const position = try self.add(.{ .kind = .alias, .data = .{ .start = target }, .at = at });
                        if (recording) self.ended(position);
                    },
                }
            }
            const top = self.open.pop().?;
            self.nodes.items[stream].data.len = top.members;
            self.nodes.items[stream].end = @intCast(self.nodes.items.len); // safe: below `none`.
            if (recording) self.spans.nodes.items[stream].end = @intCast(self.p.scanner.input.len); // safe: below `none`, as `read` checks.
        }
        /// Node `position` ends where the event just read does; a block
        /// scalar's trailing line breaks are not its own here, nor its
        /// collection's.
        fn ended(self: *Builder, position: u32) void {
            const span = &self.spans.nodes.items[position];
            const input = self.p.scanner.input;
            var end = @max(span.start, self.p.last_end);
            while (end > span.start and (input[end - 1] == '\n' or input[end - 1] == '\r' or input[end - 1] == ' ')) end -= 1;
            span.end = end;
        }
        /// A tagged scalar is what its tag says. A float spelled as an integer
        /// (`!!float 12`) is given a float's spelling, so that what reads it
        /// knows it from an integer.
        fn check(self: *Builder, node: *Node, event: parser.Event) Error!void {
            const text = self.p.text(event.value);
            const at = event.start.index;
            const fits = switch (node.tag) {
                .none, .non_specific, .str => true,
                .null => schema.isNull(text),
                .bool => schema.boolean(text) != null,
                .int => schema.number(text) == .integer,
                .float => schema.number(text) != null,
                .seq, .map => false,
            };
            if (!fits) return self.fail(at, if (node.tag == .seq or node.tag == .map) error.UnexpectedType else error.SyntaxError);
            if (node.tag != .float or schema.number(text) != .integer) return;
            // In decimal, then `.0`: `-0x1` is no spelling, so a sign is decimal's.
            const negative = text[0] == '-';
            const magnitude = schema.integer(u128, if (negative or text[0] == '+') text[1..] else text) orelse return self.fail(at, error.NumberOutOfRange);
            const decoded = self.p.scanner.decoded;
            const start = std.math.cast(u32, decoded.items.len) orelse return error.InputLimit;
            decoded.print(self.allocator, "{s}{d}.0", .{ if (negative) "-" else "", magnitude }) catch |err| return self.oom(err);
            node.decoded = true;
            node.data = .{ .start = start, .len = @intCast(decoded.items.len - start) }; // safe: a spelling of a u128, short.
        }
    };
}

/// The stream `input`, its nodes and decoded bytes on `allocator`, which
/// `Document.deinit` gives back. `failed_at` is where in the text it was
/// refused, when it was.
pub fn read(c: *core.Context, allocator: std.mem.Allocator, input: []const u8, failed_at: *usize) Error!Document {
    return readWith(false, c, allocator, input, failed_at, {});
}
/// The stream as `read` reads it, and in `spans` where each node is written,
/// on `allocator` too.
pub fn readSpans(c: *core.Context, allocator: std.mem.Allocator, input: []const u8, failed_at: *usize, spans: *Spans) Error!Document {
    return readWith(true, c, allocator, input, failed_at, spans);
}
fn readWith(comptime recording: bool, c: *core.Context, allocator: std.mem.Allocator, input: []const u8, failed_at: *usize, spans: if (recording) *Spans else void) Error!Document {
    // A node's place in the text is 32 bits.
    if (input.len >= none) return error.InputLimit;
    try c.chargeWork(input.len);
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
    var decoded: std.ArrayList(u8) = .empty;
    var p: parser.Parser = .init(input, allocator, &decoded);
    defer p.deinit();
    var builder: BuilderOf(recording) = .{ .c = c, .allocator = allocator, .p = &p, .spans = spans };
    defer {
        builder.open.deinit(allocator);
        builder.anchors.deinit(allocator);
        builder.keys.deinit(allocator);
    }
    builder.run() catch |err| {
        failed_at.* = builder.failed_at;
        builder.nodes.deinit(allocator);
        decoded.deinit(allocator);
        return err;
    };
    return .{ .input = input, .nodes = builder.nodes, .decoded = decoded };
}

test "a node is 20 bytes" {
    try std.testing.expectEqual(20, @sizeOf(Node));
}
