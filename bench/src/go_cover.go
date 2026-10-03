package main

// The rest of the public operations with encoding/json (v1) and
// encoding/json/v2 (standard library since Go 1.25). Rows and checksums are
// named as strand's are, so the harness compares them.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"encoding/json/jsontext"
	jsonv2 "encoding/json/v2"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"time"
)

const sideV1 = "go-encoding-json"
const sideV2 = "go-encoding-json-v2"

func emitAs(side, work, metric string, value float64, unit string) {
	fmt.Printf("%s\t%s\t%s\t%.6f\t%s\n", side, work, metric, value, unit)
}
func checkAs(side, work, metric string, value uint64) {
	fmt.Printf("%s\t%s\t%s\t%d\tchecksum\n", side, work, metric, value)
}
func rateAs(side, work string, items uint64, elapsed time.Duration) {
	if items == 0 {
		items = 1
	}
	s := elapsed.Seconds()
	emitAs(side, work, "items", float64(items)/s, "items/s")
	emitAs(side, work, "per_item", s*1e9/float64(items), "ns")
}
func mbAs(side, work string, bytes uint64, elapsed time.Duration) {
	emitAs(side, work, "bytes", float64(bytes)/elapsed.Seconds()/1e6, "MB/s")
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func fileSize(path string) uint64 {
	st, err := os.Stat(path)
	must(err)
	return uint64(st.Size())
}

// eachLine frames with bufio.Scanner, whose line is a view of its buffer.
func eachLine(path string, body func([]byte)) {
	f, err := os.Open(path)
	must(err)
	defer f.Close()
	s := bufio.NewScanner(f)
	s.Buffer(make([]byte, 1<<20), 2<<20)
	for s.Scan() {
		body(s.Bytes())
	}
	must(s.Err())
}
func linesOf(path string) [][]byte {
	b, err := os.ReadFile(path)
	must(err)
	var out [][]byte
	for _, l := range bytes.Split(b, []byte{'\n'}) {
		if len(l) != 0 {
			out = append(out, l)
		}
	}
	return out
}

type decodeFn func([]byte, any) error
type encodeFn func(any) ([]byte, error)

func v1Decode(b []byte, v any) error { return json.Unmarshal(b, v) }
func v2Decode(b []byte, v any) error { return jsonv2.Unmarshal(b, v) }
func v1Encode(v any) ([]byte, error) { return json.Marshal(v) }
func v2Encode(v any) ([]byte, error) { return jsonv2.Marshal(v) }

func readTyped(side string, decode decodeFn, path string) {
	var n, sum uint64
	start := benchmarkNow()
	for i := 0; i < count(2); i++ {
		eachLine(path, func(line []byte) {
			var v Record
			must(decode(line, &v))
			sum += v.Count
			n++
		})
	}
	elapsed := benchmarkSince(start)
	emitAs(side, "typed-read", "lines", float64(n)/elapsed.Seconds(), "lines/s")
	emitAs(side, "typed-read", "bytes", float64(fileSize(path))*float64(count(2))/elapsed.Seconds()/1e6, "MB/s")
}

func writeV2(path string, each bool) {
	f, err := os.Create(path)
	must(err)
	defer f.Close()
	w := bufio.NewWriterSize(f, 1<<20)
	v := sample()
	start := benchmarkNow()
	for i := 0; i < count(1_000_000); i++ {
		must(jsonv2.MarshalWrite(w, &v))
		must(w.WriteByte('\n'))
		if each {
			must(w.Flush())
		}
	}
	must(w.Flush())
	elapsed := benchmarkSince(start)
	work := "typed-write"
	if each {
		work = "typed-write-flush"
	}
	emitAs(sideV2, work, "bytes", float64(fileSize(path))/elapsed.Seconds()/1e6, "MB/s")
}

// keep: Go always copies strings out of the input, so a decode is a keep.
func keep(side string, decode decodeFn, path string) {
	var lines, sum uint64
	held := make([]Record, 0, 1024)
	start := benchmarkNow()
	for i := 0; i < count(2); i++ {
		eachLine(path, func(line []byte) {
			var v Record
			must(decode(line, &v))
			sum += v.Count + uint64(len(v.Message)) + uint64(len(v.Tags)) + uint64(len(v.Meta.Region))
			lines++
			held = append(held, v)
			if len(held) == 1024 {
				held = held[:0]
			}
		})
	}
	elapsed := benchmarkSince(start)
	rateAs(side, "keep", lines, elapsed)
	mbAs(side, "keep", fileSize(path)*uint64(count(2)), elapsed)
	checkAs(side, "keep", "lines", lines)
	checkAs(side, "keep", "sum", sum)
}

func skip(side string, decode decodeFn, path string) {
	var lines, skipped, sum uint64
	start := benchmarkNow()
	for i := 0; i < count(2); i++ {
		eachLine(path, func(line []byte) {
			var v Record
			if decode(line, &v) != nil {
				skipped++
				return
			}
			sum += v.Count
			lines++
		})
	}
	elapsed := benchmarkSince(start)
	rateAs(side, "skip-malformed", lines+skipped, elapsed)
	mbAs(side, "skip-malformed", fileSize(path)*uint64(count(2)), elapsed)
	checkAs(side, "skip-malformed", "lines", lines)
	checkAs(side, "skip-malformed", "skipped", skipped)
	checkAs(side, "skip-malformed", "sum", sum)
}

// prettyRead: the decoders frame by parsing, so records over several lines
// need no join.
func prettyRead(side string, path string) {
	var lines, sum uint64
	start := benchmarkNow()
	f, err := os.Open(path)
	must(err)
	r := bufio.NewReaderSize(f, 1<<20)
	if side == sideV1 {
		dec := json.NewDecoder(r)
		for {
			var v Record
			if err := dec.Decode(&v); err == io.EOF {
				break
			} else {
				must(err)
			}
			sum += v.Count
			lines++
		}
	} else {
		dec := jsontext.NewDecoder(r)
		for {
			var v Record
			if err := jsonv2.UnmarshalDecode(dec, &v); err == io.EOF {
				break
			} else {
				must(err)
			}
			sum += v.Count
			lines++
		}
	}
	f.Close()
	elapsed := benchmarkSince(start)
	rateAs(side, "pretty-read", lines, elapsed)
	mbAs(side, "pretty-read", fileSize(path), elapsed)
	checkAs(side, "pretty-read", "lines", lines)
	checkAs(side, "pretty-read", "sum", sum)
}

func writePretty(side string, path string) {
	n := count(200_000)
	f, err := os.Create(path)
	must(err)
	defer f.Close()
	w := bufio.NewWriterSize(f, 1<<20)
	v := sample()
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	start := benchmarkNow()
	for i := 0; i < n; i++ {
		if side == sideV1 {
			must(enc.Encode(&v))
		} else {
			must(jsonv2.MarshalWrite(w, &v, jsontext.WithIndent("  ")))
			must(w.WriteByte('\n'))
		}
	}
	must(w.Flush())
	elapsed := benchmarkSince(start)
	rateAs(side, "write-pretty", uint64(n), elapsed)
	mbAs(side, "write-pretty", fileSize(path), elapsed)
}

// objectOpen: marshal, take the closing brace off, append `c`, close.
func objectOpen(side string, encode encodeFn, path string) {
	n := count(1_000_000)
	f, err := os.Create(path)
	must(err)
	defer f.Close()
	w := bufio.NewWriterSize(f, 1<<20)
	v := sample()
	start := benchmarkNow()
	for i := 0; i < n; i++ {
		b, err := encode(&v)
		must(err)
		b = b[:len(b)-1]
		so := len(b)
		b = append(b, `,"c":`...)
		b = fmt.Appendf(b, "%d}\n", so)
		_, err = w.Write(b)
		must(err)
	}
	must(w.Flush())
	elapsed := benchmarkSince(start)
	rateAs(side, "object-open", uint64(n), elapsed)
	mbAs(side, "object-open", fileSize(path), elapsed)
}

// firstKey peeks with the streaming token APIs: v1 Decoder.Token (a new
// decoder per line; it has no reset) and v2 jsontext.Decoder (reset per line).
type keyPeek func([]byte) (string, bool)

func peekV1() keyPeek {
	return func(line []byte) (string, bool) {
		dec := json.NewDecoder(bytes.NewReader(line))
		if t, err := dec.Token(); err != nil || t != json.Delim('{') {
			return "", false
		}
		t, err := dec.Token()
		if err != nil {
			return "", false
		}
		s, ok := t.(string)
		return s, ok
	}
}
func peekV2() keyPeek {
	dec := jsontext.NewDecoder(bytes.NewReader(nil))
	r := bytes.NewReader(nil)
	return func(line []byte) (string, bool) {
		r.Reset(line)
		dec.Reset(r)
		if t, err := dec.ReadToken(); err != nil || t.Kind() != '{' {
			return "", false
		}
		t, err := dec.ReadToken()
		if err != nil || t.Kind() != '"' {
			return "", false
		}
		return t.String(), true
	}
}

func route(side string, peek keyPeek, path string) {
	lines := linesOf(path)
	rounds := count(10)
	var hits uint64
	start := benchmarkNow()
	for i := 0; i < rounds; i++ {
		for _, line := range lines {
			if k, ok := peek(line); ok && k == "id" {
				hits++
			}
		}
	}
	elapsed := benchmarkSince(start)
	rateAs(side, "route-kind", uint64(len(lines)*rounds), elapsed)
	checkAs(side, "route-kind", "hits", hits)
}
func routeTag(side string, peek keyPeek, path string) {
	lines := linesOf(path)
	rounds := count(10)
	var counts [3]uint64
	start := benchmarkNow()
	for i := 0; i < rounds; i++ {
		for _, line := range lines {
			k, ok := peek(line)
			if !ok {
				continue
			}
			switch k {
			case "open":
				counts[0]++
			case "retry":
				counts[1]++
			case "close":
				counts[2]++
			}
		}
	}
	elapsed := benchmarkSince(start)
	rateAs(side, "route-tag", uint64(len(lines)*rounds), elapsed)
	checkAs(side, "route-tag", "open", counts[0])
	checkAs(side, "route-tag", "retry", counts[1])
	checkAs(side, "route-tag", "close", counts[2])
}

func leading(side string, decode decodeFn, path string) {
	lines := linesOf(path)
	rounds := count(4)
	var sum uint64
	start := benchmarkNow()
	for i := 0; i < rounds; i++ {
		for _, line := range lines {
			var v struct {
				ID uint64 `json:"id"`
			}
			must(decode(line, &v))
			sum += v.ID
		}
	}
	elapsed := benchmarkSince(start)
	rateAs(side, "leading-ints", uint64(len(lines)*rounds), elapsed)
	checkAs(side, "leading-ints", "sum", sum)
}

var controlSet = func() string {
	var b strings.Builder
	for c := 0; c < 0x20; c++ {
		if c != '\t' {
			b.WriteByte(byte(c))
		}
	}
	return b.String()
}()

func control(path string) {
	lines := linesOf(path)
	rounds := count(10)
	var hits, scanned uint64
	start := benchmarkNow()
	for i := 0; i < rounds; i++ {
		for _, line := range lines {
			if at := bytes.IndexAny(line, controlSet); at >= 0 {
				hits++
				scanned += uint64(at)
			} else {
				scanned += uint64(len(line))
			}
		}
	}
	elapsed := benchmarkSince(start)
	mbAs(sideV1, "control-scan", scanned, elapsed)
	rateAs(sideV1, "control-scan", uint64(len(lines)*rounds), elapsed)
	checkAs(sideV1, "control-scan", "hits", hits)
	checkAs(sideV1, "control-scan", "scanned", scanned)
}

func split(path string) {
	b, err := os.ReadFile(path)
	must(err)
	rounds := count(10)
	var lines, total uint64
	start := benchmarkNow()
	for i := 0; i < rounds; i++ {
		for line := range bytes.Lines(b) {
			lines++
			total += uint64(len(bytes.TrimSuffix(line, []byte{'\n'})))
		}
	}
	elapsed := benchmarkSince(start)
	mbAs(sideV1, "split-lines", uint64(len(b))*uint64(rounds), elapsed)
	checkAs(sideV1, "split-lines", "lines", lines)
	checkAs(sideV1, "split-lines", "bytes", total)
}

func starts(path string) []int64 {
	b, err := os.ReadFile(path)
	must(err)
	var out []int64
	n := 0
	for at := 0; at < len(b); n++ {
		if n%100 == 0 {
			out = append(out, int64(at))
		}
		i := bytes.IndexByte(b[at:], '\n')
		if i < 0 {
			break
		}
		at += i + 1
	}
	return out
}
func resume(side string, decode decodeFn, path string) {
	offsets := starts(path)
	slices.Reverse(offsets)
	f, err := os.Open(path)
	must(err)
	defer f.Close()
	r := bufio.NewReaderSize(f, 64*1024)
	var sum uint64
	start := benchmarkNow()
	for _, off := range offsets {
		_, err := f.Seek(off, io.SeekStart)
		must(err)
		r.Reset(f)
		line, err := r.ReadSlice('\n')
		must(err)
		var v Record
		must(decode(line[:len(line)-1], &v))
		sum += v.ID
	}
	elapsed := benchmarkSince(start)
	rateAs(side, "resume", uint64(len(offsets)), elapsed)
	checkAs(side, "resume", "sum", sum)
}

// HookedV1 delegates through UnmarshalJSON, which hands over the value's
// bytes (scanned once to find them) and decodes them again.
type HookedV1 struct{ Inner Record }

func (h *HookedV1) UnmarshalJSON(b []byte) error { return json.Unmarshal(b, &h.Inner) }

// HookedV2 delegates on the same token stream.
type HookedV2 struct{ Inner Record }

func (h *HookedV2) UnmarshalJSONFrom(dec *jsontext.Decoder) error {
	return jsonv2.UnmarshalDecode(dec, &h.Inner)
}

func hook(side string, path string) {
	var lines, sum uint64
	start := benchmarkNow()
	for i := 0; i < count(2); i++ {
		eachLine(path, func(line []byte) {
			if side == sideV1 {
				var v HookedV1
				must(json.Unmarshal(line, &v))
				sum += v.Inner.Count
			} else {
				var v HookedV2
				must(jsonv2.Unmarshal(line, &v))
				sum += v.Inner.Count
			}
			lines++
		})
	}
	elapsed := benchmarkSince(start)
	rateAs(side, "custom-hook", lines, elapsed)
	mbAs(side, "custom-hook", fileSize(path)*uint64(count(2)), elapsed)
	checkAs(side, "custom-hook", "lines", lines)
	checkAs(side, "custom-hook", "sum", sum)
}

type Data struct {
	Who  string   `json:"who"`
	Beat uint64   `json:"beat"`
	Tags []string `json:"tags"`
}

func carried(side string, decode decodeFn, encode encodeFn, path string) {
	var lines, at, dataBytes uint64
	start := benchmarkNow()
	eachLine(path, func(line []byte) {
		if side == sideV1 {
			var v struct {
				Kind string          `json:"kind"`
				At   uint64          `json:"at"`
				Data json.RawMessage `json:"data"`
			}
			must(json.Unmarshal(line, &v))
			at += v.At
			dataBytes += uint64(len(v.Data))
		} else {
			var v struct {
				Kind string         `json:"kind"`
				At   uint64         `json:"at"`
				Data jsontext.Value `json:"data"`
			}
			must(jsonv2.Unmarshal(line, &v))
			at += v.At
			dataBytes += uint64(len(v.Data))
		}
		lines++
	})
	elapsed := benchmarkSince(start)
	rateAs(side, "carried", lines, elapsed)
	mbAs(side, "carried", fileSize(path), elapsed)
	checkAs(side, "carried", "at", at)
	checkAs(side, "carried", "data_bytes", dataBytes)

	var held [][]byte
	for _, line := range linesOf(path) {
		from := bytes.Index(line, []byte(`"data":`)) + len(`"data":`)
		held = append(held, line[from:len(line)-1])
		if len(held) == 200_000 {
			break
		}
	}
	var beats uint64
	start = benchmarkNow()
	for _, raw := range held {
		var d Data
		must(decode(raw, &d))
		beats += d.Beat + uint64(len(d.Tags))
	}
	elapsed = benchmarkSince(start)
	rateAs(side, "raw-parse", uint64(len(held)), elapsed)
	checkAs(side, "raw-parse", "sum", beats)

	var encoded uint64
	start = benchmarkNow()
	for i := range held {
		b, err := encode(&Data{Who: "ada", Beat: uint64(i % 7), Tags: []string{"a", "b"}})
		must(err)
		encoded += uint64(len(b))
	}
	elapsed = benchmarkSince(start)
	rateAs(side, "raw-encode", uint64(len(held)), elapsed)
	checkAs(side, "raw-encode", "bytes", encoded)
}

func fileID(path string) {
	rounds := count(100_000)
	f, err := os.Open(path)
	must(err)
	defer f.Close()
	first, err := f.Stat()
	must(err)
	var same uint64
	start := benchmarkNow()
	for i := 0; i < rounds; i++ {
		st, err := f.Stat()
		must(err)
		if os.SameFile(st, first) {
			same++
		}
	}
	elapsed := benchmarkSince(start)
	rateAs(sideV1, "file-id", uint64(rounds), elapsed)
	checkAs(sideV1, "file-id", "same", same)
	same = 0
	start = benchmarkNow()
	for i := 0; i < rounds; i++ {
		st, err := os.Stat(path)
		must(err)
		if os.SameFile(st, first) {
			same++
		}
	}
	elapsed = benchmarkSince(start)
	rateAs(sideV1, "file-id-path", uint64(rounds), elapsed)
	checkAs(sideV1, "file-id-path", "same", same)
}

// syncAll: File.Sync is fcntl(F_FULLFSYNC) on darwin, the call strand makes
// there at either level; Go has no data-only sync.
func syncAll(dir string) {
	rounds := count(100)
	chunk := bytes.Repeat([]byte{'x'}, 128)
	f, err := os.Create(dir + "/go-sync.dat")
	must(err)
	start := benchmarkNow()
	for i := 0; i < rounds; i++ {
		_, err := f.Write(chunk)
		must(err)
		must(f.Sync())
	}
	rateAs(sideV1, "sync-all", uint64(rounds), benchmarkSince(start))
	f.Close()
	d, err := os.Open(dir)
	must(err)
	start = benchmarkNow()
	for i := 0; i < rounds; i++ {
		must(d.Sync())
	}
	rateAs(sideV1, "sync-dir", uint64(rounds), benchmarkSince(start))
	d.Close()
	wf, err := os.Create(dir + "/go-writer-sync.jsonl")
	must(err)
	defer wf.Close()
	w := bufio.NewWriterSize(wf, 64*1024)
	enc := json.NewEncoder(w)
	v := sample()
	var records uint64
	start = benchmarkNow()
	for i := 0; i < rounds; i++ {
		must(enc.Encode(&v))
		must(w.Flush())
		must(wf.Sync())
		records++
	}
	rateAs(sideV1, "writer-sync", uint64(rounds), benchmarkSince(start))
	checkAs(sideV1, "writer-sync", "records", records)
}

// cover runs one of the modes above; false when the name is not one.
func cover(mode, arg string) bool {
	v2 := strings.HasSuffix(mode, "-v2")
	side, decode, encode, peek := sideV1, decodeFn(v1Decode), encodeFn(v1Encode), keyPeek(nil)
	if v2 {
		mode = strings.TrimSuffix(mode, "-v2")
		side, decode, encode = sideV2, v2Decode, v2Encode
	}
	if mode == "route" || mode == "route-tag" {
		if v2 {
			peek = peekV2()
		} else {
			peek = peekV1()
		}
	}
	switch mode {
	case "read":
		readTyped(side, decode, arg)
	case "write":
		writeV2(arg, false)
	case "write-flush":
		writeV2(arg, true)
	case "keep":
		keep(side, decode, arg)
	case "skip":
		skip(side, decode, arg)
	case "pretty":
		prettyRead(side, arg)
	case "write-pretty":
		writePretty(side, arg)
	case "object-open":
		objectOpen(side, encode, arg)
	case "route":
		route(side, peek, arg)
	case "route-tag":
		routeTag(side, peek, arg)
	case "leading":
		leading(side, decode, arg)
	case "control":
		control(arg)
	case "split":
		split(arg)
	case "resume":
		resume(side, decode, arg)
	case "hook":
		hook(side, arg)
	case "carried":
		carried(side, decode, encode, arg)
	case "file-id":
		fileID(arg)
	case "sync":
		syncAll(arg)
	default:
		return false
	}
	return true
}
