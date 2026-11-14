//! The schema documents one compile reads, by URI. Each subschema's base URI is
//! the RFC 3986 §5 resolution, through `uplink.wire`, of every `$id` on the way
//! to it; the registry holds the resources and anchors each document declares,
//! and finds a reference's target in a document already read, among the
//! embedded meta-schemas, or through the caller's loader.
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const wire = @import("uplink.wire");
const Limits = @import("Limits.zig");
const Location = @import("Location.zig");
const Loader = @import("Loader.zig");
const metaschemas = @import("metaschemas.zig");
const dialect = @import("dialect.zig");

const Value = strand.json.Value;
/// An object's member, as `Value` holds it.
const Member = strand.core.Pair([]const u8, Value);
const uri = wire.uri;

pub const Dialect = dialect.Dialect;
const Vocabularies = dialect.Vocabularies;

/// The base URI of a document read with none: a schema compiled from bytes
/// with no `$id` resolves its relative references against this.
pub const default_base = "urn:strand:schema";

pub const Error = error{
    OutOfMemory,
    /// An `$id`, `$anchor` or reference that is not what its draft allows,
    /// two schemas with one URI, or a document that is not JSON.
    Invalid,
    /// A reference to no schema: a document no one has, or a fragment that
    /// names nothing in it.
    UnresolvedReference,
    /// Past `Limits.schema_bytes`, `Limits.subschemas`, or
    /// `Limits.reference_chain` meta-schemas deep.
    TooLarge,
    /// A `$schema` naming a meta-schema strand neither has nor can load.
    UnknownDialect,
    /// A meta-schema requiring a vocabulary strand does not know.
    UnsupportedVocabulary,
} || Loader.LoadError;

/// Where a schema sits: the base URI its references resolve against, and the
/// draft it is read as.
pub const Scope = struct {
    base: []const u8,
    dialect: Dialect,
    /// The vocabularies its meta-schema turns on: the dialect's own, or a
    /// custom meta-schema's `$vocabulary`.
    vocabularies: Vocabularies,
    /// `$recursiveAnchor: true` at a resource's root (2019-09).
    recursive_anchor: bool = false,
    /// The schema it is in, null for a document's root.
    parent: ?*const Value = null,
    /// The JSON Pointer from `parent` to it, as written (`/properties/a~1b`).
    path: []const u8 = "",
    /// Whether a resource begins here: a document's root, or an `$id`.
    resource: bool = false,
};

/// Where a subschema is being read from: the scope around it.
const Around = struct {
    base: []const u8,
    dialect: Dialect,
    vocabularies: Vocabularies,
    parent: ?*const Value = null,
    path: []const u8 = "",
};

pub const Anchor = struct {
    value: *const Value,
    /// A `$dynamicAnchor` (2020-12), which `$dynamicRef` may resolve to.
    dynamic: bool,
};

/// A reference's schema, and where it sits.
pub const Target = struct {
    value: *const Value,
    scope: Scope,
};

