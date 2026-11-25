# Sims Mod Helper

A private family tool that lets a child ask a chat bot for The Sims 4 mods, and has them checked and installed on their PC, from CurseForge only.

The AI only finds mods. Fixed rules decide what gets downloaded, scanned and installed.

## How it works

```
child (Discord) -> bot (Hermes Agent + smh MCP tools) -> Google Sheet relay <- installer on the child's PC -> CurseForge API
```

- **Bot** (`agent/`): a [Hermes Agent](https://hermes-agent.nousresearch.com/) profile whose only tools are four MCP tools: search the CurseForge Sims 4 catalogue, queue an install, queue an uninstall, list installs. Every built-in toolset (shell, files, web, browser, code) is disabled. Pasted post text is treated as information, never instructions. A small cron script tells the child (and parent) the outcome.
- **Relay** (`relay/`): a Google Apps Script web app over one Sheet. The bot and the installer each have their own token; the bot can only queue and read, the installer can only read pending rows and report status. The Sheet holds identifiers and status words only.
- **Installer** (`installer/`): PowerShell 5.1, runs as the child's standard Windows account from the Startup folder, every 5 minutes.

Neither side connects to the other. Both connect out to the Sheet, so the bot's host never sees a mod file and the child's PC never reaches the bot's host.

## Installer rules

- Trusts only the CurseForge project and file ids in a row. Re-fetches everything from the CurseForge API; downloads only from `edge.forgecdn.net` / `mediafilez.forgecdn.net`, re-checked on every redirect.
- Skips any mod whose author has turned off third-party distribution.
- Downloads to a quarantine folder and scans with Microsoft Defender before unpacking. If the scan can't run, the mod is blocked (fails closed).
- Installs only `.package` (must start with `DBPF`) and `.ts4script` (must be a zip) files, flat into `Mods\SMH_<projectId>_<name>`. Any program or script file, nested archive, extensionless file or path-traversal entry blocks the whole mod.
- Never writes outside the Mods folder, its quarantine and its log. Never changes game settings; it reports when custom content or script mods are switched off.

## Setup

1. Relay: see `relay/README.md`.
2. Bot: see `agent/profile/DEPLOY.md`. Needs a CurseForge API key, a Discord bot in a private server, and the values in `agent/profile/env.example`.
3. Installer: on the child's PC, as the child, run `installer/install.ps1` and give it the relay URL, the installer token and the CurseForge key.

## Tests

```
node relay/test/relay.test.js
python -m unittest agent/test_smh.py
python agent/profile/check_profile.py agent/profile/config.yaml
powershell -NoProfile -ExecutionPolicy Bypass -File installer/test.ps1
```

## Not affiliated

Not affiliated with or endorsed by CurseForge, Overwolf, Electronic Arts or Maxis. Uses the CurseForge API under its terms.
