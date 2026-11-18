"""ntf-ai 0.4.2 security fixes (second review, 2026-11-17).

1. E2E strict status never trusts a cached ledger answer that was not recorded as authenticated.
2. (a) The same ciphertext posted again (a replay) is skipped: the first copy wins and a copy never replaces a later
   answer. (b) Outer fields outside the ciphertext (an attachment) are dropped from decrypted messages.
"""
import base64
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, os.environ.get('NTF_CLI_DIR', str(Path(__file__).resolve().parents[1])))
import ntf_ai as n

ASKED = 1000


def client():
    c = n.Client('https://ntf-ai.app')
    c.topic_password = 'pw'
    return c


def seal(c, message, tags=('re-R',)):
    return n.encrypt_jwe(c._topic_key('t'), json.dumps({'message': message, 'tags': list(tags)}).encode())


class LedgerTests(unittest.TestCase):
    def entry(self, final):
        return dict(id='R', topic='t', server='https://ntf-ai.app', asked_at=ASKED, schema=None, e2e=True, final=final)

    def test_strict_status_ignores_a_cached_unauthenticated_answer(self):
        cached = dict(state='acked', answered_at=ASKED + 1, acked_at=ASKED + 2, answer_authenticated=False)
        self.assertEqual(n.fold_status(self.entry(cached), [], now=ASKED + 3)['state'], 'acked')
        self.assertEqual(n.fold_status(self.entry(cached), [], now=ASKED + 3, require_authenticated=True)['state'], 'pending')
        # A 0.4.0/0.4.1 ledger row does not say: fail closed.
        legacy = dict(state='answered', answered_at=ASKED + 1)
        self.assertEqual(n.fold_status(self.entry(legacy), [], now=ASKED + 3, require_authenticated=True)['state'], 'pending')
        good = dict(cached, answer_authenticated=True)
        self.assertEqual(n.fold_status(self.entry(good), [], now=ASKED + 3, require_authenticated=True)['state'], 'acked')

    def test_ledger_keeps_whether_an_encrypted_answer_was_authenticated(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, 'asks.jsonl')
            for auth in (False, True):
                n.record_ask(self.entry(dict(state='answered', answered_at=ASKED + 1,
                                             answer=dict(answer='approve', authenticated=auth, message_id='M'))), path=path, now=ASKED)
                row = n.find_ask('R', path=path)
                self.assertNotIn('answer', row['final'])  # answer text never stored for encrypted asks
                self.assertIs(row['final']['answer_authenticated'], auth)
                self.assertEqual(row['final']['answer_message_id'], 'M')
                state = n.fold_status(row, [], now=ASKED + 3, require_authenticated=True)['state']
                self.assertEqual(state, 'answered' if auth else 'pending')


