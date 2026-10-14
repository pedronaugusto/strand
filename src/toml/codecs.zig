//! TOML's dates and times as types: an offset date-time, a local date-time,
//! a local date and a local time, each its own type, none of them turned
//! into another (a local time never becomes UTC, a local date never a
//! midnight). In TOML each is read and written as itself; in any other
//! format, as text in RFC 3339's spelling. A fraction of a second is kept to
//! the nanosecond; TOML truncates finer digits, as its specification asks.
const std = @import("std");
const temporal = @import("temporal.zig");
const Format = @import("Decoder.zig").Format;

/// A day, with no relation to an offset or a time zone (`1979-05-27`).
pub const LocalDate = struct {
    year: u16,
    month: u8,
    day: u8,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!LocalDate {
        return dateOf(try read(access, .local_date));
    }
    pub fn strandSerialize(self: LocalDate, access: anytype) @TypeOf(access.*).Error!void {
        try write(access, self.asParts());
    }
    /// `text` as a local date, or null when it is none.
    pub fn parse(text: []const u8) ?LocalDate {
        const parts = temporal.parse(text) orelse return null;
        return if (parts.kind == .local_date) dateOf(parts) else null;
    }
    pub fn format(self: LocalDate, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return spell(self.asParts(), writer);
    }
    fn asParts(self: LocalDate) temporal.Parts {
        return .{ .kind = .local_date, .year = self.year, .month = self.month, .day = self.day };
    }
};

/// A time of day, with no relation to a day, an offset or a time zone (`07:32:00`).
pub const LocalTime = struct {
    hour: u8,
    minute: u8,
    second: u8 = 0,
    nanosecond: u32 = 0,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!LocalTime {
        return timeOf(try read(access, .local_time));
    }
    pub fn strandSerialize(self: LocalTime, access: anytype) @TypeOf(access.*).Error!void {
        try write(access, self.asParts());
    }
    /// `text` as a local time, or null when it is none.
    pub fn parse(text: []const u8) ?LocalTime {
        const parts = temporal.parse(text) orelse return null;
        return if (parts.kind == .local_time) timeOf(parts) else null;
    }
    pub fn format(self: LocalTime, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return spell(self.asParts(), writer);
    }
    fn asParts(self: LocalTime) temporal.Parts {
        return .{ .kind = .local_time, .hour = self.hour, .minute = self.minute, .second = self.second, .nanosecond = self.nanosecond };
    }
};

/// A day and a time of it, with no relation to an offset or a time zone
/// (`1979-05-27T07:32:00`): no instant until a zone is chosen for it.
pub const LocalDateTime = struct {
    date: LocalDate,
    time: LocalTime,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!LocalDateTime {
        const parts = try read(access, .local_date_time);
        return .{ .date = dateOf(parts), .time = timeOf(parts) };
    }
    pub fn strandSerialize(self: LocalDateTime, access: anytype) @TypeOf(access.*).Error!void {
        try write(access, self.asParts());
    }
    /// `text` as a local date-time, or null when it is none.
    pub fn parse(text: []const u8) ?LocalDateTime {
        const parts = temporal.parse(text) orelse return null;
        return if (parts.kind == .local_date_time) .{ .date = dateOf(parts), .time = timeOf(parts) } else null;
    }
    pub fn format(self: LocalDateTime, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return spell(self.asParts(), writer);
    }
    fn asParts(self: LocalDateTime) temporal.Parts {
        var p = self.time.asParts();
        p.kind = .local_date_time;
        p.year = self.date.year;
        p.month = self.date.month;
        p.day = self.date.day;
        return p;
    }
};

