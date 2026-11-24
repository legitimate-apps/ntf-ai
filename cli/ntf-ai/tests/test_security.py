"""Security tests for ntf_ai.py: attachment downloads and error redaction, against local HTTP servers. Stdlib only.

An attachment URL comes from a message, and anyone who knows the topic can post one. These tests play that attacker.
Run: python3 -m unittest tests.test_security   (from cli/ntf-ai)
"""
import http.server
import os
import shutil
import sys
import tempfile
import threading
import ipaddress
import socket
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.environ.get("NTF_CLI_DIR", os.path.dirname(HERE)))
import ntf_ai as n  # noqa: E402

TOKEN = "tk_secret_value_123"
TOPIC = "agent-0123456789abcdef0123456789abcdef"


class Recorder(http.server.BaseHTTPRequestHandler):
    """Serves fixed routes and records each request's path and Authorization header."""
    routes = {}
    seen = None

    def do_GET(self):
        self.seen.append((self.path, self.headers.get("Authorization")))
        status, headers, body = self.routes.get(self.path.split("?")[0], (404, {}, b"no"))
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        if "Content-Length" not in headers and status != 204:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def read(path):
    with open(path, "rb") as f:
        return f.read()


def serve(routes):
    seen = []
    handler = type("H", (Recorder,), {"routes": routes, "seen": seen})
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, f"http://127.0.0.1:{httpd.server_port}", seen


class NoLengthHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # body ends when the connection closes, so there is no Content-Length to trust

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"x" * 5000)

    def log_message(self, *a):
        pass


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.servers = []

    def tearDown(self):
        for s in self.servers:
            s.shutdown()
            s.server_close()
        shutil.rmtree(self.dir)

    def server(self, routes):
        httpd, url, seen = serve(routes)
        self.servers.append(httpd)
        return url, seen

    def files(self):
        out = []
        for root, _, names in os.walk(self.dir):
            out += [os.path.relpath(os.path.join(root, f), self.dir) for f in names]
        return sorted(out)


