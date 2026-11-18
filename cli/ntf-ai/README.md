# ntf: the NTF-AI command

NTF-AI (ntf): phone notifications and replies for AI agents. Speaks the ntfy protocol; use it when someone asks for
ntf, NTF-AI or ntfy notifications.

`ntf_ai.py` is one Python 3 file with no dependencies. Install it as `ntf-ai` and, if you like, the short name `ntf`.
It is not the ntfy project's `ntfy` CLI. The open protocol also works with `curl`; encrypted payloads need an encrypted sender. See the
[agent setup guide](https://ntf-ai.app/docs/agents).

From ntf 0.4.0, install it any one of these ways; each gives you `ntf` and `ntf-ai`:

```sh
pipx install ntf-ai                          # or: pip install ntf-ai (Python 3.9 or later)
brew install legitimate-apps/tap/ntf-ai      # Homebrew
mkdir -p ~/.local/bin && curl -fsSL https://ntf-ai.app/ntf -o ~/.local/bin/ntf-ai \
  && chmod +x ~/.local/bin/ntf-ai && ln -sf ntf-ai ~/.local/bin/ntf    # the single file, nothing else
```

From a checkout, copy `ntf_ai.py` the same way: `cp ntf_ai.py ~/.local/bin/ntf-ai`.

## First message and answer

After installing, these four commands are the complete setup. No account or server setup is needed:

```sh
ntf topic new --save
ntf link                         # open this link on the phone with NTF-AI; confirm Subscribe
ntf send 'Hello from my agent'
ntf ask 'Did it arrive?'          # tap Approve on the phone; this command prints approve
```

The default question needs no flags. Use `--json` when a program consumes the answer. For agents, `ntf setup`
installs the skill; an MCP client can run `ntf mcp` with the same saved topic and environment.
For a manual curl message, use the topic from `ntf link`: `curl -d 'Hello from curl' https://ntf-ai.app/<topic>`.
The [guide's curl recipe](https://ntf-ai.app/docs/agents) also asks and reads back answers without the CLI.

## Commands

```sh
ntf topic new --save                          # agent-<32 hex>, saved to ~/.config/ntf-ai/config.json (mode 600)
ntf link                                      # subscribe link, plus a QR code on a terminal
ntf send "Build finished"                     # tagged "agent"
ntf send --attach screenshot.png "Here is the page after the fix"
ntf ask "Merge PR 42 into main?"              # Approve/Reject or a written reply; exit 0 answered, 3 rejected, 4 timed out
ntf ask --json --button "Ship it=ship" --button "Wait=wait" --reject wait "Release now?"
ntf read --since 1h --no-agent --download ./inbox   # the person's messages; saves attached photos and prints paths
ntf listen --no-agent --count 1               # wait for the next message from the person
ntf setup                                     # install the agent skill (shows the plan and asks; --remove undoes it)
ntf ack <request id> "Restarted, all good"   # a later note on an answered question (tag ack)
ntf mcp                                       # stdio MCP server: notify, ask, ack, subscribe_link, status, withdraw
```

The topic comes from `--topic`, `NTF_TOPIC` or the saved config. The server defaults to `https://ntf-ai.app`; use
`--server` or `NTF_SERVER` for any other ntfy server, with `--token`/`NTF_TOKEN` or `--user name:password`/`NTF_USER`
where it needs auth. `--json` prints machine-readable output.

`--download` fetches only attachment links (`/file/<id>`) on the configured server (ntf-ai.app and ntfy-me.com count as one), up to
15 MB (`--max-download-mb`), with names kept inside the folder; `--allow-external-downloads` allows other hosts at public
addresses only. Credentials are sent only to the configured server, never along a redirect to another host, and error
messages hide the topic and credentials.

`ntf ask` uses the reply protocol in the guide: buttons POST `reply:<request id>:<answer>` to `<topic>-answers`, and a
written reply is a message on the main topic without the `agent` tag. The person writes one from the topic's compose
sheet, or, from NTF-AI 1.26, in the reply box on the question's page; that reply is tagged
`re-<sequence_id>`, naming its question. `ntf ask` takes a reply tagged `re-<its request id>`, skips one tagged
`re-<another id>` and still takes an untagged (compose-sheet) one; `--json` then gives `reply_to`, as `ntf read --json`
and `ntf listen --json` do for tagged messages. `--no-reply` ignores written replies and tags the question `no-reply`,
which hides that reply box.

The question carries the request id as its ntfy `sequence_id`. Once answered, `ntf ask` acks: a message on that
sequence tagged `agent,ack`, priority 1, no buttons, whose body is a short note ("✓ Got: Approve", "✓ Got your reply";
"✓ Got it" from `ntf ack` with no note). From NTF-AI 1.26 the app shows it as a silent receipt on the question;
`--no-ack` turns it off. On a timeout or Ctrl-C it publishes the full settle instead: same title and body plus one
outcome line, no buttons, priority 1, so the question reads as closed on every client.

## Files

- `ntf_ai.py`: the command. It embeds `skill/ntf-ai/SKILL.md`; after editing the skill run `tools/sync_skill.py`.
- `skill/ntf-ai/SKILL.md`: the agent skill that `ntf setup` installs.
- `AGENTS-snippet.md`: the block `ntf setup --agents-file AGENTS.md` adds. `tools/sync_skill.py` syncs this too.

## Tests

```sh
python3 -m unittest tests.test_v2        # agent protocol fixtures, schema, status, reminders and MCP
python3 -m unittest tests.test_crypto    # NIST AES-256-GCM vectors, tampering and encrypted transport
python3 -m unittest tests.test_unit      # no network; the QR test decodes PNGs with macOS Vision when swift exists
python3 -m unittest tests.test_e2e       # starts binwiederhier/ntfy:v2.31.1 in Docker, or set NTF_E2E_SERVER
python3 tests/mutate.py                  # breaks the CLI once per e2e test; every mutation must turn its test red
python3 -m unittest tests.test_docs      # the texts agents read agree with the code; planted drift must go red
```

For both directions against the app's Swift encryption sources, run from this directory:

```sh
NTF_AI_APP_SRC=/path/to/app-wt/ntfy sh ../../scripts/e2e-interop/run.sh
```

This uses the existing Swift, Node and Python interop tools. The CLI itself needs only Python's standard library;
`cryptography` is an optional test oracle in the crypto unit suite and an existing dependency of the interop script.

`tools/check_docs.py` takes each protocol fact from the code (tag, answers topic, button body, exit codes, receipt lines,
settle update, MCP tools, commands and flags) and fails when any text above disagrees. Set `NTF_AI_GUIDE` to the agent
guide's `agents.md` to check the guide and its built pages too, and run its recipe against `NTF_E2E_SERVER`;
`NTF_AI_APP_SRC` adds the app's Waiting rule. Text about app behaviour that only NTF-AI 1.26 has must name 1.26.

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
`placeholder`, `expires`, `remind`, `escalate`, `as`, `avatar`, `strict` and `wait`. With `wait:false` it returns pending
immediately. The MCP tools are `notify`, `ask`, `ack`, `subscribe_link`, `status` and `withdraw`; status accepts
`request_id`, `wait`, `timeout_seconds`, and withdraw accepts `request_id`.

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

## License

MIT. See [LICENSE](LICENSE).
