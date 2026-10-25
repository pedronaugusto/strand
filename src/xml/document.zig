//! A document read into nodes: each element followed by its attributes and
//! then its content, each knowing where it ends, so a value can be walked
//! again (a union tagged inside its element) and repeated children found
//! wherever they stand. A text node is a maximal run of character data
//! between two elements: CDATA sections, references and the text of
//! entities joined into it, comments and processing instructions passed
//! over.
//!
//! What a doctype's internal subset declares is honoured as XML asks of a
//! reader that does not validate: an internal entity's replacement text is
//! read where it is referred to, as content or as part of an attribute value,
//! each expansion charged as work and its nodes and bytes to the operation's
//! limits as they are made, so an entity that would grow a document without
//! end is refused once it has grown past them; an entity referring to itself
//! is refused. An external entity is never fetched: a reference to one is
//! `UnsupportedValue`. Namespace declarations are scope, not attributes: their
//! nodes are marked so, and every prefix used is checked as bound.
const std = @import("std");
const core = @import("../core.zig");
const text = @import("text.zig");
const Scanner = @import("Scanner.zig");
const dtd_reader = @import("dtd.zig");

pub const Error = core.DecodeError;
pub const Source = enum(u2) { input, replacement, decoded };
pub const Kind = enum(u2) { element, attribute, text };
pub const Span32 = struct { start: u32 = 0, len: u32 = 0 };

/// A node: 28 bytes.
pub const Node = struct {
    kind: Kind,
    name_source: Source = .input,
    value_source: Source = .input,
    /// An element some text run of which is not all white space: its
    /// content is mixed, and its white space is content too.
    mixed: bool = false,
    /// A text run of white space alone.
    blank: bool = false,
    /// An attribute that declares a namespace: scope, which a map of an
    /// element's content keeps and a record does not.
    declaration: bool = false,
    /// An element that holds a child element.
    elements: bool = false,
    /// An element's name; an attribute's key, `@` and its name.
    name: Span32 = .{},
    /// An attribute's value; a text run's bytes; an element's attribute count
    /// in `start`.
    value: Span32 = .{},
    /// The position after the node and everything under it.
    end: u32 = 0,
    /// Where it was written.
    at: u32 = 0,

    pub fn attributes(self: Node) u32 {
        return self.value.start;
    }
};

pub const Options = struct {
    /// Check names against Namespaces in XML 1.0.
    namespaces: bool = true,
};

pub const Document = struct {
    /// The document's text: the input, or its UTF-16 transcoded.
    source: []const u8,
    /// Whether `source` is the caller's input, which a result may borrow.
    borrowed: bool,
    nodes: std.ArrayList(Node),
    decoded: std.ArrayList(u8),
    dtd: dtd_reader.Dtd,
    transcoded: ?[]u8,
    /// The byte-order mark the input started with.
    mark: enum { none, utf8, utf16 } = .none,

    fn bytesOf(self: *const Document, source: Source) []const u8 {
        return switch (source) {
            .input => self.source,
            .replacement => self.dtd.replacement.items,
            .decoded => self.decoded.items,
        };
    }
    pub fn lifetime(self: *const Document, source: Source) core.Lifetime {
        return if (source == .input and self.borrowed) .borrowed else .transient;
    }
    pub fn name(self: *const Document, node: Node) []const u8 {
        return self.bytesOf(node.name_source)[node.name.start..][0..node.name.len];
    }
    pub fn value(self: *const Document, node: Node) core.Span {
        return .{ .bytes = self.bytesOf(node.value_source)[node.value.start..][0..node.value.len], .lifetime = self.lifetime(node.value_source) };
    }
    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
        self.decoded.deinit(allocator);
        self.dtd.deinit(allocator);
        if (self.transcoded) |t| allocator.free(t);
    }
};

const xml_namespace = "http://www.w3.org/XML/1998/namespace";
const xmlns_namespace = "http://www.w3.org/2000/xmlns/";

/// A piece of the text run being made.
const Piece = struct {
    source: Source,
    start: u32,
    len: u32,
    cdata: bool = false,
    /// Its bytes are its text as they are: no reference, no carriage return.
    plain: bool = false,
    blank: bool = false,
};
/// Bytes in one of the document's sources.
const Decoded = struct { source: Source, span: Span32 };
/// A prefix bound in the elements open.
const Binding = struct { prefix: []const u8, uri: Decoded };

