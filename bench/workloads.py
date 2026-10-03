"""Every public operation, with A/B pairs and the standard tools that do the same job."""
import json
import shutil
from quiet import HERE

PACKAGE = 'strand'
COMPARISONS = ['Zig std.json', 'Rust serde_json 1.0.145 (borrowed Cow lines, owned values, RawValue, stream reader)',
               'Go encoding/json and encoding/json/v2 (Go 1.27 standard library)',
               'Rust std, Go std and Zig std where the operation is not JSON (line split, control scan, file identity, sync)',
               'system tail (-n, -r, -F)', 'copied Chronicle codec bde5a26',
               'Raw versus std.json.Value', 'mixed-line reader versus parse alone']

UNAVAILABLE = [
    'simd-json (not implemented)',
    'before: copyOwned/freeOwned, writeObjectOpen, leadingIntMembers, innerParse, Writer.initFileBounded, '
    'FileId.ofPath, syncDir and Reader oversized_member are new since the before pin',
    'seq-read/seq-write (RFC 7464 record separator): no reader or writer for it in std.json, serde_json or encoding/json',
    'write-bounded: no standard JSON writer refuses a record past a line bound before writing it',
    'versioned: no schema-version envelope with migration in std.json, serde_json or encoding/json',
    'oversized: Go bufio.Scanner stops the stream at ErrTooLong, Rust BufRead and std.json have no bounded line read',
    'copy: Go strings are immutable (assignment shares them, no deep copy API); std.json has no copy of a parsed value',
    'pretty-read: std.json reads one document, not a stream of them',
    'follow: no follower in Rust, Go or Zig std; system tail -F is the comparison (bytes through a pipe)',
    'identity-fingerprint: no standard file fingerprint',
    'sync-data in Go: File.Sync is the only call (F_FULLFSYNC on darwin)',
]


def agree(workload):
    """Every `checksum` row must match across the sides that print it."""
    seen = {}
    def validate(side, rows):
        found = [r for r in rows if r['unit'] == 'checksum']
        if not found:
            raise RuntimeError(f'{workload}/{side}: no checksum rows')
        for r in found:
            key = (r['workload'], r['metric'])
            first = seen.setdefault(key, (side, r['value']))
            if first[1] != r['value']:
                raise RuntimeError(f'{workload}/{side}: {key[0]} {key[1]} differs from {first[0]}')
    return validate


