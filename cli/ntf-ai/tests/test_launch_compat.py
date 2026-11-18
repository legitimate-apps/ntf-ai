"""Launch compatibility (2026-11-17): NTF-AI 1.26 answers ntf 0.4's typed questions with a written reply.

Seen live on ntfy-me.com: a 1.26 user replying "2" to a four-way choice got plain `ntf ask` to print "2", not the
choice's answer key, and nothing said the answer came by the fallback path. The agent must get the same answer
whichever app version answered, and be told when the fallback was used.
"""
import contextlib
import io
import os
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch
sys.path.insert(0, os.environ.get('NTF_CLI_DIR', str(Path(__file__).resolve().parents[1])))
import ntf_ai as n

CHOICE = dict(status='answered', kind='reply', answer='2', type='choice', value='staging', valid=True,
              request_id='R', reply_to='R')


class LaunchCompatTests(unittest.TestCase):
    def cli_result(self, result, flags=()):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(n, 'ask', return_value=result), patch.object(n, 'load_config', return_value={}), \
                contextlib.redirect_stderr(err):
            code = n.main(['ask', *flags, 'Q'], stdout=out, env={'NTF_TOPIC': 't'})
        return code, out.getvalue(), err.getvalue()

    def test_plain_choice_reply_prints_the_answer_key_and_says_how_it_came(self):
        code, out, err = self.cli_result(CHOICE)
        self.assertEqual((code, out), (0, 'staging\n'))
        self.assertIn('written reply', err)
        self.assertIn("'2'", err)

    def test_plain_multi_and_form_replies_print_what_the_answer_form_sends(self):
        code, out, _ = self.cli_result(dict(CHOICE, answer='1,3', value=['a', 'c']))
        self.assertEqual((code, out), (0, 'a,c\n'))
        code, out, _ = self.cli_result(dict(CHOICE, answer='Branch: main\nReplicas: 3', type='form',
                                            value={'branch': 'main', 'replicas': 3}))
        self.assertEqual((code, out), (0, '{"branch":"main","replicas":3}\n'))
        code, out, _ = self.cli_result(dict(CHOICE, answer='12.50', type='number', value=12.5))
        self.assertEqual((code, out), (0, '12.5\n'))

    def test_native_answer_and_plain_v1_reply_are_unchanged_and_silent(self):
        code, out, err = self.cli_result(dict(CHOICE, kind='structured', answer='staging'))
        self.assertEqual((code, out, err), (0, 'staging\n', ''))
        code, out, err = self.cli_result(dict(status='answered', kind='reply', answer='sure, go', valid=None))
        self.assertEqual((code, out, err), (0, 'sure, go\n', ''))

    def test_invalid_reply_keeps_raw_text_and_exit_6(self):
        code, out, err = self.cli_result(dict(CHOICE, answer='lots', type='number', value=None, valid=False))
        self.assertEqual((code, out), (6, 'lots\n'))
        # A multi reply under its minimum still has a parsed value; the person's own text is what prints.
        code, out, _ = self.cli_result(dict(CHOICE, answer='1', value=['a'], valid=False))
        self.assertEqual((code, out), (6, '1\n'))
        self.assertIn('written reply', err)

    def test_mcp_text_gives_the_key_and_the_fallback(self):
        m = n.McpServer(dict(server='https://ntfy-me.com', topic='t'))
        with patch.object(m, '_client', return_value=object()), patch.object(n, 'ask', return_value=CHOICE):
            r = m.run_tool('ask', dict(question='Q', choices=['Prod=prod', 'Staging=staging', 'Dev=dev', 'QA=qa']),
                           threading.Event(), None)
        text = r['content'][0]['text']
        self.assertTrue(text.startswith('The person wrote: staging\n'), text)
        self.assertIn('written reply', text)


if __name__ == '__main__':
    unittest.main()
