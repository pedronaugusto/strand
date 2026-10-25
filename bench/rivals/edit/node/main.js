// jsonc-parser 3.3.1 (VS Code's) on the settings files strand's
// bench/edit.zig writes (`strand-edit-bench --inputs DIR`, about 4 KiB and
// 256 KiB): opened (its
// tree), one value set and the text taken, and the session of three edits (a
// value set, a key added, an entry removed) and the text taken, each edit
// computed by `modify` and applied by `applyEdits`. Rows as strand's: median
// of 31 samples of at least 100 ms each, in nanoseconds per document.
// jsonc-parser does not read its result back. Each session's text is written
// to DIR/jsonc-parser-SIZE.jsonc for `strand-edit-bench --check DIR`.
import { readFileSync, writeFileSync } from "node:fs";
import { applyEdits, modify, parseTree } from "jsonc-parser";

function row(name, f) {
  let batch = 1;
  for (;;) {
    const start = process.hrtime.bigint();
    for (let i = 0; i < batch; i++) f();
    if (process.hrtime.bigint() - start >= 100_000_000n) break;
    batch *= 2;
  }
  const samples = [];
  for (let s = 0; s < 31; s++) {
    const start = process.hrtime.bigint();
    for (let i = 0; i < batch; i++) f();
    samples.push(Number(process.hrtime.bigint() - start) / batch);
  }
  samples.sort((a, b) => a - b);
  console.log(JSON.stringify({ row: name, median: Math.round(samples[15]), best: Math.round(samples[0]) }));
}

const options = { formattingOptions: { insertSpaces: true, tabSize: 2 } };
const edit = (text, path, value) => applyEdits(text, modify(text, path, value, options));
const setOne = (text) => edit(text, ["items", "mid", "level"], 5);
const session = (text) => edit(edit(setOne(text), ["items", "mid", "note"], "new"), ["items", "old"], undefined);

const dir = process.argv[2];
for (const size of ["4k", "256k"]) {
  const text = readFileSync(`${dir}/input-${size}.jsonc`, "utf8");
  writeFileSync(`${dir}/jsonc-parser-${size}.jsonc`, session(text));
  row(`jsonc-parser.open.${size}`, () => parseTree(text).children.length);
  row(`jsonc-parser.set.${size}`, () => setOne(text).length);
  row(`jsonc-parser.session.${size}`, () => session(text).length);
}
