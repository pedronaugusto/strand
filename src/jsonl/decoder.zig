//! Push JSON Lines decoder. One owner for its bounded record buffer and arena.
const std = @import("std");
const json = @import("strand.json");
const core = @import("strand.core");
const framing = @import("framing.zig");
const line = @import("line.zig");
pub fn Decoder(comptime T: type) type {
    return struct {
        gpa: std.mem.Allocator,
        options: Options,
        arena: std.heap.ArenaAllocator,
        buffer: []u8 = &.{},
        arena_resident_bytes: usize = 0,
        used: usize = 0,
        consumed: u64 = 0,
        record_offset: u64 = 0,
        number: u64 = 0,
        skipped: u64 = 0,
        discarding: bool = false,
        ready: bool = false,
        finished: bool = false,
        bom_checked: bool = false,
        fault: ?Error = null,
        const Self = @This();
        const ParseError = @typeInfo(@TypeOf(json.parseLeaky(T, @as(std.mem.Allocator, undefined), "", .{}))).error_union.error_set;
        pub const Error = ParseError || error{ LineTooLong, RecoveryLimit, TruncatedRecord, Finished };
        pub const Options = struct {
            max_line_bytes: usize = 1 << 20,
            recovery_bytes: usize = 16 * 1024 * 1024,
            skip_blank: bool = true,
            skip_bom: bool = true,
            crlf: bool = true,
            on_malformed: enum { fail, skip } = .fail,
            final_record: enum { accept, require_terminator, drop } = .accept,
            parse: json.ParseOptions = .{},
        };
        pub const Status = union(enum) { need_input, record: line.Line(T), failure: Error };
        pub const Result = struct { consumed: usize, status: Status };
        pub fn init(gpa: std.mem.Allocator, options: Options) Self {
            return .{ .gpa = gpa, .options = options, .arena = .init(gpa) };
        }
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
            self.gpa.free(self.buffer);
            self.* = undefined;
        }
        /// Returned value/bytes expire on the next push, finish, or deinit.
        pub fn keep(self: *Self, value: T) core.DecodeError!core.Parsed(T) {
            return core.clone(self.gpa, value, self.options.parse.limits);
        }
        fn advance(self: *Self) void {
            if (self.ready) {
                self.used = 0;
                self.ready = false;
                self.record_offset = self.consumed;
            }
            _ = self.arena.reset(.retain_capacity);
        }
        fn append(self: *Self, bytes: []const u8, backing: *core.Backing) Error!void {
            const cap = std.math.add(usize, @min(self.options.max_line_bytes, self.options.parse.limits.input_bytes), 4) catch return error.InputLimit;
            if (bytes.len > cap - self.used) return error.LineTooLong;
            const needed = self.used + bytes.len;
            if (needed > self.buffer.len) {
                const capacity = @min(cap, @max(needed, @max(@as(usize, 64), self.buffer.len *| 2)));
                const available = self.options.parse.limits.allocation_bytes - backing.live;
                if (self.buffer.len > available or capacity > available - self.buffer.len) return error.AllocationLimit;
                const next = try self.gpa.alloc(u8, capacity);
                @memcpy(next[0..self.used], self.buffer[0..self.used]);
                self.gpa.free(self.buffer);
                self.buffer = next;
                backing.limit = self.options.parse.limits.allocation_bytes - capacity;
            }
            @memcpy(self.buffer[self.used..][0..bytes.len], bytes);
            self.used = needed;
        }
        fn record(self: *Self, terminated: bool, backing: *const core.Backing) Status {
            self.number += 1;
            var bytes = self.buffer[0..self.used];
            if (terminated and self.options.crlf and bytes.len != 0 and bytes[bytes.len - 1] == '\r') bytes = bytes[0 .. bytes.len - 1];
            if (!self.bom_checked) {
                self.bom_checked = true;
                if (self.options.skip_bom and std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) {
                    bytes = bytes[3..];
                    self.record_offset += 3;
                }
            }
            self.ready = true;
            if (bytes.len > self.options.max_line_bytes) {
                self.fault = error.LineTooLong;
                return .{ .failure = error.LineTooLong };
            }
            if (self.options.skip_blank and line.isBlank(bytes)) return .need_input;
            var options = self.options.parse;
            options.limits.allocation_bytes -= self.buffer.len;
            const value = json.parseLeaky(T, self.arena.allocator(), bytes, options) catch |failure| {
                const err = if (failure == error.OutOfMemory and backing.limited) error.AllocationLimit else failure;
                self.fault = err;
                if (self.options.on_malformed == .skip and err != error.OutOfMemory and err != error.AllocationLimit) {
                    self.skipped += 1;
                    return .need_input;
                }
                return .{ .failure = err };
            };
            return .{ .record = .{ .value = value, .line = bytes, .number = self.number, .offset = self.record_offset } };
        }
        pub fn push(self: *Self, chunk: []const u8) Result {
            var backing: core.Backing = .{ .gpa = self.gpa, .limit = self.options.parse.limits.allocation_bytes - self.buffer.len, .live = self.arena_resident_bytes };
            self.arena.child_allocator = backing.allocator();
            defer {
                self.arena.child_allocator = self.gpa;
                self.arena_resident_bytes = backing.live;
            }
            return self.pushWith(chunk, &backing);
        }
        fn pushWith(self: *Self, chunk: []const u8, backing: *core.Backing) Result {
            if (self.finished) return .{ .consumed = 0, .status = .{ .failure = error.Finished } };
            self.advance();
            var at: usize = 0;
            var recovery: usize = 0;
            while (at < chunk.len) {
                const part = framing.part(chunk[at..], if (self.discarding) self.options.recovery_bytes - recovery else chunk.len - at);
                if (self.discarding) {
                    at += part.consumed;
                    self.consumed += part.consumed;
                    recovery += part.consumed;
                    if (part.terminated) {
                        self.discarding = false;
                        self.record_offset = self.consumed;
                    } else if (recovery == self.options.recovery_bytes) return .{ .consumed = at, .status = .{ .failure = error.RecoveryLimit } };
                    continue;
                }
                const payload = chunk[at..][0 .. part.consumed - @intFromBool(part.terminated)];
                self.append(payload, backing) catch |err| {
                    if (err != error.LineTooLong) return .{ .consumed = at, .status = .{ .failure = err } };
                    self.used = 0;
                    self.discarding = true;
                    self.number += 1;
                    self.fault = err;
                    return .{ .consumed = at, .status = .{ .failure = err } };
                };
                at += part.consumed;
                self.consumed += part.consumed;
                if (part.terminated) {
                    const status = self.record(true, backing);
                    if (status != .need_input) return .{ .consumed = at, .status = status };
                    self.advance();
                }
            }
            return .{ .consumed = at, .status = .need_input };
        }
        pub fn finish(self: *Self) Result {
            if (self.finished) return .{ .consumed = 0, .status = .need_input };
            var backing: core.Backing = .{ .gpa = self.gpa, .limit = self.options.parse.limits.allocation_bytes - self.buffer.len, .live = self.arena_resident_bytes };
            self.arena.child_allocator = backing.allocator();
            defer {
                self.arena.child_allocator = self.gpa;
                self.arena_resident_bytes = backing.live;
            }
            self.advance();
            self.finished = true;
            if (self.discarding or self.used == 0) return .{ .consumed = 0, .status = .need_input };
            return .{ .consumed = 0, .status = switch (self.options.final_record) {
                .accept => self.record(false, &backing),
                .require_terminator => .{ .failure = error.TruncatedRecord },
                .drop => .need_input,
            } };
        }
    };
}
