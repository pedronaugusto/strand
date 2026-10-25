//! json5-tests (github.com/json5/json5-tests) at ceb24d4, MIT license beside
//! the inputs in `src/corpus/json5-tests`: a `.json` or `.json5` case is
//! read, a `.js` or `.txt` case refused. Each case read is the value JSON5's
//! reference implementation (json5 2.2.3) reads it as, which `expected`
//! holds as JSON5 (trials' `strand/formats/json5/node/main.js suite` writes
//! these cases); a `.json` case is the value JSON reads it as, too, but for
//! `comments/irregular-block-comment.json`, which has a comment, and so is
//! no JSON. A key given twice keeps its last value, as the reference keeps it.
const std = @import("std");
const strand = @import("../strand.zig");
const json = strand.json;

const Case = struct { name: []const u8, input: []const u8, expected: ?[]const u8 };

const cases = [_]Case{
    .{ .name = "arrays/empty-array.json", .input = @embedFile("../corpus/json5-tests/arrays/empty-array.json"), .expected = "[]" },
    .{ .name = "arrays/leading-comma-array.js", .input = @embedFile("../corpus/json5-tests/arrays/leading-comma-array.js"), .expected = null },
    .{ .name = "arrays/lone-trailing-comma-array.js", .input = @embedFile("../corpus/json5-tests/arrays/lone-trailing-comma-array.js"), .expected = null },
    .{ .name = "arrays/no-comma-array.txt", .input = @embedFile("../corpus/json5-tests/arrays/no-comma-array.txt"), .expected = null },
    .{ .name = "arrays/regular-array.json", .input = @embedFile("../corpus/json5-tests/arrays/regular-array.json"), .expected = "[true,false,null]" },
    .{ .name = "arrays/trailing-comma-array.json5", .input = @embedFile("../corpus/json5-tests/arrays/trailing-comma-array.json5"), .expected = "[null]" },
    .{ .name = "comments/block-comment-following-array-element.json5", .input = @embedFile("../corpus/json5-tests/comments/block-comment-following-array-element.json5"), .expected = "[false]" },
    .{ .name = "comments/block-comment-following-top-level-value.json5", .input = @embedFile("../corpus/json5-tests/comments/block-comment-following-top-level-value.json5"), .expected = "null" },
    .{ .name = "comments/block-comment-in-string.json", .input = @embedFile("../corpus/json5-tests/comments/block-comment-in-string.json"), .expected = "\"This /* block comment */ isn't really a block comment.\"" },
    .{ .name = "comments/block-comment-preceding-top-level-value.json5", .input = @embedFile("../corpus/json5-tests/comments/block-comment-preceding-top-level-value.json5"), .expected = "null" },
    .{ .name = "comments/block-comment-with-asterisks.json5", .input = @embedFile("../corpus/json5-tests/comments/block-comment-with-asterisks.json5"), .expected = "true" },
    .{ .name = "comments/inline-comment-following-array-element.json5", .input = @embedFile("../corpus/json5-tests/comments/inline-comment-following-array-element.json5"), .expected = "[false]" },
    .{ .name = "comments/inline-comment-following-top-level-value.json5", .input = @embedFile("../corpus/json5-tests/comments/inline-comment-following-top-level-value.json5"), .expected = "null" },
    .{ .name = "comments/inline-comment-in-string.json", .input = @embedFile("../corpus/json5-tests/comments/inline-comment-in-string.json"), .expected = "\"This inline comment // isn't really an inline comment.\"" },
    .{ .name = "comments/inline-comment-preceding-top-level-value.json5", .input = @embedFile("../corpus/json5-tests/comments/inline-comment-preceding-top-level-value.json5"), .expected = "null" },
    .{ .name = "comments/irregular-block-comment.json", .input = @embedFile("../corpus/json5-tests/comments/irregular-block-comment.json"), .expected = "true" },
    .{ .name = "comments/top-level-block-comment.txt", .input = @embedFile("../corpus/json5-tests/comments/top-level-block-comment.txt"), .expected = null },
    .{ .name = "comments/top-level-inline-comment.txt", .input = @embedFile("../corpus/json5-tests/comments/top-level-inline-comment.txt"), .expected = null },
    .{ .name = "comments/unterminated-block-comment.txt", .input = @embedFile("../corpus/json5-tests/comments/unterminated-block-comment.txt"), .expected = null },
    .{ .name = "misc/empty.txt", .input = @embedFile("../corpus/json5-tests/misc/empty.txt"), .expected = null },
    .{ .name = "misc/npm-package.json", .input = @embedFile("../corpus/json5-tests/misc/npm-package.json"), .expected = "{\"name\":\"npm\",\"publishConfig\":{\"proprietary-attribs\":false},\"description\":\"A package manager for node\",\"keywords\":[\"package manager\",\"modules\",\"install\",\"package.json\"],\"version\":\"1.1.22\",\"preferGlobal\":true,\"config\":{\"publishtest\":false},\"homepage\":\"http://npmjs.org/\",\"author\":\"Isaac Z. Schlueter <i@izs.me> (http://blog.izs.me)\",\"repository\":{\"type\":\"git\",\"url\":\"https://github.com/isaacs/npm\"},\"bugs\":{\"email\":\"npm-@googlegroups.com\",\"url\":\"http://github.com/isaacs/npm/issues\"},\"directories\":{\"doc\":\"./doc\",\"man\":\"./man\",\"lib\":\"./lib\",\"bin\":\"./bin\"},\"main\":\"./lib/npm.js\",\"bin\":\"./bin/npm-cli.js\",\"dependencies\":{\"semver\":\"~1.0.14\",\"ini\":\"1\",\"slide\":\"1\",\"abbrev\":\"1\",\"graceful-fs\":\"~1.1.1\",\"minimatch\":\"~0.2\",\"nopt\":\"1\",\"node-uuid\":\"~1.3\",\"proto-list\":\"1\",\"rimraf\":\"2\",\"request\":\"~2.9\",\"which\":\"1\",\"tar\":\"~0.1.12\",\"fstream\":\"~0.1.17\",\"block-stream\":\"*\",\"inherits\":\"1\",\"mkdirp\":\"0.3\",\"read\":\"0\",\"lru-cache\":\"1\",\"node-gyp\":\"~0.4.1\",\"fstream-npm\":\"0 >=0.0.5\",\"uid-number\":\"0\",\"archy\":\"0\",\"chownr\":\"0\"},\"bundleDependencies\":[\"slide\",\"ini\",\"semver\",\"abbrev\",\"graceful-fs\",\"minimatch\",\"nopt\",\"node-uuid\",\"rimraf\",\"request\",\"proto-list\",\"which\",\"tar\",\"fstream\",\"block-stream\",\"inherits\",\"mkdirp\",\"read\",\"lru-cache\",\"node-gyp\",\"fstream-npm\",\"uid-number\",\"archy\",\"chownr\"],\"devDependencies\":{\"ronn\":\"https://github.com/isaacs/ronnjs/tarball/master\"},\"engines\":{\"node\":\"0.6 || 0.7 || 0.8\",\"npm\":\"1\"},\"scripts\":{\"test\":\"node ./test/run.js\",\"prepublish\":\"npm prune; rm -rf node_modules/*/{test,example,bench}*; make -j4 doc\",\"dumpconf\":\"env | grep npm | sort | uniq\"},\"licenses\":[{\"type\":\"MIT +no-false-attribs\",\"url\":\"http://github.com/isaacs/npm/raw/master/LICENSE\"}]}" },
    .{ .name = "misc/npm-package.json5", .input = @embedFile("../corpus/json5-tests/misc/npm-package.json5"), .expected = "{\"name\":\"npm\",\"publishConfig\":{\"proprietary-attribs\":false},\"description\":\"A package manager for node\",\"keywords\":[\"package manager\",\"modules\",\"install\",\"package.json\"],\"version\":\"1.1.22\",\"preferGlobal\":true,\"config\":{\"publishtest\":false},\"homepage\":\"http://npmjs.org/\",\"author\":\"Isaac Z. Schlueter <i@izs.me> (http://blog.izs.me)\",\"repository\":{\"type\":\"git\",\"url\":\"https://github.com/isaacs/npm\"},\"bugs\":{\"email\":\"npm-@googlegroups.com\",\"url\":\"http://github.com/isaacs/npm/issues\"},\"directories\":{\"doc\":\"./doc\",\"man\":\"./man\",\"lib\":\"./lib\",\"bin\":\"./bin\"},\"main\":\"./lib/npm.js\",\"bin\":\"./bin/npm-cli.js\",\"dependencies\":{\"semver\":\"~1.0.14\",\"ini\":\"1\",\"slide\":\"1\",\"abbrev\":\"1\",\"graceful-fs\":\"~1.1.1\",\"minimatch\":\"~0.2\",\"nopt\":\"1\",\"node-uuid\":\"~1.3\",\"proto-list\":\"1\",\"rimraf\":\"2\",\"request\":\"~2.9\",\"which\":\"1\",\"tar\":\"~0.1.12\",\"fstream\":\"~0.1.17\",\"block-stream\":\"*\",\"inherits\":\"1\",\"mkdirp\":\"0.3\",\"read\":\"0\",\"lru-cache\":\"1\",\"node-gyp\":\"~0.4.1\",\"fstream-npm\":\"0 >=0.0.5\",\"uid-number\":\"0\",\"archy\":\"0\",\"chownr\":\"0\"},\"bundleDependencies\":[\"slide\",\"ini\",\"semver\",\"abbrev\",\"graceful-fs\",\"minimatch\",\"nopt\",\"node-uuid\",\"rimraf\",\"request\",\"proto-list\",\"which\",\"tar\",\"fstream\",\"block-stream\",\"inherits\",\"mkdirp\",\"read\",\"lru-cache\",\"node-gyp\",\"fstream-npm\",\"uid-number\",\"archy\",\"chownr\"],\"devDependencies\":{\"ronn\":\"https://github.com/isaacs/ronnjs/tarball/master\"},\"engines\":{\"node\":\"0.6 || 0.7 || 0.8\",\"npm\":\"1\"},\"scripts\":{\"test\":\"node ./test/run.js\",\"prepublish\":\"npm prune; rm -rf node_modules/*/{test,example,bench}*; make -j4 doc\",\"dumpconf\":\"env | grep npm | sort | uniq\"},\"licenses\":[{\"type\":\"MIT +no-false-attribs\",\"url\":\"http://github.com/isaacs/npm/raw/master/LICENSE\"}]}" },
    .{ .name = "misc/readme-example.json5", .input = @embedFile("../corpus/json5-tests/misc/readme-example.json5"), .expected = "{\"foo\":\"bar\",\"while\":true,\"this\":\"is a multi-line string\",\"here\":\"is another\",\"hex\":3735928559,\"half\":0.5,\"delta\":10,\"to\":Infinity,\"finally\":\"a trailing comma\",\"oh\":[\"we shouldn't forget\",\"arrays can have\",\"trailing commas too\"]}" },
    .{ .name = "misc/valid-whitespace.json5", .input = @embedFile("../corpus/json5-tests/misc/valid-whitespace.json5"), .expected = "{\"a\":true}" },
    .{ .name = "new-lines/comment-cr.json5", .input = @embedFile("../corpus/json5-tests/new-lines/comment-cr.json5"), .expected = "{}" },
    .{ .name = "new-lines/comment-crlf.json5", .input = @embedFile("../corpus/json5-tests/new-lines/comment-crlf.json5"), .expected = "{}" },
    .{ .name = "new-lines/comment-lf.json5", .input = @embedFile("../corpus/json5-tests/new-lines/comment-lf.json5"), .expected = "{}" },
    .{ .name = "new-lines/escaped-cr.json5", .input = @embedFile("../corpus/json5-tests/new-lines/escaped-cr.json5"), .expected = "{\"a\":\"line 1 line 2\"}" },
    .{ .name = "new-lines/escaped-crlf.json5", .input = @embedFile("../corpus/json5-tests/new-lines/escaped-crlf.json5"), .expected = "{\"a\":\"line 1 line 2\"}" },
    .{ .name = "new-lines/escaped-lf.json5", .input = @embedFile("../corpus/json5-tests/new-lines/escaped-lf.json5"), .expected = "{\"a\":\"line 1 line 2\"}" },
    .{ .name = "numbers/float-leading-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/float-leading-decimal-point.json5"), .expected = "0.5" },
    .{ .name = "numbers/float-leading-zero.json", .input = @embedFile("../corpus/json5-tests/numbers/float-leading-zero.json"), .expected = "0.5" },
    .{ .name = "numbers/float-trailing-decimal-point-with-integer-exponent.json5", .input = @embedFile("../corpus/json5-tests/numbers/float-trailing-decimal-point-with-integer-exponent.json5"), .expected = "50000" },
    .{ .name = "numbers/float-trailing-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/float-trailing-decimal-point.json5"), .expected = "5" },
    .{ .name = "numbers/float-with-integer-exponent.json", .input = @embedFile("../corpus/json5-tests/numbers/float-with-integer-exponent.json"), .expected = "1200" },
    .{ .name = "numbers/float.json", .input = @embedFile("../corpus/json5-tests/numbers/float.json"), .expected = "1.2" },
    .{ .name = "numbers/hexadecimal-empty.txt", .input = @embedFile("../corpus/json5-tests/numbers/hexadecimal-empty.txt"), .expected = null },
    .{ .name = "numbers/hexadecimal-lowercase-letter.json5", .input = @embedFile("../corpus/json5-tests/numbers/hexadecimal-lowercase-letter.json5"), .expected = "200" },
    .{ .name = "numbers/hexadecimal-uppercase-x.json5", .input = @embedFile("../corpus/json5-tests/numbers/hexadecimal-uppercase-x.json5"), .expected = "200" },
    .{ .name = "numbers/hexadecimal-with-integer-exponent.json5", .input = @embedFile("../corpus/json5-tests/numbers/hexadecimal-with-integer-exponent.json5"), .expected = "51428" },
    .{ .name = "numbers/hexadecimal.json5", .input = @embedFile("../corpus/json5-tests/numbers/hexadecimal.json5"), .expected = "200" },
    .{ .name = "numbers/infinity.json5", .input = @embedFile("../corpus/json5-tests/numbers/infinity.json5"), .expected = "Infinity" },
    .{ .name = "numbers/integer-with-float-exponent.txt", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-float-exponent.txt"), .expected = null },
    .{ .name = "numbers/integer-with-hexadecimal-exponent.txt", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-hexadecimal-exponent.txt"), .expected = null },
    .{ .name = "numbers/integer-with-integer-exponent.json", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-integer-exponent.json"), .expected = "2e+23" },
    .{ .name = "numbers/integer-with-negative-float-exponent.txt", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-negative-float-exponent.txt"), .expected = null },
    .{ .name = "numbers/integer-with-negative-hexadecimal-exponent.txt", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-negative-hexadecimal-exponent.txt"), .expected = null },
    .{ .name = "numbers/integer-with-negative-integer-exponent.json", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-negative-integer-exponent.json"), .expected = "2e-23" },
    .{ .name = "numbers/integer-with-negative-zero-integer-exponent.json", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-negative-zero-integer-exponent.json"), .expected = "5" },
    .{ .name = "numbers/integer-with-positive-float-exponent.txt", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-positive-float-exponent.txt"), .expected = null },
    .{ .name = "numbers/integer-with-positive-hexadecimal-exponent.txt", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-positive-hexadecimal-exponent.txt"), .expected = null },
    .{ .name = "numbers/integer-with-positive-integer-exponent.json", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-positive-integer-exponent.json"), .expected = "100" },
    .{ .name = "numbers/integer-with-positive-zero-integer-exponent.json", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-positive-zero-integer-exponent.json"), .expected = "5" },
    .{ .name = "numbers/integer-with-zero-integer-exponent.json", .input = @embedFile("../corpus/json5-tests/numbers/integer-with-zero-integer-exponent.json"), .expected = "5" },
    .{ .name = "numbers/integer.json", .input = @embedFile("../corpus/json5-tests/numbers/integer.json"), .expected = "15" },
    .{ .name = "numbers/lone-decimal-point.txt", .input = @embedFile("../corpus/json5-tests/numbers/lone-decimal-point.txt"), .expected = null },
    .{ .name = "numbers/nan.json5", .input = @embedFile("../corpus/json5-tests/numbers/nan.json5"), .expected = "NaN" },
    .{ .name = "numbers/negative-float-leading-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/negative-float-leading-decimal-point.json5"), .expected = "-0.5" },
    .{ .name = "numbers/negative-float-leading-zero.json", .input = @embedFile("../corpus/json5-tests/numbers/negative-float-leading-zero.json"), .expected = "-0.5" },
    .{ .name = "numbers/negative-float-trailing-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/negative-float-trailing-decimal-point.json5"), .expected = "-5" },
    .{ .name = "numbers/negative-float.json", .input = @embedFile("../corpus/json5-tests/numbers/negative-float.json"), .expected = "-1.2" },
    .{ .name = "numbers/negative-hexadecimal.json5", .input = @embedFile("../corpus/json5-tests/numbers/negative-hexadecimal.json5"), .expected = "-200" },
    .{ .name = "numbers/negative-infinity.json5", .input = @embedFile("../corpus/json5-tests/numbers/negative-infinity.json5"), .expected = "-Infinity" },
    .{ .name = "numbers/negative-integer.json", .input = @embedFile("../corpus/json5-tests/numbers/negative-integer.json"), .expected = "-15" },
    .{ .name = "numbers/negative-noctal.js", .input = @embedFile("../corpus/json5-tests/numbers/negative-noctal.js"), .expected = null },
    .{ .name = "numbers/negative-octal.txt", .input = @embedFile("../corpus/json5-tests/numbers/negative-octal.txt"), .expected = null },
    .{ .name = "numbers/negative-zero-float-leading-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/negative-zero-float-leading-decimal-point.json5"), .expected = "-0" },
    .{ .name = "numbers/negative-zero-float-trailing-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/negative-zero-float-trailing-decimal-point.json5"), .expected = "-0" },
    .{ .name = "numbers/negative-zero-float.json", .input = @embedFile("../corpus/json5-tests/numbers/negative-zero-float.json"), .expected = "-0" },
    .{ .name = "numbers/negative-zero-hexadecimal.json5", .input = @embedFile("../corpus/json5-tests/numbers/negative-zero-hexadecimal.json5"), .expected = "-0" },
    .{ .name = "numbers/negative-zero-integer.json", .input = @embedFile("../corpus/json5-tests/numbers/negative-zero-integer.json"), .expected = "-0" },
    .{ .name = "numbers/negative-zero-octal.txt", .input = @embedFile("../corpus/json5-tests/numbers/negative-zero-octal.txt"), .expected = null },
    .{ .name = "numbers/noctal-with-leading-octal-digit.js", .input = @embedFile("../corpus/json5-tests/numbers/noctal-with-leading-octal-digit.js"), .expected = null },
    .{ .name = "numbers/noctal.js", .input = @embedFile("../corpus/json5-tests/numbers/noctal.js"), .expected = null },
    .{ .name = "numbers/octal.txt", .input = @embedFile("../corpus/json5-tests/numbers/octal.txt"), .expected = null },
    .{ .name = "numbers/positive-float-leading-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-float-leading-decimal-point.json5"), .expected = "0.5" },
    .{ .name = "numbers/positive-float-leading-zero.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-float-leading-zero.json5"), .expected = "0.5" },
    .{ .name = "numbers/positive-float-trailing-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-float-trailing-decimal-point.json5"), .expected = "5" },
    .{ .name = "numbers/positive-float.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-float.json5"), .expected = "1.2" },
    .{ .name = "numbers/positive-hexadecimal.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-hexadecimal.json5"), .expected = "200" },
    .{ .name = "numbers/positive-infinity.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-infinity.json5"), .expected = "Infinity" },
    .{ .name = "numbers/positive-integer.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-integer.json5"), .expected = "15" },
    .{ .name = "numbers/positive-noctal.js", .input = @embedFile("../corpus/json5-tests/numbers/positive-noctal.js"), .expected = null },
    .{ .name = "numbers/positive-octal.txt", .input = @embedFile("../corpus/json5-tests/numbers/positive-octal.txt"), .expected = null },
    .{ .name = "numbers/positive-zero-float-leading-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-zero-float-leading-decimal-point.json5"), .expected = "0" },
    .{ .name = "numbers/positive-zero-float-trailing-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-zero-float-trailing-decimal-point.json5"), .expected = "0" },
    .{ .name = "numbers/positive-zero-float.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-zero-float.json5"), .expected = "0" },
    .{ .name = "numbers/positive-zero-hexadecimal.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-zero-hexadecimal.json5"), .expected = "0" },
    .{ .name = "numbers/positive-zero-integer.json5", .input = @embedFile("../corpus/json5-tests/numbers/positive-zero-integer.json5"), .expected = "0" },
    .{ .name = "numbers/positive-zero-octal.txt", .input = @embedFile("../corpus/json5-tests/numbers/positive-zero-octal.txt"), .expected = null },
    .{ .name = "numbers/zero-float-leading-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/zero-float-leading-decimal-point.json5"), .expected = "0" },
    .{ .name = "numbers/zero-float-trailing-decimal-point.json5", .input = @embedFile("../corpus/json5-tests/numbers/zero-float-trailing-decimal-point.json5"), .expected = "0" },
    .{ .name = "numbers/zero-float.json", .input = @embedFile("../corpus/json5-tests/numbers/zero-float.json"), .expected = "0" },
    .{ .name = "numbers/zero-hexadecimal.json5", .input = @embedFile("../corpus/json5-tests/numbers/zero-hexadecimal.json5"), .expected = "0" },
    .{ .name = "numbers/zero-integer-with-integer-exponent.json", .input = @embedFile("../corpus/json5-tests/numbers/zero-integer-with-integer-exponent.json"), .expected = "0" },
    .{ .name = "numbers/zero-integer.json", .input = @embedFile("../corpus/json5-tests/numbers/zero-integer.json"), .expected = "0" },
    .{ .name = "numbers/zero-octal.txt", .input = @embedFile("../corpus/json5-tests/numbers/zero-octal.txt"), .expected = null },
    .{ .name = "objects/duplicate-keys.json", .input = @embedFile("../corpus/json5-tests/objects/duplicate-keys.json"), .expected = "{\"a\":false}" },
    .{ .name = "objects/empty-object.json", .input = @embedFile("../corpus/json5-tests/objects/empty-object.json"), .expected = "{}" },
    .{ .name = "objects/illegal-unquoted-key-number.txt", .input = @embedFile("../corpus/json5-tests/objects/illegal-unquoted-key-number.txt"), .expected = null },
    .{ .name = "objects/illegal-unquoted-key-symbol.txt", .input = @embedFile("../corpus/json5-tests/objects/illegal-unquoted-key-symbol.txt"), .expected = null },
    .{ .name = "objects/leading-comma-object.txt", .input = @embedFile("../corpus/json5-tests/objects/leading-comma-object.txt"), .expected = null },
    .{ .name = "objects/lone-trailing-comma-object.txt", .input = @embedFile("../corpus/json5-tests/objects/lone-trailing-comma-object.txt"), .expected = null },
    .{ .name = "objects/no-comma-object.txt", .input = @embedFile("../corpus/json5-tests/objects/no-comma-object.txt"), .expected = null },
    .{ .name = "objects/reserved-unquoted-key.json5", .input = @embedFile("../corpus/json5-tests/objects/reserved-unquoted-key.json5"), .expected = "{\"while\":true}" },
    .{ .name = "objects/single-quoted-key.json5", .input = @embedFile("../corpus/json5-tests/objects/single-quoted-key.json5"), .expected = "{\"hello\":\"world\"}" },
    .{ .name = "objects/trailing-comma-object.json5", .input = @embedFile("../corpus/json5-tests/objects/trailing-comma-object.json5"), .expected = "{\"foo\":\"bar\"}" },
    .{ .name = "objects/unquoted-keys.json5", .input = @embedFile("../corpus/json5-tests/objects/unquoted-keys.json5"), .expected = "{\"hello\":\"world\",\"_\":\"underscore\",\"$\":\"dollar sign\",\"one1\":\"numerals\",\"_$_\":\"multiple symbols\",\"$_$hello123world_$_\":\"mixed\"}" },
    .{ .name = "strings/escaped-single-quoted-string.json5", .input = @embedFile("../corpus/json5-tests/strings/escaped-single-quoted-string.json5"), .expected = "\"I can't wait\"" },
    .{ .name = "strings/multi-line-string.json5", .input = @embedFile("../corpus/json5-tests/strings/multi-line-string.json5"), .expected = "\"hello world\"" },
    .{ .name = "strings/single-quoted-string.json5", .input = @embedFile("../corpus/json5-tests/strings/single-quoted-string.json5"), .expected = "\"hello world\"" },
    .{ .name = "strings/unescaped-multi-line-string.txt", .input = @embedFile("../corpus/json5-tests/strings/unescaped-multi-line-string.txt"), .expected = null },
    .{ .name = "todo/unicode-escaped-unquoted-key.json5", .input = @embedFile("../corpus/json5-tests/todo/unicode-escaped-unquoted-key.json5"), .expected = "{\"sig\xce\xa3ma\":\"the sum of all things\"}" },
    .{ .name = "todo/unicode-unquoted-key.json5", .input = @embedFile("../corpus/json5-tests/todo/unicode-unquoted-key.json5"), .expected = "{\"\xc3\xbcml\xc3\xa5\xc3\xbbt\":\"that's not really an \xc3\xbcmla\xc3\xbct, but this is\"}" },
};

