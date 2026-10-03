use serde::de::{Deserializer, IgnoredAny, MapAccess, Visitor};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use std::borrow::Cow;
use std::env;
use std::fmt;
use std::fs::File;
use std::hint::black_box;
use std::io::{BufRead, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::time::Instant;

#[derive(Serialize, Deserialize, Clone)]
struct Meta { region: String, score: u64 }
#[derive(Serialize, Deserialize, Clone)]
struct Record { id: u64, name: String, count: u64, meta: Meta, tags: Vec<String>, message: String }

/// The record as strand and std.json hand it back: strings borrowed from the
/// line when they need no unescaping, copied when they do.
#[derive(Deserialize)]
#[allow(dead_code)]
struct MetaB<'a> { #[serde(borrow)] region: Cow<'a, str>, score: u64 }
#[derive(Deserialize)]
#[allow(dead_code)]
struct RecordB<'a> {
    id: u64,
    #[serde(borrow)] name: Cow<'a, str>,
    count: u64,
    #[serde(borrow)] meta: MetaB<'a>,
    #[serde(borrow)] tags: Vec<Cow<'a, str>>,
    #[serde(borrow)] message: Cow<'a, str>,
}

fn sample() -> Record { Record {
    id: 123456, name: "user-3456".into(), count: 987654,
    meta: Meta { region: "eu".into(), score: 73 },
    tags: vec!["jsonl".into(), "benchmark".into(), "g42".into()],
    message: "abcdefghij".repeat(25) + "abcdef",
} }
const SIDE: &str = "serde-json";
fn emit(work: &str, metric: &str, value: f64, unit: &str) { println!("{SIDE}\t{work}\t{metric}\t{value:.6}\t{unit}"); }
fn check(work: &str, metric: &str, value: u64) { println!("{SIDE}\t{work}\t{metric}\t{value}\tchecksum"); }
fn rate(work: &str, items: u64, s: f64) { emit(work, "items", items.max(1) as f64 / s, "items/s"); emit(work, "per_item", s * 1e9 / items.max(1) as f64, "ns"); }
fn mb(work: &str, bytes: u64, s: f64) { emit(work, "bytes", bytes as f64 / s / 1e6, "MB/s"); }

fn smoke() -> bool { env::var("BENCH_SMOKE").as_deref() == Ok("1") }
fn count(n: usize) -> usize { if smoke() { 1 } else { n } }
fn size(path: &str) -> u64 { std::fs::metadata(path).unwrap().len() }

/// Each line of `path` without its terminator, framed with `read_until` into
/// one reused buffer (no per-line allocation, no UTF-8 pass over the frame).
fn each_line(path: &str, mut body: impl FnMut(&[u8])) {
    let mut r = BufReader::with_capacity(1 << 20, File::open(path).unwrap());
    let mut line = Vec::with_capacity(4096);
    loop {
        line.clear();
        if r.read_until(b'\n', &mut line).unwrap() == 0 { break }
        let end = if line.last() == Some(&b'\n') { line.len() - 1 } else { line.len() };
        body(&line[..end]);
    }
}
fn lines_of(bytes: &[u8]) -> Vec<&[u8]> { bytes.split(|b| *b == b'\n').filter(|l| !l.is_empty()).collect() }

