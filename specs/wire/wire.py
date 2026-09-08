#!/usr/bin/env python3
"""Reference decoder for Wire, the GiTF compact artifact notation.

Standard library only. Mirrors ``GiTF.Wire`` (lib/gitf/wire/*.ex) and is
checked against the same test vectors (specs/wire/vectors/) by
test/gitf/wire_test.exs, so a divergence between the two fails the build.

Usage:
    python3 wire.py <kind> [file]          # decode a Wire document to JSON on stdout
    python3 wire.py <kind> --files ctx.wire [file]
                                           # resolve F refs against a prompt's file table

Kinds: triage research requirements design review plan validation scoring.
See ../WIRE.md for the normative grammar and per-kind tables.
"""
import json
import re
import sys

# ---------------------------------------------------------------------------
# Syntax layer: text -> records
# ---------------------------------------------------------------------------

HEADER_RE = re.compile(r"^%wire\s+(\d+)(?:\s+([a-z_]+))?\s*$")
RECORD_RE = re.compile(r"^([A-Za-z][A-Za-z_]*?)(\d+)?:?(?:\s+(.*))?$")
FENCE_RE = re.compile(r"```wire\s*\n([\s\S]*?)\n\s*```")

# Head arity per tag, per kind. A tag absent here has no head (arity 0).
HEADS = {
    "triage": {"cx": 1, "bug": 1, "skip": 1, "files": 1},
    "research": {"cx": 1, "files": 1},
    "requirements": {"R": 2, "N": 1},
    "design": {"C": 1, "M": 2, "D": 2},
    "review": {"ok": 1, "sel": 1, "cov": 2, "I": 1},
    "plan": {"O": 1, "f": 1, "r": 1, "dep": 1},
    "validation": {"V": 2, "unc": 1, "verdict": 1},
    "scoring": {"out": 1, "traj": 1, "tool": 1, "safe": 1, "overall": 2},
}


def extract(text):
    """The last ```wire fence, or the text itself if it starts with %wire."""
    fences = FENCE_RE.findall(text)
    if fences:
        return fences[-1]
    t = text.strip()
    return t if t.startswith("%wire") else None


def _indent(line):
    if line.startswith("\t"):
        line = "  " + line[1:]
    return len(line) - len(line.lstrip(" "))


def _split_head(rest, arity):
    if not arity:
        return [], (rest.strip() or None)
    parts = rest.split(" | ", 1)
    if len(parts) == 2:
        return parts[0].split(), (parts[1].strip() or None)
    toks = rest.split()
    if len(toks) <= arity:
        return toks, None
    return toks[:arity], (" ".join(toks[arity:]) or None)


def _record(line, n, heads):
    m = RECORD_RE.match(line)
    if not m:
        return None
    tag, num, rest = m.group(1), m.group(2), m.group(3)
    head, text = _split_head(rest, heads.get(tag, 0)) if rest is not None else ([], None)
    return {"tag": tag, "id": int(num) if num else None, "head": head, "text": text, "props": [], "line": n}


def parse(text, heads):
    """Returns (header, records). Never raises on malformed lines; they are skipped."""
    header, records, blank = None, [], False
    for n, raw in enumerate(text.replace("\r\n", "\n").split("\n"), 1):
        if not raw.strip():
            blank = True
            continue
        ind = _indent(raw)
        if ind == 0 and raw.lstrip().startswith("#"):
            continue
        m = HEADER_RE.match(raw) if header is None and not records else None
        if m:
            header = {"version": int(m.group(1)), "kind": m.group(2)}
            continue
        if ind == 0:
            rec = _record(raw.rstrip(), n, heads)
            if rec:
                records.append(rec)
        elif 1 <= ind <= 3 and records:
            rec = _record(raw.strip(), n, heads)
            if rec:
                records[-1]["props"].append(rec)
        elif ind >= 4 and records:
            target = records[-1]["props"][-1] if records[-1]["props"] else records[-1]
            sep = "\n\n" if blank else "\n"
            target["text"] = raw.strip() if target["text"] is None else target["text"] + sep + raw.strip()
        blank = False
    return header, records