def run(p, bins):
    own, codec = {}, {}
    for side in ('before', 'after'):
        root = p.scratch / side / 'bench'
        own[side] = p.zig(root / 'own') / 'strand-own-bench'
        codec[side] = p.zig(root / 'codec') / 'codec-bench'
    print('Preparing existing same-job tools' if p.preparing else 'Using prepared same-job tools', flush=True)
    p.setup_command([p.tool('cargo'), 'build', '-j1', '--release', '--locked'])
    go = p.scratch / 'go-bench'
    p.setup_command([p.tool('go'), 'build', '-p=1', '-trimpath', "-ldflags=-s -w", '-o', go,
                     './src/go_bench.go', './src/go_cover.go'])
    tail = p.scratch / 'tail-command'
    p.setup_command([p.tool('cc'), '-O2', '-o', tail, 'src/tail_command.c'])
    follow_tool = p.scratch / 'follow-command'
    p.setup_command([p.tool('cc'), '-O2', '-o', follow_tool, 'src/follow_command.c'])
    rust = p.env['CARGO_TARGET_DIR'] + '/release/strand-tools-bench'
    stdjson = bins['after'] / 'zig-stdjson-bench'
    fixtures = p.scratch / 'fixtures'
    p.setup_command([p.tool('python'), 'src/generate.py', fixtures])
    p.prepared.require(fixtures)
    for tool in (go, tail, follow_tool):
        p.prepared.require(tool)

    def ours(mode, *args, before=True):
        sides = [('before', [bins['before'] / 'strand-bench', mode, *args])] if before else []
        return sides + [('after', [bins['after'] / 'strand-bench', mode, *args])]

    def json_sides(mode, *args, std=True, go_v2=True):
        sides = [('std.json', [stdjson, mode, *args])] if std else []
        sides.append(('serde_json', [rust, mode, *args]))
        sides.append(('encoding/json', [go, mode, *args]))
        if go_v2:
            sides.append(('encoding/json/v2', [go, mode + '-v2', *args]))
        return sides

    def discard(outputs):
        # A timed pass keeps no written file (each is hundreds of MB); smoke
        # keeps them for the comparisons above.
        return None if p.smoke else lambda side: outputs[side].unlink(missing_ok=True)

    def same_records(outputs, strip=b''):
        # Smoke proves the same record was encoded by every implementation.
        def check(side, rows):
            if p.smoke:
                record = json.loads(outputs[side].read_bytes().lstrip(strip))
                if record != json.loads(outputs[next(iter(outputs))].read_bytes().lstrip(strip)):
                    raise RuntimeError(f'{side}: encoded record differs')
        return check

    for fixture in ('regular', 'long'):
        path = fixtures / f'{fixture}.jsonl'
        p.group(f'typed-read-{fixture}', [
            ('before', [bins['before'] / 'strand-bench', 'read', path]),
            ('after', [bins['after'] / 'strand-bench', 'read', path]),
            ('std.json', [stdjson, 'read', path]),
            ('serde_json-lines', [rust, 'read', path]),
            ('serde_json-stream', [rust, 'stream', path]),
            ('encoding/json', [go, 'read', path]),
            ('encoding/json/v2', [go, 'read-v2', path])])
        p.group(f'raw-frame-{fixture}', [
            ('before', [bins['before'] / 'strand-bench', 'raw', path]),
            ('after', [bins['after'] / 'strand-bench', 'raw', path]),
            ('Rust-line-frame', [rust, 'raw', path]),
            ('Go-line-frame', [go, 'raw', path])])
    for mode in ('write', 'write-flush'):
        outputs = {side: p.scratch / f'{side.replace("/", "-")}-{mode}.jsonl'
                   for side in ('before', 'after', 'std.json', 'serde_json', 'Go', 'encoding/json/v2')}
        p.group(mode, [
            ('before', [bins['before'] / 'strand-bench', mode, outputs['before']]),
            ('after', [bins['after'] / 'strand-bench', mode, outputs['after']]),
            ('std.json', [stdjson, mode, outputs['std.json']]),
            ('serde_json', [rust, mode, outputs['serde_json']]),
            ('Go', [go, mode, outputs['Go']]),
            ('encoding/json/v2', [go, mode + '-v2', outputs['encoding/json/v2']])], validate=same_records(outputs),
            cleanup=discard(outputs))
    path = fixtures / 'regular.jsonl'
    p.group('tail', [('before', [bins['before'] / 'strand-bench', 'tail', path]),
                     ('after', [bins['after'] / 'strand-bench', 'tail', path]),
                     ('Rust-backward-reader', [rust, 'tail', path]), ('system-tail', [tail, path])])

    # Reads that own their values, and the deep copy on its own.
    for fixture in ('regular', 'long'):
        path = fixtures / f'{fixture}.jsonl'
        p.group(f'keep-{fixture}', ours('keep', path) + json_sides('keep', path), validate=agree('keep'))
        p.group(f'copy-{fixture}', ours('copy', path, before=False) + [('Rust-clone', [rust, 'copy', path])],
                validate=agree('copy'))
    damaged = fixtures / 'damaged.jsonl'
    p.group('skip-malformed', ours('skip', damaged) + json_sides('skip', damaged), validate=agree('skip-malformed'))
    pretty = fixtures / 'pretty.jsonl'
    p.group('pretty-read', ours('pretty', pretty) + json_sides('pretty', pretty, std=False), validate=agree('pretty-read'))
    seq = fixtures / 'seq.jsonl'
    p.group('seq-read', ours('seq-read', seq), validate=agree('seq-read'))

    # Writers: formats, bounds, open objects.
    def written(job, sides):
        outputs = {side: p.scratch / f'{side.replace("/", "-")}-{job}.jsonl' for side, _ in sides}
        return [(side, [*argv, outputs[side]]) for side, argv in sides], outputs
    sides, outputs = written('write-pretty', [(s, a) for s, a in ours('write-pretty') + json_sides('write-pretty')])
    p.group('write-pretty', sides, validate=same_records(outputs), cleanup=discard(outputs))
    sides, outputs = written('seq-write', ours('seq-write'))
    p.group('seq-write', sides, validate=same_records(outputs, strip=b'\x1e'), cleanup=discard(outputs))
    sides, outputs = written('write-bounded', ours('write-bounded', before=False))
    p.group('write-bounded', sides, validate=same_records({'reference': p.scratch / 'after-write.jsonl', **outputs}),
            cleanup=discard(outputs))
    sides, outputs = written('object-open', ours('object-open', before=False) + json_sides('object-open'))
    def same_bytes(side, rows):
        if p.smoke and outputs[side].read_bytes() != outputs['after'].read_bytes():
            raise RuntimeError(f'object-open/{side}: bytes differ from strand')
    p.group('object-open', sides, validate=same_bytes, cleanup=discard(outputs))

    # Questions answered off a line's bytes.
    for fixture in ('regular', 'long'):
        path = fixtures / f'{fixture}.jsonl'
        p.group(f'route-kind-{fixture}', ours('route', path) + json_sides('route', path), validate=agree('route-kind'))
        p.group(f'leading-ints-{fixture}', ours('leading', path, before=False) + json_sides('leading', path),
                validate=agree('leading-ints'))
        p.group(f'control-scan-{fixture}', ours('control', path) + [
            ('std.mem.indexOfAny', [stdjson, 'control', path]), ('Rust-position', [rust, 'control', path]),
            ('Go-bytes.IndexAny', [go, 'control', path])], validate=agree('control-scan'))
        p.group(f'split-lines-{fixture}', ours('split', path) + [
            ('std.mem.splitScalar', [stdjson, 'split', path]), ('Rust-slice-split', [rust, 'split', path]),
            ('Go-bytes.Lines', [go, 'split', path])], validate=agree('split-lines'))
    tagged = fixtures / 'tagged.jsonl'
    p.group('route-tag', ours('route-tag', tagged) + json_sides('route-tag', tagged), validate=agree('route-tag'))

    # Places, hooks, versions, carried values.
    regular = fixtures / 'regular.jsonl'
    p.group('resume', ours('resume', regular) + json_sides('resume', regular), validate=agree('resume'))
    p.group('custom-hook', ours('hook', regular, before=False) + json_sides('hook', regular), validate=agree('custom-hook'))
    p.group('versioned', ours('versioned', 'memory'), validate=agree('versioned'))
    carried = fixtures / 'carried.jsonl'
    p.group('carried-raw', ours('carried', carried) + json_sides('carried', carried), validate=agree('carried'))
    p.group('oversized', ours('oversized', fixtures / 'long.jsonl'), validate=agree('oversized'))

    # Files: backwards, following, identity, durability.
    p.group('backward', ours('backward', regular) + [('Rust-backward-reader', [rust, 'backward', regular]),
                                                      ('system-tail-r', [follow_tool, 'reverse', regular])],
            validate=agree('backward'))
    def fresh(name):
        def prepare(side):
            directory = p.scratch / f'{side.replace("/", "-")}-{name}'
            shutil.rmtree(directory, ignore_errors=True)
            directory.mkdir(parents=True)
        return prepare
    def directory(side, name):
        return p.scratch / f'{side.replace("/", "-")}-{name}'
    p.group('follow', [(side, [bins[side] / 'strand-bench', 'follow', directory(side, 'follow'), regular])
                       for side in ('before', 'after')] +
            [('system-tail-F', [follow_tool, 'follow', directory('system-tail-F', 'follow'), regular])],
            prepare=fresh('follow'), validate=agree('follow'))
    p.group('file-id', ours('file-id', regular) + [('Zig-std-stat', [stdjson, 'file-id', regular]),
                                                    ('Rust-metadata', [rust, 'file-id', regular]),
                                                    ('Go-os.Stat', [go, 'file-id', regular])], validate=agree('file-id'))
    sync_agree = agree('sync')
    p.group('sync', [(side, [*argv, directory(side, 'sync')]) for side, argv in
                     ours('sync') + [('Zig-std-fsync', [stdjson, 'sync']), ('Rust-std', [rust, 'sync']),
                                     ('Go-std', [go, 'sync'])]],
            prepare=fresh('sync'),
            validate=lambda side, rows: None if side == 'Zig-std-fsync' else sync_agree(side, rows))

    corpus = p.scratch / 'synthetic_events.jsonl'
    p.setup_command([p.tool('python'), 'codec/src/synthetic_corpus.py', corpus,
               *(['--smoke'] if p.smoke else [])])
    p.prepared.require(corpus)
    p.group('codec', [('before', [codec['before'], 'strand', corpus]),
                      ('after', [codec['after'], 'strand', corpus]),
                      ('Chronicle-bde5a26', [codec['after'], 'chronicle', corpus])])
    p.group('own-operations', [('before', [own['before']]), ('after', [own['after']])])