/// An instant: a day and a time at an offset from UTC
/// (`1979-05-27T00:32:00-07:00`). An offset of zero is written `Z`.
pub const OffsetDateTime = struct {
    date: LocalDate,
    time: LocalTime,
    /// Minutes east of UTC, from -1439 to 1439.
    offset_minutes: i16,

    pub fn strandDeserialize(access: anytype) @TypeOf(access.*).Error!OffsetDateTime {
        const parts = try read(access, .offset_date_time);
        return .{ .date = dateOf(parts), .time = timeOf(parts), .offset_minutes = parts.offset_minutes };
    }
    pub fn strandSerialize(self: OffsetDateTime, access: anytype) @TypeOf(access.*).Error!void {
        try write(access, self.asParts());
    }
    /// `text` as an offset date-time, or null when it is none.
    pub fn parse(text: []const u8) ?OffsetDateTime {
        const parts = temporal.parse(text) orelse return null;
        return if (parts.kind == .offset_date_time) .{ .date = dateOf(parts), .time = timeOf(parts), .offset_minutes = parts.offset_minutes } else null;
    }
    pub fn format(self: OffsetDateTime, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return spell(self.asParts(), writer);
    }
    fn asParts(self: OffsetDateTime) temporal.Parts {
        var p = (LocalDateTime{ .date = self.date, .time = self.time }).asParts();
        p.kind = .offset_date_time;
        p.offset_minutes = self.offset_minutes;
        return p;
    }
};

fn dateOf(parts: temporal.Parts) LocalDate {
    return .{ .year = parts.year, .month = parts.month, .day = parts.day };
}
fn timeOf(parts: temporal.Parts) LocalTime {
    return .{ .hour = parts.hour, .minute = parts.minute, .second = parts.second, .nanosecond = parts.nanosecond };
}

/// The value's parts, of `kind`: in TOML, the tag naming its kind and then
/// its spelling; elsewhere, text that spells one of that kind.
fn read(access: anytype, kind: temporal.Kind) @TypeOf(access.*).Error!temporal.Parts {
    if (comptime @TypeOf(access.*).Format == Format) {
        if (try access.tag() != @backingInt(kind)) return error.UnexpectedType;
    }
    const spelling = try access.read([]const u8);
    const parts = temporal.parse(spelling) orelse return error.UnsupportedValue;
    if (parts.kind != kind) return error.UnexpectedType;
    return parts;
}
fn write(access: anytype, parts: temporal.Parts) @TypeOf(access.*).Error!void {
    if (!temporal.valid(parts)) return error.UnsupportedValue;
    var buffer: [temporal.max_len]u8 = undefined;
    const spelled = temporal.format(parts, &buffer);
    if (comptime @TypeOf(access.*).Format == Format) try access.tag(@backingInt(parts.kind));
    try access.write(spelled);
}
fn spell(parts: temporal.Parts, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var buffer: [temporal.max_len]u8 = undefined;
    try writer.writeAll(temporal.format(parts, &buffer));
}

test "each type parsed from its spelling and spelled back" {
    var buffer: [64]u8 = undefined;
    const odt = OffsetDateTime.parse("1979-05-27 00:32:00.5-07:00").?;
    try std.testing.expectEqual(@as(i16, -420), odt.offset_minutes);
    try std.testing.expectEqualStrings("1979-05-27T00:32:00.5-07:00", try std.mem.print(&buffer, "{f}", .{odt}));
    try std.testing.expectEqualStrings("1979-05-27T07:32:00", try std.mem.print(&buffer, "{f}", .{LocalDateTime.parse("1979-05-27t07:32").?}));
    try std.testing.expectEqualStrings("2000-02-29", try std.mem.print(&buffer, "{f}", .{LocalDate.parse("2000-02-29").?}));
    try std.testing.expectEqualStrings("07:32:00.999999", try std.mem.print(&buffer, "{f}", .{LocalTime.parse("07:32:00.999999").?}));
    // Each kind is its own: one is never read as another.
    try std.testing.expectEqual(null, LocalDate.parse("1979-05-27T07:32:00"));
    try std.testing.expectEqual(null, LocalDateTime.parse("1979-05-27T07:32:00Z"));
    try std.testing.expectEqual(null, OffsetDateTime.parse("1979-05-27T07:32:00"));
}