pub const Registry = struct {
    /// Every document, key and URI: freed with the compile's arena.
    arena: std.mem.Allocator,
    io: std.Io,
    loader: ?*Loader,
    limits: Limits,
    /// Each resource's root, by its absolute URI with no fragment.
    resources: std.StringHashMapUnmanaged(*const Value) = .empty,
    /// `uri#name` for each `$anchor`, `$dynamicAnchor` and draft-07
    /// fragment `$id`.
    anchors: std.StringHashMapUnmanaged(Anchor) = .empty,
    /// Each subschema read, where it sits.
    scopes: std.AutoHashMapUnmanaged(*const Value, Scope) = .empty,
    subschemas: usize = 0,
    /// The URI the last failed `add` or `lookup` was reading.
    failed: []const u8 = "",
    /// Meta-schemas being read for a `$schema` right now, one inside another.
    meta_depth: usize = 0,

    pub fn init(arena: std.mem.Allocator, io: std.Io, loader: ?*Loader, limits: Limits) Registry {
        return .{ .arena = arena, .io = io, .loader = loader, .limits = limits };
    }

    /// Reads `root`, a document from `retrieval` (`default_base` when null),
    /// in `dialect` unless its `$schema` names another.
    pub fn add(r: *Registry, retrieval: ?[]const u8, root: *const Value, d: Dialect) Error!Target {
        const base = retrieval orelse default_base;
        r.failed = base;
        const parsed = uri.parse(.init(base), .absolute, .iri, null) catch return error.Invalid;
        _ = parsed;
        try r.index(root, .{ .base = try r.arena.dupe(u8, base), .dialect = d, .vocabularies = dialect.defaults(d) }, true);
        return r.targetOf(root);
    }

    /// The schema `reference` names, resolved against `base`; a document not
    /// yet read is read in `dialect` unless its `$schema` names another.
    pub fn lookup(r: *Registry, base: []const u8, reference: []const u8, d: Dialect) Error!Target {
        r.failed = reference;
        const target = try r.resolve(base, reference);
        r.failed = target;
        const parts = splitFragment(target);
        const root = r.resources.get(parts.uri) orelse try r.fetch(parts.uri, d);
        const fragment = parts.fragment orelse "";
        if (fragment.len == 0) return r.targetOf(root);
        // The fragment is percent-encoded (uri.parse checked each escape).
        const decoded = wire.url.percentDecode(try r.arena.alloc(u8, fragment.len), fragment);
        if (decoded[0] == '/') return r.pointer(root, decoded);
        const key = try std.mem.concat(r.arena, u8, &.{ parts.uri, "#", decoded });
        const anchor = r.anchors.get(key) orelse return error.UnresolvedReference;
        return r.targetOf(anchor.value);
    }

    /// The name of the anchor `reference` names, resolved against `base`,
    /// when it is a `$dynamicAnchor`: where a `$dynamicRef` searches the
    /// dynamic scope. Null for a pointer, or a plain anchor. The document it
    /// names is one already read.
    pub fn dynamicAnchorName(r: *Registry, base: []const u8, reference: []const u8) Error!?[]const u8 {
        const parts = splitFragment(try r.resolve(base, reference));
        const fragment = parts.fragment orelse return null;
        if (fragment.len == 0) return null;
        const decoded = wire.url.percentDecode(try r.arena.alloc(u8, fragment.len), fragment);
        if (decoded[0] == '/') return null;
        const key = try std.mem.concat(r.arena, u8, &.{ parts.uri, "#", decoded });
        const anchor = r.anchors.get(key) orelse return null;
        return if (anchor.dynamic) decoded else null;
    }

    /// Where `value`, a subschema the registry read, sits.
    pub fn targetOf(r: *const Registry, value: *const Value) Target {
        return .{ .value = value, .scope = r.scopes.get(value).? }; // every root and anchor was indexed
    }

    /// `reference` resolved against `base` by RFC 3986 §5.2, on the arena.
    fn resolve(r: *Registry, base: []const u8, reference: []const u8) Error![]const u8 {
        const b = uri.parse(.init(base), .uri, .iri, null) catch return error.Invalid;
        const ref = uri.parse(.init(reference), .reference, .iri, null) catch return error.Invalid;
        // The target is the base's parts and the reference's, with at most
        // a '/' joining a merged path: the two lengths and that bound it.
        const out = try r.arena.alloc(u8, base.len + reference.len + 1);
        return uri.resolve(b, ref, out) catch |err| switch (err) {
            error.NotAbsolute => error.Invalid,
            error.NoSpaceLeft => error.TooLarge,
        };
    }

    /// The JSON Pointer `pointer` from `root`, its scope that of the last
    /// subschema the walk passed through.
    fn pointer(r: *Registry, root: *const Value, text: []const u8) Error!Target {
        var tokens = Location.tokens(text) catch return error.Invalid;
        const buffer = try r.arena.alloc(u8, text.len);
        var at = root;
        var scope = r.scopes.get(root).?; // a resource root was indexed
        while (tokens.next(buffer)) |token| {
            at = switch (at.*) {
                .object => |members| for (members) |*m| {
                    if (std.mem.eql(u8, m.key, token)) break &m.value;
                } else return error.UnresolvedReference,
                .array => |items| blk: {
                    const i = Location.arrayIndex(token) orelse return error.UnresolvedReference;
                    if (i >= items.len) return error.UnresolvedReference;
                    break :blk &items[i];
                },
                else => return error.UnresolvedReference,
            };
            if (r.scopes.get(at)) |s| scope = s;
        }
        return .{ .value = at, .scope = scope };
    }

    /// The document at `address`: embedded, or the loader's.
    fn fetch(r: *Registry, address: []const u8, d: Dialect) Error!*const Value {
        const bytes = metaschemas.get(address) orelse blk: {
            const loader = r.loader orelse return error.UnresolvedReference;
            break :blk try loader.load(r.arena, r.io, address);
        };
        if (aegis.units.Bytes(usize).fromRaw(bytes.len).compare(r.limits.schema_bytes) == .gt) return error.TooLarge;
        const value = try r.arena.create(Value);
        value.* = strand.json.parseLeaky(Value, r.arena, bytes, .{}) catch |err|
            return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
        try r.index(value, .{ .base = address, .dialect = d, .vocabularies = dialect.defaults(d) }, true);
        return value;
    }

    /// Reads the schema `value` and every subschema in it, `around` where
    /// it sits; `root` for a document's root, which its retrieval URI names
    /// too.
    fn index(r: *Registry, value: *const Value, around: Around, root: bool) Error!void {
        r.subschemas += 1;
        if (r.subschemas > r.limits.subschemas) return error.TooLarge;
        var scope: Scope = .{ .base = around.base, .dialect = around.dialect, .vocabularies = around.vocabularies, .parent = around.parent, .path = around.path, .resource = root };
        const members = switch (value.*) {
            .object => |m| m,
            else => {
                // `true`, `false`, or what compiling refuses as a schema.
                try r.scopes.put(r.arena, value, scope);
                if (root) try r.putResource(scope.base, value);
                return;
            },
        };
        const id = member(members, "$id");
        // In draft-07 `$ref` hides its siblings, `$id` among them.
        const hidden = around.dialect == .draft7 and member(members, "$ref") != null;
        const id_text: ?[]const u8 = if (id == null or hidden) null else switch (id.?.*) {
            .string => |s| s,
            else => return error.Invalid,
        };
        // `$schema` where a resource begins.
        if (root or id_text != null) if (member(members, "$schema")) |s| switch (s.*) {
            .string => |text| try r.metaschema(&scope, text),
            else => return error.Invalid,
        };
        if (root) try r.putResource(scope.base, value);
        if (id_text) |text| {
            if (scope.dialect == .draft7 and std.mem.startsWith(u8, text, "#")) {
                // A plain-name fragment: an anchor in the base it is in.
                try r.putAnchor(scope.base, text[1..], value, false);
            } else {
                const parts = splitFragment(try r.resolve(scope.base, text));
                const fragment = parts.fragment orelse "";
                // Only draft-07 lets an `$id` carry a fragment.
                if (fragment.len > 0 and scope.dialect != .draft7) return error.Invalid;
                scope.base = parts.uri;
                scope.resource = true;
                try r.putResource(scope.base, value);
                if (fragment.len > 0) try r.putAnchor(scope.base, fragment, value, false);
            }
        }
        if (scope.dialect != .draft7) {
            if (member(members, "$anchor")) |a| try r.putAnchor(scope.base, try anchorName(scope.dialect, a), value, false);
        }
        if (scope.dialect == .draft2020_12) {
            if (member(members, "$dynamicAnchor")) |a| try r.putAnchor(scope.base, try anchorName(scope.dialect, a), value, true);
        }
        if (scope.dialect == .draft2019_09) {
            if (member(members, "$recursiveAnchor")) |a| switch (a.*) {
                .boolean => |on| scope.recursive_anchor = on,
                else => return error.Invalid,
            };
        }
        try r.scopes.put(r.arena, value, scope);
        for (members) |*m| {
            const s = dialect.shape(scope.dialect, m.key) orelse continue;
            const inner: Around = .{ .base = scope.base, .dialect = scope.dialect, .vocabularies = scope.vocabularies, .parent = value };
            switch (s) {
                .one => try r.indexOne(&m.value, inner, &.{.{ .name = m.key }}),
                .list => try r.indexList(&m.value, inner, m.key),
                .map => if (m.value == .object) for (m.value.object) |*entry| {
                    try r.indexOne(&entry.value, inner, &.{ .{ .name = m.key }, .{ .name = entry.key } });
                },
                .one_or_list => if (m.value == .array) try r.indexList(&m.value, inner, m.key) else try r.indexOne(&m.value, inner, &.{.{ .name = m.key }}),
            }
        }
    }

    /// Reads the meta-schema a resource's `$schema` names into `scope`: one
    /// of the three drafts, or a custom meta-schema, whose own `$schema`
    /// gives the dialect and whose `$vocabulary` the vocabularies.
    fn metaschema(r: *Registry, scope: *Scope, text: []const u8) Error!void {
        if (Dialect.fromUri(text)) |d| {
            scope.dialect = d;
            scope.vocabularies = dialect.defaults(d);
            return;
        }
        r.meta_depth += 1;
        defer r.meta_depth -= 1;
        if (r.meta_depth > r.limits.reference_chain) return error.TooLarge;
        const meta = r.lookup(scope.base, text, scope.dialect) catch |err| return switch (err) {
            error.UnresolvedReference, error.NotFound => error.UnknownDialect,
            else => err,
        };
        // A meta-schema still being read, its own or one that names it.
        const meta_scope = r.scopes.get(meta.value) orelse return error.Invalid;
        scope.dialect = meta_scope.dialect;
        scope.vocabularies = meta_scope.vocabularies;
        if (meta_scope.dialect == .draft7 or meta.value.* != .object) return;
        const declared = member(meta.value.object, "$vocabulary") orelse return;
        if (declared.* != .object) return error.Invalid;
        scope.vocabularies = .empty;
        for (declared.object) |entry| {
            const required = switch (entry.value) {
                .boolean => |b| b,
                else => return error.Invalid,
            };
            if (dialect.vocabularyFromUri(meta_scope.dialect, entry.key)) |v| {
                scope.vocabularies.insert(v);
            } else if (required) return error.UnsupportedVocabulary;
        }
    }

    /// The JSON Pointer from the resource `value` is in to `value`, as an
    /// absolute location writes it after its URI's `#`.
    pub fn pointerOf(r: *const Registry, gpa: std.mem.Allocator, value: *const Value) error{OutOfMemory}![]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        var at = value;
        while (true) {
            const scope = r.scopes.get(at).?; // only a value the registry read is asked about
            if (scope.resource) break;
            try parts.append(gpa, scope.path);
            at = scope.parent orelse break;
        }
        std.mem.reverse([]const u8, parts.items);
        return std.mem.concat(gpa, u8, parts.items);
    }

    /// `value` if it is a schema (an object or a boolean), `steps` below
    /// the schema around it.
    fn indexOne(r: *Registry, value: *const Value, around: Around, steps: []const Location.Step) Error!void {
        switch (value.*) {
            .object, .boolean => {},
            else => return,
        }
        var path: std.Io.Writer.Allocating = .init(r.arena);
        for (steps) |step| {
            path.writer.writeByte('/') catch return error.OutOfMemory;
            switch (step) {
                .name => |n| Location.writeToken(&path.writer, n) catch return error.OutOfMemory,
                .index => |i| path.writer.print("{d}", .{i}) catch return error.OutOfMemory,
            }
        }
        var inner = around;
        inner.path = path.written();
        try r.index(value, inner, false);
    }

    fn indexList(r: *Registry, value: *const Value, around: Around, keyword: []const u8) Error!void {
        if (value.* != .array) return;
        for (value.array, 0..) |*item, i| try r.indexOne(item, around, &.{ .{ .name = keyword }, .{ .index = i } });
    }

    fn putResource(r: *Registry, key: []const u8, value: *const Value) Error!void {
        const entry = try r.resources.getOrPut(r.arena, key);
        if (entry.found_existing) {
            // Two schemas with one URI.
            if (entry.value_ptr.* != value) return error.Invalid;
            return;
        }
        entry.key_ptr.* = try r.arena.dupe(u8, key);
        entry.value_ptr.* = value;
    }

    fn putAnchor(r: *Registry, base: []const u8, name: []const u8, value: *const Value, dynamic: bool) Error!void {
        const key = try std.mem.concat(r.arena, u8, &.{ base, "#", name });
        const entry = try r.anchors.getOrPut(r.arena, key);
        if (entry.found_existing) {
            if (entry.value_ptr.value != value) return error.Invalid;
            entry.value_ptr.dynamic = entry.value_ptr.dynamic or dynamic;
            return;
        }
        entry.value_ptr.* = .{ .value = value, .dynamic = dynamic };
    }
};