# ---------------------------------------------------------------------------
# File table
# ---------------------------------------------------------------------------

class Files:
    def __init__(self, paths=()):
        self.by_id, self.by_path = {}, {}
        for p in paths:
            self.add(p)

    def add(self, path):
        path = path.strip()
        if path not in self.by_path:
            n = max(self.by_id, default=0) + 1
            self.by_id[n], self.by_path[path] = path, n
        return "F%d" % self.by_path[path]

    def absorb(self, records):
        for r in records:
            if r["tag"] == "F" and r["id"] is not None and r["text"]:
                self.by_id[r["id"]] = r["text"].strip()
                self.by_path[r["text"].strip()] = r["id"]
        return self

    def declared(self, records):
        out = []
        for r in sorted((r for r in records if r["tag"] == "F" and r["id"] and r["text"]), key=lambda r: r["id"]):
            p = r["text"].strip()
            if p not in out:
                out.append(p)
        return out

    def resolve(self, tok):
        if tok in (None, "-"):
            return None
        m = re.match(r"^F(\d+)$", tok)
        return self.by_id.get(int(m.group(1))) if m else tok.strip()

    def resolve_list(self, s):
        if s in (None, "-"):
            return []
        return [p for p in (self.resolve(t) for t in s.split(",") if t) if p is not None]


# ---------------------------------------------------------------------------
# Semantic layer: records -> artifact (per kind)
# ---------------------------------------------------------------------------

EARS = {"ubiq": "ubiquitous", "event": "event", "state": "state", "unwanted": "unwanted", "opt": "optional"}
PRIORITY = {"must": "must-have", "should": "should-have", "could": "nice-to-have"}
SEVERITY = {"high": "high", "med": "medium", "low": "low"}
MODEL = {"general": "general", "thinking": "thinking", "fast": "fast"}
COMPLEXITY = {k: k for k in ("trivial", "simple", "moderate", "complex")}
RESEARCH_CX = {"low": "low", "high": "high"}
VERDICT = {"pass": "pass", "fail": "fail"}
PHASES = ["research", "requirements", "design", "review", "planning"]
EARS_RE = re.compile(r"^\s*((?:WHEN|WHILE|IF|WHERE)\b.*?),\s*(?:THEN\s+)?((?:\S+\s+){1,4}SHALL\b.*)$", re.I | re.S)
COMPREHENSIVE = ("arch", "pat", "tech", "test", "dep", "risk")


def enum(tok, table):
    if tok is None:
        return None
    t = tok.lower()
    for short, long in table.items():
        if t in (short, long.lower()):
            return long
    return None


def boolean(tok, default):
    if tok is None:
        return default
    t = tok.lower()
    if t in ("y", "yes", "true", "1", "met"):
        return True
    if t in ("n", "no", "false", "0", "unmet"):
        return False
    return default


def integer(tok):
    m = re.match(r"^-?\d+", tok or "")
    return int(m.group(0)) if m else None


def req_id(tok):
    if tok is None:
        return None
    if re.match(r"^R\d+$", tok, re.I):
        return "FR-" + tok[1:]
    if re.match(r"^N\d+$", tok, re.I):
        return "NFR-" + tok[1:]
    return tok.upper()


def op_index(tok):
    m = re.match(r"^O?(\d+)$", tok, re.I)
    return int(m.group(1)) - 1 if m else None


def ref_list(s, fn):
    if s in (None, "-"):
        return []
    return [v for v in (fn(t) for t in s.split(",") if t) if v is not None]


def tagged(recs, tag):
    return [r for r in recs if r["tag"] == tag]


def last(recs, tag):
    rs = tagged(recs, tag)
    return rs[-1] if rs else None


def text(recs, tag):
    r = last(recs, tag)
    return r["text"] if r else None


def texts(recs, tag):
    return [r["text"] for r in tagged(recs, tag) if r["text"] is not None]


def head(recs, tag):
    r = last(recs, tag)
    return r["head"] if r else []


