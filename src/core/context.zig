//! Checked resource accounting: one operation owns this state; no shared mutable
//! state or OS resources. The totals charged once (input, output, work, requested
//! allocation) are aegis budgets; the node count, which is handed back, the
//! nesting depths and the allocator's live bytes are counters of their own, for
//! the reasons written at each.
const std = @import("std");
const aegis = @import("aegis");
const bounded = aegis.bounded;
const err = aegis.err;
const int = aegis.int;

pub const LimitError = error{ InputLimit, OutputLimit, DepthLimit, ItemLimit, LengthLimit, AllocationLimit, WorkLimit };
pub const DecodeError = error{ InputLimit, DepthLimit, ItemLimit, LengthLimit, AllocationLimit, WorkLimit } || error{ SyntaxError, UnexpectedEndOfInput, InvalidUtf8, UnexpectedType, MissingField, UnknownField, DuplicateField, UnknownVariant, NumberOutOfRange, InexactNumber, UnsupportedValue, BorrowUnavailable, CustomRejected, OutOfMemory };
pub const EncodeError = LimitError || error{ DuplicateField, InvalidRaw, InvalidUtf8, NumberOutOfRange, InexactNumber, UnsupportedValue, CycleDetected, CustomRejected, OutOfMemory };
pub const Lifetime = enum { borrowed, transient, owned };
pub const Ownership = enum { borrowed, owned };
pub const Borrow = enum { prefer, copy, require };
pub const Acceptance = struct { reject_unknown_fields: bool = false, reject_duplicates: bool = false };

pub const Limits = struct {
    input_bytes: usize = 16 * 1024 * 1024,
    output_bytes: usize = 16 * 1024 * 1024,
    depth: usize = 128,
    items: usize = 1024 * 1024,
    container_items: usize = 1024 * 1024,
    string_bytes: usize = 8 * 1024 * 1024,
    key_bytes: usize = 64 * 1024,
    numeric_bytes: usize = 1024,
    allocation_bytes: usize = 32 * 1024 * 1024,
    work: usize = 128 * 1024 * 1024,
};

/// One step of the path to a value: a field or a position.
///
/// A field's name comes from the schema or from the input, and the input
/// chooses what an unknown one says, so it is kept as aegis' public text:
/// escaped, never raw bytes, truncated with a marker at `name_bytes`.
pub const Step = struct {
    pub const aegis_public_frame = true;
    pub const Kind = enum { field, index };
    pub const name_bytes = 32;
    kind: Kind,
    /// The position of an `index` step; zero for a field.
    index: usize,
    /// The escaped name of a `field` step; empty for an index.
    name: err.PublicText(name_bytes),
};

/// Names in errors are copied, escaped, into inline storage; nothing in them is
/// retained from input.
pub const Diagnostics = struct {
    offset: usize = 0,
    line: ?usize = null,
    column: ?usize = null,
    format: []const u8 = "",
    expected: Expected = .unknown,
    custom_code: ?u32 = null,
    /// Where in the value the failure is, outermost first. Past `path_steps`
    /// the path stops growing and says so (`path.truncated`).
    path: err.Context(Step, path_steps) = .{},
    pub const path_steps = 32;
    pub const Expected = enum { unknown, boolean, integer, floating, text, symbol, scalar, bytes, option, unit, sequence, tuple, record, variant, map, named_tuple, named_unit, newtype, some };
    /// How much of the path there is: what a failed alternative returns to.
    pub const Checkpoint = struct {
        steps: usize,
        truncated: bool,
        /// The mark of an operation that keeps no diagnostics.
        pub const none: Checkpoint = .{ .steps = 0, .truncated = false };
    };
    pub fn checkpoint(self: *const Diagnostics) Checkpoint {
        return .{ .steps = self.path.len, .truncated = self.path.truncated };
    }
    pub fn restore(self: *Diagnostics, mark: Checkpoint) void {
        self.path.len = mark.steps;
        self.path.truncated = mark.truncated;
    }
    pub fn field(self: *Diagnostics, name: []const u8) void {
        self.path.push(.{
            .kind = .field,
            .index = 0,
            .name = .copy(err.PublicSource.classify("a field name of the schema or the input, escaped by the text type", name)),
        });
    }
    pub fn index(self: *Diagnostics, position: usize) void {
        self.path.push(.{ .kind = .index, .index = position, .name = .{} });
    }
};