/// The member `name` of an object's members.
fn member(members: []const Member, name: []const u8) ?*const Value {
    for (members) |*m| if (std.mem.eql(u8, m.key, name)) return &m.value;
    return null;
}

/// An `$anchor` or `$dynamicAnchor`'s name, as its draft spells one:
/// 2020-12 `[A-Za-z_][-A-Za-z0-9._]*`, 2019-09 `[A-Za-z][-A-Za-z0-9.:_]*`.
fn anchorName(d: Dialect, value: *const Value) Error![]const u8 {
    const name = switch (value.*) {
        .string => |s| s,
        else => return error.Invalid,
    };
    if (name.len == 0) return error.Invalid;
    const first_ok = std.ascii.isAlphabetic(name[0]) or (d == .draft2020_12 and name[0] == '_');
    if (!first_ok) return error.Invalid;
    for (name[1..]) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or (d == .draft2019_09 and c == ':');
        if (!ok) return error.Invalid;
    }
    return name;
}

const Parts = struct { uri: []const u8, fragment: ?[]const u8 };

/// A URI at its first `#`.
fn splitFragment(text: []const u8) Parts {
    const h = std.mem.findScalar(u8, text, '#') orelse return .{ .uri = text, .fragment = null };
    return .{ .uri = text[0..h], .fragment = text[h + 1 ..] };
}

