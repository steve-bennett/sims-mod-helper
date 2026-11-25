import ast
import contextlib
import io
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import notifier
import smh_core

RELAY_URL = "https://relay.example.test/exec"
PARENT_ID = "4242"


class FakeHTTP:
    def __init__(self):
        self.calls = []
        self.search = []
        self.mods = {}
        self.files = {}
        self.relay = {}
        self.fail = set()

    def __call__(self, method, url, headers, body):
        self.calls.append({"method": method, "url": url, "headers": headers, "body": body})
        if url.startswith("https://api.curseforge.com/v1/mods/search"):
            return 200, {"data": self.search}
        if "/files/" in url:
            project_id, file_id = url.split("/v1/mods/")[1].split("/files/")
            return 200, {"data": self.files[(int(project_id), int(file_id))]}
        if url.startswith("https://api.curseforge.com/v1/mods/"):
            return 200, {"data": self.mods[int(url.rsplit("/", 1)[1])]}
        action = body["action"]
        if action in self.fail:
            return 200, {"ok": False, "error": "not allowed"}
        payload = {"ok": True}
        payload.update(self.relay.get(action, {}))
        return 200, payload

    def relay_calls(self):
        return [call["body"] for call in self.calls if call["url"] == RELAY_URL]


def make_mod(
    project_id=111,
    name="Nice Hair",
    game_id=78062,
    allow=True,
    file_id=9001,
    url="https://edge.forgecdn.net/files/9001/x.zip",
    author="Alex",
):
    return {
        "id": project_id,
        "name": name,
        "gameId": game_id,
        "allowModDistribution": allow,
        "authors": [{"name": author}],
        "links": {"websiteUrl": "https://www.curseforge.com/sims4/mods/%d" % project_id},
        "mainFileId": file_id,
        "latestFiles": [{"id": file_id, "downloadUrl": url}],
    }


