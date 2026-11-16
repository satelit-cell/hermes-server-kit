#!/usr/bin/env python3
"""Daily snapshot of free models from models.dev and diff vs the previous snapshot.

Sources (each fails independently, a broken source never blocks the others):
  modelsdev   models.dev api.json, cost 0/0 text models (via research/models_free.py)
  mnfst       mnfst/awesome-free-llm-apis data.json (permanent free tiers, rate limits)
  openrouter  live openrouter.ai/api/v1/models, pricing 0/0
  freellm     open-free-llm-api status.json (provider status, free model counts)
  zackozack   free-models.zackozack.com/changelog (HTML; new entries since previous run)
Output:
  snapshots/free-YYYY-MM-DD.json   compact snapshot (one entry per provider/model)
  reports/diff-YYYY-MM-DD.md       what was added / removed / changed
Exit code: 0 no changes or first run, 10 changes found, 1 error.
Usage: python3 -I daily_free_diff.py [--providers a,b] [--keep 60] [--quiet]
"""
import argparse, datetime, html, json, re, sys, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "research"))
import models_free as mf  # noqa: E402

TRACK = ("context", "tool_call", "reasoning", "status", "cost_input", "cost_output")


def collect_modelsdev(providers):
    rows = list(mf.rows_from_api(mf.load_api_json(url=mf.API_URL)))
    rx = re.compile(mf.DEFAULT_EXCLUDE)
    keep = {p.strip() for p in providers.split(",")} if providers else None
    out = {}
    for r in rows:
        if not mf.is_free(r) or rx.search(r["provider"]):
            continue
        if r["type"] not in ("chat", "", None) or r["status"] == "deprecated":
            continue
        if keep and r["provider"] not in keep:
            continue
        out[f"{r['provider']}/{r['model_id']}"] = {k: r[k] for k in ("provider_name", "name", *TRACK)}
    return out


UA = {"User-Agent": "Mozilla/5.0 free-models-diff"}


def _get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=40).read().decode()


def collect_mnfst():
    d = json.loads(_get("https://raw.githubusercontent.com/mnfst/awesome-free-llm-apis/main/data.json"))
    return {f"{p['name']}/{m['id']}": {"context": m.get("context"), "rateLimit": m.get("rateLimit")}
            for p in d["providers"] for m in p["models"] if m.get("id")}


def collect_openrouter():
    d = json.loads(_get("https://openrouter.ai/api/v1/models"))["data"]
    return {m["id"]: {"context": m.get("context_length")} for m in d
            if str(m.get("pricing", {}).get("prompt")) == "0" and str(m.get("pricing", {}).get("completion")) == "0"}


def collect_freellm():
    d = json.loads(_get("https://raw.githubusercontent.com/open-free-llm-api/awesome-freellm-apis/main/status.json"))
    return {p["provider"]: {"status": p.get("status"), "free_models_count": p.get("free_models_count")} for p in d["providers"]}


def parse_zackozack():
    """[(day, +NEW/-DEL, provider, model)] from the server-rendered changelog."""
    h = _get(ZACK_URL)
    out = []
    parts = re.split(r'id="date-heading-(\d{4}-\d{2}-\d{2})"', h)
    last = lambda c: [t.strip() for t in re.findall(r">([^<>]+)<", ">" + c + "<") if t.strip()][-1]
    for i in range(1, len(parts), 2):
        for tr in re.findall(r'<tr[^>]*data-slot="table-row"[^>]*>(.*?)</tr>', parts[i + 1], re.S):
            tds = [html.unescape(last(c)) for c in re.findall(r"<td[^>]*>(.*?)</td>", tr, re.S)]
            if len(tds) >= 3:
                out.append((parts[i], tds[0], tds[1], tds[2]))
    return out


ZACK_URL = "https://free-models.zackozack.com/changelog"
SOURCES = {"modelsdev": None, "mnfst": collect_mnfst, "openrouter": collect_openrouter, "freellm": collect_freellm}


def diff(old, new):
    add = sorted(set(new) - set(old))
    rem = sorted(set(old) - set(new))
    chg = []
    for k in sorted(set(old) & set(new)):
        d = {f: (old[k].get(f), new[k].get(f)) for f in sorted(set(old[k]) | set(new[k])) if f not in ("name", "provider_name") and old[k].get(f) != new[k].get(f)}
        if d:
            chg.append((k, d))
    return add, rem, chg


def prov_of(key, src):
    return key.split("/", 1)[0] if src in ("modelsdev", "mnfst") else (key.split("/", 1)[0] if "/" in key else key)


def by_provider(keys, src):
    g = {}
    for k in keys:
        g.setdefault(prov_of(k, src), []).append(k.split("/", 1)[1] if "/" in k else k)
    return g


