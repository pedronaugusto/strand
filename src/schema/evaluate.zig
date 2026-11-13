//! Validation: an instance's events streamed through a program, with no tree.
//! At each value the schemas that apply there are slots: the roots the value
//! was reached by, and below each the schemas it applies in place (a
//! reference, `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`,
//! `dependentSchemas`), all side by side, so one pass serves every branch. A
//! scalar is checked by every slot; a container's members and items are
//! each read once, against the schemas its slots apply to them; and at the
//! value's end each slot's outcome is settled from its checks and its
//! children's, the deepest first. Memory is the slots of the values open at
//! once, bounded by `Limits.frames`; per object a bit for each name its
//! schemas mention; and, charged to `Limits.state`, where a keyword needs it:
//! a bit per member or item for `unevaluatedProperties` and
//! `unevaluatedItems`, and a keyed hash per item for `uniqueItems`. A
//! value's canonical encoding, for `const`, `enum` and `uniqueItems`, is the
//! one place a value is held whole. Each slot knows the resources entered on
//! the way to it, the dynamic scope a `$dynamicRef` or `$recursiveRef`
//! searches. The reading is a strand seed (`Read`), so every format the core
//! reads is validated alike.
const std = @import("std");
const strand = @import("strand");
const Limits = @import("Limits.zig");
const Decimal = @import("Decimal.zig");
const canonical = @import("canonical.zig");
const Program = @import("Program.zig");
const Pointer = @import("Location.zig");
const dialect = @import("dialect.zig");
const formats = @import("formats.zig");
const spectra = @import("spectra");

const Node = Program.Node;
const Value = strand.json.Value;

pub const Error = error{
    OutOfMemory,
    /// More schemas applying at once than `Limits.frames`.
    TooManyFrames,
    /// An instance nested deeper than a location names
    /// (`Location.max_steps`), met only collecting errors.
    TooDeep,
    /// A number past `Limits.exponent`, or state past `Limits.state`.
    TooLarge,
    /// The validation's `Io` was canceled; it checks once per MiB read.
    Canceled,
};

/// How much of the instance is read between checks for cancellation.
const cancel_interval = 1 << 20;

/// The resources entered on the way to a slot, innermost first: the dynamic
/// scope.
pub const Scope = struct {
    base: []const u8,
    outer: ?*const Scope,
};

/// A schema to apply at a location, the dynamic scope it is reached in, and
/// (collecting errors) the keyword location it is reached by.
pub const Root = struct { node: Node, scope: ?*const Scope, path: []const u8 = "" };

/// One error of a `basic` output.
pub const Record = struct {
    /// The JSON Pointer to the value that failed.
    instance_location: []const u8,
    /// The path through the schema to the keyword, references and all.
    keyword_location: []const u8,
    /// The keyword's absolute location: its resource's URI and the pointer.
    absolute_keyword_location: []const u8,
    message: []const u8,
};

