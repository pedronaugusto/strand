//! XML: documents read as types (attributes, child elements, text, repeated
//! children grouped wherever they stand, unions by element name) and as
//! `xml.Element`, entities expanded within the limits and never fetched,
//! namespaces checked, documents written and read back, failures placed in
//! the text, limits at their edges, allocation failures, and properties over
//! generated values and over any bytes. The W3C conformance suite runs in
//! `testing/xml_suite.zig`.
const std = @import("std");
const xml = @import("xml.zig");
const core = @import("core.zig");
const shakedown = @import("shakedown");
const gen = shakedown.gen;

const gpa = std.testing.allocator;

const Owner = struct { ID: []const u8, DisplayName: []const u8 = "" };
const Object = struct {
    Key: []const u8,
    LastModified: []const u8,
    ETag: []const u8,
    Size: u64,
    StorageClass: []const u8,
    Owner: ?Owner = null,
};
/// An S3 `ListBucketResult`, as a client reads one.
const Listing = struct {
    Name: []const u8,
    Prefix: []const u8 = "",
    MaxKeys: u32,
    IsTruncated: bool,
    Contents: []const Object = &.{},
};

fn written(value: anytype, options: xml.WriteOptions) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try xml.write(&out.writer, value, options);
    return out.toOwnedSlice();
}

test "an S3 listing read as a type: a default namespace, repeated children, numbers and booleans" {
    const input =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        \\  <Name>bucket</Name>
        \\  <Prefix/>
        \\  <MaxKeys>1000</MaxKeys>
        \\  <IsTruncated>false</IsTruncated>
        \\  <Contents>
        \\    <Key>my-image.jpg</Key>
        \\    <LastModified>2009-10-12T17:50:30.000Z</LastModified>
        \\    <ETag>&quot;fba9dede5f27731c9771645a39863328&quot;</ETag>
        \\    <Size>434234</Size>
        \\    <StorageClass>STANDARD</StorageClass>
        \\  </Contents>
        \\  <Contents>
        \\    <Key>a &amp; b.txt</Key>
        \\    <LastModified>2009-10-12T17:50:31.000Z</LastModified>
        \\    <ETag>"x"</ETag>
        \\    <Size> 7 </Size>
        \\    <StorageClass>STANDARD</StorageClass>
        \\    <Owner><ID>75aa</ID><DisplayName>mtd</DisplayName></Owner>
        \\  </Contents>
        \\</ListBucketResult>
    ;
    var parsed = try xml.parse(Listing, gpa, input, .{});
    defer parsed.deinit();
    const v = parsed.value;
    try std.testing.expectEqualStrings("bucket", v.Name);
    try std.testing.expectEqualStrings("", v.Prefix);
    try std.testing.expectEqual(@as(u32, 1000), v.MaxKeys);
    try std.testing.expect(!v.IsTruncated);
    try std.testing.expectEqual(@as(usize, 2), v.Contents.len);
    try std.testing.expectEqualStrings("\"fba9dede5f27731c9771645a39863328\"", v.Contents[0].ETag);
    try std.testing.expectEqualStrings("a & b.txt", v.Contents[1].Key);
    try std.testing.expectEqual(@as(u64, 7), v.Contents[1].Size);
    try std.testing.expectEqualStrings("mtd", v.Contents[1].Owner.?.DisplayName);
    try std.testing.expectEqual(null, v.Contents[0].Owner);
}

const Link = struct { @"@href": []const u8, @"@rel": []const u8 = "alternate" };
/// Attributes come before children: a start tag is written before them.
const Item = struct { @"@id": u32, title: []const u8, link: Link };
const Feed = struct {
    @"@version": []const u8,
    title: []const u8,
    item: []const Item = &.{},
    note: ?[]const u8 = null,
};

test "attributes and children, repeated children apart from one another, a round trip" {
    const input =
        \\<feed version="2.0"><item id="1"><title>a</title><link href="/a"/></item>
        \\<title>T</title><item id="2"><link href="/b" rel="self"/><title>b</title></item></feed>
    ;
    var parsed = try xml.parse(Feed, gpa, input, .{});
    defer parsed.deinit();
    const v = parsed.value;
    try std.testing.expectEqualStrings("2.0", v.@"@version");
    try std.testing.expectEqualStrings("T", v.title);
    try std.testing.expectEqual(@as(usize, 2), v.item.len);
    try std.testing.expectEqual(@as(u32, 2), v.item[1].@"@id");
    try std.testing.expectEqualStrings("self", v.item[1].link.@"@rel");
    try std.testing.expectEqualStrings("alternate", v.item[0].link.@"@rel");

    const out = try written(v, .{ .root = "feed", .declaration = false });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<feed version=\"2.0\"><title>T</title><item id=\"1\"><title>a</title><link href=\"/a\" rel=\"alternate\"/></item><item id=\"2\"><title>b</title><link href=\"/b\" rel=\"self\"/></item></feed>", out);
    var again = try xml.parse(Feed, gpa, out, .{});
    defer again.deinit();
    try std.testing.expectEqualStrings("b", again.value.item[1].title);
}

