//! A doctype's internal subset: its grammar checked whole (element, attribute
//! list, entity and notation declarations, comments, processing
//! instructions, parameter-entity references between declarations), and its
//! entity declarations kept, which is all of a DTD a reader that does not
//! validate takes. An internal parameter entity referred to between
//! declarations is read in place, as declarations; an external one is never
//! read, and the declarations after it are checked but not taken, as XML 1.0
//! §5.1 asks. A general entity's replacement text is its literal with
//! character references expanded and other references left for its use.
//! Nothing is fetched: an external entity is a name and an identifier.
const std = @import("std");
const core = @import("../core.zig");
const text = @import("text.zig");

pub const Error = error{ SyntaxError, InvalidUtf8, DepthLimit, ItemLimit, LengthLimit, WorkLimit, AllocationLimit, OutOfMemory };

pub const Entity = struct {
    kind: Kind,
    /// An internal entity's replacement text, in `Dtd.replacement`.
    start: u32 = 0,
    len: u32 = 0,
    pub const Kind = enum { internal, external, unparsed };
};

pub const Dtd = struct {
    general: std.StringHashMapUnmanaged(Entity) = .empty,
    parameter: std.StringHashMapUnmanaged(Entity) = .empty,
    /// The replacement texts of internal entities, one after another.
    replacement: std.ArrayList(u8) = .empty,
    /// The subset refers to a parameter entity, or there is an external
    /// subset: an undeclared entity may then be declared where strand does
    /// not read, and is refused as unread rather than as not well-formed.
    unread: bool = false,
    /// Copies of parameter entities' text read as declarations: the names
    /// declared there are kept by the tables.
    copies: std.ArrayList([]u8) = .empty,

    pub fn replacementOf(self: *const Dtd, entity: Entity) []const u8 {
        return self.replacement.items[entity.start..][0..entity.len];
    }
    pub fn deinit(self: *Dtd, allocator: std.mem.Allocator) void {
        self.general.deinit(allocator);
        self.parameter.deinit(allocator);
        self.replacement.deinit(allocator);
        for (self.copies.items) |copy| allocator.free(copy);
        self.copies.deinit(allocator);
    }
};

