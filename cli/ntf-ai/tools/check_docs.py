#!/usr/bin/env python3
"""Fail when what agents read disagrees with what the code does.

Agents only know what these texts tell them, so each protocol fact is taken from the code (ntf_ai.py, and the app's
Swift source when --app is given) and checked against every surface an agent reads:

  CLI:   skill/ntf-ai/SKILL.md (and the copy embedded in ntf_ai.py), AGENTS-snippet.md, README.md, `ntf --help`,
         `ntf ask --help`, the MCP server's instructions and tool descriptions.
  Guide: the agent guide's Markdown source (--guide) and, when they sit beside it, the pages built from it
         (ntfyme-docs/agents.html, ntfyme-seo/llms-full.txt), which must match the source.

With --server, the guide's numbered recipe (sections 1-5) also runs as written against that ntfy server, and the
messages it leaves behind are compared with what `ntf ask` would send.

  python3 tools/check_docs.py                                   # CLI surfaces
  python3 tools/check_docs.py --guide .../agents.md --app .../ntfy --server http://127.0.0.1:18977

Exit 0 when everything agrees; 1 with one line per disagreement. Stdlib only.
"""
import argparse
import html
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CLI_DIR = os.path.dirname(HERE)

# Behaviour that only NTF-AI 1.26 has. Until 1.26 is the only version people run, a paragraph that names one of these
# must say which version brought it, so a 1.25 user is never told they can do something they can't.
APP_126_TERMS = ("Waiting on you", "reply box", "You replied")
APP_126_MARK = "1.26"
# The app's own receipt label (ACK-SPEC.md), which a text may quote; it is not an ack body.
APP_RECEIPT_TEXT = ("✓ Agent got it",)


