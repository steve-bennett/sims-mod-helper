#!/usr/bin/env python3
"""Checks the smh profile config. Usage: python check_profile.py config.yaml"""
import re
import sys

TOOLSETS = (
    "web browser terminal file code_execution vision video image_gen video_gen "
    "x_search tts stt skills todo kanban memory context_engine session_search "
    "connections clarify delegation cronjob yuanbao computer_use a2a"
).split()

TOKEN_KEY = re.compile(r"^\s*(?:SMH_|DISCORD_)[A-Z0-9_]+\s*:\s*(.*)$")
TOKEN_VALUE = re.compile(r"""["']?\$\{[A-Za-z0-9_]+\}["']?""")


def indent(line):
    return len(line) - len(line.lstrip(" "))


def block_after(lines, key):
    """First `key:` line and the lines nested under it."""
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("#") or not s.startswith(key + ":"):
            continue
        base = indent(line)
        if s[len(key) + 1:].strip():
            return base, []
        out = []
        for nxt in lines[i + 1:]:
            if not nxt.strip() or nxt.lstrip().startswith("#"):
                continue
            if indent(nxt) <= base:
                break
            out.append(nxt)
        return base, out
    return None, []


def is_token_value_ok(value):
    value = value.strip()
    if value in ("", "''", '""'):
        return True
    return bool(TOKEN_VALUE.fullmatch(value))


def main(argv):
    if len(argv) != 2:
        print("FAIL usage: check_profile.py config.yaml")
        return 1
    try:
        with open(argv[1], encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        print("FAIL cannot read %s: %s" % (argv[1], exc))
        return 1

    lines = text.splitlines()
    fails = []

    if not any(re.fullmatch(r"toolsets:\s*\[\]", line) for line in lines):
        fails.append("toolsets is not []")

    base, block = block_after(lines, "disabled_toolsets")
    if base is None:
        fails.append("no disabled_toolsets block")
    else:
        names = [ln.strip()[2:].strip().strip("'\"") for ln in block if ln.strip().startswith("- ")]
        missing = [t for t in TOOLSETS if t not in names]
        if missing:
            fails.append("disabled_toolsets missing: " + ", ".join(missing))

    base, block = block_after(lines, "mcp_servers")
    if base is None:
        fails.append("no mcp_servers block")
    else:
        child = indent(block[0]) if block else base + 2
        entries = [
            ln.strip()[:-1]
            for ln in block
            if indent(ln) == child and ln.strip().endswith(":") and not ln.strip().startswith("-")
        ]
        if entries != ["smh"]:
            fails.append("mcp_servers entries are %s, want exactly smh" % (entries or "none"))

    if "hermes-cli" in text:
        fails.append("hermes-cli appears in config")

    for key in ("allow_any_attachment", "trust_recent_files"):
        if not re.search(r"^\s*%s:\s*false\s*$" % key, text, re.MULTILINE):
            fails.append("%s is not false" % key)

    # 0 means unlimited in Hermes; 1 drops every document before download.
    if not re.search(r"^\s*max_attachment_bytes:\s*1\s*$", text, re.MULTILINE):
        fails.append("max_attachment_bytes is not 1")

    for number, line in enumerate(lines, 1):
        match = TOKEN_KEY.match(line)
        if match and not is_token_value_ok(match.group(1)):
            fails.append("line %d: literal token value" % number)

    if fails:
        for reason in fails:
            print("FAIL " + reason)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
