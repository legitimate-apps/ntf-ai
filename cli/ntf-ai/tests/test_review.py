"""Regression gates for the independent c7c0180 review; exercise public behavior."""
import contextlib
import io
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
sys.path.insert(0, os.environ.get('NTF_CLI_DIR', str(Path(__file__).resolve().parents[1])))
import ntf_ai as n
from test_v2 import Recorder

class ReviewTests(unittest.TestCase):
    def cli_result(self, result, flags=()):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(n, 'ask', return_value=result), patch.object(n, 'load_config', return_value={}), contextlib.redirect_stderr(err):
            code = n.main(['ask', *flags, 'Q'], stdout=out, env={'NTF_TOPIC':'t'})
        return code, out.getvalue(), err.getvalue()

    def test_B1_unwritable_ledger_does_not_abandon_published_question(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)/'file'; parent.write_text('not a directory')
            c=Recorder(); c.ledger_file=str(parent/'asks.jsonl')
            c.stream=lambda *a,**kw:iter([dict(event='message',id='A',topic='t',tags=['re-R'],message='hello',time=1001)])
            err=io.StringIO()
            with contextlib.redirect_stderr(err):
                r=n.ask(c,'t','Q',request_id='R',timeout=2,ack=False)
            self.assertEqual(r['answer'],'hello'); self.assertEqual(len(c.calls),1)
            self.assertIn('ledger',err.getvalue()); self.assertNotIn('Traceback',err.getvalue())

    def test_M1_failed_reminder_retries_without_losing_answer(self):
        c=Recorder(); t=[0.0]; attempts=[]; original=c.publish
        def publish(*a,**kw):
            if c.calls:
                attempts.append(t[0])
                if len(attempts)==1:
                    e=n.NtfError('HTTP 429'); e.retry_after='7'; raise e
            return original(*a,**kw)
        c.publish=publish
        def stream(topics,since,deadline,clock=None):
            t[0]=deadline
            if len(attempts)>=2:
                return iter([dict(event='message',id='A',topic='t',tags=['re-R','ans'],message='ok',time=1001)])
            return iter([])
        c.stream=stream
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stderr(io.StringIO()) as err:
            c.ledger_file=str(Path(tmp)/'asks.jsonl')
            r=n.ask(c,'t','Q',request_id='R',schema=dict(v=2,kind='text'),remind=[300],timeout=320,
                    ack=False,clock=lambda:t[0],wall_clock=lambda:1000)
        self.assertEqual(r['answer'],'ok'); self.assertEqual(r['reminders_sent'],1)
        self.assertEqual(attempts,[300,307]); self.assertIn('reminder',err.getvalue())
        self.assertEqual(n.decode_schema(c.calls[1]['actions'][0]['url'].split('=',1)[1])['rem'],1)

    def test_M1_delayed_retry_keeps_successful_reminders_five_minutes_apart(self):
        c=Recorder(); t=[0.0]; attempts=[]; original=c.publish
        def publish(*a,**kw):
            if c.calls:
                attempts.append(t[0])
                if len(attempts)==1:
                    e=n.NtfError('HTTP 429'); e.retry_after='600'; raise e
            return original(*a,**kw)
        c.publish=publish
        def stream(topics,since,deadline,clock=None):
            t[0]=deadline
            if len(c.calls)>=3:
                return iter([dict(event='message',id='A',topic='t',tags=['re-R','ans'],message='ok',time=1001)])
            return iter([])
        c.stream=stream
        with patch.object(n,'record_ask'),contextlib.redirect_stderr(io.StringIO()):
            r=n.ask(c,'t','Q',request_id='R',schema=dict(v=2,kind='text'),remind=[300,900],timeout=1210,
                    ack=False,clock=lambda:t[0],wall_clock=lambda:1000)
        self.assertEqual(r['answer'],'ok'); self.assertEqual(r['reminders_sent'],2)
        self.assertEqual(attempts,[300,900,1200])

    def test_M2_plain_pending_prints_handle(self):
        code,out,err=self.cli_result(dict(status='pending',request_id='RID'),['--no-wait'])
        self.assertEqual((code,out),(0,'RID\n'))

    def test_M2_mcp_pending_text_includes_handle(self):
        c=Recorder(); m=n.McpServer(dict(server=c.server,topic='t'))
        with patch.object(m,'_client',return_value=c),patch.object(n,'record_ask'):
            r=m.run_tool('ask',dict(question='Q',wait=False),threading.Event(),None)
        self.assertIn(r['structuredContent']['request_id'],r['content'][0]['text'])

    def test_M3_invalid_plain_answer_is_not_success(self):
        code,out,err=self.cli_result(dict(status='answered',kind='reply',answer='banana',valid=False))
        self.assertEqual(code,6); self.assertEqual(out,'banana\n'); self.assertIn('invalid',err)

    def test_M4_cursor_and_ledger_use_publication_server_time(self):
        for skew in (-120,120):
            c=Recorder()
            with tempfile.TemporaryDirectory() as tmp:
                c.ledger_file=str(Path(tmp)/'asks.jsonl')
                with patch.object(n,'wait_for_answer',return_value=None) as wait, patch.object(n.time,'time',return_value=1000+skew):
                    n.ask(c,'t','Q',request_id='R',wall_clock=lambda:1000+skew,settle=False)
                self.assertEqual(wait.call_args.args[6],'999')
                self.assertEqual(n.find_ask('R',c.ledger_file)['asked_at'],1000)

    def test_M6_choice_and_button_share_label_first_order_and_limit(self):
        for flag in ('--button','--choice'):
            args=n.build_parser().parse_args(['ask',flag,'Go!=go',flag,'Stop=stop','Q'])
            schema=n.schema_from_args(args)
            if schema is None:
                opts=[dict(k=k,l=l) for l,k in n.parse_buttons(args.button)]
            else: opts=schema['options']
            self.assertEqual(opts,[dict(k='go',l='Go!'),dict(k='stop',l='Stop')])
            argv=['ask']
            for i in range(12): argv += [flag,'Option '+str(i)+'=k'+str(i)]
            schema=n.schema_from_args(n.build_parser().parse_args(argv+['Q']))
            self.assertEqual(len(schema['options']),12)

    def test_M6_spec_replaces_rare_flags_without_losing_kinds(self):
        schemas=[dict(kind='number',min=1,max=9,step=.5,unit='GB'),dict(kind='date',mode='date',min='2026-11-15'),
                 dict(kind='text',max=60,placeholder='Branch!'),dict(kind='form',fields=[dict(k='go',l='Go!',kind='choice',options=[dict(k='y',l='Yes!',d=True),dict(k='n',l='No')])]),
                 dict(kind='choice',multi=True,min=1,max=2,options=[dict(k='a',l='A'),dict(k='b',l='B')])]
        for s in schemas:
            with self.subTest(schema=s):
                a=n.build_parser().parse_args(['ask','--spec',json.dumps(s),'Q'])
                self.assertEqual(n.schema_from_args(a),dict(v=2,**s))
        with tempfile.TemporaryDirectory() as tmp:
            f=Path(tmp)/'schema.json'; f.write_text(json.dumps(schemas[0]))
            a=n.build_parser().parse_args(['ask','--spec','@'+str(f),'Q'])
            self.assertEqual(n.schema_from_args(a),dict(v=2,**schemas[0]))
        p=n.build_parser(); sub=next(a for a in p._actions if isinstance(a,n.argparse._SubParsersAction)).choices['ask']
        self.assertLessEqual(sum(bool(a.option_strings) for a in sub._actions),34)
        self.assertNotIn('--number',sub.format_help())

    def test_m1_comma_in_free_choice_label_is_atomic(self):
        for multi in (False,True):
            s=dict(v=2,kind='choice',multi=multi,options=[dict(k='yes',l='Yes, deploy'),dict(k='no',l='No')])
            self.assertEqual(n.validate_answer(s,'Yes, deploy'),(['yes'] if multi else 'yes',True))
            self.assertEqual(n.validate_answer(s,'yes,no',True)[1],multi)

    def test_m2_fractional_datetime_is_portable_to_python39(self):
        # A real 3.9 interpreter catches fromisoformat's old 3/6-digit restriction.
        code="import sys;sys.path.insert(0,sys.argv[1]);import ntf_ai as n;assert n.validate_answer(dict(v=2,kind='date'),'2026-11-16T09:30:00.5-08:00')[1]"
        current_datetime=n.datetime.datetime
        class Python39Datetime(current_datetime):
            @classmethod
            def fromisoformat(cls, value):
                fraction=re.search(r"\.(\d+)",value)
                if fraction and len(fraction.group(1)) not in (3,6):
                    raise ValueError("Python 3.9 fractional precision")
                return current_datetime.fromisoformat(value)
        with patch.object(n.datetime,'datetime',Python39Datetime):
            self.assertTrue(n.validate_answer(dict(v=2,kind='date'),'2026-11-16T09:30:00.5-08:00')[1])
        interpreters=[sys.executable]
        if Path('/usr/bin/python3').exists(): interpreters.append('/usr/bin/python3')
        for python in interpreters:
            r=subprocess.run([python,'-c',code,str(Path(n.__file__).parent)],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stderr)

    def test_m3_hosted_alias_does_not_erase_custom_port_or_path(self):
        canonical=n.derive_topic_key('pw','https://ntfy-me.com','t')
        self.assertNotEqual(n.derive_topic_key('pw','http://ntf-ai.app:8443','t'),canonical)
        self.assertNotEqual(n.derive_topic_key('pw','https://ntf-ai.app/prefix','t'),canonical)
        self.assertEqual(n.derive_topic_key('pw','https://NTF-AI.APP:443','t'),canonical)

    def test_m3b_ask_warns_once_on_first_undecryptable_message(self):
        c=n.Client('https://ntf-ai.app'); c.topic_password='right'
        bad=n.encrypt_jwe(n.derive_topic_key('wrong',c.server,'t'),b'{"message":"secret"}')
        rows=[dict(event='message',id=i,topic='t',message=bad) for i in ('A','B')]
        rows.append(dict(event='message',id='C',topic='t',tags=['re-R'],message='ok'))
        c.stream=lambda *a,**kw:iter(rows)
        err=io.StringIO()
        with contextlib.redirect_stderr(err):
            a=n.wait_for_answer(c,'t','R',[],True,set(),'999',5)
        self.assertEqual(a['answer'],'ok'); self.assertEqual(c.undecryptable,2)
        self.assertEqual(err.getvalue().count('undecryptable'),1)
        self.assertIn('password',err.getvalue()); self.assertNotIn('secret',err.getvalue())

    def test_m5_withdrawn_plain_explains_exit(self):
        code,out,err=self.cli_result(dict(status='withdrawn',kind='withdrawn'))
        self.assertEqual(code,5); self.assertIn('withdrawn',err)

    def test_m6_encrypted_ledger_retains_state_without_plaintext_answer(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=str(Path(tmp)/'asks.jsonl')
            entry=dict(id='R',topic='t',server='https://ntf-ai.app',asked_at=1000,e2e=True,
                       final=dict(state='acked',answered_at=1001,acked_at=1002,answer=dict(answer='secret-value',value='secret-value')))
            n.record_ask(entry,path=path,now=1002)
            self.assertNotIn('secret-value',Path(path).read_text())
            r=n.fold_status(n.find_ask('R',path),[],now=1000000)
            self.assertEqual(r['state'],'acked'); self.assertEqual(r['answered_at'],1001)

    def test_m7_default_docs_gate_has_a_real_guide(self):
        import test_docs
        self.assertTrue(test_docs.GUIDE and Path(test_docs.GUIDE).is_file())
        self.assertFalse(getattr(test_docs.GuideRecipeRuns,'__unittest_skip__',False))

    def test_n1_number_hint_describes_quantization(self):
        for schema,term in [(dict(v=2,kind='number',min=1,max=9),'whole number'),
                            (dict(v=2,kind='number',step=.5),'steps of 0.5'),
                            (dict(v=2,kind='number',min=.5),'steps of 1')]:
            actions,hint=n.schema_actions('https://ntf-ai.app','t','R',schema,True)
            self.assertIn(term,hint)

    def test_n3_poll_publish_window_message_is_not_legacy_reply(self):
        c=Recorder(); polls=[0]
        stale=dict(event='message',id='OLD',topic='t',message='old',time=1000)
        q=dict(event='message',id='question0001',topic='t',tags=['agent'],time=1000)
        answer=dict(event='message',id='A',topic='t',message='new',time=1000)
        def poll(*a):
            polls[0]+=1
            return [] if polls[0]==1 else [stale,q,answer]
        c.poll=poll; c.stream=lambda *a,**kw:iter([stale,q,answer])
        with patch.object(n,'record_ask'):
            r=n.ask(c,'t','Q',request_id='R',ack=False)
        self.assertEqual(r['answer'],'new')

if __name__=='__main__': unittest.main()
