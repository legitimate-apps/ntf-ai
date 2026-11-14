# Seed a dedicated simulator's app-group store with an agent inbox: waiting questions, answered and
# failing ones, a long Markdown report, a picture, a muted topic. Run after run.py --seed --seed-only.
# usage: inbox_seed.py <udid> <app-group-id> [--empty]
import sys, sqlite3, plistlib, pathlib, time, json, zlib, struct, urllib.parse
udid, group = sys.argv[1], sys.argv[2]
empty = '--empty' in sys.argv
# --tapprobe: ten more urgent questions on deploys, so a tap test can spend one per tap.
tapprobe = '--tapprobe' in sys.argv
# --replyhook: Home publishes to the local hook, so a typed reply on its question goes through.
replyhook = '--replyhook' in sys.argv
# --protocol: on Home, a question sent with `ntf ask --no-reply` and the person's typed reply to q-door.
protocol = '--protocol' in sys.argv
# --acks: agent confirmations (build 48) on Home, which polls the local hook. Answers and acks are
# seeded into the app group's defaults; q-live gets its ack from the hook's poll, through the store.
acks = '--acks' in sys.argv
replyhook = replyhook or acks
base = pathlib.Path.home() / "Library/Developer/CoreSimulator/Devices" / udid / "data/Containers/Shared/AppGroup"
gdir = next(d for d in base.iterdir()
            if (d / ".com.apple.mobile_container_manager.metadata.plist").exists()
            and plistlib.loads((d / ".com.apple.mobile_container_manager.metadata.plist").read_bytes()).get("MCMMetadataIdentifier") == group)
store = gdir / "ntfy.sqlite"
SERVER = "http://127.0.0.1:1"
HOOK = "http://127.0.0.1:8765"
now = int(time.time())
REF = 978307200  # Core Data dates count from 2001

def png(path, w=1200, h=750):
    # A small dashboard-like chart: background, gridlines, five bars.
    rows = []
    bars = [(120, 0.55, (52, 120, 246)), (330, 0.80, (52, 120, 246)), (540, 0.35, (52, 120, 246)), (750, 0.92, (255, 159, 10)), (960, 0.68, (52, 120, 246))]
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            c = (246, 247, 249)
            if y % 150 == 0: c = (222, 225, 230)
            for bx, frac, col in bars:
                if bx <= x < bx + 140 and y >= h - int(h * frac) - 40 and y < h - 40: c = col
            if h - 42 <= y < h - 38: c = (60, 60, 67)
            row += bytes(c)
        rows.append(bytes(row))
    raw = b"".join(rows)
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    path.write_bytes(data)
    return len(data)

def http(label, path, body):
    return {"id": label.lower().replace(" ", "-") + "-" + str(abs(hash(path)) % 9999), "action": "http", "label": label,
            "url": HOOK + path if path.startswith("/") else path, "method": "POST", "body": body}

def reply_link(label, target):
    return {"id": "reply-" + label.lower(), "action": "view", "label": label,
            "url": "https://ntfy-me.com/docs/agents#reply-v1=" + urllib.parse.quote(target, safe="")}

