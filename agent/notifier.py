#!/usr/bin/env python3
"""Hermes no-agent cron script: posts finished queue rows to Discord."""

import json
import os
import sys
import urllib.error
import urllib.request

MAX_MESSAGE = 1800
SWITCH_LINE = (
    'To switch mods on: open the game \u2192 Game Options \u2192 Other \u2192 tick '
    '"Enable Custom Content and Mods" and "Script Mods Allowed", then restart the game.'
)


def http(method, url, headers, body):
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read().decode("utf-8") or "null")
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read().decode("utf-8"))
        except Exception:
            return exc.code, None
    except Exception:
        return 0, None


def relay(action, **args):
    url = os.environ.get("SMH_RELAY_URL")
    token = os.environ.get("SMH_AGENT_TOKEN")
    if not url or not token:
        raise RuntimeError("SMH_RELAY_URL and SMH_AGENT_TOKEN must be set")
    body = {"token": token, "action": action}
    body.update(args)
    status, payload = http("POST", url, None, body)
    if not isinstance(payload, dict) or not payload.get("ok"):
        error = payload.get("error") if isinstance(payload, dict) else None
        raise RuntimeError(error or "relay call failed")
    return payload


def _name(row):
    return row.get("modName") or "Unknown mod"


def _with_reason(row):
    reason = (row.get("reason") or "").strip()
    return _name(row) + (" (" + reason + ")" if reason else "")


def build_message(rows):
    groups = {"installed": [], "blocked": [], "failed": [], "uninstalled": []}
    for row in rows:
        groups[row.get("status")].append(row)

    lines = []
    if groups["installed"]:
        lines.append(
            "\u2705 Installed: "
            + ", ".join(_with_reason(row) for row in groups["installed"])
            + ". Restart the game to see them."
        )
    if groups["blocked"]:
        lines.append(
            "\u26d4 Blocked: " + ", ".join(_with_reason(row) for row in groups["blocked"]) + "."
        )
    if groups["failed"]:
        lines.append(
            "\u26a0\ufe0f Couldn't install: "
            + ", ".join(_with_reason(row) for row in groups["failed"])
            + "."
        )
    if groups["uninstalled"]:
        lines.append(
            "\U0001f5d1\ufe0f Removed: "
            + ", ".join(_name(row) for row in groups["uninstalled"])
            + "."
        )
    if any(
        row.get("status") == "installed" and "switched off" in (row.get("reason") or "").lower()
        for row in rows
    ):
        lines.append(SWITCH_LINE)
    if any(row.get("status") in ("blocked", "failed") for row in rows):
        parent = os.environ.get("SMH_PARENT_DISCORD_ID")
        if parent:
            lines.append("<@" + parent + ">")
    return "\n".join(lines)


def choose_rows(rows):
    included = []
    for row in rows:
        candidate = included + [row]
        if len(build_message(candidate)) > MAX_MESSAGE:
            break
        included = candidate
    return included


def main():
    try:
        payload = relay("unnotified")
    except Exception as exc:
        sys.stderr.write("notifier: " + str(exc) + "\n")
        return 1
    rows = [
        row
        for row in payload.get("rows") or []
        if row.get("status") in ("installed", "blocked", "failed", "uninstalled")
    ]
    if not rows:
        print('{"wakeAgent": false}')
        return 0
    included = choose_rows(rows)
    if not included:
        included = rows[:1]
    print(build_message(included))
    ids = [row.get("id") for row in included if row.get("id")]
    try:
        relay("mark_notified", ids=ids)
    except Exception as exc:
        sys.stderr.write("notifier: " + str(exc) + "\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
