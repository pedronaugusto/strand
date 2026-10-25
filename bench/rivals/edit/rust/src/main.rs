//! toml_edit 0.25.17 on the manifests strand's bench/edit.zig writes
//! (`strand-edit-bench --inputs DIR`, about 4 KiB and 256 KiB): opened, one value set and the text
//! taken, and the session of three edits (a value set, a key added, an entry
//! removed) and the text taken. Rows as strand's: median of 31 samples of at
//! least 100 ms each, in nanoseconds per document. toml_edit opens a document
//! once and edits its tree; strand reads the text again for each edit and
//! keeps it only if the result reads. Each session's text is written to
//! DIR/toml_edit-SIZE.toml for `strand-edit-bench --check DIR`.
use std::time::{Duration, Instant};
use toml_edit::{value, DocumentMut};

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

fn set(doc: &mut DocumentMut) {
    doc["package"]["version"] = value("0.2.0");
}
fn session(doc: &mut DocumentMut) {
    set(doc);
    doc["dependencies"]["zeta"] = value("2.0.0");
    doc["dependencies"].as_table_mut().unwrap().remove("old");
}

fn main() {
    let dir = std::env::args().nth(1).expect("the inputs directory");
    for size in ["4k", "256k"] {
        let text = std::fs::read_to_string(format!("{dir}/input-{size}.toml")).unwrap();
        let mut doc: DocumentMut = text.parse().unwrap();
        session(&mut doc);
        std::fs::write(format!("{dir}/toml_edit-{size}.toml"), doc.to_string()).unwrap();
        row(&format!("toml_edit.open.{size}"), || text.parse::<DocumentMut>().unwrap().len());
        row(&format!("toml_edit.set.{size}"), || {
            let mut doc: DocumentMut = text.parse().unwrap();
            set(&mut doc);
            doc.to_string().len()
        });
        row(&format!("toml_edit.session.{size}"), || {
            let mut doc: DocumentMut = text.parse().unwrap();
            session(&mut doc);
            doc.to_string().len()
        });
    }
}