test "text beside attributes, a union by element name, enums and floats" {
    const Price = struct { @"@currency": []const u8, @"$text": f64 };
    const Shape = union(enum) { circle: struct { @"@r": f32 }, square: struct { @"@side": f32 }, none };
    const Doc = struct { price: Price, shape: Shape, kind: enum { a, b }, ratio: f64 };
    const input = "<doc><price currency=\"EUR\">12.50</price><shape><square side=\"2\"/></shape><kind>b</kind><ratio>-INF</ratio></doc>";
    var parsed = try xml.parse(Doc, gpa, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 12.5), parsed.value.price.@"$text");
    try std.testing.expectEqual(@as(f32, 2), parsed.value.shape.square.@"@side");
    try std.testing.expectEqual(.b, parsed.value.kind);
    try std.testing.expect(std.math.isNegativeInf(parsed.value.ratio));
    const out = try written(parsed.value, .{ .root = "doc", .declaration = false });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<doc><price currency=\"EUR\">12.5</price><shape><square side=\"2\"/></shape><kind>b</kind><ratio>-INF</ratio></doc>", out);

    // A union at the root is its arm's element.
    var root = try xml.parse(Shape, gpa, "<circle r=\"1.5\"/>", .{});
    defer root.deinit();
    try std.testing.expectEqual(@as(f32, 1.5), root.value.circle.@"@r");
    const shape_out = try written(Shape{ .none = {} }, .{ .root = "ignored", .declaration = false });
    defer gpa.free(shape_out);
    try std.testing.expectEqualStrings("<none/>", shape_out);
}

test "a document as xml.Element: mixed content kept in order, written back" {
    const input = "<p class=\"x\">Hello <b>big</b> <i>world</i>!<br/></p>";
    var parsed = try xml.parse(xml.Element, gpa, input, .{});
    defer parsed.deinit();
    const e = parsed.value;
    try std.testing.expectEqualStrings("p", e.name);
    try std.testing.expectEqualStrings("x", e.attribute("class").?);
    try std.testing.expectEqual(@as(usize, 7), e.content.len);
    try std.testing.expectEqualStrings(" ", e.content[3].value.text);
    try std.testing.expectEqualStrings("big", e.child("b").?.text);
    const out = try written(e, .{ .root = "ignored", .declaration = false });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<p class=\"x\">Hello <b>big</b> <i>world</i>!<br></br></p>", out);
    var again = try xml.parse(xml.Element, gpa, out, .{});
    defer again.deinit();
    try std.testing.expect(e.eql(again.value));
}