fn typed_read(path: &str) {
    let mut lines = 0u64; let mut sum = 0u64;
    let start = BenchmarkInstant::now();
    for _ in 0..count(2) { each_line(path, |line| { let v: RecordB = serde_json::from_slice(line).unwrap(); sum = sum.wrapping_add(v.count); lines += 1; }); }
    let s = start.elapsed().as_secs_f64(); black_box(sum);
    emit("typed-read", "lines", lines as f64 / s, "lines/s"); emit("typed-read", "bytes", size(path) as f64 * count(2) as f64 / s / 1e6, "MB/s");
}
fn stream_read(path: &str) {
    let mut lines = 0u64; let mut sum = 0u64;
    let start = BenchmarkInstant::now();
    for _ in 0..count(2) { let reader = BufReader::with_capacity(1 << 20, File::open(path).unwrap()); let stream = serde_json::Deserializer::from_reader(reader).into_iter::<Record>(); for v in stream { let v = v.unwrap(); sum = sum.wrapping_add(v.count); lines += 1; } }
    let s = start.elapsed().as_secs_f64(); black_box(sum);
    emit("typed-read-stream", "lines", lines as f64 / s, "lines/s"); emit("typed-read-stream", "bytes", size(path) as f64 * count(2) as f64 / s / 1e6, "MB/s");
}
fn raw(path: &str) {
    let mut sum = 0usize; let start = BenchmarkInstant::now();
    for _ in 0..count(12) { each_line(path, |line| { sum = sum.wrapping_add(line.len() + 1); }); }
    let s = start.elapsed().as_secs_f64(); black_box(sum); emit("raw-frame", "bytes", size(path) as f64 * count(12) as f64 / s / 1e6, "MB/s");
}
fn write_records(path: &str, flush_each: bool) {
    let mut w = BufWriter::with_capacity(1 << 20, File::create(path).unwrap()); let v = sample(); let start = BenchmarkInstant::now();
    for _ in 0..count(1_000_000) { serde_json::to_writer(&mut w, &v).unwrap(); w.write_all(b"\n").unwrap(); if flush_each { w.flush().unwrap(); } }
    w.flush().unwrap(); let s = start.elapsed().as_secs_f64(); let bytes = size(path);
    emit(if flush_each { "typed-write-flush" } else { "typed-write" }, "bytes", bytes as f64 / s / 1e6, "MB/s");
}
/// The last `n` lines: read backwards a block at a time until `n + 1`
/// terminators are in hand, then each of those lines parsed from the bytes
/// already read, into owned values (what strand's `Tail.last` returns).
fn tail_back_once(path: &str) {
    let n = count(1000);
    let mut f = File::open(path).unwrap(); let len = f.metadata().unwrap().len();
    let mut pos = len; let mut block = vec![0u8; 64 * 1024]; let mut held: Vec<u8> = Vec::new(); let mut found = 0usize;
    while pos > 0 && found <= n {
        let take = usize::try_from(pos.min(block.len() as u64)).unwrap(); pos -= take as u64;
        f.seek(SeekFrom::Start(pos)).unwrap(); f.read_exact(&mut block[..take]).unwrap();
        found += block[..take].iter().filter(|b| **b == b'\n').count();
        let mut joined = block[..take].to_vec(); joined.extend_from_slice(&held); held = joined;
    }
    let mut lines: Vec<&[u8]> = lines_of(&held);
    if pos > 0 { lines.remove(0); }
    let tail = &lines[lines.len() - n..];
    let mut values = Vec::with_capacity(n); let mut sum = 0u64;
    for line in tail { let v: Record = serde_json::from_slice(line).unwrap(); sum = sum.wrapping_add(v.count); values.push(v); }
    assert_eq!(values.len(), n); black_box((sum, values));
}
fn tail_back(path: &str) {
    let start = BenchmarkInstant::now(); for _ in 0..count(500) { tail_back_once(path); }
    println!("rust-backwards\ttail-1000\tlatency\t{:.6}\tms", start.elapsed().as_secs_f64() * 1000.0 / count(500) as f64);
}