class ReplayTests(unittest.TestCase):
    def status(self, c, rows, entry=None):
        c.poll = lambda topics, since: rows
        c.capabilities = lambda: {}
        entry = entry or dict(id='R', topic='t', server=c.server, asked_at=ASKED, schema=None)
        with patch.object(n, 'find_ask', return_value=entry), patch.object(n, 'record_ask'):
            return n.question_status(c, 't', 'R', now=ASKED + 100)

    def test_replayed_ciphertext_is_skipped_so_the_first_copy_wins(self):
        c = client()
        reject = seal(c, 'reject')
        # The first copy predates the question (unauthenticated); a fresh copy would otherwise pass as bound and fresh.
        r = self.status(c, [dict(event='message', id='1', topic='t', time=ASKED - 5, message=reject),
                            dict(event='message', id='2', topic='t', time=ASKED + 3, message=reject)])
        self.assertEqual((r['answer']['message_id'], r['answer']['authenticated']), ('1', False))
        self.assertEqual(c.replayed, 1)

    def test_first_authenticated_answer_wins_in_fold(self):
        c = client()
        r = self.status(c, [dict(event='message', id='1', topic='t', time=ASKED + 1, message=seal(c, 'approve')),
                            dict(event='message', id='2', topic='t', time=ASKED + 2, message=seal(c, 'reject'))])
        self.assertEqual((r['answer']['answer'], r['answered_at']), ('approve', ASKED + 1))

    def test_respelled_replay_is_caught(self):
        c = client()
        jwe = seal(c, 'yes')
        first = dict(event='message', id='1', topic='t', time=ASKED + 1, message=jwe)
        self.assertTrue(c.decode_answer(first)[1])
        # Surrounding whitespace: same bytes, so a replay.
        self.assertEqual(c.decode_answer(dict(first, id='2', message=jwe + '\n')), (None, False))
        self.assertEqual(c.replayed, 1)
        # Spare trailing bits in the 16-byte tag (22 characters): same bytes, another spelling. Rejected outright.
        parts = jwe.split('.')
        alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
        parts[4] = parts[4][:-1] + alphabet[alphabet.index(parts[4][-1]) ^ 1]
        respelled = '.'.join(parts)
        self.assertEqual(base64.urlsafe_b64decode(parts[4] + '=='), n.unb64url(jwe.split('.')[4]))  # same bytes
        with self.assertRaises(n.NtfError):
            n.unb64url(parts[4])
        self.assertEqual(c.decode_answer(dict(first, id='3', message=respelled)), (None, False))
        self.assertEqual(c.undecryptable, 1)

    def test_cross_process_replay_after_the_original_aged_out_does_not_change_status(self):
        writer = client()
        approve = seal(writer, 'approve')
        entry = dict(id='R', topic='t', server=writer.server, asked_at=ASKED, schema=None, e2e=True,
                     final=dict(state='acked', answered_at=ASKED + 1, acked_at=ASKED + 2, answer_authenticated=True,
                                answer_message_id='A1'))
        replay = dict(event='message', id='X9', topic='t', time=ASKED + 50, message=approve)
        later = dict(event='message', id='X10', topic='t', time=ASKED + 60, message=seal(writer, 'reject'))
        for strict in (False, True):
            reader = client()  # another process: nothing in memory
            reader.e2e_strict = strict
            r = self.status(reader, [replay, later], entry=entry)
            self.assertEqual((r['state'], r['answered_at'], r.get('answer')), ('acked', ASKED + 1, None))
        # While the original is still on the server it fills in the text the ledger does not keep.
        r = self.status(client(), [dict(replay, id='A1', time=ASKED + 1), later], entry=entry)
        self.assertEqual((r['answer']['message_id'], r['answer']['answer']), ('A1', 'approve'))

    def test_same_message_again_is_not_a_replay(self):
        c = client()
        row = dict(event='message', id='1', topic='t', time=ASKED + 1, message=seal(c, 'yes'))
        self.assertTrue(c.decode_answer(row)[1])
        self.assertTrue(c.decode_answer(dict(row))[1])  # a reconnect delivers the same id again
        self.assertEqual(c.decode_answer(dict(row, id='2')), (None, False))
        self.assertEqual(c.replayed, 1)

    def test_strict_wait_skips_a_replay(self):
        c = client()
        jwe = seal(c, 'yes')
        c.poll = lambda topics, since, rows=[[dict(event='message', id='old', topic='t', time=ASKED - 5, message=jwe),
                                                dict(event='message', id='new', topic='t', time=ASKED + 1, message=jwe),
                                                dict(event='message', id='ok', topic='t', time=ASKED + 2,
                                                     message=seal(c, 'fresh'))]]: rows.pop() if rows else []
        a = n.wait_for_answer(c, 't', 'R', [], True, set(), '999', 5, poll_interval=0.01, asked_at=ASKED,
                              require_authenticated=True)
        self.assertEqual((a['answer'], a['message_id']), ('fresh', 'ok'))


class OuterFieldTests(unittest.TestCase):
    def test_outer_attachment_is_dropped_from_a_decrypted_message(self):
        c = client()
        row = dict(event='message', id='1', topic='t', time=ASKED + 1, message=seal(c, 'see file'),
                   attachment=dict(name='a.sh', url='https://evil.example/a.sh'))
        decoded, auth = c.decode_answer(row)
        self.assertTrue(auth)
        self.assertNotIn('attachment', decoded)
        a = n.match_answer(decoded, 't', 'R', [], True, set(), authenticated=auth, asked_at=ASKED)
        self.assertNotIn('attachment', a)
        plain, auth = c.decode_answer(dict(row, id='p', message='plain'))
        self.assertFalse(auth)
        self.assertIn('attachment', plain)  # plain messages keep theirs, unauthenticated as ever


if __name__ == '__main__':
    unittest.main()