const Builder = struct {
    c: *core.Context,
    allocator: std.mem.Allocator,
    doc: *Document,
    options: Options,
    /// The open elements, as their nodes.
    open: std.ArrayList(u32) = .empty,
    run: std.ArrayList(Piece) = .empty,
    run_at: u32 = 0,
    /// The entities being read, to refuse one inside itself.
    expanding: std.ArrayList([]const u8) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    /// Where each open element's bindings start.
    scopes: std.ArrayList(u32) = .empty,
    standalone: bool = false,
    failed_at: *usize,
    /// Where a reference being read was written, for nodes it makes.
    reference_at: ?u32 = null,

    fn deinit(self: *Builder) void {
        self.open.deinit(self.allocator);
        self.run.deinit(self.allocator);
        self.expanding.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
    }
    fn fail(self: *Builder, at: usize) error{SyntaxError} {
        self.failed_at.* = at;
        return error.SyntaxError;
    }
    fn oom(self: *Builder) Error {
        return if (self.c.allocation_limited) error.AllocationLimit else error.OutOfMemory;
    }
    fn append(self: *Builder, node: Node) Error!u32 {
        try self.c.node();
        const index = self.doc.nodes.items.len;
        if (index >= std.math.maxInt(u32)) return error.ItemLimit;
        self.doc.nodes.append(self.allocator, node) catch return self.oom();
        return @intCast(index);
    }
    fn decodedLen(self: *Builder) Error!u32 {
        const len = self.doc.decoded.items.len;
        if (len > std.math.maxInt(u32)) return error.LengthLimit;
        return @intCast(len);
    }
    fn place(self: *Builder, source: Source, offset: usize) u32 {
        if (self.reference_at) |at| return at;
        return if (source == .input) @intCast(offset) else 0;
    }

    /// Reads every token of `scanner`, whose text is `source` from `base`.
    fn tokens(self: *Builder, scanner: *Scanner, source: Source, base: u32) Error!void {
        while (true) {
            const token = scanner.next() catch |err| {
                if (source == .input) self.failed_at.* = scanner.failed_at;
                return err;
            };
            const t = token orelse return;
            const bytes = self.doc.bytesOf(source);
            switch (t) {
                .declaration => |d| try self.declaration(d),
                .doctype => |d| try self.doctype(d),
                .start => |s| try self.startElement(s, source, base, offsetIn(bytes, s.name)),
                .end => try self.endElement(),
                .text => |raw| if (self.open.items.len != 0) try self.textPiece(raw, source, scanner.text_flags, offsetIn(bytes, raw)),
                .cdata => |raw| try self.addPiece(.{ .source = source, .start = offsetIn(bytes, raw), .len = @intCast(raw.len), .cdata = true }, offsetIn(bytes, raw)),
                .comment => {},
                .pi => |p| if (self.options.namespaces and std.mem.findScalar(u8, p.target, ':') != null) return self.fail(offsetIn(bytes, p.target)),
            }
        }
    }
    fn offsetIn(bytes: []const u8, part: []const u8) u32 {
        return @intCast(@intFromPtr(part.ptr) - @intFromPtr(bytes.ptr)); // safe: `part` is a slice of `bytes`.
    }

    /// The declared encoding against the bytes: one the byte-order mark or
    /// the declaration's own bytes contradict is not well-formed; one that
    /// agrees with UTF-8 on ASCII names a document of ASCII alone truly; any
    /// other is an encoding strand does not read.
    fn declaration(self: *Builder, d: Scanner.Declaration) Error!void {
        self.standalone = d.standalone orelse false;
        const e = d.encoding orelse return;
        const utf8 = std.ascii.eqlIgnoreCase(e, "UTF-8") or std.ascii.eqlIgnoreCase(e, "UTF8");
        const utf16 = std.ascii.startsWithIgnoreCase(e, "UTF-16");
        switch (self.doc.mark) {
            .utf16 => return if (utf16) {} else self.fail(0),
            .utf8 => return if (utf8) {} else self.fail(0),
            .none => {},
        }
        if (utf8) return;
        // UTF-16 always starts with its mark: a declaration read as ASCII
        // that names it is in no such encoding.
        if (utf16) return self.fail(0);
        const ascii_compatible = [_][]const u8{ "US-ASCII", "ASCII", "ISO-8859-1", "ISO-8859-15", "LATIN1", "WINDOWS-1252", "ISO646-US" };
        for (ascii_compatible) |a| if (std.ascii.eqlIgnoreCase(e, a)) {
            if (std.mem.findNone(u8, self.doc.source, &ascii_bytes) == null) return;
            return error.UnsupportedValue;
        };
        return error.UnsupportedValue;
    }
    const ascii_bytes = blk: {
        var all: [128]u8 = undefined;
        for (&all, 0..) |*b, i| b.* = i;
        break :blk all;
    };

    fn doctype(self: *Builder, d: Scanner.Doctype) Error!void {
        if (self.options.namespaces and !text.isQName(d.name)) return self.fail(d.internal_at);
        const external = d.system_id != null;
        if (d.internal) |subset| {
            var failed: usize = d.internal_at;
            dtd_reader.read(self.c, self.allocator, &self.doc.dtd, subset, d.internal_at, external, self.options.namespaces, &failed) catch |err| {
                self.failed_at.* = failed;
                return switch (err) {
                    error.OutOfMemory => self.oom(),
                    else => |e| e,
                };
            };
        } else if (external) self.doc.dtd.unread = true;
    }

    fn startElement(self: *Builder, s: Scanner.Start, source: Source, base: u32, name_offset: u32) Error!void {
        try self.closeRun();
        if (self.open.items.len >= self.c.limits.depth) return error.DepthLimit;
        const at = self.place(source, name_offset);
        if (self.open.items.len != 0) self.doc.nodes.items[self.open.items[self.open.items.len - 1]].elements = true;
        const index = try self.append(.{ .kind = .element, .name_source = source, .name = .{ .start = name_offset, .len = @intCast(s.name.len) }, .at = at });
        _ = base;
        self.open.append(self.allocator, index) catch return self.oom();
        self.scopes.append(self.allocator, @intCast(self.bindings.items.len)) catch return self.oom();
        // Namespace declarations first, so the attributes' prefixes see them.
        var attributes = s.attributes();
        while (attributes.next()) |a| {
            if (!isDeclaration(a.name)) continue;
            const uri = try self.attributeValue(a.value, source, offsetIn(self.doc.bytesOf(source), a.value));
            try self.declare(a.name, uri, at);
        }
        var count: u32 = 0;
        attributes = s.attributes();
        while (attributes.next()) |a| {
            const bytes = self.doc.bytesOf(source);
            const value_offset = offsetIn(bytes, a.value);
            const decoded = try self.attributeValue(a.value, source, value_offset);
            // The key: `@` and the name, kept with the decoded bytes.
            const key_start = try self.decodedLen();
            self.doc.decoded.ensureUnusedCapacity(self.allocator, a.name.len + 1) catch return self.oom();
            self.doc.decoded.appendAssumeCapacity('@');
            self.doc.decoded.appendSliceAssumeCapacity(a.name);
            _ = try self.append(.{
                .kind = .attribute,
                .name_source = .decoded,
                .name = .{ .start = key_start, .len = @intCast(a.name.len + 1) },
                .value_source = decoded.source,
                .value = decoded.span,
                .end = @intCast(self.doc.nodes.items.len + 1),
                .at = self.place(source, value_offset),
                .declaration = isDeclaration(a.name),
            });
            count += 1;
        }
        self.doc.nodes.items[index].value.start = count;
        if (self.options.namespaces) try self.checkNames(index, count, at);
        if (s.empty) {} // its end comes as a token of its own
    }
    fn isDeclaration(n: []const u8) bool {
        return std.mem.eql(u8, n, "xmlns") or std.mem.startsWith(u8, n, "xmlns:");
    }
    fn declare(self: *Builder, attribute: []const u8, decoded: Decoded, at: u32) Error!void {
        if (!self.options.namespaces) return;
        const uri = self.uriOf(decoded);
        const p = if (attribute.len > 5) attribute[6..] else "";
        if (attribute.len > 5) {
            if (!text.isWholeName(p) or std.mem.findScalar(u8, p, ':') != null) return self.fail(at);
            if (uri.len == 0) return self.fail(at); // 1.0 has no undeclaring a prefix
            if (std.mem.eql(u8, p, "xmlns")) return self.fail(at);
            if (std.mem.eql(u8, p, "xml") != std.mem.eql(u8, uri, xml_namespace)) return self.fail(at);
        } else if (std.mem.eql(u8, uri, xml_namespace)) return self.fail(at);
        if (std.mem.eql(u8, uri, xmlns_namespace)) return self.fail(at);
        self.bindings.append(self.allocator, .{ .prefix = p, .uri = decoded }) catch return self.oom();
    }
    fn resolve(self: *Builder, p: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, p, "xml")) return xml_namespace;
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.bindings.items[i].prefix, p)) return self.uriOf(self.bindings.items[i].uri);
        }
        return null;
    }
    fn uriOf(self: *Builder, d: Decoded) []const u8 {
        return self.doc.bytesOf(d.source)[d.span.start..][0..d.span.len];
    }
    /// An element's and its attributes' names: qualified names whose
    /// prefixes are bound, no two attributes one name in one namespace.
    fn checkNames(self: *Builder, index: u32, count: u32, at: u32) Error!void {
        const nodes = self.doc.nodes.items;
        const element_name = self.doc.name(nodes[index]);
        if (!text.isQName(element_name)) return self.fail(at);
        const element_prefix = text.prefix(element_name);
        if (element_prefix.len != 0 and (std.mem.eql(u8, element_prefix, "xmlns") or self.resolve(element_prefix) == null)) return self.fail(at);
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            if (nodes[index + 1 + k].declaration) continue;
            const a = self.doc.name(nodes[index + 1 + k])[1..];
            if (!text.isQName(a)) return self.fail(at);
            const p = text.prefix(a);
            if (p.len == 0) continue;
            const uri = self.resolve(p) orelse return self.fail(at);
            if (std.mem.eql(u8, p, "xmlns")) return self.fail(at);
            const local = a[p.len + 1 ..];
            var j: u32 = 0;
            while (j < k) : (j += 1) {
                if (nodes[index + 1 + j].declaration) continue;
                try self.c.chargeWork(local.len + 1);
                const b = self.doc.name(nodes[index + 1 + j])[1..];
                const q = text.prefix(b);
                if (q.len == 0 or !std.mem.eql(u8, b[q.len + 1 ..], local)) continue;
                if (std.mem.eql(u8, self.resolve(q).?, uri)) return self.fail(at);
            }
        }
    }

    fn endElement(self: *Builder) Error!void {
        try self.closeRun();
        const index = self.open.pop().?;
        self.doc.nodes.items[index].end = @intCast(self.doc.nodes.items.len);
        self.bindings.shrinkRetainingCapacity(self.scopes.pop().?);
    }

    fn addPiece(self: *Builder, piece: Piece, at: u32) Error!void {
        if (piece.len == 0) return;
        if (self.run.items.len == 0) self.run_at = self.place(piece.source, at);
        self.run.append(self.allocator, piece) catch return self.oom();
    }
    /// Character data: its pieces between references to entities, each
    /// entity's text read in place.
    fn textPiece(self: *Builder, raw: []const u8, source: Source, flags: Scanner.TextFlags, offset: u32) Error!void {
        if (!flags.references) return self.addPiece(.{ .source = source, .start = offset, .len = @intCast(raw.len), .plain = !flags.carriage_return, .blank = flags.blank }, offset);
        var i: usize = 0;
        var piece_start: usize = 0;
        while (std.mem.findScalarPos(u8, raw, i, '&')) |k| {
            const ref = (dtd_reader.reference(raw, k) catch |err| return err).?; // the scanner checked it
            switch (ref) {
                .char => |cp| i = cp.end,
                .entity => |e| {
                    i = e.end;
                    if (dtd_reader.isPredefined(e.name) != null) continue;
                    try self.addPiece(.{ .source = source, .start = offset + @as(u32, @intCast(piece_start)), .len = @intCast(k - piece_start) }, offset + @as(u32, @intCast(piece_start)));
                    try self.expandContent(e.name, self.place(source, offset + k));
                    piece_start = i;
                },
            }
        }
        try self.addPiece(.{ .source = source, .start = offset + @as(u32, @intCast(piece_start)), .len = @intCast(raw.len - piece_start) }, offset + @as(u32, @intCast(piece_start)));
    }
    /// The entity `name` referred to at `at`, found, or refused as XML says:
    /// undeclared, where every declaration was read, is not well-formed.
    fn entity(self: *Builder, name: []const u8, at: u32) Error!dtd_reader.Entity {
        if (self.options.namespaces and std.mem.findScalar(u8, name, ':') != null) return self.fail(at);
        if (self.doc.dtd.general.get(name)) |found| return found;
        if (self.doc.dtd.unread and !self.standalone) return error.UnsupportedValue;
        return self.fail(at);
    }
    fn enter(self: *Builder, name: []const u8, at: u32) Error!void {
        for (self.expanding.items) |open| if (std.mem.eql(u8, open, name)) return self.fail(at);
        if (self.expanding.items.len >= self.c.limits.depth) return error.DepthLimit;
        self.expanding.append(self.allocator, name) catch return self.oom();
    }
    fn expandContent(self: *Builder, name: []const u8, at: u32) Error!void {
        const found = try self.entity(name, at);
        switch (found.kind) {
            .external => return error.UnsupportedValue,
            .unparsed => return self.fail(at),
            .internal => {},
        }
        try self.enter(name, at);
        defer _ = self.expanding.pop();
        const replacement = self.doc.dtd.replacementOf(found);
        try self.c.chargeWork(replacement.len + 1);
        var scanner: Scanner = undefined;
        scanner.start(self.c, self.allocator, replacement, .content);
        defer scanner.deinit();
        const outer = self.reference_at;
        self.reference_at = outer orelse at;
        defer self.reference_at = outer;
        const depth = self.open.items.len;
        self.tokens(&scanner, .replacement, found.start) catch |err| {
            if (err == error.SyntaxError) return self.fail(at);
            return err;
        };
        if (self.open.items.len != depth) return self.fail(at);
    }

    /// Ends the text run being made: one node, its bytes borrowed where one
    /// piece of the input needs nothing done to it, else decoded.
    fn closeRun(self: *Builder) Error!void {
        if (self.run.items.len == 0) return;
        defer self.run.clearRetainingCapacity();
        const pieces = self.run.items;
        var node: Node = .{ .kind = .text, .at = self.run_at };
        const only = pieces[0];
        if (pieces.len == 1 and only.source == .input and only.plain) {
            node.value_source = .input;
            node.value = .{ .start = only.start, .len = only.len };
            node.blank = only.blank;
        } else {
            const start = try self.decodedLen();
            for (pieces) |p| try self.decodePiece(p);
            const len = try self.decodedLen() - start;
            node.value_source = .decoded;
            node.value = .{ .start = start, .len = len };
            node.blank = text.allSpace(self.doc.decoded.items[start..][0..len]);
        }
        try self.c.span(node.value.len, false);
        node.end = @intCast(self.doc.nodes.items.len + 1);
        _ = try self.append(node);
        if (!node.blank) self.doc.nodes.items[self.open.items[self.open.items.len - 1]].mixed = true;
    }
    /// A piece's bytes into `decoded`: references to characters and the five
    /// predefined entities replaced, line ends of the input made line feeds.
    /// (A carriage return in an entity's text came from a character
    /// reference and is kept.)
    fn decodePiece(self: *Builder, p: Piece) Error!void {
        const bytes = self.doc.bytesOf(p.source)[p.start..][0..p.len];
        try self.c.chargeWork(bytes.len);
        const out = &self.doc.decoded;
        out.ensureUnusedCapacity(self.allocator, bytes.len) catch return self.oom();
        var i: usize = 0;
        while (i < bytes.len) {
            const k = std.mem.findAnyPos(u8, bytes, i, if (p.cdata) "\r" else "&\r") orelse bytes.len;
            out.appendSliceAssumeCapacity(bytes[i..k]);
            if (k == bytes.len) break;
            if (bytes[k] == '\r') {
                if (p.source == .replacement) {
                    out.appendAssumeCapacity('\r');
                } else {
                    out.appendAssumeCapacity('\n');
                    if (k + 1 < bytes.len and bytes[k + 1] == '\n') i = k + 2 else i = k + 1;
                    continue;
                }
                i = k + 1;
                continue;
            }
            i = try self.appendReference(bytes, k);
        }
    }
    fn appendReference(self: *Builder, bytes: []const u8, k: usize) Error!usize {
        const out = &self.doc.decoded;
        const ref = (try dtd_reader.reference(bytes, k)).?;
        switch (ref) {
            .char => |cp| {
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp.value, &buffer) catch unreachable; // unreachable: a Char is a scalar.
                out.appendSlice(self.allocator, buffer[0..len]) catch return self.oom();
                return cp.end;
            },
            .entity => |e| {
                out.append(self.allocator, dtd_reader.isPredefined(e.name).?) catch return self.oom();
                return e.end;
            },
        }
    }

    /// An attribute's value, normalized as XML 1.0 §3.3.3 does for CDATA:
    /// references replaced (an entity's text normalized in turn), each white
    /// space character a space. Borrowed where nothing needs doing.
    fn attributeValue(self: *Builder, raw: []const u8, source: Source, offset: u32) Error!Decoded {
        if (source == .input and std.mem.findAny(u8, raw, "&\t\n\r") == null)
            return .{ .source = .input, .span = .{ .start = offset, .len = @intCast(raw.len) } };
        const start = try self.decodedLen();
        try self.normalize(raw, source, self.place(source, offset));
        const len = try self.decodedLen() - start;
        try self.c.span(len, false);
        return .{ .source = .decoded, .span = .{ .start = start, .len = len } };
    }
    fn normalize(self: *Builder, raw: []const u8, source: Source, at: u32) Error!void {
        try self.c.chargeWork(raw.len);
        const out = &self.doc.decoded;
        var i: usize = 0;
        while (i < raw.len) {
            const b = raw[i];
            switch (b) {
                '\r' => {
                    out.append(self.allocator, ' ') catch return self.oom();
                    // A line end of the input is one space, CR LF included.
                    if (source == .input and i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
                    i += 1;
                },
                '\t', '\n' => {
                    out.append(self.allocator, ' ') catch return self.oom();
                    i += 1;
                },
                '&' => {
                    const ref = (try dtd_reader.reference(raw, i)) orelse return self.fail(at);
                    switch (ref) {
                        .char => i = try self.appendReference(raw, i),
                        .entity => |e| {
                            if (dtd_reader.isPredefined(e.name) != null) {
                                i = try self.appendReference(raw, i);
                                continue;
                            }
                            const found = try self.entity(e.name, at);
                            if (found.kind != .internal) return self.fail(at);
                            const replacement = self.doc.dtd.replacementOf(found);
                            if (std.mem.findScalar(u8, replacement, '<') != null) return self.fail(at);
                            try self.enter(e.name, at);
                            defer _ = self.expanding.pop();
                            // The replacement may move as `decoded` grows: it is
                            // in the DTD's buffer, which no longer grows.
                            try self.normalize(replacement, .replacement, at);
                            i = e.end;
                        },
                    }
                },
                else => {
                    const k = std.mem.findAnyPos(u8, raw, i, "\r\t\n&") orelse raw.len;
                    out.appendSlice(self.allocator, raw[i..k]) catch return self.oom();
                    i = k;
                },
            }
        }
    }
};

