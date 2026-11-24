"""The docs agents read agree with the code (tools/check_docs.py), and the check can fail.

Run: python3 -m unittest discover -s cli/ntf-ai/tests -p 'test_docs.py'
The checked-in guide is always tested. NTF_AI_GUIDE=<site>/ntfyme-docs-src/agents.md overrides it and checks built pages; NTF_AI_APP_SRC=<app>/ntfy adds
the app's Waiting rule. With NTF_AI_GUIDE set, the guide's recipe also runs against NTF_E2E_SERVER, or a Docker ntfy
started as in test_e2e.
"""
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, HERE)
import check_docs  # noqa: E402

GUIDE = os.environ.get("NTF_AI_GUIDE", os.path.join(ROOT, "..", "..", "notes", "legs", "agent-v2-2026-11-15", "guide-patched", "agents.md"))
APP = os.environ.get("NTF_AI_APP_SRC")


def copy_cli(tmp):
    for rel in ("ntf_ai.py", "README.md", "AGENTS-snippet.md", os.path.join("skill", "ntf-ai", "SKILL.md")):
        os.makedirs(os.path.dirname(os.path.join(tmp, rel)), exist_ok=True)
        shutil.copy(os.path.join(ROOT, rel), os.path.join(tmp, rel))


def edit(path, old, new):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    assert s.count(old) >= 1, f"{old!r} not in {path}"
    with open(path, "w", encoding="utf-8") as f:
        f.write(s.replace(old, new, 1))


class DocsAgree(unittest.TestCase):
    def test_cli_surfaces_agree_with_the_code(self):
        self.assertEqual(check_docs.check(ROOT, app=APP), [])

    def test_v2_flags_and_version_documented(self):
        n = check_docs.load_cli(ROOT)
        texts = check_docs.cli_surfaces(n, ROOT)
        for name in ('SKILL.md', 'README.md', 'AGENTS-snippet.md'):
            for flag in ('--choice', '--multi', '--spec', '--expires', '--remind', '--escalate', '--as', '--avatar', '--strict'):
                with self.subTest(surface=name, flag=flag): self.assertIn(flag, texts[name])
            self.assertIn('0.4.0', texts[name])
        if GUIDE:
            guide = check_docs.brand(check_docs.read(GUIDE), GUIDE)
            self.assertIn('From NTF-AI 1.27 and ntf 0.4.0', guide)
            for word in ('#ask-v2', 'ntf status', 'ntf withdraw', 'agent_retention_seconds'):
                self.assertIn(word, guide)

    def test_encryption_sources_and_retention_are_documented(self):
        n = check_docs.load_cli(ROOT)
        texts = check_docs.cli_surfaces(n, ROOT)
        for name, text in texts.items():
            for term in ('--password-env', '--password-file', '--e2e-strict'):
                with self.subTest(surface=name, term=term): self.assertIn(term, text)
            self.assertNotIn('encryption is deferred', text)
        for name in ('SKILL.md', 'README.md', 'AGENTS-snippet.md'):
            self.assertIn('NTF_TOPIC_PASSWORD', texts[name])
            self.assertIn('8 days', texts[name])
        if GUIDE:
            text = check_docs.read(GUIDE)
            for term in ('--password-env', '--password-file', '--e2e-strict', '8 days', '12 hours'):
                self.assertIn(term, text)

    def test_041_authentication_rules_are_documented(self):
        n = check_docs.load_cli(ROOT)
        texts = check_docs.cli_surfaces(n, ROOT)
        if GUIDE:
            texts['guide'] = check_docs.read(GUIDE)
        for name, text in texts.items():
            if name in ('ntf ask --help',):
                continue
            with self.subTest(surface=name):
                self.assertIn('0.4.1', text)
                self.assertIn('re-<request id>', text)
                self.assertIn('0.4.2', text)
        for name in ('SKILL.md', 'README.md', 'AGENTS-snippet.md', 'ntf --help', 'guide'):
            if name in texts:
                with self.subTest(surface=name):
                    self.assertRegex(texts[name], r'exits 7|7 unauthenticated')
        if GUIDE:
            self.assertIn('**ntf 0.4.1:**', texts['guide'])
            self.assertIn('**ntf 0.4.2:**', texts['guide'])

    def test_retention_names_the_advertised_field(self):
        n = check_docs.load_cli(ROOT)
        texts = check_docs.cli_surfaces(n, ROOT)
        if GUIDE:
            texts['guide'] = check_docs.read(GUIDE)
        for name, text in texts.items():
            with self.subTest(surface=name):
                self.assertNotRegex(text, r'(?i)capabilities\s+(?:v2|version\s*2)\b')
        for name in ('SKILL.md', 'README.md', 'guide'):
            if name in texts:
                self.assertIn('agent_retention_seconds', texts[name])

    def test_multiselect_is_documented_as_a_choice_setting(self):
        n = check_docs.load_cli(ROOT)
        texts = check_docs.cli_surfaces(n, ROOT)
        if GUIDE:
            texts['guide'] = check_docs.read(GUIDE)
        for name in ('SKILL.md', 'README.md', 'guide'):
            if name in texts:
                with self.subTest(surface=name):
                    self.assertIn('"kind":"choice","multi":true', texts[name])
                    self.assertIn('`multi` is not a kind', texts[name])

    def test_050_images_and_files_are_documented(self):
        n = check_docs.load_cli(ROOT)
        texts = check_docs.cli_surfaces(n, ROOT)
        if GUIDE:
            texts['guide'] = check_docs.brand(check_docs.read(GUIDE), GUIDE)
        for name, text in texts.items():
            if name in ('ntf ask --help',):
                continue
            with self.subTest(surface=name):
                self.assertRegex(text, r'(?i)from NTF-AI 1\.32 and ntf 0\.5\.0')
                self.assertIn('5 MB', text)
        for name in ('SKILL.md', 'README.md', 'AGENTS-snippet.md', 'guide'):
            if name in texts:
                with self.subTest(surface=name):
                    self.assertIn('15 MB', texts[name])
                    self.assertRegex(texts[name], r'3 hours|3 h\b')
        if GUIDE:
            whats_new = texts['guide'].split("## What's new for agents", 1)[1]
            first_bullet = next(l for l in whats_new.splitlines() if l.strip().startswith('- '))
            self.assertIn('From NTF-AI 1.32 and ntf 0.5.0:', first_bullet)

    def test_guide_agrees_with_the_code(self):
        self.assertEqual(check_docs.check(ROOT, guide=GUIDE, app=APP), [])