def head1(recs, tag):
    h = head(recs, tag)
    return h[0] if h else None


def pad(lst, n):
    return (list(lst) + [None] * n)[:n]


def file_refs(recs, files):
    lst = head1(recs, "files")
    return files.declared(recs) if lst is None else files.resolve_list(lst)


def requirement(prefix, r, pattern):
    desc = r["text"] or ""
    m = EARS_RE.match(desc)
    trigger, response = (m.group(1).strip(), m.group(2).rstrip(".")) if m else (None, desc.rstrip("."))
    return {
        "id": "%s-%d" % (prefix, r["id"]),
        "description": desc,
        "ears_pattern": enum(pattern, EARS) or "ubiquitous",
        "trigger": trigger,
        "response": response,
        "acceptance_criteria": texts(r["props"], "ac"),
    }


def decode_triage(recs, files):
    files.absorb(recs)
    bug = last(recs, "bug")
    skip = head1(recs, "skip")
    skip = [] if skip in (None, "-") else [s.lower() for s in skip.split(",") if s]
    return {
        "complexity": enum(head1(recs, "cx"), COMPLEXITY),
        "goal_restatement": text(recs, "goal") or "",
        "external_context": text(recs, "ext") or "",
        "target_files": file_refs(recs, files),
        "bug_reproducible": boolean(bug["head"][0] if bug and bug["head"] else None, True),
        "bug_evidence": (bug["text"] if bug else None) or "",
        "skip_flags": {"skip_" + p: p in skip for p in PHASES},
        "reasoning": text(recs, "why") or "",
    }


def decode_research(recs, files):
    files.absorb(recs)
    out = {
        "key_files": file_refs(recs, files),
        "external_context": text(recs, "ext") or "",
        "complexity": enum(head1(recs, "cx"), RESEARCH_CX) or "low",
        "triage_reasoning": text(recs, "why") or "",
    }
    if any(r["tag"] in COMPREHENSIVE for r in recs):
        out.update({
            "architecture": text(recs, "arch") or "",
            "patterns": texts(recs, "pat"),
            "tech_stack": texts(recs, "tech"),
            "test_setup": text(recs, "test") or "",
            "dependencies": texts(recs, "dep"),
            "risks": texts(recs, "risk"),
        })
    return out


def decode_requirements(recs, files):
    frs = []
    for r in tagged(recs, "R"):
        pattern, priority = pad(r["head"], 2)
        fr = requirement("FR", r, pattern)
        fr["priority"] = enum(priority, PRIORITY) or "must-have"
        frs.append(fr)
    nfrs = [requirement("NFR", r, pad(r["head"], 1)[0]) for r in tagged(recs, "N")]
    return {
        "title": text(recs, "title") or "",
        "functional_requirements": frs,
        "non_functional": nfrs,
        "constraints": texts(recs, "con"),
        "out_of_scope": texts(recs, "out"),
    }


def decode_design(recs, files):
    files.absorb(recs)
    comps = tagged(recs, "C")
    names = {c["id"]: c["text"] or "C%d" % c["id"] for c in comps}

    def cname(tok):
        if tok in (None, "-"):
            return ""
        m = re.match(r"^C(\d+)$", tok, re.I)
        return names.get(int(m.group(1)), tok) if m else tok

    return {
        "components": [
            {
                "name": c["text"] or "C%d" % c["id"],
                "description": text(c["props"], "desc") or "",
                "files": files.resolve_list(pad(c["head"], 1)[0]),
                "interfaces": texts(c["props"], "if"),
            }
            for c in comps
        ],
        "requirement_mapping": [
            {"req_id": req_id(pad(m["head"], 2)[0]), "component": cname(pad(m["head"], 2)[1]), "approach": m["text"] or ""}
            for m in tagged(recs, "M")
        ],
        "dependencies": [
            {"from": cname(pad(d["head"], 2)[0]), "to": cname(pad(d["head"], 2)[1])} for d in tagged(recs, "D")
        ],
        "risks": texts(recs, "K"),
    }


