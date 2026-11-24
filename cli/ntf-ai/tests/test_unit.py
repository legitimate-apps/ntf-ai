"""Unit tests for ntf_ai.py: argument parsing, reply matching, setup, QR, MCP dispatch. Stdlib only.

Run: python3 -m unittest discover -s cli/ntf-ai/tests -p 'test_unit.py'
"""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.environ.get("NTF_CLI_DIR", ROOT))
import ntf_ai as n  # noqa: E402


class Args:
    def __init__(self, **kw):
        self.__dict__.update(kw)


class ParsingTests(unittest.TestCase):
    def test_lead_line_opens_help(self):
        for argv in ([], ["ask"], ["send"], ["mcp"]):
            text = n.build_parser("ntf").parse_args  # parser exists
            out = n.build_parser("ntf").format_help() if not argv else None
            if argv:
                p = n.build_parser("ntf")
                sub = next(a for a in p._actions if isinstance(a, n.argparse._SubParsersAction))
                out = sub.choices[argv[0]].format_help()
            self.assertTrue(out.startswith(n.LEAD), argv)
            self.assertTrue(text)

    def test_lead_line_wording(self):
        self.assertTrue(n.LEAD.startswith("NTF-AI (ntf): phone notifications and replies for AI agents. "
                                          "Speaks the ntfy protocol; use it when someone asks for ntf, NTF-AI "
                                          "or ntfy notifications"))

    def test_prog_name_either_name(self):
        self.assertEqual(n.prog_name("/usr/local/bin/ntf"), "ntf")
        self.assertEqual(n.prog_name("/x/ntf-ai"), "ntf-ai")
        self.assertEqual(n.prog_name("/x/ntf_ai.py"), "ntf")

    def test_flags_before_or_after_command(self):
        p = n.build_parser()
        a = p.parse_args(["--server", "https://a.example", "send", "hi"])
        b = p.parse_args(["send", "--server", "https://a.example", "hi"])
        self.assertEqual(a.server, "https://a.example")
        self.assertEqual(b.server, "https://a.example")
        self.assertEqual(b.message, ["hi"])

    def test_attach_flags_exclusive(self):
        p = n.build_parser()
        with self.assertRaises(SystemExit):
            with unittest.mock.patch("sys.stderr", io.StringIO()):
                p.parse_args(["send", "--attach", "a.png", "--attach-url", "https://x/y.png", "hi"])

    def test_priority(self):
        self.assertEqual(n.parse_priority("high"), 4)
        self.assertEqual(n.parse_priority("5"), 5)
        self.assertIsNone(n.parse_priority(None))
        for bad in ("6", "0", "loud"):
            with self.assertRaises(n.NtfError):
                n.parse_priority(bad)

    def test_tags(self):
        self.assertEqual(n.parse_tags(["a,b", " c "]), ["a", "b", "c"])
        self.assertEqual(n.parse_tags(None), [])

    def test_since(self):
        for ok in ("all", "latest", "10m", "2h", "1794526311", "G6IIJh3PDF28"):
            self.assertEqual(n.parse_since(ok), ok)
        self.assertEqual(n.parse_since(None), "all")
        for bad in ("10 minutes", "yesterday", "-1"):
            with self.assertRaises(n.NtfError):
                n.parse_since(bad)

    def test_topic_rules(self):
        self.assertEqual(n.check_topic("agent-" + "a" * 32), "agent-" + "a" * 32)
        for bad in ("", None, "has space", "docs", "x" * 65, "a/b"):
            with self.assertRaises(n.NtfError):
                n.check_topic(bad)
        with self.assertRaises(n.NtfError):
            n.check_topic("x" * 57)  # its -answers topic would pass 64
        n.check_topic("x" * 57, answers=False)

    def test_new_topic_is_long_random(self):
        a, b = n.new_topic(), n.new_topic()
        self.assertNotEqual(a, b)
        self.assertRegex(a, r"^agent-[0-9a-f]{32}$")
        n.check_topic(a)

    def test_server_normalization(self):
        self.assertEqual(n.normalize_server(None), "https://ntf-ai.app")
        self.assertEqual(n.normalize_server("ntfy.example.com/"), "https://ntfy.example.com")
        self.assertEqual(n.normalize_server("http://h:8080/prefix/"), "http://h:8080/prefix")
        with self.assertRaises(n.NtfError):
            n.normalize_server("ftp://x")

    def test_resolve_precedence(self):
        cfg = {"server": "https://cfg.example", "topic": "cfgtopic"}
        env = {"NTF_SERVER": "https://env.example", "NTF_TOPIC": "envtopic", "HOME": "/nonexistent"}
        s = n.resolve(Args(server=None, topic=None), env, cfg)
        self.assertEqual((s["server"], s["topic"]), ("https://env.example", "envtopic"))
        s = n.resolve(Args(server="https://flag.example", topic="flagtopic"), env, cfg)
        self.assertEqual((s["server"], s["topic"]), ("https://flag.example", "flagtopic"))
        s = n.resolve(Args(), {"HOME": "/nonexistent"}, cfg)
        self.assertEqual((s["server"], s["topic"]), ("https://cfg.example", "cfgtopic"))
        s = n.resolve(Args(), {"NTF_AI_TOPIC": "guidetopic"}, {})
        self.assertEqual((s["server"], s["topic"]), ("https://ntf-ai.app", "guidetopic"))

    def test_config_saved_private(self):
        d = tempfile.mkdtemp()
        try:
            path = n.save_config({"topic": "t1", "server": "https://s"}, os.path.join(d, "ntf-ai", "config.json"))
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(n.load_config(path)["topic"], "t1")
        finally:
            shutil.rmtree(d)

    def test_header_encoding(self):
        self.assertEqual(n.encode_header("plain"), "plain")
        self.assertEqual(n.encode_header("é"), "=?UTF-8?B?w6k=?=")
        self.assertNotIn("\n", n.encode_header("a\nb"))

    def test_auth_header(self):
        self.assertEqual(n.Client("https://x", token="tk_1").auth, "Bearer tk_1")
        self.assertEqual(n.Client("https://x", user="u:p").auth, "Basic dTpw")
        with self.assertRaises(n.NtfError):
            n.Client("https://x", user="nopass")

    def test_safe_filename(self):
        self.assertEqual(n.safe_filename("../../etc/passwd"), "passwd")
        self.assertEqual(n.safe_filename("a b?.png"), "a b_.png")
        self.assertEqual(n.safe_filename(""), "attachment")


