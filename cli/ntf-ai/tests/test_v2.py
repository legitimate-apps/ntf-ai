"""Agent protocol v2 contract tests. No network; test_e2e covers the stock server."""
import base64
import copy
import io
import json
import os
import pathlib
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
sys.path.insert(0, os.environ.get('NTF_CLI_DIR', str(pathlib.Path(__file__).resolve().parents[1])))
import ntf_ai as n
FIXTURES = json.loads((pathlib.Path(__file__).parent/'fixtures/ask-v2.json').read_text())

class Recorder:
    server='https://ntf-ai.app'
    def __init__(self): self.calls=[]
    def poll(self, topics, since): return []
    def publish(self, topic, message='', **kw):
        self.calls.append(dict(topic=topic,message=message,**kw))
        return dict(self.calls[-1],id='question0001',time=1000)

class SchemaTests(unittest.TestCase):
    def test_fixtures_encode_exactly(self):
        for f in FIXTURES[:6]:
            with self.subTest(f=f['name']):
                raw=json.dumps(f['schema'],ensure_ascii=False,separators=(',',':')).encode()
                encoded=n.encode_schema(f['schema'])
                self.assertEqual(encoded,base64.urlsafe_b64encode(raw).decode().rstrip('='))
                self.assertEqual(n.decode_schema(encoded),f['schema'])
    def test_answer_table(self):
        for f in FIXTURES[:6]:
            for a in f['answers']:
                with self.subTest(f=f['name'],body=a['body']):
                    value,valid=n.validate_answer(f['schema'],a['body'],structured=False)
                    self.assertEqual(valid,a['valid'])
                    if valid: self.assertEqual(value,a['value'])
    def test_schema_limits_and_wrong_types(self):
        base=dict(v=2,kind='choice',options=[dict(k='a',l='A'),dict(k='b',l='B')])
        bad=[dict(base,options=[dict(k=str(i),l='X') for i in range(13)]),dict(base,exp=1000+7*86400+1),
             dict(base,options=[dict(k='bad,key',l='A'),dict(k='b',l='B')]),dict(base,multi=1),
             dict(v=2,kind='number',step=0),dict(v=2,kind='number',min=True),
             dict(v=2,kind='text',max=1001),dict(v=2,kind='date',mode='date',min='2026-02-30'),
             dict(v=2,kind='form',fields=[]),* [f['schema'] for f in FIXTURES[6:]]]
        for s in bad:
            with self.subTest(schema=s),self.assertRaises(n.NtfError): n.validate_schema(s,now=1000,publishing=True)
        oversized=dict(v=2,kind='text',future='x'*1504)
        self.assertEqual(len(json.dumps(oversized,separators=(',',':')).encode()),1537)
        with self.assertRaises(n.NtfError): n.encode_schema(oversized)
    def test_v1_golden(self):
        c=Recorder()
        with patch.object(n,'wait_for_answer',return_value=None),patch.object(n,'record_ask',create=True):
            n.ask(c,'topic','Deploy?',request_id='RID',timeout=0,settle=False)
        expected={'topic':'topic','message':'Deploy?','attach_url':None,'title':'Your agent needs an answer','priority':None,
                  'tags':['agent'],'markdown':False,'actions':[
            {'action':'http','label':'Approve','url':'https://ntf-ai.app/topic-answers','method':'POST',
             'headers':{'Content-Type':'text/plain'},'body':'reply:RID:approve','clear':True},
            {'action':'http','label':'Reject','url':'https://ntf-ai.app/topic-answers','method':'POST',
             'headers':{'Content-Type':'text/plain'},'body':'reply:RID:reject','clear':True}],
             'sequence_id':'RID'}
        self.assertEqual(json.dumps(c.calls[0]),json.dumps(expected))
    def test_cli_builder_actions_hints(self):
        p=n.build_parser()
        a=p.parse_args(['ask','--spec',json.dumps(dict(kind='choice',options=[dict(k=k,l=k.upper()) for k in 'abc'],multi=True,max=2)),'Q'])
        s=n.schema_from_args(a,now=1000)
        self.assertTrue(s['multi']); self.assertEqual(s['max'],2)
        actions,hint=n.schema_actions('https://ntfy-me.com','topic','RID',s,True)
        self.assertEqual(len(actions),2); self.assertIn('#ask-v2=',actions[0]['url'])
        self.assertIn('#reply-v1=',actions[1]['url']); self.assertIn('numbers, comma-separated',hint)
        self.assertEqual(n.decode_schema(actions[0]['url'].split('=',1)[1])['hint'],hint)
        a=p.parse_args(['ask','--spec',json.dumps(dict(kind='form',fields=[dict(k='branch',kind='text',l='Branch',max=60),dict(k='n',kind='number',l='Replicas',min=1,max=5)])),'Q'])
        self.assertEqual(n.schema_from_args(a)['fields'][1]['max'],5)
    def test_answer_matching_and_withdrawal(self):
        s=FIXTURES[2]['schema']; m=dict(event='message',id='M',topic='t',tags=['re-R','ans'],message='12.5')
        a=n.match_answer(m,'t','R',[],False,set(),schema=s)
        self.assertEqual((a['kind'],a['value'],a['valid'],a['authenticated'],a['reply_to']),('structured',12.5,True,False,'R'))
        m['tags']=['re-R']; m['message']='12,5'
        a=n.match_answer(m,'t','R',[],True,set(),schema=s)
        self.assertEqual((a['kind'],a['valid'],a['answer']),('reply',False,'12,5'))
        a=n.match_answer(dict(event='message_delete',id='D',topic='t',sequence_id='R'),'t','R',[],True,set(),schema=s)
        self.assertEqual(a['kind'],'withdrawn')
    def test_strict_keeps_waiting(self):
        c=Recorder(); rows=[dict(event='message',id='1',topic='t',tags=['re-R','ans'],message='bad'),
                           dict(event='message',id='2',topic='t',tags=['re-R','ans'],message='12.5')]
        c.stream=lambda *a,**kw: iter(rows)
        a=n.wait_for_answer(c,'t','R',[],True,set(),'999',5,schema=FIXTURES[2]['schema'],strict=True)
        self.assertTrue(a['valid']); self.assertEqual(a['value'],12.5)
    def test_identity_precedence_and_validation(self):
        args=n.build_parser().parse_args(['--as','Deploy bot','send','Q'])
        self.assertEqual(n.resolve(args,env={'NTF_AGENT':'Env'},cfg={'agent_name':'Config'})['agent_name'],'Deploy bot')
        self.assertEqual(n.resolve(n.build_parser().parse_args(['send','Q']),env={'NTF_AGENT':'Env'},cfg={})['agent_name'],'Env')
        with self.assertRaises(n.NtfError): n.agent_tags([], 'bad@name')
    def test_reminder_clock(self):
        c=Recorder(); t=[0.0]
        def stream(topics,since,deadline,clock=None):
            t[0]=deadline
            return iter([])
        c.stream=stream
        with patch.object(n,'record_ask'):
            r=n.ask(c,'t','Q',request_id='R',schema=dict(v=2,kind='text'),remind=[300,900],escalate=True,
                    timeout=901,settle=False,clock=lambda:t[0],wall_clock=lambda:1000)
        qs=c.calls
        self.assertEqual([x['priority'] for x in qs],[3,4,4])
        self.assertEqual([n.decode_schema(x['actions'][0]['url'].split('=',1)[1]).get('rem') for x in qs],[None,1,2])
        self.assertEqual(r['reminders_sent'],2)
        c=Recorder(); c.stream=lambda *a,**kw:iter([dict(event='message',id='A',topic='t',tags=['re-R','ans'],message='ok')])
        with patch.object(n,'record_ask'):
            n.ask(c,'t','Q',request_id='R',schema=dict(v=2,kind='text'),remind=[300,900],timeout=901,settle=False,ack=False)
        self.assertEqual(len(c.calls),1)
        for x in ['1m','5m,6m','5m,15m,20m,25m','15m,5m']:
            with self.assertRaises(n.NtfError): n.parse_reminders(x)

