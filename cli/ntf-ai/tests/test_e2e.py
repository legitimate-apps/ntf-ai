"""End-to-end tests: the real CLI (a subprocess) against a real stock ntfy server.

By default this starts `binwiederhier/ntfy:v2.31.1` in Docker on a free local port and removes it afterwards.
Set NTF_E2E_SERVER=http://host:port to use a running server instead (it must allow attachments; turn off the
per-visitor topic-creation limit, NTFY_VISITOR_TOPIC_CREATION_LIMIT_BURST=0, or the mutation run hits 429s).
NTF_CLI=path runs a different copy of the CLI (the mutation check uses this).

Run: python3 -m unittest discover -s cli/ntf-ai/tests -p 'test_e2e.py'
"""
import json
import http.server as http_server
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.environ.get("NTF_CLI", os.path.join(os.path.dirname(HERE), "ntf_ai.py"))
IMAGE = os.environ.get("NTF_E2E_IMAGE", "binwiederhier/ntfy:v2.31.1")
SERVER = None
CONTAINER = None


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def setUpModule():
    global SERVER, CONTAINER
    if os.environ.get("NTF_E2E_SERVER"):
        SERVER = os.environ["NTF_E2E_SERVER"].rstrip("/")
        return
    if not shutil.which("docker"):
        raise unittest.SkipTest("docker not found; set NTF_E2E_SERVER")
    port = free_port()
    SERVER = f"http://127.0.0.1:{port}"
    CONTAINER = f"ntf-cli-e2e-{secrets.token_hex(4)}"
    subprocess.run(["docker", "run", "-d", "--rm", "--name", CONTAINER, "--memory", "256m",
                    "-p", f"127.0.0.1:{port}:80", "-e", f"NTFY_BASE_URL={SERVER}",
                    "-e", "NTFY_CACHE_FILE=/tmp/cache.db", "-e", "NTFY_ATTACHMENT_CACHE_DIR=/tmp/att",
                    "-e", "NTFY_VISITOR_REQUEST_LIMIT_BURST=2000", "-e", "NTFY_VISITOR_REQUEST_LIMIT_REPLENISH=100ms",
                    "-e", "NTFY_VISITOR_TOPIC_CREATION_LIMIT_BURST=0",
                    IMAGE, "serve"], check=True, capture_output=True)
    for _ in range(100):
        try:
            urllib.request.urlopen(SERVER + "/v1/health", timeout=1).read()
            return
        except Exception:
            time.sleep(0.2)
    raise RuntimeError("ntfy did not start")


def tearDownModule():
    if CONTAINER:
        subprocess.run(["docker", "rm", "-f", CONTAINER], capture_output=True)