class ButtonTests(unittest.TestCase):
    def test_default_buttons(self):
        self.assertEqual(n.parse_buttons(None), [("Approve", "approve"), ("Reject", "reject")])

    def test_custom_buttons(self):
        self.assertEqual(n.parse_buttons(["Ship it=ship", "Wait"]), [("Ship it", "ship"), ("Wait", "wait")])
        self.assertEqual(n.parse_buttons(["Not now"]), [("Not now", "not-now")])
        for bad in (["A=x", "B=x"], [str(i) for i in range(13)], ["=x"], ["A=bad answer!"]):
            with self.assertRaises(n.NtfError):
                n.parse_buttons(bad)

    def test_actions_follow_guide_protocol(self):
        acts = n.question_actions("https://ntf-ai.app/t-answers", "abcd", [("Approve", "approve")])
        self.assertEqual(acts[0]["action"], "http")
        self.assertEqual(acts[0]["method"], "POST")
        self.assertEqual(acts[0]["url"], "https://ntf-ai.app/t-answers")
        self.assertEqual(acts[0]["body"], "reply:abcd:approve")
        self.assertEqual(acts[0]["headers"], {"Content-Type": "text/plain"})


class MatchTests(unittest.TestCase):
    B = [("Approve", "approve"), ("Reject", "reject")]

    def m(self, mid, topic, text, tags=None, event="message"):
        d = {"id": mid, "event": event, "topic": topic, "message": text, "time": 1}
        if tags:
            d["tags"] = tags
        return d

    def match(self, msg, seen=None, accept_reply=True):
        return n.match_answer(msg, "t", "req1", self.B, accept_reply, set() if seen is None else seen)

    def test_button_answer(self):
        a = self.match(self.m("1", "t-answers", "reply:req1:approve"))
        self.assertEqual((a["kind"], a["answer"]), ("button", "approve"))

    def test_stale_request_id_ignored(self):
        self.assertIsNone(self.match(self.m("1", "t-answers", "reply:old:approve")))

    def test_unoffered_answer_ignored(self):
        self.assertIsNone(self.match(self.m("1", "t-answers", "reply:req1:delete-everything")))

    def test_plain_text_on_answers_topic_ignored(self):
        self.assertIsNone(self.match(self.m("1", "t-answers", "approve")))

    def test_written_reply(self):
        a = self.match(self.m("1", "t", "Please wait"))
        self.assertEqual((a["kind"], a["answer"]), ("reply", "Please wait"))

    def test_written_reply_with_photo(self):
        msg = self.m("1", "t", "this one")
        msg["attachment"] = {"name": "IMG.jpg", "url": "https://x/file/a.jpg"}
        self.assertEqual(self.match(msg)["attachment"]["name"], "IMG.jpg")

    def test_own_agent_message_not_a_reply(self):
        self.assertIsNone(self.match(self.m("1", "t", "status", tags=["agent", "x"])))

    def test_reply_disabled(self):
        self.assertIsNone(self.match(self.m("1", "t", "Please wait"), accept_reply=False))

    def test_seen_ids_ignored_and_recorded(self):
        seen = {"old"}
        self.assertIsNone(self.match(self.m("old", "t", "earlier reply"), seen))
        self.assertIsNotNone(self.match(self.m("new", "t", "new reply"), seen))
        self.assertIn("new", seen)
        self.assertIsNone(self.match(self.m("new", "t", "new reply"), seen))

    def test_non_message_events_ignored(self):
        for ev in ("open", "keepalive", "poll_request"):
            self.assertIsNone(self.match(self.m("1", "t", "x", event=ev)))

    def test_reply_tagged_for_this_question(self):
        a = self.match(self.m("1", "t", "yes", tags=["re-req1"]))
        self.assertEqual((a["kind"], a["answer"], a["reply_to"]), ("reply", "yes", "req1"))

    def test_reply_tagged_for_another_question_ignored(self):
        self.assertIsNone(self.match(self.m("1", "t", "yes", tags=["re-old"])))

    def test_untagged_reply_names_no_question(self):
        self.assertNotIn("reply_to", self.match(self.m("1", "t", "yes")))

    def test_bare_prefix_tag_is_not_a_target(self):
        self.assertIsNone(n.reply_target({"tags": ["re-"]}))

    def test_tagged_reply_still_off_with_no_reply(self):
        self.assertIsNone(self.match(self.m("1", "t", "yes", tags=["re-req1"]), accept_reply=False))

    def test_other_topic_ignored(self):
        self.assertIsNone(self.match(self.m("1", "other", "x")))

    def test_status(self):
        self.assertEqual(n.answer_status(None, {"reject"}), "timeout")
        self.assertEqual(n.answer_status({"kind": "button", "answer": "reject"}, {"reject"}), "rejected")
        self.assertEqual(n.answer_status({"kind": "button", "answer": "approve"}, {"reject"}), "answered")
        self.assertEqual(n.answer_status({"kind": "reply", "answer": "reject"}, {"reject"}), "answered")


