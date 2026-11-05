# Typed notification replies

Status: local feature branch; not a released capability or marketing claim.

## Contract

Publish an ordinary ntfy `view` action. Its URL is the existing guide URL with a versioned fragment:

```json
{"action":"view","label":"Reply in PING","url":"https://ntfy-me.com/docs/agents#reply-v1=https%3A%2F%2Fntfy-me.com%2FLONG_RANDOM_REPLY_TOPIC"}
```

The destination is an HTTP(S) ntfy topic URL, with no query, fragment or embedded credentials. A server path prefix and non-default port are supported. Use a separate random reply topic per question to correlate the raw UTF-8 answer without a template or JSON escaping. The agent polls that topic with a timeout, processes each message ID once, and never infers authorization from a timeout or a public topic's sender. Destination topic names are shared access, not authentication. Plain replies are not end-to-end encrypted; do not use this contract for an encrypted topic.

PING recognizes only this exact HTTPS guide host/path and fragment version on a `view` action. The banner uses UNTextInputNotificationAction, requires authentication on iOS, and sends only on submission of nonblank text. The text is posted verbatim as text/plain; quotes, Unicode and newlines need no interpolation. Existing credential scoping and redirect handling apply. No credentials are added for a different server. On Mac, retain foreground routing so the existing extension relay can reach the app. Preserve reply text in the relay, including decoding old queued responses that have no text. Completion and background-expiration handling follow the existing HTTP action path.

A message-list view tap, an old PING version, or an official client opens the guide URL. On a new PING banner, a recognized reply action without submitted text is ignored; it never sends a request or consumes deduplication. The fragment is not sent in the HTTP request. It cannot accidentally POST a placeholder or a fake answer. The label says which app supports the typed interaction. In the message list the link keeps this guide fallback; users can compose a reply to the destination topic there. No special ntfy server, new action type, dependency, entitlement or URL scheme is needed. The guide route must be deployed alongside release; nothing in this branch deploys it.

## Alternatives considered

- HTTP action with `{{reply}}` in its body: rejected. Stock servers pass it, but clients without this extension can submit the literal placeholder and appear to answer.
- New `reply` action type or server-specific fields: rejected; stock ntfy validates action kinds and may discard unrecognized fields.
- Reuse click URLs / custom ntfy:// routing: rejected; ordinary taps must retain their existing behavior and the shared scheme is not an unambiguous feature negotiation.
- HTTP GET fallback with custom headers: more fields and ambiguous destination/credential semantics; the view-link fallback is already understood by clients.

## Validation and limits

Red-to-green tests cover native action registration and category identity, strict URL parsing, verbatim request construction, missing/empty submissions, credential boundaries and relay persistence/backward decoding. A leased simulator can verify local notification UI, typed submission and the real delegate-to-HTTP round trip. Simulator delivery does not prove APNs/NSE wake-up, locked-device authentication, background time under real power/network constraints, acoustic alerts, or Mac extension routing; those remain real-device checks before release.
