"""What strand reads against what expat reads (Python's pyexpat, non-validating,
internal entities expanded, attributes as specified, no namespaces).

  infoset.py suite XMLCONF_DIR MANIFEST STRAND_BENCH
      every well-formed document of the W3C suite strand's manifest lists:
      both trees, compared.
  infoset.py fuzz STRAND_BENCH SEED COUNT
      documents made by damaging examples: both verdicts and, where both
      read one, both trees, compared.

A tree is ["name", [["attribute", "value"], ...], [child, "text", ...]] with
adjacent text joined and, as strand reads, white space between child elements
dropped unless the element's content is mixed (some text of it not blank).
"""
import json, random, subprocess, sys, xml.parsers.expat

def expat_tree(data):
    p = xml.parsers.expat.ParserCreate()
    p.specified_attributes = True
    p.ordered_attributes = True
    p.SetParamEntityParsing(xml.parsers.expat.XML_PARAM_ENTITY_PARSING_UNLESS_STANDALONE)
    stack = [["#doc", [], []]]
    def start(name, attrs):
        node = [name, [[attrs[i], attrs[i + 1]] for i in range(0, len(attrs), 2) if not attrs[i].startswith("xmlns")], []]
        node[1] += [[attrs[i], attrs[i + 1]] for i in range(0, len(attrs), 2) if attrs[i].startswith("xmlns")]
        stack[-1][2].append(node)
        stack.append(node)
    def end(name):
        stack.pop()
    def text(t):
        if len(stack) == 1: return
        kids = stack[-1][2]
        if kids and isinstance(kids[-1], str): kids[-1] += t
        else: kids.append(t)
    p.StartElementHandler = start
    p.EndElementHandler = end
    p.CharacterDataHandler = text
    p.buffer_text = True
    p.Parse(data, True)
    return normalize(stack[0][2][0])

def normalize(node):
    name, attrs, kids = node
    mixed = any(isinstance(k, str) and k.strip(" \t\n\r") for k in kids)
    has_elements = any(not isinstance(k, str) for k in kids)
    out = []
    for k in kids:
        if isinstance(k, str):
            if not mixed and has_elements and not k.strip(" \t\n\r"): continue
            if k == "": continue
            out.append(k)
        else:
            out.append(normalize(k))
    return [name, sorted(attrs), out]

def strand_trees(bench, documents):
    payload = b"".join(len(d).to_bytes(8, "little") + d for d in documents)
    out = subprocess.run([bench, "--dump"], input=payload, capture_output=True, check=True).stdout
    lines = out.decode("utf-8").splitlines()
    assert len(lines) == len(documents), (len(lines), len(documents))
    result = []
    for line in lines:
        v = json.loads(line)
        result.append(v if isinstance(v, dict) else normalize(v))
    return result

def expat_verdict(d):
    try:
        return expat_tree(d)
    except xml.parsers.expat.ExpatError as e:
        return {"refused": str(e)}
    except Exception as e:
        return {"refused": "python: " + repr(e)}

def suite(root, manifest, bench):
    docs, ids = [], []
    for line in open(manifest):
        kind, ns, path, ident = line.split()
        if kind == "not-wf": continue
        docs.append(open(f"{root}/{path}", "rb").read())
        ids.append(ident)
    mine = strand_trees(bench, docs)
    same = differ = 0
    for ident, doc, s in zip(ids, docs, mine):
        e = expat_verdict(doc)
        if s == e: same += 1
        else:
            differ += 1
            print("DIFFER", ident, json.dumps(s)[:300], "| expat:", json.dumps(e)[:300])
    print(f"suite: {same} the same, {differ} different, of {len(docs)}")

EXAMPLES = [
    b"<?xml version=\"1.0\"?><a x='1'>t<b/><![CDATA[<c>]]><!--n--><?p d?></a>",
    b"<!DOCTYPE d [<!ENTITY e \"v&#65;\"><!ATTLIST d k CDATA 'z'>]><d k=\"&e;\">&e;&amp;</d>",
    b"<r><s>\r\n x </s><s a=\"&#9;\t\"/>&#x10FFFF;</r>",
    b"<l><i>1</i><i>2</i><j>3</j><i>4</i></l>",
    b"<!DOCTYPE x [<!ENTITY a \"<b>&c;</b>\"><!ENTITY c \"z\">]><x>&a;&a;</x>",
]
def mutate(rng, data):
    d = bytearray(data)
    for _ in range(rng.randint(1, 4)):
        op = rng.randrange(4)
        if op == 0 and d: del d[rng.randrange(len(d))]
        elif op == 1: d.insert(rng.randrange(len(d) + 1), rng.choice(b"<>&;\"'=/!?[]-x \t\r\n\xc3\xa9#%"))
        elif op == 2 and d: d[rng.randrange(len(d))] = rng.randrange(256)
        elif op == 3 and len(d) > 2:
            i = rng.randrange(len(d)); j = rng.randrange(len(d))
            d[min(i, j):max(i, j)] = d[min(i, j):max(i, j)] * 2
    return bytes(d)

def fuzz(bench, seed, count):
    rng = random.Random(seed)
    docs = [mutate(rng, rng.choice(EXAMPLES)) for _ in range(count)]
    mine = strand_trees(bench, docs)
    both_read = both_refused = 0
    disagreements = {}
    for d, s in zip(docs, mine):
        e = expat_verdict(d)
        s_ok, e_ok = "refused" not in s, "refused" not in e
        if s_ok and e_ok:
            if s == e: both_read += 1
            else: disagreements.setdefault("trees differ", []).append(d)
        elif not s_ok and not e_ok: both_refused += 1
        elif s_ok: disagreements.setdefault("strand reads, expat refuses: " + e["refused"].split(":")[0], []).append(d)
        else: disagreements.setdefault("expat reads, strand refuses: " + s["refused"], []).append(d)
    print(f"fuzz seed {seed}: {count} documents, both read the same {both_read}, both refused {both_refused}")
    for k, v in sorted(disagreements.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(v):6d}  {k}   e.g. {v[0][:120]!r}")

if __name__ == "__main__":
    if sys.argv[1] == "suite": suite(sys.argv[2], sys.argv[3], sys.argv[4])
    else: fuzz(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