test "internal entities are expanded, external ones never fetched, a billion laughs refused" {
    const Doc = struct { a: []const u8, @"@t": []const u8 };
    const input =
        \\<!DOCTYPE doc [
        \\  <!ENTITY who "World">
        \\  <!ENTITY greeting "Hello, &who;!">
        \\  <!ENTITY bold "<b>x</b>">
        \\]>
        \\<doc t="&greeting;"><a>&greeting; &#x263A;</a></doc>
    ;
    var parsed = try xml.parse(Doc, gpa, input, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Hello, World! \u{263A}", parsed.value.a);
    try std.testing.expectEqualStrings("Hello, World!", parsed.value.@"@t");

    const external = "<!DOCTYPE doc [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><doc><a>&x;</a></doc>";
    try std.testing.expectError(error.UnsupportedValue, xml.parse(Doc, gpa, external, .{ .ignore_unknown_fields = true }));
    const in_attribute = "<!DOCTYPE doc [<!ENTITY x SYSTEM \"a\">]><doc t=\"&x;\"/>";
    try std.testing.expectError(error.SyntaxError, xml.parse(Doc, gpa, in_attribute, .{}));
    const recursive = "<!DOCTYPE doc [<!ENTITY a \"&b;\"><!ENTITY b \"&a;\">]><doc><a>&a;</a></doc>";
    try std.testing.expectError(error.SyntaxError, xml.parse(Doc, gpa, recursive, .{}));
    const undeclared = "<doc><a>&nope;</a></doc>";
    try std.testing.expectError(error.SyntaxError, xml.parse(Doc, gpa, undeclared, .{}));

    var laughs: std.ArrayList(u8) = .empty;
    defer laughs.deinit(gpa);
    try laughs.appendSlice(gpa, "<!DOCTYPE lolz [<!ENTITY lol0 \"lol\">");
    for (1..10) |i| {
        try laughs.print(gpa, "<!ENTITY lol{d} \"", .{i});
        for (0..10) |_| try laughs.print(gpa, "&lol{d};", .{i - 1});
        try laughs.appendSlice(gpa, "\">");
    }
    try laughs.appendSlice(gpa, "]><lolz>&lol9;</lolz>");
    const result = xml.parse([]const u8, gpa, laughs.items, .{});
    try std.testing.expect(result == error.WorkLimit or result == error.AllocationLimit);
}

test "namespaces are checked, declarations are no members" {
    const Envelope = struct { @"soap:Body": struct { m: u8 } };
    const input = "<soap:Envelope xmlns:soap=\"http://www.w3.org/2003/05/soap-envelope\"><soap:Body><m>1</m></soap:Body></soap:Envelope>";
    var parsed = try xml.parse(Envelope, gpa, input, .{ .root = "soap:Envelope" });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u8, 1), parsed.value.@"soap:Body".m);
    try std.testing.expectError(error.UnexpectedType, xml.parse(Envelope, gpa, input, .{ .root = "Envelope" }));
    try std.testing.expectError(error.SyntaxError, xml.parse(xml.Element, gpa, "<a:b/>", .{}));
    var lenient = try xml.parse(xml.Element, gpa, "<a:b/>", .{ .namespaces = false });
    defer lenient.deinit();
    try std.testing.expectError(error.SyntaxError, xml.parse(xml.Element, gpa, "<a xmlns:p=\"u\" xmlns:q=\"u\" p:x=\"1\" q:x=\"2\"/>", .{}));
}

test "unknown members, a second child of one name, and refusals placed in the text" {
    const One = struct { a: u8 };
    try std.testing.expectError(error.UnknownField, xml.parse(One, gpa, "<r><a>1</a><b/></r>", .{}));
    var skipped = try xml.parse(One, gpa, "<r x=\"1\"><a>1</a><b><c/></b></r>", .{ .ignore_unknown_fields = true });
    skipped.deinit();
    try std.testing.expectError(error.DuplicateField, xml.parse(One, gpa, "<r><a>1</a><a>2</a></r>", .{}));
    try std.testing.expectError(error.UnexpectedType, xml.parse(One, gpa, "<r><a>x</a></r>", .{}));
    var d: core.Diagnostics = .{};
    try std.testing.expectError(error.SyntaxError, xml.parse(One, gpa, "<r>\n<a>1</b></r>", .{ .diagnostics = &d }));
    try std.testing.expectEqual(@as(usize, 2), d.line);
}

test "what XML cannot hold is refused when written" {
    const T = struct { a: []const u8 };
    var buffer: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.UnsupportedValue, xml.write(&w, T{ .a = "\x00" }, .{ .root = "r" }));
    w = .fixed(&buffer);
    try std.testing.expectError(error.UnsupportedValue, xml.write(&w, T{ .a = "x" }, .{ .root = "1r" }));
    const S = struct { a: []const []const u8 };
    w = .fixed(&buffer);
    try xml.write(&w, S{ .a = &.{ "x", "<&>\r" } }, .{ .root = "r", .declaration = false });
    try std.testing.expectEqualStrings("<r><a>x</a><a>&lt;&amp;&gt;&#13;</a></r>", w.buffered());
    var back = try xml.parse(S, gpa, w.buffered(), .{});
    defer back.deinit();
    try std.testing.expectEqualStrings("<&>\r", back.value.a[1]);
}

test "UTF-16 by its byte-order mark" {
    const text = "<a>\u{e9}</a>";
    var units: [64]u8 = undefined;
    units[0] = 0xFF;
    units[1] = 0xFE;
    var n: usize = 2;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        std.mem.writeInt(u16, units[n..][0..2], @intCast(cp), .little);
        n += 2;
    }
    var parsed = try xml.parse([]const u8, gpa, units[0..n], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("\u{e9}", parsed.value);
}

