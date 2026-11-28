# Licensing

Which license covers which part of this repository. The license texts are the legal terms; this
page is a map.

| Path | License | Text |
|---|---|---|
| Everything not listed below: the NTF-AI app (`ntfy/`), its extensions (`ntfyNSE/`, `ntfyShare/`), tests, `scripts/`, docs and assets | PolyForm Shield License 1.0.0 (`LicenseRef-PolyForm-Shield-1.0.0`) | [LICENSE](LICENSE) |
| `cli/ntf-ai/` (the `ntf` command and MCP server) | MIT | [cli/ntf-ai/LICENSE](cli/ntf-ai/LICENSE) |
| Code that came from [ntfy-ios](https://github.com/binwiederhier/ntfy-ios) | MIT, as upstream | [LICENSES/ntfy-ios-MIT.txt](LICENSES/ntfy-ios-MIT.txt) |
| Third-party packages the app links (Firebase, GoogleUtilities, GoogleDataTransport, Promises, nanopb) | Apache-2.0, MIT, zlib | Shown in the app under Settings, Licenses |

Required Notice: Copyright Legitimate LLC (https://ntf-ai.app)

Every first-party source file starts with a two-line header naming its license and the AI-use
rules. `python3 scripts/ai-use-headers.py` adds it to new files; CI runs it with `--check`.

## The change from GPL-3.0

Versions 1.27 to 1.32 were published under GPL-3.0-only, and earlier versions under the MIT
License. From NTF-AI 1.33 the app code is under the
PolyForm Shield License 1.0.0. The cut-over is the commit that adds this file; the last commit
under GPL-3.0-only is `54d4ced` on `main`
([its LICENSE](https://github.com/legitimate-apps/ntf-ai/blob/54d4ced/LICENSE)).

Versions already published under GPL-3.0 or MIT, meaning every commit before the cut-over and
every release before 1.33, stay under those licenses for anyone who has them. Those licenses
can't be taken back, and this change doesn't try to. It applies to the code from the cut-over on.

PolyForm Shield lets anyone use, change and share the app's code for any purpose except providing
a product that competes with it or with another Legitimate LLC product that uses it. Read
[LICENSE](LICENSE) for the exact terms.

GitHub doesn't recognise PolyForm Shield, so the repository sidebar shows the license as
"Other" (View license) rather than naming it.

## AI tools

[AI-USE.md](AI-USE.md) says how AI assistants and agents may use this repository: they may build
and fix NTF-AI here, and must not copy its code, designs or features into other projects or use
it for model training.

## Contributions

Contributors license their contributions to Legitimate LLC under the MIT License
([CONTRIBUTING.md](CONTRIBUTING.md)), which lets them ship in the App Store build under the
license above.
