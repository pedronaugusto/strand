//! Compiling a schema into a `Program`. The registry reads every document and
//! gives each subschema its base URI and dialect; the compiler turns each
//! subschema it reaches into a node, by a worklist and never by recursion,
//! each keyword into an instruction as its draft and its meta-schema's
//! vocabularies read it. Then it refuses what evaluation could not finish: a
//! cycle of references that applies a schema again where it already is,
//! reading none of the instance, is `ReferenceCycle`, and a chain of such
//! applications longer than `Limits.reference_chain` is `TooLarge`.
const std = @import("std");
const strand = @import("strand");
const Limits = @import("Limits.zig");
const Decimal = @import("Decimal.zig");
const Loader = @import("Loader.zig");
const canonical = @import("canonical.zig");
const dialect = @import("dialect.zig");
const registry = @import("registry.zig");
const Program = @import("Program.zig");

const Value = strand.json.Value;
const Member = strand.core.Pair([]const u8, Value);
const Node = Program.Node;
const Op = Program.Op;
const Keyword = dialect.Keyword;
const Dialect = dialect.Dialect;
const Registry = registry.Registry;
const Scope = registry.Scope;

pub const Options = struct {
    /// The draft of a document with no `$schema`: 2020-12 when null.
    dialect: ?Dialect = null,
    /// Where remote documents come from; null refuses a reference to one.
    loader: ?*Loader = null,
    /// The URI the document was read from, its base when it has no `$id`.
    retrieval: ?[]const u8 = null,
    limits: Limits = .{},
    /// Where a schema failed to compile, and why.
    diagnostics: ?*Diagnostic = null,
};

pub const Error = error{
    OutOfMemory,
    /// Not a schema its draft allows: a keyword's value of the wrong kind,
    /// a malformed reference or identifier, a document that is not JSON.
    Invalid,
    /// A `$schema` naming a meta-schema strand neither has nor can load.
    UnknownDialect,
    /// A meta-schema requiring a vocabulary strand does not know.
    UnsupportedVocabulary,
    /// A reference to no schema.
    UnresolvedReference,
    /// References that apply a schema again where it already is.
    ReferenceCycle,
    /// Past one of `Limits`' bounds on a schema.
    TooLarge,
} || Loader.LoadError;

/// Where compiling stopped: the absolute location of the keyword (its
/// resource's URI and the JSON Pointer to it), cut to fit, and what was
/// wrong there.
pub const Diagnostic = struct {
    what: []const u8 = "",
    buffer: [512]u8 = undefined,
    len: usize = 0,

    pub fn location(d: *const Diagnostic) []const u8 {
        return d.buffer[0..d.len];
    }

    fn set(d: *Diagnostic, what: []const u8, parts: []const []const u8) void {
        d.what = what;
        d.len = 0;
        for (parts) |part| {
            const n = @min(part.len, d.buffer.len - d.len);
            @memcpy(d.buffer[d.len..][0..n], part[0..n]);
            d.len += n;
        }
    }
};

/// The program compiled from `root`, read from `options.retrieval`, its
/// documents and the program's memory on `arena`.
pub fn compile(arena: std.mem.Allocator, io: std.Io, root: *const Value, options: Options) Error!Program {
    var r: Registry = .init(arena, io, options.loader, options.limits);
    var c: Compiler = .{ .arena = arena, .registry = &r, .limits = options.limits };
    return c.run(root, options) catch |err| {
        if (options.diagnostics) |d| c.diagnose(d, err);
        return err;
    };
}

