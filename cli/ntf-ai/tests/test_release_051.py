# SPDX-License-Identifier: MIT
"""ntf 0.5.1: MCP tools that can write say so, MCP download_dir stays inside the inbox, sips only on small images."""
import os
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_release_050 import Base050, TINY_HEIC, TINY_JPEG, TINY_PDF, TINY_PNG, make_fake_sips  # noqa: E402
import ntf_ai as n  # noqa: E402


class ReadOnlyHintTests(unittest.TestCase):
    def test_tools_that_save_files_are_not_read_only(self):
        # Clients auto-approve read-only tools, so a tool that can write files or run sips must not claim it.
        tools = {t["name"]: t for t in n.mcp_tools()}
        for name, tool in tools.items():
            props = tool["inputSchema"].get("properties", {})
            if "download" in props or "download_dir" in props:
                self.assertIs(tool["annotations"]["readOnlyHint"], False, name)
        self.assertIs(tools["read"]["annotations"]["readOnlyHint"], False)
        self.assertIs(tools["status"]["annotations"]["readOnlyHint"], True)

    def test_download_dir_schema_says_it_is_confined(self):
        for name in ("read", "ask"):
            desc = {t["name"]: t for t in n.mcp_tools()}[name]["inputSchema"]["properties"]["download_dir"]["description"]
            self.assertIn("inside the inbox", desc)
            self.assertIn("refused", desc)


class DownloadFolderTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self.inbox = os.path.join(self.tmp, "inbox")
        os.makedirs(self.inbox)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_default_relative_and_inside_paths_are_allowed(self):
        self.assertEqual(n.mcp_download_folder(self.inbox), self.inbox)
        self.assertEqual(n.mcp_download_folder(self.inbox, ""), self.inbox)
        self.assertEqual(n.mcp_download_folder(self.inbox, "shots"), os.path.join(self.inbox, "shots"))
        self.assertEqual(n.mcp_download_folder(self.inbox, os.path.join(self.inbox, "a", "b")),
                         os.path.join(self.inbox, "a", "b"))

    def test_outside_paths_are_refused(self):
        for bad in (self.tmp, "/tmp", os.path.expanduser("~/.ssh"), "../escape", "a/../../escape",
                    self.inbox + "-sibling", "~"):
            with self.assertRaises(n.NtfError, msg=bad) as cm:
                n.mcp_download_folder(self.inbox, bad)
            self.assertEqual(cm.exception.code, n.EXIT_USAGE)
        for bad in (5, ["x"], "a\0b"):
            with self.assertRaises(n.NtfError):
                n.mcp_download_folder(self.inbox, bad)

    def test_symlink_inside_the_inbox_pointing_out_is_refused(self):
        outside = os.path.join(self.tmp, "outside")
        os.makedirs(outside)
        os.symlink(outside, os.path.join(self.inbox, "link"))
        with self.assertRaises(n.NtfError):
            n.mcp_download_folder(self.inbox, "link")
        with self.assertRaises(n.NtfError):
            n.mcp_download_folder(self.inbox, os.path.join(self.inbox, "link", "deeper"))


class McpDownloadDirTests(Base050):
    def test_read_refuses_a_folder_outside_the_inbox_and_writes_nothing(self):
        self.srv.add_person_file(self.topic, "Look", "screen.png", TINY_PNG, "image/png")
        outside = os.path.join(self.tmp, "elsewhere")
        with self.assertRaises(n.NtfError) as cm:
            self.mcp().run_tool("read", {"download_dir": outside}, threading.Event(), None)
        self.assertIn("inside the inbox", str(cm.exception))
        self.assertFalse(os.path.exists(outside))

    def test_read_saves_into_a_relative_subfolder_of_the_inbox(self):
        self.srv.add_person_file(self.topic, "Look", "screen.png", TINY_PNG, "image/png")
        res = self.mcp().run_tool("read", {"download_dir": "today"}, threading.Event(), None)
        saved = res["structuredContent"]["messages"][0]["downloaded"]
        want = os.path.join(os.path.realpath(n.inbox_path(self.env)), "today", "screen.png")
        self.assertEqual(saved, want)
        self.assertTrue(os.path.isfile(want))

    def test_download_false_ignores_download_dir(self):
        self.srv.add_person_file(self.topic, "Look", "screen.png", TINY_PNG, "image/png")
        res = self.mcp().run_tool("read", {"download": False, "download_dir": "/etc"}, threading.Event(), None)
        self.assertEqual(res["structuredContent"]["count"], 1)

    def test_ask_refuses_an_outside_folder_before_sending_the_question(self):
        outside = os.path.join(self.tmp, "elsewhere")
        with self.assertRaises(n.NtfError):
            self.mcp().run_tool("ask", {"question": "Ship it?", "download_dir": outside, "timeout_seconds": 5},
                                threading.Event(), None)
        self.assertEqual([m for m in self.srv.messages if m.get("topic") == self.topic], [])
        self.assertFalse(os.path.exists(outside))

    def test_cli_download_flag_is_not_confined(self):
        # A person types --download; it may point anywhere they choose.
        self.srv.add_person_file(self.topic, "Look", "screen.png", TINY_PNG, "image/png")
        folder = os.path.join(self.tmp, "my-downloads")
        os.makedirs(folder)
        code, out, err = self.run_cli(["read", "--since", "all", "--download", folder])
        self.assertEqual(code, 0, err)
        self.assertTrue(os.path.isfile(os.path.join(folder, "screen.png")))


class SipsGuardTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()
        self.sips = make_fake_sips(self.tmp)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, data):
        path = os.path.join(self.tmp, name)
        with open(path, "wb") as f:
            f.write(data)
        return path

    def test_sips_skips_non_images_and_files_over_the_cap(self):
        calls = []
        real_run = n.subprocess.run

        def spy(cmd, *a, **k):
            calls.append(cmd)
            return real_run(cmd, *a, **k)

        with patch.object(n.shutil, "which", side_effect=lambda c: self.sips if c == "sips" else None), \
                patch.object(n.subprocess, "run", side_effect=spy):
            self.assertIsNone(n.image_preview(self.write("doc.pdf", TINY_PDF)))
            self.assertIsNone(n.image_preview(self.write("fake.jpg", b"not an image at all")))
            big = self.write("big.heic", TINY_HEIC + b"\x00" * (n.SIPS_INPUT_MAX + 1 - len(TINY_HEIC)))
            self.assertIsNone(n.jpeg_copy(big))
            self.assertEqual(calls, [])
            ok = n.image_preview(self.write("ok.jpg", TINY_JPEG))
        self.assertIsNotNone(ok)
        self.assertEqual(len(calls), 1)

    def test_cap_is_25_mb(self):
        self.assertEqual(n.SIPS_INPUT_MAX, 25 * 1024 * 1024)


if __name__ == "__main__":
    unittest.main()
