"""ntf-ai 0.5.0: images and files, both ways (CLI + MCP). No live network."""
import base64
import contextlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, os.environ.get("NTF_CLI_DIR", str(Path(__file__).resolve().parents[1])))
import ntf_ai as n  # noqa: E402

TINY_PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082"
)
TINY_JPEG = b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9"
TINY_GIF = b"GIF89a\x01\x00\x01\x00\x00\x00\x00;\n"
TINY_WEBP = b"RIFF\x14\x00\x00\x00WEBPVP8 \x08\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
TINY_HEIC = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic" + b"\x00" * 32
TINY_PDF = b"%PDF-1.4\n1 0 obj\n<<>>\nendobj\ntrailer\n<<>>\n%%EOF\n"


class FakeNtfyServer:
    """In-process HTTP server speaking ntfy's publish, upload, poll and file routes."""

    def __init__(self, upload_status=200):
        self.messages = []
        self.files = {}
        self.uploads = []
        self.polls = []
        self.file_hits = []
        self.upload_status = upload_status
        parent = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _json(self, code, obj):
                raw = json.dumps(obj).encode("utf-8")
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def do_GET(self):
                path, _, query = self.path.partition("?")
                if path == "/v1/ntfyme/capabilities":
                    return self._json(200, {"version": 1, "agent_retention_seconds": 691200})
                if path.startswith("/file/"):
                    parent.file_hits.append(path)
                    if path not in parent.files:
                        return self._json(404, {"error": "not found"})
                    ctype, data = parent.files[path]
                    self.send_response(200)
                    self.send_header("Content-Type", ctype)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                if path.endswith("/json"):
                    topics = set(path[1:-5].split(","))
                    params = dict(p.split("=", 1) for p in query.split("&") if "=" in p)
                    parent.polls.append((topics, params.get("since")))
                    rows = [m for m in parent.messages if m.get("topic") in topics]
                    raw = "".join(json.dumps(m) + "\n" for m in rows).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "application/x-ndjson")
                    self.send_header("Content-Length", str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                    return
                self._json(404, {"error": "unknown route"})

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                if self.path == "/":
                    obj = json.loads(body.decode("utf-8"))
                else:
                    obj = {"topic": self.path.lstrip("/"), "message": body.decode("utf-8", "replace")}
                msg = dict(
                    id=f"m{len(parent.messages) + 1:011d}",
                    time=1700000000 + len(parent.messages),
                    event="message",
                    **obj,
                )
                parent.messages.append(msg)
                self._json(200, msg)

            def do_PUT(self):
                length = int(self.headers.get("Content-Length", "0"))
                data = self.rfile.read(length)
                if parent.upload_status != 200:
                    return self._json(parent.upload_status, {"error": "too large"})
                topic = self.path.lstrip("/")
                fname = self.headers.get("Filename") or "attachment.bin"
                fid = f"/file/f{len(parent.files) + 1}{os.path.splitext(fname)[1]}"
                parent.files[fid] = ("application/octet-stream", data)
                parent.uploads.append((topic, fname, len(data), dict(self.headers)))
                tags = [t.strip() for t in (self.headers.get("Tags") or "").split(",") if t.strip()]
                actions_hdr = self.headers.get("Actions")
                msg = {
                    "id": f"m{len(parent.messages) + 1:011d}",
                    "time": 1700000000 + len(parent.messages),
                    "event": "message",
                    "topic": topic,
                    "message": self.headers.get("Message") or "",
                    "tags": tags,
                    "attachment": {
                        "name": fname,
                        "url": parent.url + fid,
                        "size": len(data),
                    },
                }
                if self.headers.get("X-Sequence-ID"):
                    msg["sequence_id"] = self.headers["X-Sequence-ID"]
                if actions_hdr:
                    msg["actions"] = json.loads(actions_hdr)
                parent.messages.append(msg)
                self._json(200, msg)

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_port}"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def add_person_file(self, topic, message, filename, data, ctype="application/octet-stream", tags=None):
        ext = os.path.splitext(filename)[1]
        fid = f"/file/p{len(self.files) + 1}{ext}"
        self.files[fid] = (ctype, data)
        msg = {
            "id": f"p{len(self.messages) + 1:011d}",
            "time": 1700000100 + len(self.messages),
            "event": "message",
            "topic": topic,
            "message": message,
            "attachment": {"name": filename, "url": self.url + fid, "type": ctype, "size": len(data)},
        }
        if tags:
            msg["tags"] = list(tags)
        self.messages.append(msg)
        return msg

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def make_fake_sips(directory, exit_code=0, payload=TINY_JPEG):
    script = os.path.join(directory, "sips")
    body = (
        f"#!{sys.executable}\n"
        "import sys\n"
        "args = sys.argv[1:]\n"
        f"if {exit_code} != 0:\n"
        f"    sys.exit({exit_code})\n"
        "assert '-s' in args and 'format' in args and 'jpeg' in args and '--out' in args, args\n"
        "out = args[args.index('--out') + 1]\n"
        f"open(out, 'wb').write({payload!r})\n"
    )
    with open(script, "w", encoding="utf-8") as f:
        f.write(body)
    os.chmod(script, os.stat(script).st_mode | stat.S_IXUSR)
    return script