class DownloadTests(Base):
    def test_other_host_refused_by_default(self):
        mine, _ = self.server({})
        other, seen = self.server({"/x.png": (200, {}, b"png")})
        c = n.Client(mine, token=TOKEN)
        with self.assertRaises(n.NtfError) as e:
            c.download(other + "/x.png", self.dir, "x.png")
        self.assertIn("--allow-external-downloads", str(e.exception))
        self.assertEqual(seen, [])  # not even contacted
        self.assertEqual(self.files(), [])

    def test_external_private_addresses_refused_even_when_allowed(self):
        mine, _ = self.server({})
        other, seen = self.server({"/x.png": (200, {}, b"png")})
        c = n.Client(mine)
        port = other.rsplit(":", 1)[1]
        for host in ("localhost", "127.0.0.1", "[::1]", "169.254.169.254", "10.0.0.5", "192.168.1.1"):
            with self.subTest(host=host), self.assertRaises(n.NtfError) as e:
                c.download(f"http://{host}:{port}/x.png", self.dir, "x.png", allow_external=True)
            self.assertIn("non-public", str(e.exception))
        self.assertEqual(seen, [])

    def test_redirect_to_another_host_carries_no_auth(self):
        other, other_seen = self.server({"/f.png": (200, {}, b"image")})
        mine, mine_seen = self.server({"/file/a.png": (302, {"Location": other + "/f.png"}, b"")})
        c = n.Client(mine, token=TOKEN)
        c._public_ip = lambda host, port: "127.0.0.1"  # stand-in for a public host
        path = c.download(mine + "/file/a.png", self.dir, "a.png", allow_external=True)
        self.assertEqual(read(path), b"image")
        self.assertEqual(mine_seen, [("/file/a.png", "Bearer " + TOKEN)])
        self.assertEqual(other_seen, [("/f.png", None)])

    def test_redirect_to_another_host_needs_permission(self):
        other, other_seen = self.server({"/f.png": (200, {}, b"image")})
        mine, _ = self.server({"/file/a.png": (302, {"Location": other + "/f.png"}, b"")})
        c = n.Client(mine, token=TOKEN)
        with self.assertRaises(n.NtfError):
            c.download(mine + "/file/a.png", self.dir, "a.png")
        self.assertEqual(other_seen, [])

    def test_api_redirect_to_another_host_carries_no_auth(self):
        other, other_seen = self.server({f"/{TOPIC}/json": (200, {}, b"")})
        mine, mine_seen = self.server({f"/{TOPIC}/json": (302, {"Location": other + f"/{TOPIC}/json?poll=1"}, b"")})
        n.Client(mine, token=TOKEN).poll([TOPIC], "all")
        self.assertEqual(mine_seen[0][1], "Bearer " + TOKEN)
        self.assertEqual([a for _, a in other_seen], [None])

    def test_size_cap(self):
        url, _ = self.server({"/file/big": (200, {}, b"x" * 5000)})
        c = n.Client(url)
        with self.assertRaises(n.NtfError) as e:
            c.download(url + "/file/big", self.dir, "big.bin", max_bytes=1000)
        self.assertIn("limit", str(e.exception))
        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), NoLengthHandler)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        self.servers.append(httpd)
        nolen = f"http://127.0.0.1:{httpd.server_port}"
        with self.assertRaises(n.NtfError):
            n.Client(nolen).download(nolen + "/file/big", self.dir, "big.bin", max_bytes=1000)
        self.assertEqual(self.files(), [])  # no partial file left behind
        self.assertTrue(n.Client(nolen).download(nolen + "/file/big", self.dir, "ok.bin", max_bytes=5000))

    def test_hostile_file_names_stay_in_the_folder(self):
        url, _ = self.server({"/file/f": (200, {}, b"data")})
        c = n.Client(url)
        target = os.path.join(self.dir, "inbox")
        names = ["../../escape.txt", "..", ".", ".bashrc", "a/../../b.txt", "..\\..\\win.txt", "....", "", "x.txt",
                 "x.txt"]
        paths = [c.download(url + "/file/f", target, name) for name in names]
        self.assertEqual(len(set(paths)), len(paths))  # collisions get new names, nothing overwritten
        for p in paths:
            self.assertEqual(os.path.dirname(os.path.realpath(p)), os.path.realpath(target))
            self.assertFalse(os.path.basename(p).startswith("."), p)
        self.assertTrue(all(f.startswith("inbox" + os.sep) for f in self.files()), self.files())

    def test_planted_symlink_not_followed(self):
        url, _ = self.server({"/file/f": (200, {}, b"data")})
        outside = os.path.join(self.dir, "outside.txt")
        target = os.path.join(self.dir, "inbox")
        os.makedirs(target)
        os.symlink(outside, os.path.join(target, "x.txt"))
        p = n.Client(url).download(url + "/file/f", target, "x.txt")
        self.assertFalse(os.path.exists(outside))
        self.assertEqual(read(p), b"data")

    def test_only_the_attachment_route_gets_credentials(self):
        # ntfy publishes on GET at these paths; a hostile attachment link must not publish with the user's login.
        mine, seen = self.server({})
        c = n.Client(mine, token=TOKEN)
        bad = [f"/{TOPIC}/publish?message=pwned", f"/{TOPIC}/send?message=x", f"/{TOPIC}/trigger", "/v1/account",
               "/file/a.png?x=1", "/file/../v1/account", "/file/a.png/extra", "/file/"]
        for path in bad:
            with self.subTest(path=path), self.assertRaises(n.NtfError):
                c.download(mine + path, self.dir, "x")
        self.assertEqual(seen, [])  # never contacted
        c._public_ip = lambda host, port: "127.0.0.1"  # as if the server were public: then it's fetched, without login
        for path in bad[:3]:
            with self.assertRaises(n.NtfError):  # 404 from the test server
                c.download(mine + path, self.dir, "x", allow_external=True)
        self.assertEqual([a for _, a in seen], [None, None, None])

    def test_attachment_route_under_a_path_prefix(self):
        url, seen = self.server({"/base/file/abc123.png": (200, {}, b"img")})
        c = n.Client(url + "/base", token=TOKEN)
        self.assertEqual(read(c.download(url + "/base/file/abc123.png", self.dir, "a.png")), b"img")
        self.assertEqual(seen, [("/base/file/abc123.png", "Bearer " + TOKEN)])
        with self.assertRaises(n.NtfError):
            c.download(url + "/file/abc123.png", self.dir, "a.png")

    def test_ipv6_wrappers_of_private_ipv4_refused(self):
        teredo_to_loopback = "2001:0:4136:e378:8000:63bf:80ff:fffe"  # client 127.0.0.1, obfuscated
        blocked = ["64:ff9b::7f00:1", "64:ff9b::a9fe:a9fe", "64:ff9b::c0a8:101", "64:ff9b:1::808:808", "::7f00:1",
                   "::a9fe:a9fe", "2002:7f00:1::", "2002:a9fe:a9fe::", teredo_to_loopback]
        for addr in blocked:
            with self.subTest(addr=addr), mock.patch.object(n.socket, "getaddrinfo", return_value=[
                    (socket.AF_INET6, socket.SOCK_STREAM, 6, "", (addr, 443, 0, 0))]):
                with self.assertRaises(n.NtfError):
                    n.Client._public_ip("evil.example", 443)
        for addr in ("64:ff9b::808:808", "2606:4700::1111"):
            with self.subTest(addr=addr), mock.patch.object(n.socket, "getaddrinfo", return_value=[
                    (socket.AF_INET6, socket.SOCK_STREAM, 6, "", (addr, 443, 0, 0))]):
                self.assertEqual(n.Client._public_ip("ok.example", 443), addr)

    def test_embedded_ipv4_unwrapped(self):
        e = lambda a: [str(x) for x in n._embedded_ipv4(ipaddress.ip_address(a))]
        self.assertEqual(e("2002:7f00:1::"), ["127.0.0.1"])
        self.assertIn("127.0.0.1", e("2001:0:4136:e378:8000:63bf:80ff:fffe"))
        self.assertEqual(e("64:ff9b::a9fe:a9fe"), ["169.254.169.254"])
        self.assertEqual(e("::ffff:10.0.0.1"), ["10.0.0.1"])

    def test_hosted_aliases_count_as_one_server(self):
        c = n.Client("https://ntf-ai.app")
        self.assertIn(("https", "ntfy-me.com", 443), c.server_origins)
        self.assertEqual(n.Client("https://ntfy.example.com").server_origins, {("https", "ntfy.example.com", 443)})


