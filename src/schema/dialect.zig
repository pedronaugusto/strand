//! The drafts a schema may be written in, and what each reads: its keywords,
//! the vocabularies they belong to, and which of them hold subschemas. The
//! drafts differ here and in the compiler only; the evaluator is the same.
const std = @import("std");

/// The drafts a schema may be written in.
pub const Dialect = enum {
    draft7,
    draft2019_09,
    draft2020_12,

    /// The dialect a `$schema` names, with or without its empty fragment.
    pub fn fromUri(text: []const u8) ?Dialect {
        const name = if (std.mem.endsWith(u8, text, "#")) text[0 .. text.len - 1] else text;
        for (std.enums.values(Dialect)) |d| {
            if (std.mem.eql(u8, name, d.uri())) return d;
        }
        return null;
    }

    /// Its meta-schema's URI, with no fragment.
    pub fn uri(d: Dialect) []const u8 {
        return switch (d) {
            .draft7 => "http://json-schema.org/draft-07/schema",
            .draft2019_09 => "https://json-schema.org/draft/2019-09/schema",
            .draft2020_12 => "https://json-schema.org/draft/2020-12/schema",
        };
    }
};

/// A vocabulary: a set of keywords a meta-schema's `$vocabulary` turns on.
/// draft-07 has none; every one of its keywords is always read.
pub const Vocabulary = enum {
    core,
    applicator,
    /// 2020-12's own; 2019-09 keeps its two keywords in the applicator.
    unevaluated,
    validation,
    meta_data,
    /// 2020-12: `format` an annotation.
    format_annotation,
    /// 2020-12: `format` an assertion.
    format_assertion,
    /// 2019-09: `format`, an annotation unless asked.
    format,
    content,
};

pub const Vocabularies = std.EnumSet(Vocabulary);

/// The vocabulary `text` names in `d`, or null for one strand does not know.
pub fn vocabularyFromUri(d: Dialect, text: []const u8) ?Vocabulary {
    const prefix = switch (d) {
        .draft7 => return null,
        .draft2019_09 => "https://json-schema.org/draft/2019-09/vocab/",
        .draft2020_12 => "https://json-schema.org/draft/2020-12/vocab/",
    };
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const name = text[prefix.len..];
    const names: std.StaticStringMap(Vocabulary) = .initComptime(.{
        .{ "core", .core },                         .{ "applicator", .applicator },
        .{ "unevaluated", .unevaluated },           .{ "validation", .validation },
        .{ "meta-data", .meta_data },               .{ "format-annotation", .format_annotation },
        .{ "format-assertion", .format_assertion }, .{ "format", .format },
        .{ "content", .content },
    });
    const v = names.get(name) orelse return null;
    return if (inDialect(d, v)) v else null;
}

/// Whether `v` is one of `d`'s vocabularies.
fn inDialect(d: Dialect, v: Vocabulary) bool {
    return switch (v) {
        .core, .applicator, .validation, .meta_data, .content => d != .draft7,
        .unevaluated, .format_annotation, .format_assertion => d == .draft2020_12,
        .format => d == .draft2019_09,
    };
}

/// What `d`'s own meta-schema turns on: every vocabulary but 2020-12's
/// format assertion. draft-07's keywords are read whatever this says.
pub fn defaults(d: Dialect) Vocabularies {
    var set: Vocabularies = .empty;
    for (std.enums.values(Vocabulary)) |v| {
        if (v != .format_assertion and (d == .draft7 or inDialect(d, v))) set.insert(v);
    }
    return set;
}

/// Every keyword of the three drafts.
pub const Keyword = enum {
    id,
    schema,
    ref,
    anchor,
    dynamic_ref,
    dynamic_anchor,
    recursive_ref,
    recursive_anchor,
    vocabulary,
    comment,
    defs,
    definitions,
    prefix_items,
    items,
    additional_items,
    contains,
    additional_properties,
    properties,
    pattern_properties,
    dependent_schemas,
    property_names,
    @"if",
    then,
    @"else",
    all_of,
    any_of,
    one_of,
    not,
    dependencies,
    unevaluated_items,
    unevaluated_properties,
    type,
    @"const",
    @"enum",
    multiple_of,
    maximum,
    exclusive_maximum,
    minimum,
    exclusive_minimum,
    max_length,
    min_length,
    pattern,
    max_items,
    min_items,
    unique_items,
    max_contains,
    min_contains,
    max_properties,
    min_properties,
    required,
    dependent_required,
    title,
    description,
    default,
    deprecated,
    read_only,
    write_only,
    examples,
    format,
    content_encoding,
    content_media_type,
    content_schema,

    /// Its name in a schema.
    pub fn name(k: Keyword) []const u8 {
        return names[@backingInt(k)];
    }

    const names = blk: {
        const fields = std.enums.values(Keyword);
        var out: [fields.len][]const u8 = undefined;
        for (spellings) |s| out[@backingInt(s[1])] = s[0];
        break :blk out;
    };
};