with sqlite3.connect(store) as db:
    ent = dict(db.execute("SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY").fetchall())
    for t in ["ZNOTIFICATION", "ZSUBSCRIPTION", "ZSEQUENCESTATE"]:
        db.execute(f"DELETE FROM {t}")
    topics = [] if empty else [
        # pk, topic, display, pinned, muted
        (1, "claude-code", None, 1, None),
        (2, "deploys", None, 0, None),
        (3, "nightly-ci", None, 0, None),
        (4, "home", "Home", 0, None),
        (5, "research", None, 0, now + 6 * 3600),
    ]
    for pk, topic, display, pinned, muted in topics:
        db.execute("INSERT INTO ZSUBSCRIPTION (Z_PK,Z_ENT,Z_OPT,ZENCRYPTED,ZFCMSUBSCRIBED,ZLASTEVENTTIME,ZPINNED,ZSEQUENCERECONCILE,"
                   "ZBASEURL,ZTOPIC,ZCUSTOMDISPLAYNAME,ZMUTEDUNTIL,ZSUBSCRIBEDAT) VALUES (?,?,1,0,1,0,?,0,?,?,?,?,?)",
                   (pk, ent["Subscription"], pinned, HOOK if replyhook and topic == "home" else SERVER, topic, display, (muted - REF) if muted else None, now - 30 * 86400 - REF))
    report = ("## What I found\n"
              "The flaky test is `test_upload_resumes`. It fails when the mock server closes the socket before the "
              "client reads the last chunk.\n\n"
              "1. The retry loop treats a closed socket as success.\n"
              "2. The final chunk is never re-sent.\n"
              "3. The test passes locally because the mock is slower on this laptop.\n\n"
              "## What I changed\n"
              "- Treat a closed socket as a retryable error.\n"
              "- Re-send the last chunk after a reconnect.\n"
              "- Add a test that closes the socket mid-chunk.\n\n"
              "```\nswift test --filter UploadTests\n```\n\n"
              "All 214 tests pass. The branch is `fix/upload-resume`.")
    img = gdir / "inbox-chart.png"
    size = png(img)
    msgs = [] if empty else [
        # pk, sub, id, seq, age_s, prio, read, title, message, actions, tags, ctype, attachment
        (1, 2, "q-rollback", "q-rollback", 6 * 60, 5, 0, "Roll back api-gateway v2.14?",
         "Error rate is 4.2% since the deploy 6 minutes ago. Rolling back takes about 2 minutes.",
         [http("Roll back", "/slow", "reply:r1:rollback"), http("Keep", "/ok", "reply:r1:keep")], "agent", None, None),
        (2, 1, "q-migrate", "q-migrate", 12 * 60, 4, 0, "Run the database migration?",
         "It adds 2 columns to users and backfills 1.2M rows, with about 4 minutes of write lock.",
         [http("Approve", "/ok", "reply:r2:approve"), http("Reject", "/ok", "reply:r2:reject")], "agent", None, None),
        (3, 3, "q-retry", "q-retry", 25 * 60, 3, 0, "Retry the flaky job?",
         "upload-tests failed twice on runner mac-3. A third run usually passes.",
         [http("Retry", "http://127.0.0.1:9/answers", "reply:r3:retry"), http("Skip", "http://127.0.0.1:9/answers", "reply:r3:skip")], "agent", None, None),
        (4, 1, "q-branch", "q-branch", 40 * 60, 3, 0, "Which branch should I release from?",
         "main has 3 commits that release/1.26 doesn't. Tell me which one to tag.",
         [reply_link("Reply", HOOK + "/reply")], "agent", None, None),
        (5, 4, "q-door", "q-door", 55 * 60, 3, 1, "Front door is unlocked",
         "It has been unlocked for 20 minutes and nobody is home. Lock it?",
         [http("Lock", "/ok", "reply:r5:lock"), http("Leave it", "/ok", "reply:r5:leave")], "agent", None, None),
        (6, 1, "m-report", "m-report", 18 * 60, 3, 0, None, report, None, "agent", "text/markdown", None),
        (7, 3, "m-nightly", "m-nightly", 3 * 3600, 3, 1, "Nightly build passed", "1,204 tests in 6 min 12 s. Coverage 81%.", None, "agent", None, None),
        (8, 2, "m-dash", "m-dash", 2 * 3600, 3, 0, "Traffic after the deploy", "Requests per second by region, last hour.", None, "agent", None,
         ("traffic.png", "image/png", str(img), size)),
        (9, 5, "m-muted", "m-muted", 30 * 60, 3, 0, "Paper summary ready", "Muted topic: this must not show in Activity.", None, "agent", None, None),
        (10, 4, "m-washer", "m-washer", 27 * 3600, 3, 1, "Washer finished", "The laundry is done.", None, None, None, None),
        (11, 1, "m-tests", "m-tests", 26 * 3600, 3, 1, "Tests fixed", "The 3 flaky tests in UploadTests pass 50 runs in a row.", None, "agent", None, None),
    ]
    if tapprobe:
        for i in range(10):
            msgs.append((12 + i, 2, f"q-probe-{i}", f"q-probe-{i}", 60 + i * 60, 5, 0, f"Probe question {i}?",
                         f"Probe body {i}: a tap on this text opens the page and never answers the agent.",
                         [http("Approve", "/ok", f"reply:p{i}:approve"), http("Reject", "/ok", f"reply:p{i}:reject")], "agent", None, None))
    if protocol:
        msgs.append((30, 4, "q-noreply", "q-noreply", 3 * 60, 4, 0, "Restart the router?",
                     "It dropped 3 times this hour. A restart takes about 2 minutes.",
                     [http("Restart", "/ok", "reply:r6:restart"), http("Not now", "/ok", "reply:r6:later")], "agent,no-reply", None, None))
        msgs.append((31, 4, "m-reply", "m-reply", 2 * 60, 3, 1, None, "Locked it from the app, thanks",
                     None, "re-q-door", None, None))
    if acks:
        msgs += [
            (40, 4, "q-garage", "q-garage", 9 * 60, 3, 1, "Garage door is open",
             "It has been open for 15 minutes. Close it?",
             [http("Close", "/ok", "reply:r7:close"), http("Leave it", "/ok", "reply:r7:leave")], "agent", None, None),
            (41, 4, "q-wifi", "q-wifi", 14 * 60, 3, 1, "Which Wi-Fi name should guests use?",
             "I'm setting up the guest network. Type the name you want, or pick one.",
             [http("HomeGuest", "/ok", "reply:r8:homeguest")], "agent", None, None),
            (42, 4, "q-live", "q-live", 4 * 60, 4, 0, "Restart the media server?",
             "Playback stalled twice in the last hour. A restart takes about a minute.",
             [http("Restart", "/ok", "reply:r9:restart"), http("Not now", "/ok", "reply:r9:later")], "agent", None, None),
            (43, 4, "q-thermo", "q-thermo", 20 * 60, 3, 1, "Turn the heating down?",
             "Nobody is home until 6 pm. Lowering it to 17 °C saves about 2 kWh.",
             [http("Lower it", "/ok", "reply:r10:lower"), http("Keep it", "/ok", "reply:r10:keep")], "agent", None, None),
            (44, 4, "q-sprinkler", "q-sprinkler", 35 * 60, 1, 1, "Skip today's watering?",
             "Rain is forecast at 4 pm.\n\nNo answer in 10 min; the agent moved on", None, "agent", None, None),
            (45, 4, "q-lights", "q-lights", 45 * 60, 1, 1, "Porch lights are still on",
             "It's daylight. Turn them off?\n\n\u2713 Agent got: Turn off", None, "agent", None, None),
        ]
    for pk, sub, mid, seq, age, prio, read, title, body, actions, tags, ctype, att in msgs:
        topic = [t for t in topics if t[0] == sub][0][1]
        cols = dict(Z_PK=pk, Z_ENT=ent["Notification"], Z_OPT=1, ZPRESENTED=1, ZREAD=read, ZPRIORITY=prio, ZTIME=now - age,
                    ZSTOREDAT=now - age - REF, ZSUBSCRIPTION=sub, ZID=mid, ZSEQUENCEID=seq, ZSEQUENCEKEY=f"{SERVER}/{topic}/{seq}",
                    ZTITLE=title, ZMESSAGE=body, ZACTIONS=json.dumps(actions) if actions else None, ZTAGS=tags,
                    ZCONTENTTYPE=ctype, ZENCRYPTION=0, ZALERTED=1)
        if att:
            cols.update(ZATTACHMENTNAME=att[0], ZATTACHMENTTYPE=att[1], ZATTACHMENTLOCALPATH=att[2], ZATTACHMENTSIZE=att[3],
                        ZATTACHMENTURL=SERVER + "/file/traffic.png", ZATTACHMENTEXPIRES=now + 3 * 86400)
        db.execute(f"INSERT INTO ZNOTIFICATION ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})", list(cols.values()))
    db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME='Notification'", (len(msgs),))
    db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME='Subscription'", (len(topics),))