/// One validation's work: the program, where its slots come from, and the
/// key its `uniqueItems` hashes take.
pub const Evaluator = struct {
    program: *const Program,
    scratch: std.mem.Allocator,
    limits: Limits,
    /// Keys `uniqueItems`' hashes, from the validation's `Io`, so an instance
    /// cannot be built to make them collide.
    hash_key: [16]u8,
    /// Slots open now, across every value being read.
    frames: usize = 0,
    /// Bytes of per-container state held now.
    state: usize = 0,
    /// Collecting a `basic` output's errors, up to `Limits.errors`.
    collect: bool = false,
    records: std.ArrayList(Record) = .empty,
    /// Where in the instance the value being read is.
    instance: Pointer = .{},
    /// The validation's `Io`, checked for cancellation.
    io: std.Io,
    /// Bytes of instance read, and where the next check for cancellation
    /// falls.
    read_bytes: usize = 0,
    next_check: usize = cancel_interval,
    /// Each pattern's search cache, made when it is first run.
    caches: std.AutoHashMapUnmanaged(*const spectra.Regex, spectra.Regex.Cache) = .empty,
    /// The downgraded keywords the validation passed through, as indexes
    /// into `Program.downgrades`.
    passed: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,

    /// The slots for `roots` at one location: each root and, below it, what
    /// it applies in place.
    pub fn open(e: *Evaluator, roots: []const Root) Error!*Location {
        const at = try e.scratch.create(Location);
        at.* = .{};
        // A failed opening gives back the slots it made.
        errdefer e.frames -= at.slots.items.len;
        for (roots) |root| try at.roots.append(e.scratch, try e.expand(at, root.node, root.scope, root.path));
        for (at.slots.items) |slot| for (e.program.instructionsOf(slot.node)) |ins| switch (ins.op) {
            .unevaluated_items, .unevaluated_properties => at.tracking = true,
            .unique_items => at.unique = true,
            else => {},
        };
        return at;
    }

    /// Makes the slot for `n` and, after it, the slots of what it applies
    /// in place, its links pointing at them in its instructions' order. A
    /// searching reference applies what the dynamic scope finds. The depth
    /// is the compiler's bounded chain.
    fn expand(e: *Evaluator, at: *Location, n: Node, outer: ?*const Scope, path: []const u8) Error!u32 {
        if (e.frames >= e.limits.frames) return error.TooManyFrames;
        const index: u32 = @intCast(at.slots.items.len);
        const info = e.program.node(n);
        // Entering a resource adds it to the dynamic scope.
        const scope: *const Scope = if (outer) |o| (if (std.mem.eql(u8, o.base, info.base)) o else try e.enter(info.base, o)) else try e.enter(info.base, null);
        try at.slots.append(e.scratch, .{ .node = n, .ok = info.verdict != .none, .links = @intCast(at.links.items.len), .scope = scope, .path = path });
        // Counted once it exists, so a failed opening gives back exactly it.
        e.frames += 1;
        for (info.downgraded) |d| try e.passed.put(e.scratch, d, {});
        if (info.verdict != .keywords) {
            if (info.verdict == .none) try e.fail(at, index, null, "the schema is false");
            return index;
        }
        var children: std.ArrayList(Node) = .empty;
        defer children.deinit(e.scratch);
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(e.scratch);
        for (e.program.instructionsOf(n)) |ins| {
            const before = children.items.len;
            switch (ins.op) {
                .dynamic_ref => |d| try children.append(e.scratch, if (d.anchor) |name| e.dynamicTarget(scope, name) orelse d.node else d.node),
                .recursive_ref => |r| try children.append(e.scratch, if (r.anchored) e.recursiveTarget(scope) orelse r.node else r.node),
                else => try ins.op.inPlace(&children, e.scratch),
            }
            if (e.collect) try inPlacePaths(e, path, ins, children.items.len - before, &paths);
        }
        const start = at.links.items.len;
        try at.links.appendNTimes(e.scratch, 0, children.items.len);
        for (children.items, 0..) |c, k| {
            const slot = try e.expand(at, c, scope, if (e.collect) paths.items[k] else "");
            at.links.items[start + k] = slot;
        }
        return index;
    }

    fn enter(e: *Evaluator, base: []const u8, outer: ?*const Scope) Error!*const Scope {
        const scope = try e.scratch.create(Scope);
        scope.* = .{ .base = base, .outer = outer };
        return scope;
    }

    /// The outermost resource in `scope` with a `$dynamicAnchor` named
    /// `name`: its schema.
    fn dynamicTarget(e: *Evaluator, scope: *const Scope, name: []const u8) ?Node {
        var found: ?Node = null;
        var at: ?*const Scope = scope;
        while (at) |s| : (at = s.outer) {
            for (e.program.dynamic_anchors) |anchor| {
                if (std.mem.eql(u8, anchor.base, s.base) and std.mem.eql(u8, anchor.name, name)) found = anchor.node;
            }
        }
        return found;
    }

    /// The outermost resource in `scope` whose root is marked
    /// `$recursiveAnchor: true`.
    fn recursiveTarget(e: *Evaluator, scope: *const Scope) ?Node {
        var found: ?Node = null;
        var at: ?*const Scope = scope;
        while (at) |s| : (at = s.outer) {
            for (e.program.recursive_roots) |root| {
                if (std.mem.eql(u8, root.base, s.base)) found = root.node;
            }
        }
        return found;
    }

    /// Marks the slot at `index` failed and, collecting, records why: the
    /// keyword (null for the schema itself) and a message.
    fn fail(e: *Evaluator, at: *Location, index: u32, keyword: ?dialect.Keyword, why: []const u8) Error!void {
        const s = &at.slots.items[index];
        s.ok = false;
        // Records made in branches later dropped count too, so the bound
        // here is wider than the output's.
        if (!e.collect or e.records.items.len >= e.limits.errors *| 8) return;
        var instance: std.Io.Writer.Allocating = .init(e.scratch);
        e.instance.format(&instance.writer) catch return error.OutOfMemory;
        const name = if (keyword) |k| k.name() else "";
        const slash: []const u8 = if (keyword != null) "/" else "";
        try e.records.append(e.scratch, .{
            .instance_location = instance.written(),
            .keyword_location = try std.mem.concat(e.scratch, u8, &.{ s.path, slash, name }),
            .absolute_keyword_location = try std.mem.concat(e.scratch, u8, &.{ e.program.node(s.node).location, slash, name }),
            .message = why,
        });
        try s.errors.append(e.scratch, @intCast(e.records.items.len - 1));
    }

    /// Counts `bytes` of instance read, and once per MiB checks whether the
    /// validation was canceled.
    fn consumed(e: *Evaluator, bytes: usize) Error!void {
        e.read_bytes += bytes;
        if (e.read_bytes < e.next_check) return;
        e.next_check = e.read_bytes + cancel_interval;
        e.io.checkCancel() catch return error.Canceled;
    }

    /// Whether `re` matches anywhere in `s`, as ECMAScript's `test` does.
    fn matches(e: *Evaluator, re: *const spectra.Regex, s: []const u8) Error!bool {
        const entry = try e.caches.getOrPut(e.scratch, re);
        if (!entry.found_existing) entry.value_ptr.* = try re.cache(e.scratch);
        return re.isMatch(entry.value_ptr, s) catch error.TooLarge;
    }

    /// Charges `bytes` of per-container state to `at`, given back when it
    /// closes; past `Limits.state` nothing is charged.
    fn charge(e: *Evaluator, at: *Location, bytes: usize) Error!void {
        if (bytes > e.limits.state.raw() -| e.state) return error.TooLarge;
        e.state += bytes;
        at.charged += bytes;
    }

    /// Closes `at`: its slots are no longer open.
    pub fn close(e: *Evaluator, at: *Location) void {
        e.frames -= at.slots.items.len;
        e.state -= at.charged;
    }
};