const Compiler = struct {
    arena: std.mem.Allocator,
    registry: *Registry,
    limits: Limits,
    nodes: std.ArrayList(Program.NodeInfo) = .empty,
    instructions: std.ArrayList(Program.Instruction) = .empty,
    /// Each schema compiled, its node.
    memo: std.AutoHashMapUnmanaged(*const Value, Node) = .empty,
    /// Where each node's schema sits.
    scopes: std.ArrayList(Scope) = .empty,
    /// Nodes whose instructions are still to be compiled.
    queue: std.ArrayList(Node) = .empty,
    /// The anchor names `$dynamicRef`s search for.
    dynamic_names: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Whether a `$recursiveRef` searches.
    recursive: bool = false,
    /// What is being compiled, for a diagnostic.
    at: ?*const Value = null,
    keyword: ?Keyword = null,
    /// The node a cycle or a chain was found at.
    culprit: ?Node = null,

    fn run(c: *Compiler, root: *const Value, options: Options) Error!Program {
        const start = try c.registry.add(options.retrieval, root, options.dialect orelse .draft2020_12);
        const first = try c.nodeFor(start.value, start.scope);
        try c.drain();
        // The schemas a dynamic search may land on, each compiled.
        while (true) {
            const before = c.nodes.items.len;
            try c.dynamicCandidates();
            try c.drain();
            if (c.nodes.items.len == before) break;
        }
        try c.checkCycles();
        return .{ .nodes = c.nodes.items, .instructions = c.instructions.items, .root = first };
    }

    fn drain(c: *Compiler) Error!void {
        while (c.queue.pop()) |n| try c.compileNode(n);
    }

    /// The node for the schema `value`, made and queued the first time;
    /// `around` is its scope where the registry read none (a schema a
    /// pointer reached somewhere no schema is expected).
    fn nodeFor(c: *Compiler, value: *const Value, around: Scope) Error!Node {
        if (c.memo.get(value)) |n| return n;
        if (c.nodes.items.len >= c.limits.subschemas) return error.TooLarge;
        const n: Node = @fromBackingInt(@as(u32, @intCast(c.nodes.items.len)));
        const scope = c.registry.scopes.get(value) orelse around;
        try c.nodes.append(c.arena, .{ .verdict = .keywords, .source = value, .base = scope.base });
        try c.scopes.append(c.arena, scope);
        try c.memo.put(c.arena, value, n);
        try c.queue.append(c.arena, n);
        return n;
    }

    fn compileNode(c: *Compiler, n: Node) Error!void {
        const info = &c.nodes.items[n.raw()];
        const scope = c.scopes.items[n.raw()];
        const source = info.source;
        c.at = source;
        c.keyword = null;
        const members = switch (source.*) {
            .boolean => |b| {
                info.verdict = if (b) .any else .none;
                return;
            },
            .object => |m| m,
            else => return error.Invalid,
        };
        var present: std.EnumArray(Keyword, ?*const Value) = .initFill(null);
        // draft-07's `$ref` hides every sibling.
        const hiding = scope.dialect == .draft7 and member(members, "$ref") != null;
        for (members) |*m| {
            const k, const vocabulary = dialect.keyword(scope.dialect, m.key) orelse continue;
            if (hiding and k != .ref) continue;
            if (vocabulary != .core and !scope.vocabularies.contains(vocabulary)) continue;
            present.set(k, &m.value);
        }
        var ops: std.ArrayList(Program.Instruction) = .empty;
        try c.keywords(&present, scope, &ops);
        std.sort.insertion(Program.Instruction, ops.items, {}, cheaper);
        // Compiling the keywords made nodes, which may have moved the list.
        const done = &c.nodes.items[n.raw()];
        done.first = @intCast(c.instructions.items.len);
        done.count = @intCast(ops.items.len);
        try c.instructions.appendSlice(c.arena, ops.items);
    }

    fn cheaper(_: void, a: Program.Instruction, b: Program.Instruction) bool {
        return a.op.cost() < b.op.cost();
    }

    fn emit(c: *Compiler, ops: *std.ArrayList(Program.Instruction), k: Keyword, op: Op) Error!void {
        try ops.append(c.arena, .{ .keyword = k, .op = op });
    }

    /// The instructions of a schema's keywords, `present` holding each one's
    /// value.
    fn keywords(c: *Compiler, present: *std.EnumArray(Keyword, ?*const Value), scope: Scope, ops: *std.ArrayList(Program.Instruction)) Error!void {
        const d = scope.dialect;
        var it = present.iterator();
        while (it.next()) |entry| {
            const v = entry.value.* orelse continue;
            const k = entry.key;
            c.keyword = k;
            switch (k) {
                .type => try c.emit(ops, k, .{ .type = try types(v) }),
                .@"const" => try c.emit(ops, k, .{ .@"const" = try c.encoding(v) }),
                .@"enum" => {
                    const items = try array(v);
                    const out = try c.arena.alloc([]const u8, items.len);
                    for (items, out) |*item, *o| o.* = try c.encoding(item);
                    try c.emit(ops, k, .{ .@"enum" = out });
                },
                .minimum => try c.emit(ops, k, .{ .minimum = try c.decimal(v) }),
                .exclusive_minimum => try c.emit(ops, k, .{ .exclusive_minimum = try c.decimal(v) }),
                .maximum => try c.emit(ops, k, .{ .maximum = try c.decimal(v) }),
                .exclusive_maximum => try c.emit(ops, k, .{ .exclusive_maximum = try c.decimal(v) }),
                .multiple_of => {
                    const divisor = try c.decimal(v);
                    if (divisor.isZero() or divisor.negative) return error.Invalid;
                    try c.emit(ops, k, .{ .multiple_of = divisor });
                },
                .min_length => try c.emit(ops, k, .{ .min_length = try c.count(v) }),
                .max_length => try c.emit(ops, k, .{ .max_length = try c.count(v) }),
                .pattern => try c.emit(ops, k, .{ .pattern = try string(v) }),
                .format => try c.emit(ops, k, .{ .format = try string(v) }),
                .min_items => try c.emit(ops, k, .{ .min_items = try c.count(v) }),
                .max_items => try c.emit(ops, k, .{ .max_items = try c.count(v) }),
                .unique_items => if (try boolean(v)) try c.emit(ops, k, .unique_items),
                .min_properties => try c.emit(ops, k, .{ .min_properties = try c.count(v) }),
                .max_properties => try c.emit(ops, k, .{ .max_properties = try c.count(v) }),
                .required => try c.emit(ops, k, .{ .required = try strings(c.arena, v) }),
                .properties => try c.emit(ops, k, .{ .properties = try c.propertyList(v, scope) }),
                .pattern_properties => try c.emit(ops, k, .{ .pattern_properties = try c.patternList(v, scope) }),
                .additional_properties => {
                    var names: []const []const u8 = &.{};
                    var patterns: []const []const u8 = &.{};
                    if (present.get(.properties)) |p| names = try keys(c.arena, p);
                    if (present.get(.pattern_properties)) |p| patterns = try keys(c.arena, p);
                    try c.emit(ops, k, .{ .additional_properties = .{ .node = try c.schema(v, scope), .names = names, .patterns = patterns } });
                },
                .property_names => try c.emit(ops, k, .{ .property_names = try c.schema(v, scope) }),
                .dependent_required => {
                    const entries = try object(v);
                    const out = try c.arena.alloc(Program.Dependency, entries.len);
                    for (entries, out) |e, *o| o.* = .{ .name = e.key, .required = try strings(c.arena, &e.value) };
                    try c.emit(ops, k, .{ .dependent_required = out });
                },
                .dependent_schemas => try c.emit(ops, k, .{ .dependent_schemas = try c.propertyList(v, scope) }),
                .dependencies => try c.dependencies(ops, v, scope),
                .all_of => try c.emit(ops, k, .{ .all_of = try c.schemaList(v, scope) }),
                .any_of => try c.emit(ops, k, .{ .any_of = try c.schemaList(v, scope) }),
                .one_of => try c.emit(ops, k, .{ .one_of = try c.schemaList(v, scope) }),
                .not => try c.emit(ops, k, .{ .not = try c.schema(v, scope) }),
                .@"if" => {
                    const then = if (present.get(.then)) |t| try c.schema(t, scope) else null;
                    const otherwise = if (present.get(.@"else")) |e| try c.schema(e, scope) else null;
                    try c.emit(ops, k, .{ .conditional = .{ .@"if" = try c.schema(v, scope), .then = then, .@"else" = otherwise } });
                },
                // Read with `if`; alone, they do nothing.
                .then, .@"else" => {},
                .prefix_items => try c.emit(ops, k, .{ .prefix_items = try c.schemaList(v, scope) }),
                .items => switch (d) {
                    .draft2020_12 => {
                        const from: u64 = if (present.get(.prefix_items)) |p| (try array(p)).len else 0;
                        try c.emit(ops, k, .{ .items = .{ .from = from, .node = try c.schema(v, scope) } });
                    },
                    .draft7, .draft2019_09 => if (v.* == .array) {
                        try c.emit(ops, k, .{ .prefix_items = try c.schemaList(v, scope) });
                    } else {
                        try c.emit(ops, k, .{ .items = .{ .from = 0, .node = try c.schema(v, scope) } });
                    },
                },
                // Only after an array `items`; otherwise it does nothing.
                .additional_items => if (present.get(.items)) |items| if (items.* == .array) {
                    try c.emit(ops, k, .{ .items = .{ .from = items.array.len, .node = try c.schema(v, scope) } });
                },
                .contains => {
                    var min: u64 = 1;
                    var max: ?u64 = null;
                    if (present.get(.min_contains)) |m| min = try c.count(m);
                    if (present.get(.max_contains)) |m| max = try c.count(m);
                    c.keyword = k;
                    try c.emit(ops, k, .{ .contains = .{ .node = try c.schema(v, scope), .min = min, .max = max } });
                },
                // Read with `contains`; alone, they do nothing.
                .min_contains, .max_contains => _ = try c.count(v),
                .ref => try c.emit(ops, k, .{ .ref = try c.reference(scope, try string(v)) }),
                .dynamic_ref => {
                    const text = try string(v);
                    const target = try c.reference(scope, text);
                    // It searches the dynamic scope only when the schema it
                    // names statically is a dynamic anchor of that name.
                    const anchor = try c.registry.dynamicAnchorName(scope.base, text);
                    if (anchor) |name| try c.dynamic_names.put(c.arena, name, {});
                    try c.emit(ops, k, .{ .dynamic_ref = .{ .node = target, .anchor = anchor } });
                },
                .recursive_ref => {
                    const target = try c.reference(scope, try string(v));
                    const anchored = c.scopes.items[target.raw()].recursive_anchor;
                    if (anchored) c.recursive = true;
                    try c.emit(ops, k, .{ .recursive_ref = .{ .node = target, .anchored = anchored } });
                },
                .unevaluated_items => try c.emit(ops, k, .{ .unevaluated_items = try c.schema(v, scope) }),
                .unevaluated_properties => try c.emit(ops, k, .{ .unevaluated_properties = try c.schema(v, scope) }),
                // Read by the registry, or annotations.
                .id, .schema, .anchor, .dynamic_anchor, .recursive_anchor, .vocabulary, .comment, .defs, .definitions => {},
                .title, .description, .default, .deprecated, .read_only, .write_only, .examples => {},
                .content_encoding, .content_media_type, .content_schema => {},
            }
        }
        c.keyword = null;
    }

    /// draft-07's `dependencies`: names required, or a schema applied, when
    /// a member is present.
    fn dependencies(c: *Compiler, ops: *std.ArrayList(Program.Instruction), v: *const Value, scope: Scope) Error!void {
        const entries = try object(v);
        var required: std.ArrayList(Program.Dependency) = .empty;
        var schemas: std.ArrayList(Program.Property) = .empty;
        for (entries) |*e| switch (e.value) {
            .array => try required.append(c.arena, .{ .name = e.key, .required = try strings(c.arena, &e.value) }),
            else => try schemas.append(c.arena, .{ .name = e.key, .node = try c.schema(&e.value, scope) }),
        };
        if (required.items.len > 0) try c.emit(ops, .dependencies, .{ .dependent_required = required.items });
        if (schemas.items.len > 0) try c.emit(ops, .dependencies, .{ .dependent_schemas = schemas.items });
    }

    /// A subschema in a keyword's value.
    fn schema(c: *Compiler, v: *const Value, around: Scope) Error!Node {
        switch (v.*) {
            .object, .boolean => {},
            else => return error.Invalid,
        }
        return c.nodeFor(v, around);
    }

    fn schemaList(c: *Compiler, v: *const Value, around: Scope) Error![]const Node {
        const items = try array(v);
        if (items.len == 0) return error.Invalid;
        const out = try c.arena.alloc(Node, items.len);
        for (items, out) |*item, *o| o.* = try c.schema(item, around);
        return out;
    }

    fn propertyList(c: *Compiler, v: *const Value, around: Scope) Error![]const Program.Property {
        const entries = try object(v);
        const out = try c.arena.alloc(Program.Property, entries.len);
        for (entries, out) |*e, *o| o.* = .{ .name = e.key, .node = try c.schema(&e.value, around) };
        return out;
    }

    fn patternList(c: *Compiler, v: *const Value, around: Scope) Error![]const Program.PatternProperty {
        const entries = try object(v);
        const out = try c.arena.alloc(Program.PatternProperty, entries.len);
        for (entries, out) |*e, *o| o.* = .{ .pattern = e.key, .node = try c.schema(&e.value, around) };
        return out;
    }

    /// The node a reference names, resolved against `scope`'s base.
    fn reference(c: *Compiler, scope: Scope, text: []const u8) Error!Node {
        const target = try c.registry.lookup(scope.base, text, scope.dialect);
        switch (target.value.*) {
            .object, .boolean => {},
            else => return error.Invalid,
        }
        return c.nodeFor(target.value, target.scope);
    }

    /// Compiles every schema a dynamic search could land on: each dynamic
    /// anchor of a name a `$dynamicRef` searches for, and each resource root
    /// marked `$recursiveAnchor`.
    fn dynamicCandidates(c: *Compiler) Error!void {
        var anchors = c.registry.anchors.iterator();
        while (anchors.next()) |entry| {
            if (!entry.value_ptr.dynamic) continue;
            const key = entry.key_ptr.*;
            const name = key[(std.mem.findScalarLast(u8, key, '#') orelse continue) + 1 ..];
            if (!c.dynamic_names.contains(name)) continue;
            const value = entry.value_ptr.value;
            _ = try c.nodeFor(value, c.registry.targetOf(value).scope);
        }
        if (!c.recursive) return;
        var scopes = c.registry.scopes.iterator();
        while (scopes.next()) |entry| {
            if (entry.value_ptr.recursive_anchor) _ = try c.nodeFor(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    /// The nodes a node may apply where it already is: its in-place
    /// instructions' nodes, and for a searching reference every schema the
    /// search could land on.
    fn inPlace(c: *Compiler, n: Node, out: *std.ArrayList(Node)) Error!void {
        out.clearRetainingCapacity();
        const info = c.nodes.items[n.raw()];
        for (c.instructions.items[info.first..][0..info.count]) |ins| {
            try ins.op.inPlace(out, c.arena);
            switch (ins.op) {
                .dynamic_ref => |dr| if (dr.anchor) |name| for (c.nodes.items, 0..) |other, i| {
                    if (c.isDynamicAnchor(other.source, name)) try out.append(c.arena, @fromBackingInt(@as(u32, @intCast(i))));
                },
                .recursive_ref => |rr| if (rr.anchored) for (c.scopes.items, 0..) |s, i| {
                    if (s.recursive_anchor) try out.append(c.arena, @fromBackingInt(@as(u32, @intCast(i))));
                },
                else => {},
            }
        }
    }

    fn isDynamicAnchor(_: *Compiler, value: *const Value, name: []const u8) bool {
        if (value.* != .object) return false;
        const a = member(value.object, "$dynamicAnchor") orelse return false;
        return a.* == .string and std.mem.eql(u8, a.string, name);
    }

    /// Refuses a cycle of in-place applications, and a chain of them past
    /// `Limits.reference_chain`: a depth-first walk with no recursion, each
    /// node's chain the longest below it.
    fn checkCycles(c: *Compiler) Error!void {
        const total = c.nodes.items.len;
        const State = enum(u2) { unseen, open, done };
        const state = try c.arena.alloc(State, total);
        @memset(state, .unseen);
        const chain = try c.arena.alloc(usize, total);
        @memset(chain, 0);
        const children = try c.arena.alloc([]const Node, total);
        var scratch: std.ArrayList(Node) = .empty;
        for (0..total) |i| {
            try c.inPlace(@fromBackingInt(@as(u32, @intCast(i))), &scratch);
            children[i] = try c.arena.dupe(Node, scratch.items);
        }
        const Frame = struct { node: u32, next: usize };
        var stack: std.ArrayList(Frame) = .empty;
        for (0..total) |start| {
            if (state[start] != .unseen) continue;
            try stack.append(c.arena, .{ .node = @intCast(start), .next = 0 });
            state[start] = .open;
            while (stack.items.len > 0) {
                const top = &stack.items[stack.items.len - 1];
                const kids = children[top.node];
                if (top.next < kids.len) {
                    const child = kids[top.next].raw();
                    top.next += 1;
                    switch (state[child]) {
                        .open => {
                            c.culprit = @fromBackingInt(child);
                            return error.ReferenceCycle;
                        },
                        .done => {},
                        .unseen => {
                            state[child] = .open;
                            try stack.append(c.arena, .{ .node = child, .next = 0 });
                        },
                    }
                    continue;
                }
                var longest: usize = 0;
                for (kids) |k| longest = @max(longest, chain[k.raw()]);
                chain[top.node] = longest + 1;
                if (chain[top.node] > c.limits.reference_chain) {
                    c.culprit = @fromBackingInt(top.node);
                    return error.TooLarge;
                }
                state[top.node] = .done;
                _ = stack.pop();
            }
        }
    }

    /// The canonical encoding of an `enum` or `const` value.
    fn encoding(c: *Compiler, v: *const Value) Error![]const u8 {
        return canonical.encodeAlloc(c.arena, v.*, c.limits.exponent);
    }

    fn decimal(c: *Compiler, v: *const Value) Error!Decimal {
        const text = switch (v.*) {
            .number => |t| t,
            else => return error.Invalid,
        };
        const buffer = try c.arena.alloc(u8, text.len);
        return Decimal.parse(text, buffer, c.limits.exponent) catch |err| switch (err) {
            error.Invalid => error.Invalid,
            error.TooLarge => error.TooLarge,
        };
    }

    /// A non-negative integer (`2.0` is one), saturating at `u64`'s largest.
    fn count(c: *Compiler, v: *const Value) Error!u64 {
        const d = try c.decimal(v);
        if (d.isZero()) return 0;
        if (d.negative or !d.isInteger()) return error.Invalid;
        if (d.digits.len + @as(usize, @intCast(d.exponent)) > 20) return std.math.maxInt(u64);
        var n: u128 = 0;
        for (d.digits) |digit| n = n * 10 + (digit - '0');
        for (0..@intCast(d.exponent)) |_| n *= 10;
        return std.math.cast(u64, n) orelse std.math.maxInt(u64);
    }

    /// Fills `d` with where `err` was met.
    fn diagnose(c: *Compiler, d: *Diagnostic, err: Error) void {
        const what: []const u8 = switch (err) {
            error.Invalid => "not a schema its draft allows",
            error.UnknownDialect => "a $schema naming no meta-schema strand has or can load",
            error.UnsupportedVocabulary => "a required vocabulary strand does not know",
            error.UnresolvedReference => "a reference to no schema",
            error.ReferenceCycle => "references that apply a schema again where it already is",
            error.TooLarge => "past a limit",
            error.OutOfMemory => "out of memory",
            else => "the loader failed",
        };
        const at = if (c.culprit) |n| c.nodes.items[n.raw()].source else c.at orelse {
            d.set(what, &.{c.registry.failed});
            return;
        };
        const scope = c.registry.scopes.get(at) orelse {
            d.set(what, &.{c.registry.failed});
            return;
        };
        // A reference that failed names the URI it was reading.
        if (err != error.Invalid and err != error.ReferenceCycle and err != error.TooLarge and c.registry.failed.len > 0) {
            d.set(what, &.{c.registry.failed});
            return;
        }
        const pointer = c.registry.pointerOf(c.arena, at) catch "";
        const keyword_text: []const u8 = if (c.culprit == null) if (c.keyword) |k| k.name() else "" else "";
        d.set(what, &.{ scope.base, "#", pointer, if (keyword_text.len > 0) "/" else "", keyword_text });
    }
};

fn member(members: []const Member, name: []const u8) ?*const Value {
    for (members) |*m| if (std.mem.eql(u8, m.key, name)) return &m.value;
    return null;
}

fn types(v: *const Value) Error!Program.Types {
    var set: Program.Types = .empty;
    switch (v.*) {
        .string => |s| set.insert(try typeName(s)),
        .array => |items| for (items) |item| switch (item) {
            .string => |s| set.insert(try typeName(s)),
            else => return error.Invalid,
        },
        else => return error.Invalid,
    }
    return set;
}

fn typeName(s: []const u8) Error!Program.Type {
    return std.meta.stringToEnum(Program.Type, s) orelse error.Invalid;
}

fn array(v: *const Value) Error![]const Value {
    return switch (v.*) {
        .array => |items| items,
        else => error.Invalid,
    };
}

fn object(v: *const Value) Error![]const Member {
    return switch (v.*) {
        .object => |members| members,
        else => error.Invalid,
    };
}

fn string(v: *const Value) Error![]const u8 {
    return switch (v.*) {
        .string => |s| s,
        else => error.Invalid,
    };
}

fn boolean(v: *const Value) Error!bool {
    return switch (v.*) {
        .boolean => |b| b,
        else => error.Invalid,
    };
}

fn strings(arena: std.mem.Allocator, v: *const Value) Error![]const []const u8 {
    const items = try array(v);
    const out = try arena.alloc([]const u8, items.len);
    for (items, out) |*item, *o| o.* = try string(item);
    return out;
}

/// An object's names: the members `additionalProperties` leaves alone.
fn keys(arena: std.mem.Allocator, v: *const Value) Error![]const []const u8 {
    const entries = try object(v);
    const out = try arena.alloc([]const u8, entries.len);
    for (entries, out) |e, *o| o.* = e.key;
    return out;
}

const testing = std.testing;

fn compiled(arena: std.mem.Allocator, text: []const u8, options: Options) Error!Program {
    const root = try arena.create(Value);
    root.* = strand.json.parseLeaky(Value, arena, text, .{}) catch return error.Invalid;
    return compile(arena, testing.io, root, options);
}

/// The keywords of `n`'s instructions, in the order they run.
fn keywordsOf(arena: std.mem.Allocator, p: *const Program, n: Node) ![]const Keyword {
    const list = p.instructionsOf(n);
    const out = try arena.alloc(Keyword, list.len);
    for (list, out) |ins, *o| o.* = ins.keyword;
    return out;
}

test "keywords compile to instructions, cheapest first, what depends on siblings last" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const p = try compiled(a,
        \\{"unevaluatedProperties": false, "properties": {"a": true}, "allOf": [{"type": "string"}],
        \\ "type": "object", "required": ["a"], "enum": [{"a": 1}], "title": "ignored", "x-unknown": 1}
    , .{});
    try testing.expectEqualSlices(Keyword, &.{ .type, .required, .@"enum", .properties, .all_of, .unevaluated_properties }, try keywordsOf(a, &p, p.root));
    // `true` and `false` decide alone.
    const props = p.instructionsOf(p.root)[3].op.properties;
    try testing.expectEqual(.any, p.node(props[0].node).verdict);
}

test "each draft's keywords: draft-07's $ref hides its siblings, items as an array, dependencies" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const seven = try compiled(a,
        \\{"$schema": "http://json-schema.org/draft-07/schema#",
        \\ "definitions": {"s": {"type": "string"}},
        \\ "properties": {
        \\   "r": {"$ref": "#/definitions/s", "minLength": 3},
        \\   "t": {"items": [true, false], "additionalItems": {"type": "null"}},
        \\   "d": {"dependencies": {"a": ["b"], "c": {"required": ["e"]}}},
        \\   "x": {"$defs": {"no": 1}, "prefixItems": [true], "dependentRequired": {"a": ["b"]}}}}
    , .{});
    const props = seven.instructionsOf(seven.root)[0].op.properties;
    try testing.expectEqualSlices(Keyword, &.{.ref}, try keywordsOf(a, &seven, props[0].node));
    const t = seven.instructionsOf(props[1].node);
    try testing.expectEqual(2, t.len);
    try testing.expectEqual(2, t[0].op.prefix_items.len);
    try testing.expectEqual(2, t[1].op.items.from);
    const d = seven.instructionsOf(props[2].node);
    try testing.expectEqual(1, d[0].op.dependent_required.len);
    try testing.expectEqual(1, d[1].op.dependent_schemas.len);
    // 2019-09 and 2020-12 keywords are unknown to draft-07.
    try testing.expectEqual(0, seven.instructionsOf(props[3].node).len);
    // 2020-12: `items` after `prefixItems`, `additionalItems` unknown.
    const twenty = try compiled(a,
        \\{"prefixItems": [true, true, true], "items": false, "additionalItems": false, "contains": true, "minContains": 2, "maxContains": 4}
    , .{});
    const ops = twenty.instructionsOf(twenty.root);
    try testing.expectEqual(3, ops.len);
    for (ops) |ins| switch (ins.op) {
        .items => |it| try testing.expectEqual(3, it.from),
        .contains => |ct| {
            try testing.expectEqual(2, ct.min);
            try testing.expectEqual(4, ct.max.?);
        },
        .prefix_items => {},
        else => return error.TestUnexpectedResult,
    };
}

test "numbers stay exact, counts may be written 2.0, and a bound past u64 saturates" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const p = try compiled(a,
        \\{"minimum": 1e-400, "maxLength": 2.0, "minItems": 1e30, "multipleOf": 0.01}
    , .{});
    for (p.instructionsOf(p.root)) |ins| switch (ins.op) {
        .minimum => |m| try testing.expectEqual(-400, m.exponent),
        .max_length => |n| try testing.expectEqual(2, n),
        .min_items => |n| try testing.expectEqual(std.math.maxInt(u64), n),
        .multiple_of => |m| try testing.expectEqual(-2, m.exponent),
        else => return error.TestUnexpectedResult,
    };
    const refused = [_][]const u8{
        "{\"minLength\": -1}",  "{\"minLength\": 1.5}",  "{\"multipleOf\": 0}",
        "{\"multipleOf\": -2}", "{\"type\": \"thing\"}", "{\"type\": 5}",
        "{\"required\": [1]}",  "{\"allOf\": []}",       "{\"properties\": {\"a\": 1}}",
        "{\"minimum\": \"1\"}", "{\"uniqueItems\": 1}",  "{\"$ref\": 1}",
        "{\"not\": []}",        "{\"enum\": 1}",
    };
    for (refused) |text| try testing.expectError(error.Invalid, compiled(a, text, .{}));
    try testing.expectError(error.TooLarge, compiled(a, "{\"maximum\": 1e5000}", .{}));
}