const spellings = [_]struct { []const u8, Keyword }{
    .{ "$id", .id },                                       .{ "$schema", .schema },
    .{ "$ref", .ref },                                     .{ "$anchor", .anchor },
    .{ "$dynamicRef", .dynamic_ref },                      .{ "$dynamicAnchor", .dynamic_anchor },
    .{ "$recursiveRef", .recursive_ref },                  .{ "$recursiveAnchor", .recursive_anchor },
    .{ "$vocabulary", .vocabulary },                       .{ "$comment", .comment },
    .{ "$defs", .defs },                                   .{ "definitions", .definitions },
    .{ "prefixItems", .prefix_items },                     .{ "items", .items },
    .{ "additionalItems", .additional_items },             .{ "contains", .contains },
    .{ "additionalProperties", .additional_properties },   .{ "properties", .properties },
    .{ "patternProperties", .pattern_properties },         .{ "dependentSchemas", .dependent_schemas },
    .{ "propertyNames", .property_names },                 .{ "if", .@"if" },
    .{ "then", .then },                                    .{ "else", .@"else" },
    .{ "allOf", .all_of },                                 .{ "anyOf", .any_of },
    .{ "oneOf", .one_of },                                 .{ "not", .not },
    .{ "dependencies", .dependencies },                    .{ "unevaluatedItems", .unevaluated_items },
    .{ "unevaluatedProperties", .unevaluated_properties }, .{ "type", .type },
    .{ "const", .@"const" },                               .{ "enum", .@"enum" },
    .{ "multipleOf", .multiple_of },                       .{ "maximum", .maximum },
    .{ "exclusiveMaximum", .exclusive_maximum },           .{ "minimum", .minimum },
    .{ "exclusiveMinimum", .exclusive_minimum },           .{ "maxLength", .max_length },
    .{ "minLength", .min_length },                         .{ "pattern", .pattern },
    .{ "maxItems", .max_items },                           .{ "minItems", .min_items },
    .{ "uniqueItems", .unique_items },                     .{ "maxContains", .max_contains },
    .{ "minContains", .min_contains },                     .{ "maxProperties", .max_properties },
    .{ "minProperties", .min_properties },                 .{ "required", .required },
    .{ "dependentRequired", .dependent_required },         .{ "title", .title },
    .{ "description", .description },                      .{ "default", .default },
    .{ "deprecated", .deprecated },                        .{ "readOnly", .read_only },
    .{ "writeOnly", .write_only },                         .{ "examples", .examples },
    .{ "format", .format },                                .{ "contentEncoding", .content_encoding },
    .{ "contentMediaType", .content_media_type },          .{ "contentSchema", .content_schema },
};

const by_name: std.StaticStringMap(Keyword) = .initComptime(spellings);

/// The keyword `text` spells in `d` and the vocabulary it belongs to, or
/// null where `d` has no such keyword: an unknown keyword, an annotation.
pub fn keyword(d: Dialect, text: []const u8) ?struct { Keyword, Vocabulary } {
    const k = by_name.get(text) orelse return null;
    const v = vocabularyOf(d, k) orelse return null;
    return .{ k, v };
}

/// The vocabulary `k` belongs to in `d`, null where `d` lacks it. draft-07's
/// keywords are given the 2019-09 vocabulary they moved to.
fn vocabularyOf(d: Dialect, k: Keyword) ?Vocabulary {
    return switch (k) {
        .id, .schema, .ref, .comment => .core,
        .defs, .vocabulary, .anchor => if (d == .draft7) null else .core,
        .definitions => if (d == .draft7) .core else null,
        .dynamic_ref, .dynamic_anchor => if (d == .draft2020_12) .core else null,
        .recursive_ref, .recursive_anchor => if (d == .draft2019_09) .core else null,
        .prefix_items => if (d == .draft2020_12) .applicator else null,
        .additional_items => if (d == .draft2020_12) null else .applicator,
        .dependencies => if (d == .draft7) .applicator else null,
        .dependent_schemas => if (d == .draft7) null else .applicator,
        .items, .contains, .additional_properties, .properties, .pattern_properties, .property_names => .applicator,
        .@"if", .then, .@"else", .all_of, .any_of, .one_of, .not => .applicator,
        .unevaluated_items, .unevaluated_properties => switch (d) {
            .draft7 => null,
            .draft2019_09 => .applicator,
            .draft2020_12 => .unevaluated,
        },
        .max_contains, .min_contains, .dependent_required => if (d == .draft7) null else .validation,
        .type, .@"const", .@"enum", .multiple_of, .maximum, .exclusive_maximum, .minimum, .exclusive_minimum => .validation,
        .max_length, .min_length, .pattern, .max_items, .min_items, .unique_items => .validation,
        .max_properties, .min_properties, .required => .validation,
        .deprecated => if (d == .draft7) null else .meta_data,
        .title, .description, .default, .read_only, .write_only, .examples => .meta_data,
        .format => switch (d) {
            .draft7, .draft2019_09 => .format,
            .draft2020_12 => .format_annotation,
        },
        .content_schema => if (d == .draft7) null else .content,
        .content_encoding, .content_media_type => .content,
    };
}