class CoreTests(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(
            os.environ,
            {
                "SMH_CF_API_KEY": "key",
                "SMH_RELAY_URL": RELAY_URL,
                "SMH_AGENT_TOKEN": "token",
            },
        )
        self.env.start()
        self.addCleanup(self.env.stop)
        self.fake = FakeHTTP()
        original = smh_core.http
        smh_core.http = self.fake
        self.addCleanup(setattr, smh_core, "http", original)

    def load_mod(self, mod):
        self.fake.mods[mod["id"]] = mod
        for item in mod["latestFiles"]:
            self.fake.files[(mod["id"], item["id"])] = item

    def installed_rows(self):
        return [
            {
                "id": "a",
                "projectId": 111,
                "modName": "Nice Hair",
                "status": "installed",
                "reason": "",
                "updatedAt": "2026-01-01T00:00:00Z",
            },
            {
                "id": "b",
                "projectId": 222,
                "modName": "Bad Hair",
                "status": "blocked",
                "reason": "it contained a program file (.exe)",
                "updatedAt": "2026-01-02T00:00:00Z",
            },
        ]

    def test_search_flags_installable_and_not(self):
        self.fake.search = [make_mod(111, "Nice Hair"), make_mod(222, "Bad Hair", allow=False)]
        results = smh_core.search_sims_mods("hair")
        self.assertEqual(len(results), 2)
        self.assertTrue(results[0]["installable"])
        self.assertFalse(results[1]["installable"])
        self.assertEqual(results[0]["projectId"], 111)
        self.assertEqual(results[0]["latestFileId"], 9001)
        self.assertEqual(results[0]["author"], "Alex")
        self.assertEqual(results[0]["pageUrl"], "https://www.curseforge.com/sims4/mods/111")
        url = self.fake.calls[0]["url"]
        self.assertIn("gameId=78062", url)
        self.assertIn("pageSize=5", url)

    def test_search_empty_query_makes_no_call(self):
        self.assertEqual(smh_core.search_sims_mods("   "), [])
        self.assertEqual(self.fake.calls, [])

    def test_search_query_trimmed_and_capped(self):
        self.fake.search = []
        smh_core.search_sims_mods("  " + "a" * 150)
        url = self.fake.calls[0]["url"]
        self.assertIn("a" * 100, url)
        self.assertNotIn("a" * 101, url)

    def test_queue_install_refuses_wrong_game(self):
        mod = make_mod(111, game_id=12345)
        self.load_mod(mod)
        result = smh_core.queue_install(111, 9001, "child")
        self.assertEqual(result, {"queued": False, "reason": "that isn't a Sims 4 mod"})
        self.assertEqual(self.fake.relay_calls(), [])

    def test_queue_install_refuses_no_distribution(self):
        mod = make_mod(111, allow=False)
        self.load_mod(mod)
        result = smh_core.queue_install(111, 9001, "child")
        self.assertEqual(result, {"queued": False, "reason": "creator doesn't allow outside downloads"})
        self.assertEqual(self.fake.relay_calls(), [])

    def test_queue_install_refuses_evil_host(self):
        mod = make_mod(111, url="https://evil.example.com/x.zip")
        self.load_mod(mod)
        result = smh_core.queue_install(111, 9001, "child")
        self.assertEqual(result, {"queued": False, "reason": "download wasn't from CurseForge"})
        self.assertEqual(self.fake.relay_calls(), [])

    def test_queue_install_uses_curseforge_name(self):
        mod = make_mod(111, name="CurseForge Name")
        self.load_mod(mod)
        self.fake.relay["queue_install"] = {"id": "row-1"}
        agent_supplied = "Agent Made This Up"
        result = smh_core.queue_install(111, 9001, "child")
        self.assertEqual(result, {"queued": True, "id": "row-1"})
        call = self.fake.relay_calls()[-1]
        self.assertEqual(call["action"], "queue_install")
        self.assertEqual(call["modName"], "CurseForge Name")
        self.assertNotEqual(call["modName"], agent_supplied)
        self.assertEqual(call["projectId"], 111)
        self.assertEqual(call["fileId"], 9001)
        self.assertEqual(call["requestedBy"], "child")

    def test_requested_by_mallory_is_child(self):
        mod = make_mod(111)
        self.load_mod(mod)
        self.fake.relay["queue_install"] = {"id": "row-2"}
        result = smh_core.queue_install(111, 9001, "mallory")
        self.assertTrue(result["queued"])
        self.assertEqual(self.fake.relay_calls()[-1]["requestedBy"], "child")

    def test_queue_uninstall_refuses_not_installed(self):
        self.fake.relay["installed"] = {"rows": self.installed_rows()}
        result = smh_core.queue_uninstall(333, "child")
        self.assertEqual(result, {"queued": False, "reason": "that mod isn't installed"})
        self.assertEqual([call["action"] for call in self.fake.relay_calls()], ["installed"])

    def test_queue_uninstall_queues_installed(self):
        self.fake.relay["installed"] = {"rows": self.installed_rows()}
        self.fake.relay["queue_uninstall"] = {"id": "row-9"}
        result = smh_core.queue_uninstall(111, "parent")
        self.assertEqual(result, {"queued": True, "id": "row-9"})
        call = self.fake.relay_calls()[-1]
        self.assertEqual(call["action"], "queue_uninstall")
        self.assertEqual(call["projectId"], 111)
        self.assertEqual(call["modName"], "Nice Hair")
        self.assertEqual(call["requestedBy"], "parent")

    def test_list_installs_includes_project_id(self):
        self.fake.relay["installed"] = {"rows": self.installed_rows()}
        rows = smh_core.list_installs()
        self.assertEqual(
            set(rows[0]), {"projectId", "modName", "status", "reason", "updatedAt"}
        )
        self.assertEqual(rows[0]["projectId"], 111)
        self.assertEqual(rows[1]["status"], "blocked")


class NotifierTests(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(
            os.environ,
            {
                "SMH_RELAY_URL": RELAY_URL,
                "SMH_AGENT_TOKEN": "token",
                "SMH_PARENT_DISCORD_ID": PARENT_ID,
            },
        )
        self.env.start()
        self.addCleanup(self.env.stop)
        original = notifier.http
        self.addCleanup(setattr, notifier, "http", original)

    def row(self, rid, name, status, reason=""):
        return {"id": rid, "modName": name, "status": status, "reason": reason}

    def run_notifier(self, rows, mark_ok=True):
        fake = FakeHTTP()
        fake.relay["unnotified"] = {"rows": rows}
        if not mark_ok:
            fake.fail.add("mark_notified")
        notifier.http = fake
        out = io.StringIO()
        err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = notifier.main()
        return code, out.getvalue(), fake

    def test_notifier_silent_on_empty_queue(self):
        code, out, fake = self.run_notifier([])
        self.assertEqual(code, 0)
        self.assertEqual(out, '{"wakeAgent": false}\n')

    def test_notifier_message_format(self):
        rows = [
            self.row("1", "A", "installed"),
            self.row("2", "B", "installed"),
            self.row("3", "C", "blocked", "it contained a program file (.exe)"),
            self.row("4", "D", "failed", "couldn't download it, will need a retry"),
            self.row("5", "E", "uninstalled"),
        ]
        code, out, fake = self.run_notifier(rows)
        self.assertEqual(code, 0)
        self.assertIn("\u2705 Installed: A, B. Restart the game to see them.", out)
        self.assertIn("\u26d4 Blocked: C (it contained a program file (.exe)).", out)
        self.assertIn(
            "\u26a0\ufe0f Couldn't install: D (couldn't download it, will need a retry).", out
        )
        self.assertIn("\U0001f5d1\ufe0f Removed: E.", out)

    def test_notifier_mentions_parent_only_for_blocked_or_failed(self):
        code, out, fake = self.run_notifier([self.row("1", "Nice Hair", "installed")])
        self.assertEqual(code, 0)
        self.assertNotIn("<@" + PARENT_ID + ">", out)
        self.assertEqual(fake.relay_calls()[-1]["ids"], ["1"])

        code, out, fake = self.run_notifier(
            [self.row("2", "Bad Hair", "blocked", "it contained a program file (.exe)")]
        )
        self.assertEqual(code, 0)
        self.assertIn("<@" + PARENT_ID + ">", out)

        code, out, fake = self.run_notifier(
            [self.row("3", "Broken Hair", "failed", "couldn't download it, will need a retry")]
        )
        self.assertEqual(code, 0)
        self.assertIn("<@" + PARENT_ID + ">", out)

        with mock.patch.dict(os.environ):
            os.environ.pop("SMH_PARENT_DISCORD_ID", None)
            code, out, fake = self.run_notifier(
                [self.row("4", "Bad Hair", "blocked", "it contained a program file (.exe)")]
            )
            self.assertEqual(code, 0)
            self.assertNotIn("<@", out)

    def test_notifier_exits_nonzero_when_mark_fails(self):
        code, out, fake = self.run_notifier(
            [self.row("1", "Nice Hair", "installed")], mark_ok=False
        )
        self.assertEqual(code, 1)
        self.assertIn("Nice Hair", out)

    def test_notifier_caps_at_1800_and_marks_printed_only(self):
        rows = []
        for index in range(20):
            status = ("installed", "blocked", "failed", "uninstalled")[index % 4]
            rows.append(
                self.row(str(index), "Mod %02d " % index + "x" * 90, status, "y" * 250)
            )
        code, out, fake = self.run_notifier(rows)
        self.assertEqual(code, 0)
        message = out.rstrip("\n")
        self.assertLessEqual(len(message), 1800)
        printed = [row for row in rows if row["modName"] in message]
        self.assertLess(len(printed), 20)
        self.assertEqual(fake.relay_calls()[-1]["ids"], [row["id"] for row in printed])

    def test_notifier_adds_switch_line(self):
        rows = [
            self.row(
                "1",
                "Nice Hair",
                "installed",
                "installed, but mods are switched off in the game settings",
            )
        ]
        code, out, fake = self.run_notifier(rows)
        self.assertEqual(code, 0)
        self.assertIn(notifier.SWITCH_LINE, out)

    def test_notifier_parses_under_python39(self):
        path = os.path.join(HERE, "notifier.py")
        with open(path, encoding="utf-8") as handle:
            ast.parse(handle.read(), feature_version=(3, 9))


if __name__ == "__main__":
    unittest.main()