pub const Context = struct {
    storage: std.mem.Allocator,
    limits: Limits,
    ownership: Ownership,
    // Wire nesting, and callback nesting beside it: counters entered and left in
    // pairs on every level of every value, so each is a bare increment and a
    // compare. A budget's reservation per level is a second word on the stack of
    // the hottest recursion in the core for a count only this file changes.
    depth: usize = 0,
    hook_depth: usize = 0,
    // Nodes are charged when a value begins and handed back when a type turns
    // out to be a hint (an option, a pointer) that has no wire node of its own.
    // A budget only charges: it has no way to give back.
    items: usize = 0,
    // Charged once, never returned: the budget is the whole of their rule.
    work_budget: bounded.Budget(usize),
    input_budget: bounded.Budget(usize),
    output_budget: bounded.Budget(usize),
    allocation_budget: bounded.Budget(usize),
    diagnostics: ?*Diagnostics = null,
    acceptance: Acceptance = .{},
    /// Internal replay: wire nodes/bytes were already validated and charged.
    replaying: bool = false,
    allocation_limited: bool = false,
    /// Writing: an optional field that is null is left out of its record, whatever
    /// its type's own policy says.
    omit_nulls: bool = false,

    pub fn init(storage: std.mem.Allocator, limits: Limits, ownership: Ownership) Context {
        return .{
            .storage = storage,
            .limits = limits,
            .ownership = ownership,
            .work_budget = .init(limits.work),
            .input_budget = .init(limits.input_bytes),
            .output_budget = .init(limits.output_bytes),
            .allocation_budget = .init(limits.allocation_bytes),
        };
    }
    /// Units of work charged so far.
    pub fn workUsed(self: *const Context) usize {
        return self.limits.work - self.work_budget.remaining();
    }
    /// Bytes written so far.
    pub fn outputUsed(self: *const Context) usize {
        return self.limits.output_bytes - self.output_budget.remaining();
    }
    /// Bytes requested of the operation's allocator so far.
    pub fn allocationRequested(self: *const Context) usize {
        return self.limits.allocation_bytes - self.allocation_budget.remaining();
    }
    /// Takes over what another operation has already been charged, as the
    /// first charge of a fresh context.
    pub fn adopt(self: *Context, work: usize, allocation: usize) error{ WorkLimit, AllocationLimit }!void {
        self.work_budget.consume(work) catch return error.WorkLimit;
        self.allocation_budget.consume(allocation) catch return error.AllocationLimit;
    }
    pub inline fn enter(self: *Context) error{DepthLimit}!void {
        @setRuntimeSafety(true);
        if (self.depth >= self.limits.depth) return error.DepthLimit;
        self.depth += 1;
    }
    /// How many elements a sequence of `current` asks for next: twice as many,
    /// at least one, and never past `ceiling`.
    pub fn grownCapacity(current: usize, ceiling: usize) error{AllocationLimit}!usize {
        const doubled = int.Checked(usize).init(current).mul(2) catch return error.AllocationLimit;
        return @min(@max(1, doubled.raw()), ceiling);
    }
    pub inline fn leave(self: *Context) void {
        @setRuntimeSafety(true);
        self.depth -= 1;
    }
    /// Callback delegation has the same finite cap without altering wire depth.
    pub fn enterHook(self: *Context) error{DepthLimit}!void {
        if (self.hook_depth >= self.limits.depth) return error.DepthLimit;
        self.hook_depth += 1;
    }
    pub fn leaveHook(self: *Context) void {
        aegis.assert.pre(self.hook_depth != 0, "a callback was left that was never entered");
        self.hook_depth -= 1;
    }
    pub inline fn node(self: *Context) error{ItemLimit}!void {
        @setRuntimeSafety(true);
        if (self.replaying) return;
        if (self.items >= self.limits.items) return error.ItemLimit;
        self.items += 1;
    }
    pub inline fn count(self: *Context, n: usize) error{ItemLimit}!void {
        @setRuntimeSafety(true);
        if (n > self.limits.container_items or (!self.replaying and n > self.limits.items - self.items)) return error.ItemLimit;
    }
    pub inline fn span(self: *Context, n: usize, key: bool) error{LengthLimit}!void {
        if (n > if (key) self.limits.key_bytes else self.limits.string_bytes) return error.LengthLimit;
    }
    pub inline fn chargeWork(self: *Context, n: usize) error{WorkLimit}!void {
        self.work_budget.consume(n) catch return error.WorkLimit;
    }
    pub inline fn input(self: *Context, n: usize) error{ InputLimit, WorkLimit }!void {
        if (self.replaying) return self.chargeWork(n);
        self.input_budget.consume(n) catch return error.InputLimit;
        try self.chargeWork(n);
    }
    pub inline fn output(self: *Context, n: usize) error{ OutputLimit, WorkLimit }!void {
        self.output_budget.consume(n) catch return error.OutputLimit;
        try self.chargeWork(n);
    }
    /// Each request is bounded before allocation. Arena backing capacity is also
    /// independently bounded by acquire's allocator; these two caps aren't added.
    pub fn alloc(self: *Context, comptime T: type, n: usize) error{ AllocationLimit, OutOfMemory }![]T {
        const bytes = int.Checked(usize).init(@sizeOf(T)).mul(n) catch return error.AllocationLimit;
        // The charge is made before the request and given back if it fails: a
        // refused allocation costs the operation nothing.
        var charge = self.allocation_budget.reserve(bytes.raw()) catch return error.AllocationLimit;
        errdefer charge.release();
        const memory = try self.storage.alloc(T, n);
        return memory;
    }
    /// Preserve actual pointer alignment/sentinel using typed allocation. The
    /// reservation includes sentinel storage and conservative alignment padding.
    pub fn allocPointer(self: *Context, comptime P: type, n: usize) error{ AllocationLimit, OutOfMemory }!Mutable(P) {
        const info = @typeInfo(P).pointer;
        const sentinel = if (info.size == .slice) info.sentinel() else null;
        const extra: usize = if (sentinel != null) 1 else 0;
        const alignment = info.attrs.@"align" orelse @alignOf(info.child);
        const padded = int.Checked(usize).init(n).add(extra) catch return error.AllocationLimit;
        const payload = int.Checked(usize).init(@sizeOf(info.child)).mul(padded.raw()) catch return error.AllocationLimit;
        const bytes = payload.add(alignment - 1) catch return error.AllocationLimit;
        var charge = self.allocation_budget.reserve(bytes.raw()) catch return error.AllocationLimit;
        errdefer charge.release();
        const memory = try self.storage.allocWithOptions(info.child, n, .fromByteUnits(alignment), sentinel);
        return if (info.size == .one) &memory[0] else memory;
    }
    /// Temporary adapter for format scratch. It cannot outlive the operation.
    /// No resize avoids uncharged growth; arena release remains the owner's.
    pub fn allocator(self: *Context) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = scratchAllocate, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = scratchFree } };
    }
    fn scratchAllocate(raw: *anyopaque, n: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Context = @ptrCast(@alignCast(raw)); // safe: allocator's pointer is its live Context.
        var charge = self.allocation_budget.reserve(n) catch {
            self.allocation_limited = true;
            return null;
        };
        return self.storage.rawAlloc(n, alignment, address) orelse {
            charge.release();
            return null;
        };
    }
    fn scratchFree(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Context = @ptrCast(@alignCast(raw)); // safe: allocator's pointer is its live Context.
        self.storage.rawFree(memory, alignment, address);
    }
    pub fn reject(self: *Context, code: u32) error{CustomRejected} {
        if (self.diagnostics) |d| d.custom_code = code;
        return error.CustomRejected;
    }
    pub fn retain(self: *Context, bytes: []const u8, lifetime: Lifetime, borrow: Borrow) DecodeError![]const u8 {
        try self.span(bytes.len, false);
        if (borrow == .require and (self.ownership == .owned or lifetime != .borrowed)) return error.BorrowUnavailable;
        // An owned visit already belongs to this operation's result arena.
        if (lifetime == .owned and borrow != .copy) return bytes;
        if (self.ownership == .borrowed and lifetime == .borrowed and borrow != .copy) return bytes;
        try self.chargeWork(bytes.len);
        const copy = try self.alloc(u8, bytes.len);
        @memcpy(copy, bytes);
        return copy;
    }
};

