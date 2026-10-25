//! YAML 1.2's events from its tokens: the stream, its documents, and in each
//! a tree of collections, scalars and aliases, with their anchors and their
//! tags resolved through the document's TAG directives. The shape is libyaml's
//! parser (a stack of states), held to YAML 1.2's rules for directives and
//! document markers.
const std = @import("std");
const scanner = @import("scanner.zig");

pub const Error = scanner.Error;
pub const Mark = scanner.Mark;
pub const Ref = scanner.Ref;
pub const Style = scanner.Style;

pub const Kind = enum(u8) {
    stream_start,
    stream_end,
    document_start,
    document_end,
    sequence_start,
    sequence_end,
    mapping_start,
    mapping_end,
    scalar,
    alias,
};

pub const Event = struct {
    kind: Kind,
    start: Mark,
    /// A document's `---` or `...` is written.
    explicit: bool = false,
    /// A collection is in flow style.
    flow: bool = false,
    style: Style = .plain,
    /// The anchor's name (or the alias's); none when empty.
    anchor: Ref = .{},
    /// The resolved tag; none when `tagged` is false.
    tag: Ref = .{},
    tagged: bool = false,
    value: Ref = .{},
};

const State = enum {
    stream_start,
    implicit_document_start,
    document_start,
    document_content,
    document_end,
    block_node,
    block_node_or_indentless_sequence,
    flow_node,
    block_sequence_first_entry,
    block_sequence_entry,
    indentless_sequence_entry,
    block_mapping_first_key,
    block_mapping_key,
    block_mapping_value,
    flow_sequence_first_entry,
    flow_sequence_entry,
    flow_sequence_entry_mapping_key,
    flow_sequence_entry_mapping_value,
    flow_sequence_entry_mapping_end,
    flow_mapping_first_key,
    flow_mapping_key,
    flow_mapping_value,
    flow_mapping_empty_value,
    end,
};

const Directive = struct { handle: Ref, prefix: Ref };