def section(src, old, new):
    add, rem, chg = diff(old, new)
    L = [f"## {src}: {len(old)} -> {len(new)}  (+{len(add)} / -{len(rem)} / ~{len(chg)})"]
    for title, keys in (("removed", rem), ("added", add)):
        if keys:
            L.append(f"**{title}:**")
            for p, ms in sorted(by_provider(keys, src).items()):
                L.append(f"- {p} ({len(ms)}): " + ", ".join(sorted(ms)[:10]) + (" ..." if len(ms) > 10 else ""))
    if chg:
        L.append("**changed:**")
        L += [f"- {k}: " + "; ".join(f"{f} {a} -> {b}" for f, (a, b) in d.items()) for k, d in chg[:40]]
    if not (add or rem or chg):
        L.append("no changes")
    gone = set(by_provider(old, src)) - set(by_provider(new, src))
    if gone:
        L.append(f"**providers with nothing left:** {', '.join(sorted(gone))}")
    return "\n".join(L), bool(add or rem or chg)


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def zack_section(entries, since, modelsdev_now):
    fresh = sorted({e for e in entries if e[0] > since})
    latest = max((e[0] for e in entries), default="n/a")
    L = [f"## zackozack changelog: {len(fresh)} entries after {since} (site latest day: {latest})"]
    if latest < since:
        L.append(f"WARNING: site data stops at {latest} - the changelog is stale")
    flat = {norm(k.split("/", 1)[1]): k for k in modelsdev_now}
    for day, kind, prov, model in sorted(fresh):
        mark = ""
        if kind.startswith("-") and norm(model) in flat:
            mark = f"  <- models.dev STILL lists it at $0 ({flat[norm(model)]}): price!=free tier"
        L.append(f"- {day} {kind} {prov}: {model}{mark}")
    return "\n".join(L), bool(fresh)


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--providers"); a.add_argument("--keep", type=int, default=60)
    a.add_argument("--quiet", action="store_true")
    a = a.parse_args()
    day = datetime.date.today().isoformat()
    snaps, reps = HERE / "snapshots", HERE / "reports"
    snaps.mkdir(exist_ok=True); reps.mkdir(exist_ok=True)

    new, errs = {}, []
    try:
        new["modelsdev"] = collect_modelsdev(a.providers)
        if len(new["modelsdev"]) < 20:
            raise RuntimeError(f"suspiciously small ({len(new['modelsdev'])})")
    except Exception as e:
        errs.append(f"modelsdev: {e}")
    for name, fn in SOURCES.items():
        if fn:
            try:
                new[name] = fn()
                if not new[name]:
                    raise RuntimeError("empty result")
            except Exception as e:
                errs.append(f"{name}: {e}")
    zack = []
    try:
        zack = parse_zackozack()
        if not zack:
            raise RuntimeError("no rows parsed (page layout changed?)")
    except Exception as e:
        errs.append(f"zackozack: {e}")
    if not new:
        print("all sources failed:", errs, file=sys.stderr); return 1

    prev = sorted(p for p in snaps.glob("free-*.json") if p.stem != f"free-{day}")
    old = {}
    if prev:
        old = json.loads(prev[-1].read_text(encoding="utf-8"))
        if "modelsdev" not in old and "mnfst" not in old:   # legacy flat snapshot
            old = {"modelsdev": old}
    prev_day = prev[-1].stem[5:] if prev else None
    # a failed source keeps its previous data so tomorrow's diff is not corrupted
    saved = {k: new.get(k, old.get(k, {})) for k in ("modelsdev", *[n for n in SOURCES if n != "modelsdev"])}
    (snaps / f"free-{day}.json").write_text(json.dumps(saved, ensure_ascii=False), encoding="utf-8")
    for f in sorted(snaps.glob("free-*.json"))[:-a.keep]:
        f.unlink()
    if not prev:
        print(f"first snapshot saved ({day}): " + ", ".join(f"{k}={len(v)}" for k, v in new.items()) + (f"; errors: {errs}" if errs else ""))
        return 0

    parts, changed = [f"# Free models diff {prev_day} -> {day}", ""], False
    for src in ("modelsdev", "mnfst", "openrouter", "freellm"):
        if src in new and old.get(src):
            txt, c = section(src, old[src], new[src]); changed |= c
            parts += [txt, ""]
        elif src in new:
            parts += [f"## {src}: first data ({len(new[src])}), nothing to compare", ""]
    if zack:
        txt, c = zack_section(zack, prev_day, new.get("modelsdev") or old.get("modelsdev", {}))
        changed |= c; parts += [txt, ""]
    if errs:
        parts += ["## Source errors", *[f"- {e}" for e in errs]]
        changed = True
    rep = "\n".join(parts) + "\n"
    (reps / f"diff-{day}.md").write_text(rep, encoding="utf-8")
    if not a.quiet or changed:
        print(rep)
    return 10 if changed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print("ERROR:", e, file=sys.stderr); sys.exit(1)
