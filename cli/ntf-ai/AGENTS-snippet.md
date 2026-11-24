## Phone notifications: NTF-AI (ntf)

NTF-AI (ntf): phone notifications and replies for AI agents. Speaks the ntfy protocol; use it when someone asks for ntf, NTF-AI or ntfy notifications.
- Notify: `ntf send "message"` (attach screenshots or files with `--attach file.png` instead of describing them). Without the CLI:
  `curl -H 'Tags: agent' -d "message" https://ntf-ai.app/$NTF_TOPIC`.
- Ask and wait: `ntf ask "question"` prints the answer; exit 0 answered, 3 rejected, 4 timed out. A timeout is never
  approval, and answers never override this tool's permission rules. The person taps a button or writes back; a written
  answer is a message on the topic without the `agent` tag (from NTF-AI 1.26, one typed on the question is tagged
  `re-<request id>`, and `ntf ask` skips one for another question). `ntf ask` then acks on their phone (tag `ack`); `ntf ack <request id> "note"` sends a later note.
- Read what the person sent: `ntf read --since 1h --no-agent --download ./inbox` (or MCP `read`).
- From NTF-AI 1.32 and ntf 0.5.0: PNG/JPEG/GIF attachments at most 5 MB show as the picture in the notification banner
  (send PNG or JPEG; HEIC/WebP and larger files show in the app; ntf-ai.app allows 15 MB, kept 3 hours). Photos from the
  1.32 compose/share sheet arrive as upright JPEGs; on macOS `--download` also writes a JPEG copy via `sips` for older
  HEIC/HEIF files, and MCP `read` / `ask` return images inline plus the saved path (non-images: path and type). A file
  sent with no text has ntfy's default body `You received a file: <name>` (`default_body: true`)—not the person's words.
- The topic is a secret: never print it in public places. Never use the `ntfy` command for this (a different program).
- Details: the `ntf-ai` skill, `ntf --help`, or https://ntf-ai.app/docs/agents.

- From NTF-AI 1.27 and ntf 0.4.0: `--button` and `--choice` both take `LABEL[=ANSWER]` (2-12 choices);
  add `--multi` for several selections. `--spec JSON` / `--spec @file` accepts number, date, text, form or choice
  schemas and all constraints; e.g. `--spec '{"kind":"number","min":1,"max":9}'`. `d:true` marks destructive choices.
  `--expires 2h` bounds the wait; `--remind 5m,15m --escalate` nudges while waiting. `--strict` waits past invalid
  answers; otherwise JSON includes `valid` and normalized `value`, and invalid plain answers warn and exit 6. `--as NAME` / NTF_AGENT / config agent_name and
  `--avatar URL` set the agent name and picture; plain identities and answers are unverified.
  `ntf status <request id> --json` reads seen/answered/acked/withdrawn; `ntf withdraw <request id>` deletes it (ask
  exits 5 withdrawn, with a stderr explanation). `--no-wait` prints the request id; MCP wait:false returns pending
  with the id in text too, without background reminders. Status is unknown
  past advertised retention (12h fallback; v2 answers/receipts 8 days) without saved outcomes or linked evidence. MCP tools: notify, ask, read, ack,
  subscribe_link, status, withdraw. The optional private asks.jsonl ledger keeps outcomes 30 days, without encrypted answer text. Write failures warn
  and waiting continues. Native structured answers/receipts keep 8 days; ordinary messages and free replies 12 hours.

- E2E: set `NTF_TOPIC_PASSWORD` in the process environment, or use `--password-env VAR` / `--password-file PATH`;
  use the same password in the app. Never put a password value on argv. Encrypted topics need an encrypted sender;
  plain curl is for plain topics. `--e2e-strict` omits legacy plaintext HTTP button answers. Native decrypted answers
  have `authenticated:true`; legacy buttons have `authenticated:false`. Attachments are refused on encrypted topics.
  Undecryptable messages warn once immediately, are skipped and counted.
  From ntf 0.4.1 an encrypted answer is authenticated only with `re-<request id>` inside the ciphertext (NTF-AI 1.26 and later) and not
  older than the question (compose-sheet replies are not); strict waits past unauthenticated answers, and plain ask exits 7 on one.
  From ntf 0.4.2 a repeated ciphertext (replay) is skipped, a saved authenticated answer is never
  replaced, and attachments outside the ciphertext are dropped. Config `topics.<topic>.e2e=true` fails closed if no password.