pub const Parser = struct {
    scanner: scanner.Scanner,
    state: State = .stream_start,
    states: std.ArrayList(State) = .empty,
    directives: std.ArrayList(Directive) = .empty,
    /// The last document ended without `...`: no directive may follow.
    open_ended: bool = false,
    failed_at: u32 = 0,
    /// Where the last token taken that is written ends: the end of the
    /// event just given, for an editor's spans.
    last_end: u32 = 0,
    /// Where the last `-` or `?` taken starts, until a reader of spans takes it.
    indicator: ?u32 = null,

    pub fn init(input: []const u8, allocator: std.mem.Allocator, decoded: *std.ArrayList(u8)) Parser {
        return .{ .scanner = .init(input, allocator, decoded) };
    }
    pub fn deinit(self: *Parser) void {
        self.scanner.deinit();
        self.states.deinit(self.scanner.allocator);
        self.directives.deinit(self.scanner.allocator);
    }
    /// Where the text was refused.
    pub fn failedAt(self: *const Parser) u32 {
        return @max(self.failed_at, self.scanner.failed_at);
    }

    fn fail(self: *Parser, mark: Mark) Error {
        self.failed_at = mark.index;
        return error.SyntaxError;
    }
    fn peek(self: *Parser) Error!*const scanner.Token {
        return self.scanner.peek();
    }
    fn skip(self: *Parser) void {
        const token = &self.scanner.tokens.items[self.scanner.head];
        if (token.end.index > token.start.index) {
            self.last_end = token.end.index;
            if (token.kind == .block_entry or token.kind == .key) self.indicator = token.start.index;
        }
        self.scanner.skip();
    }
    fn push(self: *Parser, state: State) Error!void {
        try self.states.append(self.scanner.allocator, state);
    }
    fn pop(self: *Parser) void {
        self.state = self.states.pop().?;
    }
    fn bytes(self: *const Parser, ref: Ref) []const u8 {
        const source = if (ref.decoded) self.scanner.decoded.items else self.scanner.input;
        return source[ref.start..][0..ref.len];
    }
    pub fn text(self: *const Parser, ref: Ref) []const u8 {
        return self.bytes(ref);
    }

    /// The next event; `stream_end` once, then refusals.
    pub fn next(self: *Parser) Error!Event {
        return switch (self.state) {
            .stream_start => self.streamStart(),
            .implicit_document_start => self.documentStart(true),
            .document_start => self.documentStart(false),
            .document_content => self.documentContent(),
            .document_end => self.documentEnd(),
            .block_node => self.node(true, false),
            .block_node_or_indentless_sequence => self.node(true, true),
            .flow_node => self.node(false, false),
            .block_sequence_first_entry => self.blockSequenceEntry(true),
            .block_sequence_entry => self.blockSequenceEntry(false),
            .indentless_sequence_entry => self.indentlessSequenceEntry(),
            .block_mapping_first_key => self.blockMappingKey(true),
            .block_mapping_key => self.blockMappingKey(false),
            .block_mapping_value => self.blockMappingValue(),
            .flow_sequence_first_entry => self.flowSequenceEntry(true),
            .flow_sequence_entry => self.flowSequenceEntry(false),
            .flow_sequence_entry_mapping_key => self.flowSequenceEntryMappingKey(),
            .flow_sequence_entry_mapping_value => self.flowSequenceEntryMappingValue(),
            .flow_sequence_entry_mapping_end => self.flowSequenceEntryMappingEnd(),
            .flow_mapping_first_key => self.flowMappingKey(true),
            .flow_mapping_key => self.flowMappingKey(false),
            .flow_mapping_value => self.flowMappingValue(false),
            .flow_mapping_empty_value => self.flowMappingValue(true),
            .end => self.fail(self.scanner.at),
        };
    }

    fn streamStart(self: *Parser) Error!Event {
        const token = try self.peek();
        std.debug.assert(token.kind == .stream_start);
        const start = token.start;
        self.skip();
        self.state = .implicit_document_start;
        return .{ .kind = .stream_start, .start = start };
    }

    fn documentStart(self: *Parser, implicit_allowed: bool) Error!Event {
        var token = try self.peek();
        // `...` with no document before it.
        var ended = false;
        while (token.kind == .document_end) {
            self.skip();
            token = try self.peek();
            ended = true;
        }
        if (ended) self.open_ended = false;
        const bare_allowed = implicit_allowed or ended;
        switch (token.kind) {
            .stream_end => {
                const start = token.start;
                self.skip();
                self.state = .end;
                return .{ .kind = .stream_end, .start = start };
            },
            .version_directive, .tag_directive, .reserved_directive, .document_start => {
                const start = token.start;
                try self.processDirectives();
                token = try self.peek();
                if (token.kind != .document_start) return self.fail(token.start);
                self.skip();
                try self.push(.document_end);
                self.state = .document_content;
                return .{ .kind = .document_start, .start = start, .explicit = true };
            },
            else => {
                if (!bare_allowed) return self.fail(token.start);
                self.directives.clearRetainingCapacity();
                const start = token.start;
                try self.push(.document_end);
                self.state = .block_node;
                return .{ .kind = .document_start, .start = start };
            },
        }
    }
    fn processDirectives(self: *Parser) Error!void {
        self.directives.clearRetainingCapacity();
        var version = false;
        while (true) {
            const token = try self.peek();
            switch (token.kind) {
                .version_directive => {
                    if (self.open_ended) return self.fail(token.start);
                    if (version) return self.fail(token.start);
                    version = true;
                    const v = self.bytes(token.value);
                    const dot = std.mem.findScalar(u8, v, '.').?;
                    const major = std.fmt.parseInt(u32, v[0..dot], 10) catch return self.fail(token.start);
                    if (major != 1) return self.fail(token.start);
                },
                .tag_directive => {
                    if (self.open_ended) return self.fail(token.start);
                    const handle = self.bytes(token.handle);
                    for (self.directives.items) |d| if (std.mem.eql(u8, self.bytes(d.handle), handle)) return self.fail(token.start);
                    try self.directives.append(self.scanner.allocator, .{ .handle = token.handle, .prefix = token.value });
                },
                .reserved_directive => if (self.open_ended) return self.fail(token.start),
                else => return,
            }
            self.skip();
        }
    }

    fn documentContent(self: *Parser) Error!Event {
        const token = try self.peek();
        switch (token.kind) {
            .version_directive, .tag_directive, .reserved_directive, .document_start, .document_end, .stream_end => {
                const start = token.start;
                self.pop();
                return empty(start);
            },
            else => return self.node(true, false),
        }
    }

    fn documentEnd(self: *Parser) Error!Event {
        const token = try self.peek();
        const start = token.start;
        var explicit = false;
        if (token.kind == .document_end) {
            self.skip();
            explicit = true;
        } else if (token.kind != .document_start and token.kind != .stream_end and token.kind != .version_directive and token.kind != .tag_directive and token.kind != .reserved_directive) {
            // Something after the document's node that is no new document.
            return self.fail(token.start);
        }
        self.open_ended = !explicit;
        // After `...` a document may start bare.
        self.state = if (explicit) .implicit_document_start else .document_start;
        return .{ .kind = .document_end, .start = start, .explicit = explicit };
    }

    fn empty(mark: Mark) Event {
        return .{ .kind = .scalar, .start = mark, .style = .plain };
    }

    /// `!`, `!!` and named handles through the document's directives.
    fn resolveTag(self: *Parser, token: *const scanner.Token) Error!Ref {
        const s = &self.scanner;
        if (token.handle.len == 0) return token.value;
        const handle = self.bytes(token.handle);
        const prefix: []const u8, const prefix_ref: ?Ref = blk: {
            for (self.directives.items) |d| if (std.mem.eql(u8, self.bytes(d.handle), handle)) break :blk .{ "", d.prefix };
            if (std.mem.eql(u8, handle, "!")) break :blk .{ "!", null };
            if (std.mem.eql(u8, handle, "!!")) break :blk .{ "tag:yaml.org,2002:", null };
            return self.fail(token.start);
        };
        const start = std.math.cast(u32, s.decoded.items.len) orelse return error.InputLimit;
        if (prefix_ref) |p| {
            // The prefix may itself be in the decoded bytes: copied by position.
            const from = self.bytes(p);
            if (p.decoded) {
                try s.decoded.ensureUnusedCapacity(s.allocator, p.len);
                s.decoded.appendSliceAssumeCapacity(s.decoded.items[p.start..][0..p.len]);
            } else try s.decoded.appendSlice(s.allocator, from);
        } else try s.decoded.appendSlice(s.allocator, prefix);
        const suffix = token.value;
        if (suffix.decoded) {
            try s.decoded.ensureUnusedCapacity(s.allocator, suffix.len);
            s.decoded.appendSliceAssumeCapacity(s.decoded.items[suffix.start..][0..suffix.len]);
        } else try s.decoded.appendSlice(s.allocator, self.bytes(suffix));
        const len = std.math.cast(u32, s.decoded.items.len - start) orelse return error.InputLimit;
        return .{ .start = start, .len = len, .decoded = true };
    }

    fn node(self: *Parser, block: bool, indentless: bool) Error!Event {
        var token = try self.peek();
        if (token.kind == .alias) {
            const event: Event = .{ .kind = .alias, .start = token.start, .anchor = token.value };
            self.skip();
            self.pop();
            return event;
        }
        const start = token.start;
        var event: Event = .{ .kind = .scalar, .start = start };
        var properties = false;
        for (0..2) |_| {
            if (token.kind == .anchor and event.anchor.len == 0) {
                event.anchor = token.value;
            } else if (token.kind == .tag and !event.tagged) {
                event.tag = try self.resolveTag(token);
                event.tagged = true;
            } else break;
            properties = true;
            self.skip();
            token = try self.peek();
        }
        if (token.kind == .anchor or token.kind == .tag) return self.fail(token.start);
        if (indentless and token.kind == .block_entry) {
            self.state = .indentless_sequence_entry;
            event.kind = .sequence_start;
            return event;
        }
        switch (token.kind) {
            .scalar => {
                event.style = token.style;
                event.value = token.value;
                self.skip();
                self.pop();
                return event;
            },
            .flow_sequence_start => {
                self.state = .flow_sequence_first_entry;
                event.kind = .sequence_start;
                event.flow = true;
                return event;
            },
            .flow_mapping_start => {
                self.state = .flow_mapping_first_key;
                event.kind = .mapping_start;
                event.flow = true;
                return event;
            },
            .block_sequence_start => if (block) {
                self.state = .block_sequence_first_entry;
                event.kind = .sequence_start;
                return event;
            },
            .block_mapping_start => if (block) {
                self.state = .block_mapping_first_key;
                event.kind = .mapping_start;
                return event;
            },
            else => {},
        }
        if (properties) {
            // Properties on nothing: an empty scalar.
            self.pop();
            return event;
        }
        return self.fail(token.start);
    }

    fn blockSequenceEntry(self: *Parser, first: bool) Error!Event {
        if (first) self.skip();
        const token = try self.peek();
        switch (token.kind) {
            .block_entry => {
                const mark = token.end;
                self.skip();
                const following = try self.peek();
                if (following.kind != .block_entry and following.kind != .block_end) {
                    try self.push(.block_sequence_entry);
                    return self.node(true, false);
                }
                self.state = .block_sequence_entry;
                return empty(mark);
            },
            .block_end => {
                const start = token.start;
                self.skip();
                self.pop();
                return .{ .kind = .sequence_end, .start = start };
            },
            else => return self.fail(token.start),
        }
    }

    fn indentlessSequenceEntry(self: *Parser) Error!Event {
        const token = try self.peek();
        if (token.kind == .block_entry) {
            const mark = token.end;
            self.skip();
            const following = try self.peek();
            switch (following.kind) {
                .block_entry, .key, .value, .block_end => {
                    self.state = .indentless_sequence_entry;
                    return empty(mark);
                },
                else => {
                    try self.push(.indentless_sequence_entry);
                    return self.node(true, false);
                },
            }
        }
        const start = token.start;
        self.pop();
        return .{ .kind = .sequence_end, .start = start };
    }

    fn blockMappingKey(self: *Parser, first: bool) Error!Event {
        if (first) self.skip();
        const token = try self.peek();
        switch (token.kind) {
            .key => {
                const mark = token.end;
                self.skip();
                const following = try self.peek();
                switch (following.kind) {
                    .key, .value, .block_end => {
                        self.state = .block_mapping_value;
                        return empty(mark);
                    },
                    else => {
                        try self.push(.block_mapping_value);
                        return self.node(true, true);
                    },
                }
            },
            .block_end => {
                const start = token.start;
                self.skip();
                self.pop();
                return .{ .kind = .mapping_end, .start = start };
            },
            .value => {
                // `:` with no key: the key is empty.
                self.state = .block_mapping_value;
                return empty(token.start);
            },
            else => return self.fail(token.start),
        }
    }

    fn blockMappingValue(self: *Parser) Error!Event {
        const token = try self.peek();
        if (token.kind == .value) {
            const mark = token.end;
            self.skip();
            const following = try self.peek();
            switch (following.kind) {
                .key, .value, .block_end => {
                    self.state = .block_mapping_key;
                    return empty(mark);
                },
                else => {
                    try self.push(.block_mapping_key);
                    return self.node(true, true);
                },
            }
        }
        self.state = .block_mapping_key;
        return empty(token.start);
    }

    fn flowSequenceEntry(self: *Parser, first: bool) Error!Event {
        if (first) self.skip();
        var token = try self.peek();
        if (token.kind != .flow_sequence_end) {
            if (!first) {
                if (token.kind != .flow_entry) return self.fail(token.start);
                self.skip();
                token = try self.peek();
            }
            if (token.kind == .key) {
                const start = token.start;
                self.state = .flow_sequence_entry_mapping_key;
                self.skip();
                return .{ .kind = .mapping_start, .start = start, .flow = true };
            }
            if (token.kind == .value) {
                // `[: b]`: a pair with an empty key.
                self.state = .flow_sequence_entry_mapping_key;
                return .{ .kind = .mapping_start, .start = token.start, .flow = true };
            }
            if (token.kind != .flow_sequence_end) {
                try self.push(.flow_sequence_entry);
                return self.node(false, false);
            }
        }
        const start = token.start;
        self.skip();
        self.pop();
        return .{ .kind = .sequence_end, .start = start };
    }
    fn flowSequenceEntryMappingKey(self: *Parser) Error!Event {
        const token = try self.peek();
        switch (token.kind) {
            .value, .flow_entry, .flow_sequence_end => {
                self.state = .flow_sequence_entry_mapping_value;
                return empty(token.start);
            },
            else => {
                try self.push(.flow_sequence_entry_mapping_value);
                return self.node(false, false);
            },
        }
    }
    fn flowSequenceEntryMappingValue(self: *Parser) Error!Event {
        const token = try self.peek();
        if (token.kind == .value) {
            const mark = token.end;
            self.skip();
            const following = try self.peek();
            if (following.kind != .flow_entry and following.kind != .flow_sequence_end) {
                try self.push(.flow_sequence_entry_mapping_end);
                return self.node(false, false);
            }
            self.state = .flow_sequence_entry_mapping_end;
            return empty(mark);
        }
        self.state = .flow_sequence_entry_mapping_end;
        return empty(token.start);
    }
    fn flowSequenceEntryMappingEnd(self: *Parser) Error!Event {
        const token = try self.peek();
        self.state = .flow_sequence_entry;
        return .{ .kind = .mapping_end, .start = token.start };
    }

    fn flowMappingKey(self: *Parser, first: bool) Error!Event {
        if (first) self.skip();
        var token = try self.peek();
        if (token.kind != .flow_mapping_end) {
            if (!first) {
                if (token.kind != .flow_entry) return self.fail(token.start);
                self.skip();
                token = try self.peek();
            }
            if (token.kind == .key) {
                const mark = token.end;
                self.skip();
                const following = try self.peek();
                switch (following.kind) {
                    .value, .flow_entry, .flow_mapping_end => {
                        self.state = .flow_mapping_value;
                        return empty(mark);
                    },
                    else => {
                        try self.push(.flow_mapping_value);
                        return self.node(false, false);
                    },
                }
            }
            if (token.kind == .value) {
                // `{: b}`: an empty key.
                self.state = .flow_mapping_value;
                return empty(token.start);
            }
            if (token.kind != .flow_mapping_end) {
                try self.push(.flow_mapping_empty_value);
                return self.node(false, false);
            }
        }
        const start = token.start;
        self.skip();
        self.pop();
        return .{ .kind = .mapping_end, .start = start };
    }
    fn flowMappingValue(self: *Parser, empty_value: bool) Error!Event {
        const token = try self.peek();
        // A key with no `?` is followed by its `:`, which may be on a line
        // of its own; with none, its value is empty.
        if (empty_value and token.kind != .value) {
            self.state = .flow_mapping_key;
            return empty(token.start);
        }
        if (token.kind == .value) {
            const mark = token.end;
            self.skip();
            const following = try self.peek();
            if (following.kind != .flow_entry and following.kind != .flow_mapping_end) {
                try self.push(.flow_mapping_key);
                return self.node(false, false);
            }
            self.state = .flow_mapping_key;
            return empty(mark);
        }
        self.state = .flow_mapping_key;
        return empty(token.start);
    }
};
