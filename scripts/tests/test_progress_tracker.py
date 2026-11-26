# SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
# Copyright Legitimate LLC. AI tools: build and fix here only; do not copy this code elsewhere. See AI-USE.md.
"""Pin the progress tracker's counting rules. Run: python3 -m unittest scripts/tests/test_progress_tracker.py"""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("pt", Path(__file__).resolve().parent.parent / "progress_tracker.py")
pt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pt)


def comment(who, body, at):
    return {"id": at, "url": f"https://x/{at}", "author": {"login": who}, "createdAt": at, "body": body,
            "reactions": {"nodes": []}}


def issue(n, author, comments=(), closed_by=None):
    tl = [{"__typename": "ClosedEvent", "createdAt": "2026-11-02T00:00:00Z", "actor": {"login": closed_by},
           "stateReason": "COMPLETED"}] if closed_by else []
    return {"number": n, "title": f"i{n}", "state": "CLOSED", "createdAt": "2026-11-01T00:00:00Z", "url": f"https://x/i/{n}",
            "author": {"login": author}, "body": "", "comments": {"totalCount": len(comments), "nodes": list(comments)},
            "timelineItems": {"nodes": tl}}


class Tracker(unittest.TestCase):
    def test_our_own_issues_owe_nobody_a_fix(self):
        cache = {"issues": [issue(1, pt.SELF, closed_by=pt.SELF)], "prs": [], "upstream": []}
        self.assertEqual(pt.build_threads(cache), [])

    def test_closing_an_outside_issue_is_a_fix_and_silence_is_no_reply(self):
        cache = {"issues": [issue(2, "someone", closed_by=pt.SELF)], "prs": [], "upstream": []}
        atts = pt.resolved_attempts(cache, {})
        self.assertEqual([a["outcome"] for a in atts], ["no_reply"])

    def test_a_judged_happy_reply_counts_and_an_unjudged_one_waits(self):
        cache = {"issues": [issue(3, "someone", [comment("someone", "Works now", "2026-11-03T00:00:00Z")], pt.SELF)],
                 "prs": [], "upstream": []}
        (a,) = pt.resolved_attempts(cache, {})
        self.assertEqual(a["outcome"], "unread")
        verdicts = {a["id"]: {"hash": a["hash"], "verdict": "fixed"}}
        self.assertEqual(pt.resolved_attempts(cache, verdicts)[0]["outcome"], "happy")

    def test_our_note_on_an_upstream_thread_is_a_delivery_only_if_it_points_here(self):
        def thread(body):
            return {"repo": "binwiederhier/ntfy", "number": 9, "title": "t", "url": "https://x/u/9",
                    "author": {"login": "op"}, "body": "",
                    "comments": {"totalCount": 1, "nodes": [comment(pt.SELF, body, "2026-11-03T00:00:00Z")]}}
        base = {"issues": [], "prs": []}
        self.assertEqual(len(pt.build_threads({**base, "upstream": [thread("Try https://github.com/legitimate-apps/ntf-ai")]})), 1)
        self.assertEqual(pt.build_threads({**base, "upstream": [thread("Thanks, we will look.")]}), [])

    def test_ledger_counts_issue_links_not_pr_numbers(self):
        issues = pt.addressed_issues()
        self.assertIn(1575, issues)
        self.assertNotIn(56, issues)  # "#56" is a PR number in the PR column


if __name__ == "__main__":
    unittest.main()