class StatusTests(unittest.TestCase):
    def test_fold_states_and_precedence(self):
        q=dict(event='message',id='Q',topic='t',time=1000,sequence_id='R',tags=['agent'],actions=[dict(url='x#ask-v2=x')])
        seen=dict(event='message_clear',id='S',topic='t',time=1001,sequence_id='R')
        ans=dict(event='message',id='A',topic='t',time=1002,tags=['re-R','ans'],message='hello')
        ack=dict(event='message',id='K',topic='t',time=1003,sequence_id='R',tags=['agent','ack'])
        settled=dict(event='message',id='T',topic='t',time=1004,sequence_id='R',tags=['agent'])
        delete=dict(event='message_delete',id='D',topic='t',time=1005,sequence_id='R')
        entry=dict(id='R',topic='t',server='https://ntf-ai.app',asked_at=1000,schema=dict(v=2,kind='text'),exp=1100)
        for events,now,state in [([q],1050,'pending'),([q,seen],1050,'seen'),([q,seen],1101,'expired'),
            ([q,settled],1101,'settled'),([q,ans],1101,'answered'),([q,ans,ack],1101,'acked'),
            ([q,ans,ack,delete],1101,'withdrawn'),([],50000,'unknown')]:
            with self.subTest(state=state): self.assertEqual(n.fold_status(entry,events,now=now,retention_seconds=43200)['state'],state)
        self.assertEqual(n.fold_status(entry,[],now=50000,retention_seconds=691200)['state'],'expired')
    def test_ledger_private_pruned_and_final_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=os.path.join(tmp,'asks.jsonl')
            n.record_ask(dict(id='old',asked_at=1),path=path,now=4000000)
            self.assertEqual(pathlib.Path(path).read_text(),'')
            n.record_ask(dict(id='R',asked_at=4000000,topic='t',schema=dict(v=2,kind='text')),path=path,now=4000000)
            n.record_ask(dict(id='R',asked_at=4000000,final=dict(state='answered',answer={'answer':'hi'})),path=path,now=4000001)
            self.assertEqual(os.stat(path).st_mode&0o777,0o600)
            rows=[json.loads(x) for x in pathlib.Path(path).read_text().splitlines()]
            self.assertEqual(len(rows),1); self.assertEqual(rows[0]['final']['state'],'answered')
    def test_status_uses_capabilities_and_timestamp(self):
        c=Recorder(); calls=[]
        c.poll=lambda topics,since: calls.append((topics,since)) or []
        c.capabilities=lambda:dict(agent_retention_seconds=691200)
        entry=dict(id='R',topic='t',server=c.server,asked_at=1000,schema=None)
        with patch.object(n,'find_ask',return_value=entry): r=n.question_status(c,'t','R',now=50000)
        self.assertEqual(r['retention_seconds'],691200); self.assertEqual(calls[0][1],'999')
    def test_version_one_retention_uses_advertised_field(self):
        for document, expected, state in [
            ({"version": 1, "agent_protocol": 2, "agent_retention_seconds": 691200}, 691200, 'expired'),
            ({"version": 1}, 43200, 'unknown'),
        ]:
            with self.subTest(document=document):
                c=n.Client('https://ntfy-me.com'); calls=[]
                class Response:
                    def __enter__(self): return self
                    def __exit__(self,*args): pass
                    def read(self): return json.dumps(document).encode()
                def request(method,url):
                    calls.append((method,url)); return Response()
                c._request=request
                c.poll=lambda topics,since: []
                entry=dict(id='R',topic='t',server=c.server,asked_at=1000,exp=2000,schema=None)
                with patch.object(n,'find_ask',return_value=entry),patch.object(n,'record_ask'):
                    result=n.question_status(c,'t','R',now=50000)
                self.assertEqual(result['retention_seconds'],expected)
                self.assertEqual(result['state'],state)
                self.assertEqual(calls,[('GET','https://ntfy-me.com/v1/ntfyme/capabilities')])

    def test_mcp_tools_and_nonblocking_ask(self):
        tools={t['name']:t for t in n.mcp_tools()}
        self.assertTrue({'status','withdraw'} <= tools.keys())
        self.assertTrue({'kind','options','expires','remind','wait','fields','as'} <= tools['ask']['inputSchema']['properties'].keys())
        c=Recorder(); m=n.McpServer(dict(server=c.server,topic='t'))
        with patch.object(m,'_client',return_value=c),patch.object(n,'record_ask'):
            r=m.run_tool('ask',dict(question='Q',kind='number',min=1,max=64,expires='2h',remind='5m,15m',wait=False),threading.Event(),None)
        self.assertEqual(r['structuredContent']['status'],'pending')
        schema=n.decode_schema(c.calls[0]['actions'][0]['url'].split('=',1)[1])
        self.assertEqual(schema['kind'],'number'); self.assertIn('exp',schema)