class GuideRecipeRuns(unittest.TestCase):
    """Sections 1-5 of the guide, run as written against a real ntfy server."""

    @classmethod
    def setUpClass(cls):
        import test_e2e
        cls.e2e = test_e2e
        test_e2e.setUpModule()

    @classmethod
    def tearDownClass(cls):
        cls.e2e.tearDownModule()

    def test_recipe_matches_ntf_ask(self):
        n = check_docs.load_cli(ROOT)
        f = check_docs.facts_from_cli(n, ROOT)
        src = check_docs.brand(check_docs.read(GUIDE), GUIDE)
        self.assertEqual(check_docs.run_recipe(src, self.e2e.SERVER, n, f), [])

    def test_recipe_goes_red_when_the_settle_step_drifts(self):
        n = check_docs.load_cli(ROOT)
        f = check_docs.facts_from_cli(n, ROOT)
        src = check_docs.brand(check_docs.read(GUIDE), GUIDE).replace("    'priority': 1,\n", "", 1)
        errs = check_docs.run_recipe(src, self.e2e.SERVER, n, f)
        self.assertTrue(any("settle priority" in e for e in errs), errs)


class PlantedMismatches(unittest.TestCase):
    """Each planted drift, in the code or in a text, must turn the check red with a line that names it."""

    CODE = [  # (old, new in ntf_ai.py, expected fragment of the error)
        ('if len(out) > 12:', 'if len(out) > 13:', "the code allows 13"),
        ('len(options) <= 3 and not remind', 'len(options) <= 4 and not remind', "the code allows 4"),
        ('EXIT_OK, EXIT_ERROR, EXIT_USAGE, EXIT_REJECTED, EXIT_TIMEOUT = 0, 1, 2, 3, 4',
         'EXIT_OK, EXIT_ERROR, EXIT_USAGE, EXIT_REJECTED, EXIT_TIMEOUT = 0, 1, 2, 5, 4', "the code exits 5"),
        ('ANSWERS_SUFFIX = "-answers"', 'ANSWERS_SUFFIX = "-replies"', "answers topic"),
        ('"body": f"reply:{request_id}:{answer}"', '"body": f"answer:{request_id}:{answer}"', "button answer body"),
        ('return "\\u2713 Got your reply"', 'return "\\u2713 Read your reply"', "reply receipt line"),
        ('ACK_TAG = "ack"', 'ACK_TAG = "done"', "tagged `done`"),
        ('DEFAULT_ACK = "\\u2713 Got it"', 'DEFAULT_ACK = "\\u2713 OK"', "default receipt line"),
        ('{"name": "subscribe_link",', '{"name": "link",', "MCP tools"),
        ('sp.add_argument("--no-reply"', 'sp.add_argument("--buttons-only"', "--no-reply"),
        ('upd = client.publish(topic, body, title=title, priority=1,', 'upd = client.publish(topic, body, title=title, priority=2,',
         "priority 2"),
        ('REPLY_TAG_PREFIX = "re-"', 'REPLY_TAG_PREFIX = "rt-"', "rt-<request id>"),
        ('NO_REPLY_TAG = "no-reply"', 'NO_REPLY_TAG = "buttons-only"', "tagged `buttons-only`"),
        ('sp.add_argument("--timeout", type=float, default=600,', 'sp.add_argument("--timeout", type=float, default=900,',
         "defaults to 600"),
    ]
    TEXT = [  # (file, old, new, expected fragment)
        ("skill/ntf-ai/SKILL.md", "`3` rejected", "`5` rejected", "exit 5 means rejected"),
        ("README.md", "from NTF-AI 1.26, ", "", "1.26 behaviour without saying so"),
        ("skill/ntf-ai/SKILL.md", "clear (`PUT .../<request id>/clear`, a\n   `message_clear`)", "clear", "message_clear"),
        ("AGENTS-snippet.md", "without the `agent` tag", "without a tag", "without the `agent` tag"),
        ("skill/ntf-ai/SKILL.md", "tag; from NTF-AI 1.26 one\n   typed", "tag; one\n   typed", "1.26 behaviour without saying so"),
        ("README.md", "tagged\n`re-<sequence_id>`", "tagged\n`reply-<sequence_id>`", "writes the reply tag"),
    ]

    def run_planted(self, rel, old, new, sync=False):
        with tempfile.TemporaryDirectory() as tmp:
            copy_cli(tmp)
            edit(os.path.join(tmp, rel), old, new)
            return check_docs.check(tmp)

    def test_code_drift_goes_red(self):
        for old, new, fragment in self.CODE:
            with self.subTest(new=new):
                errs = self.run_planted("ntf_ai.py", old, new)
                self.assertTrue(any(fragment in e for e in errs), errs)

    def test_text_drift_goes_red(self):
        for rel, old, new, fragment in self.TEXT:
            with self.subTest(file=rel, new=new):
                errs = self.run_planted(rel, old, new)
                self.assertTrue(any(fragment in e for e in errs), errs)

    def test_app_tag_drift_goes_red(self):
        if not GUIDE:
            self.skipTest("needs NTF_AI_GUIDE")
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "Utils"))
            with open(os.path.join(tmp, "Utils", "AnswerLog.swift"), "w") as f:
                f.write('static let maxAge: TimeInterval = 3 * 24 * 60 * 60\n'
                        'enum AgentReply {\n    static let agentTag = "bot"\n}\n')
            errs = check_docs.check(ROOT, guide=GUIDE, app=tmp)
        self.assertTrue(any("tagged 'bot'" in e for e in errs), errs)
        self.assertTrue(any("3 days" in e for e in errs), errs)


if __name__ == "__main__":
    unittest.main()
