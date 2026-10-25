//! The W3C XML Conformance Test Suite (xmlts20130923), every test that
//! applies to a reader of XML 1.0 (fifth edition) that fetches no external
//! entity: each valid and invalid document (well-formed, whatever its DTD
//! says) read as `xml.Element`, each document that is not well-formed
//! refused. The documents are the W3C's tarball, fetched by the build (its
//! parts' licences allow no other copy); `corpus/xml/xmlconf.manifest` lists
//! the tests, made from the suite's own files by type, namespace flag, path
//! and ID, and the build embeds the documents it lists. Tests skipped are named below with their reasons; the manifest
//! leaves out those for XML 1.1, for editions before the fifth, those whose
//! documents need an external entity, and the optional `error` ones.
const std = @import("std");
const xml = @import("../xml.zig");
const suite = @import("xmlconf_documents");

const manifest = @embedFile("../corpus/xml/xmlconf.manifest");

/// Tests strand does not pass, each with its reason.
const skipped = [_]struct { []const u8, []const u8 }{
    .{ "rmt-e3e-13", "well-formed, but refers to an entity declared nowhere: strand refuses it (UnsupportedValue) rather than read the content without it" },
    .{ "rmt-ns10-012", "two namespace names equal only once an ATTLIST's NMTOKEN normalization is applied, which strand does not apply (design: CDATA normalization only, as libxml2 and Go by default)" },
};

fn isSkipped(id: []const u8) bool {
    for (skipped) |s| if (std.mem.eql(u8, s[0], id)) return true;
    return false;
}

test "the W3C XML conformance suite" {
    // The build fetches the suite unless it runs without its lazy
    // dependencies.
    const documents = suite.documents orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var failures: usize = 0;
    var passed: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, manifest, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const kind = fields.next().?;
        const namespaces = std.mem.eql(u8, fields.next().?, "yes");
        const path = fields.next().?;
        const id = fields.next().?;
        const input = documents[index];
        const result = xml.parse(xml.Element, gpa, input, .{ .namespaces = namespaces });
        const well_formed = !std.mem.eql(u8, kind, "not-wf");
        var ok = false;
        if (result) |parsed| {
            var p = parsed;
            p.deinit();
            ok = well_formed;
        } else |err| {
            ok = !well_formed and (err == error.SyntaxError or err == error.InvalidUtf8);
            if (!ok and !isSkipped(id)) std.debug.print("{s} {s} ({s}): {t}\n", .{ id, kind, path, err });
        }
        if (ok) {
            passed += 1;
            if (isSkipped(id)) {
                std.debug.print("{s} passes and is listed as skipped\n", .{id});
                failures += 1;
            }
        } else if (!isSkipped(id)) {
            if (well_formed == false) std.debug.print("{s} {s} ({s}): accepted\n", .{ id, kind, path });
            failures += 1;
        }
    }
    if (failures != 0) {
        std.debug.print("xmlconf: {d} passed, {d} failed, {d} skipped\n", .{ passed, failures, skipped.len });
        return error.TestUnexpectedResult;
    }
}
