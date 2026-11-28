---
name: ntf-ai
description: "NTF-AI (ntf): phone notifications and replies for AI agents. Speaks the ntfy protocol; use it when someone asks for ntf, NTF-AI or ntfy notifications, wants their phone to buzz when a job finishes or needs them, wants to approve or answer an agent from their phone, or wants a screenshot or file sent to their phone."
---

# NTF-AI (ntf): reach the person's phone, and read their answer

NTF-AI is an iPhone and iPad app. You publish to a topic with one HTTP request; the person's phone, subscribed to that
topic, shows it. They can tap an Approve/Reject button or write a reply (text or a photo) that you read back. No
account, SDK or API key on the default server `https://ntf-ai.app`. It speaks the ntfy protocol, so any ntfy server
works too, including a self-hosted one (`--server` or `NTF_SERVER`). Its short name is `ntf`.

The `ntf` command (also installed as `ntf-ai`) wraps everything below. If it isn't installed, every step has a plain
`curl` form; nothing requires the CLI. To install it (from ntf 0.4.0): `pipx install ntf-ai`, `brew install
legitimate-apps/tap/ntf-ai`, or the single file `curl -fsSL https://ntf-ai.app/ntf -o ntf && chmod +x ntf`. Never run or install a command named `ntfy` for this: that is the ntfy project's
own CLI, a different program.

## 1. Set up once: a topic and one tap from the person

The topic name is the password: anyone who knows it can read and post. Keep it long and random, and keep it out of
repos, logs, screenshots and shared transcripts.

```sh
ntf topic new --save        # makes agent-<32 hex>, saves it to ~/.config/ntf-ai/config.json (mode 600)
ntf link                    # prints https://ntf-ai.app/<topic>; on a terminal also draws a QR code
ntf link --qr-png qr.png    # or a PNG you can show the person
```

Without the CLI: `TOPIC="agent-$(python3 -c 'import secrets; print(secrets.token_hex(16))')"`, link
`https://ntf-ai.app/$TOPIC`.