/// The slots at one location, and what the value read there has settled.
pub const Location = struct {
    slots: std.ArrayList(Slot) = .empty,
    /// Each slot's in-place children, in its instructions' order.
    links: std.ArrayList(u32) = .empty,
    /// The slots of the roots, in the order they were given.
    roots: std.ArrayList(u32) = .empty,
    /// The value's canonical encoding, where a container's `const` or
    /// `enum` asks for it.
    encoding: ?[]const u8 = null,
    /// Some slot reads `unevaluatedProperties` or `unevaluatedItems`: every
    /// slot keeps which members or items it evaluated.
    tracking: bool = false,
    /// Some slot reads `uniqueItems`.
    unique: bool = false,
    /// What the value read here is, where it is a container.
    container: enum { none, object, array } = .none,
    /// Two items of the array are equal.
    duplicate: bool = false,
    /// Each item's hash, and where it lies, for `uniqueItems`.
    hashes: std.ArrayList(Hashed) = .empty,
    /// State charged for this location, given back when it closes.
    charged: usize = 0,

    const Hashed = struct { hash: u128, start: usize, end: usize };

    /// Whether any slot compares the whole value.
    pub fn wantsEncoding(at: *const Location, p: *const Program) bool {
        for (at.slots.items) |s| for (p.instructionsOf(s.node)) |ins| switch (ins.op) {
            .@"const", .@"enum" => return true,
            else => {},
        };
        return false;
    }

    /// Whether the value at root `i` is valid, once settled.
    pub fn outcome(at: *const Location, i: usize) bool {
        return at.slots.items[at.roots.items[i]].ok;
    }
};

pub const Slot = struct {
    node: Node,
    /// Every check so far passed, before its children are combined.
    ok: bool,
    /// Where its children's links begin in `Location.links`.
    links: u32 = 0,
    /// `contains`' matches.
    contained: u64 = 0,
    /// Members or items read.
    count: u64 = 0,
    /// For an object: the names its instructions mention (`required`'s,
    /// `dependentRequired`'s keys and lists, `dependentSchemas`' keys), and
    /// which of them were seen.
    names: []const []const u8 = &.{},
    seen: []bool = &.{},
    /// The resources entered on the way to it.
    scope: ?*const Scope = null,
    /// Where tracked: which members or items it evaluated (its own, and
    /// once settled its successful children's), and for its
    /// `unevaluated*` which of them its subschema found valid.
    evaluated: std.DynamicBitSetUnmanaged = .{},
    unevaluated_valid: std.DynamicBitSetUnmanaged = .{},
    /// Collecting: its keyword location, and the records of why it failed.
    path: []const u8 = "",
    errors: std.ArrayList(u32) = .empty,

    fn present(s: *const Slot, name: []const u8) bool {
        for (s.names, s.seen) |n, seen| if (seen and std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

/// The keyword locations of the slots `ins` applies in place, `count` of
/// them, below `path`.
fn inPlacePaths(e: *Evaluator, path: []const u8, ins: Program.Instruction, count: usize, out: *std.ArrayList([]const u8)) Error!void {
    const name = ins.keyword.name();
    switch (ins.op) {
        .all_of, .any_of, .one_of => for (0..count) |k| try out.append(e.scratch, try std.fmt.allocPrint(e.scratch, "{s}/{s}/{d}", .{ path, name, k })),
        .conditional => |c| {
            try out.append(e.scratch, try std.fmt.allocPrint(e.scratch, "{s}/if", .{path}));
            if (c.then != null) try out.append(e.scratch, try std.fmt.allocPrint(e.scratch, "{s}/then", .{path}));
            if (c.@"else" != null) try out.append(e.scratch, try std.fmt.allocPrint(e.scratch, "{s}/else", .{path}));
        },
        .dependent_schemas => |deps| for (deps) |dep| try out.append(e.scratch, try below(e, path, name, dep.name)),
        else => for (0..count) |_| try out.append(e.scratch, try std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ path, name })),
    }
}

/// `path/keyword/token`, the token escaped as a JSON Pointer's.
fn below(e: *Evaluator, path: []const u8, keyword: []const u8, token: []const u8) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(e.scratch);
    out.writer.print("{s}/{s}/", .{ path, keyword }) catch return error.OutOfMemory;
    Pointer.writeToken(&out.writer, token) catch return error.OutOfMemory;
    return out.written();
}