const testing = std.testing;

/// `text` read as a document on `arena`.
fn document(arena: std.mem.Allocator, text: []const u8) !*const Value {
    const value = try arena.create(Value);
    value.* = try strand.json.parseLeaky(Value, arena, text, .{});
    return value;
}

/// A loader over a table of URIs and documents, counting its loads.
const TableLoader = struct {
    loader: Loader = .{ .vtable = &.{ .load = load } },
    documents: []const [2][]const u8,
    loads: usize = 0,

    fn load(l: *Loader, gpa: std.mem.Allocator, io: std.Io, wanted: []const u8) Loader.LoadError![]const u8 {
        _ = io;
        const self: *TableLoader = @fieldParentPtr("loader", l);
        self.loads += 1;
        for (self.documents) |d| if (std.mem.eql(u8, d[0], wanted)) return gpa.dupe(u8, d[1]);
        return error.NotFound;
    }
};

test "every reference in the embedded meta-schemas resolves" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    var r: Registry = .init(state.allocator(), testing.io, null, .{});
    for (metaschemas.all) |d| _ = try r.lookup(default_base, d.uri, .draft2020_12);
    // Each document's own `$schema` chose its dialect.
    try testing.expectEqual(Dialect.draft7, r.targetOf(r.resources.get(Dialect.draft7.uri()).?).scope.dialect);
    try testing.expectEqual(Dialect.draft2019_09, r.targetOf(r.resources.get("https://json-schema.org/draft/2019-09/meta/core").?).scope.dialect);
    // The references, collected before any is followed.
    var references: std.ArrayList(struct { scope: Scope, text: []const u8 }) = .empty;
    var it = r.scopes.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.*.* != .object) continue;
        for ([_][]const u8{ "$ref", "$dynamicRef", "$recursiveRef" }) |keyword| {
            if (member(entry.key_ptr.*.object, keyword)) |v| try references.append(state.allocator(), .{ .scope = entry.value_ptr.*, .text = v.string });
        }
    }
    try testing.expect(references.items.len >= 40);
    const resources = r.resources.count();
    for (references.items) |ref| {
        const target = try r.lookup(ref.scope.base, ref.text, ref.scope.dialect);
        try testing.expect(target.value.* == .object or target.value.* == .boolean);
    }
    // Nothing outside the embedded documents was asked for.
    try testing.expectEqual(resources, r.resources.count());
    // 2019-09's meta-schemas mark their roots for `$recursiveRef`.
    try testing.expect(r.targetOf(r.resources.get("https://json-schema.org/draft/2019-09/schema").?).scope.recursive_anchor);
    // 2020-12's `#meta` is a dynamic anchor.
    try testing.expect(r.anchors.get("https://json-schema.org/draft/2020-12/schema#meta").?.dynamic);
}

