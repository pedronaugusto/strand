//! Checked resource accounting. Local until admitted aegis contracts replace it.
//! Safe: one operation owns this state; no shared mutable state or OS resources.
const std = @import("std");

pub const LimitError = error{ InputLimit, OutputLimit, DepthLimit, ItemLimit, LengthLimit, AllocationLimit, WorkLimit };
pub const DecodeError = error{ InputLimit, DepthLimit, ItemLimit, LengthLimit, AllocationLimit, WorkLimit } || error{ SyntaxError, InvalidUtf8, UnexpectedType, MissingField, UnknownField, DuplicateField, UnknownVariant, NumberOutOfRange, InexactNumber, UnsupportedValue, BorrowUnavailable, CustomRejected, OutOfMemory };
pub const EncodeError = LimitError || error{ InvalidRaw, InvalidUtf8, NumberOutOfRange, InexactNumber, UnsupportedValue, CycleDetected, CustomRejected, OutOfMemory };
pub const Lifetime = enum { borrowed, transient, owned };
pub const Ownership = enum { borrowed, owned };
pub const Borrow = enum { prefer, copy, require };

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

/// Names in errors are copied into inline storage, never retained from input.
pub const Diagnostics = struct {
    offset: usize = 0,
    path: [32]Component = undefined,
    count: usize = 0,
    names: [512]u8 = undefined,
    used: usize = 0,
    truncated: bool = false,
    pub const Component = union(enum) { field: struct { start: usize, len: usize }, index: usize };
    pub fn field(self: *Diagnostics, name: []const u8) void {
        if (self.count == self.path.len or name.len > self.names.len - self.used) {
            self.truncated = true;
            return;
        }
        @memcpy(self.names[self.used..][0..name.len], name);
        self.path[self.count] = .{ .field = .{ .start = self.used, .len = name.len } };
        self.count += 1;
        self.used += name.len;
    }
    pub fn index(self: *Diagnostics, i: usize) void {
        if (self.count == self.path.len) {
            self.truncated = true;
            return;
        }
        self.path[self.count] = .{ .index = i };
        self.count += 1;
    }
};

pub const Context = struct {
    storage: std.mem.Allocator,
    limits: Limits,
    ownership: Ownership,
    depth: usize = 0,
    items: usize = 0,
    work: usize = 0,
    input_bytes: usize = 0,
    output_bytes: usize = 0,
    allocation_requested: usize = 0,
    diagnostics: ?*Diagnostics = null,

    pub fn init(storage: std.mem.Allocator, limits: Limits, ownership: Ownership) Context {
        return .{ .storage = storage, .limits = limits, .ownership = ownership };
    }
    pub fn enter(self: *Context) error{DepthLimit}!void {
        @setRuntimeSafety(true);
        if (self.depth >= self.limits.depth) return error.DepthLimit;
        self.depth += 1;
    }
    pub fn leave(self: *Context) void {
        @setRuntimeSafety(true);
        self.depth -= 1;
    }
    pub fn node(self: *Context) error{ItemLimit}!void {
        @setRuntimeSafety(true);
        if (self.items >= self.limits.items) return error.ItemLimit;
        self.items += 1;
    }
    pub fn count(self: *Context, n: usize) error{ItemLimit}!void {
        @setRuntimeSafety(true);
        if (n > self.limits.container_items or n > self.limits.items - self.items) return error.ItemLimit;
    }
    pub fn span(self: *Context, n: usize, key: bool) error{LengthLimit}!void {
        if (n > if (key) self.limits.key_bytes else self.limits.string_bytes) return error.LengthLimit;
    }
    pub fn chargeWork(self: *Context, n: usize) error{WorkLimit}!void {
        @setRuntimeSafety(true);
        if (n > self.limits.work - self.work) return error.WorkLimit;
        self.work += n;
    }
    pub fn input(self: *Context, n: usize) error{ InputLimit, WorkLimit }!void {
        @setRuntimeSafety(true);
        if (n > self.limits.input_bytes - self.input_bytes) return error.InputLimit;
        self.input_bytes += n;
        try self.chargeWork(n);
    }
    pub fn output(self: *Context, n: usize) error{ OutputLimit, WorkLimit }!void {
        @setRuntimeSafety(true);
        if (n > self.limits.output_bytes - self.output_bytes) return error.OutputLimit;
        self.output_bytes += n;
        try self.chargeWork(n);
    }
    /// Each request is bounded before allocation. Arena backing capacity is also
    /// independently bounded by acquire's allocator; these two caps aren't added.
    pub fn alloc(self: *Context, comptime T: type, n: usize) DecodeError![]T {
        @setRuntimeSafety(true);
        const bytes = std.math.mul(usize, @sizeOf(T), n) catch return error.AllocationLimit;
        if (bytes > self.limits.allocation_bytes - self.allocation_requested) return error.AllocationLimit;
        const memory = try self.storage.alloc(T, n);
        self.allocation_requested += bytes;
        return memory;
    }
    /// Preserve actual pointer alignment/sentinel using typed allocation. The
    /// reservation includes sentinel storage and conservative alignment padding.
    pub fn allocPointer(self: *Context, comptime P: type, n: usize) DecodeError!Mutable(P) {
        @setRuntimeSafety(true);
        const info = @typeInfo(P).pointer;
        const sentinel = if (info.size == .slice) info.sentinel() else null;
        const extra: usize = if (sentinel != null) 1 else 0;
        const total_count = std.math.add(usize, n, extra) catch return error.AllocationLimit;
        const payload = std.math.mul(usize, @sizeOf(info.child), total_count) catch return error.AllocationLimit;
        const alignment = info.attrs.@"align" orelse @alignOf(info.child);
        const bytes = std.math.add(usize, payload, alignment - 1) catch return error.AllocationLimit;
        if (bytes > self.limits.allocation_bytes - self.allocation_requested) return error.AllocationLimit;
        const memory = try self.storage.allocWithOptions(info.child, n, .fromByteUnits(alignment), sentinel);
        self.allocation_requested += bytes;
        return if (info.size == .one) &memory[0] else memory;
    }
    pub fn retain(self: *Context, bytes: []const u8, lifetime: Lifetime, borrow: Borrow) DecodeError![]const u8 {
        try self.span(bytes.len, false);
        if (borrow == .require and (self.ownership == .owned or lifetime != .borrowed)) return error.BorrowUnavailable;
        if (self.ownership == .borrowed and lifetime == .borrowed and borrow != .copy) return bytes;
        try self.chargeWork(bytes.len);
        const copy = try self.alloc(u8, bytes.len);
        @memcpy(copy, bytes);
        return copy;
    }
};

/// Bounds arena capacity, not merely the lengths of values stored in that arena.
/// The allocator is used only during acquisition, while its address is stable.
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