/// A child's keyword location, collecting; empty otherwise.
fn childPath(e: *Evaluator, s: *const Slot, ins: Program.Instruction, token: ?[]const u8) Error![]const u8 {
    if (!e.collect) return "";
    if (token) |t| return below(e, s.path, ins.keyword.name(), t);
    return std.fmt.allocPrint(e.scratch, "{s}/{s}", .{ s.path, ins.keyword.name() });
}

/// Why an instruction failed, in a few words.
fn message(op: Program.Op) []const u8 {
    return switch (op) {
        .type => "the value is not of the type the schema names",
        .@"const" => "the value is not the one the schema requires",
        .@"enum" => "the value is not one of those the schema lists",
        .minimum => "the number is below the minimum",
        .exclusive_minimum => "the number is not above the exclusive minimum",
        .maximum => "the number is above the maximum",
        .exclusive_maximum => "the number is not below the exclusive maximum",
        .multiple_of => "the number is not a multiple of the divisor",
        .min_length => "the string is shorter than the minimum length",
        .max_length => "the string is longer than the maximum length",
        .pattern => "the string does not match the pattern",
        .format => "the string is not of the format",
        .min_items => "the array has fewer items than the minimum",
        .max_items => "the array has more items than the maximum",
        .unique_items => "the array has two equal items",
        .contains => "the array has too few or too many items matching contains",
        .min_properties => "the object has fewer members than the minimum",
        .max_properties => "the object has more members than the maximum",
        .required => "a required member is missing",
        .dependent_required => "a member another member requires is missing",
        .property_names => "a member's name is invalid",
        .any_of => "no subschema of anyOf is valid",
        .one_of => "not exactly one subschema of oneOf is valid",
        .not => "the subschema of not is valid",
        .unevaluated_items => "an item no other keyword evaluated is invalid",
        .unevaluated_properties => "a member no other keyword evaluated is invalid",
        else => "the subschema is invalid",
    };
}

/// JSON's type of a value, as `type` names it (`integer` aside).
const Kind = enum { null, boolean, number, string, object, array };

/// Reads one value against the slots of `at` and settles them: a strand
/// seed, which consumes exactly one value through its access, in any format,
/// builds nothing, and hands each member and item a seed of its own.
pub const Read = struct {
    e: *Evaluator,
    at: *Location,

    pub fn strandDeserializeSeed(self: Read, access: anytype) (@TypeOf(access.*).Error || Error)!void {
        try read(self.e, self.at, access);
    }
};

fn read(e: *Evaluator, at: *Location, access: anytype) (@TypeOf(access.*).Error || Error)!void {
    switch (try access.peek()) {
        .none => {
            _ = try access.read(?bool);
            try e.consumed(1);
            try scalar(e, at, .null, .{ .null_value = {} });
        },
        .boolean => {
            const b = try access.read(bool);
            try e.consumed(1);
            try scalar(e, at, .boolean, .{ .boolean = b });
        },
        .number => {
            const text = try access.number();
            try e.consumed(text.len + 1);
            try scalar(e, at, .number, .{ .number = text });
        },
        .floating => {
            // A format's binary float (TOML's, CBOR's): its exact decimal
            // value, which a double's shortest spelling reads back as.
            const f = try access.read(f64);
            if (!std.math.isFinite(f)) return error.UnexpectedType;
            const text = try std.fmt.allocPrint(e.scratch, "{e}", .{f});
            try e.consumed(text.len);
            try scalar(e, at, .number, .{ .number = text });
        },
        .integer => {
            const n = try access.read(i128);
            const text = try std.fmt.allocPrint(e.scratch, "{d}", .{n});
            try scalar(e, at, .number, .{ .number = text });
        },
        .text => {
            const s = try access.read([]const u8);
            try e.consumed(s.len + 2);
            try scalar(e, at, .string, .{ .string = s });
        },
        .begin => |header| switch (header.kind) {
            .map, .record => {
                at.container = .object;
                var compound = try access.begin(header.kind);
                defer compound.abort();
                try typeChecks(e, at, .object, null);
                try prepareObject(e, at);
                while (try compound.hasNext()) {
                    const key = try compound.key([]const u8);
                    try e.consumed(key.len + 4);
                    try member(e, at, &compound, key);
                }
                try compound.finish();
                try finishObject(e, at);
            },
            .sequence, .tuple => {
                at.container = .array;
                var compound = try access.begin(header.kind);
                defer compound.abort();
                try typeChecks(e, at, .array, null);
                var i: u64 = 0;
                while (try compound.hasNext()) : (i += 1) try item(e, at, &compound, i);
                try compound.finish();
                for (at.slots.items) |*s| s.count = i;
                try finishArray(e, at);
            },
            else => return error.UnexpectedType,
        },
        else => return error.UnexpectedType,
    }
    try settle(e, at);
}