fn sweep(a: std.mem.Allocator) !void {
    const input = "<!DOCTYPE r [<!ENTITY e \"&#x41;<b>x</b>\">]><r k=\"v&amp;\">t&e;<c><d/></c>&lt;</r>";
    var parsed = try xml.parseOwned(xml.Element, a, input, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    // The writer's own allocation failing is its write failing.
    xml.write(&out.writer, parsed.value, .{ .root = "r" }) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
}

test "every allocation failure while reading and writing is an error, never a leak" {
    try std.testing.checkAllAllocationFailures(gpa, sweep, .{});
}

const names = [_][]const u8{ "a", "b", "item", "x-y", "_z.1", "\u{e9}t\u{e9}", "p:q" };
/// Text XML can hold, never blank, so that it is content wherever it stands.
fn content(case: *shakedown.Case) error{OutOfMemory}![]const u8 {
    const raw = try gen.string(case.source, case.gpa, .{ .max_len = 12 });
    var out: std.ArrayList(u8) = .empty;
    try out.append(case.gpa, 't');
    var pieces = std.unicode.Utf8View.initUnchecked(raw).iterator();
    while (pieces.nextCodepointSlice()) |piece| {
        const keep = if (piece.len == 1) (piece[0] >= 0x20 or piece[0] == '\t' or piece[0] == '\n' or piece[0] == '\r') else !std.mem.eql(u8, piece, "\u{FFFE}") and !std.mem.eql(u8, piece, "\u{FFFF}");
        try out.appendSlice(case.gpa, if (keep) piece else "x");
    }
    return out.toOwnedSlice(case.gpa);
}
/// A generated element's content: attributes of distinct names, then text
/// runs and child elements, never two runs side by side (a reader joins
/// them). A child of text alone is that text.
fn entries(case: *shakedown.Case, depth: u8) error{OutOfMemory}![]const xml.Entry {
    const s = case.source;
    const a = case.gpa;
    var list: std.ArrayList(xml.Entry) = .empty;
    var used: [names.len]bool = @splat(false);
    for (0..gen.intRange(s, usize, 0, 3)) |_| {
        const k = gen.intRange(s, usize, 0, names.len - 2);
        if (used[k]) continue;
        used[k] = true;
        try list.append(a, .{ .key = try std.mem.concat(a, u8, &.{ "@", names[k] }), .value = .{ .text = try content(case) } });
    }
    var last_text = false;
    for (0..gen.intRange(s, usize, 0, if (depth == 0) 1 else 4)) |_| {
        if (!last_text and gen.boolean(s)) {
            try list.append(a, .{ .key = "$text", .value = .{ .text = try content(case) } });
            last_text = true;
            continue;
        }
        last_text = false;
        const name = gen.oneOf(s, []const u8, names[0 .. names.len - 1]);
        const inner = if (depth == 0) &.{} else try entries(case, depth - 1);
        const holds_more = for (inner) |e| {
            if (!std.mem.eql(u8, e.key, "$text")) break true;
        } else false;
        if (holds_more) {
            try list.append(a, .{ .key = name, .value = .{ .content = inner } });
        } else {
            try list.append(a, .{ .key = name, .value = .{ .text = if (inner.len == 1) inner[0].value.text else "" } });
        }
    }
    return list.toOwnedSlice(a);
}

fn roundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const element: xml.Element = .{ .name = gen.oneOf(case.source, []const u8, names[0 .. names.len - 1]), .content = try entries(case, 3) };
    var out: std.Io.Writer.Allocating = .init(case.gpa);
    try xml.write(&out.writer, element, .{ .root = "ignored" });
    case.note("xml: {s}", .{out.written()});
    var parsed = try xml.parse(xml.Element, case.gpa, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.eql(element));
    // Cut anywhere, it is refused or read as some document, never a crash;
    // a document read is written and read back as itself.
    for (0..out.written().len) |end| {
        var cut = xml.parse(xml.Element, case.gpa, out.written()[0..end], .{}) catch continue;
        defer cut.deinit();
        try rewritten(case, cut.value);
    }
}
fn rewritten(case: *shakedown.Case, element: xml.Element) !void {
    var again: std.Io.Writer.Allocating = .init(case.gpa);
    defer again.deinit();
    try xml.write(&again.writer, element, .{ .root = "ignored" });
    var back = try xml.parse(xml.Element, case.gpa, again.written(), .{});
    defer back.deinit();
    try std.testing.expect(back.value.eql(element));
}

test "generated documents read back as they were, truncated anywhere" {
    try shakedown.check(gpa, {}, roundTrip, .{ .cases = 400 });
}

