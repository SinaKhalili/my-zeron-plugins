"""Read the selected coding account's quota through Zeron's local engine."""
from datetime import datetime
import importlib.util
import json
import math
from pathlib import Path
import sys
import time

# Keep interpreter caches out of the signed plugin's source tree.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("account_usage_ipc", Path(__file__).with_name("ipc.py"))
ipc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipc)

NAMES = {"codex": "Codex", "claude-code": "Claude", "cursor": "Cursor", "devin": "Devin", "grok": "Grok", "pi": "Pi", "hermes": "Hermes"}


def epoch(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, AttributeError):
        return None


def date_text(value):
    return datetime.fromtimestamp(value).astimezone().strftime("%a %H:%M") if value else None


def normalize(account, harness, now=None):
    now = time.time() if now is None else now
    fetched = account.get("usageFetchedAt")
    fetched = fetched / 1000 if isinstance(fetched, (int, float)) else None
    windows = []
    for window in account.get("usageWindows", []):
        used = window.get("usedFraction")
        if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used):
            continue
        reset = epoch(window.get("resetsAt"))
        label = window.get("label") or "Usage"
        windows.append({"label": label, "left": int(math.floor((1 - min(1, max(0, used))) * 100 + 0.5)),
                        "reset": reset, "resetText": date_text(reset)})
    stale = not fetched or now - fetched > 600 or bool(account.get("usageError"))
    stale = stale or any(w["reset"] and w["reset"] <= now for w in windows)
    return {"harness": harness, "name": NAMES.get(harness, harness), "plan": account.get("planLabel") or "",
            "windows": windows, "fetched": fetched, "updatedText": date_text(fetched), "stale": bool(stale),
            "note": (account.get("usageError") or "")[:160]}


def read_usage(args):
    selected = args.get("provider", "auto")
    harness = args.get("fallback") or "codex"
    target = None
    chat_id = args.get("chat")
    if chat_id:
        chats = ipc.EngineIPC().request("WatchChats", stream=True)
        chat = next((c for c in chats if c.get("id") == chat_id), None)
        if chat:
            config = chat.get("config") or {}
            harness = config.get("harness") or harness
            target = chat.get("deviceId")
    if selected != "auto":
        harness = selected
    params = {"forceUsage": bool(args.get("force"))}
    if target:
        params["targetDeviceId"] = target
    snapshot = ipc.EngineIPC().request("ListAgentAccounts", params)
    accounts = [a for a in snapshot.get("accounts", []) if a.get("harness") == harness and a.get("active")]
    if not accounts:
        return {"harness": harness, "name": NAMES.get(harness, harness), "windows": [], "note": "No signed-in account reported on this device."}
    if len(accounts) != 1:
        return {"harness": harness, "name": NAMES.get(harness, harness), "windows": [], "note": "Multiple active accounts reported; usage cannot be attributed to one account."}
    return normalize(accounts[0], harness)


if __name__ == "__main__":
    try:
        result = read_usage(json.load(sys.stdin))
    except Exception:
        result = {"error": "Usage unavailable", "windows": [], "note": "Could not read Zeron’s local account-usage feed."}
    print(json.dumps(result, ensure_ascii=False))