/// A scalar's checks, in every slot.
fn scalar(e: *Evaluator, at: *Location, kind: Kind, value: Value) Error!void {
    if (at.wantsEncoding(e.program)) at.encoding = canonical.encodeAlloc(e.scratch, value, e.limits.exponent) catch |err| return switch (err) {
        error.Invalid => error.TooLarge,
        else => |x| x,
    };
    var number: ?Decimal = null;
    if (value == .number) {
        const buffer = try e.scratch.alloc(u8, value.number.len);
        number = Decimal.parse(value.number, buffer, e.limits.exponent) catch return error.TooLarge;
    }
    try typeChecks(e, at, kind, number);
    for (at.slots.items, 0..) |*s, si| {
        if ((!s.ok and !e.collect) or e.program.node(s.node).verdict != .keywords) continue;
        for (e.program.instructionsOf(s.node)) |ins| {
            const pass = switch (ins.op) {
                .minimum => |m| if (number) |n| n.order(m) != .lt else true,
                .exclusive_minimum => |m| if (number) |n| n.order(m) == .gt else true,
                .maximum => |m| if (number) |n| n.order(m) != .gt else true,
                .exclusive_maximum => |m| if (number) |n| n.order(m) == .lt else true,
                .multiple_of => |m| if (number) |n| try n.multipleOf(m, e.scratch) else true,
                .min_length => |m| if (value == .string) codePoints(value.string) >= m else true,
                .max_length => |m| if (value == .string) codePoints(value.string) <= m else true,
                .pattern => |re| if (value == .string) try e.matches(re, value.string) else true,
                .format => |format| if (value == .string) try formats.check(e.scratch, format, value.string) else true,
                else => true,
            };
            if (!pass) {
                try e.fail(at, @intCast(si), ins.keyword, message(ins.op));
                // Collecting, every keyword that fails is said.
                if (!e.collect) break;
            }
        }
    }
}