test "references resolve to nodes, recursion through the instance compiles, and a cycle in place is refused" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    // A tree: each node's children are read before it applies again.
    const tree = try compiled(a,
        \\{"$defs": {"node": {"properties": {"children": {"items": {"$ref": "#/$defs/node"}}}}}, "$ref": "#/$defs/node"}
    , .{});
    const target = tree.instructionsOf(tree.root)[0].op.ref;
    try testing.expectEqual(.keywords, tree.node(target).verdict);
    const cycles = [_][]const u8{
        "{\"$ref\": \"#\"}",
        "{\"allOf\": [{\"$ref\": \"#\"}]}",
        "{\"$defs\": {\"a\": {\"$ref\": \"#/$defs/b\"}, \"b\": {\"not\": {\"$ref\": \"#/$defs/a\"}}}, \"$ref\": \"#/$defs/a\"}",
        "{\"if\": true, \"then\": {\"$ref\": \"#\"}}",
        "{\"dependentSchemas\": {\"a\": {\"$ref\": \"#\"}}}",
        "{\"$id\": \"http://e.com/x\", \"$defs\": {\"y\": {\"$id\": \"y\", \"anyOf\": [{\"$ref\": \"x\"}]}}, \"$ref\": \"y\"}",
    };
    for (cycles) |text| {
        var d: Diagnostic = .{};
        try testing.expectError(error.ReferenceCycle, compiled(a, text, .{ .diagnostics = &d }));
        try testing.expect(d.location().len > 0);
    }
    // A chain in place past the bound.
    try testing.expectError(error.TooLarge, compiled(a,
        \\{"$defs": {"a": {"$ref": "#/$defs/b"}, "b": {"$ref": "#/$defs/c"}, "c": true}, "$ref": "#/$defs/a"}
    , .{ .limits = .{ .reference_chain = 3 } }));
    _ = try compiled(a,
        \\{"$defs": {"a": {"$ref": "#/$defs/b"}, "b": {"$ref": "#/$defs/c"}, "c": true}, "$ref": "#/$defs/a"}
    , .{ .limits = .{ .reference_chain = 4 } });
    try testing.expectError(error.UnresolvedReference, compiled(a, "{\"$ref\": \"#/$defs/none\"}", .{}));
    try testing.expectError(error.UnresolvedReference, compiled(a, "{\"$ref\": \"http://e.com/remote.json\"}", .{}));
}