const Reader = struct {
    dtd: *Dtd,
    allocator: std.mem.Allocator,
    c: *core.Context,
    /// Declarations are taken until an external parameter entity is referred to.
    taking: bool = true,
    /// The parameter entities being read, for a reference to one inside itself.
    reading: std.ArrayList([]const u8) = .empty,
    failed_at: *usize,
    /// Where the text being read starts in the input, when it is the input.
    base: ?usize,
    /// Names of entities and notations are held to Namespaces in XML.
    namespaces: bool,

    fn fail(r: *Reader, bytes: []const u8, i: usize) error{SyntaxError} {
        r.failed_at.* = if (r.base) |b| b + i else r.failed_at.*;
        _ = bytes;
        return error.SyntaxError;
    }
    fn spaces(bytes: []const u8, at: usize) usize {
        var i = at;
        while (i < bytes.len and text.isSpace(bytes[i])) i += 1;
        return i;
    }
    /// At least one space at `at`, and the position after all of them.
    fn requireSpace(r: *Reader, bytes: []const u8, at: usize) Error!usize {
        if (at >= bytes.len or !text.isSpace(bytes[at])) return r.fail(bytes, at);
        return spaces(bytes, at);
    }
    fn name(r: *Reader, bytes: []const u8, at: usize) Error![]const u8 {
        const n = text.nameLength(bytes[at..]) orelse return error.InvalidUtf8;
        if (n == 0) return r.fail(bytes, at);
        try r.c.span(n, true);
        return bytes[at..][0..n];
    }
    fn chars(r: *Reader, bytes: []const u8, at: usize) Error!void {
        var i: usize = 0;
        while (i < bytes.len) {
            const d = text.decode(bytes, i) orelse return error.InvalidUtf8;
            if (!text.isChar(d.c)) return r.fail(bytes, at + i);
            i += d.len;
        }
    }

    /// `(markupdecl | DeclSep)*` over all of `bytes`.
    fn declarations(r: *Reader, bytes: []const u8) Error!void {
        var i: usize = 0;
        while (true) {
            i = spaces(bytes, i);
            if (i >= bytes.len) return;
            try r.c.chargeWork(1);
            if (bytes[i] == '%') {
                i = try r.parameterReference(bytes, i);
            } else if (std.mem.startsWith(u8, bytes[i..], "<!--")) {
                const end = std.mem.findPos(u8, bytes, i + 4, "--") orelse return r.fail(bytes, i);
                if (end + 2 >= bytes.len or bytes[end + 2] != '>') return r.fail(bytes, end);
                try r.chars(bytes[i + 4 .. end], i + 4);
                i = end + 3;
            } else if (std.mem.startsWith(u8, bytes[i..], "<?")) {
                i = try r.instruction(bytes, i);
            } else if (std.mem.startsWith(u8, bytes[i..], "<!ENTITY")) {
                i = try r.entityDecl(bytes, i + 8);
            } else if (std.mem.startsWith(u8, bytes[i..], "<!ELEMENT")) {
                i = try r.elementDecl(bytes, i + 9);
            } else if (std.mem.startsWith(u8, bytes[i..], "<!ATTLIST")) {
                i = try r.attlist(bytes, i + 9);
            } else if (std.mem.startsWith(u8, bytes[i..], "<!NOTATION")) {
                i = try r.notationDecl(bytes, i + 10);
            } else return r.fail(bytes, i);
        }
    }

    /// `%name;` between declarations: an internal entity read in place, an
    /// external one left unread (and the declarations after it not taken).
    fn parameterReference(r: *Reader, bytes: []const u8, at: usize) Error!usize {
        const n = try r.name(bytes, at + 1);
        const end = at + 1 + n.len;
        if (end >= bytes.len or bytes[end] != ';') return r.fail(bytes, end);
        r.dtd.unread = true;
        const entity = r.dtd.parameter.get(n) orelse {
            // An undeclared parameter entity: nothing more is taken.
            r.taking = false;
            return end + 1;
        };
        if (entity.kind != .internal) {
            r.taking = false;
            return end + 1;
        }
        for (r.reading.items) |open| if (std.mem.eql(u8, open, n)) return r.fail(bytes, at);
        if (r.reading.items.len >= r.c.limits.depth) return error.DepthLimit;
        try r.reading.append(r.allocator, n);
        defer _ = r.reading.pop();
        // Its replacement text may move as declarations add to the buffer:
        // read from a copy of it.
        // Read from a copy kept as long as the tables: the buffer may move
        // as declarations add to it, and the names it declares stay.
        try r.dtd.copies.ensureUnusedCapacity(r.allocator, 1);
        const replacement = try r.allocator.dupe(u8, r.dtd.replacementOf(entity));
        r.dtd.copies.appendAssumeCapacity(replacement);
        try r.c.chargeWork(replacement.len);
        const base = r.base;
        r.base = null;
        defer r.base = base;
        try r.declarations(replacement);
        return end + 1;
    }

    fn instruction(r: *Reader, bytes: []const u8, at: usize) Error!usize {
        const target = try r.name(bytes, at + 2);
        if (std.ascii.eqlIgnoreCase(target, "xml")) return r.fail(bytes, at);
        var i = at + 2 + target.len;
        const end = std.mem.findPos(u8, bytes, i, "?>") orelse return r.fail(bytes, at);
        if (end != i) {
            if (!text.isSpace(bytes[i])) return r.fail(bytes, i);
            i = spaces(bytes, i);
            if (i < end) try r.chars(bytes[i..end], i);
        }
        return end + 2;
    }

    /// A quoted literal: its contents and the position after it.
    fn literal(r: *Reader, bytes: []const u8, at: usize) Error!struct { value: []const u8, end: usize } {
        if (at >= bytes.len or (bytes[at] != '"' and bytes[at] != '\'')) return r.fail(bytes, at);
        const close = std.mem.findScalarPos(u8, bytes, at + 1, bytes[at]) orelse return r.fail(bytes, at);
        try r.chars(bytes[at + 1 .. close], at + 1);
        return .{ .value = bytes[at + 1 .. close], .end = close + 1 };
    }
    /// `ExternalID` at `at`, or null where none starts; with `public_only` a
    /// `PUBLIC` identifier may stand alone (a notation's).
    fn externalId(r: *Reader, bytes: []const u8, at: usize, public_only: bool) Error!?usize {
        const public = std.mem.startsWith(u8, bytes[at..], "PUBLIC");
        if (!public and !std.mem.startsWith(u8, bytes[at..], "SYSTEM")) return null;
        var i = try r.requireSpace(bytes, at + 6);
        if (public) {
            const p = try r.literal(bytes, i);
            for (p.value) |b| if (!isPubidChar(b)) return r.fail(bytes, i);
            i = p.end;
            if (public_only) {
                const after = spaces(bytes, i);
                if (after == i or after >= bytes.len or (bytes[after] != '"' and bytes[after] != '\'')) return i;
                i = after;
            } else i = try r.requireSpace(bytes, i);
        }
        return (try r.literal(bytes, i)).end;
    }
    fn isPubidChar(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or std.mem.findScalar(u8, " \r\n-'()+,./:=?;!*#@$_%", b) != null;
    }
    /// The end of a declaration: optional space, then `>`.
    fn closeDecl(r: *Reader, bytes: []const u8, at: usize) Error!usize {
        const i = spaces(bytes, at);
        if (i >= bytes.len or bytes[i] != '>') return r.fail(bytes, i);
        return i + 1;
    }

    fn entityDecl(r: *Reader, bytes: []const u8, at: usize) Error!usize {
        var i = try r.requireSpace(bytes, at);
        var is_parameter = false;
        if (i < bytes.len and bytes[i] == '%') {
            is_parameter = true;
            i = try r.requireSpace(bytes, i + 1);
        }
        const n = try r.name(bytes, i);
        if (r.namespaces and std.mem.findScalar(u8, n, ':') != null) return r.fail(bytes, i);
        i = try r.requireSpace(bytes, i + n.len);
        var declared: Entity = undefined;
        if (try r.externalId(bytes, i, false)) |end| {
            i = end;
            declared = .{ .kind = .external };
            const after = spaces(bytes, i);
            if (std.mem.startsWith(u8, bytes[after..], "NDATA")) {
                if (is_parameter or after == i) return r.fail(bytes, after);
                i = try r.requireSpace(bytes, after + 5);
                i += (try r.name(bytes, i)).len;
                declared = .{ .kind = .unparsed };
            }
        } else {
            const value = try r.literal(bytes, i);
            declared = try r.entityValue(bytes, value.value, i + 1);
            i = value.end;
        }
        i = try r.closeDecl(bytes, i);
        // The first declaration binds; one after an unread parameter entity
        // is not taken.
        if (r.taking) {
            const table = if (is_parameter) &r.dtd.parameter else &r.dtd.general;
            if (table.count() >= r.c.limits.container_items) return error.ItemLimit;
            const slot = try table.getOrPut(r.allocator, n);
            if (!slot.found_existing) slot.value_ptr.* = declared;
        }
        return i;
    }
    /// An entity's literal as its replacement text: line ends made line
    /// feeds, character references expanded, other references checked and kept; no parameter-entity
    /// reference, which the internal subset refuses inside a declaration.
    fn entityValue(r: *Reader, bytes: []const u8, value: []const u8, at: usize) Error!Entity {
        const out = &r.dtd.replacement;
        const start = out.items.len;
        if (start + value.len > std.math.maxInt(u32)) return error.LengthLimit;
        try r.c.chargeWork(value.len);
        // Line ends of the input are line feeds; a carriage return in a
        // parameter entity's text came from a character reference and stays.
        const input = r.base != null;
        var i: usize = 0;
        while (i < value.len) {
            const k = std.mem.findAnyPos(u8, value, i, if (input) "&%\r" else "&%") orelse value.len;
            try out.appendSlice(r.allocator, value[i..k]);
            if (k == value.len) break;
            if (value[k] == '\r') {
                try out.append(r.allocator, '\n');
                i = if (k + 1 < value.len and value[k + 1] == '\n') k + 2 else k + 1;
                continue;
            }
            if (value[k] == '%') return r.fail(bytes, at + k);
            const ref = try reference(value, k) orelse return r.fail(bytes, at + k);
            switch (ref) {
                .char => |cp| {
                    var buffer: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp.value, &buffer) catch unreachable; // unreachable: a Char is a scalar.
                    try out.appendSlice(r.allocator, buffer[0..len]);
                    i = cp.end;
                },
                .entity => |e| {
                    try out.appendSlice(r.allocator, value[k..e.end]);
                    i = e.end;
                },
            }
        }
        if (out.items.len > std.math.maxInt(u32)) return error.LengthLimit;
        return .{ .kind = .internal, .start = @intCast(start), .len = @intCast(out.items.len - start) };
    }

    fn elementDecl(r: *Reader, bytes: []const u8, at: usize) Error!usize {
        var i = try r.requireSpace(bytes, at);
        i += (try r.name(bytes, i)).len;
        i = try r.requireSpace(bytes, i);
        if (std.mem.startsWith(u8, bytes[i..], "EMPTY")) {
            i += 5;
        } else if (std.mem.startsWith(u8, bytes[i..], "ANY")) {
            i += 3;
        } else {
            if (i >= bytes.len or bytes[i] != '(') return r.fail(bytes, i);
            const after = spaces(bytes, i + 1);
            if (std.mem.startsWith(u8, bytes[after..], "#PCDATA")) {
                i = try r.mixed(bytes, after + 7);
            } else {
                i = try r.particle(bytes, i, 0);
            }
        }
        return r.closeDecl(bytes, i);
    }
    /// `Mixed` after `(#PCDATA`.
    fn mixed(r: *Reader, bytes: []const u8, at: usize) Error!usize {
        var i = spaces(bytes, at);
        var names: usize = 0;
        while (i < bytes.len and bytes[i] == '|') {
            i = spaces(bytes, i + 1);
            i += (try r.name(bytes, i)).len;
            i = spaces(bytes, i);
            names += 1;
        }
        if (i >= bytes.len or bytes[i] != ')') return r.fail(bytes, i);
        i += 1;
        if (i < bytes.len and bytes[i] == '*') return i + 1;
        if (names != 0) return r.fail(bytes, i);
        return i;
    }
    /// `cp`: a name, or a choice or sequence in parentheses, then `?`, `*` or `+`.
    fn particle(r: *Reader, bytes: []const u8, at: usize, level: usize) Error!usize {
        if (level >= r.c.limits.depth) return error.DepthLimit;
        try r.c.chargeWork(1);
        var i = at;
        if (i < bytes.len and bytes[i] == '(') {
            i = spaces(bytes, i + 1);
            i = try r.particle(bytes, i, level + 1);
            i = spaces(bytes, i);
            var separator: ?u8 = null;
            while (i < bytes.len and (bytes[i] == '|' or bytes[i] == ',')) {
                if (separator) |s| if (s != bytes[i]) return r.fail(bytes, i);
                separator = bytes[i];
                i = spaces(bytes, i + 1);
                i = try r.particle(bytes, i, level + 1);
                i = spaces(bytes, i);
            }
            if (i >= bytes.len or bytes[i] != ')') return r.fail(bytes, i);
            i += 1;
        } else {
            i += (try r.name(bytes, i)).len;
        }
        if (i < bytes.len and (bytes[i] == '?' or bytes[i] == '*' or bytes[i] == '+')) i += 1;
        return i;
    }

    fn attlist(r: *Reader, bytes: []const u8, at: usize) Error!usize {
        var i = try r.requireSpace(bytes, at);
        i += (try r.name(bytes, i)).len;
        while (true) {
            const before = i;
            i = spaces(bytes, i);
            if (i < bytes.len and bytes[i] == '>') return i + 1;
            if (i == before) return r.fail(bytes, i);
            try r.c.chargeWork(1);
            i += (try r.name(bytes, i)).len;
            i = try r.requireSpace(bytes, i);
            i = try r.attributeType(bytes, i);
            i = try r.requireSpace(bytes, i);
            if (std.mem.startsWith(u8, bytes[i..], "#REQUIRED")) {
                i += 9;
            } else if (std.mem.startsWith(u8, bytes[i..], "#IMPLIED")) {
                i += 8;
            } else {
                if (std.mem.startsWith(u8, bytes[i..], "#FIXED")) i = try r.requireSpace(bytes, i + 6);
                const value = try r.literal(bytes, i);
                try r.defaultValue(bytes, value.value, i + 1);
                i = value.end;
            }
        }
    }
    fn attributeType(r: *Reader, bytes: []const u8, at: usize) Error!usize {
        const types = [_][]const u8{ "CDATA", "IDREFS", "IDREF", "ID", "ENTITIES", "ENTITY", "NMTOKENS", "NMTOKEN" };
        for (types) |t| if (std.mem.startsWith(u8, bytes[at..], t)) return at + t.len;
        var i = at;
        var notation = false;
        if (std.mem.startsWith(u8, bytes[i..], "NOTATION")) {
            notation = true;
            i = try r.requireSpace(bytes, i + 8);
        }
        if (i >= bytes.len or bytes[i] != '(') return r.fail(bytes, i);
        while (true) {
            i = spaces(bytes, i + 1);
            const start = i;
            while (i < bytes.len and !text.isSpace(bytes[i]) and bytes[i] != '|' and bytes[i] != ')') i += 1;
            const token = bytes[start..i];
            if (if (notation) !text.isWholeName(token) else !text.isNmtoken(token)) return r.fail(bytes, start);
            i = spaces(bytes, i);
            if (i >= bytes.len) return r.fail(bytes, i);
            if (bytes[i] == ')') return i + 1;
            if (bytes[i] != '|') return r.fail(bytes, i);
        }
    }
    /// An attribute's default value: an attribute value's grammar, and each
    /// entity it refers to declared before it, internal, and holding no `<`.
    fn defaultValue(r: *Reader, bytes: []const u8, value: []const u8, at: usize) Error!void {
        if (!try r.attributeText(value)) return r.fail(bytes, at);
    }
    /// Whether an attribute value's text holds no `<` and refers only to
    /// entities that are declared (where every declaration was read),
    /// internal, and do the same, none inside itself.
    fn attributeText(r: *Reader, value: []const u8) Error!bool {
        var i: usize = 0;
        while (std.mem.findAnyPos(u8, value, i, "&<")) |k| {
            if (value[k] == '<') return false;
            const ref = try reference(value, k) orelse return false;
            switch (ref) {
                .char => |cp| i = cp.end,
                .entity => |e| {
                    i = e.end;
                    if (isPredefined(e.name) != null) continue;
                    const found = r.dtd.general.get(e.name) orelse {
                        if (!r.dtd.unread) return false;
                        continue;
                    };
                    if (found.kind != .internal) return false;
                    for (r.reading.items) |open| if (std.mem.eql(u8, open, e.name)) return false;
                    if (r.reading.items.len >= r.c.limits.depth) return error.DepthLimit;
                    try r.c.chargeWork(found.len + 1);
                    try r.reading.append(r.allocator, e.name);
                    defer _ = r.reading.pop();
                    if (!try r.attributeText(r.dtd.replacementOf(found))) return false;
                },
            }
        }
        return true;
    }

    fn notationDecl(r: *Reader, bytes: []const u8, at: usize) Error!usize {
        var i = try r.requireSpace(bytes, at);
        const n = try r.name(bytes, i);
        if (r.namespaces and std.mem.findScalar(u8, n, ':') != null) return r.fail(bytes, i);
        i += n.len;
        i = try r.requireSpace(bytes, i);
        i = (try r.externalId(bytes, i, true)) orelse return r.fail(bytes, i);
        return r.closeDecl(bytes, i);
    }
};