class Base050(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.srv = FakeNtfyServer()
        self.topic = "agent-" + "a" * 32
        self.env = {
            "HOME": self.tmp,
            "XDG_CONFIG_HOME": self.tmp,
            "NTF_SERVER": self.srv.url,
            "NTF_TOPIC": self.topic,
        }

    def tearDown(self):
        self.srv.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_cli(self, argv, env=None):
        out, err = io.StringIO(), io.StringIO()
        merged = dict(self.env, **(env or {}))
        with contextlib.redirect_stderr(err):
            code = n.main(argv, stdin=io.StringIO(""), stdout=out, env=merged)
        return code, out.getvalue(), err.getvalue()

    def mcp(self, extra=None):
        s = n.resolve(n.build_parser().parse_args(["mcp"]), env=self.env, cfg={})
        if extra:
            s.update(extra)
        return n.McpServer(s, poll_interval=0.02)


class VersionAndToolsTests(unittest.TestCase):
    def test_version_is_050_and_read_tool_listed(self):
        self.assertEqual(n.VERSION, "0.6.0")
        tools = {t["name"]: t for t in n.mcp_tools()}
        self.assertEqual(
            set(tools),
            {"notify", "ask", "read", "ack", "subscribe_link", "status", "withdraw"},
        )
        props = tools["read"]["inputSchema"]["properties"]
        for key in ("since", "include_agent", "limit", "download", "download_dir"):
            self.assertIn(key, props)
        for key in ("download", "download_dir"):
            self.assertIn(key, tools["ask"]["inputSchema"]["properties"])


class UploadSizeWarningTests(Base050):
    def write_bytes(self, name, data):
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def test_small_and_exact_5mb_images_do_not_warn(self):
        small = self.write_bytes("small.png", TINY_PNG)
        code, out, err = self.run_cli(["send", "--attach", small, "After the fix"])
        self.assertEqual((code, err), (0, ""))
        self.assertTrue(out.strip())

        exact = self.write_bytes("exact.png", TINY_PNG + b"\x00" * (5 * 1024 * 1024 - len(TINY_PNG)))
        code, _, err = self.run_cli(["send", "--attach", exact, "Exact 5 MB"])
        self.assertEqual((code, err), (0, ""))

    def test_image_over_5mb_warns_on_stderr_and_still_sends(self):
        big_png = self.write_bytes("render.png", TINY_PNG + b"\x00" * (5 * 1024 * 1024))
        code, out, err = self.run_cli(["send", "--attach", big_png, "Full render"])
        self.assertEqual(code, 0)
        self.assertTrue(out.strip())
        self.assertIn("render.png", err)
        self.assertIn("5 MB", err)
        self.assertIn("app", err)
        self.assertIn("banner", err)

        # Extensionless file whose magic bytes are PNG also warns.
        raw_shot = self.write_bytes("rawshot", TINY_PNG + b"\x00" * (5 * 1024 * 1024))
        code, _, err = self.run_cli(["send", "--attach", raw_shot, "Raw"])
        self.assertEqual(code, 0)
        self.assertIn("banner", err)

    def test_non_image_over_5mb_and_failed_upload_do_not_warn_banner(self):
        big_pdf = self.write_bytes("bundle.pdf", TINY_PDF + b"0" * (5 * 1024 * 1024 + 100))
        code, _, err = self.run_cli(["send", "--attach", big_pdf, "Bundle"])
        self.assertEqual((code, err), (0, ""))

        fail_srv = FakeNtfyServer(upload_status=413)
        try:
            big_png = self.write_bytes("huge.png", TINY_PNG + b"\x00" * (5 * 1024 * 1024))
            code, _, err = self.run_cli(["send", "--attach", big_png, "Too big"], env={"NTF_SERVER": fail_srv.url})
            self.assertEqual(code, 1)
            self.assertNotIn("shows in the app", err)
        finally:
            fail_srv.close()


class SipsCopyTests(Base050):
    def test_heic_download_makes_jpeg_copy_when_sips_present(self):
        self.srv.add_person_file(self.topic, "Whiteboard photo", "IMG_0042.HEIC", TINY_HEIC, "image/heic")
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        sips = make_fake_sips(bin_dir)
        inbox = os.path.join(self.tmp, "inbox")

        with patch.object(n.shutil, "which", side_effect=lambda cmd: sips if cmd == "sips" else None):
            code, out, err = self.run_cli(["read", "--no-agent", "--download", inbox])
        self.assertEqual((code, err), (0, ""))
        heic_path = os.path.join(inbox, "IMG_0042.HEIC")
        jpg_path = os.path.join(inbox, "IMG_0042.jpg")
        self.assertTrue(os.path.isfile(heic_path))
        self.assertTrue(os.path.isfile(jpg_path))
        with open(jpg_path, "rb") as f:
            self.assertEqual(f.read(), TINY_JPEG)
        self.assertIn(heic_path, out)
        self.assertIn(jpg_path, out)

        inbox_json = os.path.join(self.tmp, "inbox-json")
        with patch.object(n.shutil, "which", side_effect=lambda cmd: sips if cmd == "sips" else None):
            code, out, err = self.run_cli(["read", "--json", "--no-agent", "--download", inbox_json])
        self.assertEqual((code, err), (0, ""))
        row = json.loads(out.strip())
        self.assertEqual(row["downloaded"], os.path.join(inbox_json, "IMG_0042.HEIC"))
        self.assertEqual(row["downloaded_jpeg"], os.path.join(inbox_json, "IMG_0042.jpg"))

    def test_heic_download_skips_quietly_when_sips_absent_or_fails(self):
        self.srv.add_person_file(self.topic, "Phone shot", "IMG_0043.heic", TINY_HEIC, "image/heic")
        inbox = os.path.join(self.tmp, "inbox-nosips")
        with patch.object(n.shutil, "which", return_value=None):
            code, out, err = self.run_cli(["read", "--json", "--no-agent", "--download", inbox])
        self.assertEqual((code, err), (0, ""))
        row = json.loads(out.strip())
        self.assertEqual(row["downloaded"], os.path.join(inbox, "IMG_0043.heic"))
        self.assertNotIn("downloaded_jpeg", row)
        self.assertEqual(os.listdir(inbox), ["IMG_0043.heic"])

        bin_dir = os.path.join(self.tmp, "badbin")
        os.makedirs(bin_dir)
        bad_sips = make_fake_sips(bin_dir, exit_code=1)
        inbox_fail = os.path.join(self.tmp, "inbox-failsips")
        with patch.object(n.shutil, "which", side_effect=lambda cmd: bad_sips if cmd == "sips" else None):
            code, out, err = self.run_cli(["read", "--json", "--no-agent", "--download", inbox_fail])
        self.assertEqual((code, err), (0, ""))
        row = json.loads(out.strip())
        self.assertEqual(row["downloaded"], os.path.join(inbox_fail, "IMG_0043.heic"))
        self.assertNotIn("downloaded_jpeg", row)
        self.assertEqual(os.listdir(inbox_fail), ["IMG_0043.heic"])

    def test_sips_jpeg_never_follows_planted_symlink_and_skips_non_heic(self):
        self.srv.add_person_file(self.topic, "HEIC", "shot.heic", TINY_HEIC, "image/heic")
        self.srv.add_person_file(self.topic, "PNG", "plain.png", TINY_PNG, "image/png")
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        sips = make_fake_sips(bin_dir)
        inbox = os.path.join(self.tmp, "inbox")
        os.makedirs(inbox)
        outside = os.path.join(self.tmp, "outside.jpg")
        os.symlink(outside, os.path.join(inbox, "shot.jpg"))

        calls = []
        orig_run = n.subprocess.run

        def spy_run(cmd, *a, **kw):
            calls.append(cmd)
            return orig_run(cmd, *a, **kw)

        with patch.object(n.shutil, "which", side_effect=lambda cmd: sips if cmd == "sips" else None), \
                patch.object(n.subprocess, "run", side_effect=spy_run):
            code, out, err = self.run_cli(["read", "--json", "--no-agent", "--download", inbox])
        self.assertEqual((code, err), (0, ""))
        self.assertFalse(os.path.exists(outside))
        rows = [json.loads(l) for l in out.splitlines()]
        self.assertEqual(rows[0]["downloaded_jpeg"], os.path.join(inbox, "shot-1.jpg"))
        self.assertNotIn("downloaded_jpeg", rows[1])
        self.assertEqual(len(calls), 1)  # plain.png never invoked sips

    def test_cli_ask_download_with_heic_prints_and_returns_jpeg_copy(self):
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        sips = make_fake_sips(bin_dir)
        orig_poll = n.Client.poll
        replied = [False]
        srv, topic = self.srv, self.topic

        def poll_and_reply(client, topics, since="all"):
            rows = orig_poll(client, topics, since)
            qs = [m for m in rows if m.get("topic") == topic and m.get("actions")]
            if qs and not replied[0]:
                replied[0] = True
                srv.add_person_file(topic, "Markup", "cam.heif", TINY_HEIC, "image/heif",
                                    tags=["re-" + qs[-1]["sequence_id"]])
                return orig_poll(client, topics, since)
            return rows

        inbox = os.path.join(self.tmp, "ask-inbox")
        with patch.object(n.Client, "poll", poll_and_reply), \
                patch.object(n.shutil, "which", side_effect=lambda cmd: sips if cmd == "sips" else None):
            code, out, err = self.run_cli(["ask", "--poll", "0.02", "--timeout", "5", "--download", inbox, "Photo?"])
        self.assertEqual((code, err), (0, ""))
        lines = out.strip().splitlines()
        self.assertEqual(lines[0], "Markup")
        self.assertEqual(lines[1], os.path.join(inbox, "cam.heif"))
        self.assertEqual(lines[2], os.path.join(inbox, "cam.jpg"))


class McpReadTests(Base050):
    def test_mcp_read_returns_image_block_and_skips_agent_by_default(self):
        self.srv.messages.append({
            "id": "a00000000001", "time": 1700000001, "event": "message",
            "topic": self.topic, "message": "Agent ping", "tags": ["agent"],
        })
        self.srv.add_person_file(self.topic, "Look at this layout", "screen.png", TINY_PNG, "image/png")
        inbox = os.path.realpath(os.path.join(n.inbox_path(self.env), "mcp-inbox"))

        res = self.mcp().run_tool("read", {"download_dir": inbox}, threading.Event(), None)
        content = res["content"]
        self.assertEqual(len(content), 2)
        self.assertEqual(content[0]["type"], "text")
        self.assertIn("Look at this layout", content[0]["text"])
        self.assertNotIn("Agent ping", content[0]["text"])
        saved = os.path.join(inbox, "screen.png")
        self.assertIn(saved, content[0]["text"])
        self.assertIn("image/png", content[0]["text"])
        self.assertEqual(
            content[1],
            {"type": "image", "data": base64.b64encode(TINY_PNG).decode("ascii"), "mimeType": "image/png"},
        )
        sc = res["structuredContent"]
        self.assertEqual(sc["count"], 1)
        self.assertEqual(sc["messages"][0]["downloaded"], saved)
        self.assertEqual(sc["messages"][0]["attachment_type"], "image/png")

        # include_agent=True includes the agent message too.
        res_all = self.mcp().run_tool("read", {"include_agent": True, "download": False}, threading.Event(), None)
        self.assertEqual(res_all["structuredContent"]["count"], 2)

    def test_mcp_read_limit_slices_before_downloading_older_files(self):
        self.srv.add_person_file(self.topic, "Old image", "old.png", TINY_PNG, "image/png")
        self.srv.add_person_file(self.topic, "Newest image", "new.jpg", TINY_JPEG, "image/jpeg")
        res = self.mcp().run_tool("read", {"limit": 1, "since": "1h"}, threading.Event(), None)
        self.assertEqual(self.srv.polls[-1][1], "1h")
        self.assertEqual(len(self.srv.file_hits), 1)
        self.assertTrue(self.srv.file_hits[0].endswith(".jpg"))
        self.assertEqual(res["structuredContent"]["count"], 1)
        self.assertEqual(res["content"][1]["mimeType"], "image/jpeg")

    def test_mcp_read_non_image_file_returns_path_and_type_without_image_block(self):
        self.srv.add_person_file(self.topic, "Logs attached", "report.pdf", TINY_PDF, "application/pdf")
        res = self.mcp().run_tool("read", {}, threading.Event(), None)
        self.assertEqual([c["type"] for c in res["content"]], ["text"])
        msg = res["structuredContent"]["messages"][0]
        self.assertTrue(os.path.isfile(msg["downloaded"]))
        self.assertEqual(msg["attachment_type"], "application/pdf")
        self.assertIn(msg["downloaded"], res["content"][0]["text"])
        self.assertIn("application/pdf", res["content"][0]["text"])

    def test_mcp_read_oversize_image_downloads_without_inlining_base64(self):
        # Over the inline cap (base64 must stay under hosts' 5 MB image limit) and no sips: path only, no image block.
        big = TINY_PNG + b"\x00" * (n.INLINE_IMAGE_MAX + 64)
        self.srv.add_person_file(self.topic, "Huge capture", "huge.png", big, "image/png")
        with patch.object(n.shutil, "which", return_value=None):
            res = self.mcp().run_tool("read", {}, threading.Event(), None)
        self.assertEqual([c["type"] for c in res["content"]], ["text"])
        msg = res["structuredContent"]["messages"][0]
        self.assertTrue(os.path.isfile(msg["downloaded"]))
        self.assertIn(msg["downloaded"], res["content"][0]["text"])
        self.assertNotIn("preview", msg)

    def test_mcp_read_oversize_image_inlines_a_sips_preview(self):
        # A 4 MB phone photo (the 1.32 compose sheet sends JPEGs up to 4096 px) is shown as a smaller JPEG preview.
        big = TINY_JPEG[:-2] + b"\x00" * (n.INLINE_IMAGE_MAX + 64) + b"\xff\xd9"
        self.srv.add_person_file(self.topic, "You received a file: IMG_0111.jpeg", "IMG_0111.jpeg", big, "image/jpeg")
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        sips = make_fake_sips(bin_dir)
        with patch.object(n.shutil, "which", side_effect=lambda cmd: sips if cmd == "sips" else None):
            res = self.mcp().run_tool("read", {}, threading.Event(), None)
        self.assertEqual([c["type"] for c in res["content"]], ["text", "image"])
        self.assertEqual(res["content"][1]["mimeType"], "image/jpeg")
        self.assertEqual(base64.b64decode(res["content"][1]["data"]), TINY_JPEG)
        msg = res["structuredContent"]["messages"][0]
        self.assertTrue(msg["preview"].endswith("IMG_0111-preview.jpg"))
        with open(msg["downloaded"], "rb") as f:
            self.assertEqual(f.read(), big)  # the original is kept whole
        self.assertIn(msg["preview"], res["content"][0]["text"])

    def test_mcp_read_heic_inlines_sips_jpeg_or_falls_back_when_absent(self):
        self.srv.add_person_file(self.topic, "Camera shot", "IMG_1.HEIC", TINY_HEIC, "image/heic")
        bin_dir = os.path.join(self.tmp, "bin")
        os.makedirs(bin_dir)
        sips = make_fake_sips(bin_dir)
        with patch.object(n.shutil, "which", side_effect=lambda cmd: sips if cmd == "sips" else None):
            res = self.mcp().run_tool("read", {}, threading.Event(), None)
        self.assertEqual([c["type"] for c in res["content"]], ["text", "image"])
        self.assertEqual(res["content"][1]["mimeType"], "image/jpeg")
        self.assertEqual(base64.b64decode(res["content"][1]["data"]), TINY_JPEG)
        msg = res["structuredContent"]["messages"][0]
        self.assertTrue(msg["downloaded"].endswith(".HEIC"))
        self.assertTrue(msg["downloaded_jpeg"].endswith(".jpg"))

        with patch.object(n.shutil, "which", return_value=None):
            res2 = self.mcp().run_tool("read", {"download_dir": "no-sips"}, threading.Event(), None)
        self.assertEqual([c["type"] for c in res2["content"]], ["text"])
        self.assertEqual(res2["structuredContent"]["messages"][0]["attachment_type"], "image/heic")

    def test_mcp_read_refuses_external_host_and_drops_encrypted_outer_attachment(self):
        self.srv.messages.append({
            "id": "ext000000001", "time": 1700000200, "event": "message",
            "topic": self.topic, "message": "External link",
            "attachment": {"name": "evil.png", "url": "http://127.0.0.1:9/file/evil.png", "type": "image/png"},
        })
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            res = self.mcp().run_tool("read", {}, threading.Event(), None)
        self.assertEqual([c["type"] for c in res["content"]], ["text"])
        msg = res["structuredContent"]["messages"][0]
        self.assertIsNone(msg.get("downloaded"))
        self.assertIn("External link", res["content"][0]["text"])

        # Encrypted topic: decrypts person message, drops forged outer attachment.
        pw = "shared-secret"
        enc_client = n.Client(self.srv.url)
        enc_client.topic_password = pw
        jwe = n.encrypt_jwe(enc_client._topic_key(self.topic), json.dumps({"message": "Private hello"}).encode())
        self.srv.messages[:] = [{
            "id": "enc000000001", "time": 1700000300, "event": "message",
            "topic": self.topic, "message": jwe,
            "attachment": {"name": "forged.png", "url": self.srv.url + "/file/p1.png"},
        }]
        res_enc = self.mcp({"topic_password": pw}).run_tool("read", {}, threading.Event(), None)
        self.assertEqual([c["type"] for c in res_enc["content"]], ["text"])
        self.assertEqual(res_enc["structuredContent"]["messages"][0]["message"], "Private hello")
        self.assertNotIn("attachment", res_enc["structuredContent"]["messages"][0])


class McpAskAttachmentTests(Base050):
    def answer_with_file(self, filename, data, ctype, text="Here is my screenshot"):
        orig_poll = n.Client.poll
        replied = [False]
        srv = self.srv
        topic = self.topic

        def poll_and_reply(client, topics, since="all"):
            rows = orig_poll(client, topics, since)
            qs = [m for m in rows if m.get("topic") == topic and m.get("actions")]
            if qs and not replied[0]:
                replied[0] = True
                srv.add_person_file(topic, text, filename, data, ctype, tags=["re-" + qs[-1]["sequence_id"]])
                return orig_poll(client, topics, since)
            return rows

        return patch.object(n.Client, "poll", poll_and_reply)

    def test_mcp_ask_answer_with_image_returns_image_block_and_saved_path(self):
        with self.answer_with_file("markup.webp", TINY_WEBP, "image/webp"):
            res = self.mcp().run_tool("ask", {"question": "Does this look right?", "timeout_seconds": 5},
                                      threading.Event(), None)
        self.assertEqual([c["type"] for c in res["content"]], ["text", "image"])
        self.assertEqual(res["content"][1]["mimeType"], "image/webp")
        self.assertEqual(base64.b64decode(res["content"][1]["data"]), TINY_WEBP)
        sc = res["structuredContent"]
        self.assertTrue(os.path.isfile(sc["downloaded"]))
        self.assertEqual(sc["attachment_type"], "image/webp")
        self.assertIn(sc["downloaded"], res["content"][0]["text"])

    def test_mcp_ask_answer_with_pdf_returns_path_without_image_block(self):
        with self.answer_with_file("spec.pdf", TINY_PDF, "application/pdf", text="Read this spec"):
            res = self.mcp().run_tool("ask", {"question": "Spec?", "timeout_seconds": 5},
                                      threading.Event(), None)
        self.assertEqual([c["type"] for c in res["content"]], ["text"])
        sc = res["structuredContent"]
        self.assertTrue(os.path.isfile(sc["downloaded"]))
        self.assertEqual(sc["attachment_type"], "application/pdf")
        self.assertIn(sc["downloaded"], res["content"][0]["text"])


class DefaultFileBodyTests(McpAskAttachmentTests):
    """A photo sent from the 1.32 compose sheet with no text arrives with ntfy's default body (live, 2026-11-24:
    {"name":"IMG_0111.jpeg","type":"image/jpeg",...}, body "You received a file: IMG_0111.jpeg"). Agents must see the
    photo and must not read that body as the person's words."""
    BODY = "You received a file: IMG_0111.jpeg"

    def test_mcp_read_flags_default_body_and_still_shows_the_photo(self):
        self.srv.add_person_file(self.topic, self.BODY, "IMG_0111.jpeg", TINY_JPEG, "image/jpeg")
        self.srv.add_person_file(self.topic, "You received a file: other.jpeg", "IMG_0112.jpeg", TINY_JPEG, "image/jpeg")
        res = self.mcp().run_tool("read", {}, threading.Event(), None)
        first, second = res["structuredContent"]["messages"]
        self.assertTrue(first["default_body"])
        self.assertNotIn("default_body", second)  # the person typed that text themselves (another file's name)
        self.assertIn("no text", res["content"][0]["text"])
        self.assertNotIn("wrote: " + self.BODY, res["content"][0]["text"])
        self.assertEqual([c["type"] for c in res["content"]], ["text", "image", "text", "image"])

    def test_cli_read_json_and_plain_flag_default_body(self):
        self.srv.add_person_file(self.topic, self.BODY, "IMG_0111.jpeg", TINY_JPEG, "image/jpeg")
        code, out, err = self.run_cli(["read", "--json", "--no-agent"])
        self.assertEqual((code, err), (0, ""))
        self.assertTrue(json.loads(out)["default_body"])
        code, out, _ = self.run_cli(["read", "--no-agent"])
        self.assertIn("ntfy's default", out)

    def test_mcp_ask_answer_photo_without_text(self):
        with self.answer_with_file("IMG_0111.jpeg", TINY_JPEG, "image/jpeg", text=self.BODY):
            res = self.mcp().run_tool("ask", {"question": "Send me the label?", "timeout_seconds": 5},
                                      threading.Event(), None)
        self.assertEqual([c["type"] for c in res["content"]], ["text", "image"])
        self.assertNotIn("The person wrote", res["content"][0]["text"])
        self.assertIn("no text", res["content"][0]["text"])
        self.assertTrue(res["structuredContent"]["default_body"])

    def test_cli_ask_photo_without_text_warns_on_stderr(self):
        inbox = os.path.join(self.tmp, "inbox")
        with self.answer_with_file("IMG_0111.jpeg", TINY_JPEG, "image/jpeg", text=self.BODY):
            code, out, err = self.run_cli(["ask", "--poll", "0.02", "--timeout", "5", "--download", inbox, "Label?"])
        self.assertEqual(code, 0)
        self.assertEqual(out.strip().splitlines()[1], os.path.join(inbox, "IMG_0111.jpeg"))
        self.assertIn("not the person's words", err)

    def test_mcp_ask_download_false_keeps_link_only(self):
        with self.answer_with_file("shot.png", TINY_PNG, "image/png"):
            res = self.mcp().run_tool("ask", {"question": "Q?", "timeout_seconds": 5, "download": False},
                                      threading.Event(), None)
        self.assertEqual([c["type"] for c in res["content"]], ["text"])
        self.assertNotIn("downloaded", res["structuredContent"])
        self.assertEqual(self.srv.file_hits, [])


class McpNotifyBannerNoteTests(Base050):
    def test_mcp_notify_large_image_says_banner_wont_show_it(self):
        big = os.path.join(self.tmp, "render.png")
        with open(big, "wb") as f:
            f.write(TINY_PNG + b"\x00" * (5 * 1024 * 1024))
        res = self.mcp().run_tool("notify", {"message": "Render", "attach": big}, threading.Event(), None)
        self.assertIn("banner", res["content"][0]["text"])
        small = os.path.join(self.tmp, "small.png")
        with open(small, "wb") as f:
            f.write(TINY_PNG)
        res = self.mcp().run_tool("notify", {"message": "Small", "attach": small}, threading.Event(), None)
        self.assertNotIn("banner", res["content"][0]["text"])

    def test_heic_attachment_warns_banner_formats(self):
        heic = os.path.join(self.tmp, "IMG_1.heic")
        with open(heic, "wb") as f:
            f.write(TINY_HEIC)
        code, _, err = self.run_cli(["send", "--attach", heic, "Photo"])
        self.assertEqual(code, 0)
        self.assertIn("PNG, JPEG and GIF", err)


if __name__ == "__main__":
    unittest.main()