def http(method, path, data=b"", headers=None):
    url = path if path.startswith("http") else SERVER + path
    req = urllib.request.Request(url, data=data if method != "GET" else None, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read()


def poll(topic, since="all"):
    body = http("GET", f"/{topic}/json?poll=1&since={since}").decode()
    return [json.loads(l) for l in body.splitlines() if l.strip()]


class Base(unittest.TestCase):
    def setUp(self):
        self.topic = "e2e-" + secrets.token_hex(12)
        self.tmp = tempfile.mkdtemp()
        self.env = dict(os.environ, NTF_SERVER=SERVER, NTF_TOPIC=self.topic, XDG_CONFIG_HOME=self.tmp,
                        HOME=self.tmp)
        for k in ("NTF_TOKEN", "NTF_USER", "NTF_AI_TOPIC"):
            self.env.pop(k, None)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def cli(self, *args, timeout=60):
        t0 = time.monotonic()
        p = subprocess.run([sys.executable, CLI, *args], env=self.env, capture_output=True, text=True,
                           timeout=timeout)
        p.elapsed = time.monotonic() - t0
        return p

    def wait_question(self, after=None, timeout=15):
        """Like the phone: wait for the agent's question to arrive on the main topic."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            qs = [m for m in poll(self.topic) if m.get("actions") and m["id"] != after]
            if qs:
                return qs[-1]
            time.sleep(0.2)
        raise AssertionError("question never arrived")

    def tap(self, question, label):
        """Make exactly the request the phone makes when the button is tapped."""
        a = next(a for a in question["actions"] if a["label"] == label)
        http(a.get("method", "POST"), a["url"], a.get("body", "").encode(), a.get("headers"))

    def in_background(self, fn):
        errors = []

        def run():
            try:
                fn()
            except Exception as e:  # surfaced by the test after the CLI returns
                errors.append(e)

        t = threading.Thread(target=run, daemon=True)
        t.start()
        return t, errors

    def write_file(self, name, size=2048):
        path = os.path.join(self.tmp, name)
        data = b"\x89PNG\r\n\x1a\n" + secrets.token_bytes(size)
        with open(path, "wb") as f:
            f.write(data)
        return path, data


class SendTests(Base):
    def test_send(self):
        p = self.cli("send", "--title", "Build", "--priority", "high", "--tags", "rocket", "Build finished é")
        self.assertEqual(p.returncode, 0, p.stderr)
        msgs = poll(self.topic)
        self.assertEqual(len(msgs), 1)
        m = msgs[0]
        self.assertEqual(m["id"], p.stdout.strip())
        self.assertEqual((m["message"], m["title"], m["priority"]), ("Build finished é", "Build", 4))
        self.assertEqual(m["tags"], ["agent", "rocket"])

    def test_send_from_stdin_json(self):
        p = subprocess.run([sys.executable, CLI, "send", "--json"], input="piped text\n", env=self.env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["message"], "piped text")


class AskTests(Base):
    def test_ask_answered_by_button(self):
        t, errors = self.in_background(lambda: self.tap(self.wait_question(), "Approve"))
        p = self.cli("ask", "--json", "--timeout", "20", "Merge PR 42?")
        t.join()
        self.assertEqual(errors, [])
        self.assertEqual(p.returncode, 0, p.stderr)
        r = json.loads(p.stdout)
        self.assertEqual((r["status"], r["kind"], r["answer"]), ("answered", "button", "approve"))
        # The button answer went to the -answers topic; the phone's topic has the question and its receipt.
        self.assertEqual([bool(m.get("actions")) for m in poll(self.topic)], [True, False])
        self.assertEqual(len(poll(self.topic + "-answers")), 1)

    def test_ask_rejected_exit_code(self):
        t, errors = self.in_background(lambda: self.tap(self.wait_question(), "Reject"))
        p = self.cli("ask", "--timeout", "20", "Deploy?")
        t.join()
        self.assertEqual((p.returncode, p.stdout.strip()), (3, "reject"), p.stderr)

    def test_ask_custom_buttons(self):
        t, errors = self.in_background(lambda: self.tap(self.wait_question(), "Ship it"))
        p = self.cli("ask", "--timeout", "20", "--button", "Ship it=ship", "--button", "Wait=wait",
                     "--reject", "wait", "Release?")
        t.join()
        self.assertEqual((p.returncode, p.stdout.strip()), (0, "ship"), p.stderr)

    def test_ask_answered_by_plain_reply(self):
        def reply():
            self.wait_question()
            http("POST", "/" + self.topic, "Please wait for my review".encode())

        t, errors = self.in_background(reply)
        p = self.cli("ask", "--json", "--timeout", "20", "Continue?")
        t.join()
        self.assertEqual(p.returncode, 0, p.stderr)
        r = json.loads(p.stdout)
        self.assertEqual((r["kind"], r["answer"]), ("reply", "Please wait for my review"))

    def test_ask_timeout(self):
        p = self.cli("ask", "--json", "--timeout", "3", "Anyone there?")
        self.assertEqual(p.returncode, 4, p.stderr)
        self.assertEqual(json.loads(p.stdout)["status"], "timeout")
        self.assertLess(p.elapsed, 10)

    def test_stale_answers_ignored(self):
        # Before the question: a reply to an earlier question and an earlier written message (same second, so
        # ntfy's since=<question id> returns it too).
        http("POST", f"/{self.topic}-answers", b"reply:0123456789abcdef:approve")
        http("POST", "/" + self.topic, b"an earlier written message")

        def answer():
            q = self.wait_question()
            http("POST", f"/{self.topic}-answers", b"reply:fedcba9876543210:approve")
            http("POST", f"/{self.topic}-answers", b"approve")
            time.sleep(1.5)
            self.tap(q, "Reject")

        t, errors = self.in_background(answer)
        p = self.cli("ask", "--json", "--timeout", "20", "Delete the branch?")
        t.join()
        self.assertEqual(errors, [])
        r = json.loads(p.stdout)
        self.assertEqual((p.returncode, r["kind"], r["answer"]), (3, "button", "reject"), p.stderr)

        # Also cover a server that does not cache the question. The post-publish snapshot
        # cannot find its boundary there; the original pre-publish seen set is essential.
        http("POST", "/" + self.topic, b"another earlier written message")
        ready=threading.Event(); uncached=[]
        class NoCacheQuestion(http_server.BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def forward(self):
                body=self.rfile.read(int(self.headers.get('Content-Length','0'))) if self.command=='POST' else None
                question=False
                if self.command=='POST' and self.path=='/':
                    obj=json.loads(body)
                    if obj.get('actions'):
                        obj['cache']='no'; body=json.dumps(obj).encode(); question=True
                request=urllib.request.Request(SERVER+self.path,data=body,method=self.command,
                    headers={'Content-Type':self.headers.get('Content-Type','application/json')})
                with urllib.request.urlopen(request,timeout=10) as response:
                    data=response.read(); code=response.status
                if question:
                    uncached.append(json.loads(data)); ready.set()
                self.send_response(code);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
            do_GET=do_POST=forward
        proxy=http_server.ThreadingHTTPServer(('127.0.0.1',0),NoCacheQuestion)
        threading.Thread(target=proxy.serve_forever,daemon=True).start()
        try:
            def answer_uncached():
                self.assertTrue(ready.wait(5),'uncached question was not published')
                self.assertEqual(uncached[0].get('expires',0),0)
                self.assertFalse(any(m['id']==uncached[0]['id'] for m in poll(self.topic)))
                time.sleep(.2)
                self.tap(uncached[0],'Reject')
            t,errors=self.in_background(answer_uncached)
            p=self.cli('--server',f'http://127.0.0.1:{proxy.server_port}','ask','--poll','.1',
                       '--json','--timeout','8','Uncached question?')
            t.join(10);self.assertEqual(errors,[])
            r=json.loads(p.stdout)
            self.assertEqual((p.returncode,r['kind'],r['answer']),(3,'button','reject'),p.stderr)
        finally:
            proxy.shutdown();proxy.server_close()

    def test_own_message_not_the_answer(self):
        def answer():
            self.wait_question()
            # The agent's own status update while it waits, sent with the CLI itself.
            s = self.cli("send", "Still working on the tests")
            assert s.returncode == 0, s.stderr
            time.sleep(1.5)
            http("POST", "/" + self.topic, b"go ahead")

        t, errors = self.in_background(answer)
        p = self.cli("ask", "--json", "--timeout", "20", "Run the migration?")
        t.join()
        self.assertEqual(errors, [])
        r = json.loads(p.stdout)
        self.assertEqual((r["kind"], r["answer"]), ("reply", "go ahead"), p.stderr)

    def test_no_reply_mode_ignores_written_reply(self):
        def answer():
            q = self.wait_question()
            http("POST", "/" + self.topic, b"typed")
            time.sleep(1)
            self.tap(q, "Approve")

        t, errors = self.in_background(answer)
        p = self.cli("ask", "--no-reply", "--timeout", "20", "OK?")
        t.join()
        self.assertEqual((p.returncode, p.stdout.strip()), (0, "approve"), p.stderr)

    def test_reply_tagged_for_this_question(self):
        # What the 1.26 reply box sends: one tag, re-<the question's sequence_id>.
        def reply():
            q = self.wait_question()
            http("POST", "/" + self.topic, b"use eu-west", {"Tags": "re-" + q["sequence_id"]})

        t, errors = self.in_background(reply)
        p = self.cli("ask", "--json", "--timeout", "20", "Which region?")
        t.join()
        self.assertEqual(errors, [])
        self.assertEqual(p.returncode, 0, p.stderr)
        r = json.loads(p.stdout)
        self.assertEqual((r["kind"], r["answer"], r.get("reply_to")), ("reply", "use eu-west", r["request_id"]))

    def test_reply_to_another_question_ignored(self):
        def answer():
            q = self.wait_question()
            http("POST", "/" + self.topic, b"meant for the old question", {"Tags": "re-0123456789abcdef"})
            time.sleep(1.5)
            self.tap(q, "Approve")

        t, errors = self.in_background(answer)
        p = self.cli("ask", "--json", "--timeout", "20", "Ship it?")
        t.join()
        self.assertEqual(errors, [])
        r = json.loads(p.stdout)
        self.assertEqual((p.returncode, r["kind"], r["answer"]), (0, "button", "approve"), p.stderr)

    def test_untagged_reply_after_other_question_reply(self):
        # A compose-sheet reply names no question, so it is still the answer; one for another question is not.
        def answer():
            self.wait_question()
            http("POST", "/" + self.topic, b"for someone else", {"Tags": "re-0123456789abcdef"})
            time.sleep(1.5)
            http("POST", "/" + self.topic, b"from the compose sheet")

        t, errors = self.in_background(answer)
        p = self.cli("ask", "--json", "--timeout", "20", "Continue?")
        t.join()
        self.assertEqual(errors, [])
        r = json.loads(p.stdout)
        self.assertEqual((p.returncode, r["kind"], r["answer"]), (0, "reply", "from the compose sheet"), p.stderr)
        self.assertNotIn("reply_to", r)

    def test_no_reply_question_is_tagged_and_ignores_tagged_reply(self):
        def answer():
            q = self.wait_question()
            assert "no-reply" in q.get("tags", []), q.get("tags")
            http("POST", "/" + self.topic, b"typed", {"Tags": "re-" + q["sequence_id"]})
            time.sleep(1)
            self.tap(q, "Approve")

        t, errors = self.in_background(answer)
        p = self.cli("ask", "--no-reply", "--timeout", "20", "OK?")
        t.join()
        self.assertEqual(errors, [])
        self.assertEqual((p.returncode, p.stdout.strip()), (0, "approve"), p.stderr)

    def test_read_json_names_the_question_a_reply_answers(self):
        http("POST", "/" + self.topic, b"yes", {"Tags": "re-abc123"})
        http("POST", "/" + self.topic, b"plain")
        p = self.cli("read", "--json", "--since", "all")
        self.assertEqual(p.returncode, 0, p.stderr)
        rows = [json.loads(l) for l in p.stdout.splitlines()]
        self.assertEqual([(m["message"], m.get("reply_to")) for m in rows], [("yes", "abc123"), ("plain", None)])

    def test_poll_mode(self):
        t, errors = self.in_background(lambda: self.tap(self.wait_question(), "Approve"))
        p = self.cli("ask", "--poll", "1", "--timeout", "20", "Poll?")
        t.join()
        self.assertEqual((p.returncode, p.stdout.strip()), (0, "approve"), p.stderr)


class AttachmentTests(Base):
    def test_send_file_and_download(self):
        path, data = self.write_file("screen shot.png")
        p = self.cli("send", "--attach", path, "--title", "Screenshot", "Here is the page after the fix")
        self.assertEqual(p.returncode, 0, p.stderr)
        m = poll(self.topic)[0]
        self.assertEqual(m["message"], "Here is the page after the fix")
        self.assertEqual(m["title"], "Screenshot")
        self.assertEqual(m["tags"], ["agent"])
        self.assertEqual(m["attachment"]["name"], "screen shot.png")
        self.assertEqual(m["attachment"]["size"], len(data))
        inbox = os.path.join(self.tmp, "inbox")
        r = self.cli("read", "--json", "--download", inbox)
        self.assertEqual(r.returncode, 0, r.stderr)
        got = json.loads(r.stdout.splitlines()[0])["downloaded"]
        with open(got, "rb") as f:
            self.assertEqual(f.read(), data)

    def test_send_attach_url(self):
        p = self.cli("send", "--attach-url", "https://example.com/report.pdf", "Report is ready")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(poll(self.topic)[0]["attachment"]["url"], "https://example.com/report.pdf")

    def test_read_downloads_photo_the_person_sent(self):
        data = secrets.token_bytes(4096)
        http("PUT", "/" + self.topic, data, {"Filename": "IMG_0001.jpg", "Message": "this one"})
        inbox = os.path.join(self.tmp, "inbox")
        r = self.cli("read", "--no-agent", "--download", inbox)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("this one", r.stdout)
        path = r.stdout.split("attachment: ")[1].strip()
        self.assertEqual(os.path.dirname(path), inbox)
        with open(path, "rb") as f:
            self.assertEqual(f.read(), data)

    def test_ask_with_screenshot_and_photo_reply(self):
        path, data = self.write_file("diff.png")
        photo = secrets.token_bytes(3000)

        def answer():
            q = self.wait_question()
            assert q["attachment"]["name"] == "diff.png", q
            http("PUT", "/" + self.topic, photo, {"Filename": "reply.jpg", "Message": "see my markup"})

        t, errors = self.in_background(answer)
        inbox = os.path.join(self.tmp, "inbox")
        p = self.cli("ask", "--json", "--attach", path, "--download", inbox, "--timeout", "20", "Look right?")
        t.join()
        self.assertEqual(errors, [])
        r = json.loads(p.stdout)
        self.assertEqual((p.returncode, r["kind"], r["answer"]), (0, "reply", "see my markup"), p.stderr)
        with open(r["downloaded"], "rb") as f:
            self.assertEqual(f.read(), photo)
        q = [m for m in poll(self.topic) if m.get("actions")][0]
        self.assertEqual(len(q["actions"]), 2)
        self.assertEqual(q["tags"], ["agent"])
        # The ack is only a note: the question (and its screenshot) stays as sent, and the ack doesn't repeat it.
        latest = [m for m in poll(self.topic) if m.get("sequence_id") == q["sequence_id"]][-1]
        self.assertEqual((latest.get("actions"), latest.get("attachment"), latest["tags"]), (None, None, ["agent", "ack"]))


class SettleTests(Base):
    """When ask settles, the question's own sequence gets a quiet update: no buttons, the outcome line."""

    def settled(self, sequence_id):
        msgs = [m for m in poll(self.topic) if m.get("sequence_id") == sequence_id]
        self.assertGreaterEqual(len(msgs), 2, msgs)
        question, latest = msgs[0], msgs[-1]
        self.assertTrue(question.get("actions"))
        self.assertIsNone(latest.get("actions"))
        self.assertEqual((latest["title"], latest["tags"], latest["priority"]),
                         (question["title"], question["tags"], 1))
        return latest

    def acked(self, sequence_id):
        """An answered question gets one ack on its sequence: tags agent+ack, priority 1, no buttons, just the note."""
        msgs = [m for m in poll(self.topic) if m.get("sequence_id") == sequence_id]
        self.assertEqual(len(msgs), 2, msgs)
        question, ack = msgs
        self.assertTrue(question.get("actions"))
        self.assertEqual((ack["tags"], ack["priority"], ack.get("actions"), ack.get("title")),
                         (["agent", "ack"], 1, None, None))
        return ack

    def test_button_answer_acks_question(self):
        t, errors = self.in_background(lambda: self.tap(self.wait_question(), "Ship it"))
        p = self.cli("ask", "--json", "--timeout", "20", "--title", "Release", "--priority", "high",
                     "--button", "Ship it=ship", "--button", "Wait=wait", "Release v2?")
        t.join()
        self.assertEqual(errors, [])
        r = json.loads(p.stdout)
        self.assertEqual((p.returncode, r["answer"]), (0, "ship"), p.stderr)
        ack = self.acked(r["sequence_id"])
        self.assertEqual(ack["message"], "\u2713 Got: Ship it")
        self.assertEqual(r["ack"], {"id": ack["id"], "message": "\u2713 Got: Ship it"})
        self.assertNotIn("settled_id", r)

    def test_typed_reply_acks_without_echo(self):
        def reply():
            self.wait_question()
            http("POST", "/" + self.topic, "secret plan B".encode())

        t, errors = self.in_background(reply)
        p = self.cli("ask", "--json", "--timeout", "20", "Which plan?")
        t.join()
        r = json.loads(p.stdout)
        self.assertEqual((p.returncode, r["answer"]), (0, "secret plan B"), p.stderr)
        self.assertEqual(self.acked(r["sequence_id"])["message"], "\u2713 Got your reply")

    def test_no_ack_sends_none(self):
        t, errors = self.in_background(lambda: self.tap(self.wait_question(), "Approve"))
        p = self.cli("ask", "--json", "--no-ack", "--timeout", "20", "Quietly?")
        t.join()
        r = json.loads(p.stdout)
        self.assertEqual((p.returncode, r["answer"]), (0, "approve"), p.stderr)
        self.assertNotIn("ack", r)
        time.sleep(0.5)
        self.assertEqual([bool(m.get("actions")) for m in poll(self.topic)], [True])

    def test_ntf_ack_updates_the_note(self):
        t, errors = self.in_background(lambda: self.tap(self.wait_question(), "Approve"))
        r = json.loads(self.cli("ask", "--json", "--timeout", "20", "Restart the service?").stdout)
        t.join()
        p = self.cli("ack", "--json", r["request_id"], "Restarted,", "all good")
        self.assertEqual(p.returncode, 0, p.stderr)
        sent = json.loads(p.stdout)
        d = self.cli("ack", r["request_id"])
        self.assertEqual(d.returncode, 0, d.stderr)
        msgs = [m for m in poll(self.topic) if m.get("sequence_id") == r["sequence_id"]]
        self.assertEqual([(m["message"], m.get("tags"), m.get("priority")) for m in msgs[1:]],
                         [("\u2713 Got: Approve", ["agent", "ack"], 1), ("Restarted, all good", ["agent", "ack"], 1),
                          ("\u2713 Got it", ["agent", "ack"], 1)])
        self.assertEqual((sent["id"], d.stdout.strip()), (msgs[2]["id"], msgs[3]["id"]))
        self.assertEqual(self.cli("ack", "not a valid id!").returncode, 2)

    def test_timeout_settles_question(self):
        p = self.cli("ask", "--json", "--timeout", "3", "Anyone there?")
        self.assertEqual(p.returncode, 4, p.stderr)
        latest = self.settled(json.loads(p.stdout)["sequence_id"])
        self.assertEqual(latest["message"], "Anyone there?\n\nNo answer in 3 sec; the agent moved on")

    def test_ctrl_c_settles_question(self):
        proc = subprocess.Popen([sys.executable, CLI, "ask", "--timeout", "60", "Still need me?"], env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        q = self.wait_question()
        time.sleep(0.5)
        proc.send_signal(signal.SIGINT)
        out, err = proc.communicate(timeout=20)
        self.assertEqual(proc.returncode, 130, err)
        latest = self.settled(q["sequence_id"])
        self.assertEqual(latest["message"], "Still need me?\n\nThe agent stopped waiting; no answer needed")
        with open(os.path.join(self.tmp,"ntf-ai","asks.jsonl")) as ledger:
            row=next(json.loads(line) for line in ledger if json.loads(line)["id"]==q["sequence_id"])
        self.assertEqual(row["final"]["state"],"settled")

    def test_failed_question_sends_nothing(self):
        p = self.cli("ask", "--timeout", "5", "--attach-url", "notaurl", "Deploy?")
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertIn("attachment URL is invalid", p.stderr)
        time.sleep(0.5)
        self.assertEqual(poll(self.topic), [])
        self.assertEqual(poll(self.topic + "-answers"), [])


class McpE2E(Base):
    def start(self):
        self.proc = subprocess.Popen([sys.executable, CLI, "mcp"], env=self.env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.addCleanup(self.stop)

    def stop(self):
        # MCP stdio shutdown: close the server's input, wait for it to exit.
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stdout.close()
        self.proc.stderr.close()

    def rpc(self, msg, want_id=True):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        if not want_id:
            return None
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise AssertionError("server closed: " + self.proc.stderr.read())
            r = json.loads(line)
            if r.get("id") == msg["id"]:
                return r

    def test_legacy_handshake_and_tools(self):
        self.start()
        r = self.rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                                 "clientInfo": {"name": "e2e", "version": "1"}}})
        self.assertEqual(r["result"]["protocolVersion"], "2025-11-25")
        self.rpc({"jsonrpc": "2.0", "method": "notifications/initialized"}, want_id=False)
        tools = self.rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
        self.assertEqual({t["name"] for t in tools},
                         {"notify", "ask", "read", "ack", "subscribe_link", "status", "withdraw"})
        path, data = self.write_file("chart.png")
        r = self.rpc({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                      "params": {"name": "notify", "arguments": {"message": "Chart attached", "attach": path}}})
        self.assertFalse(r["result"].get("isError"), r)
        m = poll(self.topic)[0]
        self.assertEqual((m["message"], m["attachment"]["name"], m["tags"]), ("Chart attached", "chart.png",
                                                                               ["agent"]))
        t, errors = self.in_background(lambda: self.tap(self.wait_question(), "Approve"))
        r = self.rpc({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                      "params": {"name": "ask", "arguments": {"question": "Proceed?", "timeout_seconds": 20}}})
        t.join()
        sc = r["result"]["structuredContent"]
        self.assertEqual((sc["status"], sc["answer"]), ("answered", "approve"))
        latest = [m for m in poll(self.topic) if m.get("sequence_id") == sc["sequence_id"]][-1]
        self.assertEqual((latest["message"], latest.get("actions"), latest["tags"]),
                         ("\u2713 Got: Approve", None, ["agent", "ack"]))
        self.assertEqual(sc["ack"]["id"], latest["id"])
        # ack=false sends none; the ack tool adds a note later.
        t, errors = self.in_background(lambda: self.tap(self.wait_question(after=sc["question_id"]), "Approve"))
        r = self.rpc({"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                      "params": {"name": "ask", "arguments": {"question": "Again?", "timeout_seconds": 20,
                                                              "ack": False}}})
        t.join()
        sc2 = r["result"]["structuredContent"]
        self.assertNotIn("ack", sc2)
        time.sleep(0.5)
        self.assertEqual(len([m for m in poll(self.topic) if m.get("sequence_id") == sc2["sequence_id"]]), 1)
        r = self.rpc({"jsonrpc": "2.0", "id": 6, "method": "tools/call",
                      "params": {"name": "ack", "arguments": {"request_id": sc2["request_id"], "note": "Done"}}})
        self.assertFalse(r["result"].get("isError"), r)
        rows = [m for m in poll(self.topic) if m.get("sequence_id") == sc2["sequence_id"]]
        self.assertEqual((rows[-1]["message"], rows[-1]["tags"], r["result"]["structuredContent"]["id"]),
                         ("Done", ["agent", "ack"], rows[-1]["id"]))
        # Person sends a photo on its own; MCP read downloads it and returns an image block.
        png_bytes = (
            bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                          "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082")
        )
        http("PUT", "/" + self.topic, png_bytes, {"Filename": "phone.png", "Message": "From my phone"})
        r_read = self.rpc({"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                           "params": {"name": "read", "arguments": {"limit": 5}}})
        self.assertFalse(r_read["result"].get("isError"), r_read)
        self.assertEqual([c["type"] for c in r_read["result"]["content"]], ["text", "image"])
        self.assertEqual(r_read["result"]["content"][1]["mimeType"], "image/png")
        saved_phone = r_read["result"]["structuredContent"]["messages"][-1]["downloaded"]
        with open(saved_phone, "rb") as f:
            self.assertEqual(f.read(), png_bytes)

    def test_modern_requests(self):
        self.start()
        meta = {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                          "io.modelcontextprotocol/clientInfo": {"name": "e2e", "version": "1"},
                          "io.modelcontextprotocol/clientCapabilities": {}}}
        d = self.rpc({"jsonrpc": "2.0", "id": "d", "method": "server/discover", "params": meta})["result"]
        self.assertEqual(d["resultType"], "complete")
        self.assertTrue(d["instructions"].startswith("NTF-AI (ntf): phone notifications and replies for AI agents."))
        r = self.rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                      "params": dict(meta, name="ask", arguments={"question": "Q?", "timeout_seconds": 5})})
        self.assertEqual(r["result"]["structuredContent"]["status"], "timeout")
        self.assertEqual(r["result"]["resultType"], "complete")
        self.assertIn("not treat this as approval", r["result"]["content"][0]["text"])



