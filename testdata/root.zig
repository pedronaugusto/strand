//! strand's test data: the conformance corpora (JSONTestSuite, json5-tests, toml-test, the YAML
//! test suite, the msgpack test suite, the cyberphone JCS corpus, python-dotenv's cases, the W3C
//! XML suite's manifest) and recorded answers, each with its licence under corpus/. It stays out
//! of src/ and of the package a project fetches (build.zig.zon's paths), and reaches the tests
//! only as the development build's module `testdata`.

/// The file at `path` under testdata/, embedded: `file("corpus/yaml/cases")`.
pub fn file(comptime path: []const u8) @TypeOf(@embedFile(path)) {
    return @embedFile(path);
}
