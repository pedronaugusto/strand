//! A compiled schema: every subschema a node, every keyword an instruction
//! with its operands resolved: a reference to the node it names, `enum` and
//! `const` to canonical encodings, numbers to exact decimals. A node's
//! instructions run cheapest first, so a failing check is met before the
//! work beneath it.
const Program = @This();
const std = @import("std");
const aegis = @import("aegis");
const strand = @import("strand");
const Decimal = @import("Decimal.zig");
const dialect = @import("dialect.zig");

/// A node of one program: positions only, branded so they are no other
/// integer.
pub const Node = aegis.handle.Index(Program, u32);

nodes: []const NodeInfo,
instructions: []const Instruction,
/// The node a validation starts at.
root: Node,

pub const NodeInfo = struct {
    /// `true` and `false` decide alone; a schema object runs its
    /// instructions.
    verdict: enum { any, none, keywords },
    /// Its instructions: `instructions[first..][0..count]`.
    first: u32 = 0,
    count: u32 = 0,
    /// The schema it was compiled from, in the program's own documents.
    source: *const strand.json.Value,
    /// The base URI of the resource it is in: entering it adds the resource
    /// to the dynamic scope a `$dynamicRef` searches.
    base: []const u8,
};

pub const Instruction = struct {
    /// The keyword it was compiled from, which a keyword location names.
    keyword: dialect.Keyword,
    op: Op,
};

/// JSON's types as `type` names them; `integer` is a number with no
/// fractional part.
pub const Type = enum { null, boolean, object, array, number, string, integer };
pub const Types = std.EnumSet(Type);

pub const Property = struct { name: []const u8, node: Node };
pub const PatternProperty = struct { pattern: []const u8, node: Node };
pub const Dependency = struct { name: []const u8, required: []const []const u8 };

pub const Op = union(enum) {
    type: Types,
    /// The canonical encoding the value must have.
    @"const": []const u8,
    /// The canonical encodings, one of which the value must have.
    @"enum": []const []const u8,
    minimum: Decimal,
    exclusive_minimum: Decimal,
    maximum: Decimal,
    exclusive_maximum: Decimal,
    /// Positive.
    multiple_of: Decimal,
    /// Lengths in code points; a bound past `u64` saturates, since no
    /// instance reaches it.
    min_length: u64,
    max_length: u64,
    /// An ECMAScript pattern, compiled when patterns are.
    pattern: []const u8,
    format: []const u8,
    min_items: u64,
    max_items: u64,
    unique_items,
    /// Items by position: 2020-12's `prefixItems`, the earlier drafts'
    /// array `items`.
    prefix_items: []const Node,
    /// Every item from position `from` on: 2020-12's `items` (from the
    /// length of `prefixItems`), an earlier draft's schema `items` (from 0)
    /// or `additionalItems` (from the length of `items`).
    items: struct { from: u64, node: Node },
    /// At least `min` and at most `max` items valid against `node`.
    contains: struct { node: Node, min: u64, max: ?u64 },
    min_properties: u64,
    max_properties: u64,
    required: []const []const u8,
    properties: []const Property,
    pattern_properties: []const PatternProperty,
    /// Every member neither `names` nor `patterns` (its siblings
    /// `properties` and `patternProperties`) matches.
    additional_properties: struct { node: Node, names: []const []const u8, patterns: []const []const u8 },
    property_names: Node,
    dependent_required: []const Dependency,
    dependent_schemas: []const Property,
    all_of: []const Node,
    any_of: []const Node,
    one_of: []const Node,
    not: Node,
    /// `if`, and `then` or `else` by its outcome; `if` alone is still
    /// evaluated for what it annotates.
    conditional: struct { @"if": Node, then: ?Node, @"else": ?Node },
    ref: Node,
    /// 2020-12: the anchor's name the dynamic scope is searched for, and the
    /// node the reference names statically, used when the search finds
    /// none or the static target is no dynamic anchor.
    dynamic_ref: struct { node: Node, anchor: ?[]const u8 },
    /// 2019-09: the node `$recursiveRef` names statically; the dynamic
    /// scope's outermost `$recursiveAnchor` replaces it when that node has
    /// one.
    recursive_ref: struct { node: Node, anchored: bool },
    unevaluated_items: Node,
    unevaluated_properties: Node,

    /// The order a node runs its instructions in: what decides from the
    /// value alone first, then what counts, then what descends, and last
    /// what depends on what its siblings evaluated.
    pub fn cost(op: Op) u8 {
        return switch (op) {
            .type => 0,
            .minimum, .exclusive_minimum, .maximum, .exclusive_maximum, .min_length, .max_length => 1,
            .min_items, .max_items, .min_properties, .max_properties, .required, .dependent_required => 1,
            .@"const", .@"enum", .multiple_of => 2,
            .format, .pattern => 3,
            .unique_items => 4,
            .prefix_items, .items, .contains, .properties, .pattern_properties, .additional_properties, .property_names => 5,
            .ref, .dynamic_ref, .recursive_ref => 6,
            .all_of, .any_of, .one_of, .not, .conditional, .dependent_schemas => 7,
            .unevaluated_items, .unevaluated_properties => 9,
        };
    }

    /// The nodes it applies at the same instance location as its own, which
    /// a reference cycle runs through without reading any of the instance.
    pub fn inPlace(op: Op, out: *std.ArrayList(Node), gpa: std.mem.Allocator) error{OutOfMemory}!void {
        switch (op) {
            .ref => |n| try out.append(gpa, n),
            .dynamic_ref => |d| try out.append(gpa, d.node),
            .recursive_ref => |r| try out.append(gpa, r.node),
            .all_of, .any_of, .one_of => |nodes| try out.appendSlice(gpa, nodes),
            .not => |n| try out.append(gpa, n),
            .conditional => |c| {
                try out.append(gpa, c.@"if");
                if (c.then) |n| try out.append(gpa, n);
                if (c.@"else") |n| try out.append(gpa, n);
            },
            .dependent_schemas => |list| for (list) |p| try out.append(gpa, p.node),
            else => {},
        }
    }
};

/// `n`'s record.
pub fn node(p: *const Program, n: Node) *const NodeInfo {
    return n.get(p.nodes) catch aegis.assert.never("a node is the program's own");
}

/// `n`'s instructions, in the order they run.
pub fn instructionsOf(p: *const Program, n: Node) []const Instruction {
    const info = p.node(n);
    return p.instructions[info.first..][0..info.count];
}

test "an op's cost puts what depends on its siblings last" {
    const n: Node = @fromBackingInt(0);
    try std.testing.expect(Op.cost(.{ .type = .empty }) < Op.cost(.{ .properties = &.{} }));
    try std.testing.expect(Op.cost(.{ .all_of = &.{} }) < Op.cost(.{ .unevaluated_properties = n }));
    try std.testing.expect(Op.cost(.{ .required = &.{} }) < Op.cost(.{ .ref = n }));
}
