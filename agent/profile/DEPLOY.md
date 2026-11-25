# Deploy the `smh` Hermes profile

Assumed CLI: `hermes profile create smh --empty`, plus `hermes -p smh cron create --no-agent --every 5m --script scripts/notifier.py --deliver discord` for the notifier. Check `--help` if the flags differ.

1. `hermes profile create smh --empty`
2. `cp config.yaml SOUL.md ~/.hermes/profiles/smh/`
3. In `~/.hermes/profiles/smh/config.yaml`, replace `HERMES_PYTHON` with the Hermes venv's python, `SMH_DIR` with this tool's checkout path, and `OLLAMA_HOST` and `FALLBACK_MODEL` with the fallback Ollama host and model (or delete the fallback).
4. In `~/.hermes/profiles/smh/SOUL.md`, replace `CHILD_NAME`, `PARENT_NAME` and `PARENT_DISCORD_ID` (the parent's Discord user id).
5. `cp env.example ~/.hermes/profiles/smh/.env` and fill every value.
6. `mkdir -p ~/.hermes/profiles/smh/scripts` and copy `notifier.py` alone into it.
7. `lsof -nP -iTCP -sTCP:LISTEN > ports.before` in a work directory that survives a reboot.
8. `hermes -p smh cron create` as a no-agent job, every 5 minutes, running `scripts/notifier.py`, delivering to the profile's Discord home channel.
9. Restart the gateway.
10. `lsof -nP -iTCP -sTCP:LISTEN > ports.after && diff ports.before ports.after` prints nothing.
11. `hermes -p smh tools list`: every built-in toolset shows disabled, and only `smh:*` tools are enabled.