test "`$id` sets the base its subschemas' references resolve against" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var r: Registry = .init(a, testing.io, null, .{});
    const root = try document(a,
        \\{"$id": "http://example.com/root.json",
        \\ "$defs": {
        \\   "B": {"$id": "other.json", "$defs": {
        \\     "X": {"$anchor": "bar"},
        \\     "Y": {"$id": "t/inner.json", "$anchor": "here"}}},
        \\   "C": {"$id": "urn:uuid:ee564b8a-7a87-4125-8c96-e9f123d6766f"},
        \\   "D": {"enum": [{"$id": "http://example.com/not-a-schema.json"}]},
        \\   "E": {"x-unknown": {"$id": "http://example.com/also-not.json"}},
        \\   "tilde~field": {"type": "integer"},
        \\   "slash/field": {"type": "number"},
        \\   "percent%field": {"type": "string"}}}
    );
    // 2019-09 and 2020-12 refuse a fragment in `$id`.
    const fragment = try document(a, "{\"$defs\": {\"A\": {\"$id\": \"#foo\"}}}");
    try testing.expectError(error.Invalid, r.add(null, fragment, .draft2020_12));
    var r19: Registry = .init(a, testing.io, null, .{});
    try testing.expectError(error.Invalid, r19.add(null, fragment, .draft2019_09));
    var r7: Registry = .init(a, testing.io, null, .{});
    const t = try r7.add(null, root, .draft2019_09);
    try testing.expectEqualStrings("http://example.com/root.json", t.scope.base);
    const b = try r7.lookup(t.scope.base, "other.json", .draft2019_09);
    try testing.expectEqualStrings("http://example.com/other.json", b.scope.base);
    const x = try r7.lookup(t.scope.base, "other.json#bar", .draft2019_09);
    try testing.expectEqualStrings("http://example.com/other.json", x.scope.base);
    const y = try r7.lookup(b.scope.base, "t/inner.json", .draft2019_09);
    try testing.expectEqualStrings("http://example.com/t/inner.json", y.scope.base);
    try testing.expect((try r7.lookup(t.scope.base, "http://example.com/t/inner.json#here", .draft2019_09)).value == y.value);
    _ = try r7.lookup(t.scope.base, "urn:uuid:ee564b8a-7a87-4125-8c96-e9f123d6766f", .draft2019_09);
    // A pointer through `$id`s ends in the scope of the resource it reaches.
    const via = try r7.lookup(t.scope.base, "#/$defs/B/$defs/X", .draft2019_09);
    try testing.expect(via.value == x.value);
    try testing.expectEqualStrings("http://example.com/other.json", via.scope.base);
    // RFC 6901's escapes under the URI's percent-encoding.
    try testing.expectEqualStrings("integer", member((try r7.lookup(t.scope.base, "#/$defs/tilde~0field", .draft2019_09)).value.object, "type").?.string);
    try testing.expectEqualStrings("number", member((try r7.lookup(t.scope.base, "#/$defs/slash~1field", .draft2019_09)).value.object, "type").?.string);
    try testing.expectEqualStrings("string", member((try r7.lookup(t.scope.base, "#/$defs/percent%25field", .draft2019_09)).value.object, "type").?.string);
    // An `$id` inside `enum` or an unknown keyword identifies nothing, but a
    // pointer still reaches it, in the scope of the schema around it.
    try testing.expectError(error.UnresolvedReference, r7.lookup(t.scope.base, "http://example.com/not-a-schema.json", .draft2019_09));
    try testing.expectError(error.UnresolvedReference, r7.lookup(t.scope.base, "http://example.com/also-not.json", .draft2019_09));
    const unknown = try r7.lookup(t.scope.base, "#/$defs/E/x-unknown", .draft2019_09);
    try testing.expectEqualStrings("http://example.com/root.json", unknown.scope.base);
    // Names nothing.
    try testing.expectError(error.UnresolvedReference, r7.lookup(t.scope.base, "#/$defs/Z", .draft2019_09));
    try testing.expectError(error.UnresolvedReference, r7.lookup(t.scope.base, "#nowhere", .draft2019_09));
    try testing.expectError(error.Invalid, r7.lookup(t.scope.base, "#/$defs/bad~2", .draft2019_09));
    try testing.expectError(error.Invalid, r7.lookup(t.scope.base, "has space", .draft2019_09));
}

test "draft-07: a fragment `$id` is an anchor, and `$ref` hides a sibling `$id`" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var r: Registry = .init(a, testing.io, null, .{});
    const root = try document(a,
        \\{"$schema": "http://json-schema.org/draft-07/schema#",
        \\ "$id": "http://example.com/seven.json",
        \\ "definitions": {
        \\   "A": {"$id": "#foo", "type": "integer"},
        \\   "B": {"$id": "http://example.com/hidden.json", "$ref": "#/definitions/A"},
        \\   "C": {"items": [{"$id": "item.json"}], "additionalItems": {"$id": "more.json"}}}}
    );
    const t = try r.add(null, root, .draft2020_12);
    try testing.expectEqual(Dialect.draft7, t.scope.dialect);
    try testing.expectEqualStrings("integer", member((try r.lookup(t.scope.base, "#foo", .draft7)).value.object, "type").?.string);
    try testing.expectError(error.UnresolvedReference, r.lookup(t.scope.base, "hidden.json", .draft7));
    _ = try r.lookup(t.scope.base, "item.json", .draft7);
    _ = try r.lookup(t.scope.base, "more.json", .draft7);
    // The `$anchor` keyword is not draft-07's.
    var r2: Registry = .init(a, testing.io, null, .{});
    _ = try r2.add("http://example.com/x.json", try document(a, "{\"$anchor\": \"x\"}"), .draft7);
    try testing.expectError(error.UnresolvedReference, r2.lookup("http://example.com/x.json", "#x", .draft7));
}

