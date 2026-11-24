"""Kind guesses get a repairable schema; free replies keep the documented exit contract."""
import contextlib
import io
import json
import os
from pathlib import Path
import shlex
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.environ.get('NTF_CLI_DIR', str(Path(__file__).resolve().parents[1])))
import ntf_ai as n
from test_v2 import Recorder


class KindHintTests(unittest.TestCase):
    def diagnostic(self, kind, as_json=False):
        out, err = io.StringIO(), io.StringIO()
        flags = ['--json'] if as_json else []
        with patch.object(n, 'load_config', return_value={}), \
                patch.object(n.Client, '_request') as request, contextlib.redirect_stderr(err):
            code = n.main(['ask', '--spec', json.dumps({'kind': kind}), *flags, 'Q'],
                          stdout=out, env={'NTF_TOPIC': 't'})
        request.assert_not_called()
        self.assertEqual(code, 2)
        self.assertLessEqual(len(err.getvalue().splitlines()), 2)
        return out.getvalue(), err.getvalue()

    def assert_repair(self, kind, multi=False, yesno=False):
        out, message = self.diagnostic(kind)
        self.assertEqual(out, '')
        self.assertIn('valid kinds: choice, number, date, text, form', message)
        self.assertIn(repr(kind), message)
        fragment = message.splitlines()[1].split('Use --spec ', 1)[1]
        tokens = shlex.split(fragment)
        self.assertEqual(len(tokens), 1, 'the suggested JSON must be shell-quoted')
        args = n.build_parser().parse_args(['ask', '--spec', tokens[0], 'Q'])
        repaired = n.schema_from_args(args)
        self.assertEqual(repaired['kind'], 'choice')
        self.assertEqual(repaired.get('multi', False), multi)
        labels = ['Yes', 'No'] if yesno else ['A', 'B']
        self.assertEqual(repaired['options'], [dict(k=x.lower(), l=x) for x in labels])

    def test_multi_hint(self):
        self.assert_repair('multi', multi=True)

    def test_select_hint(self):
        self.assert_repair('select')

    def test_options_hint(self):
        self.assert_repair('options')

    def test_buttons_hint(self):
        self.assert_repair('buttons')

    def test_bool_hint(self):
        self.assert_repair('bool', yesno=True)

    def test_boolean_hint(self):
        self.assert_repair('boolean', yesno=True)

    def test_yesno_hint(self):
        self.assert_repair('yesno', yesno=True)

    def test_unknown_kind_lists_valid_kinds(self):
        _, message = self.diagnostic('toggle')
        self.assertEqual(len(message.splitlines()), 1)
        self.assertIn('valid kinds: choice, number, date, text, form', message)

    def test_nonstring_kind_is_a_usage_error(self):
        _, message = self.diagnostic([])
        self.assertIn('valid kinds: choice, number, date, text, form', message)

    def test_json_usage_error_preserves_the_hint(self):
        out, message = self.diagnostic('multi', as_json=True)
        result = json.loads(out)
        self.assertEqual(result['status'], 'error')
        self.assertIn('Use --spec ', result['error'])
        self.assertTrue(message.endswith(result['error'] + '\n'))

    def test_form_multi_hint_offers_a_supported_single_choice(self):
        with self.assertRaises(n.NtfError) as caught:
            n.validate_schema(dict(kind='multi', k='x', l='X'), field=True)
        message = str(caught.exception)
        self.assertEqual(caught.exception.code, 2)
        self.assertLessEqual(len(message.splitlines()), 2)
        self.assertIn('valid kinds: choice, number, date, text\n', message)
        self.assertIn('Form choices are single-select; use ', message)
        repaired = json.loads(message.split('Form choices are single-select; use ', 1)[1])
        n.validate_schema(repaired, field=True)
        self.assertEqual(repaired['kind'], 'choice')
        self.assertFalse(repaired.get('multi', False))

    def test_choice_free_reply_exit_contract(self):
        spec = dict(kind='choice', options=[dict(k='red', l='Red'), dict(k='blue', l='Blue')])
        for flags, expected_code in [(['--json'], 0), ([], 6), (['--json', '--strict'], 0)]:
            with self.subTest(flags=flags):
                c = Recorder()
                rows = [dict(event='message', id='A', topic='t', time=1001,
                             tags=['re-R'], message='Teal please')]
                if '--strict' in flags:
                    rows.append(dict(rows[0], id='B', message='Red'))
                c.stream = lambda *a, **kw: iter(rows)
                out, err = io.StringIO(), io.StringIO()
                with patch.object(n, 'Client', return_value=c), \
                        patch.object(n, 'load_config', return_value={}), \
                        patch.object(n, 'new_request_id', return_value='R'), \
                        patch.object(n, 'record_ask'), contextlib.redirect_stderr(err):
                    code = n.main(['ask', '--spec', json.dumps(spec), '--no-ack', *flags, 'Color?'],
                                  stdout=out, env={'NTF_TOPIC': 't'})
                self.assertEqual(code, expected_code)
                if '--json' in flags:
                    result = json.loads(out.getvalue())
                    self.assertEqual(result['kind'], 'reply')
                    self.assertEqual(result['valid'], '--strict' in flags)
                    self.assertEqual(result['answer'], 'Red' if '--strict' in flags else 'Teal please')
                else:
                    self.assertEqual(out.getvalue(), 'Teal please\n')
                    self.assertIn('invalid', err.getvalue())