class ProtocolV2E2E(Base):
    def test_structured_answer_and_status(self):
        def answer():
            q=self.wait_question(); seq=q['sequence_id']
            self.assertIn('#ask-v2=',q['actions'][0]['url'])
            http('POST','/'+self.topic,b'12.5',{'Tags':'re-'+seq+',ans'})
        t,errors=self.in_background(answer)
        p=self.cli('ask','--spec','{"kind":"number","min":1,"max":64,"step":0.5}','--json','--timeout','8','Memory?')
        t.join(10); self.assertEqual(errors,[]); self.assertEqual(p.returncode,0,p.stderr)
        r=json.loads(p.stdout); self.assertEqual((r['kind'],r['value'],r['valid'],r['authenticated']),('structured',12.5,True,False))
        p=self.cli('status',r['request_id'],'--json'); self.assertEqual(p.returncode,0,p.stderr)
        status=json.loads(p.stdout); self.assertEqual(status['state'],'acked'); self.assertEqual(status['answer']['value'],12.5)
    def test_withdraw_exits_five_and_deletes(self):
        def withdraw():
            q=self.wait_question()
            p=self.cli('withdraw',q['sequence_id'],'--json')
            self.assertEqual(p.returncode,0,p.stderr)
        t,errors=self.in_background(withdraw)
        p=self.cli('ask','--spec','{"kind":"text"}','--json','--timeout','8','Question?')
        t.join(10); self.assertEqual(errors,[]); self.assertEqual(p.returncode,5,p.stderr)
        r=json.loads(p.stdout); self.assertEqual(r['status'],'withdrawn')
        self.assertTrue(any(m['event']=='message_delete' for m in poll(self.topic)))
        self.assertFalse(any('ack' in m.get('tags',[]) for m in poll(self.topic)))
    def test_expired_question_reconnect_uses_unix_time(self):
        # A separate short-cache server makes the old id unusable; force reconnect with --poll.
        port=free_port(); url=f'http://127.0.0.1:{port}'; name='ntf-v2-expire-'+secrets.token_hex(4)
        subprocess.run(['docker','run','-d','--rm','--name',name,'--memory','256m','-p',f'127.0.0.1:{port}:80',
                        '-e','NTFY_CACHE_FILE=/tmp/cache.db','-e','NTFY_CACHE_DURATION=10s',
                        '-e','NTFY_MANAGER_INTERVAL=5s',IMAGE,'serve'],check=True,capture_output=True)
        cursors=[]
        class Proxy(http_server.BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def forward(self):
                query=urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                if 'since' in query: cursors.append(query['since'][0])
                body=self.rfile.read(int(self.headers.get('Content-Length','0'))) if self.command=='POST' else None
                request=urllib.request.Request(url+self.path,data=body,method=self.command,
                    headers={'Content-Type':self.headers.get('Content-Type','application/json')})
                try:
                    with urllib.request.urlopen(request,timeout=10) as response:
                        data=response.read();code=response.status
                except urllib.error.HTTPError as error:
                    data=error.read();code=error.code
                self.send_response(code);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
            do_GET=do_POST=forward
        proxy=http_server.ThreadingHTTPServer(('127.0.0.1',0),Proxy)
        threading.Thread(target=proxy.serve_forever,daemon=True).start()
        proxy_url=f'http://127.0.0.1:{proxy.server_port}'
        try:
            for _ in range(100):
                try: http('GET',url+'/v1/health'); break
                except Exception: time.sleep(.2)
            def answer():
                end=time.monotonic()+10; q=None
                while time.monotonic()<end:
                    rows=json.loads('[]')
                    raw=http('GET',url+'/'+self.topic+'/json?poll=1&since=all')
                    rows=[json.loads(x) for x in raw.splitlines()]
                    if rows: q=rows[-1]; break
                    time.sleep(.1)
                self.assertIsNotNone(q)
                time.sleep(15)
                self.assertEqual(http('GET',url+'/'+self.topic+'/json?poll=1&since=all'),b'')
                http('POST',url+'/'+self.topic,b'ok',{'Tags':'re-'+q['sequence_id']+',ans'})
            t,errors=self.in_background(answer)
            p=self.cli('--server',proxy_url,'ask','--poll','1','--json','--timeout','25','Still there?')
            t.join(27); self.assertEqual(errors,[]); self.assertEqual(p.returncode,0,p.stderr)
            self.assertEqual(json.loads(p.stdout)['answer'],'ok')
            reconnects=[cursor for cursor in cursors if cursor!='all']
            self.assertGreater(len(reconnects),10)
            self.assertTrue(all(cursor.isdigit() for cursor in reconnects),reconnects)
        finally:
            proxy.shutdown();proxy.server_close()
            subprocess.run(['docker','rm','-f',name],capture_output=True)
    def test_invalid_answer_returned_and_strict_waits(self):
        def answer():
            q=self.wait_question(); tags={'Tags':'re-'+q['sequence_id']+',ans'}
            http('POST','/'+self.topic,b'12,5',tags)
            time.sleep(.4)
            http('POST','/'+self.topic,b'12.5',tags)
        t,errors=self.in_background(answer)
        p=self.cli('ask','--spec','{"kind":"number","step":0.5}','--strict','--json','--timeout','8','Amount?')
        t.join(10); self.assertEqual(errors,[]); self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(json.loads(p.stdout)['value'],12.5)
    def test_identity_and_nonblocking_ask(self):
        p=self.cli('ask','--spec','{"kind":"text"}','--as','deploy-bot','--avatar','https://example.com/deploy-bot.png','--no-wait','--json','Q')
        self.assertEqual(p.returncode,0,p.stderr); r=json.loads(p.stdout); self.assertEqual(r['status'],'pending')
        q=self.wait_question(); self.assertIn('@deploy-bot',q['tags']); self.assertEqual(q['icon'],'https://example.com/deploy-bot.png')

class EncryptionE2E(Base):
    def setUp(self):
        super().setUp()
        self.env['NTF_TOPIC_PASSWORD']='synthetic interop password ✓'
        sys.path.insert(0,os.environ.get('NTF_CLI_DIR',os.path.dirname(HERE)))
        import ntf_ai
        self.n=ntf_ai
        self.client=ntf_ai.Client(SERVER);self.client.topic_password=self.env['NTF_TOPIC_PASSWORD']
    def decrypted(self):
        out=[]
        for m in poll(self.topic):
            decoded,auth=self.client.decode_answer(m)
            self.assertTrue(auth);out.append(decoded)
        return out
    def question(self):
        end=time.monotonic()+10
        while time.monotonic()<end:
            rows=self.decrypted()
            qs=[m for m in rows if m.get('actions')]
            if qs:return qs[-1]
            time.sleep(.1)
        raise AssertionError('encrypted question did not arrive')
    def test_send_read_and_listen(self):
        p=self.cli('send','--title','Private title','--as','bot','secret message ✓')
        self.assertEqual(p.returncode,0,p.stderr)
        raw=poll(self.topic)[0]
        self.assertNotIn('secret',raw['message']);self.assertNotIn('title',raw);self.assertNotIn('tags',raw)
        decoded=self.decrypted()[0];self.assertEqual(decoded['title'],'Private title');self.assertIn('@bot',decoded['tags'])
        p=self.cli('read','--json');self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(json.loads(p.stdout)['message'],'secret message ✓')
        p=self.cli('listen','--since','all','--count','1','--timeout','3','--json')
        self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(json.loads(p.stdout)['title'],'Private title')
    def test_native_answer_ack_and_status(self):
        def answer():
            q=self.question()
            # An undecipherable answer is skipped, so a later authenticated answer can complete the ask.
            wrong=self.n.Client(SERVER);wrong.topic_password='wrong password'
            wrong.publish(self.topic,'15',tags=['re-'+q['sequence_id'],'ans'])
            self.client.publish(self.topic,'12.5',tags=['re-'+q['sequence_id'],'ans'])
        t,errors=self.in_background(answer)
        p=self.cli('ask','--spec','{"kind":"number","min":1,"max":64,"step":0.5}','--json','--timeout','8','Memory?')
        t.join(10);self.assertEqual(errors,[]);self.assertEqual(p.returncode,0,p.stderr)
        r=json.loads(p.stdout);self.assertEqual((r['value'],r['authenticated'],r['undecryptable']),(12.5,True,1))
        raw=poll(self.topic);self.assertEqual(raw[-1]['tags'],['agent','ack']);self.assertNotIn('title',raw[-1])
        ack=self.client.decode_answer(raw[-1])[0]
        self.assertEqual(ack['tags'],['agent','ack']);self.assertEqual(ack['priority'],1)
        p=self.cli('status',r['request_id'],'--json');self.assertEqual(p.returncode,0,p.stderr)
        status=json.loads(p.stdout);self.assertEqual(status['state'],'acked');self.assertTrue(status['answer']['authenticated'])
        self.env.pop('NTF_TOPIC_PASSWORD')
        p=self.cli('status',r['request_id'],'--json');self.assertEqual(p.returncode,2,p.stderr)
        self.assertIn('encrypted',p.stderr)
    def test_legacy_button_is_plain_unauthenticated(self):
        t,errors=self.in_background(lambda:self.tap(self.question(),'Approve'))
        p=self.cli('ask','--json','--timeout','8','Proceed?')
        t.join(10);self.assertEqual(errors,[]);self.assertEqual(p.returncode,0,p.stderr)
        r=json.loads(p.stdout);self.assertEqual(r['answer'],'approve');self.assertFalse(r['authenticated'])
        self.assertEqual(poll(self.topic+'-answers')[0]['message'],'reply:'+r['request_id']+':approve')
    def test_strict_schema_and_timeout_settle_encrypted(self):
        p=self.cli('ask','--e2e-strict','--no-wait','--json','Proceed?')
        self.assertEqual(p.returncode,0,p.stderr);q=self.question()
        self.assertTrue(any('#ask-v2=' in a.get('url','') for a in q['actions']))
        self.assertFalse(any(a['action']=='http' for a in q['actions']))
        p=self.cli('ask','--spec','{"kind":"text"}','--json','--timeout','.15','Short wait?')
        self.assertEqual(p.returncode,4,p.stderr)
        raw=poll(self.topic)[-1];self.assertNotIn('stopped',raw['message'])
        settled,auth=self.client.decode_answer(raw);self.assertTrue(auth)
        self.assertEqual(settled['priority'],1);self.assertFalse(settled.get('actions'))
    def test_strict_ask_waits_for_an_answer_bound_to_it(self):
        # 0.4.1: a compose-sheet reply (encrypted, no inner re-<id>) and a plain one never resolve a strict ask.
        def answer():
            q=self.question()
            self.client.publish(self.topic,'unbound')
            http('POST','/'+self.topic,b'plain',{'Tags':'re-'+q['sequence_id']})
            time.sleep(.3)
            self.client.publish(self.topic,'bound',tags=['re-'+q['sequence_id']])
        t,errors=self.in_background(answer)
        p=self.cli('ask','--e2e-strict','--json','--timeout','8','Proceed?')
        t.join(10);self.assertEqual(errors,[]);self.assertEqual(p.returncode,0,p.stderr)
        r=json.loads(p.stdout);self.assertEqual((r['answer'],r['authenticated']),('bound',True))
    def test_unbound_reply_in_plain_mode_exits_7(self):
        def answer():
            self.question();self.client.publish(self.topic,'go ahead')
        t,errors=self.in_background(answer)
        p=self.cli('ask','--timeout','8','Proceed?')
        t.join(10);self.assertEqual(errors,[]);self.assertEqual(p.returncode,7,p.stderr)
        self.assertEqual(p.stdout,'go ahead\n');self.assertIn('unauthenticated answer',p.stderr)
    def test_mcp_inherits_password(self):
        s=dict(server=SERVER,topic=self.topic,topic_password=self.env['NTF_TOPIC_PASSWORD'],ledger_path=os.path.join(self.tmp,'asks.jsonl'))
        mcp=self.n.McpServer(s)
        result=mcp.run_tool('ask',dict(question='Which?',kind='number',wait=False),threading.Event(),None)
        self.assertEqual(result['structuredContent']['status'],'pending')
        self.assertIn('#ask-v2=',self.question()['actions'][0]['url'])
        raw=poll(self.topic)[0];self.assertNotIn('actions',raw)

if __name__ == "__main__":
    unittest.main()