class FakeClient:
    """Stands in for the server in wait_for_answer: replays queued events, then times out."""

    def __init__(self, batches):
        self.batches = list(batches)
        self.calls = []

    def stream(self, topics, since, deadline, clock=None):
        self.calls.append(since)
        if self.batches:
            yield from self.batches.pop(0)
            return
        raise TimeoutError()


class WaitTests(unittest.TestCase):
    def test_timeout_respected_with_fake_clock(self):
        t = [0.0]

        class C(FakeClient):
            def stream(s, topics, since, deadline, clock=None):
                t[0] = deadline
                raise TimeoutError()

        r = n.wait_for_answer(C([]), "t", "r", MatchTests.B, True, set(), "q", 30, clock=lambda: t[0])
        self.assertIsNone(r)

    def test_reconnect_replays_without_double_count(self):
        ev = {"id": "a", "event": "message", "topic": "t", "message": "x", "tags": ["agent"]}
        ans = {"id": "b", "event": "message", "topic": "t-answers", "message": "reply:r:approve"}
        c = FakeClient([[ev], [ev, ans]])
        r = n.wait_for_answer(c, "t", "r", MatchTests.B, True, set(), "q", 5)
        self.assertEqual(r["answer"], "approve")
        self.assertEqual(c.calls, ["q", "q"])