/// Reads the internal subset `subset` (at `at` in the input) into `dtd`.
/// `external` says whether the doctype names an external subset.
pub fn read(c: *core.Context, allocator: std.mem.Allocator, dtd: *Dtd, subset: []const u8, at: usize, external: bool, namespaces: bool, failed_at: *usize) Error!void {
    if (external) dtd.unread = true;
    var r: Reader = .{ .dtd = dtd, .allocator = allocator, .c = c, .failed_at = failed_at, .base = at, .namespaces = namespaces };
    defer r.reading.deinit(allocator);
    try r.declarations(subset);
}

pub const Reference = union(enum) {
    char: struct { value: u21, end: usize },
    entity: struct { name: []const u8, end: usize },
};
/// The reference at `at` (an `&`) in `bytes`, or null where it is not one.
pub fn reference(bytes: []const u8, at: usize) Error!?Reference {
    var i = at + 1;
    if (i < bytes.len and bytes[i] == '#') {
        i += 1;
        const hex = i < bytes.len and bytes[i] == 'x';
        if (hex) i += 1;
        const start = i;
        var value: u32 = 0;
        while (i < bytes.len and bytes[i] != ';') : (i += 1) {
            const d = std.fmt.charToDigit(bytes[i], if (hex) 16 else 10) catch return null;
            value = value * (if (hex) @as(u32, 16) else 10) + d;
            if (value > 0x10FFFF) return null;
        }
        if (i == start or i >= bytes.len or !text.isChar(@intCast(value))) return null;
        return .{ .char = .{ .value = @intCast(value), .end = i + 1 } };
    }
    const n = text.nameLength(bytes[i..]) orelse return error.InvalidUtf8;
    if (n == 0 or i + n >= bytes.len or bytes[i + n] != ';') return null;
    return .{ .entity = .{ .name = bytes[i..][0..n], .end = i + n + 1 } };
}

