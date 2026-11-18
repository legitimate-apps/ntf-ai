"""Stdlib crypto contract; NIST CAVP vectors and independent library cross-checks."""
import io
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,os.environ.get('NTF_CLI_DIR',str(ROOT)))
import ntf_ai as n

class CryptoTests(unittest.TestCase):
    def test_nist_aes256_gcm_vectors(self):
        fixture=json.loads((ROOT/'tests/fixtures/nist-gcm256.json').read_text())
        self.assertEqual(len(fixture['vectors']),25)
        for v in fixture['vectors']:
            with self.subTest(lengths=v['lengths']):
                key,iv,pt,aad,ct,tag=[bytes.fromhex(v[k]) for k in ('Key','IV','PT','AAD','CT','Tag')]
                self.assertEqual(n.aes_gcm_encrypt(key,iv,pt,aad),(ct,tag))
                self.assertEqual(n.aes_gcm_decrypt(key,iv,ct,tag,aad),pt)
    def test_tampering_rejected_before_plaintext(self):
        key=bytes(range(32));iv=bytes(range(12));aad=b'header';pt=b'secret'*7
        ct,tag=n.aes_gcm_encrypt(key,iv,pt,aad)
        flip=lambda b: bytes([b[0]^1])+b[1:]
        for iv2,ct2,tag2,aad2 in [(flip(iv),ct,tag,aad),(iv,flip(ct),tag,aad),(iv,ct,flip(tag),aad),(iv,ct,tag,b'other')]:
            with self.subTest(aad=aad2),self.assertRaises(n.NtfError): n.aes_gcm_decrypt(key,iv2,ct2,tag2,aad2)
        for k,iv2 in [(b'x'*31,iv),(key,b'x'*11)]:
            with self.assertRaises(n.NtfError):n.aes_gcm_encrypt(k,iv2,pt,aad)
    def test_cryptography_cross_check(self):
        try:
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        except ImportError:
            self.skipTest('SPEC 10 optional oracle unavailable; NIST vectors and Swift interop remain required')
        for size in (0,1,15,16,17,60,1024,3000):
            key=os.urandom(32);iv=os.urandom(12);plain=os.urandom(size);aad=os.urandom(size//3)
            ct,tag=n.aes_gcm_encrypt(key,iv,plain,aad)
            self.assertEqual(ct+tag,AESGCM(key).encrypt(iv,plain,aad))
            self.assertEqual(n.aes_gcm_decrypt(key,iv,ct,tag,aad),plain)
    def test_salt_aliases_and_upstream_vector(self):
        a=n.derive_topic_key('pw','https://ntf-ai.app/','t')
        self.assertEqual(a,n.derive_topic_key('pw','https://ntfy-me.com','t'))
        self.assertNotEqual(a,n.derive_topic_key('pw','https://ntfy.sh','t'))
        self.assertEqual(n.derive_topic_key('secr3t password','https://ntfy.sh','mysecret').hex(),
            '30b7e72f6273da6e59d2dec535466e548da3eafc98650c9664c06edab707fa25')
    def test_jwe_header_limits_random_iv_and_raw_text(self):
        key=bytes(range(32));a=n.encrypt_jwe(key,b'hello');b=n.encrypt_jwe(key,b'hello')
        self.assertNotEqual(a,b);self.assertEqual(n.decrypt_jwe(key,a),b'hello')
        for text in ('a.b.c',a.replace('..','.key.',1),a+'=',a.replace(a.split('.')[0],'e30',1)):
            with self.assertRaises(n.NtfError):n.decrypt_jwe(key,text)
        self.assertEqual(len(n.encrypt_jwe(key,b'x'*3010)),4095)
        with self.assertRaises(n.NtfError):n.encrypt_jwe(key,b'x'*3011)
        with patch.object(n,'aes_gcm_encrypt',side_effect=AssertionError('oversize reached AES')):
            with self.assertRaises(n.NtfError):n.encrypt_jwe(key,b'x'*4000)
    def test_transport_encrypts_all_metadata_and_decodes_inner_tags_only(self):
        c=n.Client('https://ntf-ai.app');c.topic_password='password'
        body=dict(topic='t',sequence_id='R',message='private',title='secret title',tags=['agent','@bot'],priority=4,
                  actions=[dict(action='view',label='Open',url='https://ntf-ai.app/docs/agents')])
        outer=c.encode_publish(body)
        self.assertEqual(set(outer),{'topic','sequence_id','message'})
        self.assertNotIn('private',json.dumps(outer));self.assertNotIn('secret title',json.dumps(outer))
        m=dict(outer,event='message',id='A',time=1,tags=['re-forged','ans'],topic='t')
        decoded,authenticated=c.decode_answer(m)
        self.assertTrue(authenticated);self.assertEqual(decoded['tags'],['agent','@bot']);self.assertEqual(decoded['message'],'private')
        ack=c.encode_publish(dict(topic='t',message='Got it',tags=['agent','ack'],priority=1,sequence_id='R'))
        self.assertEqual(ack['tags'],['agent','ack']);self.assertNotIn('priority',ack)
        ans=c.encode_publish(dict(topic='t',message='yes',tags=['re-R','ans']))
        self.assertEqual(ans['tags'],['re-R','ans'])
    def test_wrong_password_skipped_counted_and_plain_button_unauthenticated(self):
        c=n.Client('https://ntf-ai.app');c.topic_password='pw'
        bad=n.encrypt_jwe(n.derive_topic_key('wrong',c.server,'t'),b'{"message":"x"}')
        self.assertEqual(c.decode_answer(dict(topic='t',event='message',message=bad)),(None,False))
        self.assertEqual(c.undecryptable,1)
        msg=dict(topic='t-answers',event='message',id='A',message='reply:R:yes')
        decoded,auth=c.decode_answer(msg)
        answer=n.match_answer(decoded,'t','R',[('Yes','yes')],True,set(),authenticated=auth)
        self.assertFalse(answer['authenticated'])
    def test_config_and_password_sources_fail_closed(self):
        p=n.build_parser();cfg=dict(topics={'t':{'e2e':True}})
        settings=n.resolve(p.parse_args(['--topic','t','send','Q']),env={},cfg=cfg)
        with self.assertRaises(n.NtfError):n.configure_encryption(n.Client(settings['server']),settings,'t')
        settings=n.resolve(p.parse_args(['--topic','t','send','Q']),env={'NTF_TOPIC_PASSWORD':'secret'},cfg=cfg)
        c=n.Client(settings['server']);n.configure_encryption(c,settings,'t');self.assertEqual(c.topic_password,'secret')
        with tempfile.TemporaryDirectory() as tmp:
            path=pathlib.Path(tmp)/'pw';path.write_text(' spaces matter \n')
            s=n.resolve(p.parse_args(['--password-file',str(path),'send','Q']),env={},cfg={})
            self.assertEqual(s['topic_password'],' spaces matter ')
        with self.assertRaises(n.NtfError):n.resolve(p.parse_args(['--password-env','MISSING','send','Q']),env={},cfg={})
    def test_strict_has_schema_without_plain_buttons(self):
        from test_v2 import Recorder
        c=Recorder();c.e2e_strict=True;c.topic_password='pw'
        with patch.object(n,'record_ask'):
            result=n.ask(c,'t','Q',wait=False)
        actions=c.calls[0]['actions']
        self.assertTrue(any('#ask-v2=' in a.get('url','') for a in actions))
        self.assertFalse(any(a['action']=='http' for a in actions))
    def test_attachments_refused_before_network(self):
        c=n.Client('https://ntf-ai.app');c.topic_password='pw'
        with patch.object(c,'_request',side_effect=AssertionError('network contacted')):
            with self.assertRaises(n.NtfError):c.publish('t','x',attach_url='https://example.com/report.pdf')
        with self.assertRaises(n.NtfError):c.upload('t','missing','x')

    def test_http_encoding_header_and_omitted_inner_fields(self):
        c=n.Client('https://ntf-ai.app');c.topic_password='pw'
        response=MagicMock()
        response.__enter__.return_value.read.return_value=b'{"id":"A"}'
        with patch.object(c,'_request',return_value=response) as request:
            c.publish('t','secret')
            self.assertEqual(request.call_args.args[3]['X-Encoding'],'jwe')
        raw=n.encrypt_jwe(c._topic_key('t'),b'{"message":"hello"}')
        decoded,auth=c.decode_answer(dict(topic='t',event='message',message=raw,tags=['re-forged','ans'],title='forged title'))
        self.assertTrue(auth);self.assertNotIn('tags',decoded);self.assertNotIn('title',decoded)
        self.assertEqual(c.decode_answer(dict(topic='t',event='message',id='bad',message=raw+'x')),(None,False))
        self.assertEqual(c.decode_answer(dict(topic='t',event='message',id='bad',message=raw+'x')),(None,False))
        self.assertEqual(c.undecryptable,1)

    def test_reminders_settle_and_ack_share_encrypted_transport(self):
        clock=[0.0];wires=[]
        class Capture(n.Client):
            def poll(self,*args):return []
            def stream(self,topics,since,deadline,clock=None):
                # Advance the test clock without real waiting.
                tick[0]=deadline
                return iter([])
            def _request(self,method,url,data=None,headers=None,**kw):
                outer=json.loads(data);wires.append((outer,headers))
                return io.BytesIO(json.dumps(dict(outer,id='Q'+str(len(wires)),time=1000)).encode())
        tick=clock;c=Capture('https://ntf-ai.app');c.topic_password='pw';c.e2e_strict=True
        with patch.object(n,'record_ask'):
            r=n.ask(c,'t','Question?',request_id='R',remind=[300,900],escalate=True,timeout=901,
                    clock=lambda:clock[0],wall_clock=lambda:1000)
        self.assertEqual(r['reminders_sent'],2);self.assertEqual(len(wires),4)
        decoded=[]
        for outer,headers in wires:
            self.assertEqual(headers['X-Encoding'],'jwe');self.assertNotIn('Question',outer['message'])
            decoded.append(c.decode_answer(dict(outer,event='message'))[0])
        self.assertEqual([m['priority'] for m in decoded],[3,4,4,1])
        for m,rem in zip(decoded[:3],[None,1,2]):
            self.assertFalse(any(a['action']=='http' for a in m['actions']))
            schema=n.decode_schema(m['actions'][0]['url'].split('#ask-v2=')[1])
            self.assertEqual(schema.get('rem'),rem)
        self.assertFalse(decoded[-1].get('actions'))
        n.send_ack(c,'t','R','Later receipt')
        self.assertEqual(wires[-1][0]['tags'],['agent','ack'])
        ack,auth=c.decode_answer(dict(wires[-1][0],event='message'))
        self.assertTrue(auth);self.assertEqual(ack['message'],'Later receipt');self.assertEqual(ack['tags'],['agent','ack'])

if __name__=='__main__':unittest.main()
