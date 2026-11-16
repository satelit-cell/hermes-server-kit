#!/usr/bin/env python3
"""Live-probe every provider whose key is in ~/.hermes/.env: list models, then ONE real chat call.
Prints status codes only - never key values. Run: python3 -I probe_providers.py [name ...]
Edit PROVIDERS (name, env var, OpenAI-compatible base URL, preferred free model ids).
"""
import json, os, re, sys, urllib.error, urllib.request

PROVIDERS = [
    ("Gemini", "GEMINI_API_KEY", "https://generativelanguage.googleapis.com/v1beta/openai", ["gemma-4-31b-it", "gemini-3.6-flash"]),
    ("Z.ai", "GLM_API_KEY", "https://api.z.ai/api/paas/v4", ["glm-4.5-flash", "glm-5.3-flash"]),
    ("ModelScope", "MODELSCOPE_API_KEY", "https://api-inference.modelscope.cn/v1", ["Qwen/Qwen3.5-35B-A3B"]),
    ("LLM7", "LLM7_API_KEY", "https://api.llm7.io/v1", ["gpt-oss:20b"]),
    ("Kilo", "KILOCODE_API_KEY", "https://api.kilo.ai/api/gateway", ["nvidia/nemotron-3-ultra-550b-a55b:free"]),
    ("SenseNova", "SENSENOVA_API_KEY", "https://token.sensenova.ai/v1", ["sensenova-6.8-flash-lite"]),
    ("AIHubMix", "AIHUBMIX_API_KEY", "https://aihubmix.com/v1", ["coding-glm-5.3-free"]),
    ("NVIDIA", "NVIDIA_API_KEY", "https://integrate.api.nvidia.com/v1", ["openai/gpt-oss-20b"]),
    ("OpenRouter", "OPENROUTER_API_KEY", "https://openrouter.ai/api/v1", []),
    ("Groq", "GROQ_API_KEY", "https://api.groq.com/openai/v1", ["openai/gpt-oss-120b"]),
    ("Cerebras", "CEREBRAS_API_KEY", "https://api.cerebras.ai/v1", ["gpt-oss-120b"]),
]
# Cloudflare: base = https://api.cloudflare.com/client/v4/accounts/<account_id>/ai/v1 (account_id is in
# the Hermes config.yaml `providers:` block); model e.g. @cf/openai/gpt-oss-120b. /models returns 405 - ignore.


def load_env():
    env = dict(os.environ)
    for line in open(os.path.expanduser("~/.hermes/.env")):
        m = re.match(r"\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$", line)
        if m:
            env.setdefault(m.group(1), m.group(2).strip("'\""))
    return env


def call(url, key, body=None, timeout=60):
    h = {"Authorization": "Bearer " + key, "User-Agent": "curl/8.5", "Content-Type": "application/json"}
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, data=body, headers=h), timeout=timeout)
        return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:160]
    except Exception as e:
        return 0, str(e)[:80]


def main():
    env, only = load_env(), {a.lower() for a in sys.argv[1:]}
    for name, var, base, prefer in PROVIDERS:
        if only and name.lower() not in only:
            continue
        key = env.get(var)
        if not key:
            print(f"{name:11} no key"); continue
        s, b = call(base + "/models", key)
        ids = []
        if s == 200:
            try:
                d = json.loads(b); d = d.get("data", d) if isinstance(d, dict) else d
                ids = [(m.get("id") or m.get("name") or "").replace("models/", "") for m in d]
            except Exception:
                pass
        cand = [m for m in prefer if m in ids] or [i for i in ids if re.search("free", i, re.I)][:1] or prefer[:1]
        out = []
        for m in cand[:2]:
            s2, b2 = call(base + "/chat/completions", key, json.dumps(
                {"model": m, "messages": [{"role": "user", "content": "Reply with one word: ok"}], "max_tokens": 200}).encode())
            out.append(f"{m} -> {s2} " + ("" if s2 == 200 else b2[:90].replace("\n", " ")))
        print(f"{name:11} models={s} n={len(ids)} | " + " | ".join(out))


if __name__ == "__main__":
    main()
