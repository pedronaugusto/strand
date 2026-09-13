# zjsonl

[![CI](https://github.com/pedronaugusto/zjsonl/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zjsonl/actions/workflows/ci.yml)

Typed [JSON Lines](https://jsonlines.org) for Zig: one JSON value per line,
read and written on top of `std.json`. For append-only logs, line protocols
and event streams.

JSON Lines is the format a log already wants to be — a complete JSON value,
then `\n`, and nothing else on the line — because it stays greppable,
tailable and appendable, and frames a stream without a length prefix.
`std.json` has every piece needed to parse and emit the values. What it does
not have is the line layer, and a program that keeps a log ends up writing
that layer itself, usually three times:

- **A line is a unit of failure.** One bad line in a million-line log should
  name itself and be skippable, not abort the read. `zjsonl.Reader` reports
  `error.MalformedLine` with the line number and the underlying `std.json`
  error, and can be told to skip instead (`on_malformed = .skip`).
- **A line is a unit of memory.** A reader that allocates per line and frees
  per stream is a leak with a slow fuse. This reader recycles one line buffer
  and one arena, so a stream of any length costs what its longest line costs,
  and `keep` is the one call that copies a value out.
- **Strings should not be copied twice.** `std.json`'s `.alloc_if_needed`
  lets a string field point into the line's own bytes when it needs no
  unescaping, which is the common case for a log. `zjsonl` reads that way by
  default and documents exactly how long the borrow lasts.
- **A line has a kind.** `kindOf` reads the first key of the object, and
  `tagOf` turns it into the tag of a tagged union, without parsing the value —
  so a dispatcher can route a line to the right type before committing to it.

## Usage

The block below is not written here: it is a region of
[`examples/usage.zig`](examples/usage.zig), which `zig build examples` builds
and RUNS, extracted by `ci/readme_usage.sh` and compared by CI. A snippet in a
README is a claim about how the library is used, and this one is a claim
something executes.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const zjsonl = @import("zjsonl");

// Write: one JSON value per line, minified, null optionals left out.
var out: std.Io.Writer.Allocating = .init(arena);
var log: zjsonl.Writer(Event) = .init(&out.writer, .{});
try log.write(.{ .kind = "open", .at = 1, .note = "user \"ada\"" });
try log.write(.{ .kind = "retry", .at = 2, .level = .warn });
try log.write(.{ .kind = "close", .at = 3 });

// Read: a stream of typed lines, each with its number and its bytes.
var source: std.Io.Reader = .fixed(out.written());
var events: zjsonl.Reader(Event) = .init(std.heap.page_allocator, &source, .{
    // Defaults, spelled out: a line the reader does not fully understand
    // is still a line, and one it cannot parse at all names itself.
    .ignore_unknown_fields = true,
    .max_line_bytes = 64 * 1024,
    .on_malformed = .fail,
});
defer events.deinit();

var warnings: u32 = 0;
var last_open: ?Event = null;
while (try events.next()) |line| {
    // `line.value` is valid until the next `next`: its strings point into
    // `line.line`, which the reader reuses. `keep` copies one out.
    if (std.mem.eql(u8, line.value.kind, "open")) {
        last_open = try events.keep(arena, line);
    }
    if (line.value.level == .warn) warnings += 1;
    std.debug.print("line {d}: {s}\n", .{ line.number, line.line });
}

// Route a line by its first key, without parsing the value.
const kind = zjsonl.kindOf("{\"kind\":\"open\",\"at\":1}");
```
<!-- END GENERATED -->

`std.Io.Reader.fixed` above is what makes the example self-contained; in a
program the source is a file or a socket, and any `*std.Io.Reader` will do.

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/zjsonl
```

```zig
const zjsonl_dep = b.dependency("zjsonl", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zjsonl", zjsonl_dep.module("zjsonl"));
```

There is nothing to link and nothing to configure: pure Zig, `std` only, no
build options, no C.

## Memory

Three rules, and they are the whole of it.

1. **A line's value borrows from the reader.** `Line.line` is the reader's
   own line buffer, and the value's string fields point either into that
   buffer (when they needed no unescaping) or into the reader's arena (when
   they did).
2. **The next line takes it back.** `next` clears the line buffer and resets
   the arena before it parses, so everything the previous `Line` pointed at is
   gone by the time the next one is returned — which is exactly why the cost
   of a stream does not grow with its length.
3. **`keep` is how a value outlives its line.** It returns a copy allocated on
   an allocator you give it, with every string copied, borrowing nothing from
   the reader. Pass an arena and drop it when you are done.

`parseLine` follows the same shape without a reader: allocations land on the
allocator you pass (use an arena), and strings borrow from the line you pass
unless you ask for `copy_strings`. `lines` and `kindOf` allocate nothing at
all and return views into the buffer they were given.

## Errors

`Reader.next` has four failure modes, and only one of them is about the
content of a line:

| Error | Meaning |
|---|---|
| `error.MalformedLine` | This line is not a `T`. `last_error_line` says which line, `last_error` says what `std.json` made of it. |
| `error.LineTooLong` | The line ran past `max_line_bytes`. It is discarded whole. |
| `error.ReadFailed` | The underlying `std.Io.Reader` failed; ask it for diagnostics. |
| `error.OutOfMemory` | The allocator failed. |

The first two do not desynchronize the stream: the offending line is consumed
in full, so `next` can simply be called again. The other two can arrive in the
middle of a line and leave the stream wherever they found it. Blank lines are
skipped by default and still counted, so a line number always means the line a
text editor would show.

## What this package does not do

- It does not parse JSON. `std.json` does; this is the line layer over it,
  and every parse option that matters is forwarded rather than reinvented.
- It does not own, buffer, open, close, flush, lock, rotate or seek a stream.
  It takes a `*std.Io.Reader` or a `*std.Io.Writer` and leaves the rest to
  the caller.
- It does not index a log, read one backwards, or seek to line *n*.
- It does not validate a line it is not asked to parse: `kindOf` answering is
  not a claim that the line is valid JSON.
- It does not decode escapes in `kindOf`/`tagOf`. A first key containing a
  `\` is answered with `null` rather than a wrong guess; parse the line if
  you need it.
- It has no global state, no threads, no allocator of its own, and no
  dependency beyond `std`.

## Requirements

Zig 0.16.0. `zig build test` runs the suite — 26 tests, every one under
`std.testing.allocator`, in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall
on Linux, macOS and Windows.

Four of them are `std.testing.fuzz` properties over generated lines: nothing
panics, nothing leaks, every line is reported under its own number, and a line
that cannot be parsed does not cost the reader its place in the stream. A
plain `zig build test` checks them over a corpus and a table of awkward inputs,
which is quick; `zig build test --fuzz` runs them as a campaign.

## License

MIT. See [LICENSE](LICENSE).
