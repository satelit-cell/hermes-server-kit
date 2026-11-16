#!/usr/bin/env python3
"""
models_free.py — выгрузка всех моделей из каталога models.dev и отбор бесплатных.

Источник данных (один из трёх):
  1) по умолчанию   — скачивает https://models.dev/api.json
  2) --file PATH    — читает уже скачанный api.json
  3) --repo PATH    — читает git-клон https://github.com/sst/models.dev (TOML-файлы),
                      если сам сайт недоступен

Примеры:
  python3 models_free.py                                  # все модели -> models_all.csv
  python3 models_free.py --free                           # только $0 -> models_free.csv
  python3 models_free.py --free --providers groq,cerebras,nvidia,openrouter,cloudflare-workers-ai,mistral,zai,google
  python3 models_free.py --file api.json --free --json free.json
  python3 models_free.py --repo ./models.dev --free

Требования: Python 3.11+ (для --repo нужен встроенный tomllib). Внешних пакетов нет.
"""
import argparse
import csv
import json
import re
import sys
import urllib.request
from pathlib import Path

API_URL = "https://models.dev/api.json"

# Провайдеры, у которых цена $0 означает «входит в подписку», а не бесплатный API.
# Это эвристика по id провайдера — список можно поправить через --exclude.
DEFAULT_EXCLUDE = r"(coding-plan|token-plan|step-plan|code-plan|copilot|opencode-go|cline-pass|gitlab|lmstudio)"

FIELDS = [
    "provider", "provider_name", "model_id", "name", "canonical_model_id", "type",
    "cost_input", "cost_output", "context", "output", "tool_call", "reasoning",
    "open_weights", "status", "release_date", "last_updated", "api", "env",
]


# ---------- источник 1/2: api.json ----------

