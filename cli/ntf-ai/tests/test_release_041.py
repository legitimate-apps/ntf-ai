"""ntf-ai 0.4.1 security fixes (review of 0.4.0, 2026-11-17).

1. E2E strict fails closed: an answer that does not prove the topic password never resolves a strict ask, and a
   non-strict plain ask says so and exits 7.
2. An encrypted answer is authenticated only when its encrypted payload names this question (`re-<request id>`)
   and the server received it no earlier than the question. NTF-AI 1.26 and 1.27 both encrypt the `re-` tag.
3. Text from the topic cannot drive the terminal: C0/C1 controls print as a visible \\xNN; JSON is unchanged.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch
sys.path.insert(0, os.environ.get('NTF_CLI_DIR', str(Path(__file__).resolve().parents[1])))
import ntf_ai as n

ASKED = 1000


class FakeClient(n.Client):
    """A real Client (real decryption) whose poll returns a fixed list once."""
    def __init__(self, rows):
        super().__init__('https://ntf-ai.app')
        self.topic_password = 'pw'
        self.rows = rows

    def poll(self, topics, since):
        rows, self.rows = self.rows, []
        return rows


def sealed(client, message, tags=None, mid='E', time=ASKED + 5, outer_tags=None):
    payload = {'message': message}
    if tags is not None:
        payload['tags'] = tags
    jwe = n.encrypt_jwe(client._topic_key('t'), json.dumps(payload).encode())
    row = dict(event='message', id=mid, topic='t', time=time, message=jwe)
    if outer_tags:
        row['tags'] = outer_tags
    return row


def match(client, row, asked_at=ASKED, schema=None):
    decoded, auth = client.decode_answer(row)
    return n.match_answer(decoded, 't', 'R', [('Approve', 'approve')], True, set(), schema=schema,
                          authenticated=auth, asked_at=asked_at)


class BindingTests(unittest.TestCase):
    def setUp(self):
        self.c = FakeClient([])

    def test_inner_reply_tag_for_this_question_is_authenticated(self):
        self.assertTrue(match(self.c, sealed(self.c, 'go', tags=['re-R']))['authenticated'])
        native = match(self.c, sealed(self.c, '12', tags=['re-R', 'ans']), schema=dict(v=2, kind='number'))
        self.assertEqual((native['kind'], native['authenticated']), ('structured', True))

    def test_untagged_encrypted_reply_is_unauthenticated(self):
        # The compose sheet (and any message without an inner binding) is still a usable reply, flagged.
        a = match(self.c, sealed(self.c, 'go'))
        self.assertEqual((a['kind'], a['answer'], a['authenticated']), ('reply', 'go', False))

    def test_outer_tag_alone_does_not_bind(self):
        a = match(self.c, sealed(self.c, 'go', outer_tags=['re-R']))
        self.assertFalse(a['authenticated'])

    def test_answer_older_than_the_question_is_unauthenticated(self):
        self.assertFalse(match(self.c, sealed(self.c, 'go', tags=['re-R'], time=ASKED - 1))['authenticated'])
        self.assertTrue(match(self.c, sealed(self.c, 'go', tags=['re-R'], time=ASKED))['authenticated'])
        # Without a known question time, freshness cannot be shown.
        self.assertFalse(match(self.c, sealed(self.c, 'go', tags=['re-R']), asked_at=None)['authenticated'])

    def test_status_binds_to_the_question_time(self):
        entry = dict(id='R', topic='t', server='https://ntf-ai.app', asked_at=ASKED, schema=None)
        old = sealed(self.c, 'old', tags=['re-R'], mid='O', time=ASKED - 100)
        new = sealed(self.c, 'new', tags=['re-R'], mid='N', time=ASKED + 1)
        decoded = [self.c.decode_answer(r) for r in (old, new)]
        r = n.fold_status(entry, [m for m, _ in decoded], now=ASKED + 2,
                          authenticated_ids={m['id']: v for m, v in decoded})
        self.assertEqual((r['answer']['answer'], r['answer']['authenticated']), ('new', True))
        r = n.fold_status(entry, [decoded[0][0]], now=ASKED + 2, authenticated_ids={'O': True})
        self.assertFalse(r['answer']['authenticated'])


class StrictTests(unittest.TestCase):
    def rows(self, c):
        return [dict(event='message', id='B', topic='t-answers', time=ASKED + 1, message='reply:R:approve'),
                dict(event='message', id='P', topic='t', time=ASKED + 2, message='approve', tags=['re-R']),
                sealed(c, 'unbound', mid='U', time=ASKED + 3),
                sealed(c, 'stale', tags=['re-R'], mid='S', time=ASKED - 3),
                sealed(c, 'yes', tags=['re-R'], mid='Y', time=ASKED + 4)]

    def wait(self, strict):
        c = FakeClient([])
        c.rows = self.rows(c)
        reached = []
        a = n.wait_for_answer(c, 't', 'R', [('Approve', 'approve')], True, set(), '999', 5, poll_interval=0.01,
                              asked_at=ASKED, require_authenticated=strict, on_answer=reached.append)
        return a, reached

    def test_strict_waits_past_every_unauthenticated_answer(self):
        a, reached = self.wait(True)
        self.assertEqual((a['answer'], a['authenticated']), ('yes', True))
        self.assertEqual([r['message_id'] for r in reached], ['Y'])  # forged answers do not stop reminders

    def test_non_strict_takes_the_first_and_flags_it(self):
        a, _ = self.wait(False)
        self.assertEqual((a['kind'], a['answer'], a['authenticated']), ('button', 'approve', False))

    def test_strict_still_stops_on_withdrawal(self):
        c = FakeClient([dict(event='message_delete', id='D', topic='t', sequence_id='R', time=ASKED + 1)])
        a = n.wait_for_answer(c, 't', 'R', [], True, set(), '999', 5, poll_interval=0.01, asked_at=ASKED,
                              require_authenticated=True)
        self.assertEqual(a['kind'], 'withdrawn')

    def test_topic_configured_e2e_is_strict(self):
        c = n.Client('https://ntf-ai.app')
        n.configure_encryption(c, {'topic_password': 'pw', 'topics': {'t': {'e2e': True}}}, 't')
        self.assertTrue(c.e2e_strict)
        c = n.Client('https://ntf-ai.app')
        n.configure_encryption(c, {'topic_password': 'pw'}, 't')
        self.assertFalse(c.e2e_strict)

    def test_strict_status_ignores_unauthenticated_answers(self):
        c = FakeClient([])
        entry = dict(id='R', topic='t', server=c.server, asked_at=ASKED, schema=None)
        btn = dict(event='message', id='B', topic='t-answers', time=ASKED + 1, message='reply:R:approve')
        self.assertEqual(n.fold_status(entry, [btn], now=ASKED + 2)['state'], 'answered')
        self.assertEqual(n.fold_status(entry, [btn], now=ASKED + 2, require_authenticated=True)['state'], 'pending')
        c.e2e_strict = True
        with patch.object(n, 'find_ask', return_value=entry), patch.object(n, 'record_ask'):
            c.rows = [btn]
            c.capabilities = lambda: {}
            self.assertEqual(n.question_status(c, 't', 'R', now=ASKED + 2)['state'], 'pending')


ANSWER = dict(status='answered', kind='button', answer='approve', valid=None, request_id='R', authenticated=False)


class CliOutputTests(unittest.TestCase):
    def cli(self, result, flags=(), env=None):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(n, 'ask', return_value=result), patch.object(n, 'load_config', return_value={}), \
                contextlib.redirect_stderr(err):
            code = n.main(['ask', *flags, 'Q'], stdout=out, env=dict({'NTF_TOPIC': 't'}, **(env or {})))
        return code, out.getvalue(), err.getvalue()

    def test_unauthenticated_answer_on_encrypted_topic_warns_and_exits_7(self):
        code, out, err = self.cli(ANSWER, env={'NTF_TOPIC_PASSWORD': 'pw'})
        self.assertEqual((code, out), (7, 'approve\n'))
        self.assertIn('unauthenticated answer', err)
        code, out, err = self.cli(dict(ANSWER, authenticated=True), env={'NTF_TOPIC_PASSWORD': 'pw'})
        self.assertEqual((code, err), (0, ''))
        # Rejected stays 3; plain topics are unchanged (nothing there is authenticated); JSON carries the field.
        self.assertEqual(self.cli(dict(ANSWER, status='rejected', answer='reject'), env={'NTF_TOPIC_PASSWORD': 'pw'})[0], 3)
        self.assertEqual(self.cli(ANSWER)[:2], (0, 'approve\n'))
        code, out, _ = self.cli(ANSWER, flags=('--json',), env={'NTF_TOPIC_PASSWORD': 'pw'})
        self.assertEqual((code, json.loads(out)['authenticated']), (0, False))
        # Invalid and unauthenticated: both warnings, and the security exit wins.
        code, _, err = self.cli(dict(ANSWER, kind='reply', type='number', valid=False), env={'NTF_TOPIC_PASSWORD': 'pw'})
        self.assertEqual(code, 7)
        self.assertIn('invalid answer', err)

    def test_mcp_text_says_unauthenticated(self):
        m = n.McpServer(dict(server='https://ntf-ai.app', topic='t'))
        client = n.Client('https://ntf-ai.app')
        client.topic_password = 'pw'
        for auth, shown in ((False, True), (True, False)):
            with patch.object(m, '_client', return_value=client), \
                    patch.object(n, 'ask', return_value=dict(ANSWER, kind='reply', authenticated=auth)):
                text = m.run_tool('ask', dict(question='Q'), threading.Event(), None)['content'][0]['text']
            self.assertEqual('Unauthenticated' in text, shown, text)

    def test_answer_text_cannot_drive_the_terminal(self):
        evil = 'ok\x1b]0;pwned\x07\x1b[2J\x9b31m\rdone\ttab\nline'
        code, out, _ = self.cli(dict(ANSWER, kind='reply', answer=evil))
        self.assertEqual(out, 'ok\\x1b]0;pwned\\x07\\x1b[2J\\x9b31m\\x0ddone\ttab\nline\n')
        code, out, _ = self.cli(dict(ANSWER, kind='reply', answer=evil), flags=('--json',))
        self.assertEqual(json.loads(out)['answer'], evil)

    def test_messages_and_attachments_print_escaped_and_json_unchanged(self):
        m = dict(event='message', id='M', topic='t', time=0, title='T\x1b[1m', message='m\x1b[31m\x00\x7f',
                 tags=['x\x1b[0m'], attachment=dict(url='https://e.example/a\x1b]8;;evil\x07'))
        out = io.StringIO()
        n.print_message(m, False, out)
        text = out.getvalue()
        for ch in '\x1b\x00\x7f\x07':
            self.assertNotIn(ch, text)
        self.assertIn('T\\x1b[1m:', text)
        self.assertIn('m\\x1b[31m\\x00\\x7f', text)
        self.assertIn('x\\x1b[0m', text)
        self.assertIn('a\\x1b]8;;evil\\x07', text)
        out = io.StringIO()
        n.print_message(m, True, out)
        self.assertEqual(json.loads(out.getvalue())['message'], m['message'])

    def test_error_text_from_the_server_is_escaped(self):
        err = io.StringIO()
        with patch.object(n, 'run', side_effect=n.NtfError('HTTP 500 \x1b[2Jboom')), contextlib.redirect_stderr(err):
            n.main(['send', 'x'], stdout=io.StringIO(), env={'NTF_TOPIC': 't'})
        self.assertNotIn('\x1b', err.getvalue())
        self.assertIn('\\x1b[2Jboom', err.getvalue())


if __name__ == '__main__':
    unittest.main()