class RedactionTests(Base):
    def test_error_hides_topic_answers_topic_and_credentials(self):
        echo = f"bad request for {TOPIC} and {TOPIC}-answers with {TOKEN}".encode()
        url, _ = self.server({f"/base/{TOPIC},{TOPIC}-answers/json": (500, {}, echo)})
        c = n.Client(url + "/base", token=TOKEN, protect=[TOPIC])
        with self.assertRaises(n.NtfError) as e:
            c.poll([TOPIC, TOPIC + "-answers"], "all")
        text = str(e.exception)
        self.assertIn("HTTP 500", text)
        for secret in (TOPIC, TOKEN, TOPIC[6:]):
            self.assertNotIn(secret, text)
        self.assertIn("<topic>-answers", text)

    def test_user_password_hidden(self):
        c = n.Client("http://127.0.0.1:9", user="alice:hunter2pass", protect=[TOPIC])
        text = c._safe(f"http://alice:hunter2pass@h/{TOPIC} said hunter2pass and {TOPIC}")
        self.assertNotIn("hunter2pass", text)
        self.assertNotIn(TOPIC, text)

    def test_connection_error_hides_topic(self):
        c = n.Client("http://127.0.0.1:9/" + "p", protect=[TOPIC])
        with self.assertRaises(n.NtfError) as e:
            c.poll([TOPIC, TOPIC + "-answers"], "all")
        self.assertNotIn(TOPIC, str(e.exception))


