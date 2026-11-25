import json
import os
import urllib.error
import urllib.request
from urllib.parse import quote, urlsplit

SIMS4_GAME_ID = 78062
CF_BASE = "https://api.curseforge.com"
ALLOWED_HOSTS = ("edge.forgecdn.net", "mediafilez.forgecdn.net")
MAX_QUERY = 100


class RelayError(RuntimeError):
    pass


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


def _env(name):
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(name + " is not set")
    return value


def _cf_get(path):
    status, payload = http(
        "GET",
        CF_BASE + path,
        {"x-api-key": _env("SMH_CF_API_KEY"), "Accept": "application/json"},
        None,
    )
    if status != 200 or not isinstance(payload, dict) or not isinstance(payload.get("data"), (dict, list)):
        raise RuntimeError("CurseForge request failed")
    return payload["data"]


def _relay(action, **args):
    body = {"token": _env("SMH_AGENT_TOKEN"), "action": action}
    body.update(args)
    status, payload = http(
        "POST",
        _env("SMH_RELAY_URL"),
        None,
        body,
    )
    if not isinstance(payload, dict) or not payload.get("ok"):
        error = payload.get("error") if isinstance(payload, dict) else None
        raise RelayError(error or "relay call failed")
    return payload


def _pick_file(mod):
    files = mod.get("latestFiles") or []
    main_id = mod.get("mainFileId")
    for item in files:
        if item.get("id") == main_id:
            return item
    return files[0] if files else None


def _is_installable(mod, file):
    return bool(
        mod.get("gameId") == SIMS4_GAME_ID
        and mod.get("allowModDistribution")
        and file
        and file.get("downloadUrl")
    )


def _allowed_url(url):
    if not isinstance(url, str):
        return False
    try:
        parts = urlsplit(url)
        host = parts.hostname
    except ValueError:
        return False
    return parts.scheme == "https" and host in ALLOWED_HOSTS


def _requested_by(value):
    text = (value or "").strip().lower()
    return text if text in ("child", "parent") else "child"


def search_sims_mods(query):
    text = (query or "").strip()
    if not text:
        return []
    text = text[:MAX_QUERY]
    data = _cf_get(
        "/v1/mods/search?gameId=%d&searchFilter=%s&pageSize=5"
        % (SIMS4_GAME_ID, quote(text, safe=""))
    )
    results = []
    for mod in data if isinstance(data, list) else []:
        file = _pick_file(mod)
        authors = [a.get("name") for a in (mod.get("authors") or []) if a.get("name")]
        results.append(
            {
                "projectId": mod.get("id"),
                "name": mod.get("name"),
                "author": ", ".join(authors),
                "pageUrl": (mod.get("links") or {}).get("websiteUrl"),
                "latestFileId": file.get("id") if file else None,
                "installable": _is_installable(mod, file),
            }
        )
    return results


def queue_install(project_id, file_id, requested_by):
    project_id = int(project_id)
    file_id = int(file_id)
    if project_id <= 0 or file_id <= 0:
        raise ValueError("project_id and file_id must be positive integers")
    try:
        mod = _cf_get("/v1/mods/%d" % project_id)
    except Exception:
        return {"queued": False, "reason": "couldn't download it, will need a retry"}
    if mod.get("gameId") != SIMS4_GAME_ID:
        return {"queued": False, "reason": "that isn't a Sims 4 mod"}
    if not mod.get("allowModDistribution"):
        return {"queued": False, "reason": "creator doesn't allow outside downloads"}
    try:
        file = _cf_get("/v1/mods/%d/files/%d" % (project_id, file_id))
    except Exception:
        return {"queued": False, "reason": "couldn't download it, will need a retry"}
    if not file.get("downloadUrl"):
        return {"queued": False, "reason": "creator doesn't allow outside downloads"}
    if not _allowed_url(file.get("downloadUrl")):
        return {"queued": False, "reason": "download wasn't from CurseForge"}
    try:
        payload = _relay(
            "queue_install",
            projectId=project_id,
            fileId=file_id,
            modName=mod.get("name") or "",
            requestedBy=_requested_by(requested_by),
        )
    except RelayError:
        return {"queued": False, "reason": "couldn't queue it, will need a retry"}
    return {"queued": True, "id": payload.get("id")}


def queue_uninstall(project_id, requested_by):
    project_id = int(project_id)
    if project_id <= 0:
        raise ValueError("project_id must be a positive integer")
    try:
        rows = _relay("installed").get("rows") or []
    except RelayError:
        return {"queued": False, "reason": "couldn't check the installed list, will need a retry"}
    match = None
    for row in rows:
        if row.get("projectId") == project_id and row.get("status") == "installed":
            match = row
            break
    if match is None:
        return {"queued": False, "reason": "that mod isn't installed"}
    try:
        payload = _relay(
            "queue_uninstall",
            projectId=project_id,
            modName=match.get("modName") or "",
            requestedBy=_requested_by(requested_by),
        )
    except RelayError:
        return {"queued": False, "reason": "couldn't queue it, will need a retry"}
    return {"queued": True, "id": payload.get("id")}


def list_installs():
    rows = _relay("installed").get("rows") or []
    keys = ("projectId", "modName", "status", "reason", "updatedAt")
    return [{key: row.get(key) for key in keys} for row in rows]