def load_api_json(url=None, file=None):
    if file:
        with open(file, encoding="utf-8") as f:
            return json.load(f)
    req = urllib.request.Request(url, headers={"User-Agent": "models-free-script/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def rows_from_api(data):
    for pid, p in data.items():
        if not isinstance(p, dict):
            continue
        for mid, m in (p.get("models") or {}).items():
            cost = m.get("cost") or {}
            limit = m.get("limit") or {}
            yield {
                "provider": pid,
                "provider_name": p.get("name", ""),
                "model_id": m.get("id", mid),
                "name": m.get("name", ""),
                "canonical_model_id": m.get("canonical_model_id", ""),
                "type": m.get("type", "chat"),
                "cost_input": cost.get("input"),
                "cost_output": cost.get("output"),
                "context": limit.get("context"),
                "output": limit.get("output"),
                "tool_call": m.get("tool_call"),
                "reasoning": m.get("reasoning"),
                "open_weights": m.get("open_weights"),
                "status": m.get("status", ""),
                "release_date": m.get("release_date", ""),
                "last_updated": m.get("last_updated", ""),
                "api": p.get("api", ""),
                "env": ",".join(p.get("env") or []),
            }


# ---------- источник 3: git-клон с TOML ----------

def deep_merge(base, over):
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def rows_from_repo(repo):
    import tomllib  # Python 3.11+

    repo = Path(repo)
    labs = {}
    for f in (repo / "models").rglob("*.toml"):
        rel = f.relative_to(repo / "models").with_suffix("").as_posix()  # lab/model
        try:
            labs[rel] = tomllib.loads(f.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"! пропущен {f}: {e}", file=sys.stderr)

    for pdir in sorted((repo / "providers").iterdir()):
        ptoml = pdir / "provider.toml"
        if not ptoml.exists():
            continue
        prov = tomllib.loads(ptoml.read_text(encoding="utf-8"))
        mdir = pdir / "models"
        if not mdir.exists():
            continue
        for f in sorted(mdir.rglob("*.toml")):
            mid = f.relative_to(mdir).with_suffix("").as_posix()
            try:
                m = tomllib.loads(f.read_text(encoding="utf-8"))
            except Exception as e:
                print(f"! пропущен {f}: {e}", file=sys.stderr)
                continue
            base = m.get("base_model")
            merged = deep_merge(labs.get(base, {}), m) if base else m
            caps = merged.get("capabilities") or {}
            cost = merged.get("cost") or {}
            ci = (cost.get("text") or {}).get("input") or {}
            co = (cost.get("text") or {}).get("output") or {}
            limit = merged.get("limit") or {}
            tools = caps.get("tools")
            reas = caps.get("reasoning")
            yield {
                "provider": pdir.name,
                "provider_name": prov.get("name", ""),
                "model_id": mid,
                "name": merged.get("name", ""),
                "canonical_model_id": base or "",
                "type": merged.get("type", "chat"),
                "cost_input": ci.get("price"),
                "cost_output": co.get("price"),
                "context": limit.get("context"),
                "output": limit.get("output"),
                "tool_call": tools.get("supported") if isinstance(tools, dict) else tools,
                "reasoning": reas.get("supported") if isinstance(reas, dict) else reas,
                "open_weights": merged.get("open_weights"),
                "status": merged.get("status", ""),
                "release_date": str(merged.get("release_date", "")),
                "last_updated": str(merged.get("last_updated", merged.get("release_date", ""))),
                "api": prov.get("api", ""),
                "env": ",".join(prov.get("env") or []),
            }


# ---------- фильтры и вывод ----------

def is_free(r):
    return r["cost_input"] == 0 and r["cost_output"] in (0, None)


def main():
    ap = argparse.ArgumentParser(description="Парсинг каталога models.dev")
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--url", default=API_URL, help="адрес api.json (по умолчанию models.dev)")
    src.add_argument("--file", help="локальный api.json")
    src.add_argument("--repo", help="путь к git-клону sst/models.dev")
    ap.add_argument("--free", action="store_true", help="только модели с ценой $0 на вход и выход")
    ap.add_argument("--providers", help="оставить только этих провайдеров (id через запятую)")
    ap.add_argument("--exclude", default=DEFAULT_EXCLUDE,
                    help="regex id провайдеров, которые отбросить при --free (подписки); '' — не отбрасывать")
    ap.add_argument("--chat-only", action="store_true", help="только текстовые чат-модели")
    ap.add_argument("--no-deprecated", action="store_true", help="убрать модели со status=deprecated")
    ap.add_argument("--csv", help="куда сохранить CSV (по умолчанию models_all.csv / models_free.csv)")
    ap.add_argument("--json", help="дополнительно сохранить в JSON")
    a = ap.parse_args()

    if a.repo:
        rows = list(rows_from_repo(a.repo))
    else:
        data = load_api_json(url=a.url, file=a.file)
        if not a.file:
            Path("api.json").write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
            print("api.json сохранён рядом со скриптом", file=sys.stderr)
        rows = list(rows_from_api(data))

    total = len(rows)
    if a.providers:
        keep = {p.strip() for p in a.providers.split(",") if p.strip()}
        rows = [r for r in rows if r["provider"] in keep]
    if a.free:
        rows = [r for r in rows if is_free(r)]
        if a.exclude:
            rx = re.compile(a.exclude)
            rows = [r for r in rows if not rx.search(r["provider"])]
    if a.chat_only:
        rows = [r for r in rows if r["type"] in ("chat", "", None)]
    if a.no_deprecated:
        rows = [r for r in rows if r["status"] != "deprecated"]

    rows.sort(key=lambda r: (r["provider"], str(r["release_date"])), reverse=False)

    out_csv = a.csv or ("models_free.csv" if a.free else "models_all.csv")
    with open(out_csv, "w", newline="", encoding="utf-8-sig") as f:  # utf-8-sig — чтобы Excel открыл кириллицу
        w = csv.DictWriter(f, fieldnames=FIELDS, delimiter=";")
        w.writeheader()
        w.writerows(rows)
    if a.json:
        Path(a.json).write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding="utf-8")

    provs = {}
    for r in rows:
        provs[r["provider"]] = provs.get(r["provider"], 0) + 1
    print(f"Всего моделей в каталоге: {total}; после фильтров: {len(rows)} у {len(provs)} провайдеров")
    for p, n in sorted(provs.items(), key=lambda x: -x[1])[:25]:
        print(f"  {p:32} {n}")
    print(f"CSV: {out_csv}" + (f"; JSON: {a.json}" if a.json else ""))


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:  # вывод обрезан через | head
        pass