/// Bounds arena capacity, not merely the lengths of values stored in that arena.
/// The allocator is used only during acquisition, while its address is stable.
/// `live` rises on allocation and falls by the size of whatever is freed, not by
/// a reservation held: plain counters, because a budget gives back a charge only
/// through the reservation that made it.
pub const Backing = struct {
    gpa: std.mem.Allocator,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    limited: bool = false,
    pub fn allocator(self: *Backing) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = release } };
    }
    fn allocate(raw: *anyopaque, n: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        @setRuntimeSafety(true);
        // safe: the vtable is paired only with a live, aligned Backing pointer.
        const self: *Backing = @ptrCast(@alignCast(raw)); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
        if (n > self.limit - self.live) {
            self.limited = true;
            return null;
        }
        const memory = self.gpa.rawAlloc(n, alignment, address) orelse return null;
        self.live += n;
        self.peak = @max(self.peak, self.live);
        return memory;
    }
    fn release(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        @setRuntimeSafety(true);
        // safe: the vtable is paired only with a live, aligned Backing pointer.
        const self: *Backing = @ptrCast(@alignCast(raw)); // safe: checked destination bounds or Zig-provided typed storage precede this conversion.
        self.gpa.rawFree(memory, alignment, address);
        self.live -= memory.len;
    }
};

fn Mutable(comptime P: type) type {
    const i = @typeInfo(P).pointer;
    var attrs = i.attrs;
    attrs.@"const" = false;
    return @Pointer(i.size, attrs, i.child, if (i.size == .slice) i.sentinel() else null);
}