test "json5-tests: every case read as the reference reads it, or refused as it is" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const options: json.ParseOptions = .{ .duplicates = .last };
    for (cases) |case| {
        const read = json.json5.parseLeaky(json.Value, a, case.input, options);
        const expected = case.expected orelse {
            if (read) |_| {
                std.debug.print("unexpected acceptance: {s}\n", .{case.name});
                return error.TestUnexpectedResult;
            } else |_| continue;
        };
        const value = read catch |err| {
            std.debug.print("unexpected refusal: {s}: {s}\n", .{ case.name, @errorName(err) });
            return err;
        };
        if (!try same(a, value, try json.json5.parseLeaky(json.Value, a, expected, .{}))) {
            std.debug.print("not the reference's value: {s}\n", .{case.name});
            return error.TestUnexpectedResult;
        }
        if (std.mem.endsWith(u8, case.name, ".json") and !std.mem.eql(u8, case.name, "comments/irregular-block-comment.json")) {
            if (!try same(a, value, try json.parseLeaky(json.Value, a, case.input, options))) {
                std.debug.print("not JSON's value: {s}\n", .{case.name});
                return error.TestUnexpectedResult;
            }
        }
    }
}

/// Whether two values are one: an object's members by key, in any order, as
/// JavaScript orders them its own way, and numbers by the double they are,
/// as JavaScript has no other, NaN as NaN and `-0` apart from `0`.
fn same(a: std.mem.Allocator, x: json.Value, y: json.Value) !bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    switch (x) {
        .null_value => return true,
        .boolean => |b| return b == y.boolean,
        .string => |s| return std.mem.eql(u8, s, y.string),
        .number => |n| {
            const p = try json.json5.parseLeaky(f64, a, n, .{});
            const q = try json.json5.parseLeaky(f64, a, y.number, .{});
            if (std.math.isNan(p)) return std.math.isNan(q);
            return p == q and std.math.signbit(p) == std.math.signbit(q);
        },
        .array => |items| {
            if (items.len != y.array.len) return false;
            for (items, y.array) |p, q| if (!try same(a, p, q)) return false;
            return true;
        },
        .object => |members| {
            if (members.len != y.object.len) return false;
            for (members) |m| {
                for (y.object) |n| {
                    if (std.mem.eql(u8, m.key, n.key)) {
                        if (!try same(a, m.value, n.value)) return false;
                        break;
                    }
                } else return false;
            }
            return true;
        },
    }
}