/// Owned values (every string copied), held 1024 at a time.
fn keep(path: &str) {
    let mut lines = 0u64; let mut sum = 0u64; let mut held: Vec<Record> = Vec::with_capacity(1024);
    let start = BenchmarkInstant::now();
    for _ in 0..count(2) { each_line(path, |line| {
        let v: Record = serde_json::from_slice(line).unwrap();
        sum += v.count + v.message.len() as u64 + v.tags.len() as u64 + v.meta.region.len() as u64; lines += 1;
        held.push(v); if held.len() == 1024 { held.clear(); }
    }); }
    let s = start.elapsed().as_secs_f64(); black_box(&held);
    rate("keep", lines, s); mb("keep", size(path) * count(2) as u64, s); check("keep", "lines", lines); check("keep", "sum", sum);
}
/// `Clone` of an owned record and its drop: the deep copy alone.
fn copy(path: &str) {
    let mut values: Vec<Record> = Vec::new();
    each_line(path, |line| { if values.len() < 100_000 { values.push(serde_json::from_slice(line).unwrap()); } });
    let rounds = count(10); let mut sum = 0u64;
    let start = BenchmarkInstant::now();
    for _ in 0..rounds { for v in &values { let c = black_box(v.clone()); sum += c.count + c.message.len() as u64 + c.tags.len() as u64 + c.meta.region.len() as u64; drop(c); } }
    let s = start.elapsed().as_secs_f64();
    rate("copy", (values.len() * rounds) as u64, s); check("copy", "sum", sum);
}
fn skip(path: &str) {
    let (mut lines, mut skipped, mut sum) = (0u64, 0u64, 0u64);
    let start = BenchmarkInstant::now();
    for _ in 0..count(2) { each_line(path, |line| match serde_json::from_slice::<RecordB>(line) { Ok(v) => { sum += v.count; lines += 1; } Err(_) => skipped += 1 }); }
    let s = start.elapsed().as_secs_f64();
    rate("skip-malformed", lines + skipped, s); mb("skip-malformed", size(path) * count(2) as u64, s);
    check("skip-malformed", "lines", lines); check("skip-malformed", "skipped", skipped); check("skip-malformed", "sum", sum);
}
/// Records laid over several lines: serde's stream deserializer over the
/// whole file read into memory (it frames by parsing, so needs no join).
fn pretty_read(path: &str) {
    let (mut lines, mut sum) = (0u64, 0u64);
    let start = BenchmarkInstant::now();
    let bytes = std::fs::read(path).unwrap();
    for v in serde_json::Deserializer::from_slice(&bytes).into_iter::<RecordB>() { let v = v.unwrap(); sum += v.count; lines += 1; }
    let s = start.elapsed().as_secs_f64();
    rate("pretty-read", lines, s); mb("pretty-read", size(path), s); check("pretty-read", "lines", lines); check("pretty-read", "sum", sum);
}
fn write_pretty(path: &str) {
    let n = count(200_000);
    let mut w = BufWriter::with_capacity(1 << 20, File::create(path).unwrap()); let v = sample(); let start = BenchmarkInstant::now();
    for _ in 0..n { serde_json::to_writer_pretty(&mut w, &v).unwrap(); w.write_all(b"\n").unwrap(); }
    w.flush().unwrap(); let s = start.elapsed().as_secs_f64();
    rate("write-pretty", n as u64, s); mb("write-pretty", size(path), s);
}
/// The record serialized, its closing brace taken off, `c` (the length so
/// far) appended, closed.
fn object_open(path: &str) {
    let n = count(1_000_000);
    let mut w = BufWriter::with_capacity(1 << 20, File::create(path).unwrap()); let v = sample(); let mut record = Vec::with_capacity(4096);
    let start = BenchmarkInstant::now();
    for _ in 0..n {
        record.clear(); serde_json::to_writer(&mut record, &v).unwrap(); record.pop();
        let so_far = record.len(); write!(record, ",\"c\":{so_far}}}\n").unwrap(); w.write_all(&record).unwrap();
    }
    w.flush().unwrap(); let s = start.elapsed().as_secs_f64();
    rate("object-open", n as u64, s); mb("object-open", size(path), s);
}

