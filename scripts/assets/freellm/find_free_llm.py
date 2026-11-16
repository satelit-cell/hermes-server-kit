#!/usr/bin/env python3
"""Find free LLMs across known sources.

Sources:
  mnfst    - mnfst/awesome-free-llm-apis data.json (curated, permanent free tiers, docs-linked)
  freellm  - open-free-llm-api/awesome-freellm-apis status.json (provider status, daily)
  modelsdev - https://models.dev/api.json, text models with cost 0/0 (limits unknown)
  openrouter - live https://openrouter.ai/api/v1/models, pricing prompt=completion=0
  github   - (--repos) search of GitHub for new free-LLM lists/gateways, existence-checked

Usage:
  find_free_llm.py [-q QUERY] [--min-context 128] [--provider NAME] [--json] [--repos]
Examples:
  find_free_llm.py -q qwen --min-context 128
  find_free_llm.py --provider groq
  find_free_llm.py --repos
"""
import argparse, json, re, sys, urllib.parse, urllib.request

UA = {"User-Agent": "find-free-llm"}
GH = "https://raw.githubusercontent.com/"


def get(url):
    return json.loads(urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30).read().decode())


def ctx_k(s):
    """'128K' / '1M' / 1048576 -> thousands of tokens (None if unknown)."""
    if s is None: return None
    if isinstance(s, (int, float)): return int(s // 1000)
    m = re.match(r"\s*([\d.]+)\s*([KMkm]?)", str(s))
    if not m: return None
    v = float(m.group(1)); u = m.group(2).lower()
    return int(v * (1000 if u == "m" else 1 if u == "k" else 0.001))


def from_mnfst():
    d = get(GH + "mnfst/awesome-free-llm-apis/main/data.json")
    for p in d["providers"]:
        for m in p["models"]:
            if m.get("id"):
                yield dict(source="mnfst", provider=p["name"], model=m["id"], context_k=ctx_k(m.get("context")),
                           limit=m.get("rateLimit", ""), modality=m.get("modality", ""), base_url=p["baseUrl"], key_url=p["url"])


def from_freellm():
    d = get(GH + "open-free-llm-api/awesome-freellm-apis/main/status.json")
    for p in d["providers"]:
        yield dict(source="freellm", provider=p["provider"], model=f"({p['free_models_count']} free models)",
                   context_k=ctx_k(p.get("max_context")), limit=p.get("tagline", ""), modality=p["status"],
                   base_url=p.get("base_url", ""), key_url=p.get("api_key_url", ""))


def from_openrouter():
    for m in get("https://openrouter.ai/api/v1/models")["data"]:
        pr = m.get("pricing", {})
        if str(pr.get("prompt")) == "0" and str(pr.get("completion")) == "0":
            yield dict(source="openrouter", provider="OpenRouter", model=m["id"], context_k=ctx_k(m.get("context_length")),
                       limit="free (50 RPD w/o credits)", modality=m.get("architecture", {}).get("modality", ""),
                       base_url="https://openrouter.ai/api/v1", key_url="https://openrouter.ai/keys")


def from_modelsdev():
    """models.dev: text models whose list cost is 0/0. NOTE: not proof of a free tier (no limits, may be promo)."""
    for pid, p in get("https://models.dev/api.json").items():
        for m in p.get("models", {}).values():
            c = m.get("cost") or {}
            if m.get("type") or c.get("input") != 0 or c.get("output") != 0:
                continue
            flags = ",".join(k for k in ("reasoning", "tool_call") if m.get(k))
            yield dict(source="modelsdev", provider=p.get("name", pid), model=m["id"], context_k=ctx_k((m.get("limit") or {}).get("context")),
                       limit=("cost 0 - SUBSCRIPTION plan, not free" if re.search(r"plan|subscription", p.get("name", pid), re.I) else "cost 0 (limits unknown)"), modality=flags, base_url=p.get("api", ""), key_url=p.get("doc", ""),
                       tools=bool(m.get("tool_call")), reasoning=bool(m.get("reasoning")))


def repos():
    seen = {}
    for q in ["free llm api", "freellmapi", "free llm gateway openai-compatible", "awesome free inference"]:
        u = "https://api.github.com/search/repositories?" + urllib.parse.urlencode({"q": q, "sort": "stars", "per_page": 8})
        for i in get(u)["items"]:
            seen[i["full_name"]] = i
    # drop clone spam: identical descriptions repeated
    desc = {}
    for i in seen.values(): desc.setdefault((i["description"] or "")[:60], []).append(i)
    out = [i for g in desc.values() if len(g) < 3 for i in g]
    return sorted(out, key=lambda i: -i["stargazers_count"])


def main():
    a = argparse.ArgumentParser()
    a.add_argument("-q", "--query", help="substring in model/provider (regex ok)")
    a.add_argument("--min-context", type=int, default=0, help="thousand tokens")
    a.add_argument("--provider")
    a.add_argument("--tools", action="store_true", help="only models.dev rows with tool calling")
    a.add_argument("--reasoning", action="store_true", help="only models.dev rows with reasoning")
    a.add_argument("--json", action="store_true")
    a.add_argument("--repos", action="store_true", help="list GitHub projects instead")
    a = a.parse_args()
    if a.repos:
        for i in repos()[:20]:
            print(f"{i['stargazers_count']:>6}  {i['pushed_at'][:10]}  {i['full_name']}  {(i['description'] or '')[:80]}")
        return
    rows, errs = [], []
    for name, fn in (("mnfst", from_mnfst), ("freellm", from_freellm), ("openrouter", from_openrouter), ("modelsdev", from_modelsdev)):
        try: rows += list(fn())
        except Exception as e: errs.append(f"{name}: {e}")
    if a.query: rows = [r for r in rows if re.search(a.query, r["model"] + " " + r["provider"], re.I)]
    if a.tools: rows = [r for r in rows if r.get("tools")]
    if a.reasoning: rows = [r for r in rows if r.get("reasoning")]
    if a.provider: rows = [r for r in rows if a.provider.lower() in r["provider"].lower()]
    if a.min_context: rows = [r for r in rows if (r["context_k"] or 0) >= a.min_context]
    rows.sort(key=lambda r: (r["provider"], r["model"]))
    if a.json: print(json.dumps(rows, ensure_ascii=False, indent=1))
    else:
        for r in rows:
            c = f"{r['context_k']}K" if r["context_k"] else "?"
            print(f"[{r['source']:<10}] {r['provider']:<22} {r['model'][:48]:<48} ctx={c:<7} {r['limit'][:50]}")
        print(f"\n{len(rows)} rows" + (f"; source errors: {errs}" if errs else ""))
    if errs and not rows: sys.exit(1)


if __name__ == "__main__":
    main()