/// Reads `input` into its nodes, on `allocator` (charged to `c`).
/// `failed_at` is set to where a document refused was found wrong.
pub fn read(c: *core.Context, allocator: std.mem.Allocator, input: []const u8, options: Options, failed_at: *usize) Error!Document {
    var doc: Document = .{ .source = input, .borrowed = true, .nodes = .empty, .decoded = .empty, .dtd = .{}, .transcoded = null };
    errdefer doc.deinit(allocator);
    if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) {
        doc.source = input[3..];
        doc.mark = .utf8;
    } else if (std.mem.startsWith(u8, input, "\xFE\xFF") or std.mem.startsWith(u8, input, "\xFF\xFE")) {
        doc.transcoded = try transcode(c, allocator, input);
        doc.source = doc.transcoded.?;
        doc.borrowed = false;
        doc.mark = .utf16;
    }
    if (doc.source.len >= std.math.maxInt(u32)) return error.InputLimit;
    // Every node is a few bytes of text at least: a first guess.
    doc.nodes.ensureTotalCapacity(allocator, @min(doc.source.len / 16 + 4, 1 << 16)) catch return if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory;
    var builder: Builder = .{ .c = c, .allocator = allocator, .doc = &doc, .options = options, .failed_at = failed_at };
    defer builder.deinit();
    var scanner: Scanner = undefined;
    scanner.start(c, allocator, doc.source, .document);
    defer scanner.deinit();
    builder.tokens(&scanner, .input, 0) catch |err| return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
        else => |e| e,
    };
    return doc;
}

/// A UTF-16 document, by its byte-order mark, as UTF-8.
fn transcode(c: *core.Context, allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    const big = input[0] == 0xFE;
    const body = input[2..];
    if (body.len % 2 != 0) return error.InvalidUtf8;
    const units = try allocator.alloc(u16, body.len / 2);
    defer allocator.free(units);
    for (units, 0..) |*u, i| u.* = std.mem.nativeToLittle(u16, std.mem.readInt(u16, body[i * 2 ..][0..2], if (big) .big else .little));
    try c.chargeWork(body.len);
    return std.unicode.utf16LeToUtf8Alloc(allocator, units) catch |err| return switch (err) {
        error.OutOfMemory => if (c.allocation_limited) error.AllocationLimit else error.OutOfMemory,
        else => error.InvalidUtf8,
    };
}