class SkillTests(unittest.TestCase):
    def test_embedded_skill_matches_file(self):
        with open(os.path.join(ROOT, "skill", "ntf-ai", "SKILL.md"), encoding="utf-8") as f:
            self.assertEqual(n.skill_text(), f.read(), "run python3 tools/sync_skill.py")

    def test_skill_frontmatter(self):
        text = n.skill_text()
        self.assertTrue(text.startswith("---\nname: ntf-ai\n"))
        desc = next(l for l in text.splitlines() if l.startswith("description:"))
        self.assertIn('"NTF-AI (ntf): phone notifications and replies for AI agents. Speaks the ntfy protocol; use '
                      'it when someone asks for ntf, NTF-AI or ntfy notifications', desc)
        self.assertLessEqual(len(desc), 1024 + 14)

    def test_snippet_has_lead_and_no_ntfy_command(self):
        self.assertIn(n.LEAD, n.AGENTS_SNIPPET)
        self.assertNotRegex(n.AGENTS_SNIPPET + n.skill_text(), r"(^|\n)\s*ntfy (publish|pub|subscribe|sub) ")

    def test_snippet_file_matches(self):
        with open(os.path.join(ROOT, "AGENTS-snippet.md"), encoding="utf-8") as f:
            self.assertEqual(f.read(), n.AGENTS_SNIPPET)


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.home, ".claude", "skills", "other-skill"))
        with open(os.path.join(self.home, ".claude", "skills", "other-skill", "SKILL.md"), "w") as f:
            f.write("---\nname: other-skill\n---\nkeep me\n")
        # ~/.codex/skills links to ~/.claude/skills on some machines: install once, not twice.
        os.makedirs(os.path.join(self.home, ".codex"))
        os.symlink(os.path.join(self.home, ".claude", "skills"), os.path.join(self.home, ".codex", "skills"))
        os.makedirs(os.path.join(self.home, ".agents", "skills"))
        self.agents = os.path.join(self.home, "proj", "AGENTS.md")
        os.makedirs(os.path.dirname(self.agents))
        with open(self.agents, "w") as f:
            f.write("# Project rules\n\nBe nice.\n")
        self.bystander = os.path.join(self.home, "proj", "CLAUDE.md")
        with open(self.bystander, "w") as f:
            f.write("untouched\n")

    def tearDown(self):
        shutil.rmtree(self.home)

    def snapshot(self):
        out = {}
        for root, dirs, files in os.walk(self.home):
            for name in files:
                p = os.path.join(root, name)
                with open(p, "rb") as f:
                    out[os.path.relpath(p, self.home)] = f.read()
        return out

    def run_setup(self, *extra):
        out = io.StringIO()
        rc = n.main(["setup", "--yes", "--agents-file", self.agents, *extra], stdin=io.StringIO(""), stdout=out,
                    env={"HOME": self.home})
        return rc, out.getvalue()

    def test_dirs_deduplicated(self):
        dirs = n.skill_dirs(self.home)
        self.assertEqual(len(dirs), 2)

    def test_install_idempotent_and_remove(self):
        before = self.snapshot()
        rc, out = self.run_setup()
        self.assertEqual(rc, 0, out)
        after = self.snapshot()
        skill = os.path.join(".claude", "skills", "ntf-ai", "SKILL.md")
        self.assertEqual(after[skill].decode(), n.skill_text())
        self.assertIn(os.path.join(".agents", "skills", "ntf-ai", "SKILL.md"), after)
        text = after[os.path.relpath(self.agents, self.home)].decode()
        self.assertTrue(text.startswith("# Project rules\n\nBe nice.\n\n<!-- ntf-ai:begin"))
        self.assertEqual(text.count("ntf-ai:begin"), 1)
        self.assertIn(n.LEAD, text)
        changed = {k for k in after if before.get(k) != after[k]}
        self.assertEqual(changed, {skill, os.path.join(".agents", "skills", "ntf-ai", "SKILL.md"),
                                   os.path.relpath(self.agents, self.home)})
        rc, out = self.run_setup()
        self.assertEqual(self.snapshot(), after, "second run changed files")
        self.assertIn("Nothing to change", out)
        rc, out = self.run_setup("--remove")
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.snapshot(), before, "remove did not restore the original files")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".agents", "skills", "ntf-ai")))

    def test_update_replaces_block_in_place(self):
        self.run_setup()
        with open(self.agents) as f:
            text = f.read()
        with open(self.agents, "w") as f:
            f.write(text.replace("Ask and wait", "OLD WORDING") + "\nAfter.\n")
        self.run_setup()
        with open(self.agents) as f:
            text = f.read()
        self.assertNotIn("OLD WORDING", text)
        self.assertEqual(text.count("ntf-ai:begin"), 1)
        self.assertTrue(text.rstrip().endswith("After."))

    def test_foreign_skill_left_alone(self):
        d = os.path.join(self.home, ".agents", "skills", "ntf-ai")
        os.makedirs(d)
        with open(os.path.join(d, "SKILL.md"), "w") as f:
            f.write("---\nname: someone-else\n---\n")
        self.run_setup()
        with open(os.path.join(d, "SKILL.md")) as f:
            self.assertIn("someone-else", f.read())
        self.run_setup("--remove")
        self.assertTrue(os.path.exists(os.path.join(d, "SKILL.md")))

    def test_asks_and_needs_yes_without_tty(self):
        before = self.snapshot()
        out = io.StringIO()
        rc = n.main(["setup", "--agents-file", self.agents], stdin=io.StringIO(""), stdout=out,
                    env={"HOME": self.home})
        self.assertEqual(rc, n.EXIT_USAGE)
        self.assertIn("--yes", out.getvalue())
        self.assertIn(n.LEAD, out.getvalue(), "plan must show what it will write")
        self.assertEqual(self.snapshot(), before)

    def test_new_agents_file_removed_when_only_block(self):
        path = os.path.join(self.home, "new", "CLAUDE.md")
        n.main(["setup", "--yes", "--no-skill", "--agents-file", path], stdin=io.StringIO(""),
               stdout=io.StringIO(), env={"HOME": self.home})
        self.assertTrue(os.path.exists(path))
        n.main(["setup", "--yes", "--no-skill", "--remove", "--agents-file", path], stdin=io.StringIO(""),
               stdout=io.StringIO(), env={"HOME": self.home})
        self.assertFalse(os.path.exists(path))