/// How a keyword holds subschemas: the places a schema's identifiers may be.
pub const Shape = enum { one, list, map, one_or_list };

/// Where `keyword` holds subschemas in `d`, null where it holds none: an
/// `$id` inside `enum`, `const` or an unknown keyword's value identifies
/// nothing. `definitions` and `dependencies` stay schema places in the later
/// drafts, whose meta-schemas still read their values as schemas.
pub fn shape(d: Dialect, text: []const u8) ?Shape {
    const k = by_name.get(text) orelse return null;
    return switch (k) {
        .definitions, .dependencies, .properties, .pattern_properties => .map,
        .additional_properties, .not, .@"if", .then, .@"else", .contains, .property_names => .one,
        .all_of, .any_of, .one_of => .list,
        .items => if (d == .draft2020_12) .one else .one_or_list,
        .additional_items => if (d == .draft2020_12) null else .one,
        .prefix_items => if (d == .draft2020_12) .list else null,
        .defs, .dependent_schemas => if (d == .draft7) null else .map,
        .unevaluated_items, .unevaluated_properties, .content_schema => if (d == .draft7) null else .one,
        else => null,
    };
}

const testing = std.testing;

test "a dialect is named by its meta-schema's URI, with or without the empty fragment" {
    try testing.expectEqual(Dialect.draft7, Dialect.fromUri("http://json-schema.org/draft-07/schema#").?);
    try testing.expectEqual(Dialect.draft7, Dialect.fromUri("http://json-schema.org/draft-07/schema").?);
    try testing.expectEqual(Dialect.draft2020_12, Dialect.fromUri("https://json-schema.org/draft/2020-12/schema").?);
    try testing.expectEqual(Dialect.draft2019_09, Dialect.fromUri("https://json-schema.org/draft/2019-09/schema#").?);
    try testing.expect(Dialect.fromUri("http://json-schema.org/draft-04/schema#") == null);
}

test "each draft's keywords, and the vocabularies they belong to" {
    try testing.expect(keyword(.draft7, "$defs") == null);
    try testing.expectEqual(Keyword.definitions, keyword(.draft7, "definitions").?[0]);
    try testing.expect(keyword(.draft2020_12, "definitions") == null);
    try testing.expect(keyword(.draft2020_12, "additionalItems") == null);
    try testing.expectEqual(Vocabulary.unevaluated, keyword(.draft2020_12, "unevaluatedItems").?[1]);
    try testing.expectEqual(Vocabulary.applicator, keyword(.draft2019_09, "unevaluatedItems").?[1]);
    try testing.expect(keyword(.draft2019_09, "$dynamicRef") == null);
    try testing.expect(keyword(.draft2020_12, "$recursiveRef") == null);
    try testing.expectEqual(Vocabulary.format_annotation, keyword(.draft2020_12, "format").?[1]);
    try testing.expect(keyword(.draft2020_12, "x-unknown") == null);
    // Every keyword spelled once, and named back as spelled.
    for (spellings) |s| try testing.expectEqualStrings(s[0], s[1].name());
    try testing.expectEqual(std.enums.values(Keyword).len, spellings.len);
}

test "vocabularies: each draft's URIs, and what its own meta-schema turns on" {
    try testing.expectEqual(Vocabulary.validation, vocabularyFromUri(.draft2020_12, "https://json-schema.org/draft/2020-12/vocab/validation").?);
    try testing.expectEqual(Vocabulary.format, vocabularyFromUri(.draft2019_09, "https://json-schema.org/draft/2019-09/vocab/format").?);
    try testing.expect(vocabularyFromUri(.draft2019_09, "https://json-schema.org/draft/2019-09/vocab/unevaluated") == null);
    try testing.expect(vocabularyFromUri(.draft2020_12, "https://json-schema.org/draft/2020-12/vocab/format") == null);
    try testing.expect(vocabularyFromUri(.draft2020_12, "http://example.com/vocab/custom") == null);
    try testing.expect(!defaults(.draft2020_12).contains(.format_assertion));
    try testing.expect(defaults(.draft2020_12).contains(.unevaluated));
    try testing.expect(!defaults(.draft2019_09).contains(.unevaluated));
}
