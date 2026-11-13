//! The formats strand asserts, each by a strict recognizer of its
//! grammar, never a lenient reader: almanac's RFC 3339 checks for dates and
//! times, uplink's RFC 3986 and 3987 parser for URIs and IRIs, xenoglyph's
//! IDNA2008 validity for internationalized names, spectra's ECMA-262 reading
//! for `regex`, and the grammars here for the rest. A format strand does not
//! know is an annotation; every format passes a value that is not a string.
const std = @import("std");
const aegis = @import("aegis");
const almanac = @import("almanac");
const spectra = @import("spectra");
const wire = @import("uplink.wire");
const net = @import("formats/net.zig");
const text = @import("formats/text.zig");

pub const Kind = enum {
    date_time,
    date,
    time,
    duration,
    email,
    idn_email,
    hostname,
    idn_hostname,
    ipv4,
    ipv6,
    uri,
    uri_reference,
    iri,
    iri_reference,
    uuid,
    uri_template,
    json_pointer,
    relative_json_pointer,
    regex,

    /// The format a schema names, null for one strand does not know.
    pub fn fromName(name: []const u8) ?Kind {
        const names: std.StaticStringMap(Kind) = .initComptime(.{
            .{ "date-time", .date_time },       .{ "date", .date },
            .{ "time", .time },                 .{ "duration", .duration },
            .{ "email", .email },               .{ "idn-email", .idn_email },
            .{ "hostname", .hostname },         .{ "idn-hostname", .idn_hostname },
            .{ "ipv4", .ipv4 },                 .{ "ipv6", .ipv6 },
            .{ "uri", .uri },                   .{ "uri-reference", .uri_reference },
            .{ "iri", .iri },                   .{ "iri-reference", .iri_reference },
            .{ "uuid", .uuid },                 .{ "uri-template", .uri_template },
            .{ "json-pointer", .json_pointer }, .{ "relative-json-pointer", .relative_json_pointer },
            .{ "regex", .regex },
        });
        return names.get(name);
    }
};

/// Whether the string `s` is of format `kind`. `gpa` is the `regex`
/// format's scratch.
pub fn check(gpa: std.mem.Allocator, kind: Kind, s: []const u8) error{ OutOfMemory, TooLarge }!bool {
    return switch (kind) {
        .date_time => almanac.text.strict.isDateTime(s),
        .date => almanac.text.strict.isDate(s),
        .time => almanac.text.strict.isTime(s),
        .duration => almanac.text.strict.isDuration(s),
        .email => net.isEmail(s, false),
        .idn_email => net.isEmail(s, true),
        .hostname => net.isHostname(s),
        .idn_hostname => net.isIdnHostname(s),
        .ipv4 => net.isIpv4(s),
        .ipv6 => net.isIpv6(s),
        .uri => isUri(s, .uri, .uri),
        .uri_reference => isUri(s, .reference, .uri),
        .iri => isUri(s, .uri, .iri),
        .iri_reference => isUri(s, .reference, .iri),
        .uuid => text.isUuid(s),
        .uri_template => text.isUriTemplate(s),
        .json_pointer => text.isJsonPointer(s),
        .relative_json_pointer => text.isRelativeJsonPointer(s),
        // ECMA-262's grammar with the `u` flag, as JSON Schema reads
        // patterns: a pattern spectra would refuse to run is still a regex.
        .regex => spectra.ecmascript.validate(gpa, .init(s), "u", .{}, null),
    };
}

fn isUri(s: []const u8, form: wire.uri.Form, charset: wire.uri.Charset) bool {
    _ = wire.uri.parse(aegis.input.Untrusted([]const u8).init(s), form, charset, null) catch return false;
    return true;
}

test {
    _ = net;
    _ = text;
}

test "each format by name, and its recognizer" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Kind.date_time, Kind.fromName("date-time").?);
    try std.testing.expect(Kind.fromName("color") == null);
    const cases = [_]struct { Kind, []const u8, bool }{
        .{ .date_time, "1963-06-19T08:30:06.283185Z", true },
        .{ .date_time, "1963-06-19 08:30:06Z", false },
        .{ .date, "2020-02-29", true },
        .{ .date, "2021-02-29", false },
        .{ .time, "23:59:60Z", true },
        .{ .time, "12:00:60Z", false },
        .{ .duration, "P4DT12H30M5S", true },
        .{ .duration, "PT", false },
        .{ .uri, "http://example.com/a?b#c", true },
        .{ .uri, "/relative", false },
        .{ .uri_reference, "/relative", true },
        .{ .iri, "http://ƒøø.ßår/?∂éœ=πîx#πîüx", true },
        .{ .uri, "http://ƒøø.ßår/", false },
        .{ .regex, "^[a-z]+(?<=x)$", true },
        .{ .regex, "^(abc]", false },
    };
    for (cases) |c| try std.testing.expectEqual(c[2], try check(a, c[0], c[1]));
}