test "every embedded meta-schema compiles, each in its own draft" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    for ([_]Dialect{ .draft7, .draft2019_09, .draft2020_12 }) |d| {
        const text = try std.fmt.allocPrint(a, "{{\"$ref\": \"{s}\"}}", .{d.uri()});
        const p = try compiled(a, text, .{});
        try testing.expect(p.nodes.len > 20);
    }
    // 2020-12's `$dynamicRef: "#meta"` searches, and every `meta` anchor is
    // compiled for it to land on.
    const p = try compiled(a, "{\"$ref\": \"https://json-schema.org/draft/2020-12/schema\"}", .{});
    var searching: usize = 0;
    for (p.instructions) |ins| if (ins.op == .dynamic_ref) {
        try testing.expectEqualStrings("meta", ins.op.dynamic_ref.anchor.?);
        searching += 1;
    };
    try testing.expect(searching > 5);
}

test "vocabularies: a custom meta-schema's $vocabulary decides which keywords are read" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var table: TableLoader = .{ .documents = &.{
        .{
            "http://localhost:1234/no-validation.json",
            \\{"$schema": "https://json-schema.org/draft/2020-12/schema", "$id": "http://localhost:1234/no-validation.json",
            \\ "$vocabulary": {"https://json-schema.org/draft/2020-12/vocab/applicator": true, "https://json-schema.org/draft/2020-12/vocab/core": true}}
        },
        .{
            "http://localhost:1234/custom-required.json",
            \\{"$schema": "https://json-schema.org/draft/2020-12/schema",
            \\ "$vocabulary": {"https://json-schema.org/draft/2020-12/vocab/core": true, "http://example.com/vocab/custom": true}}
        },
        .{
            "http://localhost:1234/custom-optional.json",
            \\{"$schema": "https://json-schema.org/draft/2020-12/schema",
            \\ "$vocabulary": {"https://json-schema.org/draft/2020-12/vocab/core": true, "https://json-schema.org/draft/2020-12/vocab/validation": true, "http://example.com/vocab/custom": false}}
        },
    } };
    const p = try compiled(a,
        \\{"$schema": "http://localhost:1234/no-validation.json", "minimum": 5, "properties": {"a": {"maximum": 1}}}
    , .{ .loader = &table.loader });
    try testing.expectEqualSlices(Keyword, &.{.properties}, try keywordsOf(a, &p, p.root));
    const inner = p.instructionsOf(p.root)[0].op.properties[0].node;
    try testing.expectEqual(0, p.instructionsOf(inner).len);
    try testing.expectError(error.UnsupportedVocabulary, compiled(a, "{\"$schema\": \"http://localhost:1234/custom-required.json\"}", .{ .loader = &table.loader }));
    const optional = try compiled(a, "{\"$schema\": \"http://localhost:1234/custom-optional.json\", \"minimum\": 1, \"items\": false}", .{ .loader = &table.loader });
    try testing.expectEqualSlices(Keyword, &.{.minimum}, try keywordsOf(a, &optional, optional.root));
    try testing.expectError(error.UnknownDialect, compiled(a, "{\"$schema\": \"http://localhost:1234/none.json\"}", .{ .loader = &table.loader }));
    try testing.expectError(error.UnknownDialect, compiled(a, "{\"$schema\": \"http://json-schema.org/draft-04/schema#\"}", .{}));
}