fn codePoints(s: []const u8) u64 {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// `type`, `const` and `enum`, in every slot.
fn typeChecks(e: *Evaluator, at: *Location, kind: Kind, number: ?Decimal) Error!void {
    for (at.slots.items, 0..) |*s, si| {
        if ((!s.ok and !e.collect) or e.program.node(s.node).verdict != .keywords) continue;
        for (e.program.instructionsOf(s.node)) |ins| {
            const pass = switch (ins.op) {
                .type => |types| typeMatches(types, kind, number),
                .@"const" => |c| if (at.encoding) |enc| std.mem.eql(u8, enc, c) else true,
                .@"enum" => |list| if (at.encoding) |enc| for (list) |c| {
                    if (std.mem.eql(u8, enc, c)) break true;
                } else false else true,
                else => true,
            };
            if (!pass) {
                try e.fail(at, @intCast(si), ins.keyword, message(ins.op));
                // Collecting, every keyword that fails is said.
                if (!e.collect) break;
            }
        }
    }
}

fn typeMatches(types: Program.Types, kind: Kind, number: ?Decimal) bool {
    return switch (kind) {
        .null => types.contains(.null),
        .boolean => types.contains(.boolean),
        .string => types.contains(.string),
        .object => types.contains(.object),
        .array => types.contains(.array),
        .number => types.contains(.number) or (types.contains(.integer) and number.?.isInteger()),
    };
}

/// The names each slot's object keywords mention, each to be marked when
/// seen: bounded by the schema, not the instance.
fn prepareObject(e: *Evaluator, at: *Location) Error!void {
    for (at.slots.items) |*s| {
        if (e.program.node(s.node).verdict != .keywords) continue;
        var names: std.ArrayList([]const u8) = .empty;
        for (e.program.instructionsOf(s.node)) |ins| switch (ins.op) {
            .required => |list| try names.appendSlice(e.scratch, list),
            .dependent_required => |deps| for (deps) |dep| {
                try names.append(e.scratch, dep.name);
                try names.appendSlice(e.scratch, dep.required);
            },
            .dependent_schemas => |deps| for (deps) |dep| try names.append(e.scratch, dep.name),
            else => {},
        };
        s.names = names.items;
        s.seen = try e.scratch.alloc(bool, names.items.len);
        @memset(s.seen, false);
    }
}

/// Marks `key` in every slot that mentions it.
fn markSeen(at: *Location, key: []const u8) void {
    for (at.slots.items) |*s| {
        for (s.names, s.seen) |name, *seen| if (std.mem.eql(u8, name, key)) {
            seen.* = true;
        };
    }
}

/// Where a child's outcome goes: into its slot's checks (and, tracked, its
/// evaluated members or items), counted for `contains`, or recorded for its
/// `unevaluated*`.
const Owner = struct {
    slot: u32,
    kind: enum { all, contains, unevaluated },
    /// For `contains`: whether a match counts as evaluated.
    evaluates: bool = false,
};

/// Grows every slot's tracking by one member or item, charged to the state.
fn track(e: *Evaluator, at: *Location, index: u64) Error!void {
    if (!at.tracking) return;
    const len: usize = @intCast(index + 1);
    for (at.slots.items) |*s| {
        try s.evaluated.resize(e.scratch, len, false);
        try s.unevaluated_valid.resize(e.scratch, len, false);
    }
    // Two bits a slot, rounded up a byte a member.
    const bytes = at.slots.items.len / 4 + 1;
    try e.charge(at, bytes);
}

fn member(e: *Evaluator, at: *Location, compound: anytype, key: []const u8) !void {
    markSeen(at, key);
    const index = if (at.slots.items.len > 0) at.slots.items[0].count else 0;
    try track(e, at, index);
    var roots: std.ArrayList(Root) = .empty;
    var owners: std.ArrayList(Owner) = .empty;
    for (at.slots.items, 0..) |*s, si| {
        s.count += 1;
        if (e.program.node(s.node).verdict != .keywords) continue;
        const slot: u32 = @intCast(si);
        for (e.program.instructionsOf(s.node)) |ins| switch (ins.op) {
            .properties => |props| for (props) |prop| if (std.mem.eql(u8, prop.name, key)) {
                try roots.append(e.scratch, .{ .node = prop.node, .scope = s.scope, .path = try childPath(e, s, ins, prop.name) });
                try owners.append(e.scratch, .{ .slot = slot, .kind = .all });
            },
            .pattern_properties => |list| for (list) |entry| if (try e.matches(entry.pattern, key)) {
                try roots.append(e.scratch, .{ .node = entry.node, .scope = s.scope, .path = if (e.collect) try below(e, s.path, ins.keyword.name(), entry.source) else "" });
                try owners.append(e.scratch, .{ .slot = slot, .kind = .all });
            },
            .additional_properties => |ap| {
                var named = for (ap.names) |name| {
                    if (std.mem.eql(u8, name, key)) break true;
                } else false;
                if (!named) for (ap.patterns) |re| if (try e.matches(re, key)) {
                    named = true;
                    break;
                };
                if (!named) {
                    try roots.append(e.scratch, .{ .node = ap.node, .scope = s.scope, .path = try childPath(e, s, ins, null) });
                    try owners.append(e.scratch, .{ .slot = slot, .kind = .all });
                }
            },
            .unevaluated_properties => |n| {
                try roots.append(e.scratch, .{ .node = n, .scope = s.scope, .path = try childPath(e, s, ins, null) });
                try owners.append(e.scratch, .{ .slot = slot, .kind = .unevaluated });
            },
            .property_names => |n| if (!try nameValid(e, n, s.scope, key)) {
                try e.fail(at, slot, ins.keyword, message(ins.op));
            },
            else => {},
        };
    }
    if (e.collect) try e.instance.push(.{ .name = key });
    defer if (e.collect) e.instance.pop();
    try child(e, at, compound, roots.items, owners.items, index, null);
}

/// Whether `key`, as a string instance, is valid against `n`.
fn nameValid(e: *Evaluator, n: Node, scope: ?*const Scope, key: []const u8) Error!bool {
    const at = try e.open(&.{.{ .node = n, .scope = scope }});
    defer e.close(at);
    try scalar(e, at, .string, .{ .string = key });
    try settle(e, at);
    return at.outcome(0);
}

fn item(e: *Evaluator, at: *Location, compound: anytype, i: u64) !void {
    try track(e, at, i);
    var roots: std.ArrayList(Root) = .empty;
    var owners: std.ArrayList(Owner) = .empty;
    var position: [24]u8 = undefined;
    const token = std.fmt.bufPrint(&position, "{d}", .{i}) catch unreachable;
    for (at.slots.items, 0..) |*s, si| {
        if (e.program.node(s.node).verdict != .keywords) continue;
        const slot: u32 = @intCast(si);
        for (e.program.instructionsOf(s.node)) |ins| switch (ins.op) {
            .prefix_items => |nodes| if (i < nodes.len) {
                try roots.append(e.scratch, .{ .node = nodes[@intCast(i)], .scope = s.scope, .path = try childPath(e, s, ins, token) });
                try owners.append(e.scratch, .{ .slot = slot, .kind = .all });
            },
            .items => |it| if (i >= it.from) {
                try roots.append(e.scratch, .{ .node = it.node, .scope = s.scope, .path = try childPath(e, s, ins, null) });
                try owners.append(e.scratch, .{ .slot = slot, .kind = .all });
            },
            .contains => |ct| {
                try roots.append(e.scratch, .{ .node = ct.node, .scope = s.scope, .path = try childPath(e, s, ins, null) });
                try owners.append(e.scratch, .{ .slot = slot, .kind = .contains, .evaluates = ct.evaluates });
            },
            .unevaluated_items => |n| {
                try roots.append(e.scratch, .{ .node = n, .scope = s.scope, .path = try childPath(e, s, ins, null) });
                try owners.append(e.scratch, .{ .slot = slot, .kind = .unevaluated });
            },
            else => {},
        };
    }
    if (e.collect) try e.instance.push(.{ .index = @intCast(i) });
    defer if (e.collect) e.instance.pop();
    if (!at.unique) return child(e, at, compound, roots.items, owners.items, i, null);
    // `uniqueItems`: the item read whole once for its encoding and its keyed
    // hash; equal hashes compare encodings, the earlier item read again.
    const held = try compound.hold();
    const encoding = try encodeHeld(e, compound, held);
    const hash = std.crypto.auth.siphash.SipHash128(1, 3).toInt(encoding, &e.hash_key);
    for (at.hashes.items) |earlier| if (earlier.hash == hash and !at.duplicate) {
        const other = try encodeHeld(e, compound, .{ .start = earlier.start, .end = earlier.end });
        if (std.mem.eql(u8, other, encoding)) at.duplicate = true;
    };
    try e.charge(at, @sizeOf(Location.Hashed));
    try at.hashes.append(e.scratch, .{ .hash = hash, .start = held.start, .end = held.end });
    try child(e, at, compound, roots.items, owners.items, i, .{ .start = held.start, .end = held.end, .encoding = encoding });
}

/// A held value's canonical encoding.
fn encodeHeld(e: *Evaluator, compound: anytype, held: anytype) ![]const u8 {
    const whole = try compound.readHeld(Value, .{ .start = held.start, .end = held.end });
    return canonical.encodeAlloc(e.scratch, whole, e.limits.exponent) catch |err| switch (err) {
        error.Invalid => error.TooLarge,
        else => |x| x,
    };
}

/// A value already passed over and encoded, to be read again from where it
/// lies.
const Held = struct { start: usize, end: usize, encoding: []const u8 };

/// Reads the next member's or item's value against `roots`, each outcome
/// to its owner; `held`, a value already passed over, is read from where it
/// lies.
fn child(e: *Evaluator, at: *Location, compound: anytype, roots: []const Root, owners: []const Owner, index: u64, held: ?Held) !void {
    if (roots.len == 0) {
        if (held == null) _ = try compound.hold();
        return;
    }
    const inner = try e.open(roots);
    defer e.close(inner);
    if (held) |h| {
        if (inner.wantsEncoding(e.program)) inner.encoding = h.encoding;
        try compound.readHeldSeed(Read{ .e = e, .at = inner }, .{ .start = h.start, .end = h.end });
    } else if (inner.wantsEncoding(e.program)) {
        // A container's `const` or `enum`: the value is read whole once for
        // its encoding, then streamed for everything else.
        const passed = try compound.hold();
        inner.encoding = try encodeHeld(e, compound, passed);
        try compound.readHeldSeed(Read{ .e = e, .at = inner }, passed);
    } else {
        try compound.elementSeed(Read{ .e = e, .at = inner });
    }
    const j: usize = @intCast(index);
    for (owners, 0..) |owner, k| {
        const valid = inner.outcome(k);
        const s = &at.slots.items[owner.slot];
        switch (owner.kind) {
            .all => {
                if (!valid) {
                    s.ok = false;
                    if (e.collect) try s.errors.appendSlice(e.scratch, inner.slots.items[inner.roots.items[k]].errors.items);
                }
                if (at.tracking) s.evaluated.set(j);
            },
            .contains => if (valid) {
                s.contained += 1;
                if (at.tracking and owner.evaluates) s.evaluated.set(j);
            },
            .unevaluated => if (valid) s.unevaluated_valid.set(j),
        }
    }
}

fn finishObject(e: *Evaluator, at: *Location) Error!void {
    for (at.slots.items, 0..) |*s, si| {
        if ((!s.ok and !e.collect) or e.program.node(s.node).verdict != .keywords) continue;
        for (e.program.instructionsOf(s.node)) |ins| {
            const pass = switch (ins.op) {
                .required => |list| for (list) |name| {
                    if (!s.present(name)) break false;
                } else true,
                .min_properties => |m| s.count >= m,
                .max_properties => |m| s.count <= m,
                .dependent_required => |deps| for (deps) |dep| {
                    if (!s.present(dep.name)) continue;
                    if (for (dep.required) |name| {
                        if (!s.present(name)) break true;
                    } else false) break false;
                } else true,
                else => true,
            };
            if (!pass) {
                try e.fail(at, @intCast(si), ins.keyword, message(ins.op));
                // Collecting, every keyword that fails is said.
                if (!e.collect) break;
            }
        }
    }
}

fn finishArray(e: *Evaluator, at: *Location) Error!void {
    for (at.slots.items, 0..) |*s, si| {
        if ((!s.ok and !e.collect) or e.program.node(s.node).verdict != .keywords) continue;
        for (e.program.instructionsOf(s.node)) |ins| {
            const pass = switch (ins.op) {
                .min_items => |m| s.count >= m,
                .max_items => |m| s.count <= m,
                .contains => |ct| s.contained >= ct.min and (ct.max == null or s.contained <= ct.max.?),
                .unique_items => !at.duplicate,
                else => true,
            };
            if (!pass) {
                try e.fail(at, @intCast(si), ins.keyword, message(ins.op));
                // Collecting, every keyword that fails is said.
                if (!e.collect) break;
            }
        }
    }
}

/// Each slot's outcome from its own checks and its children's, the deepest
/// first: a slot's children were made after it. Where tracked, a slot's
/// evaluated members or items take in those of each child whose outcome
/// keeps its annotations (a passing reference, `allOf`, `anyOf` or `oneOf`
/// branch, `if` and the branch it chose, a present `dependentSchemas`; never
/// `not`), and then its `unevaluated*` judges the rest.
fn settle(e: *Evaluator, at: *Location) Error!void {
    var i = at.slots.items.len;
    while (i > 0) {
        i -= 1;
        const index: u32 = @intCast(i);
        const s = &at.slots.items[i];
        if (e.program.node(s.node).verdict != .keywords) continue;
        var link = s.links;
        for (e.program.instructionsOf(s.node)) |ins| switch (ins.op) {
            .ref, .dynamic_ref, .recursive_ref => {
                if (!keep(at, s, link)) try adopt(e, at, index, link);
                link += 1;
            },
            .all_of => |nodes| for (nodes) |_| {
                if (!keep(at, s, link)) try adopt(e, at, index, link);
                link += 1;
            },
            .any_of => |nodes| {
                const first = link;
                var any = false;
                for (nodes) |_| {
                    any = keep(at, s, link) or any;
                    link += 1;
                }
                if (!any) {
                    try e.fail(at, index, ins.keyword, message(ins.op));
                    for (first..link) |l| try adopt(e, at, index, @intCast(l));
                }
            },
            .one_of => |nodes| {
                const first = link;
                var valid: usize = 0;
                for (nodes) |_| {
                    if (keep(at, s, link)) valid += 1;
                    link += 1;
                }
                if (valid != 1) {
                    try e.fail(at, index, ins.keyword, message(ins.op));
                    if (valid == 0) for (first..link) |l| try adopt(e, at, index, @intCast(l));
                }
            },
            .not => {
                if (at.slots.items[at.links.items[link]].ok) try e.fail(at, index, ins.keyword, message(ins.op));
                link += 1;
            },
            .conditional => |c| {
                const condition = keep(at, s, link);
                link += 1;
                if (c.then != null) {
                    if (condition and !keep(at, s, link)) try adopt(e, at, index, link);
                    link += 1;
                }
                if (c.@"else" != null) {
                    if (!condition and !keep(at, s, link)) try adopt(e, at, index, link);
                    link += 1;
                }
            },
            .dependent_schemas => |deps| for (deps) |dep| {
                // Applies only where its member is present.
                if (s.present(dep.name) and !keep(at, s, link)) try adopt(e, at, index, link);
                link += 1;
            },
            // Each over its own kind of container only.
            .unevaluated_items, .unevaluated_properties => if (at.tracking and at.container == (if (ins.op == .unevaluated_items) @as(@TypeOf(at.container), .array) else .object)) {
                const count: usize = @intCast(s.count);
                for (0..count) |j| if (!s.evaluated.isSet(j) and !s.unevaluated_valid.isSet(j)) {
                    try e.fail(at, index, ins.keyword, message(ins.op));
                    break;
                };
                if (count > 0) s.evaluated.setRangeValue(.{ .start = 0, .end = count }, true);
            },
            else => {},
        };
    }
}

/// The slot at `index` fails with its child at `link`: collecting, the
/// child's records become the slot's.
fn adopt(e: *Evaluator, at: *Location, index: u32, link: u32) Error!void {
    const s = &at.slots.items[index];
    s.ok = false;
    if (e.collect) try s.errors.appendSlice(e.scratch, at.slots.items[at.links.items[link]].errors.items);
}

/// Whether the child at `link` passed; if so, where tracked, its evaluated
/// members or items become the slot's too.
fn keep(at: *Location, s: *Slot, link: u32) bool {
    const c = &at.slots.items[at.links.items[link]];
    if (c.ok and at.tracking) s.evaluated.setUnion(c.evaluated);
    return c.ok;
}