def decode_review(recs, files):
    out = {
        "approved": boolean(head1(recs, "ok"), False),
        "coverage": [
            {"req_id": req_id(pad(c["head"], 2)[0]), "covered": boolean(pad(c["head"], 2)[1], True), "gap": c["text"]}
            for c in tagged(recs, "cov")
        ],
        "issues": [
            {
                "severity": enum(pad(i["head"], 1)[0], SEVERITY) or "medium",
                "description": i["text"] or "",
                "suggestion": text(i["props"], "fix") or "",
            }
            for i in tagged(recs, "I")
        ],
        "risk_assessment": text(recs, "risk") or "",
    }
    sel = head1(recs, "sel")
    if sel:
        out["selected_design"] = sel
    return out


def decode_plan(recs, files):
    files.absorb(recs)
    ops = []
    for o in tagged(recs, "O"):
        p = o["props"]
        ops.append({
            "title": o["text"] or "",
            "description": text(p, "do") or "",
            "target_files": files.resolve_list(head1(p, "f")),
            "acceptance_criteria": texts(p, "ac"),
            "requirement_ids": ref_list(head1(p, "r"), req_id),
            "depends_on_indices": ref_list(head1(p, "dep"), op_index),
            "model_recommendation": enum(pad(o["head"], 1)[0], MODEL) or "general",
        })
    return ops


def decode_validation(recs, files):
    met = []
    for v in tagged(recs, "V"):
        req, m = pad(v["head"], 2)
        entry = {"req_id": req_id(req), "met": boolean(m, False), "evidence": v["text"] or ""}
        rebut = text(v["props"], "rebut")
        if rebut:
            entry["rebuttal"] = rebut
        met.append(entry)
    return {
        "requirements_met": met,
        "uncovered_requirements": ref_list(head1(recs, "unc"), req_id),
        "gaps": texts(recs, "gap"),
        "overall_verdict": enum(head1(recs, "verdict"), VERDICT) or "fail",
        "summary": text(recs, "sum") or "",
    }


def decode_scoring(recs, files):
    def dim(tag):
        r = last(recs, tag)
        return {"score": integer(r["head"][0]) if r and r["head"] else None, "notes": (r["text"] if r else None) or ""}

    overall, grade = pad(head(recs, "overall"), 2)
    return {
        "final_output": dim("out"),
        "trajectory": dim("traj"),
        "tool_usage": dim("tool"),
        "safety_alignment": dim("safe"),
        "overall_score": integer(overall),
        "grade": grade,
        "summary": text(recs, "sum") or "",
    }


DECODERS = {
    "triage": decode_triage,
    "research": decode_research,
    "requirements": decode_requirements,
    "design": decode_design,
    "review": decode_review,
    "plan": decode_plan,
    "planning": decode_plan,
    "validation": decode_validation,
    "scoring": decode_scoring,
}


def decode(text, kind, files=None):
    """Decode Wire text (bare or fenced) for `kind` into the JSON-shaped artifact."""
    kind = "plan" if kind == "planning" else kind
    body = extract(text)
    if body is None:
        raise ValueError("no Wire document found")
    _, records = parse(body, HEADS.get(kind, {}))
    if not records:
        raise ValueError("empty Wire document")
    return DECODERS[kind](records, files or Files())


def files_in(prompt):
    """The file table a prompt declared: only the fence headed `%wire 1 files`
    counts, so example F lines in the output card never shadow it."""
    files = Files()
    for body in FENCE_RE.findall(prompt):
        header, records = parse(body, {})
        if header and header.get("kind") == "files":
            files.absorb(records)
    return files


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] not in DECODERS:
        sys.exit(__doc__)
    kind, ctx = args[0], None
    if "--files" in args:
        i = args.index("--files")
        ctx = files_in(open(args[i + 1]).read())
        del args[i:i + 2]
    src = open(args[1]).read() if len(args) > 1 else sys.stdin.read()
    print(json.dumps(decode(src, kind, ctx), indent=2, ensure_ascii=False))