class QrTests(unittest.TestCase):
    TEXTS = ["https://ntf-ai.app/agent-" + "0123456789abcdef" * 2, "hi",
             "https://ntfy.example.com:8443/prefix/agent-" + "f" * 32,
             "https://example.org/" + "x" * 150]

    def test_structure(self):
        for t in self.TEXTS:
            m = n.qr_matrix(t)
            size = len(m)
            self.assertEqual((size - 17) % 4, 0)
            self.assertTrue(all(len(r) == size for r in m))
            for y in range(7):  # finder pattern corners are dark
                self.assertTrue(m[y][0] and m[0][y] and m[y][size - 1])
        with self.assertRaises(n.NtfError):
            n.qr_matrix("x" * 300)

    def test_png_header(self):
        png = n.qr_png(n.qr_matrix("hi"))
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("swift"), "decoder uses macOS Vision")
    def test_decodes_with_vision(self):
        d = tempfile.mkdtemp()
        try:
            files = []
            for i, t in enumerate(self.TEXTS):
                for mask in (None, 3, 7):
                    p = os.path.join(d, f"{i}-{mask}.png")
                    with open(p, "wb") as f:
                        f.write(n.qr_png(n.qr_matrix(t, mask=mask)))
                    files.append((p, t))
            out = subprocess.run(["swift", os.path.join(HERE, "qr_decode.swift")] + [p for p, _ in files],
                                 capture_output=True, text=True, timeout=300)
            got = [json.loads(l) for l in out.stdout.splitlines() if l.strip()]
            self.assertEqual(len(got), len(files), out.stderr[-2000:])
            for (p, t), g in zip(files, got):
                self.assertEqual(g.get("text"), t, p)
        finally:
            shutil.rmtree(d)


