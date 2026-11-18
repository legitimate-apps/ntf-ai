#!/usr/bin/env python3
"""Show each end-to-end test can fail: break the CLI one way per test, run that test against the broken copy,
and require it to go red. The original file is never edited. Prints one JSON line per mutation and a summary."""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "ntf_ai.py")
M = [  # (test, old, new)
    ("SendTests.test_send", 'body = {"topic": topic, "message": message}', 'body = {"topic": topic, "message": ""}'),
    ("SendTests.test_send_from_stdin_json", "        if text.strip():\n", "        if False:\n"),
    ("AskTests.test_ask_answered_by_button", 'if msg.get("topic") == topic + ANSWERS_SUFFIX:',
     'if msg.get("topic") == "nothing":'),
    ("AskTests.test_ask_rejected_exit_code", '"rejected": EXIT_REJECTED', '"rejected": EXIT_OK'),
    ("AskTests.test_ask_custom_buttons", "answer = (answer if sep else label).strip().lower()",
     "answer = label.strip().lower()"),
    ("AskTests.test_ask_answered_by_plain_reply", "topic and accept_reply and AGENT_TAG", "topic and False and AGENT_TAG"),
    ("AskTests.test_ask_timeout", "deadline = clock() + timeout\n", "deadline = clock() + timeout * 100\n"),
    ("AskTests.test_stale_answers_ignored",
     '        prefix = f"reply:{request_id}:"\n        text = (msg.get("message") or "").strip()\n',
     '        text = (msg.get("message") or "").strip()\n        prefix = "reply:" + text.split(":")[1] + ":" if text.count(":") == 2 else ""\n'),
    ("AskTests.test_stale_answers_ignored",
     'seen.update(m["id"] for m in client.poll([topic], "all") if m.get("id"))', "pass"),
    ("AskTests.test_own_message_not_the_answer", 'and AGENT_TAG not in (msg.get("tags") or []):', ":"),
    ("AskTests.test_no_reply_mode_ignores_written_reply", "accept_reply=not args.no_reply", "accept_reply=True"),
    ("AskTests.test_poll_mode", "for m in client.poll(topics, since):", "for m in client.poll(topics[:1], since):"),
    ("AttachmentTests.test_send_file_and_download", "                f.write(chunk)\n", "                pass\n"),
    ("AttachmentTests.test_send_attach_url", '("attach", attach_url)', '("attach", None)'),
    ("AttachmentTests.test_read_downloads_photo_the_person_sent", '    if not (folder and att.get("url")):\n', "    if True:\n"),
    ("AttachmentTests.test_ask_with_screenshot_and_photo_reply", '        if msg.get("attachment"):\n            out["attachment"]',
     '        if False:\n            out["attachment"]'),
    ("AttachmentTests.test_ask_with_screenshot_and_photo_reply", "sent = client.upload(topic, attach, question, **kw)",
     "sent = client.publish(topic, question, **kw)"),
    ("McpE2E.test_legacy_handshake_and_tools", "self.legacy = requested if requested in MCP_LEGACY_VERSIONS else",
     "self.legacy = MCP_LEGACY_VERSIONS[-1] if requested in MCP_LEGACY_VERSIONS else"),
    ("McpE2E.test_legacy_handshake_and_tools", 'sent = (client.upload(topic, attach_file, args["message"], **kw) if attach_file',
     'sent = (client.publish(topic, args["message"], **kw) if attach_file'),
    ("McpE2E.test_modern_requests", 'modern = version is not None or method == "server/discover"', "modern = False"),
    # Replies that name their question (re-<sequence_id>) and no-reply questions.
    ("AskTests.test_reply_tagged_for_this_question", '            out["reply_to"] = target\n', "            pass\n"),
    ("AskTests.test_reply_to_another_question_ignored", "        if target is not None and target != request_id:",
     "        if False:"),
    ("AskTests.test_untagged_reply_after_other_question_reply", "        if target is not None and target != request_id:",
     "        if target != request_id:"),
    ("AskTests.test_no_reply_question_is_tagged_and_ignores_tagged_reply",
     "([] if accept_reply else [NO_REPLY_TAG])", "[]"),
    ("AskTests.test_read_json_names_the_question_a_reply_answers", "            m = dict(m, reply_to=target)", "            pass"),
    # Acks for answers; the full settle for a timeout or Ctrl-C.
    ("SettleTests.test_timeout_settles_question", "                             sequence_id=seq)",
     "                             sequence_id=None)"),
    ("SettleTests.test_timeout_settles_question", "        upd = client.publish(topic, body, title=title, priority=1,",
     "        upd = client.publish(topic, body, title=title, priority=None,"),
    ("SettleTests.test_button_answer_acks_question", 'return f"\\u2713 Got: {label}"',
     'return f"\\u2713 Got: {answer[\'answer\']}"'),
    ("SettleTests.test_button_answer_acks_question", "priority=1, tags=[AGENT_TAG, ACK_TAG],",
     "priority=None, tags=[AGENT_TAG, ACK_TAG],"),
    ("SettleTests.test_typed_reply_acks_without_echo", 'return "\\u2713 Got your reply"',
     'return "\\u2713 Got: " + answer["answer"]'),
    ("SettleTests.test_timeout_settles_question", "    receipt = settle_with(answer, interrupted)\n",
     "    receipt = settle_with(answer, interrupted) if answer else None\n"),
    ("SettleTests.test_ctrl_c_settles_question", "        settle_with(None, interrupted=True)\n        raise\n",
     "        raise\n"),
    ("SettleTests.test_failed_question_sends_nothing",
     "        sent = client.publish(topic, question, attach_url=attach_url, **kw)\n",
     "        try:\n            sent = client.publish(topic, question, attach_url=attach_url, **kw)\n"
     "        except NtfError:\n            settle_question(client, topic, {\"sequence_id\": request_id}, question, \"x\", "
     "title, all_tags, markdown)\n            raise\n"),
    ("SettleTests.test_no_ack_sends_none", "ack=not args.no_ack", "ack=True"),
    ("SettleTests.test_ntf_ack_updates_the_note", '(note or "").strip() or DEFAULT_ACK', "DEFAULT_ACK"),
    ("AskTests.test_ask_answered_by_button", "            if not ack:\n                return None\n",
     "            if True:\n                return None\n"),
    ("AttachmentTests.test_ask_with_screenshot_and_photo_reply", "priority=1, tags=[AGENT_TAG, ACK_TAG],",
     "priority=1, tags=[AGENT_TAG],"),
    ("McpE2E.test_legacy_handshake_and_tools", 'ack=args.get("ack", True) is not False', "ack=True"),
    ("McpE2E.test_legacy_handshake_and_tools", 'if name not in ("notify", "ask", "ack", "status", "withdraw"):', 'if name not in ("notify", "ask"):'),
    # Security (tests/test_security.py, no Docker): downloads and redaction.
    ("test_security.DownloadTests.test_other_host_refused_by_default", "                if not allow_external:\n",
     "                if False:\n"),
    ("test_security.DownloadTests.test_external_private_addresses_refused_even_when_allowed",
     "    return not ip.is_global or ip.is_multicast\n", "    return False\n"),
    ("test_security.DownloadTests.test_redirect_to_another_host_carries_no_auth",
     "            if self.auth and own and (scheme, host, port) == self.origin:\n", "            if self.auth:\n"),
    ("test_security.DownloadTests.test_api_redirect_to_another_host_carries_no_auth",
     "return _OPENER.open(req, ", "return urllib.request.urlopen(req, "),
    ("test_security.DownloadTests.test_size_cap", "                if size > max_bytes:\n", "                if False:\n"),
    ("test_security.DownloadTests.test_hostile_file_names_stay_in_the_folder",
     '    name = str(name or "").replace("\\\\", "/").split("/")[-1]\n', '    return str(name) or "attachment"\n'),
    ("test_security.DownloadTests.test_planted_symlink_not_followed", 'f = open(path, "xb")', 'f = open(path, "wb")'),
    ("test_security.RedactionTests.test_error_hides_topic_answers_topic_and_credentials",
     "                text = text.replace(form, self._hidden[value])\n", "                pass\n"),
    ("test_security.RedactionTests.test_user_password_hidden", 'self._hidden[password] = "<password>"', "pass"),
    ("test_security.DownloadTests.test_only_the_attachment_route_gets_credentials",
     "and not parts.query and self._file_path(parts.path)", ""),
    ("test_security.DownloadTests.test_only_the_attachment_route_gets_credentials",
     "            if self.auth and own and (scheme, host, port) == self.origin:\n",
     "            if self.auth and (scheme, host, port) == self.origin:\n"),
    ("test_security.DownloadTests.test_attachment_route_under_a_path_prefix",
     'prefix = urllib.parse.urlsplit(self.server).path.rstrip("/")', 'prefix = ""'),
    ("test_security.DownloadTests.test_ipv6_wrappers_of_private_ipv4_refused",
     "    if ip in _NAT64 or ip in _V4_COMPAT:\n", "    if False:\n"),
    ("test_security.DownloadTests.test_embedded_ipv4_unwrapped", "    if ip.sixtofour:\n", "    if False:\n"),
    ("test_security.DownloadTests.test_embedded_ipv4_unwrapped", "        out.extend(ip.teredo)\n", "        pass\n"),
    ("test_security.RedactionTests.test_connection_error_hides_topic",
     'err = NtfError(self._safe(f"{method} {url} failed: {reason}"))', 'err = NtfError(f"{method} {url} failed: {reason}")'),
]
# Protocol v2 mutations, gated by pure tests as well as the real-server tests above.
M += [
    ("test_v2.SchemaTests.test_fixtures_encode_exactly", '.decode("ascii").rstrip("=")', '.decode("ascii")'),
    ("test_v2.SchemaTests.test_schema_limits_and_wrong_types", 'SCHEMA_LIMIT = 1536', 'SCHEMA_LIMIT = 4096'),
    ("test_v2.SchemaTests.test_schema_limits_and_wrong_types", '2 <= len(opts) <= 12', '2 <= len(opts) <= 13'),
    ("test_v2.SchemaTests.test_schema_limits_and_wrong_types", 'now + 7 * 86400', 'now + 8 * 86400'),
    ("test_v2.SchemaTests.test_answer_table", 'if abs(delta - n*step) > decimal.Decimal("1e-9"):', 'if False:'),
    ("test_v2.ProtocolEdges.test_structured_formats_and_normalization", 'if json_form and not _number(value):', 'if False:'),
    ("test_v2.SchemaTests.test_strict_keeps_waiting", 'if a and (not strict or a.get("valid") is not False):\n                        return a\n                    if cancel', 'if a:\n                        return a\n                    if cancel'),
    ("test_v2.StatusTests.test_fold_states_and_precedence", 'if out["withdrawn"]:', 'if False:'),
    ("test_v2.StatusTests.test_status_uses_capabilities_and_timestamp", 'retention = caps.get("agent_retention_seconds", 43200)', 'retention = 43200'),
    ("test_v2.ProtocolEdges.test_ask_timestamp_and_deadline", 'seen, str(max(0, asked_at-1)), timeout,', 'seen, qid, timeout,'),
    ("test_v2.ProtocolEdges.test_ask_timestamp_and_deadline", 'timeout = min(timeout, max(0, schema["exp"]-wall_clock()))', 'timeout = timeout'),
    ("test_v2.SchemaTests.test_reminder_clock", 'rs = dict(schema, rem=next_reminder)', 'rs = dict(schema, rem=1)'),
    ("test_v2.SchemaTests.test_reminder_clock", 'min(4, (priority or 3) + next_reminder)', 'min(5, (priority or 3) + next_reminder)'),
    ("test_v2.ProtocolEdges.test_reminders_stop_on_external_settle", 'reminders_active[0] = False  # another agent already acked or settled this question', 'reminders_active[0] = True  # broken external settle handling'),
    ("test_v2.StatusTests.test_ledger_private_pruned_and_final_preserved", 'rows = [r for r in rows.values() if now-r.get("asked_at", 0) <= 30*86400]', 'rows = list(rows.values())'),
    ("ProtocolV2E2E.test_withdraw_exits_five_and_deletes", 'client._request("DELETE", topic_url(client.server, topic) + "/" + request_id)', 'client._request("PUT", topic_url(client.server, topic) + "/" + request_id + "/clear")'),
    ("ProtocolV2E2E.test_identity_and_nonblocking_ask", 'kw["icon"] = avatar', 'pass'),
]
# AES/GCM and encryption integration. The independent vectors pin every crypto stage.
M += [
 ('test_crypto.CryptoTests.test_nist_aes256_gcm_vectors','elif i % 8 == 4:', 'elif False:'),
 ('test_crypto.CryptoTests.test_nist_aes256_gcm_vectors','range(1,15):','range(1,14):'),
 ('test_crypto.CryptoTests.test_nist_aes256_gcm_vectors','if round_number != 14:', 'if False:'),
 ('test_crypto.CryptoTests.test_nist_aes256_gcm_vectors','0xe1000000000000000000000000000000','0xe0000000000000000000000000000000'),
 ('test_crypto.CryptoTests.test_nist_aes256_gcm_vectors','for data in (aad,ciphertext):','for data in (ciphertext,):'),
 ('test_crypto.CryptoTests.test_nist_aes256_gcm_vectors',"(len(aad)*8).to_bytes(8,'big')", "len(aad).to_bytes(8,'big')"),
 ('test_crypto.CryptoTests.test_nist_aes256_gcm_vectors',"(len(ciphertext)*8).to_bytes(8,'big')", "len(ciphertext).to_bytes(8,'big')"),
 ('test_crypto.CryptoTests.test_nist_aes256_gcm_vectors',"i//16 + 2", "i//16 + 1"),
 ('test_crypto.CryptoTests.test_tampering_rejected_before_plaintext','if not hmac.compare_digest(expected,tag):','if False:'),
 ('test_security.EncryptionSecurityTests.test_authentication_checked_before_decryption_and_outer_tags_not_trusted','expected = _gcm_tag(keys,iv,ciphertext,aad)','_gcm_crypt(keys,iv,ciphertext)\n    expected = _gcm_tag(keys,iv,ciphertext,aad)'),
 ('test_crypto.CryptoTests.test_salt_aliases_and_upstream_vector',"server = 'https://ntfy-me.com'",'pass'),
 ('test_crypto.CryptoTests.test_salt_aliases_and_upstream_vector',"salt,50000,32",'salt,49999,32'),
 ('test_crypto.CryptoTests.test_jwe_header_limits_random_iv_and_raw_text','iv = secrets.token_bytes(12) if iv is None else iv','iv = bytes(12) if iv is None else iv'),
 ('test_crypto.CryptoTests.test_jwe_header_limits_random_iv_and_raw_text','if encoded_size >= 4096:','if False:'),
 ('test_crypto.CryptoTests.test_jwe_header_limits_random_iv_and_raw_text',"if ek or json.loads(unb64url(header)) != {'alg':'dir','enc':'A256GCM'}:",'if False:'),
 ('test_crypto.CryptoTests.test_transport_encrypts_all_metadata_and_decodes_inner_tags_only','payload = {k: body[k] for k in ENCRYPTED_FIELDS if k in body}', 'payload = {"message": body.get("message")}'),
 ('test_crypto.CryptoTests.test_transport_encrypts_all_metadata_and_decodes_inner_tags_only','if t == ACK_TAG or t == "ans" or t.startswith("re-")','if False'),
 ('test_crypto.CryptoTests.test_http_encoding_header_and_omitted_inner_fields','decoded = {k: v for k, v in message.items() if k not in ENCRYPTED_FIELDS}', 'decoded = dict(message)'),
 ('test_crypto.CryptoTests.test_wrong_password_skipped_counted_and_plain_button_unauthenticated','self.undecryptable += 1','self.undecryptable += 0'),
 ('test_security.EncryptionSecurityTests.test_password_never_in_argv_or_error_logs',"client._hidden[password] = '<topic password>'",'pass'),
 ('test_crypto.CryptoTests.test_config_and_password_sources_fail_closed',"if (required or configured.get('e2e') or strict) and not password:",'if False:'),
 ('test_crypto.CryptoTests.test_strict_has_schema_without_plain_buttons','allow_buttons = not getattr(client, "e2e_strict", False)','allow_buttons = True'),
 ('test_crypto.CryptoTests.test_attachments_refused_before_network','if body.get("attach") or body.get("filename"):', 'if False:'),
 ('test_crypto.CryptoTests.test_http_encoding_header_and_omitted_inner_fields','headers["X-Encoding"] = "jwe"','headers["X-Encoding"] = "wrong"'),
]
# Independent-review regressions: each failure path must remain observable.
M += [
 ('test_review.ReviewTests.test_B1_unwritable_ledger_does_not_abandon_published_question',
  'except OSError:\n        sys.stderr.write("ntf: could not save the local ask ledger;',
  'except OSError:\n        raise\n        sys.stderr.write("ntf: could not save the local ask ledger;'),
 ('test_review.ReviewTests.test_M1_failed_reminder_retries_without_losing_answer',
  'reminder_retry_at[0] = clock() + delay', 'raise'),
 ('test_review.ReviewTests.test_M1_failed_reminder_retries_without_losing_answer',
  'max(reminder_backoff[0], int(retry_after) if str(retry_after).isdigit() else 0)', 'reminder_backoff[0]'),
 ('test_review.ReviewTests.test_M2_plain_pending_prints_handle',
  'out.write(res["request_id"] + "\\n")', 'pass'),
 ('test_review.ReviewTests.test_M2_mcp_pending_text_includes_handle',
  'text = f"{res[\'status\']}: {res[\'request_id\']}"', 'text = res["status"]'),
 ('test_review.ReviewTests.test_M3_invalid_plain_answer_is_not_success',
  'return EXIT_INVALID', 'return EXIT_OK'),
 ('test_review.ReviewTests.test_M4_cursor_and_ledger_use_publication_server_time',
  'asked_at = int(server_time) if isinstance(server_time, (int, float)) else 0', 'asked_at = int(wall_clock())'),
 ('test_review.ReviewTests.test_M6_choice_and_button_share_label_first_order_and_limit',
  'for label, key in parse_buttons(values)', 'for key, label in parse_buttons(values)'),
 ('test_review.ReviewTests.test_M6_spec_replaces_rare_flags_without_losing_kinds',
  's.setdefault("v", 2)', 's["v"] = 1'),
 ('test_review.ReviewTests.test_m1_comma_in_free_choice_label_is_atomic',
  'if not structured and len(exact) == 1 else text.split(",")', 'if False else text.split(",")'),
 ('test_review.ReviewTests.test_m2_fractional_datetime_is_portable_to_python39',
  '(m.group(1) + "000000")[:6]', 'm.group(1)'),
 ('test_review.ReviewTests.test_m3_hosted_alias_does_not_erase_custom_port_or_path',
  'and parts.port in (None, 443 if parts.scheme == "https" else 80)', ''),
 ('test_review.ReviewTests.test_m3_hosted_alias_does_not_erase_custom_port_or_path',
  'and not parts.path and not parts.query and not parts.fragment', ''),
 ('test_review.ReviewTests.test_m3b_ask_warns_once_on_first_undecryptable_message',
  'if self.undecryptable == 1:', 'if False:'),
 ('test_review.ReviewTests.test_m5_withdrawn_plain_explains_exit',
  'sys.stderr.write("question withdrawn; stopped waiting\\n")', 'pass'),
 ('test_review.ReviewTests.test_m6_encrypted_ledger_retains_state_without_plaintext_answer',
  'if k != "answer"', 'if True'),
 ('test_review.ReviewTests.test_m6_encrypted_ledger_retains_state_without_plaintext_answer',
  'elif (out.get("answer") or out.get("answered_at") is not None) and out.get("acked_at") is not None:',
  'elif out.get("answer") and out.get("acked_at") is not None:'),
 ('test_review.ReviewTests.test_n1_number_hint_describes_quantization',
  '"whole number" if whole else "number"', '"number"'),
 ('test_review.ReviewTests.test_n3_poll_publish_window_message_is_not_legacy_reply',
  'seen.update(before)', 'pass'),
]
M += [('test_v2.StatusTests.test_version_one_retention_uses_advertised_field',
       'retention = caps.get("agent_retention_seconds", 43200)',
       'retention = caps.get("agent_retention_seconds", 43200) if caps.get("version") == 2 else 43200')]