const examples = [_][]const u8{
    "<?xml version=\"1.0\"?><a x='1'>t<b/><![CDATA[<c>]]><!--n--><?p d?></a>",
    "<!DOCTYPE d [<!ENTITY e \"v&#65;\"><!ATTLIST d k CDATA 'z'>]><d k=\"&e;\">&e;&amp;</d>",
    "<p:r xmlns:p=\"u\" p:a=\"1\"><p:s>\r\n x </p:s></p:r>",
    "<l><i>1</i><i>2</i><j>3</j><i>4</i></l>",
};
fn anyBytes(_: void, case: *shakedown.Case) anyerror!void {
    var buffer: [160]u8 = undefined;
    const input = gen.mutated(case.source, &buffer, &examples);
    case.note("input: {s}", .{input});
    // The scanner reads any bytes to an end or a refusal.
    var scanner: xml.Scanner = undefined;
    scanner.init(case.gpa, input, .{ .limits = .{ .work = 1 << 16 } });
    defer scanner.deinit();
    const scanned = while (true) {
        const token = scanner.next() catch break false;
        if (token == null) break true;
    };
    const options: xml.ParseOptions = .{ .limits = .{ .work = 1 << 16, .depth = 32, .items = 1 << 12 } };
    var parsed = xml.parse(xml.Element, case.gpa, input, options) catch |err| {
        // Refused borrowed, refused owned and on an arena, alike.
        try std.testing.expectError(err, xml.parseOwned(xml.Element, case.gpa, input, options));
        return;
    };
    defer parsed.deinit();
    // A document read is one the scanner reads whole.
    try std.testing.expect(scanned);
    var owned = try xml.parseOwned(xml.Element, case.gpa, input, options);
    defer owned.deinit();
    var arena: std.heap.ArenaAllocator = .init(case.gpa);
    defer arena.deinit();
    const leaky = try xml.parseLeaky(xml.Element, arena.allocator(), input, options);
    try std.testing.expect(parsed.value.eql(owned.value));
    try std.testing.expect(parsed.value.eql(leaky));
    try rewritten(case, parsed.value);
}

test "fuzz: any bytes are a document or refused, and a document read is written and read back as itself" {
    try shakedown.check(gpa, {}, anyBytes, .{ .cases = 3000 });
}

fn typedRoundTrip(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const a = case.gpa;
    const items = try a.alloc(Item, gen.intRange(s, usize, 0, 4));
    for (items) |*it| it.* = .{ .@"@id" = gen.int(s, u32), .title = try content(case), .link = .{ .@"@href" = try content(case), .@"@rel" = try content(case) } };
    const feed: Feed = .{ .@"@version" = try content(case), .title = try content(case), .item = items, .note = if (gen.boolean(s)) try content(case) else null };
    const out = try written(feed, .{ .root = "feed", .whitespace = gen.oneOf(s, xml.Whitespace, &.{ .minified, .indent_2 }) });
    defer gpa.free(out);
    case.note("xml: {s}", .{out});
    var back = try xml.parse(Feed, a, out, .{});
    defer back.deinit();
    try std.testing.expectEqualDeep(feed, back.value);
}

test "generated typed values read back as they were, minified and indented" {
    try shakedown.check(gpa, {}, typedRoundTrip, .{ .cases = 400 });
}

test "limits at their edges" {
    const depth = "<a><a><a></a></a></a>";
    // The scanner holds a document's nesting to the depth too.
    var scanner: xml.Scanner = undefined;
    scanner.init(gpa, depth, .{ .limits = .{ .depth = 2 } });
    defer scanner.deinit();
    _ = try scanner.next();
    _ = try scanner.next();
    try std.testing.expectError(error.DepthLimit, scanner.next());
    var ok = try xml.parse(xml.Element, gpa, depth, .{ .limits = .{ .depth = 16 } });
    ok.deinit();
    try std.testing.expectError(error.DepthLimit, xml.parse(xml.Element, gpa, depth, .{ .limits = .{ .depth = 2 } }));
    try std.testing.expectError(error.InputLimit, xml.parse(xml.Element, gpa, depth, .{ .limits = .{ .input_bytes = .literal("20B") } }));
    try std.testing.expectError(error.LengthLimit, xml.parse([]const u8, gpa, "<a>abcdef</a>", .{ .limits = .{ .string_bytes = .literal("5B") } }));
    var five = try xml.parse([]const u8, gpa, "<a>abcde</a>", .{ .limits = .{ .string_bytes = .literal("5B") } });
    five.deinit();
}
