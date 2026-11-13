//! Validation: an instance's events streamed through a program, with no tree.
//! At each value the schemas that apply there are slots: the roots the value
//! was reached by, and below each the schemas it applies in place (a
//! reference, `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`,
//! `dependentSchemas`), all side by side, so one pass serves every branch. A
//! scalar is checked by every slot; a container's members and items are
//! each read once, against the schemas its slots apply to them; and at the
//! value's end each slot's outcome is settled from its checks and its
//! children's, the deepest first. Memory is the slots of the values open at
//! once, bounded by `Limits.frames`, and per object a bit for each name its
//! schemas mention; a value's canonical encoding, for `const` and `enum` on
//! a container, is the one place a value is held whole. The reading is a
//! strand seed (`Read`), so every format the core reads is validated alike.
const std = @import("std");
const strand = @import("strand");
const Limits = @import("Limits.zig");
const Decimal = @import("Decimal.zig");
const canonical = @import("canonical.zig");
const Program = @import("Program.zig");

const Node = Program.Node;
const Value = strand.json.Value;

pub const Error = error{
    OutOfMemory,
    /// More schemas applying at once than `Limits.frames`.
    TooManyFrames,
    /// A number past `Limits.exponent`, or state past `Limits.state`.
    TooLarge,
    /// A keyword this build does not evaluate yet: `uniqueItems`,
    /// `unevaluatedItems`, `unevaluatedProperties`, `pattern`,
    /// `patternProperties`, and a `$dynamicRef` or `$recursiveRef` that
    /// searches the dynamic scope. Never passed over in silence.
    Unsupported,
};