M += [('test_review.ReviewTests.test_M1_delayed_retry_keeps_successful_reminders_five_minutes_apart',
       'last_reminder_at[0] = clock()', 'last_reminder_at[0] = started')]
# Every suggested kind must keep its actionable repair, not just the valid-kind list.
guesses = ("multi", "select", "options", "buttons", "bool", "boolean", "yesno")
for guess in guesses:
    M.append((f'test_kind_hints.KindHintTests.test_{guess}_hint',
              f'if kind in {guesses!r}:'.replace("'", '"'),
              f'if kind in {tuple(k for k in guesses if k != guess)!r}:'))
M += [
 ('test_kind_hints.KindHintTests.test_multi_hint',
  'correction["multi"] = True', 'pass'),
 ('test_kind_hints.KindHintTests.test_bool_hint',
  'labels = ("Yes", "No") if kind in ("bool", "boolean", "yesno") else ("A", "B")',
  'labels = ("A", "B")'),
 ('test_kind_hints.KindHintTests.test_form_multi_hint_offers_a_supported_single_choice',
  'if kind == "multi" and not field:', 'if kind == "multi":'),
]
# Launch compatibility: a 1.26 written reply to a typed question prints the same answer and says it was a fallback.
M += [
 ('test_launch_compat.LaunchCompatTests.test_plain_choice_reply_prints_the_answer_key_and_says_how_it_came',
  'out.write(answer_text(res) + "\\n")', 'out.write(res["answer"] + "\\n")'),
 ('test_launch_compat.LaunchCompatTests.test_plain_choice_reply_prints_the_answer_key_and_says_how_it_came',
  'sys.stderr.write("ntf: " + fallback_note(res) + "\\n")', 'pass'),
 ('test_launch_compat.LaunchCompatTests.test_plain_multi_and_form_replies_print_what_the_answer_form_sends',
  'return ",".join(value)', 'return compact_json(value)'),
 ('test_launch_compat.LaunchCompatTests.test_native_answer_and_plain_v1_reply_are_unchanged_and_silent',
  'if res.get("kind") != "reply" or not res.get("type"):', 'if res.get("kind") not in ("reply", "structured"):'),
 ('test_launch_compat.LaunchCompatTests.test_invalid_reply_keeps_raw_text_and_exit_6',
  'if not res.get("type") or not res.get("valid") or value is None:', 'if not res.get("type") or value is None:'),
 ('test_launch_compat.LaunchCompatTests.test_mcp_text_gives_the_key_and_the_fallback',
  'text = f"The person wrote: {answer_text(res)}"', 'text = f"The person wrote: {res[\'answer\']}"'),
]
ONLY = sys.argv[1] if len(sys.argv) > 1 else ""  # e.g. "test_security" runs only those mutations
src = open(SRC, encoding="utf-8").read()
tmp = tempfile.mkdtemp(dir=os.environ.get("NTF_SCRATCH"))
red = 0
try:
    for i, (test, old, new) in enumerate(M):
        if ONLY and not test.startswith(ONLY):
            continue
        if src.count(old) != 1:
            print(json.dumps({"n": i, "test": test, "result": "BAD-MUTATION", "matches": src.count(old)}))
            continue
        path = os.path.join(tmp, f"m{i}", "ntf_ai.py")
        os.makedirs(os.path.dirname(path))
        mutated = src.replace(old, new)
        try:
            compile(mutated, path, "exec")
        except SyntaxError as e:
            print(json.dumps({"n": i, "test": test, "result": "BAD-MUTATION", "why": str(e)}))
            continue  # a syntax error is not evidence of a behavioral assertion
        open(path, "w", encoding="utf-8").write(mutated)
        env = dict(os.environ, NTF_CLI=path, NTF_CLI_DIR=os.path.dirname(path))
        target = test if test.startswith("test_") else f"test_e2e.{test}"
        p = subprocess.run([sys.executable, "-m", "unittest", target], cwd=HERE, env=env,
                           capture_output=True, text=True, timeout=300)
        ok = p.returncode != 0
        red += ok
        last = [l for l in p.stderr.splitlines() if l.startswith(("FAIL", "ERROR", "AssertionError", "subprocess"))][:2]
        print(json.dumps({"n": i, "test": test, "result": "red" if ok else "STILL-GREEN", "why": last}), flush=True)
finally:
    shutil.rmtree(tmp)
ran = sum(1 for t, _, _ in M if not ONLY or t.startswith(ONLY))
print(json.dumps({"mutations": ran, "red": red}))
sys.exit(0 if red == ran else 1)
