# Changelog

Each entry says what the old shape could not express, so a port has the reason
and not only the diff. Versions follow [semantic versioning](https://semver.org);
before 1.0 the minor is the breaking one.

## 0.1.0

First release: the line layer over `std.json`, and nothing else.

- `Reader(T)` reads a `*std.Io.Reader` as a stream of typed lines, each
  carrying its value, its raw bytes and its 1-based number. One line buffer
  and one arena are recycled per line, so the cost of a stream is the cost of
  its longest line; `keep` copies a value onto a caller's allocator when it
  has to outlive the line it came from.
- A malformed line is `error.MalformedLine` naming the line in
  `last_error_line`, with the `std.json` error in `last_error`, or is skipped
  under `on_malformed = .skip`. An over-long line is `error.LineTooLong` and
  is discarded whole. No failure desynchronizes the stream.
- Strings borrow from the line's own bytes when they need no unescaping
  (`std.json`'s `.alloc_if_needed`), and the borrow's lifetime is documented
  per field rather than implied.
- `kindOf` and `tagOf` answer what kind of line this is from the first key
  alone, allocating nothing and parsing no value; both answer `null` rather
  than guess at an escaped key.
- `Writer(T)` and `writeLine` emit one minified value per line, omitting null
  optional fields by default, and count what they wrote. `parseLine` and
  `lines` cover a buffer already in memory.