/// serde has no peek: the visitor takes the first key, then the rest of the
/// object is scanned as `IgnoredAny` to finish the value.
struct FirstKey<'a>(Option<&'a str>);
impl<'de: 'a, 'a> Deserialize<'de> for FirstKey<'a> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct V;
        impl<'de> Visitor<'de> for V {
            type Value = FirstKey<'de>;
            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result { f.write_str("an object") }
            fn visit_map<M: MapAccess<'de>>(self, mut map: M) -> Result<Self::Value, M::Error> {
                let key: Option<&'de str> = map.next_key()?;
                if key.is_some() { map.next_value::<IgnoredAny>()?; while map.next_entry::<IgnoredAny, IgnoredAny>()?.is_some() {} }
                Ok(FirstKey(key))
            }
        }
        d.deserialize_map(V)
    }
}
fn route(path: &str) {
    let bytes = std::fs::read(path).unwrap(); let lines = lines_of(&bytes);
    let rounds = count(10); let mut hits = 0u64;
    let start = BenchmarkInstant::now();
    for _ in 0..rounds { for line in &lines { if let Ok(FirstKey(Some("id"))) = serde_json::from_slice::<FirstKey>(line) { hits += 1; } } }
    let s = start.elapsed().as_secs_f64();
    rate("route-kind", (lines.len() * rounds) as u64, s); check("route-kind", "hits", hits);
}
#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum Tagged<'a> {
    Open { #[allow(dead_code)] at: u64, #[serde(borrow)] #[allow(dead_code)] who: Cow<'a, str> },
    Retry { #[allow(dead_code)] at: u64, #[allow(dead_code)] attempt: u64 },
    Close { #[allow(dead_code)] at: u64, #[allow(dead_code)] code: i64 },
}
/// serde's externally tagged enum is the routing idiom; it parses the arm.
fn route_tag(path: &str) {
    let bytes = std::fs::read(path).unwrap(); let lines = lines_of(&bytes);
    let rounds = count(10); let mut counts = [0u64; 3];
    let start = BenchmarkInstant::now();
    for _ in 0..rounds { for line in &lines { match serde_json::from_slice::<Tagged>(line) { Ok(Tagged::Open { .. }) => counts[0] += 1, Ok(Tagged::Retry { .. }) => counts[1] += 1, Ok(Tagged::Close { .. }) => counts[2] += 1, Err(_) => {} } } }
    let s = start.elapsed().as_secs_f64();
    rate("route-tag", (lines.len() * rounds) as u64, s); check("route-tag", "open", counts[0]); check("route-tag", "retry", counts[1]); check("route-tag", "close", counts[2]);
}
#[derive(Deserialize)]
struct IdOnly { id: u64 }
fn leading(path: &str) {
    let bytes = std::fs::read(path).unwrap(); let lines = lines_of(&bytes);
    let rounds = count(4); let mut sum = 0u64;
    let start = BenchmarkInstant::now();
    for _ in 0..rounds { for line in &lines { sum += serde_json::from_slice::<IdOnly>(line).unwrap().id; } }
    let s = start.elapsed().as_secs_f64();
    rate("leading-ints", (lines.len() * rounds) as u64, s); check("leading-ints", "sum", sum);
}
fn control(path: &str) {
    let bytes = std::fs::read(path).unwrap(); let lines = lines_of(&bytes);
    let rounds = count(10); let (mut hits, mut scanned) = (0u64, 0u64);
    let start = BenchmarkInstant::now();
    for _ in 0..rounds { for line in &lines { match line.iter().position(|b| *b < 0x20 && *b != b'\t') { Some(at) => { hits += 1; scanned += at as u64; } None => scanned += line.len() as u64 } } }
    let s = start.elapsed().as_secs_f64();
    mb("control-scan", scanned, s); rate("control-scan", (lines.len() * rounds) as u64, s); check("control-scan", "hits", hits); check("control-scan", "scanned", scanned);
}
fn split(path: &str) {
    let bytes = std::fs::read(path).unwrap(); let rounds = count(10); let (mut lines, mut total) = (0u64, 0u64);
    // str::lines searches with memchr (slice::split tests every byte through
    // the closure); the UTF-8 check that makes the &str is outside the clock.
    let text = std::str::from_utf8(&bytes).unwrap();
    let start = BenchmarkInstant::now();
    for _ in 0..rounds { for line in text.lines() { lines += 1; total += line.len() as u64; } }
    let s = start.elapsed().as_secs_f64();
    mb("split-lines", bytes.len() as u64 * rounds as u64, s); check("split-lines", "lines", lines); check("split-lines", "bytes", total);
}
fn starts(path: &str) -> Vec<u64> {
    let bytes = std::fs::read(path).unwrap(); let mut out = Vec::new(); let mut at = 0usize; let mut n = 0usize;
    while at < bytes.len() { if n % 100 == 0 { out.push(at as u64); } at += bytes[at..].iter().position(|b| *b == b'\n').map_or(bytes.len() - at, |i| i + 1); n += 1; }
    out
}
fn resume(path: &str) {
    let mut offsets = starts(path); offsets.reverse();
    let mut r = BufReader::with_capacity(64 * 1024, File::open(path).unwrap()); let mut line = Vec::with_capacity(4096); let mut sum = 0u64;
    let start = BenchmarkInstant::now();
    for off in &offsets { r.seek(SeekFrom::Start(*off)).unwrap(); line.clear(); r.read_until(b'\n', &mut line).unwrap(); line.pop(); sum += serde_json::from_slice::<RecordB>(&line).unwrap().id; }
    let s = start.elapsed().as_secs_f64();
    rate("resume", offsets.len() as u64, s); check("resume", "sum", sum);
}
/// A type with its own `Deserialize` that delegates to the record's.
struct Hooked<'a>(RecordB<'a>);
impl<'de: 'a, 'a> Deserialize<'de> for Hooked<'a> {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> { RecordB::deserialize(d).map(Hooked) }
}
fn hook(path: &str) {
    let (mut lines, mut sum) = (0u64, 0u64);
    let start = BenchmarkInstant::now();
    for _ in 0..count(2) { each_line(path, |line| { let v: Hooked = serde_json::from_slice(line).unwrap(); sum += v.0.count; lines += 1; }); }
    let s = start.elapsed().as_secs_f64();
    rate("custom-hook", lines, s); mb("custom-hook", size(path) * count(2) as u64, s); check("custom-hook", "lines", lines); check("custom-hook", "sum", sum);
}
#[derive(Deserialize)]
struct Carried<'a> { #[serde(borrow)] #[allow(dead_code)] kind: Cow<'a, str>, at: u64, #[serde(borrow)] data: &'a RawValue }
#[derive(Serialize, Deserialize)]
struct Data<'a> { #[serde(borrow)] who: Cow<'a, str>, beat: u64, #[serde(borrow)] tags: Vec<Cow<'a, str>> }
fn carried(path: &str) {
    let (mut lines, mut at, mut data_bytes) = (0u64, 0u64, 0u64);
    let start = BenchmarkInstant::now();
    each_line(path, |line| { let v: Carried = serde_json::from_slice(line).unwrap(); at += v.at; data_bytes += v.data.get().len() as u64; lines += 1; });
    let s = start.elapsed().as_secs_f64();
    rate("carried", lines, s); mb("carried", size(path), s); check("carried", "at", at); check("carried", "data_bytes", data_bytes);

    let bytes = std::fs::read(path).unwrap(); let mut held: Vec<&[u8]> = Vec::new();
    for line in lines_of(&bytes) { let from = line.windows(7).position(|w| w == b"\"data\":").unwrap() + 7; held.push(&line[from..line.len() - 1]); if held.len() == 200_000 { break } }
    let mut beats = 0u64;
    let start = BenchmarkInstant::now();
    for raw in &held { let v: Data = serde_json::from_slice(raw).unwrap(); beats += v.beat + v.tags.len() as u64; }
    let s = start.elapsed().as_secs_f64();
    rate("raw-parse", held.len() as u64, s); check("raw-parse", "sum", beats);

    let mut encoded = 0u64;
    let start = BenchmarkInstant::now();
    for i in 0..held.len() { let raw = serde_json::value::to_raw_value(&Data { who: Cow::Borrowed("ada"), beat: (i % 7) as u64, tags: vec![Cow::Borrowed("a"), Cow::Borrowed("b")] }).unwrap(); encoded += raw.get().len() as u64; }
    let s = start.elapsed().as_secs_f64();
    rate("raw-encode", held.len() as u64, s); check("raw-encode", "bytes", encoded);
}
/// The whole file backwards, 64 KiB at a time, each line handed over last
/// first: typed (borrowed, as strand's `prev`) and as bytes (`prevRaw`).
/// The partial line a block starts with is kept right after the space the
/// next block is read into, in one reused buffer. Rust's std has no public
/// `memrchr`, so the terminator search is `rposition`.
fn backward_pass(path: &str, mut body: impl FnMut(&[u8])) {
    const BLOCK: usize = 64 * 1024;
    let mut f = File::open(path).unwrap(); let mut pos = f.metadata().unwrap().len();
    let mut buf = vec![0u8; 2 * BLOCK]; let mut carry = 0usize; // the partial line: buf[BLOCK..BLOCK + carry]
    while pos > 0 {
        let take = usize::try_from(pos.min(BLOCK as u64)).unwrap(); pos -= take as u64;
        let from = BLOCK - take;
        f.seek(SeekFrom::Start(pos)).unwrap(); f.read_exact(&mut buf[from..BLOCK]).unwrap();
        let mut end = take + carry;
        {
            let joined = &buf[from..BLOCK + carry];
            while let Some(i) = joined[..end].iter().rposition(|b| *b == b'\n') {
                if i + 1 < end { body(&joined[i + 1..end]); }
                end = i;
            }
        }
        if BLOCK + end > buf.len() { buf.resize(BLOCK + end, 0); }
        buf.copy_within(from..from + end, BLOCK);
        carry = end;
    }
    if carry > 0 { body(&buf[BLOCK..BLOCK + carry]); }
}
fn backward(path: &str) {
    let (mut lines, mut sum) = (0u64, 0u64);
    let start = BenchmarkInstant::now();
    backward_pass(path, |line| { sum += serde_json::from_slice::<RecordB>(line).unwrap().count; lines += 1; });
    let s = start.elapsed().as_secs_f64();
    rate("backward", lines, s); mb("backward", size(path), s); check("backward", "lines", lines); check("backward", "sum", sum);
    let (mut lines, mut bytes) = (0u64, 0u64);
    let start = BenchmarkInstant::now();
    backward_pass(path, |line| { bytes += line.len() as u64; lines += 1; });
    let s = start.elapsed().as_secs_f64();
    rate("backward-raw", lines, s); mb("backward-raw", size(path), s); check("backward-raw", "lines", lines); check("backward-raw", "bytes", bytes);
}
fn file_id(path: &str) {
    use std::os::unix::fs::MetadataExt;
    let rounds = count(100_000); let f = File::open(path).unwrap(); let m = f.metadata().unwrap(); let first = (m.dev(), m.ino());
    let mut same = 0u64; let start = BenchmarkInstant::now();
    for _ in 0..rounds { let m = f.metadata().unwrap(); if (m.dev(), m.ino()) == first { same += 1; } }
    let s = start.elapsed().as_secs_f64(); rate("file-id", rounds as u64, s); check("file-id", "same", same);
    let mut same = 0u64; let start = BenchmarkInstant::now();
    for _ in 0..rounds { let m = std::fs::metadata(path).unwrap(); if (m.dev(), m.ino()) == first { same += 1; } }
    let s = start.elapsed().as_secs_f64(); rate("file-id-path", rounds as u64, s); check("file-id-path", "same", same);
}
/// `sync_data` and `sync_all`: on Apple targets both are `fcntl(F_FULLFSYNC)`
/// in Rust's std, the call strand makes there.
fn sync(dir: &str) {
    let rounds = count(100); let chunk = [b'x'; 128];
    for (work, all) in [("sync-data", false), ("sync-all", true)] {
        let mut f = File::create(format!("{dir}/rust-sync.dat")).unwrap();
        let start = BenchmarkInstant::now();
        for _ in 0..rounds { f.write_all(&chunk).unwrap(); if all { f.sync_all().unwrap() } else { f.sync_data().unwrap() } }
        rate(work, rounds as u64, start.elapsed().as_secs_f64());
    }
    let d = File::open(dir).unwrap(); let start = BenchmarkInstant::now();
    for _ in 0..rounds { d.sync_all().unwrap(); }
    rate("sync-dir", rounds as u64, start.elapsed().as_secs_f64());
    let mut w = BufWriter::with_capacity(64 * 1024, File::create(format!("{dir}/rust-writer-sync.jsonl")).unwrap()); let v = sample(); let mut records = 0u64;
    let start = BenchmarkInstant::now();
    for _ in 0..rounds { serde_json::to_writer(&mut w, &v).unwrap(); w.write_all(b"\n").unwrap(); w.flush().unwrap(); w.get_ref().sync_data().unwrap(); records += 1; }
    rate("writer-sync", rounds as u64, start.elapsed().as_secs_f64()); check("writer-sync", "records", records);
}
fn main() {
    let a: Vec<String> = env::args().collect(); if a.len() != 3 { panic!("usage: bench WORKLOAD PATH") }
    let p = &a[2];
    match a[1].as_str() {
        "read" => typed_read(p), "stream" => stream_read(p), "raw" => raw(p), "write" => write_records(p, false), "write-flush" => write_records(p, true), "tail" => tail_back(p),
        "keep" => keep(p), "copy" => copy(p), "skip" => skip(p), "pretty" => pretty_read(p), "write-pretty" => write_pretty(p), "object-open" => object_open(p),
        "route" => route(p), "route-tag" => route_tag(p), "leading" => leading(p), "control" => control(p), "split" => split(p), "resume" => resume(p),
        "hook" => hook(p), "carried" => carried(p), "backward" => backward(p), "file-id" => file_id(p), "sync" => sync(p),
        _ => panic!("bad workload"),
    }
}

// Runtime smoke mode never starts a performance clock.
struct BenchmarkInstant(Option<Instant>);
impl BenchmarkInstant {
    fn now() -> Self {
        Self(if std::env::var("BENCH_SMOKE").as_deref() == Ok("1") { None } else { Some(Instant::now()) })
    }
    fn elapsed(&self) -> std::time::Duration {
        self.0.map_or(std::time::Duration::from_nanos(1), |start| start.elapsed())
    }
}
