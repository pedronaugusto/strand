// Go's encoding/xml (go1.27) on the documents strand's bench/xml.zig writes
// (`strand-xml-bench --inputs DIR`): typed reads of an S3 listing, its
// tokens, and a write. Rows as strand's: median of 31 samples of at least
// 100 ms each, in nanoseconds per document. encoding/xml ignores members a
// type does not name (strand refuses them by default): a policy mismatch.
package main

import (
	"encoding/xml"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"
)

type Owner struct {
	ID          string
	DisplayName string
}
type Object struct {
	Key          string
	LastModified string
	ETag         string
	Size         uint64
	StorageClass string
	Owner        Owner
}
type Listing struct {
	XMLName     xml.Name `xml:"http://s3.amazonaws.com/doc/2006-03-01/ ListBucketResult"`
	Name        string
	Prefix      string
	KeyCount    uint32
	MaxKeys     uint32
	IsTruncated bool
	Contents    []Object
}

var sink int

func row(name string, f func() int) {
	batch := 1
	for {
		start := time.Now()
		for i := 0; i < batch; i++ {
			sink += f()
		}
		if time.Since(start) >= 100*time.Millisecond {
			break
		}
		batch *= 2
	}
	samples := make([]float64, 31)
	for s := range samples {
		start := time.Now()
		for i := 0; i < batch; i++ {
			sink += f()
		}
		samples[s] = float64(time.Since(start).Nanoseconds()) / float64(batch)
	}
	sort.Float64s(samples)
	fmt.Printf("{\"row\":%q,\"median\":%.0f,\"best\":%.0f}\n", name, samples[15], samples[0])
}

func main() {
	dir := os.Args[1]
	small, _ := os.ReadFile(dir + "/s3-small.xml")
	large, _ := os.ReadFile(dir + "/s3-large.xml")
	typed := func(b []byte) func() int {
		return func() int {
			var l Listing
			if err := xml.Unmarshal(b, &l); err != nil {
				panic(err)
			}
			return len(l.Contents)
		}
	}
	row("go.typed.s3-10", typed(small))
	row("go.typed.s3-1000", typed(large))
	row("go.scan.s3-1000", func() int {
		d := xml.NewDecoder(strings.NewReader(string(large)))
		n := 0
		for {
			_, err := d.Token()
			if err == io.EOF {
				return n
			}
			if err != nil {
				panic(err)
			}
			n++
		}
	})
	var value Listing
	if err := xml.Unmarshal(large, &value); err != nil {
		panic(err)
	}
	// What encoding/xml writes, for strand to read (`strand-xml-bench --check`).
	written, err := xml.MarshalIndent(value, "", "  ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(dir+"/go-written.xml", written, 0o644); err != nil {
		panic(err)
	}
	row("go.write.s3-1000", func() int {
		out, err := xml.MarshalIndent(value, "", "  ")
		if err != nil {
			panic(err)
		}
		return len(out)
	})
}
