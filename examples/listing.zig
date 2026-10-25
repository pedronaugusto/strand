//! An S3 bucket listing as XML: attributes, child elements and repeated
//! children read into structs, an entity of the document's own expanded,
//! a document read as `xml.Element`, and a value written back.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- xml`
//! extracts the region between the xml markers into README.md.

const std = @import("std");
const strand = @import("strand");

const Object = struct { Key: []const u8, Size: u64, StorageClass: []const u8 = "STANDARD" };
const Listing = struct {
    Name: []const u8,
    IsTruncated: bool,
    Contents: []const Object = &.{},
};
const Link = struct { @"@href": []const u8, @"@rel": []const u8 = "alternate" };
const Entry = struct { @"@id": u32, title: []const u8, link: Link };

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // --- README:xml ---

    const text =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        \\  <Name>photos</Name>
        \\  <IsTruncated>false</IsTruncated>
        \\  <Contents><Key>2026/beach.jpg</Key><Size>434234</Size></Contents>
        \\  <Contents><Key>a &amp; b.txt</Key><Size> 7 </Size><StorageClass>GLACIER</StorageClass></Contents>
        \\</ListBucketResult>
    ;
    var listing = try strand.xml.parse(Listing, gpa, text, .{});
    defer listing.deinit();
    std.debug.assert(listing.value.Contents.len == 2);
    std.debug.assert(std.mem.eql(u8, listing.value.Contents[1].Key, "a & b.txt"));
    std.debug.assert(listing.value.Contents[1].Size == 7);

    // `@name` is an attribute; attributes come before children.
    var out: std.Io.Writer.Allocating = .init(gpa);
    try strand.xml.write(&out.writer, Entry{ .@"@id" = 7, .title = "Hello & welcome", .link = .{ .@"@href" = "/7" } }, .{ .root = "entry", .declaration = false });
    std.debug.assert(std.mem.eql(u8, out.written(), "<entry id=\"7\"><title>Hello &amp; welcome</title><link href=\"/7\" rel=\"alternate\"/></entry>"));

    // A document's own entities are expanded; an external one is never fetched.
    const doctype = "<!DOCTYPE p [<!ENTITY who \"World\">]><p class=\"x\">Hello, <b>&who;</b>!</p>";
    var element = try strand.xml.parse(strand.xml.Element, gpa, doctype, .{});
    defer element.deinit();
    std.debug.assert(std.mem.eql(u8, element.value.attribute("class").?, "x"));
    std.debug.assert(std.mem.eql(u8, element.value.child("b").?.text, "World"));
    const external = "<!DOCTYPE p [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><p>&x;</p>";
    std.debug.assert(strand.xml.parse(strand.xml.Element, gpa, external, .{}) == error.UnsupportedValue);
    // --- README:xml ---

    std.log.info("xml: {s}", .{out.written()});
}