class ProtocolAuthenticationTests(unittest.TestCase):
    def test_plain_answer_cannot_claim_authentication(self):
        msg = dict(id="A", event="message", topic="t", message="ok", tags=["re-R", "ans"], authenticated=True)
        client = n.Client("https://ntf-ai.app")
        decoded, authenticated = client.decode_answer(msg)
        self.assertFalse(authenticated)
        answer = n.match_answer(decoded, "t", "R", [], True, set(), schema=dict(v=2, kind="text"), authenticated=authenticated)
        self.assertFalse(answer["authenticated"])
        self.assertTrue(answer["valid"])


class EncryptionSecurityTests(unittest.TestCase):
    def test_password_never_in_argv_or_error_logs(self):
        import json, subprocess, time
        from unittest.mock import patch
        password='test topic secret %+/✓'
        httpd,url,seen=serve({'/t/json':(500,{},json.dumps({'error':password}).encode())})
        try:
            c=n.Client(url)
            n.configure_encryption(c,{'topic_password':password},'t')
            with self.assertRaises(n.NtfError) as error:c.poll(['t'],'all')
            self.assertNotIn(password,str(error.exception));self.assertIn('<topic password>',str(error.exception))
            env=dict(os.environ,NTF_TOPIC_PASSWORD=password)
            proc=subprocess.Popen([sys.executable,os.environ.get('NTF_CLI',os.path.join(os.path.dirname(HERE),'ntf_ai.py')),
                '--server',url,'--topic','t','listen','--timeout','2'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                time.sleep(.15)
                argv=subprocess.check_output(['ps','-p',str(proc.pid),'-o','command='],text=True)
                self.assertNotIn(password,argv);self.assertIn('listen',argv)
                stdout,stderr=proc.communicate(timeout=8)
                self.assertNotIn(password,stdout+stderr)
            finally:
                if proc.poll() is None:proc.kill();proc.communicate()
        finally:httpd.shutdown();httpd.server_close()

    def test_authentication_checked_before_decryption_and_outer_tags_not_trusted(self):
        from unittest.mock import patch
        key=bytes(32);iv=bytes(12);ct,tag=n.aes_gcm_encrypt(key,iv,b'secret',b'h')
        with patch.object(n,'_gcm_crypt',side_effect=AssertionError('plaintext released')):
            with self.assertRaises(n.NtfError):n.aes_gcm_decrypt(key,iv,ct,bytes(16),b'h')
        c=n.Client('https://ntf-ai.app');c.topic_password='pw'
        jwe=n.encrypt_jwe(c._topic_key('t'),b'{"message":"forged answer","tags":["agent"]}')
        decoded,auth=c.decode_answer(dict(event='message',id='X',topic='t',message=jwe,tags=['re-R','ans']))
        self.assertTrue(auth)
        self.assertIsNone(n.match_answer(decoded,'t','R',[],True,set(),schema=dict(v=2,kind='text'),authenticated=auth))

    def test_required_encryption_and_attachments_fail_before_network(self):
        from unittest.mock import patch
        p=n.build_parser()
        with tempfile.TemporaryDirectory() as tmp:
            cfg=os.path.join(tmp,'config.json')
            with open(cfg,'w') as f:f.write('{"topic":"t","topics":{"t":{"e2e":true}}}')
            with patch.dict(os.environ,{'NTF_CONFIG':cfg},clear=True),patch.object(n.Client,'_request',side_effect=AssertionError('network')):
                with self.assertRaises(n.NtfError):n.run(p.parse_args(['send','secret']),p,None,None,dict(os.environ),False,'ntf')
        c=n.Client('https://ntf-ai.app');c.topic_password='pw'
        with patch.object(c,'_request',side_effect=AssertionError('network')):
            for kw in ({'attach':'missing'},{'attach_url':'https://ntf-ai.app/file/report.pdf'}):
                with self.assertRaises(n.NtfError):n.ask(c,'t','secret',**kw)

if __name__ == "__main__":
    unittest.main()
