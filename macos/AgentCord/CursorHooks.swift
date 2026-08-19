//
//  CursorHooks.swift
//  AgentCord
//
//  Install Cursor user hooks once. Marker is agentcord-cursor-turn.sh.
//

import Foundation

enum CursorHooks {
    static let marker = "agentcord-cursor-turn.sh"
    static let hookCmd = "sh \"./hooks/agentcord-cursor-turn.sh\""
    private static let events = ["beforeSubmitPrompt", "stop"]

    static let script = #"""
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
"""#

    static func ensure() {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
        _ = ensure(in: home)
    }

    /// Returns true when hooks.json was rewritten.
    @discardableResult
    static func ensure(in cursorHome: URL) -> Bool {
        let fm = FileManager.default
        let hooksDir = cursorHome.appendingPathComponent("hooks", isDirectory: true)
        try? fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let scriptURL = hooksDir.appendingPathComponent(marker)
        let existing = (try? String(contentsOf: scriptURL, encoding: .utf8))
        if existing != script {
            try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        }

        let path = cursorHome.appendingPathComponent("hooks.json")
        var root: [String: Any]
        if let data = try? Data(contentsOf: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        } else {
            root = ["version": 1, "hooks": [String: Any]()]
        }
        if root["hooks"] as? [String: Any] == nil {
            root["hooks"] = [String: Any]()
        }
        if root["version"] == nil {
            root["version"] = 1
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false
        for event in events {
            changed = ensureEvent(&hooks, event: event) || changed
        }
        if changed {
            root["hooks"] = hooks
            if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: path, options: .atomic)
            }
        }
        return changed
    }

    static func isOurs(_ cmd: String) -> Bool {
        cmd.contains(marker)
    }

    private static func ensureEvent(_ hooks: inout [String: Any], event: String) -> Bool {
        let arr = hooks[event] as? [[String: Any]] ?? []
        let before = arr.count
        var kept = false
        var next: [[String: Any]] = []
        for item in arr {
            let cmd = item["command"] as? String ?? ""
            if !isOurs(cmd) {
                next.append(item)
                continue
            }
            if kept { continue }
            kept = true
            next.append(item)
        }
        var changed = next.count != before
        if !kept {
            next.append(["command": hookCmd, "timeout": 5])
            changed = true
        }
        if changed {
            hooks[event] = next
        }
        return changed
    }
}