/// One validation's work: the program, where its slots come from, and the
/// roots the value about to be read is to be checked against.
pub const Evaluator = struct {
    program: *const Program,
    scratch: std.mem.Allocator,
    limits: Limits,
    /// Slots open now, across every value being read.
    frames: usize = 0,

    /// The slots for `roots` at one location: each root and, below it, what
    /// it applies in place.
    pub fn open(e: *Evaluator, roots: []const Node) Error!*Location {
        const at = try e.scratch.create(Location);
        at.* = .{};
        for (roots) |root| try at.roots.append(e.scratch, try e.expand(at, root));
        return at;
    }

    /// Makes the slot for `n` and, after it, the slots of what it applies
    /// in place, its links pointing at them in its instructions' order. The
    /// depth is the compiler's bounded chain.
    fn expand(e: *Evaluator, at: *Location, n: Node) Error!u32 {
        e.frames += 1;
        if (e.frames > e.limits.frames) return error.TooManyFrames;
        const index: u32 = @intCast(at.slots.items.len);
        const info = e.program.node(n);
        try at.slots.append(e.scratch, .{ .node = n, .ok = info.verdict != .none, .links = @intCast(at.links.items.len) });
        if (info.verdict != .keywords) return index;
        var children: std.ArrayList(Node) = .empty;
        defer children.deinit(e.scratch);
        for (e.program.instructionsOf(n)) |ins| {
            switch (ins.op) {
                .unique_items, .unevaluated_items, .unevaluated_properties, .pattern, .pattern_properties => return error.Unsupported,
                .dynamic_ref => |d| if (d.anchor != null) return error.Unsupported,
                .recursive_ref => |r| if (r.anchored) return error.Unsupported,
                else => {},
            }
            try ins.op.inPlace(&children, e.scratch);
        }
        const start = at.links.items.len;
        try at.links.appendNTimes(e.scratch, 0, children.items.len);
        for (children.items, 0..) |c, k| {
            const slot = try e.expand(at, c);
            at.links.items[start + k] = slot;
        }
        return index;
    }

    /// Closes `at`: its slots are no longer open.
    pub fn close(e: *Evaluator, at: *Location) void {
        e.frames -= at.slots.items.len;
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

    fn present(s: *const Slot, name: []const u8) bool {
        for (s.names, s.seen) |n, seen| if (seen and std.mem.eql(u8, n, name)) return true;
        return false;
    }
};

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
            try scalar(e, at, .null, .{ .null_value = {} });
        },
        .boolean => {
            const b = try access.read(bool);
            try scalar(e, at, .boolean, .{ .boolean = b });
        },
        .number => {
            const text = try access.number();
            try scalar(e, at, .number, .{ .number = text });
        },
        .integer => {
            const n = try access.read(i128);
            const text = try std.fmt.allocPrint(e.scratch, "{d}", .{n});
            try scalar(e, at, .number, .{ .number = text });
        },
        .text => {
            const s = try access.read([]const u8);
            try scalar(e, at, .string, .{ .string = s });
        },
        .begin => |header| switch (header.kind) {
            .map, .record => {
                var compound = try access.begin(header.kind);
                defer compound.abort();
                try typeChecks(e, at, .object, null);
                try prepareObject(e, at);
                while (try compound.hasNext()) {
                    const key = try compound.key([]const u8);
                    try member(e, at, &compound, key);
                }
                try compound.finish();
                try finishObject(e, at);
            },
            .sequence, .tuple => {
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
    settle(e, at);
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
    for (at.slots.items) |*s| {
        if (!s.ok or e.program.node(s.node).verdict != .keywords) continue;
        for (e.program.instructionsOf(s.node)) |ins| {
            const pass = switch (ins.op) {
                .minimum => |m| if (number) |n| n.order(m) != .lt else true,
                .exclusive_minimum => |m| if (number) |n| n.order(m) == .gt else true,
                .maximum => |m| if (number) |n| n.order(m) != .gt else true,
                .exclusive_maximum => |m| if (number) |n| n.order(m) == .lt else true,
                .multiple_of => |m| if (number) |n| try n.multipleOf(m, e.scratch) else true,
                .min_length => |m| if (value == .string) codePoints(value.string) >= m else true,
                .max_length => |m| if (value == .string) codePoints(value.string) <= m else true,
                else => true,
            };
            if (!pass) {
                s.ok = false;
                break;
            }
        }
    }
}

fn codePoints(s: []const u8) u64 {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// `type`, `const` and `enum`, in every slot.
fn typeChecks(e: *Evaluator, at: *Location, kind: Kind, number: ?Decimal) Error!void {
    for (at.slots.items) |*s| {
        if (!s.ok or e.program.node(s.node).verdict != .keywords) continue;
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
                s.ok = false;
                break;
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

/// Where a child's outcome goes: into its slot's checks, or counted for
/// `contains`.
const Owner = struct { slot: u32, kind: enum { all, contains } };

fn member(e: *Evaluator, at: *Location, compound: anytype, key: []const u8) !void {
    markSeen(at, key);
    var roots: std.ArrayList(Node) = .empty;
    var owners: std.ArrayList(Owner) = .empty;
    for (at.slots.items, 0..) |*s, si| {
        s.count += 1;
        if (e.program.node(s.node).verdict != .keywords) continue;
        for (e.program.instructionsOf(s.node)) |ins| switch (ins.op) {
            .properties => |props| for (props) |prop| if (std.mem.eql(u8, prop.name, key)) {
                try roots.append(e.scratch, prop.node);
                try owners.append(e.scratch, .{ .slot = @intCast(si), .kind = .all });
            },
            .additional_properties => |ap| {
                const named = for (ap.names) |name| {
                    if (std.mem.eql(u8, name, key)) break true;
                } else false;
                if (!named) {
                    try roots.append(e.scratch, ap.node);
                    try owners.append(e.scratch, .{ .slot = @intCast(si), .kind = .all });
                }
            },
            .property_names => |n| if (!try nameValid(e, n, key)) {
                s.ok = false;
            },
            else => {},
        };
    }
    try child(e, at, compound, roots.items, owners.items);
}

/// Whether `key`, as a string instance, is valid against `n`.
fn nameValid(e: *Evaluator, n: Node, key: []const u8) Error!bool {
    const at = try e.open(&.{n});
    defer e.close(at);
    try scalar(e, at, .string, .{ .string = key });
    settle(e, at);
    return at.outcome(0);
}

fn item(e: *Evaluator, at: *Location, compound: anytype, i: u64) !void {
    var roots: std.ArrayList(Node) = .empty;
    var owners: std.ArrayList(Owner) = .empty;
    for (at.slots.items, 0..) |s, si| {
        if (e.program.node(s.node).verdict != .keywords) continue;
        for (e.program.instructionsOf(s.node)) |ins| switch (ins.op) {
            .prefix_items => |nodes| if (i < nodes.len) {
                try roots.append(e.scratch, nodes[@intCast(i)]);
                try owners.append(e.scratch, .{ .slot = @intCast(si), .kind = .all });
            },
            .items => |it| if (i >= it.from) {
                try roots.append(e.scratch, it.node);
                try owners.append(e.scratch, .{ .slot = @intCast(si), .kind = .all });
            },
            .contains => |ct| {
                try roots.append(e.scratch, ct.node);
                try owners.append(e.scratch, .{ .slot = @intCast(si), .kind = .contains });
            },
            else => {},
        };
    }
    try child(e, at, compound, roots.items, owners.items);
}

/// Reads the next member's or item's value against `roots`, each outcome
/// to its owner.
fn child(e: *Evaluator, at: *Location, compound: anytype, roots: []const Node, owners: []const Owner) !void {
    if (roots.len == 0) {
        _ = try compound.hold();
        return;
    }
    const inner = try e.open(roots);
    defer e.close(inner);
    if (inner.wantsEncoding(e.program)) {
        // A container's `const` or `enum`: the value is read whole once for
        // its encoding, then streamed for everything else.
        const held = try compound.hold();
        const whole = try compound.readHeld(Value, held);
        inner.encoding = canonical.encodeAlloc(e.scratch, whole, e.limits.exponent) catch |err| return switch (err) {
            error.Invalid => error.TooLarge,
            else => |x| x,
        };
        try compound.readHeldSeed(Read{ .e = e, .at = inner }, held);
    } else {
        try compound.elementSeed(Read{ .e = e, .at = inner });
    }
    for (owners, 0..) |owner, k| {
        const valid = inner.outcome(k);
        const s = &at.slots.items[owner.slot];
        switch (owner.kind) {
            .all => if (!valid) {
                s.ok = false;
            },
            .contains => if (valid) {
                s.contained += 1;
            },
        }
    }
}

fn finishObject(e: *Evaluator, at: *Location) Error!void {
    for (at.slots.items) |*s| {
        if (!s.ok or e.program.node(s.node).verdict != .keywords) continue;
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
                s.ok = false;
                break;
            }
        }
    }
}

fn finishArray(e: *Evaluator, at: *Location) Error!void {
    for (at.slots.items) |*s| {
        if (!s.ok or e.program.node(s.node).verdict != .keywords) continue;
        for (e.program.instructionsOf(s.node)) |ins| {
            const pass = switch (ins.op) {
                .min_items => |m| s.count >= m,
                .max_items => |m| s.count <= m,
                .contains => |ct| s.contained >= ct.min and (ct.max == null or s.contained <= ct.max.?),
                else => true,
            };
            if (!pass) {
                s.ok = false;
                break;
            }
        }
    }
}

/// Each slot's outcome from its own checks and its children's, the deepest
/// first: a slot's children were made after it.
fn settle(e: *Evaluator, at: *Location) void {
    var i = at.slots.items.len;
    while (i > 0) {
        i -= 1;
        const s = &at.slots.items[i];
        if (e.program.node(s.node).verdict != .keywords) continue;
        var link = s.links;
        var ok = s.ok;
        for (e.program.instructionsOf(s.node)) |ins| switch (ins.op) {
            .ref, .dynamic_ref, .recursive_ref => {
                ok = ok and at.slots.items[at.links.items[link]].ok;
                link += 1;
            },
            .all_of => |nodes| {
                for (nodes) |_| {
                    ok = ok and at.slots.items[at.links.items[link]].ok;
                    link += 1;
                }
            },
            .any_of => |nodes| {
                var any = false;
                for (nodes) |_| {
                    any = any or at.slots.items[at.links.items[link]].ok;
                    link += 1;
                }
                ok = ok and any;
            },
            .one_of => |nodes| {
                var valid: usize = 0;
                for (nodes) |_| {
                    if (at.slots.items[at.links.items[link]].ok) valid += 1;
                    link += 1;
                }
                ok = ok and valid == 1;
            },
            .not => {
                ok = ok and !at.slots.items[at.links.items[link]].ok;
                link += 1;
            },
            .conditional => |c| {
                const condition = at.slots.items[at.links.items[link]].ok;
                link += 1;
                var then_ok = true;
                var else_ok = true;
                if (c.then != null) {
                    then_ok = at.slots.items[at.links.items[link]].ok;
                    link += 1;
                }
                if (c.@"else" != null) {
                    else_ok = at.slots.items[at.links.items[link]].ok;
                    link += 1;
                }
                ok = ok and (if (condition) then_ok else else_ok);
            },
            .dependent_schemas => |deps| for (deps) |dep| {
                // Applies only where its member is present.
                if (s.present(dep.name)) ok = ok and at.slots.items[at.links.items[link]].ok;
                link += 1;
            },
            else => {},
        };
        s.ok = ok;
    }
}