test "anchors: each draft's spelling, dynamic anchors, and no two schemas with one name" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var r: Registry = .init(a, testing.io, null, .{});
    const t = try r.add("http://example.com/d.json", try document(a,
        \\{"$defs": {"a": {"$dynamicAnchor": "node", "$anchor": "node"}, "b": {"$anchor": "_under"}}}
    ), .draft2020_12);
    try testing.expect(r.anchors.get("http://example.com/d.json#node").?.dynamic);
    _ = try r.lookup(t.scope.base, "#_under", .draft2020_12);
    const bad = [_]struct { Dialect, []const u8 }{
        .{ .draft2020_12, "{\"$anchor\": \"1a\"}" },
        .{ .draft2020_12, "{\"$anchor\": \"a:b\"}" },
        .{ .draft2019_09, "{\"$anchor\": \"_a\"}" },
        .{ .draft2020_12, "{\"$anchor\": 1}" },
        .{ .draft2020_12, "{\"$defs\": {\"a\": {\"$anchor\": \"x\"}, \"b\": {\"$anchor\": \"x\"}}}" },
        .{ .draft2020_12, "{\"$defs\": {\"a\": {\"$id\": \"http://e.com/a\"}, \"b\": {\"$id\": \"http://e.com/a\"}}}" },
        .{ .draft2020_12, "{\"$id\": 7}" },
    };
    for (bad, 0..) |case, i| {
        var each: Registry = .init(a, testing.io, null, .{});
        const uri_text = try a.print("http://example.com/bad{d}.json", .{i});
        try testing.expectError(error.Invalid, each.add(uri_text, try document(a, case[1]), case[0]));
    }
    var r19: Registry = .init(a, testing.io, null, .{});
    _ = try r19.add("http://example.com/n.json", try document(a, "{\"$anchor\": \"a:b\"}"), .draft2019_09);
    _ = try r19.lookup("http://example.com/n.json", "#a:b", .draft2019_09);
}

test "remote documents come through the loader, once, within the limits" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var table: TableLoader = .{ .documents = &.{
        .{ "http://localhost:1234/name.json", "{\"$defs\": {\"orNull\": {\"anyOf\": [{\"type\": \"null\"}, {\"$ref\": \"#\"}]}}, \"type\": \"string\"}" },
        .{ "http://localhost:1234/folder/inner.json", "{\"$id\": \"http://localhost:1234/elsewhere.json\", \"type\": \"integer\"}" },
        .{ "http://localhost:1234/broken.json", "{\"type\": " },
    } };
    var r: Registry = .init(a, testing.io, &table.loader, .{});
    const t = try r.add("http://localhost:1234/root.json", try document(a, "{\"$ref\": \"name.json#/$defs/orNull\"}"), .draft2020_12);
    const name = try r.lookup(t.scope.base, "name.json#/$defs/orNull", .draft2020_12);
    try testing.expectEqualStrings("http://localhost:1234/name.json", name.scope.base);
    _ = try r.lookup(t.scope.base, "name.json", .draft2020_12);
    try testing.expectEqual(1, table.loads);
    // A document is found by where it was read and by its own `$id`.
    const inner = try r.lookup(t.scope.base, "folder/inner.json", .draft2020_12);
    try testing.expectEqualStrings("http://localhost:1234/elsewhere.json", inner.scope.base);
    try testing.expect((try r.lookup(t.scope.base, "elsewhere.json", .draft2020_12)).value == inner.value);
    try testing.expectError(error.NotFound, r.lookup(t.scope.base, "missing.json", .draft2020_12));
    try testing.expectEqualStrings("http://localhost:1234/missing.json", r.failed);
    try testing.expectError(error.Invalid, r.lookup(t.scope.base, "broken.json", .draft2020_12));
    // With no loader a remote reference is unresolved; the meta-schemas need none.
    var bare: Registry = .init(a, testing.io, null, .{});
    try testing.expectError(error.UnresolvedReference, bare.lookup(default_base, "http://localhost:1234/name.json", .draft2020_12));
    _ = try bare.lookup(default_base, "https://json-schema.org/draft/2020-12/schema#meta", .draft2020_12);
    // Past the limits.
    var small: Registry = .init(a, testing.io, &table.loader, .{ .schema_bytes = .fromRaw(16) });
    try testing.expectError(error.TooLarge, small.lookup(default_base, "http://localhost:1234/name.json", .draft2020_12));
    var few: Registry = .init(a, testing.io, &table.loader, .{ .subschemas = 3 });
    try testing.expectError(error.TooLarge, few.lookup(default_base, "http://localhost:1234/name.json", .draft2020_12));
}