test "a diagnostic names the keyword where compiling stopped" {
    var state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var d: Diagnostic = .{};
    try testing.expectError(error.Invalid, compiled(a, "{\"properties\": {\"a~b\": {\"type\": 5}}}", .{ .diagnostics = &d }));
    try testing.expectEqualStrings("urn:strand:schema#/properties/a~0b/type", d.location());
    try testing.expectError(error.UnresolvedReference, compiled(a, "{\"$id\": \"http://e.com/s\", \"$ref\": \"other.json\"}", .{ .diagnostics = &d }));
    try testing.expectEqualStrings("http://e.com/other.json", d.location());
}

/// A loader over a table of URIs and documents.
const TableLoader = struct {
    loader: Loader = .{ .vtable = &.{ .load = load } },
    documents: []const [2][]const u8,

    fn load(l: *Loader, gpa: std.mem.Allocator, io: std.Io, wanted: []const u8) Loader.LoadError![]const u8 {
        _ = io;
        const self: *TableLoader = @fieldParentPtr("loader", l);
        for (self.documents) |d| if (std.mem.eql(u8, d[0], wanted)) return gpa.dupe(u8, d[1]);
        return error.NotFound;
    }
};

test "any graph of references: refused exactly when one applies a schema again in place" {
    const shakedown = @import("shakedown");
    try shakedown.check(testing.allocator, {}, struct {
        const max = 5;
        /// How one schema reaches another: in place (the same instance
        /// location) or through the instance (a member or an item).
        const Kind = enum { ref, all_of, any_of, not, then, properties, items };

        fn inPlaceKind(k: Kind) bool {
            return switch (k) {
                .ref, .all_of, .any_of, .not, .then => true,
                .properties, .items => false,
            };
        }

        fn one(_: void, case: *shakedown.Case) anyerror!void {
            const gen = shakedown.gen;
            const s = case.source;
            var state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer state.deinit();
            const a = state.allocator();
            const n = gen.intRange(s, usize, 1, max);
            // reach[i][j]: schema i applies schema j in place.
            var reach: [max][max]bool = @splat(@splat(false));
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(a, "{\"$defs\": {");
            for (0..n) |i| {
                if (i > 0) try text.appendSlice(a, ", ");
                try text.print(a, "\"d{d}\": {{\"type\": [\"object\", \"array\", \"null\"]", .{i});
                // At most one of each kind, so each keyword appears once.
                for (std.enums.values(Kind)) |kind| {
                    if (gen.intRange(s, u8, 0, 2) != 0) continue;
                    const j = gen.intRange(s, usize, 0, n - 1);
                    if (inPlaceKind(kind)) reach[i][j] = true;
                    const ref = try std.fmt.allocPrint(a, "{{\"$ref\": \"#/$defs/d{d}\"}}", .{j});
                    switch (kind) {
                        .ref => try text.print(a, ", \"$ref\": \"#/$defs/d{d}\"", .{j}),
                        .all_of => try text.print(a, ", \"allOf\": [{s}]", .{ref}),
                        .any_of => try text.print(a, ", \"anyOf\": [true, {s}]", .{ref}),
                        .not => try text.print(a, ", \"not\": {s}", .{ref}),
                        .then => try text.print(a, ", \"if\": true, \"then\": {s}", .{ref}),
                        .properties => try text.print(a, ", \"properties\": {{\"p\": {s}}}", .{ref}),
                        .items => try text.print(a, ", \"items\": {s}", .{ref}),
                    }
                }
                try text.append(a, '}');
            }
            // The root applies every one in place.
            try text.appendSlice(a, "}, \"allOf\": [");
            for (0..n) |i| try text.print(a, "{s}{{\"$ref\": \"#/$defs/d{d}\"}}", .{ if (i > 0) ", " else "", i });
            try text.appendSlice(a, "]}");
            // Warshall's closure: a cycle is a schema reaching itself.
            for (0..n) |k| for (0..n) |i| for (0..n) |j| {
                if (reach[i][k] and reach[k][j]) reach[i][j] = true;
            };
            const cycle = for (0..n) |i| {
                if (reach[i][i]) break true;
            } else false;
            const result = compiled(a, text.items, .{});
            if (cycle) return testing.expectError(error.ReferenceCycle, result);
            _ = try result;
        }
    }.one, .{ .cases = 3000, .seed = 0xc1c1e });
}
