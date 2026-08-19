#!/bin/sh
# Logs Cursor turn start/end for AgentCord. Always fail-open.
raw=$(cat)
printf '{}'
printf '%s' "$raw" | python3 -c '
import json, os, sys, time
from datetime import datetime
raw = sys.stdin.read()
cut = raw.find("{")
if cut > 0:
    raw = raw[cut:]
try:
    payload = json.loads(raw)
except Exception:
    sys.exit(0)
ev = payload.get("hook_event_name") or payload.get("hookEventName") or ""
kind = {"beforeSubmitPrompt": "start", "stop": "end"}.get(ev)
if not kind:
    sys.exit(0)
ident = payload.get("conversation_id") or payload.get("conversationId") or ""
cwd = ""
roots = payload.get("workspace_roots") or []
if roots:
    cwd = str(roots[0])
ms = int(time.time() * 1000)
directory = os.environ.get("AGENTCORD_CURSOR_UPTIME_DIR") or os.path.join(
    os.environ.get("TMPDIR", "/tmp"), "AgentCord"
)
os.makedirs(directory, exist_ok=True)
day = datetime.now().strftime("%Y-%m-%d")
line = json.dumps({"e": kind, "ms": ms, "id": ident, "cwd": cwd}, separators=(",", ":"))
path = os.path.join(directory, "%s-uptime.json" % day)
with open(path, "a", encoding="utf-8") as handle:
    handle.write(line + "\n")
' >/dev/null 2>&1 || true
exit 0