def load_cli(cli_dir):
    spec = importlib.util.spec_from_file_location("ntf_ai_checked", os.path.join(cli_dir, "ntf_ai.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------- facts, from the code

def facts_from_cli(n, cli_dir):
    f = {"tag": n.AGENT_TAG, "suffix": n.ANSWERS_SUFFIX}
    act = n.question_actions("https://h/t-answers", "RID", [("Label", "ANS")])[0]
    body = act["body"]
    f["reply_prefix"] = body[:body.index("RID")]                     # "reply:"
    f["reply_sep"] = body[body.index("RID") + 3:body.index("ANS")]   # ":"
    f["action"] = {k: act[k] for k in ("action", "method", "headers")}
    f["exit"] = {"answered": n.EXIT_OK, "rejected": n.EXIT_REJECTED, "timeout": n.EXIT_TIMEOUT,
                 "error": n.EXIT_ERROR, "usage": n.EXIT_USAGE, "withdrawn": n.EXIT_WITHDRAWN,
                 "dismissed": n.EXIT_DISMISSED}
    f["mcp_tools"] = [t["name"] for t in n.mcp_tools()]
    ask_parser = n.build_parser("ntf")._subparsers._group_actions[0].choices["ask"]
    f["timeout_default"] = int(next(a.default for a in ask_parser._actions if a.dest == "timeout"))
    limit = 0
    while True:
        try:
            n.parse_buttons([f"B{i}" for i in range(limit + 1)])
            limit += 1
        except n.NtfError:
            break
    f["max_choices"] = limit
    # The CLI accepts 12 choices, while stock ntfy can display only three HTTP buttons.
    # Derive that boundary from emitted actions, rather than the argument parser's choice limit.
    legacy_counts = []
    for count in range(2, limit + 1):
        try:
            actions, _ = n.schema_actions("https://h", "t", "RID",
                dict(v=2, kind="choice", options=[dict(k=str(i), l=str(i)) for i in range(count)]), True)
        except n.NtfError:
            continue  # parser/native-schema drift is reported by the independent choice-limit claim
        if all(a["action"] == "http" for a in actions):
            legacy_counts.append(count)
    f["max_buttons"] = max(legacy_counts, default=0)
    # The receipt lines, with the parts that vary turned into patterns.
    dur = re.escape(n.human_duration(f["timeout_default"]))
    btn = n.outcome_line({"kind": "button", "answer": "x"}, [("LABEL", "x")], 600)
    f["outcomes"] = {
        "button": re.escape(btn).replace("LABEL", r"[^\"'`\n]+?"),
        "reply": re.escape(n.outcome_line({"kind": "reply", "answer": "t"}, [], 600)),
        "timeout": re.escape(n.outcome_line(None, [], f["timeout_default"])).replace(
            dur, r"\d+ (?:sec|min|h)(?: \d+ min)?"),
        "interrupted": re.escape(n.outcome_line(None, [], 600, interrupted=True)),
        "default": re.escape(n.ack_line(None, [])),
    }
    # The ack, as `ntf ask` and `ntf ack` send it: the tags, priority and sequence on a note.
    rec = _Recorder()
    n.send_ack(rec, "T", "RID", "")
    f["ack"] = {k: rec.calls[0].get(k) for k in ("tags", "priority", "sequence_id", "body")}
    f["ack_tag"] = [t for t in f["ack"]["tags"] if t != n.AGENT_TAG][0]
    # Written replies that name their question (from NTF-AI 1.26): the tag prefix `ntf ask` matches, checked against
    # what match_answer does, and the tag `ntf ask --no-reply` puts on its question.
    prefix = n.REPLY_TAG_PREFIX
    probe = lambda tag: n.match_answer({"event": "message", "id": tag, "topic": "t", "message": "x", "tags": [tag]},
                                       "t", "RID", [("A", "a")], True, set())
    if not (probe(prefix + "RID") or {}).get("reply_to") == "RID" or probe(prefix + "OTHER") is not None:
        raise SystemExit(f"check_docs: match_answer doesn't honour REPLY_TAG_PREFIX {prefix!r}; fix the code first")
    f["reply_tag_prefix"] = prefix
    f["no_reply_tag"] = no_reply_tag(n)
    # The settle update, as `ntf ask` sends it.
    f["settle"] = settle_call(n, {"id": "Q", "sequence_id": "S"}, "Question?", "Line", "Title", [n.AGENT_TAG])
    sub = n.build_parser("ntf")._subparsers._group_actions[0].choices
    def options(parser):  # a command's flags, including those of nested commands (`ntf topic new --save`)
        out = set()
        for a in parser._actions:
            out |= set(a.option_strings)
            for child in (getattr(a, "choices", None) or {}).values() if isinstance(a, argparse._SubParsersAction) else ():
                out |= options(child)
        return out
    f["commands"] = {name: options(p) for name, p in sub.items()}
    f["global_flags"] = {o for a in n.build_parser("ntf")._actions for o in a.option_strings}
    return f


class _Recorder:
    server = "https://ntf-ai.app"

    def __init__(self):
        self.calls = []

    def publish(self, topic, body, **kw):
        self.calls.append(dict(kw, topic=topic, body=body))
        return {"id": "U"}

    def poll(self, topics, since):
        return []


def no_reply_tag(n):
    """The tag `ntf ask --no-reply` adds to its question, read from what ask() publishes."""
    import threading
    rec, stop = _Recorder(), threading.Event()
    stop.set()
    from unittest.mock import patch
    with patch.object(n, "record_ask"):
        n.ask(rec, "T", "Q?", accept_reply=False, timeout=5, cancel=stop, settle=False)
    extra = [t for t in rec.calls[0]["tags"] if t != n.AGENT_TAG]
    return extra[0] if extra else None


def settle_call(n, sent, question, line, title, tags):
    rec = _Recorder()
    n.settle_question(rec, "T", sent, question, line, title, tags, False)
    return rec.calls[0]


def facts_from_app(app_dir):
    """The two app facts agents rely on: how long a question waits, and the tag that earns it a reply box."""
    src = read(os.path.join(app_dir, "Utils", "AnswerLog.swift"))
    out = {}
    m = re.search(r"static let maxAge: TimeInterval = ([\d *]+)", src)
    if m:
        seconds = 1
        for part in m.group(1).split("*"):
            seconds *= int(part.strip())
        out["max_age_days"] = seconds // 86400
    m = re.search(r'enum AgentReply \{.*?static let agentTag = "([^"]+)"', src, re.S)
    if m:
        out["reply_tag"] = m.group(1)
    return out


# ---------------------------------------------------------------- surfaces

def cli_surfaces(n, cli_dir):
    def run(*argv):
        env = dict(os.environ, HOME=tempfile.gettempdir())
        return subprocess.run([sys.executable, os.path.join(cli_dir, "ntf_ai.py"), *argv], capture_output=True,
                              text=True, env=env).stdout
    mcp = n.MCP_INSTRUCTIONS + "\n\n" + "\n\n".join(
        t["description"] + "\n" + json.dumps(t["inputSchema"], ensure_ascii=False) for t in n.mcp_tools())
    return {
        "SKILL.md": read(os.path.join(cli_dir, "skill", "ntf-ai", "SKILL.md")),
        "ntf_ai.py SKILL_MD": n.SKILL_MD,
        "AGENTS-snippet.md": read(os.path.join(cli_dir, "AGENTS-snippet.md")),
        "README.md": read(os.path.join(cli_dir, "README.md")),
        "ntf --help": run("--help"),
        "ntf ask --help": run("ask", "--help"),
        "MCP": mcp,
    }


def brand(text, guide_path):
    name = "NTF-AI"
    brand_file = os.path.join(os.path.dirname(os.path.dirname(guide_path)), "ntfyme-brand.json")
    if os.path.exists(brand_file):
        name = json.loads(read(brand_file))["name"]
    return text.replace("{{APP_NAME}}", name)


# ---------------------------------------------------------------- checks

def paragraphs(text):
    """Blank-line paragraphs, with list items as their own paragraph."""
    out = []
    for block in re.split(r"\n\s*\n", text):
        out.extend(p for p in re.split(r"\n(?=\s*(?:[-*]|\d+\.) )", block) if p.strip())
    return out


def code_lines(text):
    """Lines that are code: fenced blocks, inline `spans`, and indented example lines in --help."""
    lines = []
    fence = False
    for line in text.splitlines():
        if line.strip().startswith("```"):
            fence = not fence
            continue
        if fence or re.match(r"^\s{2}ntf ", line):
            lines.append(line)
    lines += re.findall(r"`([^`\n]+)`", text)
    return lines


EXIT_CLAIM = re.compile(r"(?<![\w.])`?(\d)`?\s+(?:when\s+(?:it\s+)?)?(answered|rejected|timed out|times out|timeout|error|bad usage|usage|withdrawn|dismissed)\b")
EXIT_WORD = {"answered": "answered", "rejected": "rejected", "timed out": "timeout", "times out": "timeout", "timeout": "timeout",
             "error": "error", "bad usage": "usage", "usage": "usage", "withdrawn": "withdrawn",
             "dismissed": "dismissed"}

# Which facts each surface must state. Everything else is checked wherever it is mentioned.
REQUIRED = {
    "SKILL.md": {"tag", "suffix", "reply_prefix", "exit", "mcp", "outcomes:button,reply,timeout,interrupted,default",
                 "settle", "written_reply", "withdraw", "reply_tag", "no_reply", "ack"},
    "AGENTS-snippet.md": {"tag", "exit", "written_reply", "reply_tag", "ack"},
    "README.md": {"tag", "suffix", "reply_prefix", "exit", "mcp", "settle", "written_reply", "reply_tag", "no_reply",
                  "ack"},
    "ntf --help": {"exit", "mcp", "reply_tag", "ack"},
    "ntf ask --help": {"exit", "no_reply", "ack"},
    "MCP": {"mcp", "written_reply", "reply_tag", "no_reply", "ack"},
    "guide": {"tag", "suffix", "reply_prefix", "exit", "mcp", "outcomes:button,reply,timeout,default", "settle",
              "written_reply", "withdraw", "app", "reply_tag", "no_reply", "ack"},
}


def check_text(name, text, f, app=None, kind=None):
    errs = []
    req = REQUIRED.get(kind or name, set())
    say = lambda msg: errs.append(f"{name}: {msg}")
    tag, suffix, prefix = f["tag"], f["suffix"], f["reply_prefix"]

    if "tag" in req and not re.search(rf"`{tag}`|Tags: {tag}\b|'{tag}'|\"{tag}\"", text):
        say(f"never names the `{tag}` tag that marks the agent's own messages")
    for m in re.finditer(r"(?:<topic>|\$NTF_AI_TOPIC|\$TOPIC|\{topic\}|topic \+ ')(-[a-z]+)\b", text):
        if m.group(1) != suffix:
            say(f"answers topic written {m.group(0)!r}; the code uses '<topic>{suffix}'")
    if "suffix" in req and suffix not in text:
        say(f"never names the '{suffix}' answers topic")
    if "reply_prefix" in req and not re.search(re.escape(prefix) + r"[<{$]", text):
        say(f"doesn't show the button answer body '{prefix}<request id>{f['reply_sep']}<answer>'")
    for m in re.finditer(r"\b([a-z]+):(?:<request id>|\{request\}|\$NTF_AI_REQUEST)", text):
        if m.group(1) + ":" != prefix:
            say(f"button answer body starts {m.group(0)!r}; the code sends '{prefix}<request id>...'")

    claims = [(int(m.group(1)), EXIT_WORD[m.group(2)]) for m in EXIT_CLAIM.finditer(text)
              if re.search(r"exit", text[max(0, m.start() - 120):m.start()], re.I)]
    for digit, what in claims:
        if f["exit"][what] != digit:
            say(f"says exit {digit} means {what}; the code exits {f['exit'][what]}")
    if "exit" in req:
        missing = {"answered", "rejected", "timeout", "dismissed"} - {w for _, w in claims}
        if missing:
            say(f"doesn't give the ask exit code for {', '.join(sorted(missing))}")

    mentions_mcp = re.search(r"\bMCP\b", text)
    if "mcp" in req or mentions_mcp:
        for tool in f["mcp_tools"]:
            if not re.search(rf"\b{tool}\b", text):
                say(f"lists MCP tools without `{tool}`")
        for listed in re.findall(r"MCP server(?: \w+)? with ([^.;\n]+?) tools", text):
            words = {w for w in re.findall(r"`?([a-z_]+)`?", listed) if w not in ("and", "or", "with")}
            if words != set(f["mcp_tools"]):
                say(f"lists the MCP tools as {sorted(words)}; the server has {f['mcp_tools']}")

    outs = [k for r in req if r.startswith("outcomes:") for k in r.split(":")[1].split(",")]
    for key in outs:
        if not re.search(f["outcomes"][key], text):
            say(f"doesn't give the {key} receipt line (pattern {f['outcomes'][key]})")
    for m in re.finditer(r"✓ [^\"'`)\n·]+", text):
        phrase = m.group(0).rstrip(" .,;")
        if phrase in APP_RECEIPT_TEXT:
            continue
        if not any(re.fullmatch(f["outcomes"][k], phrase) for k in ("button", "reply", "default")):
            say(f"receipt line {phrase!r} isn't one the code sends")
    if "ack" in req:
        a, t = f["ack_tag"], f["tag"]
        if not re.search(rf"Tags: {t},{a}\b|`{t},{a}`|tag(?:ged|s)?\s+`?{t}`?\s+and\s+`?{a}`?(?![\w-])"
                         rf"|tag(?:ged)?\s+`?{a}`?(?![\w-])|`{a}`\s+tag", text):
            say(f"never says the ack is tagged `{a}` (with `{t}`)")
    if re.search(r"Ctrl-C", text) and any(r.startswith("outcomes:") and "interrupted" in r for r in req) \
            and not re.search(f["outcomes"]["interrupted"], text):
        say("mentions Ctrl-C but not the line the code sends then")

    if "settle" in req:
        prio = f["settle"]["priority"]
        if not re.search(rf"(?:['\"]priority['\"]: ?{prio}\b|priority {prio}\b)", text):
            say(f"doesn't say the settle update is sent at priority {prio}")
        if "actions" in f["settle"] or not re.search(r"no `?actions`?|no buttons", text):
            say("doesn't say the settle update carries no actions")
    rt, nr = f["reply_tag_prefix"], f["no_reply_tag"]
    if "reply_tag" in req and not re.search(re.escape(rt) + r"(?:<|\$NTF_AI_REQUEST|\{)", text):
        say(f"never shows the `{rt}<request id>` tag a reply typed on the question carries")
    for m in re.finditer(r"(?:tag(?:ged)?\s+`?|`)([a-z]+-)(?:<(?:request id|sequence_id|its request id|your request id|another id)|\$NTF_AI_REQUEST)", text):
        if m.group(1) != rt:
            say(f"writes the reply tag as {m.group(0)!r}; the code matches '{rt}<request id>'")
    if "no_reply" in req and not re.search(rf"tag(?:ged|s)?(?:\s+it|\s+the\s+question)?\s+`?{re.escape(nr or '?')}`?(?![\w-])|`{re.escape(nr or '?')}`\s+tag", text):
        say(f"doesn't say a --no-reply question is tagged `{nr}`")
    if "written_reply" in req and not re.search(rf"without the `?{tag}`? tag", text):
        say(f"doesn't say a written reply is a message without the `{tag}` tag")
    if "withdraw" in req:
        if not re.search(r"message_clear", text) or not re.search(r"/clear\b", text):
            say("doesn't warn that PUT /clear (message_clear) leaves the question waiting")
        if not re.search(r"DELETE|message_delete", text):
            say("doesn't say a delete takes the question out")

    for m in re.finditer(r"(?:timeout|--timeout|in seconds)[^\n.]{0,40}?\(?default (\d+)", text, re.I):
        if int(m.group(1)) != f["timeout_default"]:
            say(f"says the ask timeout defaults to {m.group(1)}; the code uses {f['timeout_default']}")
    for m in re.finditer(r"[Uu]p to (\d+)(?=[ ;)]|$)(?: (?:labels|buttons|action buttons))?", text):
        window = text[max(0, m.start() - 120):m.end() + 40]
        if re.search(r"button|label", window, re.I) and int(m.group(1)) != f["max_buttons"]:
            say(f"says up to {m.group(1)} buttons; the code allows {f['max_buttons']}")

    for m in re.finditer(r"2-(\d+) choices", text):
        if int(m.group(1)) != f["max_choices"]:
            say(f"says 2-{m.group(1)} choices; the code allows {f['max_choices']}")

    known_flags = set().union(*f["commands"].values()) | f["global_flags"]
    for flag in re.findall(r"`(--[a-z][\w-]*)", text):
        if flag not in known_flags:
            say(f"names the flag `{flag}`, which no ntf command accepts")
    for line in code_lines(text):
        for m in re.finditer(r"(?:^|[\s(|;&])ntf(?:-ai)? ([a-z]+)((?:\s+[^\s#|;&`]+)*)", line):
            cmd, rest = m.group(1), m.group(2)
            if cmd not in f["commands"]:
                if cmd not in ("command",):
                    say(f"shows `ntf {cmd}`, which isn't a command (have: {', '.join(sorted(f['commands']))})")
                continue
            for flag in re.findall(r"(?<![\w-])(--?[a-zA-Z][\w-]*)", rest):
                if flag not in f["commands"][cmd] | f["global_flags"]:
                    say(f"shows `ntf {cmd} {flag}`, which `ntf {cmd}` doesn't accept")

    if app is not None and "app" in req:
        if app.get("reply_tag") and app["reply_tag"] != tag:
            say(f"the app gives a reply box to questions tagged {app['reply_tag']!r}, the CLI tags {tag!r}")
        days = app.get("max_age_days")
        if days and not re.search(rf"\b{days} days\b", text):
            say(f"doesn't say a question waits at most {days} days (the app's WaitingRule.maxAge)")

    for p in paragraphs(text):
        if any(t in p for t in APP_126_TERMS + (rt + "<",)) and APP_126_MARK not in p and not p.lstrip().startswith("#"):
            say("describes 1.26 behaviour without saying so: " + re.sub(r"\s+", " ", p.strip())[:100])
    return errs


def check_generated(guide_path, src):
    """The served pages must be built from the current source (build-docs-pages.py)."""
    errs = []
    site = os.path.dirname(os.path.dirname(guide_path))
    llms = os.path.join(site, "ntfyme-seo", "llms-full.txt")
    page = os.path.join(site, "ntfyme-docs", "agents.html")
    if os.path.exists(llms):
        full = read(llms)
        m = re.search(r"Source: https://ntf-ai\.app/docs/agents\n(.*?)(?:\n---\n|\Z)", full, re.S)
        want = re.sub(r"\]\((/[^)]*)\)", r"](https://ntf-ai.app\1)", src)
        norm = lambda s: "\n".join(l.rstrip() for l in s.strip().splitlines())
        if not m or norm(m.group(1)) != norm(want):
            errs.append("llms-full.txt: the agents section isn't the current guide; run build-docs-pages.py")
    if os.path.exists(page):
        text = html.unescape(re.sub(r"<[^>]+>", "", read(page)))
        for block in re.findall(r"```\w*\n(.*?)```", src, re.S):
            if block.strip() not in text:
                errs.append("agents.html: a code block differs from the guide source; run build-docs-pages.py: "
                            + block.strip().splitlines()[0][:80])
    return errs


# ---------------------------------------------------------------- run the guide's recipe

TINY_PNG = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                         "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082")


def recipe(src):
    """Sections 1-5 as one bash script, plus the inline delete command."""
    start = src.index("## 1.")
    end = src.index("\n## ", src.index("## 5."))
    body = src[start:end]
    blocks = re.findall(r"```sh\n(.*?)```", body, re.S)
    delete = re.findall(r"`(curl -X DELETE [^`]+)`", body)
    return blocks, delete


def run_recipe(src, server, n, f):
    errs = []
    blocks, delete = recipe(src)
    if not delete:
        errs.append("guide: section 5 has no `curl -X DELETE` command to drop a question")
    # Then a reply to another question arrives, and the guide's read step runs again: it must skip that one.
    read_step = next((b for b in blocks if "Written reply:" in b), "")
    other = (f'curl -fsS -o /dev/null -H "Tags: {f["reply_tag_prefix"]}0000000000000000" '
             '--data-binary "meant for another question" "$NTF_AI_URL"\n')
    script = "set -euo pipefail\n" + "\n".join(blocks + delete) + "\n" + other + read_step + "\n"
    script = script.replace("https://ntf-ai.app", server.rstrip("/"))
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "screenshot.png"), "wb") as fh:
            fh.write(TINY_PNG)
        p = subprocess.run(["bash", "-c", script + 'printf "TOPIC=%s\\nREQUEST=%s\\n" "$NTF_AI_TOPIC" "$NTF_AI_REQUEST"\n'],
                           cwd=tmp, capture_output=True, text=True, timeout=300)
    if p.returncode != 0:
        return [f"guide recipe failed (exit {p.returncode}): {p.stderr.strip()[-400:]}"]
    out = p.stdout
    env = dict(re.findall(r"^(TOPIC|REQUEST)=(.*)$", out, re.M))
    if "Button answer: approve" not in out:
        errs.append("guide recipe: the wait step didn't print the simulated Approve")
    if "Written reply: Please wait for my review" not in out:
        errs.append("guide recipe: the read step didn't print the written reply")
    if "meant for another question" in out:
        errs.append(f"guide recipe: the read step took a reply tagged {f['reply_tag_prefix']}<another id>; "
                    "it must skip replies to other questions")
    if read_step and f["reply_tag_prefix"] + "$NTF_AI_REQUEST" not in "\n".join(blocks):
        errs.append(f"guide recipe: the simulated reply isn't tagged {f['reply_tag_prefix']}$NTF_AI_REQUEST "
                    "as the 1.26 reply box sends it")
    with urllib.request.urlopen(f"{server.rstrip('/')}/{env['TOPIC']}/json?poll=1&since=all", timeout=10) as r:
        msgs = [json.loads(l) for l in r if l.strip()]
    seq = env["REQUEST"]
    rows = [m for m in msgs if m.get("sequence_id") == seq]
    question = next((m for m in rows if m.get("event") == "message" and m.get("actions")), None)
    acked = lambda m: f["ack_tag"] in (m.get("tags") or [])
    ack = next((m for m in rows if m.get("event") == "message" and acked(m)), None)
    settled = next((m for m in rows if m.get("event") == "message" and not m.get("actions") and not acked(m)), None)
    if not question or not settled or not ack:
        return errs + ["guide recipe: expected a question, an ack and a full settle (the fallback) on the request's "
                       "sequence"]
    # The guide's ack must be the one `ntf ask` / `ntf ack` send.
    for key, server_key in (("tags", "tags"), ("priority", "priority")):
        if f["ack"][key] != ack.get(server_key):
            errs.append(f"guide recipe: ack {server_key} is {ack.get(server_key)!r}; ntf ack sends {f['ack'][key]!r}")
    if ack.get("actions") or ack.get("title"):
        errs.append("guide recipe: the ack carries actions or a title; ntf ack sends neither")
    # The guide's question must be the one `ntf ask` sends.
    want_actions = n.question_actions(f"{server.rstrip('/')}/{env['TOPIC']}{f['suffix']}", seq,
                                      [(a["label"], a["label"].lower()) for a in question["actions"]])
    keys = ("action", "label", "url", "method", "headers", "body")
    got = [{k: a.get(k) for k in keys} for a in question["actions"]]
    if got != [{k: a.get(k) for k in keys} for a in want_actions]:
        errs.append(f"guide recipe: question actions {got} differ from ntf ask's {want_actions}")
    if f["tag"] not in (question.get("tags") or []):
        errs.append(f"guide recipe: the question isn't tagged {f['tag']!r}")
    # The settle update must be the one `ntf ask` would send for that question.
    line = settled.get("message", "").rsplit("\n\n", 1)[-1]
    if not re.fullmatch("|".join(f"(?:{v})" for v in f["outcomes"].values()), line):
        errs.append(f"guide recipe: settle line {line!r} isn't one the code sends")
    want = settle_call(n, question, question["message"], line, question.get("title"), question.get("tags"))
    for key, server_key in (("body", "message"), ("title", "title"), ("priority", "priority"),
                            ("tags", "tags"), ("sequence_id", "sequence_id")):
        if want.get(key) != settled.get(server_key):
            errs.append(f"guide recipe: settle {server_key} is {settled.get(server_key)!r}; ntf ask sends {want.get(key)!r}")
    if not any(m.get("event") == "message_delete" for m in rows):
        errs.append("guide recipe: the delete command left no message_delete on the sequence")
    return errs