Give the person only that link. With the app installed, opening it on their iPhone offers the subscription and they
confirm **Subscribe**; or in the app, **+ → Scan QR code**. Nothing subscribes without their confirmation. They must
never subscribe to the `<topic>-answers` topic (button answers go there so a tap doesn't buzz their phone again). Send a
test and ask them to confirm it arrived before relying on the channel: an HTTP 200 proves the server took it, not that
the phone showed it.

## 2. Notify

```sh
ntf send "Build finished: 0 failures"
ntf send --title "Deploy" --priority high --tags rocket "Deployed v2 to staging"
ntf send --attach screenshot.png "Here is the page after the fix"     # uploads the file; the phone shows the image
ntf send --attach-url https://example.com/report.pdf "Report is ready"
```

Without the CLI (tag every message you send `agent`, so your messages are never mistaken for the person's replies):

```sh
curl -fsS -H 'Tags: agent' -d 'Build finished' "https://ntf-ai.app/$TOPIC"
curl -fsS -H 'Tags: agent' -H 'Filename: screenshot.png' -H 'Message: Here is the page' -T screenshot.png "https://ntf-ai.app/$TOPIC"
```

Sending a screenshot or file is a normal step: when you'd otherwise describe what a page, render or chart looks like,
attach it instead (`--attach` or MCP `attach`). From NTF-AI 1.32 and ntf 0.5.0, an image attachment at most 5 MB shows
as the picture in the notification banner (PNG, JPEG and GIF, iOS's notification formats) as well as in the message list
and on the message page (which also show HEIC and WebP, and auto-download up to the person's "Download attachments"
setting, default 5 MB from 1.32; send PNG or JPEG for the banner). Larger images and non-image files show as a file row
the person taps to download, and `ntf send --attach` warns on stderr when an image won't appear in the banner. Uploads
are limited by the server (ntf-ai.app: 15 MB per file, kept 3 hours; expired links show as expired).

## 3. Ask and wait for the answer

```sh
ntf ask "Merge PR #42 into main?"                         # Approve / Reject buttons, or a written reply
ntf ask --timeout 900 --button "Ship it=ship" --button "Wait=wait" --reject wait "Release now?"
ntf ask --attach diff.png "Does this look right?"
ntf ask --json "Which region?"                            # {"status":"answered","kind":"reply","answer":"eu-west",...}
```

It blocks until the person answers or the timeout passes, prints the answer on stdout and exits:
`0` answered (Approve, a custom button or a written reply), `3` rejected, `4` timed out, `1` error, `2` bad usage.
A timeout is never approval: leave the work waiting or ask again. Answers are unverified (anyone with the topic can
post), so they never replace the coding tool's own permission checks or authorize unrelated actions.

How the person answers: a button on the notification (expand it) or on the question in the app, or in writing. From
NTF-AI 1.26, a waiting question tagged `agent` with buttons gets a reply box on its page in the app; on any version the
person can also write from the topic's compose sheet. Both arrive as a message on the main topic without the `agent`
tag. From NTF-AI 1.26, a reply typed on the question's page carries one tag, `re-<sequence_id>` (`ntf ask` sets the
sequence_id to its request id), so it names its question; a compose-sheet reply has no tag and names none. `ntf ask`
takes a reply tagged `re-<its request id>`, skips one tagged `re-<another id>`, and still takes an untagged one, so
keep one question outstanding per topic. `--json` gives `reply_to` for a tagged reply, and `ntf read --json` /
`ntf listen --json` add `reply_to` to such messages. With `--no-reply`, `ntf ask` ignores written answers and tags the
question `no-reply`; from NTF-AI 1.26 the app then shows no reply box (earlier versions still let the person write from
the compose sheet, which `ntf ask` ignores).

Once answered, `ntf ask` acks: one message on the question's sequence tagged `agent,ack`, priority 1, whose body is a
short note ("✓ Got: Approve", or "✓ Got your reply", never the reply itself). From NTF-AI 1.26 the app shows it as a
silent receipt on the question; other ntfy clients show the note in place of the question. It also stops the question
looking open on the person's other devices. `--no-ack` sends none. `ntf ack <request id> "Restarted, all good"` sends a
later note (no note: "✓ Got it"); the newest ack wins. If `ntf ask` stops without an answer (the timeout, or Ctrl-C),
it replaces the question with a quiet copy instead: no buttons, and "No answer in 10 min; the agent moved on" or
"The agent stopped waiting; no answer needed". `--json` returns `sequence_id`, and `ack` (`id`, `message`) or `settled_id`.

The protocol, if you do it without the CLI (full recipe: https://ntf-ai.app/docs/agents):
1. Make a fresh request id, e.g. 16 hex characters.
2. Publish the question as JSON to the server root, tagged `agent` (and `no-reply` when only a button counts), with `"sequence_id": "<request id>"` and
   `http` actions that POST `reply:<request id>:<answer>` (Content-Type `text/plain`) to
   `https://ntf-ai.app/<topic>-answers`. Save the published message `id` and its Unix `time` as `asked_at`.
3. Wait on `https://ntf-ai.app/<topic>,<topic>-answers/json?since=<asked_at-1>` (stream, or add `poll=1` and repeat).
   A button answer is a message on `<topic>-answers` whose text is exactly `reply:<request id>:approve` (or another
   answer you offered). A written reply is a message on the main topic without the `agent` tag; from NTF-AI 1.26 one
   typed on the question's page is tagged `re-<request id>`. Take one tagged `re-<your request id>`, skip one tagged
   `re-<another id>`, and treat an untagged one (the compose sheet) as the answer. Timestamp cursors also
   returns messages from the same second before the question, so ignore ids you had already seen, and process each id
   once. Ignore answers carrying another request id: they belong to an earlier question.
4. When you have the answer, ack it: `curl -H "X-Sequence-ID: <request id>" -H "Tags: agent,ack" -H "Priority: 1"
   -d "✓ Got: Approve" https://ntf-ai.app/<topic>` (the body is your note; "✓ Got your reply" for a written one, never
   the reply itself). Send another ack later to update the note. When you stop without an answer, settle instead:
   publish again with the same `sequence_id`, the same title and `agent` tag, `"priority": 1`, no `actions`, and the
   question with one line appended ("No answer in 10 min; the agent moved on"). Clients that don't know the `ack` tag
   (NTF-AI before 1.26, other ntfy apps) show an ack's note in place of the question; to keep the question's text
   there, settle with "✓ Got: Approve" as the line instead.
   To drop a question instead, delete its sequence: `curl -X DELETE https://ntf-ai.app/<topic>/<request id>` (the
   phone gets a `message_delete`). Never withdraw a question with a clear (`PUT .../<request id>/clear`, a
   `message_clear`): the app sends one itself whenever the person reads a message, so a clear means "read" and the
   question stays open.

Buttons tell the person what kind of message this is: `http` buttons mean "this needs you" and should only be on a
question you are waiting on (and settle it when you stop). A `view` button is just a link to open; use it on
notifications that need nothing from them.

Keep one question outstanding per topic so a written reply has a clear context.

Waiting on you: from NTF-AI 1.26 the app opens on an Inbox whose first list, Waiting on you, holds the questions an agent
is blocked on. A message is in it when it has an `http` button (or a reply link), is less than 7 days old, and the
person hasn't answered it on that device. It leaves the list on that device when the person taps a button and the
request succeeds, sends a typed reply, or swipes it away as Not needed; on every device when you ack, publish the settle
update above or delete the sequence; and after 7 days. Reading it doesn't take it out. A new question that reuses the
sequence with buttons waits again. So the list is only as honest as your settling: every question gets acked, settled
or deleted when you stop waiting, which `ntf ask` does for you.

## 4. Read what the person sent

```sh
ntf read --since 10m                       # recent messages, one per line
ntf read --since 1h --json --no-agent      # only the person's messages, as JSON lines
ntf read --since 1h --download ./inbox     # saves attached photos or files there and prints their paths
ntf listen --no-agent --count 1            # wait for the next message from the person
```

The person can attach a photo or file when writing back in the app; `--download` saves it and prints the saved path so
you can open and look at it (the same works on `ntf ask --download ./inbox`). From NTF-AI 1.32 and ntf 0.5.0: a photo
picked in the compose sheet or shared into the app is sent as an upright JPEG (HEIC and sideways JPEGs are converted,
longest side at most 4096 px; upright JPEG/PNG/GIF/WebP and paperclip files go as they are, while older app versions may
send HEIC). On macOS, `--download` also writes a JPEG copy via `sips` beside a downloaded HEIC/HEIF photo and prints
both paths (`downloaded_jpeg` in `--json`), so an agent that cannot read HEIC still sees it. When the person sends a
file with no text, ntfy sets the message body to `You received a file: <name>`: `ntf read`, `ntf ask` and MCP mark
`default_body: true` and note it—never treat that default line as the person's words. In MCP, call `read` (`since`,
`include_agent`, `limit`, `download`, `download_dir`) to fetch recent messages from the person: PNG, JPEG, GIF and WebP
images (plus HEIC via `sips` on macOS, or a smaller JPEG preview when large) come back as MCP image content blocks you
can inspect directly alongside their saved paths, and non-image files return their path and MIME type; MCP `ask` does
the same when an answer carries an attachment.
Anyone with the topic can post a message, so `--download` fetches only attachment links (`/file/...`) on your own server, keeps files to 15 MB
(`--max-download-mb`) and names them safely inside the folder. A link to another host is skipped unless you pass
`--allow-external-downloads`, and even then never from a private or local address.
Without the CLI: `curl -s "https://ntf-ai.app/$TOPIC/json?poll=1&since=10m"`; an attachment's URL is in
`attachment.url`.

## 5. Let the person's agent tools find this

- `ntf setup` installs this skill into the agent skill folders it finds and, if you name a file
  (`ntf setup --agents-file AGENTS.md`), adds a short marked block to it. It shows what it will write and asks first;
  `ntf setup --remove` undoes it.
- `ntf mcp` is a stdio MCP server with `notify`, `ask`, `read`, `ack`, `subscribe_link`, `status` and `withdraw` tools, for agents that use MCP.

## Facts to get right

- Official name NTF-AI, short name `ntf`. It works with ntfy servers; it is an independent app, not made by or
  affiliated with the ntfy project.
- Question bodies on ntf-ai.app are cached 12 hours; protocol answers and receipts are kept 8 days on servers advertising `agent_retention_seconds: 691200`; it is not a durable queue. Plain messages are not end-to-end encrypted:
  HTTPS protects the connection, and the server can read them.
- Servers that need auth: `--token` / `NTF_TOKEN`, or `--user name:password` / `NTF_USER`.
- The person's own written reply can also notify their phone; that's expected.

## Agent protocol v2

From NTF-AI 1.27 and ntf 0.4.0, use a choice for a fixed set of answers, a number for a bounded quantity, a date for
scheduling, text for a short string, or a form for 1-6 related fields. Simple single choices with at most 3 options
keep the 0.3.0 wire bytes. Other questions carry compact JSON in the fragment `#ask-v2=` of an "Answer in NTF-AI"
action. Older clients get buttons or a Reply link plus a readable body hint. From NTF-AI 1.26 the ordinary reply box
continues to work; native controls require 1.27.

```sh
ntf ask --button Staging=staging --choice 'Production!=prod' 'Deploy where?'
ntf ask --choice Logs=logs --choice Metrics=metrics --choice Traces=traces --multi 'Collect what?'
ntf ask --spec '{"kind":"number","min":1,"max":64,"step":0.5,"unit":"GB"}' 'Memory?'
ntf ask --spec '{"kind":"date","mode":"date","min":"2026-11-15","max":"2026-12-31"}' 'Which day?'
ntf ask --spec '{"kind":"text","max":60,"placeholder":"Branch name"}' 'Which branch?'
ntf ask --spec '{"kind":"form","fields":[{"k":"branch","kind":"text","l":"Branch","max":60},{"k":"n","kind":"number","l":"Replicas","min":1,"max":5}]}' 'Deploy settings?'
ntf ask --expires 2h --remind 5m,15m --escalate --as deploy-bot --avatar https://example.com/deploy-bot.png 'Proceed?'
ntf status <request id> --json
ntf status <request id> --wait --timeout 600
ntf withdraw <request id>
```

`--button` (or `-b`) and `--choice` are the same option: `LABEL[=ANSWER]`, repeated for 2-12 choices.
Without `=ANSWER`, the label becomes a lowercase key with spaces replaced by hyphens. Up to 3 choices use the
original buttons; more use the native picker. Labels ending in `!` are literal. `--multi` allows several selections.
For constraints or other kinds use `--spec JSON`, or `--spec @question.json`. It accepts the wire schema object
(`v` defaults to 2): `kind` is choice, number, date, text or form. No additional schema flags are needed. For multi-select, use `{"kind":"choice","multi":true,"options":[{"k":"a","l":"A"},{"k":"b","l":"B"}]}`; `multi` is not a kind.

A choice spec has `options:[{"k":"go","l":"Go!","d":true},{"k":"stop","l":"Stop"}]`; `d:true` alone marks a
destructive choice. `multi:true` enables selection-count `min`/`max`. Number bounds are inclusive; `step` defaults
to 1 from `min` (or zero), and `unit` is display only (12 characters). Date `mode` is date (`YYYY-MM-DD`), time
(`HH:MM`) or datetime (default, RFC 3339 with an offset); bounds use the same format. Text `max` is 1-1000
characters (default 200); `placeholder` is at most 60. A form's `fields` array has 1-6 objects with `k`, `l`, `kind`
and the corresponding kind constraints, plus `opt:true` for optional fields. Nested forms and multi-choice fields
are not supported. Schemas are limited to 1536 UTF-8 bytes; option/field labels to 40 characters.

Free replies keep the NTF-AI 1.26 behavior. The 1.27 app sends structured answers on the main topic with tags `re-<request id>,ans`. Without `ans` the result
stays `kind: reply`. `--json` returns the raw `answer`, normalized `value`, `type`, `valid`, `authenticated`, and
`reply_to` for tagged replies. Free replies accept option keys, labels (case-insensitive) or 1-based numbers; multi
choice numbers are comma-separated. Number answers use a dot, dates use ISO format, and forms accept a JSON object
or one `Label: value` line per field. Invalid JSON results retain `valid: false`. Plain output retains the raw answer, warns on stderr and exits 6;
`--strict` keeps waiting instead.
From ntf 0.4.0, plain output and the MCP text print a valid typed answer the way the 1.27 answer form sends it (the choice key, keys
comma-separated, the number, date or text, a form as compact JSON), whichever app answered. When a written reply answered a
typed question (NTF-AI before 1.27, or another ntfy app), stderr says so and how it was read, e.g. `read '2' as 'staging'`;
under `--json` that answer is `kind: reply`.
`--no-reply` removes the fallback reply link and ignores free replies, while native structured answers still work;
it warns for free-form kinds because older clients then have no answer path. Exit 5 means withdrawn; existing exit
codes remain 0 answered, 3 rejected, 4 timed out, 1 error, 2 usage.

`--expires` accepts 60s to 7d and caps the wait at the schema's `exp` deadline. A timeout still settles at priority 1
with no actions. `--remind` accepts at most 3 offsets at least 5 minutes apart, such as 5m,15m. While the agent keeps
waiting, it republishes the same sequence/body with increasing `rem`; `--escalate` raises priority by one per reminder,
capped at 4 (an explicit 5 stays 5). From NTF-AI 1.27 the app can alert for these reminders; older apps keep updates
silent. `--no-wait` publishes and prints the request id (JSON returns pending), with no background reminders; use status to read the answer later.

`ntf status` folds linked server events into withdrawn, acked, answered, settled, expired, seen, pending or unknown
(in that precedence). Seen means read or dismissed on some device, not proof a person read it. A clear
(`message_clear`) records that observation; `ntf withdraw` sends DELETE and produces `message_delete`. A withdrawn plain ask explains why it stopped on stderr. Status polls
from the publication's server Unix timestamp, so local clock skew and an expired question row cannot hide answers. `asks.jsonl`, next to the config,
is mode 600, pruned at 30 days, and stores schemas, request metadata and observed outcomes. Answer text is stored
only for plain topics; encrypted asks save outcome state and timestamps without the answer. A write failure warns
and the ask keeps waiting. Without server caching, untagged legacy replies in the poll/publish window are ambiguous;
use replies tagged `re-<request id>` (from NTF-AI 1.26) when questions overlap.
`ntf status --topic TOPIC <request id>` works without a ledger; its answers have `valid: null`. Keep the ledger private.

From NTF-AI 1.26 free replies still use `re-<request id>`; without `ans` they have normal retention.
Question bodies, ordinary messages and free replies expire after 12 hours. On servers advertising `agent_retention_seconds: 691200`, structured
`ans,re-<id>` answers, `agent,ack` receipts, clear/delete events and `-answers` topic rows are kept 8 days; older servers default to 12 hours. Past advertised retention, status reports unknown unless it has an observed
outcome or linked server evidence. It reads `agent_retention_seconds` when advertised; this CLI does not change
server retention. `--as` uses the flag, `NTF_AGENT`, then config `agent_name`; names are 1-32 letters, digits, spaces,
periods, underscores or hyphens. `--avatar` carries an https URL as ntfy `icon`. Plain-topic names, icons and answers
can be forged by anyone who knows the topic. Plain answers report `authenticated: false`.

MCP `ask` accepts `kind`, `options` (`k`, `l`, optional `d`), `multi`, `min`, `max`, `step`, `unit`, `mode`, `fields`,
`placeholder`, `expires`, `remind`, `escalate`, `as`, `avatar`, `strict`, `wait`, `download` and `download_dir`. With `wait:false` it returns pending
immediately. The MCP tools are `notify`, `ask`, `read`, `ack`, `subscribe_link`, `status` and `withdraw`; `read` accepts
`since`, `include_agent`, `limit`, `download` and `download_dir`, status accepts
`request_id`, `wait`, `timeout_seconds`, and withdraw accepts `request_id`. From ntf 0.5.1, MCP `read` is not marked read-only, since it saves files; MCP `download_dir` must be inside the
inbox `~/.cache/ntf-ai/inbox` (a relative name is a subfolder of it, anything else is refused; the CLI's `--download`
folder is not limited), and `sips` converts only image files up to 25 MB.

## End-to-end encryption with ntf

Set the same topic password in the app and in the shell running `ntf`. No packages or extra service are needed:

```sh
# Load the password from your secret manager, or enter it without putting it in shell history:
export NTF_TOPIC_PASSWORD="$(python3 -c 'import getpass; print(getpass.getpass("Topic password: "))')"
ntf send 'Private build result'
ntf ask --spec '{"kind":"number","min":1,"max":64,"unit":"GB"}' 'Memory?'
```

`NTF_TOPIC_PASSWORD` enables encryption for send, questions, reminders, settles and acknowledgements, and decrypts
read, listen, ask and status. MCP inherits it from its process environment too. `--password-env VAR` chooses another
environment variable; `--password-file PATH` reads a UTF-8 file, trimming only trailing newlines. Password values
never go in command arguments. Keep the password file private. Config `"topics":{"TOPIC":{"e2e":true}}` requires a
password for that topic, so a missing secret fails before publishing. The private ledger stores metadata and schemas, but omits observed answer text for encrypted asks.

The format matches NTF-AI 1.26 and later: AES-256-GCM compact JWE, PBKDF2-HMAC-SHA256 with 50,000 rounds, and a random 12-byte IV.
The bare public alias on its standard HTTP/HTTPS port derives with `https://ntfy-me.com/<topic>`. Other server
URLs use the exact spelling stored in the app (including host case and any path or custom port), without trailing
slashes; use the same spelling in both clients. Message,
title, tags, priority, links, icon, Markdown and actions are encrypted together. The outer topic, sequence id and
protocol tags (`agent,ack`, `re-<id>,ans`) remain visible for routing and retention; authenticated inner tags are trusted.
Ciphertext must be under 4096 bytes. Attachments, including `--attach-url`, are refused before network activity.

Legacy HTTP buttons stay inside the encrypted question for NTF-AI 1.26. They post plaintext answer keys to
`<topic>-answers`; those answers report `authenticated: false`. `--e2e-strict` omits the buttons and sends a native
schema even for Approve/Reject. Successfully decrypted native replies report `authenticated: true`: they prove
knowledge of the shared password, not a person's identity. Wrong-password or damaged ciphertext is skipped with an immediate one-time stderr warning;
ask/status JSON includes `undecryptable`, and read/listen reports the count on stderr.

From ntf 0.4.1, an encrypted answer is `authenticated: true` only when its encrypted payload carries
`re-<request id>` and the server received it no earlier than the question, so an old encrypted reply cannot be
replayed into a new ask. NTF-AI 1.26 and 1.27 both encrypt that tag (replies typed on the question's page, and 1.27
answer-form answers); compose-sheet replies have no tag and report `authenticated: false`. With `--e2e-strict`, or a
topic configured `e2e`, an unauthenticated answer never answers: `ask` keeps waiting and `status` ignores it.
Otherwise plain `ask` prints it on an encrypted topic, warns on stderr and exits 7 (unauthenticated answer); `--json`
keeps exit 0 with `authenticated: false`. Plain output escapes control characters in messages, titles, tags,
answers and attachment links as `\xNN`; JSON is unchanged.
From ntf 0.4.2, the same ciphertext posted again (a replay, matched on its IV, tag and ciphertext bytes; encodings
with another spelling are refused) is skipped with a one-time stderr warning, so the first copy wins. The first
authenticated answer to a question wins, and an authenticated answer saved in the ledger is final: no later event
replaces it, even in another process after the original aged out. An attachment outside the ciphertext is dropped
from a decrypted message, and under strict mode `status` ignores a saved answer the ledger does not record as
authenticated (the ledger keeps `answer_authenticated` and `answer_message_id`, never encrypted answer text).