print(f"inbox seeded: {len(topics)} topics, {len(msgs)} messages")

# Answers live in the app group's defaults (AnswerLog, answerLog.v1), outside the store: clear them
# so each run starts with every question unanswered. Through cfprefsd, which caches the plist.
import subprocess
# The group's suite lives in its container, not the simulator user's domain, so name the plist by path.
prefs = gdir / "Library/Preferences" / group
r = subprocess.run(["xcrun", "simctl", "spawn", udid, "defaults", "delete", str(prefs), "answerLog.v1"],
                   capture_output=True, text=True)
left = subprocess.run(["xcrun", "simctl", "spawn", udid, "defaults", "read", str(prefs), "answerLog.v1"],
                      capture_output=True, text=True)
print("answer log cleared" if left.returncode != 0 else "ANSWER LOG STILL SET", r.returncode)

# Confirmations: start with none recorded and the setting at its default (on).
for key in ("agentAcks.v1", "showAgentConfirmations"):
    subprocess.run(["xcrun", "simctl", "spawn", udid, "defaults", "delete", str(prefs), key], capture_output=True)
if acks and not empty:
    REF2001 = 978307200
    base = HOOK.rstrip("/")
    def k(seq): return f"{base}|home|{seq}"
    def entry(kind, label, ago, mid, text=None):
        e = {"kind": kind, "label": label, "at": now - ago - REF2001, "ok": True, "messageId": mid}
        if text: e["text"] = text
        return e
    log = {k("q-garage"): entry("tap", "Close", 8 * 60, "q-garage"),
           k("q-wifi"): entry("reply", "Reply", 13 * 60, "q-wifi", "Call it HomeGuest-5G"),
           k("q-door"): entry("tap", "Lock", 54 * 60, "q-door"),
           k("q-thermo"): entry("reply", "Reply", 19 * 60, "q-thermo", "Lower it to 18, not 17"),
           k("q-lights"): entry("tap", "Turn off", 46 * 60, "q-lights-0")}
    acklog = {k("q-door"): {"id": "a-door", "time": now - 53 * 60, "note": "Locked. I'll check the back door too.", "version": "q-door"},
              k("q-thermo"): {"id": "a-thermo", "time": now - 18 * 60, "version": "q-thermo"}}
    for key, value in (("answerLog.v1", log), ("agentAcks.v1", acklog)):
        hexdata = json.dumps(value).encode().hex()
        r = subprocess.run(["xcrun", "simctl", "spawn", udid, "defaults", "write", str(prefs), key, "-data", hexdata],
                           capture_output=True, text=True)
        print(f"{key} seeded" if r.returncode == 0 else f"{key} SEED FAILED {r.stderr}")