class ProtocolEdges(unittest.TestCase):
    def test_full_v1_wire_golden_from_030(self):
        class Reply:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self): return b'{"id":"question0001","time":1000,"sequence_id":"RID"}'
        fixtures=json.loads((pathlib.Path(__file__).parent/'fixtures/v1-wire.json').read_text())
        for f in fixtures:
            with self.subTest(options=f['options']):
                calls=[]; c=n.Client('https://ntf-ai.app'); c.poll=lambda *a:[]
                def capture(method,url,data=None,headers=None,**kw):
                    calls.append(dict(method=method,url=url,body=data.decode(),headers=headers));return Reply()
                c._request=capture
                with patch.object(n,'wait_for_answer',return_value=None),patch.object(n,'record_ask',create=True):
                    n.ask(c,'topic','Deploy?',request_id='RID',timeout=0,settle=False,**f['options'])
                self.assertEqual(calls[0],f['request'])
                # New --choice syntax must also preserve the old wire when its schema needs no v2 carrier.
                buttons=f['options'].get('buttons') or [('Approve','approve'),('Reject','reject')]
                schema=dict(v=2,kind='choice',options=[dict(k=key,l=label) for label,key in buttons])
                calls.clear()
                with patch.object(n,'wait_for_answer',return_value=None),patch.object(n,'record_ask',create=True):
                    n.ask(c,'topic','Deploy?',request_id='RID',timeout=0,settle=False,schema=schema,**f['options'])
                self.assertEqual(calls[0],f['request'])
    def test_action_matrix(self):
        opts=[dict(k='a',l='A'),dict(k='b',l='B'),dict(k='c',l='C')]
        for schema,reply,types,hint in [
            (dict(v=2,kind='choice',options=opts),True,['http','http','http'],False),
            (dict(v=2,kind='choice',options=opts[:2],exp=2000),True,['view','http','http'],False),
            (dict(v=2,kind='choice',options=opts,exp=2000),True,['view','view'],True),
            (dict(v=2,kind='text'),True,['view','view'],False),
            (dict(v=2,kind='text'),False,['view'],False),
            (dict(v=2,kind='number'),False,['view'],True)]:
            with self.subTest(schema=schema,reply=reply):
                actions,body=n.schema_actions('https://ntf-ai.app','t','R',schema,reply)
                self.assertEqual([a['action'] for a in actions],types);self.assertEqual(bool(body),hint)
        s=dict(v=2,kind='choice',multi=True,options=[dict(k=str(i),l='X'*40) for i in range(12)])
        acts,hint=n.schema_actions('https://ntf-ai.app','t','R',s,True)
        self.assertLessEqual(len(hint),200);self.assertEqual(len(n.decode_schema(acts[0]['url'].split('=',1)[1])['options']),12)
    def test_structured_formats_and_normalization(self):
        cases=[(FIXTURES[0]['schema'],'3',False),(FIXTURES[0]['schema'],'Production',False),
               (FIXTURES[1]['schema'],'c,a',True),
               (dict(v=2,kind='date',mode='time'),'23:59',True),
               (dict(v=2,kind='date',mode='time'),'24:00',False),
               (dict(v=2,kind='date'),'2026-11-16T09:30:00-08:00',True),
               (dict(v=2,kind='date'),'2026-11-16T09:30:00',False),
               (dict(v=2,kind='number',step=.1),'0.3',True),
               (dict(v=2,kind='number'),'NaN',False),
               (dict(v=2,kind='number'),'Infinity',False),
               (FIXTURES[5]['schema'],'{"branch":"main","replicas":"2"}',False),
               (FIXTURES[5]['schema'],'{"branch":"main","replicas":true}',False),
               (FIXTURES[5]['schema'],'{"branch":"main","replicas":2,"unknown":"x"}',False)]
        for s,body,valid in cases:
            with self.subTest(body=body): self.assertEqual(n.validate_answer(s,body,structured=True)[1],valid)
        self.assertEqual(n.validate_answer(FIXTURES[1]['schema'],'c,a',True)[0],['a','c'])
    def test_deadline_bounds(self):
        p=n.build_parser()
        for duration in ('60s','7d'):
            args=p.parse_args(['ask','--expires',duration,'Q'])
            self.assertIn('exp',n.schema_from_args(args,now=1000.9))
            with patch.object(n.time,'time',return_value=1000.9):
                self.assertIn('exp',n.mcp_schema(dict(kind='text',expires=duration)))
        for duration in ('59s','8d'):
            with self.assertRaises(n.NtfError): n.schema_from_args(p.parse_args(['ask','--expires',duration,'Q']),now=1000)
    def test_reminders_stop_on_external_settle(self):
        c=Recorder(); t=[0.0]; first=[True]
        def stream(topics,since,deadline,clock=None):
            t[0]=deadline
            if first[0]:
                first[0]=False
                return iter([dict(event='message',id='SETTLE',topic='t',sequence_id='R',tags=['agent'],time=1001)])
            return iter([])
        c.stream=stream
        with patch.object(n,'record_ask'):
            n.ask(c,'t','Q',schema=dict(v=2,kind='text'),request_id='R',timeout=901,remind=[300,900],settle=False,
                  clock=lambda:t[0],wall_clock=lambda:1000)
        self.assertEqual(len(c.calls),1)
        # An invalid submitted answer still leaves pending/seen; strict may wait for correction but must not nudge.
        c=Recorder();t[0]=0.0;first[0]=True
        def invalid(topics,since,deadline,clock=None):
            t[0]=deadline
            if first[0]:
                first[0]=False
                return iter([dict(event='message',id='BAD',topic='t',tags=['re-R','ans'],message='12,5')])
            return iter([])
        c.stream=invalid
        with patch.object(n,'record_ask'):
            n.ask(c,'t','Q',schema=dict(v=2,kind='number'),request_id='R',timeout=901,remind=[300,900],settle=False,
                  strict=True,clock=lambda:t[0],wall_clock=lambda:1000)
        self.assertEqual(len(c.calls),1)
    def test_ask_timestamp_and_deadline(self):
        c=Recorder(); calls=[]
        def wait(*args,**kw): calls.append((args,kw));return None
        with patch.object(n,'record_ask'),patch.object(n,'wait_for_answer',side_effect=wait):
            n.ask(c,'t','Q',schema=dict(v=2,kind='text',exp=1100),timeout=600,wall_clock=lambda:1000.5,settle=False)
        self.assertEqual(calls[0][0][6],'999'); self.assertEqual(calls[0][0][7],99.5)
    def test_status_without_ledger_and_cached_terminal(self):
        e=dict(id='R',topic='t',server='https://ntf-ai.app',asked_at=None,schema=None)
        ans=dict(id='A',event='message',topic='t-answers',message='reply:R:any',time=2)
        r=n.fold_status(e,[ans],now=5000000)
        self.assertEqual((r['state'],r['answer']['valid']),('answered',None))
        clear=dict(id='C',event='message_clear',topic='t',sequence_id='R',time=3)
        self.assertEqual(n.fold_status(e,[clear],now=5000000)['state'],'seen')
        e.update(asked_at=1,final=dict(answer=dict(answer='cached'),answered_at=2,acked_at=3))
        self.assertEqual(n.fold_status(e,[],now=5000000)['state'],'acked')
        for name in ('message_clear','message_delete'):
            row=dict(id='E',event=name,topic='t',sequence_id='OTHER',time=3)
            self.assertEqual(n.fold_status(dict(e,final={}),[row],now=5000000)['state'],'unknown')
    def test_capability_route_and_stock_fallback(self):
        c=n.Client('https://ntf-ai.app'); calls=[]
        class Response:
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self):return b'{"agent_retention_seconds":691200}'
        def request(method,url):calls.append((method,url));return Response()
        c._request=request
        self.assertEqual(c.capabilities()['agent_retention_seconds'],691200)
        self.assertEqual(calls,[('GET','https://ntf-ai.app/v1/ntfyme/capabilities')])
        c._request=lambda *a: (_ for _ in ()).throw(n.NtfError('404'))
        self.assertEqual(c.capabilities(),{})
    def test_invalid_numeric_inputs_are_usage_errors(self):
        with self.assertRaises(n.NtfError):n.validate_schema(dict(v=2,kind='number',max=10**1000))
        for kw in (dict(timeout=float('nan')),dict(timeout=-1),dict(poll_interval=-1)):
            with self.subTest(kw=kw),self.assertRaises(n.NtfError):n.ask(Recorder(),'t','Q',**kw)

    def test_no_reply_still_accepts_structured(self):
        c=Recorder(); c.stream=lambda *a,**kw:iter([dict(event='message',id='A',topic='t',tags=['re-R','ans'],message='ok')])
        err=io.StringIO()
        with patch.object(n,'record_ask'),patch('sys.stderr',err):
            r=n.ask(c,'t','Q',schema=dict(v=2,kind='text'),request_id='R',accept_reply=False,ack=False)
        self.assertTrue(r['valid']); self.assertIn('older clients',err.getvalue());self.assertIn('no-reply',c.calls[0]['tags'])


if __name__=='__main__': unittest.main()
