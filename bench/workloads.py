"""The existing line, codec and own-operation jobs, with A/B pairs."""
from quiet import HERE

PACKAGE = 'strand'
COMPARISONS = ['Zig std.json', 'Rust serde_json (line and stream readers)',
               'Go encoding/json', 'system tail', 'copied Chronicle codec bde5a26',
               'Raw versus std.json.Value', 'mixed-line reader versus parse alone']

UNAVAILABLE = ['simd-json (not implemented)']


def run(p, bins):
    own, codec = {}, {}
    for side in ('before', 'after'):
        root = p.scratch / side / 'bench'
        own[side] = p.zig(root / 'own') / 'strand-own-bench'
        codec[side] = p.zig(root / 'codec') / 'codec-bench'
    print('Building existing same-job tools', flush=True)
    p.command([p.tool('cargo'), 'build', '-j1', '--release', '--locked'])
    go = p.scratch / 'go-bench'
    p.command([p.tool('go'), 'build', '-p=1', '-trimpath', "-ldflags=-s -w", '-o', go, './src/go_bench.go'])
    tail = p.scratch / 'tail-command'
    p.command([p.tool('cc'), '-O2', '-o', tail, 'src/tail_command.c'])
    rust = p.env['CARGO_TARGET_DIR'] + '/release/strand-tools-bench'
    stdjson = bins['after'] / 'zig-stdjson-bench'
    fixtures = p.scratch / 'fixtures'
    p.command([p.tool('python'), 'src/generate.py', fixtures])
    for fixture in ('regular', 'long'):
        path = fixtures / f'{fixture}.jsonl'
        p.group(f'typed-read-{fixture}', [
            ('before', [bins['before'] / 'strand-bench', 'read', path]),
            ('after', [bins['after'] / 'strand-bench', 'read', path]),
            ('std.json', [stdjson, 'read', path]),
            ('serde_json-lines', [rust, 'read', path]),
            ('serde_json-stream', [rust, 'stream', path]),
            ('encoding/json', [go, 'read', path])])
        p.group(f'raw-frame-{fixture}', [
            ('before', [bins['before'] / 'strand-bench', 'raw', path]),
            ('after', [bins['after'] / 'strand-bench', 'raw', path]),
            ('Rust-line-frame', [rust, 'raw', path]),
            ('Go-line-frame', [go, 'raw', path])])
    for mode in ('write', 'write-flush'):
        outputs = {side: p.scratch / f'{side}-{mode}.jsonl' for side in ('before', 'after', 'std.json', 'serde_json', 'Go')}
        def check(side, rows):
            # Smoke proves the same record was encoded by every implementation.
            if p.smoke:
                import json
                record = json.loads(outputs[side].read_text())
                if record != json.loads(outputs['before'].read_text()):
                    raise RuntimeError(f'{side}: encoded record differs')
        p.group(mode, [
            ('before', [bins['before'] / 'strand-bench', mode, outputs['before']]),
            ('after', [bins['after'] / 'strand-bench', mode, outputs['after']]),
            ('std.json', [stdjson, mode, outputs['std.json']]),
            ('serde_json', [rust, mode, outputs['serde_json']]),
            ('Go', [go, mode, outputs['Go']])], validate=check)
    path = fixtures / 'regular.jsonl'
    p.group('tail', [('before', [bins['before'] / 'strand-bench', 'tail', path]),
                     ('after', [bins['after'] / 'strand-bench', 'tail', path]),
                     ('Rust-backward-reader', [rust, 'tail', path]), ('system-tail', [tail, path])])
    corpus = p.scratch / 'synthetic_events.jsonl'
    p.command([p.tool('python'), 'codec/src/synthetic_corpus.py', corpus,
               *(['--smoke'] if p.smoke else [])])
    p.group('codec', [('before', [codec['before'], 'strand', corpus]),
                      ('after', [codec['after'], 'strand', corpus]),
                      ('Chronicle-bde5a26', [codec['after'], 'chronicle', corpus])])
    p.group('own-operations', [('before', [own['before']]), ('after', [own['after']])])
