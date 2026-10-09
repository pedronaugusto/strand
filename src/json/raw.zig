//! A JSON value kept as the bytes it was written in.
//!
//! A line often carries a value its reader does not read: another program's
//! record passed along, the payload of a plugin the reader only routes, a
//! request handed on as it came. Typed as a `std.json.Value`, that value is
//! built into a tree nobody walks, and the type around it leaves the direct
//! decoder for `std.json`'s token parser, because a `Value` parses itself.
//! Typed as a `Raw`, it is checked and kept: the line is refused if the value
//! is not JSON, and otherwise the value is its bytes, decoded when and if the
//! caller asks and written back as they came.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Scanner = @import("Scanner.zig");
const EncodeBuffer = @import("encode/Buffer.zig");

pub fn RawType(comptime strand: type) type {
    return struct {
        /// One JSON value as its bytes, undecoded.
        ///
        /// Decoding a field of this type checks the value the way the rest of the
        /// line is checked — a value that is not JSON is the line's error, named as
        /// any other would be — and keeps its bytes, from its first to its last,
        /// whitespace inside it included. They borrow from the line exactly as a
        /// string does: a view into it by default, a copy on the allocator under
        /// `copy_strings`; `Reader.keep` copies the already parsed bytes through
        /// `copyOwned`. `parse` is the value when it is wanted, as any type at all.
        ///
        /// Writing one writes the bytes, with two exceptions, both of them promises
        /// the writer makes about every line: a line break, which JSON allows only
        /// between tokens, is written as a space in `.minified`, so a record stays
        /// one line; and under `escape_unicode` a character that is not ASCII is
        /// written as its `\u` escape. Neither changes the value. It is not
        /// re-indented in `.pretty`.
        ///
        /// A `Raw` made by hand is trusted: bytes that are not one JSON value are
        /// written as they are, and make a line no reader will take back.
        /// `parseLine(Raw, ...)` is the constructor that checks them, and `encode` is
        /// the one that makes them from a value.
        ///
        /// The type is on the direct path both ways, and a struct or a union holding
        /// one stays there. Through `std.json`'s own entry points it parses and
        /// stringifies itself; there, a value handed over as a `std.json.Value`
        /// (`std.json.parseFromValue`, `Versioned`'s migration) is kept as that value
        /// encoded, since the bytes it was written in are no longer anywhere.
        pub const Raw = struct {
            /// The value's bytes: one complete JSON value, with nothing before or
            /// after it.
            bytes: []const u8,

            /// JSON `null`, as a default: `data: strand.Raw = .null`.
            pub const @"null": Raw = .{ .bytes = "null" };

            /// What `encode` can fail with.
            pub const EncodeError = Allocator.Error || std.Io.Writer.Error;

            /// `value`, encoded as `Writer` encodes it with its default options, as
            /// a `Raw` on `gpa`. The bytes are one allocation of exactly their
            /// length, so `gpa.free(raw.bytes)` returns it.
            /// `OutOfMemory` means the allocation failed; `WriteFailed` means a
            /// custom `jsonStringify` hook refused to encode the value.
            pub fn encode(gpa: Allocator, value: anytype) EncodeError!Raw {
                var out: EncodeBuffer = .init(gpa);
                defer out.deinit();
                strand.writeValue(&out.writer, value, .{}) catch |err| return out.diagnose(err);
                return .{ .bytes = try out.toOwnedSlice() };
            }

            // A parsed JSON tree has no custom hooks; only its storage can fail.
            fn fromValue(arena: Allocator, value: std.json.Value) Allocator.Error!Raw {
                return encode(arena, value) catch |err| switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.WriteFailed => unreachable,
                };
            }

            /// The value, as a `T`: `parseLine` over the bytes, with its options,
            /// its errors and its ownership. Strings that need no unescaping point
            /// into `raw.bytes`, so they live as long as those do.
            pub fn parse(
                raw: Raw,
                comptime T: type,
                arena: Allocator,
                options: strand.ParseOptions,
            ) strand.ParseLineError!T {
                return strand.parseLine(T, arena, raw.bytes, options);
            }

            /// Reads the value. Called by `std.json`, and by this package on the
            /// paths that use `std.json`'s token parser.
            ///
            /// A source that holds the whole input in one slice — this package's
            /// scanner, or `std.json.Scanner` over complete input — is where the
            /// bytes are, so the value is checked by skipping it and the bytes it
            /// covered are kept. A source that streams has no such slice; there the
            /// value is parsed and encoded, which keeps what it means and not how it
            /// was spaced.
            pub fn jsonParse(
                arena: Allocator,
                source: anytype,
                options: std.json.ParseOptions,
            ) std.json.ParseError(@TypeOf(source.*))!Raw {
                const Source = @TypeOf(source.*);
                if (comptime Source == Scanner or Source == std.json.Scanner) whole: {
                    if (Source == std.json.Scanner and !source.is_end_of_input) break :whole;
                    // The peek steps over whitespace and the colon before a
                    // field's value, so the cursor is on the value's first byte.
                    switch (try source.peekNextTokenType()) {
                        // No value starts here. `std.json.Scanner`'s peek
                        // names a bracket by its own kind even where it closes
                        // the other kind of container, and the token is
                        // taken so the scanner says which error it is; to
                        // skip it would be to skip a value that is not there.
                        .object_end, .array_end, .end_of_document => {
                            _ = try source.next();
                            return error.UnexpectedToken;
                        },
                        else => {},
                    }
                    const start = source.cursor;
                    try source.skipValue();
                    return keep(arena, source.input[start..source.cursor], options);
                }
                const value = try std.json.innerParse(std.json.Value, arena, source, options);
                return fromValue(arena, value);
            }

            /// A value `std.json` has already parsed into a `std.json.Value`: kept
            /// as that value encoded.
            pub fn jsonParseFromValue(
                arena: Allocator,
                source: std.json.Value,
                options: std.json.ParseOptions,
            ) std.json.ParseFromValueError!Raw {
                _ = options;
                return fromValue(arena, source);
            }

            /// Writes the value. Called by `std.json`; `Writer` writes a `Raw`
            /// itself in `.minified` and through this in `.pretty`, and the bytes
            /// written are the same, line breaks and escapes as the type says.
            pub fn jsonStringify(raw: Raw, jw: anytype) !void {
                try jw.beginWriteRaw();
                try strand.encode.raw(raw.bytes, jw.options, jw.writer);
                jw.endWriteRaw();
            }

            /// The bytes as a decoded value would hold them: borrowed unless every
            /// string is to be copied.
            fn keep(arena: Allocator, bytes: []const u8, options: std.json.ParseOptions) Allocator.Error!Raw {
                if ((options.allocate orelse .alloc_always) == .alloc_always)
                    return .{ .bytes = try arena.dupe(u8, bytes) };
                return .{ .bytes = bytes };
            }
        };

        //=========================================================================
        // Tests. The scenarios with a stream in them are in `strand_test.zig`.
        //=========================================================================

    };
}