/// The five entities XML predefines, as the character each stands for.
pub fn isPredefined(n: []const u8) ?u8 {
    if (std.mem.eql(u8, n, "lt")) return '<';
    if (std.mem.eql(u8, n, "gt")) return '>';
    if (std.mem.eql(u8, n, "amp")) return '&';
    if (std.mem.eql(u8, n, "apos")) return '\'';
    if (std.mem.eql(u8, n, "quot")) return '"';
    return null;
}

test "an internal subset's entities" {
    var c: core.Context = .init(std.testing.allocator, .{}, .borrowed);
    var dtd: Dtd = .{};
    defer dtd.deinit(std.testing.allocator);
    var failed: usize = 0;
    const subset =
        \\<!ELEMENT a (b|c)*> <!ELEMENT b (#PCDATA|c)*> <!ATTLIST a x CDATA #IMPLIED y (p|q) "p">
        \\<!ENTITY e "x&#65;&f;"> <!ENTITY e "ignored"> <!ENTITY % p "<!ENTITY g 'G'>"> %p;
        \\<!ENTITY ext SYSTEM "a.xml"> <!NOTATION n PUBLIC "x"> <!-- c --> <?pi x?>
    ;
    try read(&c, std.testing.allocator, &dtd, subset, 0, false, true, &failed);
    try std.testing.expectEqualStrings("xA&f;", dtd.replacementOf(dtd.general.get("e").?));
    try std.testing.expectEqualStrings("G", dtd.replacementOf(dtd.general.get("g").?));
    try std.testing.expectEqual(Entity.Kind.external, dtd.general.get("ext").?.kind);
    for ([_][]const u8{ "<!ENTITY e \"%p;\">", "<!ELEMENT a (b|c,d)>", "<!ENTITY a>", "<!FOO>", "<!ENTITY % p '<!ENTITY'> %p;", "<!ATTLIST a x CDATA \"&u;\">" }) |bad| {
        var d: Dtd = .{};
        defer d.deinit(std.testing.allocator);
        try std.testing.expectError(error.SyntaxError, read(&c, std.testing.allocator, &d, bad, 0, false, true, &failed));
    }
}
