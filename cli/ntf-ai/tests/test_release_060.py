# SPDX-License-Identifier: MIT
"""ntf 0.6.0 with NTF-AI 1.33: the dismissed receipt.

When the person clears a question from Waiting on you, NTF-AI 1.33 publishes on the question's topic a message with
body `Dismissed in NTF-AI`, tags `agent,dis,re-<sequence>`, priority 1. `ntf ask` stops waiting and exits 8
(dismissed), `ntf status` reports dismissed with its time, `ntf read` says what it is, and the MCP tools report it.
A dismissal is never an answer and never approval. On an encrypted topic only `dis`/`re-` inside the ciphertext count.

Deadlines and reminders: `--expires` and `--remind` already publish an ask-v2 schema carrying `exp` and `rem`, which
NTF-AI 1.33 reads first, so ntf adds no `exp-`/`rem-` tag (pinned below so a duplicate does not creep in).
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
DISMISS = dict(event='message', id='D1', topic='t', time=ASKED + 5, priority=1, message='Dismissed in NTF-AI',
               tags=['agent', 'dis', 're-R'])


class Recorder:
    server = 'https://ntf-ai.app'

    def __init__(self, rows=()):
        self.calls, self.rows = [], list(rows)

    def poll(self, topics, since):
        return []

    def stream(self, topics, since, deadline, clock=None):
        return iter(self.rows)

    def publish(self, topic, message='', **kw):
        self.calls.append(dict(topic=topic, message=message, **kw))
        return dict(self.calls[-1], id='Q%d' % len(self.calls), time=ASKED)


def encrypted_client():
    c = n.Client('https://ntf-ai.app')
    c.topic_password = 'pw'
    return c


def seal(c, message, tags):
    return n.encrypt_jwe(c._topic_key('t'), json.dumps({'message': message, 'tags': list(tags)}).encode())


class MatchDismissal(unittest.TestCase):
    def match(self, msg, **kw):
        return n.match_answer(msg, 't', 'R', [('Approve', 'approve'), ('Reject', 'reject')], True, set(),
                              asked_at=ASKED, **kw)

    def test_dismissal_for_this_question_is_dismissed_not_an_answer(self):
        a = self.match(DISMISS)
        self.assertEqual(a['kind'], 'dismissed')
        self.assertNotIn('answer', a)
        self.assertEqual((a['message_id'], a['time']), ('D1', ASKED + 5))

    def test_dismissal_for_another_question_is_skipped(self):
        self.assertIsNone(self.match(dict(DISMISS, tags=['agent', 'dis', 're-OTHER'])))
        self.assertIsNone(self.match(dict(DISMISS, tags=['agent', 'dis'])))
        self.assertIsNone(self.match(dict(DISMISS, topic='t-answers')))

    def test_encrypted_topic_trusts_only_inner_dismissal(self):
        # A plaintext receipt on an encrypted topic proves nothing: anyone with the topic name could post it.
        self.assertIsNone(self.match(DISMISS, encrypted=True, authenticated=False))
        self.assertEqual(self.match(DISMISS, encrypted=True, authenticated=True)['kind'], 'dismissed')
        # Encrypted, but older than the question (a replay of an earlier ask's receipt): skipped.
        self.assertIsNone(self.match(dict(DISMISS, time=ASKED - 1), encrypted=True, authenticated=True))

    def test_decoded_inner_tags_identify_the_dismissal(self):
        c = encrypted_client()
        outer = dict(DISMISS, tags=['agent', 'dis', 're-R'], message=seal(c, 'Dismissed in NTF-AI', ['agent', 'dis', 're-R']))
        m, auth = c.decode_answer(outer)
        self.assertTrue(auth)
        self.assertEqual(self.match(m, encrypted=True, authenticated=auth)['kind'], 'dismissed')
        # Outer tags say dismissal, ciphertext says nothing: not a dismissal.
        outer = dict(DISMISS, id='D2', message=seal(c, 'hello', []))
        m, auth = c.decode_answer(outer)
        self.assertNotEqual((self.match(m, encrypted=True, authenticated=auth) or {}).get('kind'), 'dismissed')


class AskStopsOnDismissal(unittest.TestCase):
    def test_wait_for_answer_returns_dismissed(self):
        c = Recorder([DISMISS])
        a = n.wait_for_answer(c, 't', 'R', [('Approve', 'approve')], True, set(), '999', 5, asked_at=ASKED)
        self.assertEqual(a['kind'], 'dismissed')

    def test_ask_reports_dismissed_settles_and_never_acks(self):
        c = Recorder([DISMISS])
        with patch.object(n, 'record_ask') as rec:
            r = n.ask(c, 't', 'Deploy?', request_id='R', timeout=30, wall_clock=lambda: ASKED)
        self.assertEqual(r['status'], 'dismissed')
        self.assertEqual(r['dismissed_at'], ASKED + 5)
        self.assertNotIn('answer', r)
        self.assertNotIn('ack', r)
        tags = [t for call in c.calls[1:] for t in call.get('tags') or []]
        self.assertNotIn('ack', tags)
        # The question is replaced by a quiet copy without buttons, so no live button is left for nobody.
        self.assertEqual(len(c.calls), 2)
        self.assertFalse(c.calls[1].get('actions'))
        self.assertIn('dismissed', c.calls[1]['message'].lower())
        self.assertEqual(rec.call_args_list[-1][0][0]['final']['state'], 'dismissed')

    def test_answer_before_dismissal_wins(self):
        ans = dict(event='message', id='A', topic='t-answers', time=ASKED + 1, message='reply:R:approve')
        c = Recorder([ans, DISMISS])
        with patch.object(n, 'record_ask'):
            r = n.ask(c, 't', 'Deploy?', request_id='R', timeout=30, wall_clock=lambda: ASKED)
        self.assertEqual((r['status'], r['answer']), ('answered', 'approve'))

    def cli(self, result, flags=()):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(n, 'ask', return_value=result), patch.object(n, 'load_config', return_value={}), \
                contextlib.redirect_stderr(err):
            code = n.main(['ask', *flags, 'Q'], stdout=out, env={'NTF_TOPIC': 't'})
        return code, out.getvalue(), err.getvalue()

    def test_cli_exits_8_with_an_explanation(self):
        self.assertEqual(n.EXIT_DISMISSED, 8)
        res = dict(status='dismissed', kind='dismissed', request_id='R', dismissed_at=ASKED + 5, message_id='D1')
        code, out, err = self.cli(res)
        self.assertEqual((code, out), (8, ''))
        self.assertIn('dismissed', err)
        self.assertIn('not an answer', err)
        code, out, _ = self.cli(res, flags=('--json',))
        self.assertEqual((code, json.loads(out)['status']), (8, 'dismissed'))

    def test_mcp_ask_says_dismissed_not_approval(self):
        m = n.McpServer(dict(server='https://ntf-ai.app', topic='t'))
        res = dict(status='dismissed', kind='dismissed', request_id='R', dismissed_at=ASKED + 5)
        with patch.object(m, '_client', return_value=Recorder()), patch.object(n, 'ask', return_value=res):
            text = m.run_tool('ask', dict(question='Q'), threading.Event(), None)['content'][0]['text']
        self.assertIn('dismissed', text)
        self.assertIn('not approval', text)
        tools = {t['name']: t for t in n.mcp_tools()}
        self.assertIn('dismissed', tools['ask']['description'])
        self.assertIn('dismissed', tools['status']['description'])


class StatusReportsDismissed(unittest.TestCase):
    entry = dict(id='R', topic='t', server='https://ntf-ai.app', asked_at=ASKED, schema=None,
                 buttons=[('Approve', 'approve'), ('Reject', 'reject')])
    question = dict(event='message', id='Q', topic='t', time=ASKED, sequence_id='R', tags=['agent'],
                    actions=[dict(action='http', url='https://ntf-ai.app/t-answers')])

    def test_fold_dismissed_with_time(self):
        out = n.fold_status(self.entry, [self.question, DISMISS], now=ASKED + 10)
        self.assertEqual((out['state'], out['dismissed_at']), ('dismissed', ASKED + 5))

    def test_answer_still_wins_after_dismissal(self):
        ans = dict(event='message', id='A', topic='t-answers', time=ASKED + 7, message='reply:R:approve')
        out = n.fold_status(self.entry, [self.question, DISMISS, ans], now=ASKED + 10)
        self.assertEqual(out['state'], 'answered')
        self.assertEqual(out['dismissed_at'], ASKED + 5)

    def test_other_question_and_unauthenticated_dismissals_are_ignored(self):
        other = dict(DISMISS, tags=['agent', 'dis', 're-OTHER'])
        self.assertEqual(n.fold_status(self.entry, [self.question, other], now=ASKED + 10)['state'], 'pending')
        enc = dict(self.entry, e2e=True)
        self.assertEqual(n.fold_status(enc, [self.question, DISMISS], now=ASKED + 10, encrypted=True)['state'], 'pending')
        self.assertEqual(n.fold_status(enc, [self.question, DISMISS], now=ASKED + 10, encrypted=True,
                                       authenticated_ids={'D1': True})['state'], 'dismissed')

    def test_cached_dismissal_outlives_retention(self):
        e = dict(self.entry, final=dict(state='dismissed', dismissed_at=ASKED + 5))
        self.assertEqual(n.fold_status(e, [], now=ASKED + 99999)['state'], 'dismissed')


class ReadShowsDismissal(unittest.TestCase):
    def test_plain_and_json(self):
        out = io.StringIO()
        n.print_message(DISMISS, False, out)
        self.assertIn('dismissed question R', out.getvalue())
        self.assertIn('not an answer', out.getvalue())
        out = io.StringIO()
        n.print_message(DISMISS, True, out)
        row = json.loads(out.getvalue())
        self.assertEqual(row['dismissed'], 'R')
        self.assertNotIn('reply_to', row)


class DeadlineAndReminderTags(unittest.TestCase):
    def test_expires_on_plain_buttons_uses_the_schema_exp_only(self):
        args = n.build_parser().parse_args(['ask', '--expires', '2h', 'Deploy?'])
        schema = n.schema_from_args(args, now=ASKED)
        self.assertEqual(schema['exp'], ASKED + 7200)
        c = Recorder()
        with patch.object(n, 'record_ask'):
            n.ask(c, 't', 'Deploy?', request_id='R', schema=schema, wait=False, wall_clock=lambda: ASKED)
        q = c.calls[0]
        self.assertFalse([t for t in q['tags'] if t.startswith('exp-')])
        self.assertTrue(any('#ask-v2=' in a.get('url', '') for a in q['actions']))

    def test_reminders_carry_schema_rem_on_the_same_sequence(self):
        t = [0.0]
        c = Recorder()

        def stream(topics, since, deadline, clock=None):
            t[0] = deadline
            return iter([])
        c.stream = stream
        with patch.object(n, 'record_ask'):
            n.ask(c, 't', 'Q', request_id='R', remind=[300], timeout=301, settle=False, clock=lambda: t[0],
                  wall_clock=lambda: ASKED)
        rem = c.calls[1]
        self.assertEqual(rem['sequence_id'], 'R')
        self.assertEqual(n.decode_schema(rem['actions'][0]['url'].split('=', 1)[1])['rem'], 1)
        self.assertFalse([x for x in rem['tags'] if x.startswith('rem-')])


class Version(unittest.TestCase):
    def test_version(self):
        self.assertEqual(n.VERSION, '0.6.0')


if __name__ == '__main__':
    unittest.main()
