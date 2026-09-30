use serde::{Deserialize, Serialize};
use std::env;
use std::fs::File;
use std::hint::black_box;
use std::io::{BufRead, BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::time::Instant;

#[derive(Serialize, Deserialize)]
struct Meta { region: String, score: u64 }
#[derive(Serialize, Deserialize)]
struct Record { id: u64, name: String, count: u64, meta: Meta, tags: Vec<String>, message: String }

fn sample() -> Record { Record {
    id: 123456, name: "user-3456".into(), count: 987654,
    meta: Meta { region: "eu".into(), score: 73 },
    tags: vec!["jsonl".into(), "benchmark".into(), "g42".into()],
    message: "abcdefghij".repeat(25) + "abcdef",
} }
fn emit(work: &str, metric: &str, value: f64, unit: &str) { println!("serde-json\t{work}\t{metric}\t{value:.6}\t{unit}"); }

fn smoke() -> bool { env::var("BENCH_SMOKE").as_deref() == Ok("1") }
fn count(n: usize) -> usize { if smoke() { 1 } else { n } }
fn typed_read(path: &str) {
    let size = std::fs::metadata(path).unwrap().len();
    let mut lines = 0u64; let mut sum = 0u64;
    let start = Instant::now();
    for _ in 0..count(2) { let reader = BufReader::with_capacity(1 << 20, File::open(path).unwrap()); for line in reader.lines() { let v: Record = serde_json::from_str(&line.unwrap()).unwrap(); sum = sum.wrapping_add(v.count); lines += 1; } }
    let s = start.elapsed().as_secs_f64(); black_box(sum);
    emit("typed-read", "lines", lines as f64 / s, "lines/s"); emit("typed-read", "bytes", size as f64 * count(2) as f64 / s / 1e6, "MB/s");
}
fn stream_read(path: &str) {
    let size = std::fs::metadata(path).unwrap().len();
    let mut lines = 0u64; let mut sum = 0u64;
    let start = Instant::now();
    for _ in 0..count(2) { let reader = BufReader::with_capacity(1 << 20, File::open(path).unwrap()); let stream = serde_json::Deserializer::from_reader(reader).into_iter::<Record>(); for v in stream { let v = v.unwrap(); sum = sum.wrapping_add(v.count); lines += 1; } }
    let s = start.elapsed().as_secs_f64(); black_box(sum);
    emit("typed-read-stream", "lines", lines as f64 / s, "lines/s"); emit("typed-read-stream", "bytes", size as f64 * count(2) as f64 / s / 1e6, "MB/s");
}
fn raw(path: &str) {
    let size = std::fs::metadata(path).unwrap().len(); let mut sum = 0usize; let start = Instant::now();
    for _ in 0..count(12) { let mut line = String::new(); let mut r = BufReader::with_capacity(1 << 20, File::open(path).unwrap()); loop { line.clear(); let n = r.read_line(&mut line).unwrap(); if n == 0 { break } sum = sum.wrapping_add(n); } }
    let s = start.elapsed().as_secs_f64(); black_box(sum); emit("raw-frame", "bytes", size as f64 * count(12) as f64 / s / 1e6, "MB/s");
}
fn write_records(path: &str, flush_each: bool) {
    let mut w = BufWriter::with_capacity(1 << 20, File::create(path).unwrap()); let v = sample(); let start = Instant::now();
    for _ in 0..count(1_000_000) { serde_json::to_writer(&mut w, &v).unwrap(); w.write_all(b"\n").unwrap(); if flush_each { w.flush().unwrap(); } }
    w.flush().unwrap(); let s = start.elapsed().as_secs_f64(); let bytes = std::fs::metadata(path).unwrap().len();
    emit(if flush_each { "typed-write-flush" } else { "typed-write" }, "bytes", bytes as f64 / s / 1e6, "MB/s");
}
fn tail_back_once(path: &str) {
    let mut f = File::open(path).unwrap(); let len = f.metadata().unwrap().len();
    let mut pos = len; let mut found = 0usize; let mut buf = vec![0u8; 64 * 1024]; let mut begin = 0u64;
    'outer: while pos > 0 && found <= count(1000) {
        let take = usize::try_from(pos.min(buf.len() as u64)).unwrap(); pos -= take as u64;
        f.seek(SeekFrom::Start(pos)).unwrap(); f.read_exact(&mut buf[..take]).unwrap();
        for i in (0..take).rev() { if buf[i] == b'\n' { found += 1; if found > count(1000) { begin = pos + i as u64 + 1; break 'outer; } } }
    }
    f.seek(SeekFrom::Start(begin)).unwrap(); let reader = BufReader::with_capacity(64 * 1024, f);
    let mut values = Vec::with_capacity(1000); let mut sum = 0u64;
    for line in reader.lines().take(count(1000)) { let v: Record = serde_json::from_str(&line.unwrap()).unwrap(); sum = sum.wrapping_add(v.count); values.push(v); }
    assert_eq!(values.len(), count(1000)); black_box((sum, values));
}
fn tail_back(path: &str) {
    let start = Instant::now(); for _ in 0..count(500) { tail_back_once(path); }
    println!("rust-backwards\ttail-1000\tlatency\t{:.6}\tms", start.elapsed().as_secs_f64() * 1000.0 / count(500) as f64);
}
fn main() {
    let a: Vec<String> = env::args().collect(); if a.len() != 3 { panic!("usage: bench WORKLOAD PATH") }
    match a[1].as_str() { "read" => typed_read(&a[2]), "stream" => stream_read(&a[2]), "raw" => raw(&a[2]), "write" => write_records(&a[2], false), "write-flush" => write_records(&a[2], true), "tail" => tail_back(&a[2]), _ => panic!("bad workload") }
}
