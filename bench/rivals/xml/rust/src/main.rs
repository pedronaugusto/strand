//! quick-xml 0.42.0 (with serde) on the documents strand's bench/xml.zig
//! writes (`strand-xml-bench --inputs DIR`): typed reads of an S3 listing,
//! its raw events, and a write. Rows as strand's: median of 31 samples of at
//! least 100 ms each, in nanoseconds per document. quick-xml's serde ignores
//! members a type does not name (strand refuses them by default) and its
//! raw reader checks no end tag against its start unless asked: policy
//! mismatches, labelled as such.
use quick_xml::events::Event;
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

#[derive(Deserialize, Serialize)]
#[allow(non_snake_case)]
struct Owner { ID: String, DisplayName: String }
#[derive(Deserialize, Serialize)]
#[allow(non_snake_case)]
struct Object { Key: String, LastModified: String, ETag: String, Size: u64, StorageClass: String, Owner: Owner }
#[derive(Deserialize, Serialize)]
#[allow(non_snake_case)]
#[serde(rename = "ListBucketResult")]
struct Listing {
    #[serde(rename = "@xmlns")] xmlns: String,
    Name: String, Prefix: String, KeyCount: u32, MaxKeys: u32, IsTruncated: bool,
    #[serde(default)] Contents: Vec<Object>,
}

fn row(name: &str, mut f: impl FnMut() -> usize) {
    let mut batch = 1u64;
    loop {
        let start = Instant::now();
        for _ in 0..batch { std::hint::black_box(f()); }
        if start.elapsed() >= Duration::from_millis(100) { break; }
        batch *= 2;
    }
    let mut samples: Vec<f64> = (0..31).map(|_| {
        let start = Instant::now();
        for _ in 0..batch { std::hint::black_box(f()); }
        start.elapsed().as_nanos() as f64 / batch as f64
    }).collect();
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("{{\"row\":\"{}\",\"median\":{:.0},\"best\":{:.0}}}", name, samples[15], samples[0]);
}

fn main() {
    let dir = std::env::args().nth(1).expect("the inputs directory");
    let small = std::fs::read_to_string(format!("{dir}/s3-small.xml")).unwrap();
    let large = std::fs::read_to_string(format!("{dir}/s3-large.xml")).unwrap();
    row("quick-xml.typed.s3-10", || quick_xml::de::from_str::<Listing>(&small).unwrap().Contents.len());
    row("quick-xml.typed.s3-1000", || quick_xml::de::from_str::<Listing>(&large).unwrap().Contents.len());
    row("quick-xml.scan.s3-1000", || {
        let mut reader = quick_xml::Reader::from_str(&large);
        let mut n = 0usize;
        loop { match reader.read_event().unwrap() { Event::Eof => break, _ => n += 1 } }
        n
    });
    row("quick-xml.scan-checked.s3-1000", || {
        let mut reader = quick_xml::Reader::from_str(&large);
        reader.config_mut().check_end_names = true;
        let mut n = 0usize;
        loop { match reader.read_event().unwrap() { Event::Eof => break, _ => n += 1 } }
        n
    });
    let value: Listing = quick_xml::de::from_str(&large).unwrap();
    // What quick-xml writes, for strand to read (`strand-xml-bench --check`).
    {
        let mut out = String::new();
        let mut ser = quick_xml::se::Serializer::new(&mut out);
        ser.indent(' ', 2);
        value.serialize(ser).unwrap();
        std::fs::write(format!("{dir}/quick-xml-written.xml"), out).unwrap();
    }
    row("quick-xml.write.s3-1000", || {
        let mut out = String::with_capacity(large.len() * 2);
        let mut ser = quick_xml::se::Serializer::new(&mut out);
        ser.indent(' ', 2);
        value.serialize(ser).unwrap();
        out.len()
    });
}
