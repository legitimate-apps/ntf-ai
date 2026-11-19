# NTF-AI

Let an AI agent or script reach your iPhone or iPad with one HTTP request. Answer a question with an action button, or write a reply in the app for the agent to read. NTF-AI is an independent iOS app for [ntfy](https://github.com/binwiederhier/ntfy), available on the **[App Store](https://apps.apple.com/us/app/id6787782178)**.

Start with the **[agent setup guide](https://ntf-ai.app/docs/agents)**: generate a long random topic, give the human a subscribe link, send a test, ask with Approve/Reject buttons, and read the answer. It includes a prompt for your agent and status-hook recipes for Claude Code and Codex. The human confirms the subscription and allows notifications. The guide's commands use standard ntfy publishing and polling.

```sh
# Subscribe to the same long random topic in the app, then from any terminal:
curl -d "Backup finished" https://ntf-ai.app/your-secret-topic

# Get notified when a long command ends
make build; curl -d "make finished: exit $?" https://ntf-ai.app/your-secret-topic
```

No account or API key: the topic name is the password, so pick a long random one. The topic is shared access: anyone who knows it can read, send or forge replies. These plain requests are not end-to-end encrypted. Button responses do not bypass your coding tool's permission checks. Written replies use the compose sheet in the app.

Or use the `ntf` command (MIT, Python 3.9+), which adds typed questions (choice, number, date, text, form) and end-to-end encrypted answers, plus an MCP server for agents:

```sh
pipx install ntf-ai            # or: brew install legitimate-apps/tap/ntf-ai
ntf topic new --save           # a long random topic, saved for later commands
ntf link                       # the subscribe link and a QR code for your iPhone
ntf ask --choice Ship --choice Wait "Release the update?"
```

See [cli/ntf-ai/README.md](cli/ntf-ai/README.md) for every command.

More recipes (Windows PowerShell, Python, GitHub Actions, Home Assistant, SSH login alerts) are on [ntf-ai.app](https://ntf-ai.app).

NTF-AI is an independent fork of [ntfy-ios](https://github.com/binwiederhier/ntfy-ios), published by Legitimate LLC. It is not affiliated with ntfy.sh or the ntfy project. It works through upstream's backlog of iOS issues: reliability and security fixes, end-to-end encrypted topics, display names, pinned topics, a simpler first-run setup, and general UX work. See [CHANGELOG.md](CHANGELOG.md) for each release.

## How it relates to ntfy

- **ntfy** is the server and protocol, plus the official Android, iOS and web apps, by Philipp C. Heckel. NTF-AI is an independent iOS app that speaks the same protocol. It is not affiliated with ntfy.sh or the ntfy project.
- **Servers:** NTF-AI works with any ntfy server. Its built-in server is ntfy-me.com, also available at ntf-ai.app. Self-hosted servers get instant push with one config line (below).
- **ntfy.sh topics** work too, but without instant banners. ntfy.sh relays iOS push only to the official app, so in NTF-AI those messages show up when you open or refresh the app. For instant banners, use ntf-ai.app or your own server.
- **Android, desktop or browser:** use the official ntfy Android app or the [web app](https://ntf-ai.app/app), pointed at the same server and topic.

## Using the app

Setup guides live at **[ntf-ai.app](https://ntf-ai.app)**:

- [Agent setup](https://ntf-ai.app/docs/agents): subscription links, questions, button answers and written replies; Claude Code and Codex recipes.

- [Quick start](https://ntf-ai.app/#qs): subscribe to a topic and send your first notification with one `curl` command.
- [Run your own server](https://ntf-ai.app/docs/self-hosting): self-host ntfy with Docker and still get instant notifications.
- [Server compatibility and push delivery](https://ntf-ai.app/docs/migrate)
- [Support](https://ntf-ai.app/docs/support), including end-to-end encrypted topics.

## Servers

The app's built-in server is **ntfy-me.com**, also available at **ntf-ai.app**, a free public ntfy server run by the app's publisher. Both hosts reach the same topics and messages. It is not affiliated with ntfy.sh or the ntfy project. Push notifications carry no message text: Google and Apple see the topic name and a message ID, and the app fetches the message from the server. ntf-ai.app keeps messages for 12 hours and attachments for 3 hours.

Any ntfy server works. If you self-host, add this to your `server.yml` for instant push to this app:

```yaml
upstream-base-url: "https://ntfy-me.com"
```

(The ntfy docs' example uses `https://ntfy.sh`, which pushes to the official ntfy app, not this one.)

## End-to-end encrypted topics

Give a topic a password (topic menu → **End-to-end encryption**) and messages sent to it with that password are encrypted in transit and on the server: the server, Google and Apple see ciphertext. Once they arrive they are stored readable on this device, like any other notification. The app shows copy-paste Node.js and Python senders for the topic. It uses the format from ntfy's own end-to-end encryption draft (JWE, AES-256-GCM, PBKDF2-SHA256), so other clients that adopt that draft can interoperate. Details: [support](https://ntf-ai.app/docs/support#end-to-end-encrypted-topics).

## Reporting a bug

[Open an issue](../../issues/new/choose) with your iOS version, device, and app version, plus steps to reproduce. Questions and ideas: [Discussions](../../discussions) or [Discord](https://discord.gg/vdWNvxdHzQ). You can also get help at [ntf-ai.app/docs/support](https://ntf-ai.app/docs/support).

Bugs in the underlying ntfy server or protocol belong upstream: [binwiederhier/ntfy/issues](https://github.com/binwiederhier/ntfy/issues).

## Building and contributing

The app builds and its full test suite runs on the simulator with no Apple or Firebase account. See [CONTRIBUTING.md](CONTRIBUTING.md) for the steps, how to sign a build with your own team, and how to submit a PR.

## Credits

Originally developed by [@Copephobia](https://github.com/Copephobia), who did the bulk of the initial work. The app was previously maintained by [Philipp C. Heckel](https://heckel.io). This fork is maintained independently from both.

Contributors: [@harshitethic](https://github.com/harshitethic) fixed copy actions, added per-message Mark read and Mark unread, and first proposed the base64 message decoding and the VoiceOver labels.

Upstream: [binwiederhier/ntfy-ios](https://github.com/binwiederhier/ntfy-ios). Server, Android app, and docs: [binwiederhier/ntfy](https://github.com/binwiederhier/ntfy), [ntfy.sh/docs](https://ntfy.sh/docs).

## Support the project

If this fork is useful to you: [Ko-fi](https://ko-fi.com/ntfai).

## License

Copyright © 2026 Legitimate LLC. Licensed under the [GNU General Public License v3.0](LICENSE) (GPL-3.0-only).

This app is based on [ntfy-ios](https://github.com/binwiederhier/ntfy-ios) by Copephobia and Philipp C. Heckel. That code is under the MIT License, kept in [LICENSES/ntfy-ios-MIT.txt](LICENSES/ntfy-ios-MIT.txt).
