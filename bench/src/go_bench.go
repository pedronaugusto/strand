package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

type Meta struct {
	Region string `json:"region"`
	Score  uint64 `json:"score"`
}
type Record struct {
	ID      uint64   `json:"id"`
	Name    string   `json:"name"`
	Count   uint64   `json:"count"`
	Meta    Meta     `json:"meta"`
	Tags    []string `json:"tags"`
	Message string   `json:"message"`
}

func count(n int) int {
	if os.Getenv("BENCH_SMOKE") == "1" {
		return 1
	}
	return n
}
func sample() Record {
	return Record{123456, "user-3456", 987654, Meta{"eu", 73}, []string{"jsonl", "benchmark", "g42"}, strings.Repeat("abcdefghij", 25) + "abcdef"}
}
func emit(work, metric string, value float64, unit string) {
	fmt.Printf("go-encoding-json\t%s\t%s\t%.6f\t%s\n", work, metric, value, unit)
}
func read(path string) {
	st, _ := os.Stat(path)
	var n, sum uint64
	start := benchmarkNow()
	for i := 0; i < count(2); i++ {
		f, _ := os.Open(path)
		s := bufio.NewScanner(f)
		s.Buffer(make([]byte, 64*1024), 2<<20)
		for s.Scan() {
			var v Record
			if json.Unmarshal(s.Bytes(), &v) != nil {
				panic("decode")
			}
			sum += v.Count
			n++
		}
		if s.Err() != nil {
			panic(s.Err())
		}
		f.Close()
	}
	elapsed := benchmarkSince(start).Seconds()
	if sum == 0 {
		panic("sum")
	}
	emit("typed-read", "lines", float64(n)/elapsed, "lines/s")
	emit("typed-read", "bytes", float64(st.Size())*float64(count(2))/elapsed/1e6, "MB/s")
}
func raw(path string) {
	st, _ := os.Stat(path)
	var n uint64
	start := benchmarkNow()
	for i := 0; i < count(12); i++ {
		f, _ := os.Open(path)
		s := bufio.NewScanner(f)
		s.Buffer(make([]byte, 64*1024), 2<<20)
		for s.Scan() {
			n += uint64(len(s.Bytes()))
		}
		if s.Err() != nil {
			panic(s.Err())
		}
		f.Close()
	}
	elapsed := benchmarkSince(start).Seconds()
	if n == 0 {
		panic("sum")
	}
	emit("raw-frame", "bytes", float64(st.Size())*float64(count(12))/elapsed/1e6, "MB/s")
}
func write(path string, each bool) {
	f, _ := os.Create(path)
	defer f.Close()
	w := bufio.NewWriterSize(f, 1<<20)
	enc := json.NewEncoder(w)
	v := sample()
	start := benchmarkNow()
	for i := 0; i < count(1_000_000); i++ {
		if enc.Encode(&v) != nil {
			panic("encode")
		}
		if each {
			w.Flush()
		}
	}
	w.Flush()
	elapsed := benchmarkSince(start).Seconds()
	st, _ := f.Stat()
	work := "typed-write"
	if each {
		work = "typed-write-flush"
	}
	emit(work, "bytes", float64(st.Size())/elapsed/1e6, "MB/s")
}
func main() {
	if len(os.Args) != 3 {
		panic("usage")
	}
	switch os.Args[1] {
	case "read":
		read(os.Args[2])
	case "raw":
		raw(os.Args[2])
	case "write":
		write(os.Args[2], false)
	case "write-flush":
		write(os.Args[2], true)
	default:
		panic("bad workload")
	}
}

func benchmarkNow() time.Time {
    if os.Getenv("BENCH_SMOKE") == "1" { return time.Time{} }
    return time.Now()
}
func benchmarkSince(start time.Time) time.Duration {
    if os.Getenv("BENCH_SMOKE") == "1" { return time.Nanosecond }
    return time.Since(start)
}