test "any document: each subschema's base, identifiers and anchors, as RFC 3986 and its draft define them" {
    const shakedown = @import("shakedown");
    try shakedown.check(testing.allocator, {}, struct {
        const host = "http://h.example";
        const retrieval = host ++ "/r/doc.json";

        /// A schema position the document has, and what the registry must
        /// make of it.
        const Expect = struct {
            pointer: []const u8,
            /// The path under `host` of the base it sits in.
            base: []const u8,
            /// Its absolute URI, if its `$id` names one.
            identified: ?[]const u8 = null,
            /// `uri#name` for its anchor.
            anchor: ?[]const u8 = null,
        };

        /// An object with an `$id` where no schema is.
        const Opaque = struct { pointer: []const u8, base: []const u8, id: []const u8 };

        const Gen = struct {
            a: std.mem.Allocator,
            s: *shakedown.Source,
            d: Dialect,
            out: std.ArrayList(u8) = .empty,
            schemas: std.ArrayList(Expect) = .empty,
            opaque_ids: std.ArrayList(Opaque) = .empty,
            /// Every URI a schema has, and every `uri#name`: a second is a
            /// duplicate the registry must refuse.
            names: std.StringHashMapUnmanaged(void) = .empty,
            duplicate: bool = false,
            unique: u32 = 0,

            fn write(g: *Gen, comptime f: []const u8, args: anytype) !void {
                try g.out.print(g.a, f, args);
            }

            fn claim(g: *Gen, name: []const u8) !void {
                const entry = try g.names.getOrPut(g.a, name);
                if (entry.found_existing) g.duplicate = true;
            }

            /// RFC 3986 §5.2's merge and dot removal, for the forms the
            /// generator writes: the base path's directory, `..` above it.
            fn directory(path: []const u8) []const u8 {
                return path[0 .. std.mem.findScalarLast(u8, path, '/').? + 1];
            }

            fn parent(dir: []const u8) []const u8 {
                if (dir.len == 1) return dir;
                return dir[0 .. std.mem.findScalarLast(u8, dir[0 .. dir.len - 1], '/').? + 1];
            }

            fn schema(g: *Gen, pointer: []const u8, base: []const u8, depth: u32) anyerror!void {
                const gen = shakedown.gen;
                if (depth > 0 and gen.intRange(g.s, u8, 0, 5) == 0) {
                    try g.write("true", .{});
                    try g.schemas.append(g.a, .{ .pointer = pointer, .base = base });
                    return;
                }
                var e: Expect = .{ .pointer = pointer, .base = base };
                try g.write("{{", .{});
                var first = true;
                const n = gen.intRange(g.s, u8, 0, 3);
                const kind = gen.intRange(g.s, u8, 0, if (g.d == .draft7) 6 else 5);
                const hidden = g.d == .draft7 and kind != 0 and gen.boolean(g.s);
                if (hidden) {
                    try g.write("\"$ref\": \"#\"", .{});
                    first = false;
                }
                if (kind != 0) {
                    if (!first) try g.write(", ", .{});
                    first = false;
                    const dir = directory(base);
                    const id_and_path: [2][]const u8 = switch (kind) {
                        1 => .{ try g.a.print("f{d}.json", .{n}), try g.a.print("{s}f{d}.json", .{ dir, n }) },
                        2 => .{ try g.a.print("d{d}/f{d}.json", .{ n, n }), try g.a.print("{s}d{d}/f{d}.json", .{ dir, n, n }) },
                        3 => .{ try g.a.print("../f{d}.json", .{n}), try g.a.print("{s}f{d}.json", .{ parent(dir), n }) },
                        4 => .{ try g.a.print(host ++ "/a{d}/f{d}.json", .{ n, n }), try g.a.print("/a{d}/f{d}.json", .{ n, n }) },
                        5 => .{ try g.a.print("d{d}/", .{n}), try g.a.print("{s}d{d}/", .{ dir, n }) },
                        // draft-07's plain-name fragment, an anchor.
                        else => .{ try g.a.print("#n{d}", .{n}), base },
                    };
                    try g.write("\"$id\": \"{s}\"", .{id_and_path[0]});
                    if (!hidden) {
                        if (kind == 6) {
                            e.anchor = try g.a.print(host ++ "{s}#n{d}", .{ base, n });
                            try g.claim(e.anchor.?);
                        } else {
                            e.base = id_and_path[1];
                            e.identified = try g.a.print(host ++ "{s}", .{e.base});
                            try g.claim(e.identified.?);
                        }
                    }
                }
                if (g.d != .draft7 and gen.intRange(g.s, u8, 0, 3) == 0) {
                    if (!first) try g.write(", ", .{});
                    first = false;
                    const name: []const u8 = if (gen.boolean(g.s)) "a" else "b";
                    try g.write("\"$anchor\": \"{s}\"", .{name});
                    e.anchor = try g.a.print(host ++ "{s}#{s}", .{ e.base, name });
                    try g.claim(e.anchor.?);
                }
                try g.schemas.append(g.a, e);
                // A draft-07 `$ref`'s siblings are not read; the generator
                // writes none, rather than guess at schemas under them.
                if (depth < 3 and !hidden) {
                    const keywords = [_][]const u8{ "properties", "allOf", "not", "items", "$defs", "prefixItems", "enum", "const", "x-unknown" };
                    for (keywords) |keyword| {
                        if (gen.intRange(g.s, u8, 0, 3) != 0) continue;
                        if (!first) try g.write(", ", .{});
                        first = false;
                        try g.write("\"{s}\": ", .{keyword});
                        const at = try g.a.print("{s}/{s}", .{ pointer, keyword });
                        const holds = schemaKeyword(g.d, keyword);
                        if (!holds) {
                            try g.opaqueValue(keyword, at, e.base);
                        } else if (std.mem.eql(u8, keyword, "properties") or std.mem.eql(u8, keyword, "$defs")) {
                            try g.write("{{\"k0\": ", .{});
                            try g.schema(try g.a.print("{s}/k0", .{at}), e.base, depth + 1);
                            try g.write(", \"k1\": ", .{});
                            try g.schema(try g.a.print("{s}/k1", .{at}), e.base, depth + 1);
                            try g.write("}}", .{});
                        } else if (std.mem.eql(u8, keyword, "allOf") or std.mem.eql(u8, keyword, "prefixItems")) {
                            try g.write("[", .{});
                            try g.schema(try g.a.print("{s}/0", .{at}), e.base, depth + 1);
                            try g.write(", ", .{});
                            try g.schema(try g.a.print("{s}/1", .{at}), e.base, depth + 1);
                            try g.write("]", .{});
                        } else {
                            try g.schema(at, e.base, depth + 1);
                        }
                    }
                }
                try g.write("}}", .{});
            }

            /// A value with an object holding an `$id` where no schema is.
            fn opaqueValue(g: *Gen, keyword: []const u8, at: []const u8, base: []const u8) !void {
                g.unique += 1;
                const id = try g.a.print(host ++ "/never{d}.json", .{g.unique});
                const array = std.mem.eql(u8, keyword, "enum") or std.mem.eql(u8, keyword, "prefixItems");
                const map = std.mem.eql(u8, keyword, "$defs");
                const pointer = if (array) try g.a.print("{s}/0", .{at}) else if (map) try g.a.print("{s}/k0", .{at}) else at;
                if (array) try g.write("[", .{}) else if (map) try g.write("{{\"k0\": ", .{});
                try g.write("{{\"$id\": \"{s}\", \"type\": \"string\"}}", .{id});
                if (array) try g.write("]", .{}) else if (map) try g.write("}}", .{});
                try g.opaque_ids.append(g.a, .{ .pointer = pointer, .base = base, .id = id });
            }
        };

        /// Whether `keyword`'s value holds schemas in `d`, as each draft's
        /// meta-schema says.
        fn schemaKeyword(d: Dialect, keyword: []const u8) bool {
            if (std.mem.eql(u8, keyword, "enum") or std.mem.eql(u8, keyword, "const") or std.mem.eql(u8, keyword, "x-unknown")) return false;
            if (std.mem.eql(u8, keyword, "$defs")) return d != .draft7;
            if (std.mem.eql(u8, keyword, "prefixItems")) return d == .draft2020_12;
            return true;
        }

        fn one(_: void, case: *shakedown.Case) anyerror!void {
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const d = std.enums.values(Dialect)[shakedown.gen.intRange(case.source, usize, 0, 2)];
            var g: Gen = .{ .a = a, .s = case.source, .d = d };
            try g.claim(retrieval);
            try g.schema("", "/r/doc.json", 0);
            const root = try document(a, g.out.items);
            var r: Registry = .init(a, testing.io, null, .{});
            const added = r.add(retrieval, root, d);
            if (g.duplicate) return testing.expectError(error.Invalid, added);
            _ = try added;
            // Each schema position: its base by RFC 3986 through every `$id`
            // above it, and found by its URI and its anchor as by its pointer.
            for (g.schemas.items) |e| {
                const at = try r.lookup(retrieval, try a.print("#{s}", .{e.pointer}), d);
                try testing.expectEqualStrings(try a.print(host ++ "{s}", .{e.base}), at.scope.base);
                if (e.identified) |u| {
                    const by = try r.lookup(retrieval, u, d);
                    try testing.expect(by.value == at.value);
                    try testing.expectEqualStrings(u, by.scope.base);
                }
                if (e.anchor) |name| try testing.expect((try r.lookup(retrieval, name, d)).value == at.value);
            }
            // An `$id` where no schema is identifies nothing; a pointer still
            // reaches it, in the base of the schema around it.
            for (g.opaque_ids.items) |o| {
                try testing.expectError(error.UnresolvedReference, r.lookup(retrieval, o.id, d));
                const at = try r.lookup(retrieval, try a.print("#{s}", .{o.pointer}), d);
                try testing.expectEqualStrings(try a.print(host ++ "{s}", .{o.base}), at.scope.base);
            }
            // Every schema counted against `Limits.subschemas`, and refused
            // past it.
            try testing.expectEqual(g.schemas.items.len, r.subschemas);
            var few: Registry = .init(a, testing.io, null, .{ .subschemas = g.schemas.items.len - 1 });
            try testing.expectError(error.TooLarge, few.add(retrieval, root, d));
        }
    }.one, .{ .cases = 3000, .seed = 0x5c4e });
}