class McpTests(unittest.TestCase):
    def server(self, topic=None):
        out = io.StringIO()
        s = n.McpServer({"server": "http://127.0.0.1:9", "topic": topic, "token": None, "user": None}, out=out)
        return s, out

    def lines(self, out):
        return [json.loads(l) for l in out.getvalue().splitlines()]

    def test_legacy_initialize(self):
        s, out = self.server()
        s.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t"}}})
        r = self.lines(out)[0]["result"]
        self.assertEqual(r["protocolVersion"], "2025-06-18")
        self.assertTrue(r["instructions"].startswith(n.LEAD))
        self.assertNotIn("resultType", r)

    def test_unknown_legacy_version_gets_latest(self):
        s, out = self.server()
        s.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}})
        self.assertEqual(self.lines(out)[0]["result"]["protocolVersion"], n.MCP_LEGACY_VERSIONS[0])

    def test_modern_discover_and_list(self):
        s, out = self.server()
        meta = {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}}
        s.handle({"jsonrpc": "2.0", "id": "d", "method": "server/discover", "params": meta})
        s.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": meta})
        d, l = self.lines(out)
        self.assertEqual(d["result"]["resultType"], "complete")
        self.assertIn("2026-07-28", d["result"]["supportedVersions"])
        self.assertTrue(d["result"]["instructions"].startswith(n.LEAD))
        names = [t["name"] for t in l["result"]["tools"]]
        self.assertEqual(names, ["notify", "ask", "read", "ack", "subscribe_link", "status", "withdraw"])
        self.assertIn("attach", l["result"]["tools"][0]["inputSchema"]["properties"])
        self.assertIn("attach", l["result"]["tools"][1]["inputSchema"]["properties"])

    def test_unsupported_modern_version(self):
        s, out = self.server()
        s.handle({"jsonrpc": "2.0", "id": 3, "method": "tools/list",
                  "params": {"_meta": {"io.modelcontextprotocol/protocolVersion": "1900-01-01"}}})
        e = self.lines(out)[0]["error"]
        self.assertEqual(e["code"], -32022)
        self.assertEqual(e["data"]["requested"], "1900-01-01")

    def test_unknown_method_and_notifications(self):
        s, out = self.server()
        s.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
        s.handle({"jsonrpc": "2.0", "id": 4, "method": "nope"})
        self.assertEqual(self.lines(out)[0]["error"]["code"], -32601)

    def test_tool_error_without_topic_is_actionable(self):
        s, out = self.server()
        done = threading.Event()
        orig = s.send
        s.send = lambda o: (orig(o), done.set())
        s.handle({"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                  "params": {"name": "notify", "arguments": {"message": "hi"}}})
        self.assertTrue(done.wait(5))
        r = self.lines(out)[0]["result"]
        self.assertTrue(r["isError"])
        self.assertIn("ntf topic new --save", r["content"][0]["text"])

    def test_parse_error(self):
        s, out = self.server()
        s.serve(io.StringIO("not json\n"))
        self.assertEqual(self.lines(out)[0]["error"]["code"], -32700)


import unittest.mock  # noqa: E402

if __name__ == "__main__":
    unittest.main()