# ---------------------------------------------------------------- main

def check(cli_dir=CLI_DIR, guide=None, app=None, server=None):
    n = load_cli(cli_dir)
    f = facts_from_cli(n, cli_dir)
    app_facts = facts_from_app(app) if app else None
    errs = []
    for name, text in cli_surfaces(n, cli_dir).items():
        kind = "SKILL.md" if name == "ntf_ai.py SKILL_MD" else name
        errs += check_text(name, text, f, app_facts, kind)
    if guide:
        src = brand(read(guide), guide)
        errs += check_text("guide", src, f, app_facts)
        errs += check_generated(guide, src)
        if server:
            errs += run_recipe(src, server, n, f)
    return errs


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--cli-dir", default=CLI_DIR, help="folder holding ntf_ai.py and its texts")
    p.add_argument("--guide", default=os.environ.get("NTF_AI_GUIDE"), help="agent guide Markdown source (agents.md)")
    p.add_argument("--app", default=os.environ.get("NTF_AI_APP_SRC"), help="the app's ntfy/ source folder")
    p.add_argument("--server", default=os.environ.get("NTF_AI_DOCS_SERVER"),
                   help="ntfy server to run the guide's recipe against")
    a = p.parse_args(argv)
    errs = check(a.cli_dir, a.guide, a.app, a.server)
    for e in errs:
        print(e)
    checked = "CLI" + (" + guide" if a.guide else "") + (" + app facts" if a.app else "") + (" + recipe run" if a.server and a.guide else "")
    print(f"check_docs: {checked}: {'OK' if not errs else str(len(errs)) + ' disagreement(s)'}", file=sys.stderr)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
